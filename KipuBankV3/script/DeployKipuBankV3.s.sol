// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

/**
 * @title DeployKipuBankV3
 * @notice A Foundry script to deploy the KipuBankV3 contract on the Sepolia testnet.
 * @dev This script reads sensitive data (private key) from environment variables
 *      and passes all necessary constructor arguments for a complete deployment.
 */
contract DeployKipuBankV3 is Script {
    function run() external returns (KipuBankV3) {
        // --- Configuration ---
        // Load the deployer's private key from the .env file
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // Ensure the private key is set
        if (deployerPrivateKey == 0) {
            revert("PRIVATE_KEY environment variable not set.");
        }

        // --- Sepolia Testnet Addresses ---
        address routerAddress = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b; // Universal Router
        address usdcTokenAddress = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // USDC Token
        address wethAddress = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // WETH9
        address priceFeedAddress = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Chainlink ETH/USD

        // --- Bank Cap Configuration ---
        // $1,000,000 USD with 8 decimals (to match Chainlink's price feed)
        uint256 initialBankCapUSD = 1_000_000 * 10**8;

        // --- Deployment ---
        // Start broadcasting transactions signed with the deployer's private key
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the KipuBankV3 contract with all constructor arguments
        KipuBankV3 kipuBankV3 = new KipuBankV3(
            routerAddress,
            usdcTokenAddress,
            priceFeedAddress,
            wethAddress,
            initialBankCapUSD
        );

        // Stop broadcasting
        vm.stopBroadcast();
        return kipuBankV3;
    }
}
