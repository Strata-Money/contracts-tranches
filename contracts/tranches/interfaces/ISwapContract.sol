// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ISwapContract
/// @notice Interface for the SwapContract that performs swaps on Uniswap V4 pools
/// @dev Uses bytes for poolKey to avoid importing v4-core types which causes version conflicts
interface ISwapContract {
    /// @notice Swap exact input tokens for output tokens with direction control
    /// @param poolKeyData ABI-encoded PoolKey struct
    /// @param zeroForOne Direction: true = token0 -> token1, false = token1 -> token0
    /// @param amountIn Exact amount of input tokens to swap
    /// @param minAmountOut Minimum amount of output tokens (slippage protection)
    /// @param deadline Timestamp after which the transaction reverts
    /// @param hookData Arbitrary data passed to the pool's hook
    /// @return amountOut The amount of output tokens received
    function swapWithEncodedKey(
        bytes calldata poolKeyData,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 deadline,
        bytes calldata hookData
    ) external returns (uint256 amountOut);

    /// @notice Approve a token for use with Permit2 and the Universal Router
    /// @param token The token to approve
    /// @param amount The amount to approve
    /// @param expiration The expiration time for the approval
    function approveTokenWithPermit2(address token, uint160 amount, uint48 expiration) external;
}
