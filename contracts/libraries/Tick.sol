// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LiquidityMath} from "./LiquidityMath.sol";

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations.
library Tick {
    /// @notice Information stored for each initialized individual tick.
    struct Info {
        // The total position liquidity that references this tick.
        uint128 liquidityGross;
        // Amount of net liquidity added (subtracted) when tick is crossed from
        // left to right (right to left).
        int128 liquidityNet;
        // Fee growth per unit of liquidity on the _other_ side of this tick
        // (relative to the current tick). Only has relative meaning, not absolute.
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // True iff the tick is initialized, i.e. the value is exactly equivalent
        // to the expression liquidityGross != 0.
        bool initialized;
    }

    /// @notice Derives the maximum liquidity per tick from a given tick spacing.
    /// @param tickSpacing The amount of required tick separation, realized in
    ///        multiples of `tickSpacing`.
    /// @return The max liquidity per tick.
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        unchecked {
            int24 minTick = (-887272 / tickSpacing) * tickSpacing;
            int24 maxTick = (887272 / tickSpacing) * tickSpacing;
            uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
            return type(uint128).max / numTicks;
        }
    }

    /// @notice Retrieves fee growth data.
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tickLower The lower tick boundary of the position.
    /// @param tickUpper The upper tick boundary of the position.
    /// @param tickCurrent The current tick.
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0.
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1.
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries.
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries.
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        unchecked {
            Info storage lower = self[tickLower];
            Info storage upper = self[tickUpper];

            // Calculate fee growth below.
            uint256 feeGrowthBelow0X128;
            uint256 feeGrowthBelow1X128;
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
            } else {
                feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }

            // Calculate fee growth above.
            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
            } else {
                feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
            }

            feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }

    /// @notice Updates a tick and returns true if the tick was flipped from
    ///         initialized to uninitialized, or vice versa.
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tick The tick that will be updated.
    /// @param tickCurrent The current tick.
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted)
    ///        when tick is crossed from left to right (right to left).
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0.
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1.
    /// @param upper True for updating a position's upper tick, or false for updating a position's lower tick.
    /// @param maxLiquidity The maximum liquidity allocation for a single tick.
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa.
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        require(liquidityGrossAfter <= maxLiquidity, "Tick: LO");

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // By convention, we assume that all growth before a tick was
            // initialized happened _below_ the tick.
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        // When the lower (upper) tick is crossed left to right (right to left),
        // liquidity must be added (removed).
        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;
    }

    /// @notice Clears tick data.
    /// @param self The mapping containing all initialized tick information for initialized ticks.
    /// @param tick The tick that will be cleared.
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement.
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tick The destination tick of the transition.
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0.
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1.
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left).
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityNet) {
        unchecked {
            Tick.Info storage info = self[tick];
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
            liquidityNet = info.liquidityNet;
        }
    }
}
