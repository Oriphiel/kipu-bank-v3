// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
// OpenZeppelin and Uniswap imports
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import { Commands } from "universal-router/contracts/libraries/Commands.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
// --- Uniswap V4 Imports ---
import { IV4Router } from "v4-periphery/src/interfaces/IV4Router.sol";
import { Actions } from "v4-periphery/src/libraries/Actions.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";

/**
 * @title KipuBankV4 (Final Task Version)
 * @author A. H.
 * @notice A hybrid DeFi bank with a corrected and functional Uniswap V4 swap implementation.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // ==============================================================================
    // State Variables
    // ==============================================================================
    /** @notice The immutable instance of Uniswap's Universal Router, which executes V4-style commands. */
    IUniversalRouter public immutable i_universalRouter;
    /** @notice The immutable instance of Uniswap's Permit2 contract for signature-based approvals. */
    IPermit2 public immutable i_permit2;
    /** @notice The immutable instance of the USDC token contract, used as the primary stable unit of account. */
    IERC20 public immutable i_USDC;
    /** @notice The immutable address of the Wrapped Ether (WETH) contract. */
    address public immutable i_WETH;
    /** @notice The immutable instance of the Chainlink ETH/USD price feed for V2-style cap validation. */
    AggregatorV3Interface public immutable i_priceFeed;

    /** @notice A constant representing the native token (ETH) for internal accounting. */
    address public constant NATIVE_TOKEN = address(0);
    /** @notice The maximum staleness period for oracle price data, in seconds (1 hour). */
    uint256 private constant ORACLE_HEARTBEAT = 3600;

    /** @notice The total capital limit of the bank, in USD with 8 decimals (matching Chainlink). */
    uint256 public s_bankCapUSD;
    /** @notice V4-style accounting for USDC balances derived from swaps. user => balance. */
    mapping(address => uint256) public s_usdcBalances;
    /** @notice V2-style accounting for native ETH and whitelisted tokens. user => token => balance. */
    mapping(address => mapping(address => uint256)) public s_multiTokenBalances;
    /** @notice Whitelist for ERC-20 tokens that can be held directly by the bank (V2 functionality). */
    mapping(address => bool) public s_isTokenSupported;

    // ==============================================================================
    // Custom Errors
    // ==============================================================================
    error AmountMustBePositive();
    error BankCapExceeded(uint256 newTotalUSDC, uint256 bankCap);
    error InvalidSwapParameters(string reason);
    error SwapFailed(string reason);
    error InsufficientBalance(uint256 userBalance, uint256 withdrawAmount);
    error InvalidAddress(string reason);
    error OracleFailed();
    error TokenNotSupported();
    error SwapModule_MultipleTokenInputsAreNotAllowed();

    // ==============================================================================
    // Events
    // ==============================================================================
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event DepositAndSwap(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    // ==============================================================================
    // Constructor
    // ==============================================================================
    constructor(
        address payable _router,
        address _usdcToken,
        address _priceFeed,
        address _wethAddress,
        uint256 _initialBankCapUSD,
        address _permit2
    ) {
        i_universalRouter = IUniversalRouter(_router);
        i_USDC = IERC20(_usdcToken);
        i_WETH = _wethAddress;
        s_bankCapUSD = _initialBankCapUSD;
        i_priceFeed = AggregatorV3Interface(_priceFeed);
        i_permit2 = IPermit2(_permit2);
    }

    // ==============================================================================
    // Uniswap V4 Generic Swap Function
    // ==============================================================================

    /**
     * @notice Executes a generic exact-input swap using Uniswap V4.
     * @param _key The PoolKey identifying the Uniswap V4 pool to trade in.
     * @param _amountIn The exact amount of input tokens to be swapped.
     * @param _minAmountOut The minimum amount of output tokens you are willing to receive.
     * @param _deadline The deadline by which the transaction must be executed.
     * @dev For ERC20 swaps, the user must first approve THIS contract to spend their tokens.
     */
    function swapExactInputSingle(
        PoolKey calldata _key,
        uint128 _amountIn,
        uint128 _minAmountOut,
        uint48 _deadline
    ) external payable {
        address tokenIn = Currency.unwrap(_key.currency0);
        address tokenOut = Currency.unwrap(_key.currency1);

        if (msg.value > 0 && tokenIn != NATIVE_TOKEN) {
            revert SwapModule_MultipleTokenInputsAreNotAllowed();
        }

        // El swap solo procederá si el token de entrada está en la lista blanca (o es ETH nativo).
        if (tokenIn != NATIVE_TOKEN && !s_isTokenSupported[tokenIn]) {
            revert TokenNotSupported();
        }

        if (tokenOut != NATIVE_TOKEN && !s_isTokenSupported[tokenOut]) {
                    revert TokenNotSupported();
        }

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // --- CORRECCIÓN FINAL: Usar la acción TAKE en lugar de SETTLE ---
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.TAKE) // <--- CAMBIO #1
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: _key,
                zeroForOne: true,
                amountIn: _amountIn,
                amountOutMinimum: _minAmountOut,
                hookData: bytes("")
            })
        );
        // Parámetros para la acción TAKE: (moneda, destinatario, cantidad)
        // Usamos cantidad 0 para indicar "toma todo el saldo que me debes de esta moneda".
        params[1] = abi.encode(_key.currency1, address(this), uint128(0)); // <--- CAMBIO #2

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // El resto de la función es correcto...
        if (tokenIn != NATIVE_TOKEN) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
            IERC20(tokenIn).safeApprove(address(i_universalRouter), _amountIn);
        }

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        if (tokenIn == NATIVE_TOKEN) {
            i_universalRouter.execute{value: msg.value}(commands, inputs, _deadline);
        } else {
            i_universalRouter.execute(commands, inputs, _deadline);
        }

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountOut = balanceAfter - balanceBefore;

        if (tokenIn != NATIVE_TOKEN && IERC20(tokenIn).allowance(address(this), address(i_universalRouter)) > 0) {
            IERC20(tokenIn).safeApprove(address(i_universalRouter), 0);
        }

        // Se comprueba el valor total del banco DESPUÉS de recibir los nuevos fondos.
        _checkBankCap(tokenOut, amountOut);

        uint256 actualAmountIn = (tokenIn == NATIVE_TOKEN) ? msg.value : _amountIn;
        if (tokenOut == address(i_USDC)) {
            s_usdcBalances[msg.sender] += amountOut;
        } else {
            // If swapping to other tokens is allowed, credit the multi-token balance.
            s_multiTokenBalances[msg.sender][tokenOut] += amountOut;
        }
        emit DepositAndSwap(msg.sender, tokenIn, actualAmountIn, amountOut);
    }
    // ==============================================================================
    // Core Bank Deposit & Withdrawal Functions
    // ==============================================================================

    /** @notice Deposits ETH to be held as ETH in the bank. */
    function depositNative() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert AmountMustBePositive();
        _checkBankCap(NATIVE_TOKEN, msg.value);
        s_multiTokenBalances[msg.sender][NATIVE_TOKEN] += msg.value;
        emit Deposit(msg.sender, NATIVE_TOKEN, msg.value);
    }

    /** @notice Deposits a whitelisted token to be held as-is. */
    function depositSupportedToken(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountMustBePositive();
        if (!s_isTokenSupported[_token]) revert TokenNotSupported();
        _checkBankCap(_token, _amount);

        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 amountReceived = IERC20(_token).balanceOf(address(this)) - balanceBefore;

        s_multiTokenBalances[msg.sender][_token] += amountReceived;
        emit Deposit(msg.sender, _token, amountReceived);
    }

    function _checkBankCap(address _tokenDeposited, uint256 _amountDeposited) internal view {
        (, int256 price, , uint256 updatedAt, ) = i_priceFeed.latestRoundData();
        if (price <= 0 || block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert OracleFailed();

        uint256 ethValueUSD = (address(this).balance * uint256(price)) / 10**18;
        uint256 usdcValueUSD = i_USDC.balanceOf(address(this)) * (10**2);
        uint256 totalValueUSD = ethValueUSD + usdcValueUSD;

        if (totalValueUSD > s_bankCapUSD) {
            revert BankCapExceeded(totalValueUSD, s_bankCapUSD);
        }
    }

    function withdrawAsset(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountMustBePositive();
        uint256 userBalance = s_multiTokenBalances[msg.sender][_token];
        if (userBalance < _amount) revert InsufficientBalance(userBalance, _amount);

        s_multiTokenBalances[msg.sender][_token] = userBalance - _amount;

        if (_token == NATIVE_TOKEN) {
            (bool success, ) = msg.sender.call{value: _amount}("");
            if (!success) revert SwapFailed("Native token transfer failed");
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
        emit Withdrawal(msg.sender, _token, _amount);
    }

    function withdrawUSDC(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountMustBePositive();
        uint256 userBalance = s_usdcBalances[msg.sender];
        if (userBalance < _amount) revert InsufficientBalance(userBalance, _amount);

        s_usdcBalances[msg.sender] = userBalance - _amount;
        i_USDC.safeTransfer(msg.sender, _amount);
        emit Withdrawal(msg.sender, address(i_USDC), _amount);
    }

    // ==============================================================================
    // Administrative Functions
    // ==============================================================================
    function setBankCap(uint256 _newBankCapUSD) external onlyOwner whenNotPaused {
        s_bankCapUSD = _newBankCapUSD;
    }

    function pause() public onlyOwner { _pause(); }

    function unpause() public onlyOwner { _unpause(); }

    function supportNewToken(address _tokenAddress) external onlyOwner whenNotPaused {
        if (_tokenAddress == NATIVE_TOKEN) revert InvalidAddress("Native token is supported by default");
        s_isTokenSupported[_tokenAddress] = true;
    }

    function removeTokenSupport(address _tokenAddress) external onlyOwner whenNotPaused {
        s_isTokenSupported[_tokenAddress] = false;
    }

    // ==============================================================================
    // View Functions
    // ==============================================================================
    function getUsdcBalance(address _user) external view returns (uint256) {
        return s_usdcBalances[_user];
    }

    function getAssetBalance(address _user, address _token) external view returns (uint256) {
        return s_multiTokenBalances[_user][_token];
    }
}