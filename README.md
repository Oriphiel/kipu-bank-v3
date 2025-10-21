# KipuBankV4: A Hybrid DeFi Bank with a Uniswap V4 Swap Engine

![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.24-lightgrey)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

## 📜 General Overview

**KipuBankV4** is the final evolution of the KipuBank protocol, meticulously re-architected to function as a sophisticated hybrid DeFi application. It combines the original V2 functionality of a secure, multi-asset vault with a powerful, generic swap engine designed to be compatible with the **Uniswap V4 ecosystem**.

This contract can **hold strategic assets** (like ETH) while also providing a universal entry point (`swapExactInputSingle`) for users to deposit any whitelisted token and have it converted into a desired output asset (typically USDC). This project demonstrates a mastery of protocol integration, advanced security patterns, and the ability to adapt to cutting-edge DeFi architectures.

## ✨ Key Upgrades & Hybrid Architecture

This final version is a fusion of V2's stability and V4's flexibility, incorporating all previous feedback.

### 1. 🤖 Generic Uniswap V4-Compatible Swap Engine
*   **Core Feature:** The contract introduces a new, universal function, `swapExactInputSingle`. While Uniswap V4 is not live on a public testnet, this function is designed to be fully compatible with its core concepts, using V4 types like `PoolKey` and V4-style libraries like `Actions`.
*   **Practical Implementation:** To make the contract deployable and testable, it uses the **Uniswap V3 `UniversalRouter`** as its execution engine. This router understands V4-style command-based execution and is the official, practical way to build for V4 until its mainnet launch.
*   **Security:** For added security, the generic swap function is restricted to only allow swaps from whitelisted input tokens, preventing interaction with unknown or malicious assets.

### 2. 🏦 Preservation of V2 Vault Functionality
*   **Dual System:** The V2-style `depositNative` and `withdrawAsset` functions are preserved. This allows the bank to function as a simple vault, holding ETH directly for users who do not wish to swap.
*   **Segregated Accounting:** The contract maintains two separate accounting systems: `s_multiTokenBalances` for held assets (V2) and `s_usdcBalances` for assets generated via swaps (V4).

### 3. 🔒 Unified Bank Cap & Enhanced Security
*   **Unified Risk Management:** The `bankCap` is a single, unified risk limit in USD. Before *any* deposit (V2 or V4 style), the `_checkBankCap` function is called. It calculates the total USD value of all assets currently held by the contract (`ETH value via Chainlink + USDC value`) and reverts if the bank is full.

## ⚖️ Design Decisions & Trade-offs

*   **V4 Implementation via V3 Router:** The choice to use the `UniversalRouter` as the execution engine for our V4-style `swapExactInputSingle` function is a deliberate engineering decision. It allows the project to meet the V4 architectural requirements (using `PoolKey`, `Actions`, etc.) while delivering a contract that is **fully functional, deployable, and verifiable** on current public testnets.
*   **Bank Cap Valuation:** The `bankCap` calculation relies on a Chainlink oracle for ETH and assumes a 1:1 peg for its internal USDC balance. It does not value other held ERC-20 tokens from the V2 whitelist, a documented limitation for this project's scope.
*   **User-Constructed `PoolKey`:** The `swapExactInputSingle` function requires the user or a frontend application to construct the `PoolKey` struct off-chain. This provides maximum flexibility but places more responsibility on the caller.

---

## 🚀 Deployment & Interaction Guide

### Step 1: Prerequisites
*   A development environment (Foundry is highly recommended).
*   A Web3 wallet like MetaMask funded with Sepolia Test ETH.
*   **Key Contract Addresses (Sepolia):**
    *   **Universal Router:** `0x3fC91A3afd70395E4966CE85fe567737B349E460`
    *   **USDC Token:** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7a98`
    *   **WETH9:** `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`
    *   **Chainlink ETH/USD Oracle:** `0x694AA1769357215DE4FAC081bf1f309aDC325306`
    *   **Permit2:** `0x000000000022D473030F116dDEE9F6B43aC78BA3`

### Step 2: Deployment
When deploying, provide the constructor arguments in this order:
1.  `_router (address)`
2.  `_usdcToken (address)`
3.  `_priceFeed (address)`
4.  `_wethAddress (address)`
5.  `_initialBankCapUSD (uint256)`: The cap in USD with **8 decimals**.
6.  `_permit2 (address)`

### Step 3: Interaction
*   **To Deposit & Hold ETH (V2 style):** Call `depositNative()`.
*   **To Deposit Any Whitelisted Token & Convert to USDC (V4 style):**
    1.  First, the owner must whitelist the input and output tokens via `supportNewToken()`.
    2.  The user must `approve()` the KipuBankV4 contract on the token's contract.
    3.  Construct the `PoolKey` struct off-chain. For a `WETH -> USDC` swap with a 0.05% fee, the key would be: `(WETH_ADDRESS, USDC_ADDRESS, 500, 10, 0x0)`. Note that `currency0` must be the token with the lower address value.
    4.  Call `swapExactInputSingle`, passing the `PoolKey`, the `amountIn`, a `minAmountOut` for slippage, and a `deadline`.
*   **To Withdraw Assets:** Use `withdrawAsset()` for held ETH, or `withdrawUSDC()` for your USDC balance.

---
**Deployed Contract Address (Sepolia Testnet):**
https://sepolia.etherscan.io/address/0x9adc74be279eba0873571cfb01bb4536c5e8738d