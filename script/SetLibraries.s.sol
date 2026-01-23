// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title LayerZero Library Configuration Script
/// @notice Sets up send and receive libraries using the address book
contract SetLibraries is Script {
    function run() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        // Get local protocol addresses from address book
        address endpoint = ctx.getEndpointV2();
        address sendLib = ctx.getSendUln302();
        address receiveLib = ctx.getReceiveUln302();

        // Get remote chain EID
        uint32 remoteEid = ctx.getEidForChainName("basesep-testnet");

        // Your OFT address (from deployment)
        address oft = vm.envAddress("OFT_ADDRESS");

        vm.startBroadcast();

        // Set send library for outbound messages
        ILayerZeroEndpointV2(endpoint).setSendLibrary(oft, remoteEid, sendLib);

        // Set receive library for inbound messages
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(oft, remoteEid, receiveLib, 0);

        vm.stopBroadcast();

        console.log("Configured libraries for OFT:", oft);
        console.log("Remote EID:", remoteEid);
    }
}

