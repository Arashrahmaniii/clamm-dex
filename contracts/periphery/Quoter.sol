// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLAMMFactory} from "../interfaces/ICLAMMFactory.sol";
import {ICLAMMPool} from "../interfaces/ICLAMMPool.sol";
import {ISwapCallback} from "../interfaces/callback/ISwapCallback.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title Quoter
/// @notice Provides swap quotes without executing the swap. Runs the real swap
///         against the pool and then reverts from the callback with the result
///         encoded, so pool state is never modified.
/// @dev The quote functions are not marked view because they rely on calling
///      non-view pool functions and catching the revert; use them with
///      `callStatic`/`eth_call` off-chain.
contract Quoter is ISwapCallback {
    using SafeCast for uint256;

    /// @notice The factory whose pools this quoter reads from.
    ICLAMMFactory public immutable factory;

    constructor(address _factory) {
        factory = ICLAMMFactory(_factory);
    }

    /// @dev Data passed through the pool's swap callback for verification.
    struct QuoteCallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
    }

    /// @dev Returns the verified pool for the given token pair and fee; reverts if it does not exist.
    function _getPool(address tokenA, address tokenB, uint24 fee) private view returns (ICLAMMPool pool) {
        address poolAddress = factory.getPool(tokenA, tokenB, fee);
        require(poolAddress != address(0), "Quoter: POOL_NOT_FOUND");
        pool = ICLAMMPool(poolAddress);
    }

    /// @inheritdoc ISwapCallback
    function clammSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external view override {
        require(amount0Delta > 0 || amount1Delta > 0, "Quoter: ZERO_SWAP");
        QuoteCallbackData memory decoded = abi.decode(data, (QuoteCallbackData));
        require(
            msg.sender == address(_getPool(decoded.tokenIn, decoded.tokenOut, decoded.fee)), "Quoter: INVALID_CALLBACK"
        );

        bool zeroForOne = decoded.tokenIn < decoded.tokenOut;
        (uint256 amountIn, uint256 amountOut) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));

        // Abort the swap by reverting with both amounts, caught by _quote below.
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountIn)
            mstore(add(ptr, 32), amountOut)
            revert(ptr, 64)
        }
    }

    /// @dev Executes the swap and decodes (amountIn, amountOut) out of the
    ///      callback's intentional revert.
    function _quote(address tokenIn, address tokenOut, uint24 fee, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        bool zeroForOne = tokenIn < tokenOut;
        ICLAMMPool pool = _getPool(tokenIn, tokenOut, fee);

        try pool.swap(
            address(this),
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96,
            abi.encode(QuoteCallbackData({tokenIn: tokenIn, tokenOut: tokenOut, fee: fee}))
        ) {
            // The callback always reverts; reaching here means it never ran.
            revert("Quoter: NO_CALLBACK");
        } catch (bytes memory reason) {
            if (reason.length != 64) {
                // Bubble up genuine errors (e.g. SPL, uninitialized pool).
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            return abi.decode(reason, (uint256, uint256));
        }
    }

    /// @notice Returns the output amount for an exact-input single-pool swap.
    /// @param tokenIn The token being swapped in.
    /// @param tokenOut The token being swapped out.
    /// @param fee The fee tier of the pool.
    /// @param amountIn The exact input amount.
    /// @param sqrtPriceLimitX96 The price limit, or 0 for the loosest acceptable limit.
    /// @return amountOut The amount of `tokenOut` the swap would return.
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut) {
        (, amountOut) = _quote(tokenIn, tokenOut, fee, amountIn.toInt256(), sqrtPriceLimitX96);
    }

    /// @notice Returns the input amount required for an exact-output single-pool swap.
    /// @param tokenIn The token being swapped in.
    /// @param tokenOut The token being swapped out.
    /// @param fee The fee tier of the pool.
    /// @param amountOut The exact output amount desired.
    /// @param sqrtPriceLimitX96 The price limit, or 0 for the loosest acceptable limit.
    /// @return amountIn The amount of `tokenIn` the swap would cost.
    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn) {
        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = _quote(tokenIn, tokenOut, fee, -amountOut.toInt256(), sqrtPriceLimitX96);
        // With no explicit price limit the full requested output must be available.
        if (sqrtPriceLimitX96 == 0) {
            require(amountOutReceived == amountOut, "Quoter: INCOMPLETE_OUTPUT");
        }
    }
}
