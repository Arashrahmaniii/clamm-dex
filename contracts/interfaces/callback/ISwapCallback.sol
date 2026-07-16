// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Callback for CLAMMPool#swap
/// @notice Any contract that calls CLAMMPool#swap must implement this interface.
interface ISwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via CLAMMPool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    ///      The caller of this method must be checked to be a CLAMMPool deployed by the canonical factory.
    ///      amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool.
    /// @param data Any data passed through by the caller via the swap call.
    function clammSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
