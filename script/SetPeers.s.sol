// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// @title LayerZero OFT Peer Configuration Script
/// @notice Uses the address book to get EIDs by chain name
contract SetPeers is Script {
    function run() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address oft = vm.envAddress("OFT_ADDRESS");

        // Remote OFT addresses (from deployment artifacts)
        address arbPeer = vm.envAddress("ARB_PEER");

        // Get EIDs from address book (no hardcoding)
        uint32 baseEid = ctx.getEidForChainName("basesep-testnet");
        uint32 arbEid = ctx.getEidForChainName("arbsep-testnet");

        vm.startBroadcast();

        // Set peers using address book EIDs
        // OFT(oft).setPeer(baseEid, bytes32(uint256(uint160(basePeer))));
        OFT(oft).setPeer(arbEid, bytes32(uint256(uint160(arbPeer))));

        vm.stopBroadcast();

        console.log("Set peer for Base EID:", baseEid);
        console.log("Set peer for Arbitrum EID:", arbEid);
    }
}

