// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Callback for CLAMMPool#flash
/// @notice Any contract that calls CLAMMPool#flash must implement this interface.
interface IFlashCallback {
    /// @notice Called to `msg.sender` after transferring tokens to the recipient from CLAMMPool#flash.
    /// @dev In the implementation you must repay the pool the tokens sent by flash plus the computed fee amounts.
    ///      The caller of this method must be checked to be a CLAMMPool deployed by the canonical factory.
    /// @param fee0 The fee amount in token0 due to the pool by the end of the flash.
    /// @param fee1 The fee amount in token1 due to the pool by the end of the flash.
    /// @param data Any data passed through by the caller via the flash call.
    function clammFlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}
