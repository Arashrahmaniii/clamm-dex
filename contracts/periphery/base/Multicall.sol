// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Multicall
/// @notice Enables calling multiple methods of the inheriting contract in a
///         single transaction, e.g. creating + initializing a pool and minting
///         a position atomically.
abstract contract Multicall {
    /// @notice Call multiple functions of this contract and return their results.
    /// @dev Reverts (bubbling the inner revert data) if any sub-call fails, so
    ///      the batch is all-or-nothing.
    /// @param data The encoded function calls to make.
    /// @return results The encoded return data of each call, in order.
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                // Bubble up the revert data of the failing call unchanged.
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
