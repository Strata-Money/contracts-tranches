// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";
import {StrataOFT} from "../contracts/oapp/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title SendOFT
 * @notice Standalone script for sending OFT tokens cross-chain
 * @dev Can be used to send tokens from any chain to any configured peer
 * 
 * Usage:
 * Send from Base to Arbitrum:
 *   OFT_ADDRESS=<base_oft> TO_ADDRESS=<recipient> TOKENS_TO_SEND=<amount> DST_CHAIN=arbsep-testnet \
 *   forge script script/Send.s.sol:SendOFT --rpc-url base_sepolia --broadcast
 * 
 * Send from Arbitrum to Base:
 *   OFT_ADDRESS=<arb_oft> TO_ADDRESS=<recipient> TOKENS_TO_SEND=<amount> DST_CHAIN=basesep-testnet \
 *   forge script script/Send.s.sol:SendOFT --rpc-url arbitrum_sepolia --broadcast
 */
contract SendOFT is Script {
    using OptionsBuilder for bytes;

    function run() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        // Read environment variables
        address oftAddress = vm.envAddress("OFT_ADDRESS");
        address toAddress = vm.envAddress("TO_ADDRESS");
        uint256 tokensToSend = vm.envUint("TOKENS_TO_SEND");
        string memory dstChainName = vm.envString("DST_CHAIN");

        // Get destination EID from address book
        uint32 dstEid = ctx.getEidForChainName(dstChainName);

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

        console.log("=== SENDING OFT TOKENS ===");
        console.log("From Chain:", ctx.getCurrentChainName());
        console.log("From OFT:", oftAddress);
        console.log("To Chain:", dstChainName);
        console.log("To Address:", toAddress);
        console.log("Amount:", tokensToSend);
        console.log("Destination EID:", dstEid);
        console.log("Fee (native):", fee.nativeFee);

        vm.startBroadcast();
        oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);
        vm.stopBroadcast();

        console.log("Tokens sent successfully!");
    }
}
