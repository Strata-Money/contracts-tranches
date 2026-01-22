// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice OFTAdapter uses a deployed ERC-20 token and SafeERC20 to interact with the OFTCore contract.
contract StrataOFTAdapter is OFTAdapter {
    constructor(address _token, address _lzEndpoint, address _owner)
        OFTAdapter(_token, _lzEndpoint, _owner)
        Ownable(_owner)
    {}
}

/// @notice OFT is an ERC-20 token that extends the OFTCore contract.
contract StrataOFT is OFT {
    constructor(string memory _name, string memory _symbol, address _lzEndpoint, address _owner)
        OFT(_name, _symbol, _lzEndpoint, _owner)
        Ownable(_owner)
    {}
}
