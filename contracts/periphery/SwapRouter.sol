// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLAMMFactory} from "../interfaces/ICLAMMFactory.sol";
import {ICLAMMPool} from "../interfaces/ICLAMMPool.sol";
import {ISwapCallback} from "../interfaces/callback/ISwapCallback.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {Multicall} from "./base/Multicall.sol";

/// @title SwapRouter
/// @notice Router for stateless execution of swaps against CLAMM pools, with
///         deadline and slippage protection.
contract SwapRouter is ISwapCallback, Multicall {
    using SafeCast for uint256;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        // Pass 0 to use the loosest acceptable limit for the swap direction.
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev Data passed through the pool's swap callback.
    struct SwapCallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address payer;
    }

    /// @notice The factory whose pools this router swaps against.
    ICLAMMFactory public immutable factory;

    constructor(address _factory) {
        factory = ICLAMMFactory(_factory);
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "SwapRouter: DEADLINE_EXPIRED");
        _;
    }

    /// @dev Returns the verified pool for the given token pair and fee; reverts if it does not exist.
    function _getPool(address tokenA, address tokenB, uint24 fee) private view returns (ICLAMMPool pool) {
        address poolAddress = factory.getPool(tokenA, tokenB, fee);
        require(poolAddress != address(0), "SwapRouter: POOL_NOT_FOUND");
        pool = ICLAMMPool(poolAddress);
    }

    /// @inheritdoc ISwapCallback
    function clammSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Swaps entirely within 0-liquidity regions are not supported.
        require(amount0Delta > 0 || amount1Delta > 0, "SwapRouter: ZERO_SWAP");
        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));

        // Only the canonical pool for this token pair + fee may invoke the callback.
        require(
            msg.sender == address(_getPool(decoded.tokenIn, decoded.tokenOut, decoded.fee)),
            "SwapRouter: INVALID_CALLBACK"
        );

        // Exactly one delta is positive: that's the amount the pool must be paid.
        (address tokenToPay, uint256 amountToPay) = amount0Delta > 0
            ? (decoded.tokenIn < decoded.tokenOut ? decoded.tokenIn : decoded.tokenOut, uint256(amount0Delta))
            : (decoded.tokenIn < decoded.tokenOut ? decoded.tokenOut : decoded.tokenIn, uint256(amount1Delta));
        require(tokenToPay == decoded.tokenIn, "SwapRouter: BAD_DELTA");

        TransferHelper.safeTransferFrom(decoded.tokenIn, decoded.payer, msg.sender, amountToPay);
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata.
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        ICLAMMPool pool = _getPool(params.tokenIn, params.tokenOut, params.fee);

        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            params.amountIn.toInt256(),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(
                SwapCallbackData({
                    tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender
                })
            )
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= params.amountOutMinimum, "SwapRouter: TOO_LITTLE_RECEIVED");
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token.
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata.
    /// @return amountIn The amount of the input token spent.
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        ICLAMMPool pool = _getPool(params.tokenIn, params.tokenOut, params.fee);

        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            -params.amountOut.toInt256(),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(
                SwapCallbackData({
                    tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender
                })
            )
        );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) =
            zeroForOne ? (uint256(amount0), uint256(-amount1)) : (uint256(amount1), uint256(-amount0));

        // If the price limit was not hit, the full output must have been received.
        if (params.sqrtPriceLimitX96 == 0) {
            require(amountOutReceived == params.amountOut, "SwapRouter: INCOMPLETE_OUTPUT");
        }
        require(amountIn <= params.amountInMaximum, "SwapRouter: TOO_MUCH_REQUESTED");
    }
}
