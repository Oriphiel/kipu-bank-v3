// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// OpenZeppelin and Uniswap imports
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import { Commands } from "universal-router/contracts/libraries/Commands.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV3
 * @author A. H.
 * @notice A hybrid DeFi bank that stores strategic assets (ETH, whitelisted tokens) and also converts
 *         arbitrary assets to USDC via Uniswap integration.
 * @dev This contract fuses V2 functionality (multi-token accounting, Chainlink oracle) with V3 capabilities
 *      (on-chain swaps), creating a more complete and realistic DeFi system. It incorporates all feedback from V2.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20; // Enabled secure methods

    // ==============================================================================
    // State Variables
    // ==============================================================================

    /**
     * @notice The immutable instance of Uniswap's Universal Router, set at deployment.
     */
    IUniversalRouter public immutable i_universalRouter;

    /**
     * @notice The immutable instance of the USDC token contract, used as the bank's unit of account.
     */
    IERC20 public immutable i_USDC;

    /**
     * @notice The immutable address of the Wrapped Ether (WETH) contract, fetched from the router at deployment.
     */
    address public immutable i_WETH;

    /**
     * @notice The immutable instance of the Chainlink ETH/USD price feed.
     */
    AggregatorV3Interface public immutable i_priceFeed;

    /**
     * @notice The special address used to represent the native token (ETH).
     */
    address public constant NATIVE_TOKEN = address(0);

    /** 
     * @notice The maximum staleness of the price feed data, in seconds. 
     */
    uint256 constant ORACLE_HEARTBEAT = 3600;

    /**
     * @notice The total capital limit of the bank, denominated in USDC with 6 decimals.
     * @dev This value can be updated by the contract owner via setBankCap().
     */
    uint256 public s_bankCapUSD;

    /**
     * @notice Mapping from a user's address to their balance in USDC (with 6 decimals).
     */
    mapping(address => uint256) private s_usdcBalances;

    /**
     * @notice V2-style accounting for native ETH and whitelisted tokens. user => token => balance.
     */
    mapping(address => mapping(address => uint256))
        private s_multiTokenBalances;

    /**
     * @notice Whitelist for ERC-20 tokens that can be held directly by the bank.
     */
    mapping(address => bool) private s_isTokenSupported;

    // ==============================================================================
    // Custom Errors
    // ==============================================================================

    /** @notice Reverts if a deposit or withdrawal amount is zero. */
    error AmountMustBePositive();

    /**
     * @notice Reverts if a deposit would cause the bank's total USDC balance to exceed the cap.
     * @param newTotalUSDC The total USDC balance the contract would have after the deposit.
     * @param bankCap The current bank capital limit in USDC.
     */
    error BankCapExceeded(uint256 newTotalUSDC, uint256 bankCap);

    /**
     * @notice Reverts if a function is called with invalid parameters for a swap (e.g., using depositArbitraryToken for USDC).
     * @param reason A description of the error.
     */
    error InvalidSwapParameters(string reason);

    /**
     * @notice Reverts if the Uniswap swap execution fails or results in zero output.
     * @param reason A description of the failure.
     */
    error SwapFailed(string reason);

    /**
     * @notice Reverts if a user tries to withdraw more than their available balance.
     * @param userBalance The user's current USDC balance.
     * @param withdrawAmount The amount the user attempted to withdraw.
     */
    error InsufficientBalance(uint256 userBalance, uint256 withdrawAmount);

    /**
     * @notice Reverts if an invalid address is provided (e.g., address(0) for a token).
     * @param reason A description of why the address is invalid.
     */
    error InvalidAddress(string reason);

    /**
     * @notice Reverts if the Chainlink oracle call fails or returns an invalid price.
     */
    error OracleFailed();

    /**
     * @notice Reverts if the token is not supported
     */
    error TokenNotSupported();

    // ==============================================================================
    // Events
    // ==============================================================================

    /**
     * @notice Emitted when a user deposits ETH or a whitelisted token.
     * @param user The address of the depositor.
     * @param token The address of the token deposited.
     * @param amount The amount of the token deposited.
     */
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user deposits an arbitrary token and it is swapped for USDC.
     * @param user The address of the depositor.
     * @param tokenIn The address of the token deposited.
     * @param amountIn The amount of the token deposited.
     * @param usdcAmountOut The amount of USDC received from the swap.
     */
    event DepositAndSwap(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcAmountOut);

    /**
     * @notice Emitted when a user withdraws.
     * @param user The address of the withdrawer.
     * @param token The address of the token.
     * @param amount The amount of withdrawn.
     */
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    // ==============================================================================
    // Constructor
    // ==============================================================================

    /**
     * @notice Initializes the contract with key infrastructure addresses and the initial bank cap.
     * @param _router The address of Uniswap's UniversalRouter contract on the target network.
     * @param _usdcToken The address of the canonical USDC token contract on the target network.
     * @param _priceFeed The address of the oracle feed
     * @param _wethAddress The address of the WETH contract.
     * @param _initialBankCapUSD The initial capital limit in USDC, denominated with 6 decimals.
     */
    constructor(
        address _router,
        address _usdcToken,
        address _priceFeed,
        address _wethAddress,
        uint256 _initialBankCapUSD
    ) {
        i_universalRouter = IUniversalRouter(_router);
        i_USDC = IERC20(_usdcToken);
        i_WETH = _wethAddress;
        s_bankCapUSD = _initialBankCapUSD;
        i_priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // ==============================================================================
    // Internal Swap Logic
    // ==============================================================================

    /**
     * @dev Internal function to execute a swap via the UniversalRouter.
     */
    function _swapExactInputSingle(address _tokenIn, uint256 _amountIn, uint24 _fee, uint256 _amountOutMinimum) private returns (uint256 usdcAmountOut) {
        IERC20(_tokenIn).safeApprove(address(i_universalRouter), _amountIn);
        bytes memory path = abi.encodePacked(_tokenIn, _fee, address(i_USDC));
        bytes memory commands = abi.encodePacked(Commands.V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(this), _amountIn, _amountOutMinimum, path, false);

        uint256 balanceBefore = i_USDC.balanceOf(address(this));
        if (_tokenIn == i_WETH) {
            i_universalRouter.execute{value: _amountIn}(commands, inputs, block.timestamp);
        } else {
            i_universalRouter.execute(commands, inputs, block.timestamp);
        }
        usdcAmountOut = i_USDC.balanceOf(address(this)) - balanceBefore;
        if (usdcAmountOut == 0) revert SwapFailed("Swap resulted in zero output");
    }
    
    /**
     * @dev Internal function to check the bank cap before a deposit.
     */
    function _checkBankCap(address _tokenDeposited, uint256 _amountDeposited) internal view {
        (, int256 price, , uint256 updatedAt, ) = i_priceFeed.latestRoundData();
        if (price <= 0 || block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert OracleFailed(); // Staleness check (1 hour)

        // Value of ETH held by the contract, in USD with 8 decimals
        uint256 ethValueUSD = (address(this).balance * uint256(price)) / 10**18;
        
        // Value of USDC held by the contract, normalized to 8 decimals for comparison
        uint256 usdcValueUSD = (i_USDC.balanceOf(address(this)) * 100);

        uint256 totalValueUSD = ethValueUSD + usdcValueUSD;

        if (totalValueUSD > s_bankCapUSD) {
            revert BankCapExceeded(totalValueUSD, s_bankCapUSD);
        }
    }

    // ==============================================================================
    // Deposit Functions
    // ==============================================================================

    /**
     * @notice Deposits ETH to be held as ETH in the bank (V2 functionality).
     */
    function depositNative() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert AmountMustBePositive();
        _checkBankCap(NATIVE_TOKEN, msg.value);
        s_multiTokenBalances[msg.sender][NATIVE_TOKEN] += msg.value;
        emit Deposit(msg.sender, NATIVE_TOKEN, msg.value);
    }

    /**
     * @notice Deposits a whitelisted token to be held as-is (V2 functionality).
     */
    function depositSupportedToken(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountMustBePositive();
        if (!s_isTokenSupported[_token]) revert TokenNotSupported();

        _checkBankCap(address(_token), _amount );
        
        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 amountReceived = IERC20(_token).balanceOf(address(this)) - balanceBefore;

        s_multiTokenBalances[msg.sender][_token] += amountReceived;
        emit Deposit(msg.sender, _token, amountReceived);
    }

    /**
     * @notice Deposits any arbitrary token to be swapped for USDC (V3 functionality).
     */
    function depositAndSwapToUSDC(address _tokenIn, uint256 _amountIn, uint24 _fee) external nonReentrant whenNotPaused {
        if (_tokenIn == address(i_USDC)) revert InvalidSwapParameters("Use a direct deposit function for USDC");
        if (_amountIn == 0) revert AmountMustBePositive();
        
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        uint256 usdcReceived = _swapExactInputSingle(_tokenIn, _amountIn, _fee, 0);
        
        _checkBankCap(address(i_USDC), usdcReceived);

        s_usdcBalances[msg.sender] += usdcReceived;
        emit DepositAndSwap(msg.sender, _tokenIn, _amountIn, usdcReceived);
    }

    // ==============================================================================
    // Withdrawal Functions
    // ==============================================================================

 
    /**
     * @notice Withdraws assets held directly (ETH or whitelisted tokens).
     */
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
    
    /**
     * @notice Withdraws the user's USDC balance.
     */
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

    /**
     * @notice Allows the owner to update the bank's capital limit.
     * @param _newBankCapUSD The new limit in USD, expressed with 8 decimals.
     */
    function setBankCap(uint256 _newBankCapUSD) external onlyOwner whenNotPaused {
        s_bankCapUSD = _newBankCapUSD;
    }
    

    /**
     * @notice Pauses all token transfers. Can only be called by the owner.
     * @dev This public function acts as a gateway to the internal _pause() function
     *      from the Pausable contract, securing it with the onlyOwner modifier.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming all token transfers. Can only be called by the owner.
     * @dev This public function acts as a gateway to the internal _unpause() function
     *      from the Pausable contract, securing it with the onlyOwner modifier.
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @notice Allows the owner to add a new ERC-20 token to the list of supported assets.
     * @param _tokenAddress The address of the ERC-20 token to support.
     */
    function supportNewToken(address _tokenAddress) external onlyOwner whenNotPaused{
        if (_tokenAddress == NATIVE_TOKEN) revert InvalidAddress("Native token is supported by default");
        s_isTokenSupported[_tokenAddress] = true;
    }

    /**
     * @notice Allows the owner to remove an ERC-20 token from the list of supported assets.
     * @dev This does not affect existing deposits of the token.
     * @param _tokenAddress The address of the ERC-20 token to remove.
     */
    function removeTokenSupport(address _tokenAddress) external onlyOwner whenNotPaused{
        s_isTokenSupported[_tokenAddress] = false;
    }

    // ==============================================================================
    // View Functions
    // ==============================================================================

    /**
     * @notice Returns the USDC balance for a specific user.
     * @param _user The address of the user to query.
     * @return The user's balance in USDC (with 6 decimals).
     */
    function getUsdcBalance(address _user) external view returns (uint256) {
        return s_usdcBalances[_user];
    }

    /**
     * @notice Returns the balance of a specific held asset (ETH or whitelisted token) for a user.
     * @param _user The address of the user to query.
     * @param _token The address of the asset (use address(0) for ETH).
     * @return The user's balance of the specified asset.
     */
    function getAssetBalance(address _user, address _token) external view returns (uint256) {
        return s_multiTokenBalances[_user][_token];
    }
}
