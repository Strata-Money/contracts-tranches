// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title SwapContract
/// @notice A contract for performing swaps on Uniswap V4 pools via Universal Router
/// @dev Based on https://docs.uniswap.org/contracts/v4/quickstart/swap
contract SwapContract {
    using StateLibrary for IPoolManager;

    UniversalRouter public immutable router;
    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;

    constructor(address _router, address _poolManager, address _permit2) {
        router = UniversalRouter(payable(_router));
        poolManager = IPoolManager(_poolManager);
        permit2 = IPermit2(_permit2);
    }

    /// @notice Approve a token for use with Permit2 and the Universal Router
    /// @param token The token to approve
    /// @param amount The amount to approve
    /// @param expiration The expiration time for the approval
    function approveTokenWithPermit2(address token, uint160 amount, uint48 expiration) external {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(router), amount, expiration);
    }

    /// @notice Swap exact input tokens for output tokens (token0 -> token1)
    /// @param key The PoolKey identifying the Uniswap V4 pool
    /// @param amountIn Exact amount of input tokens to swap
    /// @param minAmountOut Minimum amount of output tokens (slippage protection)
    /// @param deadline Timestamp after which the transaction reverts
    /// @return amountOut The amount of output tokens received
    function swapExactInputSingle(PoolKey calldata key, uint128 amountIn, uint128 minAmountOut, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        router.execute(commands, inputs, deadline);

        // Verify and return the output amount
        amountOut = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }

    /// @notice Swap exact input tokens for output tokens with direction control
    /// @param key The PoolKey identifying the Uniswap V4 pool
    /// @param zeroForOne Direction: true = token0 -> token1, false = token1 -> token0
    /// @param amountIn Exact amount of input tokens to swap
    /// @param minAmountOut Minimum amount of output tokens (slippage protection)
    /// @param deadline Timestamp after which the transaction reverts
    /// @param hookData Arbitrary data passed to the pool's hook
    /// @return amountOut The amount of output tokens received
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 deadline,
        bytes calldata hookData
    ) external returns (uint256 amountOut) {
        // Determine input and output currencies based on swap direction
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: hookData
            })
        );
        params[1] = abi.encode(inputCurrency, amountIn);
        params[2] = abi.encode(outputCurrency, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        router.execute(commands, inputs, deadline);

        // Verify and return the output amount
        amountOut = IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }

    /// @notice Swap tokens to receive an exact amount of output tokens
    /// @param key The PoolKey identifying the Uniswap V4 pool
    /// @param zeroForOne Direction: true = token0 -> token1, false = token1 -> token0
    /// @param amountOut Exact amount of output tokens desired
    /// @param maxAmountIn Maximum amount of input tokens willing to spend (slippage protection)
    /// @param deadline Timestamp after which the transaction reverts
    /// @param hookData Arbitrary data passed to the pool's hook
    /// @return amountIn The amount of input tokens spent
    function swapExactOutput(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maxAmountIn,
        uint256 deadline,
        bytes calldata hookData
    ) external returns (uint256 amountIn) {
        // Determine input and output currencies based on swap direction
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: maxAmountIn,
                hookData: hookData
            })
        );
        params[1] = abi.encode(inputCurrency, maxAmountIn);
        params[2] = abi.encode(outputCurrency, amountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        router.execute(commands, inputs, deadline);

        // Calculate actual input amount spent
        uint256 inputBalance = IERC20(Currency.unwrap(inputCurrency)).balanceOf(address(this));
        amountIn = maxAmountIn - inputBalance;

        return amountIn;
    }
}
