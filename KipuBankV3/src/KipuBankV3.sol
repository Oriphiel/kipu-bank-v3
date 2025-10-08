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

}