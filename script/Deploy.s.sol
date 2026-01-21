// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {Minter} from "../src/Minter.sol";
import {BoardManager} from "../src/BoardManager.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {Referral} from "../src/Referral.sol";
import {Automation} from "../src/Automation.sol";

contract DeployScript is Script {
    // BSC Testnet BTCB address
    address constant BTC_ADDRESS = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;

    // Contract parameters (all values use 18-decimal BTCB units)
    uint256 constant WAD = 1e18;
    uint256 constant USD_PER_TOKEN = 1 * WAD; // Target $1 per MINB
    uint256 constant BTC_PRICE_USD = 90_000 * WAD; // $89k -> update before deploy if price changes
    uint256 constant BASE_COST = (USD_PER_TOKEN * WAD) / BTC_PRICE_USD; // Converts USD -> BTC
    uint256 constant DOUBLE_PRICE_AFTER = 1_000_000;
    uint256 constant GROWTH_RATE = BASE_COST / DOUBLE_PRICE_AFTER;
    uint256 constant AUTOMATION_FEE_PER_ROUND = 1e12; // 0.000001 BTCB (payment token) per execution
    uint256 constant MIN_DEPOSIT_PER_ALLOCATION = 1e10; // 0.00000001 BTCB minimum per square
    uint256 constant MAX_PARTICIPANTS_PER_ROUND = 500;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying contracts with address:", deployer);
        console.log("Deploying to BSC Testnet");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Token
        Token token = new Token();
        console.log("Token deployed at:", address(token));

        // 2. Deploy Vault
        Vault vault = new Vault(BTC_ADDRESS, address(token));
        console.log("Vault deployed at:", address(vault));

        // 3. Deploy Minter
        Minter minter = new Minter(
            BTC_ADDRESS,
            address(token),
            address(vault),
            BASE_COST,
            GROWTH_RATE
        );
        console.log("Minter deployed at:", address(minter));

        // 4. Deploy Airdrop
        Airdrop airdrop = new Airdrop(address(token), deployer);
        console.log("Airdrop deployed at:", address(airdrop));

        // 5. Deploy Referral
        Referral referral = new Referral(BTC_ADDRESS, address(token));
        console.log("Referral deployed at:", address(referral));

        // 6. Deploy BoardManager
        BoardManager boardManager = new BoardManager(
            BTC_ADDRESS,
            address(minter),
            address(vault),
            address(airdrop),
            address(referral),
            deployer,
            MIN_DEPOSIT_PER_ALLOCATION,
            MAX_PARTICIPANTS_PER_ROUND
        );
        console.log("BoardManager deployed at:", address(boardManager));

        // 7. Deploy Automation
        Automation automation = new Automation(
            BTC_ADDRESS,
            address(boardManager),
            AUTOMATION_FEE_PER_ROUND
        );
        console.log("Automation deployed at:", address(automation));

        // 8. Setup contract relationships
        token.setBurner(address(vault));
        token.transferOwnership(address(minter));
        vault.setMinter(address(minter));
        vault.setBoardContract(address(boardManager));
        minter.setBoardContract(address(boardManager));
        airdrop.setBoardManager(address(boardManager));
        referral.setBoardContract(address(boardManager));
        boardManager.setAutomation(address(automation));
        automation.setBoardManager(address(boardManager));

        // Optional: Set varSetter to deployer for automation (can be changed later)
        boardManager.setVarSetter(deployer);

        console.log("Contract setup completed!");
        console.log("Token:", address(token));
        console.log("Vault:", address(vault));
        console.log("Minter:", address(minter));
        console.log("Airdrop:", address(airdrop));
        console.log("Referral:", address(referral));
        console.log("BoardManager:", address(boardManager));
        console.log("Automation:", address(automation));

        vm.stopBroadcast();
    }
}
