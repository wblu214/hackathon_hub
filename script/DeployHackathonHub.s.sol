// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/HackathonHub.sol";

/// @notice Foundry deployment script for ZetaChain EVM testnet (or any EVM chain).
/// @dev Usage:
///      - export PRIVATE_KEY=0x...
///      - export PLATFORM_OWNER=0xYourTreasuryAddress
///      - forge script script/DeployHackathonHub.s.sol \
///          --rpc-url $ZETA_RPC_URL --broadcast --verify --slow
contract DeployHackathonHubScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address platformOwner = vm.envAddress("PLATFORM_OWNER");

        // Example parameters for testnet; adjust to your token economics.
        uint256 listingFee = 0.0035 ether; // "3.5 U" equivalent in native token units (for demo)
        uint256 likeStakeAmount = 0.001 ether; // "1 U" equivalent (min stake to like)
        uint256 platformFeeBps = 500; // 5% platform fee on tips

        vm.startBroadcast(deployerPrivateKey);

        HackathonHub hub = new HackathonHub(
            platformOwner,
            listingFee,
            likeStakeAmount,
            platformFeeBps
        );

        vm.stopBroadcast();

        console2.log("HackathonHub deployed at:", address(hub));
    }
}

