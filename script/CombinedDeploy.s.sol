// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";
import {StrataOFT} from "../contracts/oapp/OFT.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title CombinedDeploy
 * @notice Combined script for deploying OFT on Base Sepolia and Arbitrum Sepolia
 * @dev Execution order: Deploy -> SetLibraries -> SetPeers -> EnforceOptions -> Send
 *
 * Usage:
 * 1. Deploy on Base Sepolia:
 *    forge script script/CombinedDeploy.s.sol:CombinedDeploy --sig "deployOnBase()" --rpc-url base_sepolia --broadcast
 *
 * 2. Deploy on Arbitrum Sepolia:
 *    forge script script/CombinedDeploy.s.sol:CombinedDeploy --sig "deployOnArbitrum()" --rpc-url arbitrum_sepolia --broadcast
 *
 * 3. Setup Base (after both deployments):
 *    OFT_ADDRESS=<base_oft> ARB_PEER=<arb_oft> forge script script/CombinedDeploy.s.sol:CombinedDeploy --sig "setupBase()" --rpc-url base_sepolia --broadcast
 *
 * 4. Setup Arbitrum (after both deployments):
 *    OFT_ADDRESS=<arb_oft> BASE_PEER=<base_oft> forge script script/CombinedDeploy.s.sol:CombinedDeploy --sig "setupArbitrum()" --rpc-url arbitrum_sepolia --broadcast
 *
 * 5. Send tokens from Base to Arbitrum:
 *    OFT_ADDRESS=<base_oft> TO_ADDRESS=<recipient> TOKENS_TO_SEND=<amount> forge script script/CombinedDeploy.s.sol:CombinedDeploy --sig "sendFromBase()" --rpc-url base_sepolia --broadcast
 *
 * 6. Send tokens from Arbitrum to Base:
 *    OFT_ADDRESS=<arb_oft> TO_ADDRESS=<recipient> TOKENS_TO_SEND=<amount> forge script script/CombinedDeploy.s.sol:CombinedDeploy --sig "sendFromArbitrum()" --rpc-url arbitrum_sepolia --broadcast
 */
