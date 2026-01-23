// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";
import {StrataOFT} from "../contracts/oapp/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

// forge script script/SendOFT.s.sol --rpc-url base_sepolia --private-key $PK
contract SendOFT is Script {
    using OptionsBuilder for bytes;

    function run() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid); // Auto-detect from RPC

        address oftAddress = vm.envAddress("OFT_ADDRESS");
        address toAddress = vm.envAddress("TO_ADDRESS");
        uint256 tokensToSend = vm.envUint("TOKENS_TO_SEND");

        // Get destination EID from address book
        uint32 dstEid = ctx.getEidForChainName("base-mainnet");

        StrataOFT oft = StrataOFT(oftAddress);

        // Build send parameters
        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(toAddress))),
            amountLD: tokensToSend,
            minAmountLD: tokensToSend * 95 / 100, // 5% slippage tolerance
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        // Get fee quote
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        console.log("Destination EID:", dstEid);
        console.log("Fee amount:", fee.nativeFee);

        vm.startBroadcast();
        oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);
        vm.stopBroadcast();

        console.log("Tokens sent!");
    }
}

