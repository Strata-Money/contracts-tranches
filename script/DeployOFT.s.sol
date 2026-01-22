// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {LZAddressContext} from "lz-address-book/helpers/LZAddressContext.sol";
import {StrataOFT} from "../contracts/oapp/OFT.sol";

// forge script script/DeployOFT.s.sol --rpc-url base_sepolia --private-key $PK
contract DeployOFT is Script {
    function run() external {
        LZAddressContext ctx = new LZAddressContext();
        ctx.setChainByChainId(block.chainid); // Auto-detect from RPC

        address endpoint = ctx.getEndpointV2();
        address owner = msg.sender;

        vm.startBroadcast();
        StrataOFT oft = new StrataOFT("My Token", "MTK", endpoint, owner);
        vm.stopBroadcast();

        console.log("MyOFT deployed to:", address(oft));
        console.log("Chain:", ctx.getCurrentChainName());
        console.log("Endpoint:", endpoint);
    }
}
