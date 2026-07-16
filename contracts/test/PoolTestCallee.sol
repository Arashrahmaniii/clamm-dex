// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLAMMPool} from "../interfaces/ICLAMMPool.sol";
import {IMintCallback} from "../interfaces/callback/IMintCallback.sol";
import {ISwapCallback} from "../interfaces/callback/ISwapCallback.sol";
import {IFlashCallback} from "../interfaces/callback/IFlashCallback.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

/// @title PoolTestCallee
/// @notice Test-only contract that fulfils the pool's callback obligations by
///         pulling tokens from the payer encoded in the callback data.
contract PoolTestCallee is IMintCallback, ISwapCallback, IFlashCallback {
    function mint(
        address pool,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1) {
        return ICLAMMPool(pool).mint(recipient, tickLower, tickUpper, amount, abi.encode(msg.sender));
    }

    function swap(
        address pool,
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external returns (int256 amount0, int256 amount1) {
        return ICLAMMPool(pool).swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, abi.encode(msg.sender));
    }

    function flash(address pool, address recipient, uint256 amount0, uint256 amount1) external {
        ICLAMMPool(pool).flash(recipient, amount0, amount1, abi.encode(msg.sender));
    }

    function clammMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        address payer = abi.decode(data, (address));
        if (amount0Owed > 0) {
            TransferHelper.safeTransferFrom(ICLAMMPool(msg.sender).token0(), payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            TransferHelper.safeTransferFrom(ICLAMMPool(msg.sender).token1(), payer, msg.sender, amount1Owed);
        }
    }

    function clammSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        address payer = abi.decode(data, (address));
        if (amount0Delta > 0) {
            TransferHelper.safeTransferFrom(ICLAMMPool(msg.sender).token0(), payer, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            TransferHelper.safeTransferFrom(ICLAMMPool(msg.sender).token1(), payer, msg.sender, uint256(amount1Delta));
        }
    }

    function clammFlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        address payer = abi.decode(data, (address));
        address token0 = ICLAMMPool(msg.sender).token0();
        address token1 = ICLAMMPool(msg.sender).token1();
        // Return everything the pool sent us plus the fees, pulling the fee from the payer.
        uint256 balance0 = IERC20Minimal(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(token1).balanceOf(address(this));
        if (balance0 > 0) TransferHelper.safeTransfer(token0, msg.sender, balance0);
        if (balance1 > 0) TransferHelper.safeTransfer(token1, msg.sender, balance1);
        if (fee0 > 0) TransferHelper.safeTransferFrom(token0, payer, msg.sender, fee0);
        if (fee1 > 0) TransferHelper.safeTransferFrom(token1, payer, msg.sender, fee1);
    }
}

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
}
