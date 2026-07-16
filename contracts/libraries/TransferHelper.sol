// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TransferHelper
/// @notice Contains helper methods for interacting with ERC20 tokens that do not
///         consistently return true/false on transfers.
library TransferHelper {
    /// @notice Transfers tokens from `msg.sender` to a recipient.
    /// @dev Errors with the underlying revert reason if the transfer fails.
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FAILED");
    }

    /// @notice Transfers tokens from the targeted address to the given destination.
    /// @dev Errors with the underlying revert reason if the transfer fails.
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FROM_FAILED");
    }
}
