// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SafeCast
/// @notice Contains methods for safely casting between types used throughout
///         the concentrated-liquidity contracts.
library SafeCast {
    /// @notice Cast a uint256 to a uint160, reverting on overflow.
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y, "SafeCast: uint160 overflow");
    }

    /// @notice Cast a uint256 to a uint128, reverting on overflow.
    function toUint128(uint256 y) internal pure returns (uint128 z) {
        require((z = uint128(y)) == y, "SafeCast: uint128 overflow");
    }

    /// @notice Cast a int256 to a int128, reverting on overflow or underflow.
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y, "SafeCast: int128 overflow");
    }

    /// @notice Cast a uint256 to a int256, reverting on overflow.
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y < 2 ** 255, "SafeCast: int256 overflow");
        z = int256(y);
    }

    /// @notice Cast a int256 to a uint256, reverting on underflow.
    function toUint256(int256 y) internal pure returns (uint256 z) {
        require(y >= 0, "SafeCast: uint256 underflow");
        z = uint256(y);
    }
}
