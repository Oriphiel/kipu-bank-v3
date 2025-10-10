# KipuBankV3: A Hybrid DeFi Vault & Aggregator

![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.20-lightgrey)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

## 📜 General Overview

**KipuBankV3** is the culmination of the KipuBank series, evolving into a hybrid DeFi protocol that combines the stability of a multi-asset vault (from V2) with the flexibility of a DeFi aggregator. The contract can now **hold strategic assets** (like ETH and whitelisted tokens) while also **accepting any other Uniswap-tradable asset**, automatically converting it to USDC.

This project demonstrates an advanced architecture that preserves existing functionality while integrating with complex external protocols, reflecting the real-world challenges of DeFi development. It also incorporates all code quality and security feedback from the V2 review, including the use of custom errors, strict naming conventions, and robust security patterns.

## ✨ Key Upgrades & Hybrid Architecture

This final version builds upon V2's secure foundation, extending its capabilities rather than replacing them.

### 1. 🏦 Dual Accounting System
*   **V2 Functionality Preserved:** The core multi-token accounting system (`s_multiTokenBalances`) is maintained. It stores the balances of **ETH** (`address(0)`) and **owner-approved whitelisted ERC-20 tokens**, allowing the bank to hold a diversified portfolio.
*   **New V3 Capability:** A new, separate accounting system for **USDC** (`s_usdcBalances`) has been introduced. This balance is credited when users deposit arbitrary, non-whitelisted tokens that are then swapped to USDC.

### 2. 🦄 Uniswap Integration for Universal Deposits
*   A new function, `depositAndSwapToUSDC`, integrates with Uniswap's **`UniversalRouter`**. This allows users to deposit any token with liquidity, which the contract automatically swaps into USDC, crediting the user's new USDC-specific balance.

### 3. 🔒 Preservation & Enhancement of V2's Core Features
*   **Chainlink Oracle Maintained:** The Chainlink oracle remains a crucial component. It is used to value the bank's native ETH holdings when verifying the total `bankCap` before any new deposit, ensuring the risk limit is respected across all asset types.
*   **Unified Bank Cap:** The `bankCap` is a unified risk limit measured in USD. Before any deposit, the contract calculates the total USD value of its current holdings (`ETH value via Chainlink + USDC value`) and ensures the new deposit does not breach the cap.
*   **Owner Control & Security:** All administrative and security features from V2 (`Ownable`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, and the token whitelist) are preserved and applied to the new functionality.

## ⚖️ Design Decisions & Trade-offs

*   **Bank Cap Valuation:** The `bankCap` is measured in USD (with 8 decimals to match the Chainlink oracle). The bank's total value is calculated on-chain as: `(Total value of ETH held, priced by Chainlink) + (Total value of USDC held)`. For the scope of this exam, the value of other whitelisted ERC-20 tokens is not included in this on-chain calculation, a documented limitation that would require a multi-oracle registry in a full production system.

---

## 🚀 Deployment & Interaction Guide (Using Remix or Foundry)

### Step 1: Prerequisites
*   A development environment (Remix IDE or a local Foundry setup).
*   A Web3 wallet like MetaMask funded with Sepolia Test ETH.
*   **Key Contract Addresses (Sepolia):**
    *   **Universal Router:** `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`
    *   **USDC Token:** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`
    *   **Chainlink ETH/USD Oracle:** `0x694AA1769357215DE4FAC081bf1f309aDC325306`
    *   **WETH9:** `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`

### Step 2: Deployment
When deploying, you must provide the constructor arguments in the correct order:
1.  `_router (address)`: The Universal Router address.
2.  `_usdcToken (address)`: The USDC token address.
3.  `_priceFeed (address)`: The Chainlink oracle address.
4.  `_wethAddress (address)`: The WETH9 contract address.
5.  `_initialBankCapUSD (uint256)`: The cap in USD with **8 decimals**. For a **$1,000,000** cap, enter: `100000000000000`.

### Step 3: Verification on Etherscan
*   **Flatten** your `KipuBankV3.sol` contract. In Foundry, run `forge flatten src/KipuBankV3.sol > KipuBankV3_flat.sol`. In Remix, right-click the file and select "Flatten".
*   Copy the content of the flattened file.
*   On Etherscan, use the **Solidity (Single File)** verifier, paste the code, and match the compiler version and other settings.

### Step 4: Interaction
You can interact with the verified contract on Etherscan's `Read Contract` and `Write Contract` tabs.

#### **User Functions:**
*   **Check Balances:**
    *   Call `getUsdcBalance(userAddress)` to see a user's USDC balance.
    *   Call `getAssetBalance(userAddress, tokenAddress)` to see a user's balance of a held asset (use `0x0...0` for ETH).
*   **To Deposit & Hold ETH (V2 style):** Call `depositNative()` and send ETH with the transaction.
*   **To Deposit & Hold a Whitelisted Token (V2 style):** The contract `owner` must first add the token via `supportNewToken()`. Then, the user must `approve()` the bank on the token's contract and call `depositSupportedToken()`.
*   **To Deposit Any Token & Convert to USDC (V3 style):** The user must `approve()` the bank on the token's contract and then call `depositAndSwapToUSDC()`.
*   **To Withdraw Assets:** Use `withdrawAsset(tokenAddress, amount)` for your held ETH and whitelisted token balances, or `withdrawUSDC(amount)` for your USDC balance.

#### **Admin Functions (Owner Only):**

*   **Manage Whitelist:** Use `supportNewToken()` and `removeTokenSupport()`.
*   **Emergency Controls:** Use `pause()` and `unpause()`.
*   **Manage Bank Cap:** Use `setBankCap()`.

---
**Deployed Contract Address (Sepolia Testnet):**
https://sepolia.etherscan.io/address/0xd718845cf52a7d5c445c1187985e770e93aa53d1