contract CombinedDeploy is Script {
    using OptionsBuilder for bytes;

    // Token configuration
    string constant TOKEN_NAME = "Strata Token";
    string constant TOKEN_SYMBOL = "STRATA";
    uint256 constant INITIAL_MINT = 1_000_000 * 1e18; // 1 million tokens

    // Message type for OFT send
    uint16 constant SEND = 1;

    /**
     * @notice Deploy OFT on Base Sepolia
     * @dev Deploys the OFT contract and mints initial tokens to deployer
     */
    function deployOnBase() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address endpoint = ctx.getEndpointV2();
        address owner = msg.sender;

        vm.startBroadcast();

        // Deploy OFT
        StrataOFT oft = new StrataOFT(TOKEN_NAME, TOKEN_SYMBOL, endpoint, owner);

        // Mint initial tokens to deployer
        oft.mint(owner, INITIAL_MINT);

        vm.stopBroadcast();

        console.log("=== BASE SEPOLIA DEPLOYMENT ===");
        console.log("OFT deployed to:", address(oft));
        console.log("Chain:", ctx.getCurrentChainName());
        console.log("Endpoint:", endpoint);
        console.log("Owner:", owner);
        console.log("Initial mint:", INITIAL_MINT);
        console.log("");
        console.log("Save this address as OFT_ADDRESS for Base setup");
    }

    /**
     * @notice Deploy OFT on Arbitrum Sepolia
     * @dev Deploys the OFT contract and mints initial tokens to deployer
     */
    function deployOnArbitrum() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address endpoint = ctx.getEndpointV2();
        address owner = msg.sender;

        vm.startBroadcast();

        // Deploy OFT
        StrataOFT oft = new StrataOFT(TOKEN_NAME, TOKEN_SYMBOL, endpoint, owner);

        // Mint initial tokens to deployer
        oft.mint(owner, INITIAL_MINT);

        vm.stopBroadcast();

        console.log("=== ARBITRUM SEPOLIA DEPLOYMENT ===");
        console.log("OFT deployed to:", address(oft));
        console.log("Chain:", ctx.getCurrentChainName());
        console.log("Endpoint:", endpoint);
        console.log("Owner:", owner);
        console.log("Initial mint:", INITIAL_MINT);
        console.log("");
        console.log("Save this address as OFT_ADDRESS for Arbitrum setup");
    }

    /**
     * @notice Setup Base Sepolia OFT (SetLibraries -> SetPeers -> EnforceOptions)
     * @dev Requires: OFT_ADDRESS (Base OFT), ARB_PEER (Arbitrum OFT)
     */
    function setupBase() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address oftAddress = vm.envAddress("OFT_ADDRESS");
        address arbPeer = vm.envAddress("ARB_PEER");

        // Get protocol addresses
        address endpoint = ctx.getEndpointV2();
        address sendLib = ctx.getSendUln302();
        address receiveLib = ctx.getReceiveUln302();

        // Get remote EID
        uint32 arbEid = ctx.getEidForChainName("arbsep-testnet");

        vm.startBroadcast();

        // 1. Set Libraries
        ILayerZeroEndpointV2(endpoint).setSendLibrary(oftAddress, arbEid, sendLib);
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(oftAddress, arbEid, receiveLib, 0);

        // 2. Set Peer
        OFT(oftAddress).setPeer(arbEid, bytes32(uint256(uint160(arbPeer))));

        // 3. Enforce Options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](1);
        enforcedOptions[0] = EnforcedOptionParam({eid: arbEid, msgType: SEND, options: options});
        OFT(oftAddress).setEnforcedOptions(enforcedOptions);

        vm.stopBroadcast();

        console.log("=== BASE SEPOLIA SETUP COMPLETE ===");
        console.log("OFT Address:", oftAddress);
        console.log("Arbitrum Peer:", arbPeer);
        console.log("Arbitrum EID:", arbEid);
        console.log("Libraries configured");
        console.log("Peer set");
        console.log("Options enforced");
    }

    /**
     * @notice Setup Arbitrum Sepolia OFT (SetLibraries -> SetPeers -> EnforceOptions)
     * @dev Requires: OFT_ADDRESS (Arbitrum OFT), BASE_PEER (Base OFT)
     */
    function setupArbitrum() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address oftAddress = vm.envAddress("OFT_ADDRESS");
        address basePeer = vm.envAddress("BASE_PEER");

        // Get protocol addresses
        address endpoint = ctx.getEndpointV2();
        address sendLib = ctx.getSendUln302();
        address receiveLib = ctx.getReceiveUln302();

        // Get remote EID
        uint32 baseEid = ctx.getEidForChainName("basesep-testnet");

        vm.startBroadcast();

        // 1. Set Libraries
        ILayerZeroEndpointV2(endpoint).setSendLibrary(oftAddress, baseEid, sendLib);
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(oftAddress, baseEid, receiveLib, 0);

        // 2. Set Peer
        OFT(oftAddress).setPeer(baseEid, bytes32(uint256(uint160(basePeer))));

        // 3. Enforce Options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](1);
        enforcedOptions[0] = EnforcedOptionParam({eid: baseEid, msgType: SEND, options: options});
        OFT(oftAddress).setEnforcedOptions(enforcedOptions);

        vm.stopBroadcast();

        console.log("=== ARBITRUM SEPOLIA SETUP COMPLETE ===");
        console.log("OFT Address:", oftAddress);
        console.log("Base Peer:", basePeer);
        console.log("Base EID:", baseEid);
        console.log("Libraries configured");
        console.log("Peer set");
        console.log("Options enforced");
    }

    /**
     * @notice Send tokens from Base to Arbitrum
     * @dev Requires: OFT_ADDRESS, TO_ADDRESS, TOKENS_TO_SEND
     */
    function sendFromBase() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address oftAddress = vm.envAddress("OFT_ADDRESS");
        address toAddress = vm.envAddress("TO_ADDRESS");
        uint256 tokensToSend = vm.envUint("TOKENS_TO_SEND");

        // Get destination EID
        uint32 arbEid = ctx.getEidForChainName("arbsep-testnet");

        StrataOFT oft = StrataOFT(oftAddress);

        // Build send parameters
        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        SendParam memory sendParam = SendParam({
            dstEid: arbEid,
            to: bytes32(uint256(uint160(toAddress))),
            amountLD: tokensToSend,
            minAmountLD: tokensToSend * 95 / 100, // 5% slippage tolerance
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        // Get fee quote
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        console.log("=== SENDING FROM BASE TO ARBITRUM ===");
        console.log("From OFT:", oftAddress);
        console.log("To Address:", toAddress);
        console.log("Amount:", tokensToSend);
        console.log("Destination EID:", arbEid);
        console.log("Fee (native):", fee.nativeFee);

        vm.startBroadcast();
        oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);
        vm.stopBroadcast();

        console.log("Tokens sent successfully!");
    }

    /**
     * @notice Send tokens from Arbitrum to Base
     * @dev Requires: OFT_ADDRESS, TO_ADDRESS, TOKENS_TO_SEND
     */
    function sendFromArbitrum() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid);

        address oftAddress = vm.envAddress("OFT_ADDRESS");
        address toAddress = vm.envAddress("TO_ADDRESS");
        uint256 tokensToSend = vm.envUint("TOKENS_TO_SEND");

        // Get destination EID
        uint32 baseEid = ctx.getEidForChainName("basesep-testnet");

        StrataOFT oft = StrataOFT(oftAddress);

        // Build send parameters
        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        SendParam memory sendParam = SendParam({
            dstEid: baseEid,
            to: bytes32(uint256(uint160(toAddress))),
            amountLD: tokensToSend,
            minAmountLD: tokensToSend * 95 / 100, // 5% slippage tolerance
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        // Get fee quote
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        console.log("=== SENDING FROM ARBITRUM TO BASE ===");
        console.log("From OFT:", oftAddress);
        console.log("To Address:", toAddress);
        console.log("Amount:", tokensToSend);
        console.log("Destination EID:", baseEid);
        console.log("Fee (native):", fee.nativeFee);

        vm.startBroadcast();
        oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);
        vm.stopBroadcast();

        console.log("Tokens sent successfully!");
    }
}
