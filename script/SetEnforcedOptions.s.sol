// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

/// @title LayerZero OFT Enforced Options Configuration Script
/// @notice Uses the address book to get destination EIDs
contract SetEnforcedOptions is Script {
    using OptionsBuilder for bytes;

    function run() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address oft = vm.envAddress("OFT_ADDRESS");

        // Get destination EIDs from address book
        uint32 baseEid = ctx.getEidForChainName("basesep-testnet");
        uint32 arbEid = ctx.getEidForChainName("arbsep-testnet");

        // Message type for OFT send
        uint16 SEND = 1;

        // Build options using OptionsBuilder
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);

        // Create enforced options array
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({eid: baseEid, msgType: SEND, options: options});
        enforcedOptions[1] = EnforcedOptionParam({eid: arbEid, msgType: SEND, options: options});

        vm.startBroadcast();

        OFT(oft).setEnforcedOptions(enforcedOptions);

        vm.stopBroadcast();

        console.log("Enforced options set for Base EID:", baseEid);
        console.log("Enforced options set for Arbitrum EID:", arbEid);
    }
}

