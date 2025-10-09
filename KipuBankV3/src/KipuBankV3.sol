// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// OpenZeppelin and Uniswap imports
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/security/Pausable.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/**
 * @title KipuBankV3
 * @author A. H. (Evolved for Final Exam)
 * @notice A DeFi aggregator bank that accepts any Uniswap-tradable asset, converts it to USDC, and manages user balances.
 * @dev This contract integrates with Uniswap's UniversalRouter to achieve V4-like functionality on a live testnet.
 *      It incorporates all feedback from the V2 review, including custom errors and strict naming conventions.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20; // Enabled secure methods

    // ==============================================================================
    // State Variables
    // ==============================================================================

    // --- Immutable State ---

    /**
     * @notice The immutable instance of Uniswap's Universal Router, set at deployment.
     */
    IUniversalRouter public immutable i_universalRouter;

    /**
     * @notice The immutable instance of Uniswap's Permit2 contract, set at deployment.
     */
    IPermit2 public immutable i_permit2;

    /**
     * @notice The immutable instance of the USDC token contract, used as the bank's unit of account.
     */
    IERC20 public immutable i_USDC;

    /**
     * @notice The immutable address of the Wrapped Ether (WETH) contract, fetched from the router at deployment.
     */
    address public immutable i_WETH;

    // --- Storage State ---

    /**
     * @notice The total capital limit of the bank, denominated in USDC with 6 decimals.
     * @dev This value can be updated by the contract owner via setBankCap().
     */
    uint256 private s_bankCapUSD;

    /**
     * @notice Mapping from a user's address to their balance in USDC (with 6 decimals).
     */
    mapping(address => uint256) private s_usdcBalances;

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

    // ==============================================================================
    // Events
    // ==============================================================================

    /**
     * @notice Emitted when a user successfully deposits funds and they are converted to USDC.
     * @param user The address of the depositor.
     * @param tokenIn The address of the asset that was deposited.
     * @param amountIn The amount of the input asset.
     * @param usdcAmountOut The amount of USDC credited to the user's balance after the swap.
     */
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcAmountOut);

    /**
     * @notice Emitted when a user successfully withdraws their USDC.
     * @param user The address of the recipient.
     * @param usdcAmount The amount of USDC withdrawn.
     */
    event Withdrawal(address indexed user, uint256 usdcAmount);

    // ==============================================================================
    // Constructor
    // ==============================================================================

    /**
     * @notice Initializes the contract with key infrastructure addresses and the initial bank cap.
     * @param _router The address of Uniswap's UniversalRouter contract on the target network.
     * @param _usdcToken The address of the canonical USDC token contract on the target network.
     * @param _permit2 The address of Uniswap's Permit2 contract.
     * @param _wethAddress The address of the WETH contract.
     * @param _initialBankCapUSD The initial capital limit in USDC, denominated with 6 decimals.
     */
    constructor(
        address _router,
        address _usdcToken,
        address _permit2,
        address _wethAddress, 
        uint256 _initialBankCapUSD
    ) Ownable() { 
        i_universalRouter = IUniversalRouter(_router);
        i_USDC = IERC20(_usdcToken);
        i_permit2 = IPermit2(_permit2);
        i_WETH = _wethAddress; 
        s_bankCapUSD = _initialBankCapUSD;
    }

    
    // ==============================================================================
    // Internal Swap Logic
    // ==============================================================================

    /**
     * @dev Implements the swap logic as required, using the UniversalRouter as the V4 stand-in.
     * @param _tokenIn The token to swap from.
     * @param _amountIn The amount to swap.
     * @param _fee The fee tier of the Uniswap pool.
     * @param _amountOutMinimum The minimum amount of USDC to receive for slippage protection.
     * @return usdcAmountOut The amount of USDC received from the swap.
     */
    function _swapExactInputSingle(address _tokenIn, uint256 _amountIn, uint24 _fee, uint256 _amountOutMinimum) private returns (uint256 usdcAmountOut) {
        IERC20(_tokenIn).safeApprove(address(i_universalRouter), _amountIn);

        bytes memory path = abi.encodePacked(_tokenIn, _fee, address(i_USDC));

        bytes memory commands = abi.encodePacked(IUniversalRouter.Command.V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(this),   // recipient
            _amountIn,       // amountIn
            _amountOutMinimum,
            path,
            false            // payerIsUser
        );

        uint256 balanceBefore = i_USDC.balanceOf(address(this));

        if (_tokenIn == i_WETH) {
            i_universalRouter.execute{value: _amountIn}(commands, inputs);
        } else {
            i_universalRouter.execute(commands, inputs);
        }
        
        usdcAmountOut = i_USDC.balanceOf(address(this)) - balanceBefore;
        if (usdcAmountOut == 0) revert SwapFailed("Swap resulted in zero output");
    }


    // ==============================================================================
    // Deposit Functions
    // ==============================================================================

    /**
     * @notice Deposits ETH, which is swapped for USDC and credited to the user's balance.
     */
    function depositNative() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert AmountMustBePositive();
        
        uint256 usdcReceived = _swapExactInputSingle(i_WETH, msg.value, 3000, 0);
        
        uint256 newTotalBalance = i_USDC.balanceOf(address(this));
        if (newTotalBalance > s_bankCapUSD) {
            revert BankCapExceeded(newTotalBalance, s_bankCapUSD);
        }

        s_usdcBalances[msg.sender] += usdcReceived;
        emit Deposit(msg.sender, i_WETH, msg.value, usdcReceived);
    }
    
    /**
     * @notice Deposits USDC directly into the bank without a swap for gas efficiency.
     * @param _amount The amount of USDC to deposit (with 6 decimals).
     */
    function depositUSDC(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountMustBePositive();

        uint256 balanceBefore = i_USDC.balanceOf(address(this));
        i_USDC.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 amountReceived = i_USDC.balanceOf(address(this)) - balanceBefore;
        
        uint256 newTotalBalance = i_USDC.balanceOf(address(this));
        if (newTotalBalance > s_bankCapUSD) {
            revert BankCapExceeded(newTotalBalance, s_bankCapUSD);
        }

        s_usdcBalances[msg.sender] += amountReceived;
        emit Deposit(msg.sender, address(i_USDC), _amount, amountReceived);
    }

    /**
     * @notice Deposits any arbitrary ERC-20 token, which is then swapped for USDC via Uniswap.
     * @param _tokenIn The address of the ERC-20 token to deposit.
     * @param _amountIn The amount of the token to deposit.
     * @param _fee The fee tier of the Uniswap V3 pool for the token->USDC pair (e.g., 3000 for 0.3%).
     */
    function depositArbitraryToken(address _tokenIn, uint256 _amountIn, uint24 _fee) external nonReentrant whenNotPaused {
        if (_tokenIn == address(i_USDC)) revert InvalidSwapParameters("Use depositUSDC for direct deposits");
        if (_amountIn == 0) revert AmountMustBePositive();
        
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        uint256 usdcReceived = _swapExactInputSingle(_tokenIn, _amountIn, _fee, 0);
        
        uint256 newTotalBalance = i_USDC.balanceOf(address(this));
        if (newTotalBalance > s_bankCapUSD) {
            revert BankCapExceeded(newTotalBalance, s_bankCapUSD);
        }

        s_usdcBalances[msg.sender] += usdcReceived;
        emit Deposit(msg.sender, _tokenIn, _amountIn, usdcReceived);
    }

}
