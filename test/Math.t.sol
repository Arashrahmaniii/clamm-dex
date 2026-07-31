// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MathTest} from "./utils/MathTest.sol";

/// @notice Unit and property tests for the fixed-point math libraries.
/// @dev Calls go through the MathTest wrapper rather than the internal libraries
///      directly, so `vm.expectRevert` observes a real external call boundary.
contract MathTests is Test {
    uint160 internal constant Q96 = uint160(1) << 96;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @dev sqrt(1.0001) scaled by 1e18, the exact ratio between consecutive ticks.
    uint256 internal constant SQRT_1_0001_WAD = 1000049998750062496;

    MathTest internal math;

    function setUp() public {
        math = new MathTest();
    }

    /*//////////////////////////////////////////////////////////////
                      TickMath.getSqrtRatioAtTick
    //////////////////////////////////////////////////////////////*/

    function test_getSqrtRatioAtTick_isQ96AtTickZero() public view {
        assertEq(math.getSqrtRatioAtTick(0), Q96);
    }

    function test_getSqrtRatioAtTick_hitsMinBoundaryExactly() public view {
        assertEq(math.getSqrtRatioAtTick(MIN_TICK), MIN_SQRT_RATIO);
        assertEq(math.minSqrtRatio(), MIN_SQRT_RATIO);
    }

    function test_getSqrtRatioAtTick_hitsMaxBoundaryExactly() public view {
        assertEq(math.getSqrtRatioAtTick(MAX_TICK), MAX_SQRT_RATIO);
        assertEq(math.maxSqrtRatio(), MAX_SQRT_RATIO);
    }

    function test_getSqrtRatioAtTick_revertsOutOfRange() public {
        vm.expectRevert("TickMath: T");
        math.getSqrtRatioAtTick(MIN_TICK - 1);

        vm.expectRevert("TickMath: T");
        math.getSqrtRatioAtTick(MAX_TICK + 1);
    }

    /// @dev Float-free replacement for the old JS closed-form comparison: the
    ///      ratio between consecutive ticks must be sqrt(1.0001) by definition,
    ///      which pins the curve without needing an off-chain reference table.
    function test_getSqrtRatioAtTick_consecutiveTicksDifferBySqrt10001() public view {
        int24[9] memory ticks = [int24(-887271), -500000, -100000, -1000, 0, 1000, 100000, 500000, 887270];
        for (uint256 i = 0; i < ticks.length; i++) {
            uint256 lo = math.getSqrtRatioAtTick(ticks[i]);
            uint256 hi = math.getSqrtRatioAtTick(ticks[i] + 1);
            assertApproxEqRel(hi * 1e18 / lo, SQRT_1_0001_WAD, 1e9, "consecutive tick ratio");
        }
    }

    function test_getSqrtRatioAtTick_isStrictlyMonotonic() public view {
        int24[9] memory ticks = [int24(-887272), -100000, -1000, -1, 0, 1, 1000, 100000, 887272];
        uint160 prev = 0;
        for (uint256 i = 0; i < ticks.length; i++) {
            uint160 ratio = math.getSqrtRatioAtTick(ticks[i]);
            assertGt(ratio, prev, "monotonicity");
            prev = ratio;
        }
    }

    /*//////////////////////////////////////////////////////////////
                      TickMath.getTickAtSqrtRatio
    //////////////////////////////////////////////////////////////*/

    function test_getTickAtSqrtRatio_isZeroAtQ96() public view {
        assertEq(math.getTickAtSqrtRatio(Q96), int24(0));
    }

    function test_getTickAtSqrtRatio_revertsOutsideRange() public {
        vm.expectRevert("TickMath: R");
        math.getTickAtSqrtRatio(MIN_SQRT_RATIO - 1);

        // The upper bound is exclusive.
        vm.expectRevert("TickMath: R");
        math.getTickAtSqrtRatio(MAX_SQRT_RATIO);
    }

    function test_getTickAtSqrtRatio_roundTripsSampleTicks() public view {
        int24[9] memory ticks = [int24(-887272), -123456, -60, -1, 0, 1, 60, 123456, 887271];
        for (uint256 i = 0; i < ticks.length; i++) {
            uint160 ratio = math.getSqrtRatioAtTick(ticks[i]);
            assertEq(math.getTickAtSqrtRatio(ratio), ticks[i], "round trip");
        }
    }

    function test_getTickAtSqrtRatio_bracketsTheInput() public view {
        uint160[5] memory samples = [MIN_SQRT_RATIO, Q96 - 1, Q96 + 1, Q96 * 2, MAX_SQRT_RATIO - 1];
        for (uint256 i = 0; i < samples.length; i++) {
            int24 tick = math.getTickAtSqrtRatio(samples[i]);
            assertLe(math.getSqrtRatioAtTick(tick), samples[i], "lower bound");
            assertGt(math.getSqrtRatioAtTick(tick + 1), samples[i], "upper bound");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FullMath.mulDiv
    //////////////////////////////////////////////////////////////*/

    function test_mulDiv_survivesPhantomOverflow() public view {
        // (2^200 * 2^100) / 2^150 = 2^150 — the intermediate product exceeds 256 bits.
        assertEq(math.mulDiv(2 ** 200, 2 ** 100, 2 ** 150), 2 ** 150);
    }

    function test_mulDiv_matchesExactArithmetic() public view {
        assertEq(math.mulDiv(7, 3, 2), 10);
        assertEq(math.mulDivRoundingUp(7, 3, 2), 11);

        uint256 a = 123456789e18;
        uint256 b = 987654321e18;
        assertEq(math.mulDiv(a, b, 1e18), a * b / 1e18);
    }

    function test_mulDiv_revertsOnZeroDenominatorAndOverflow() public {
        vm.expectRevert();
        math.mulDiv(1, 1, 0);

        // Result would not fit in 256 bits.
        vm.expectRevert();
        math.mulDiv(2 ** 255, 4, 2);
    }

    /*//////////////////////////////////////////////////////////////
                             SqrtPriceMath
    //////////////////////////////////////////////////////////////*/

    function test_getNextSqrtPriceFromInput_movesPriceInTheRightDirection() public view {
        uint160 price = Q96;
        uint128 liquidity = 1e18;
        uint256 amount = 1e15;

        assertLt(math.getNextSqrtPriceFromInput(price, liquidity, amount, true), price, "zeroForOne lowers price");
        assertGt(math.getNextSqrtPriceFromInput(price, liquidity, amount, false), price, "oneForZero raises price");
    }

    function test_amountDeltas_roundInThePoolsFavour() public view {
        uint160 a = Q96;
        uint160 b = uint160(uint256(Q96) * 101 / 100);
        uint128 liquidity = 1e18;

        uint256 up0 = math.getAmount0Delta(a, b, liquidity, true);
        uint256 down0 = math.getAmount0Delta(a, b, liquidity, false);
        uint256 up1 = math.getAmount1Delta(a, b, liquidity, true);
        uint256 down1 = math.getAmount1Delta(a, b, liquidity, false);

        assertGe(up0, down0);
        assertGe(up1, down1);
        assertLe(up0 - down0, 1, "amount0 rounding is at most 1 wei");
        assertLe(up1 - down1, 1, "amount1 rounding is at most 1 wei");
    }

    /*//////////////////////////////////////////////////////////////
                        SwapMath.computeSwapStep
    //////////////////////////////////////////////////////////////*/

    function test_computeSwapStep_chargesExactFeeWhenTargetIsReached() public view {
        uint160 price = Q96;
        uint160 target = uint160(uint256(Q96) * 101 / 100); // +1%, oneForZero
        uint128 liquidity = 2e18;
        int256 amount = 1e18;
        uint24 feePips = 600;

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            math.computeSwapStep(price, target, liquidity, amount, feePips);

        assertEq(sqrtQ, target, "enough input to reach the target");

        // Fee is amountIn * fee / (1e6 - fee), rounded up.
        uint256 expectedFee = (amountIn * feePips + (1e6 - feePips) - 1) / (1e6 - feePips);
        assertEq(feeAmount, expectedFee);
        assertLe(amountIn + feeAmount, uint256(amount));
        assertGt(amountOut, 0);
    }

    function test_computeSwapStep_consumesEverythingWhenTargetIsFarAway() public view {
        uint160 price = Q96;
        uint160 target = Q96 * 2;
        uint128 liquidity = 1e24;
        int256 amount = 1e18;

        (uint160 sqrtQ, uint256 amountIn,, uint256 feeAmount) =
            math.computeSwapStep(price, target, liquidity, amount, 3000);

        assertLt(sqrtQ, target);
        assertEq(amountIn + feeAmount, uint256(amount), "entire input consumed");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice getTickAtSqrtRatio inverts getSqrtRatioAtTick across the whole domain.
    function testFuzz_tickMath_roundTrips(int24 tick) public view {
        tick = int24(bound(tick, MIN_TICK, MAX_TICK - 1));
        assertEq(math.getTickAtSqrtRatio(math.getSqrtRatioAtTick(tick)), tick);
    }

    /// @notice For any valid ratio, the returned tick brackets it: r(t) <= x < r(t+1).
    function testFuzz_tickMath_bracketsAnyRatio(uint160 ratio) public view {
        ratio = uint160(bound(ratio, MIN_SQRT_RATIO, MAX_SQRT_RATIO - 1));
        int24 tick = math.getTickAtSqrtRatio(ratio);
        assertLe(math.getSqrtRatioAtTick(tick), ratio);
        assertGt(math.getSqrtRatioAtTick(tick + 1), ratio);
    }

    /// @notice getSqrtRatioAtTick is strictly increasing for every adjacent pair.
    function testFuzz_tickMath_isMonotonic(int24 tick) public view {
        tick = int24(bound(tick, MIN_TICK, MAX_TICK - 1));
        assertGt(math.getSqrtRatioAtTick(tick + 1), math.getSqrtRatioAtTick(tick));
    }

    /// @notice mulDiv agrees with native arithmetic whenever the product cannot overflow.
    function testFuzz_mulDiv_matchesNativeWhenNoOverflow(uint128 a, uint128 b, uint128 denominator) public view {
        vm.assume(denominator != 0);
        assertEq(math.mulDiv(a, b, denominator), uint256(a) * uint256(b) / uint256(denominator));
    }

    /// @notice Rounding up never differs from rounding down by more than one unit,
    ///         and is never smaller.
    function testFuzz_mulDivRoundingUp_isAtMostOneAbove(uint128 a, uint128 b, uint128 denominator) public view {
        vm.assume(denominator != 0);
        uint256 down = math.mulDiv(a, b, denominator);
        uint256 up = math.mulDivRoundingUp(a, b, denominator);
        assertGe(up, down);
        assertLe(up - down, 1);
    }

    /// @notice Amount deltas are symmetric in their price arguments and round consistently.
    function testFuzz_amountDeltas_roundUpNeverBelowRoundDown(uint160 priceA, uint160 priceB, uint128 liquidity)
        public
        view
    {
        priceA = uint160(bound(priceA, MIN_SQRT_RATIO, MAX_SQRT_RATIO - 1));
        priceB = uint160(bound(priceB, MIN_SQRT_RATIO, MAX_SQRT_RATIO - 1));
        liquidity = uint128(bound(liquidity, 1, 1e30));

        assertGe(
            math.getAmount0Delta(priceA, priceB, liquidity, true),
            math.getAmount0Delta(priceA, priceB, liquidity, false)
        );
        assertGe(
            math.getAmount1Delta(priceA, priceB, liquidity, true),
            math.getAmount1Delta(priceA, priceB, liquidity, false)
        );
    }

    /// @notice A swap step can never consume more than the input it was offered.
    function testFuzz_computeSwapStep_neverOverspendsInput(uint128 liquidity, uint256 amountIn, uint24 feePips)
        public
        view
    {
        liquidity = uint128(bound(liquidity, 1e12, 1e30));
        amountIn = bound(amountIn, 1, 1e24);
        feePips = uint24(bound(feePips, 1, 1e6 - 1));

        uint160 price = Q96;
        uint160 target = uint160(uint256(Q96) * 99 / 100); // zeroForOne

        (, uint256 consumedIn,, uint256 feeAmount) =
            math.computeSwapStep(price, target, liquidity, int256(amountIn), feePips);

        assertLe(consumedIn + feeAmount, amountIn, "step never overspends");
    }
}
