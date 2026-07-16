// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FixedPoint128
/// @notice A library for handling binary fixed-point numbers, see
///         https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used for the Q128.128 fee-growth accumulators.
library FixedPoint128 {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000; // 2**128
}
