// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {MathTest} from "./utils/MathTest.sol";
import {ICLAMMPool} from "../contracts/interfaces/ICLAMMPool.sol";

/// @notice Core factory and pool behaviour: creation, initialization, minting,
///         swapping, fee accrual, burning and flash loans.
contract PoolTests is Base {
    function setUp() public {
        _deployPool();
        _fundAndApprove(_defaultUsers(), address(callee));
    }

    /// @dev Most tests start from a pool priced at 1.
    function _initialize() internal {
        pool.initialize(Q96);
    }

    /// @dev A pool priced at 1 with a single wide in-range position owned by `lp`.
    function _seedLiquidity() internal {
        _initialize();
        _mint(lp, LOWER, UPPER, LIQUIDITY);
    }

    /*//////////////////////////////////////////////////////////////
                                FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_factory_enablesCanonicalFeeTiers() public view {
        assertEq(factory.feeAmountTickSpacing(FEE_LOW), SPACING_LOW);
        assertEq(factory.feeAmountTickSpacing(FEE_MEDIUM), SPACING_MEDIUM);
        assertEq(factory.feeAmountTickSpacing(FEE_HIGH), SPACING_HIGH);
    }

    function test_factory_storesPoolUnderBothTokenOrderings() public view {
        assertEq(factory.getPool(address(token0), address(token1), FEE_MEDIUM), address(pool));
        assertEq(factory.getPool(address(token1), address(token0), FEE_MEDIUM), address(pool));
    }

    function test_factory_rejectsDuplicateIdenticalAndDisabledFees() public {
        vm.expectRevert("CLAMMFactory: POOL_EXISTS");
        factory.createPool(address(token0), address(token1), FEE_MEDIUM);

        vm.expectRevert("CLAMMFactory: SAME_TOKEN");
        factory.createPool(address(token0), address(token0), FEE_MEDIUM);

        vm.expectRevert("CLAMMFactory: FEE_NOT_ENABLED");
        factory.createPool(address(token0), address(token1), 1234);
    }

    function test_factory_restrictsFeeAndOwnershipChangesToOwner() public {
        vm.prank(other);
        vm.expectRevert("CLAMMFactory: NOT_OWNER");
        factory.enableFeeAmount(100, 1);

        vm.prank(other);
        vm.expectRevert("CLAMMFactory: NOT_OWNER");
        factory.setOwner(other);

        factory.enableFeeAmount(100, 1);
        assertEq(factory.feeAmountTickSpacing(100), int24(1));

        vm.expectRevert("CLAMMFactory: FEE_ALREADY_ENABLED");
        factory.enableFeeAmount(100, 2);
    }

    function test_factory_configuresPoolImmutables() public view {
        assertEq(pool.factory(), address(factory));
        assertEq(pool.token0(), address(token0));
        assertEq(pool.token1(), address(token1));
        assertEq(pool.fee(), FEE_MEDIUM);
        assertEq(pool.tickSpacing(), SPACING_MEDIUM);
        assertGt(pool.maxLiquidityPerTick(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsPriceAndTickOnce() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit ICLAMMPool.Initialize(Q96, 0);
        pool.initialize(Q96);

        (uint160 sqrtPriceX96, int24 tick,, bool unlocked) = pool.slot0();
        assertEq(sqrtPriceX96, Q96);
        assertEq(tick, int24(0));
        assertTrue(unlocked);

        vm.expectRevert("CLAMMPool: AI");
        pool.initialize(Q96);
    }

    function test_initialize_derivesTickFromNonUnityPrice() public {
        uint160 price = encodePriceSqrt(4, 1); // price 4 => tick ~ ln(4)/ln(1.0001) ~ 13862.94
        pool.initialize(price);

        int24 tick = _tick();
        MathTest math = new MathTest();
        assertLe(math.getSqrtRatioAtTick(tick), price, "ratio(tick) <= price");
        assertGt(math.getSqrtRatioAtTick(tick + 1), price, "price < ratio(tick+1)");
        assertTrue(tick == 13862 || tick == 13863, "tick near ln(4)/ln(1.0001)");
    }

    function test_initialize_lockBlocksActionsBeforeInitialization() public {
        vm.prank(lp);
        vm.expectRevert("CLAMMPool: LOK");
        callee.mint(address(pool), lp, LOWER, UPPER, LIQUIDITY);
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_takesBothTokensForAnInRangePosition() public {
        _initialize();

        uint256 bal0Before = token0.balanceOf(lp);
        uint256 bal1Before = token1.balanceOf(lp);
        _mint(lp, LOWER, UPPER, LIQUIDITY);
        uint256 paid0 = bal0Before - token0.balanceOf(lp);
        uint256 paid1 = bal1Before - token1.balanceOf(lp);

        // Symmetric range around price 1, so both legs cost the same.
        assertGt(paid0, 0);
        assertEq(paid0, paid1);
        assertEq(pool.liquidity(), LIQUIDITY);
        assertEq(_positionLiquidity(lp, LOWER, UPPER), LIQUIDITY);
    }

    function test_mint_takesOnlyOneTokenForOutOfRangePositions() public {
        _initialize();

        uint256 bal0 = token0.balanceOf(lp);
        uint256 bal1 = token1.balanceOf(lp);
        _mint(lp, 60, 120, LIQUIDITY); // entirely above the current price
        assertGt(bal0 - token0.balanceOf(lp), 0, "token0 only above range");
        assertEq(bal1 - token1.balanceOf(lp), 0);

        bal0 = token0.balanceOf(lp);
        bal1 = token1.balanceOf(lp);
        _mint(lp, -120, -60, LIQUIDITY); // entirely below the current price
        assertEq(bal0 - token0.balanceOf(lp), 0);
        assertGt(bal1 - token1.balanceOf(lp), 0, "token1 only below range");

        // Neither out-of-range position contributes active liquidity.
        assertEq(pool.liquidity(), 0);
    }

    function test_mint_rejectsInvalidRangesAndZeroLiquidity() public {
        _initialize();

        vm.startPrank(lp);

        vm.expectRevert("CLAMMPool: TLU");
        callee.mint(address(pool), lp, UPPER, LOWER, LIQUIDITY);

        vm.expectRevert("CLAMMPool: TLM");
        callee.mint(address(pool), lp, -887280, UPPER, LIQUIDITY);

        vm.expectRevert("CLAMMPool: TUM");
        callee.mint(address(pool), lp, LOWER, 887280, LIQUIDITY);

        vm.expectRevert("CLAMMPool: ZERO_LIQUIDITY");
        callee.mint(address(pool), lp, LOWER, UPPER, 0);

        vm.expectRevert("TickBitmap: TS");
        callee.mint(address(pool), lp, LOWER + 1, UPPER, LIQUIDITY);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAP
    //////////////////////////////////////////////////////////////*/

    function test_swap_exactInputZeroForOneMovesPriceDown() public {
        _seedLiquidity();
        uint256 amountIn = 1e15;

        uint256 bal0 = token0.balanceOf(trader);
        uint256 bal1 = token1.balanceOf(trader);
        _swap(trader, true, int256(amountIn));

        assertEq(bal0 - token0.balanceOf(trader), amountIn, "exact input spent");
        uint256 received = token1.balanceOf(trader) - bal1;
        assertGt(received, 0);
        assertLt(received, amountIn, "fee plus price impact at price 1");

        assertLt(_sqrtPrice(), Q96);
        assertLt(_tick(), int24(0));
    }

    function test_swap_exactOutputOneForZero() public {
        _seedLiquidity();
        uint256 amountOut = 1e15;

        uint256 bal0 = token0.balanceOf(trader);
        _swap(trader, false, -int256(amountOut));

        assertEq(token0.balanceOf(trader) - bal0, amountOut, "exact output received");
        assertGt(_sqrtPrice(), Q96);
    }

    function test_swap_stopsAtThePriceLimitAndPartiallyFills() public {
        _seedLiquidity();
        uint160 limit = uint160(uint256(Q96) * 999 / 1000); // allow only ~0.1% down

        vm.prank(trader);
        callee.swap(address(pool), trader, true, 1e21, limit);

        assertEq(_sqrtPrice(), limit, "price pinned to the limit");
    }

    function test_swap_crossesTickAndDeactivatesOutOfRangeLiquidity() public {
        _seedLiquidity();

        // A second, narrower position the price will exit.
        _mint(lp, -60, 60, LIQUIDITY);
        assertEq(pool.liquidity(), 2 * uint256(LIQUIDITY));

        _swap(trader, true, 1e16);

        assertLt(_tick(), int24(-60));
        assertEq(pool.liquidity(), LIQUIDITY, "only the wide position stays active");
    }

    function test_swap_rejectsBadPriceLimitAndZeroAmount() public {
        _seedLiquidity();

        vm.startPrank(trader);

        vm.expectRevert("CLAMMPool: SPL");
        callee.swap(address(pool), trader, true, 1000, 0);

        // A limit above the current price is invalid for zeroForOne.
        vm.expectRevert("CLAMMPool: SPL");
        callee.swap(address(pool), trader, true, 1000, Q96 + 1);

        vm.expectRevert("CLAMMPool: AS");
        callee.swap(address(pool), trader, true, 0, MIN_SQRT_RATIO + 1);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 FEES
    //////////////////////////////////////////////////////////////*/

    function test_fees_accrueToInRangeLpsAndAreCollectable() public {
        _seedLiquidity();
        uint256 amountIn = 1e16;

        _swap(trader, true, int256(amountIn));
        assertGt(pool.feeGrowthGlobal0X128(), 0);

        // Poke the position so fee accounting is written to storage.
        vm.prank(lp);
        pool.burn(LOWER, UPPER, 1);

        (uint128 owed0,) = _tokensOwed(lp, LOWER, UPPER);
        uint256 expectedFee = amountIn * 3000 / 1e6; // 0.30%
        assertGe(owed0, expectedFee * 99 / 100);
        assertLe(owed0, expectedFee + 1);

        uint256 balBefore = token0.balanceOf(lp);
        vm.prank(lp);
        pool.collect(lp, LOWER, UPPER, MAX_UINT128, 0);
        assertEq(token0.balanceOf(lp) - balBefore, owed0);
    }

    function test_fees_routeTheProtocolShareWhenEnabled() public {
        _seedLiquidity();
        pool.setFeeProtocol(4, 4); // 1/4 of swap fees to the protocol

        _swap(trader, true, 1e16);

        (uint128 fees0, uint128 fees1) = pool.protocolFees();
        assertGt(fees0, 0);
        assertEq(fees1, 0, "only the input token accrues protocol fees");

        // One wei per token stays behind to keep the storage slot warm.
        vm.expectEmit(true, true, false, true, address(pool));
        emit ICLAMMPool.CollectProtocol(address(this), address(this), fees0 - 1, 0);
        pool.collectProtocol(address(this), fees0, 0);
    }

    function test_fees_restrictProtocolConfigurationToOwnerAndValidValues() public {
        _seedLiquidity();

        vm.prank(other);
        vm.expectRevert("CLAMMPool: NOT_OWNER");
        pool.setFeeProtocol(4, 4);

        vm.prank(other);
        vm.expectRevert("CLAMMPool: NOT_OWNER");
        pool.collectProtocol(other, 1, 1);

        vm.expectRevert("CLAMMPool: FP");
        pool.setFeeProtocol(3, 4); // below the minimum denominator

        vm.expectRevert("CLAMMPool: FP");
        pool.setFeeProtocol(11, 4); // above the maximum denominator

        pool.setFeeProtocol(0, 10); // disabling and the maximum are both valid
    }

    /*//////////////////////////////////////////////////////////////
                            BURN & COLLECT
    //////////////////////////////////////////////////////////////*/

    function test_burn_returnsPrincipalMinusRounding() public {
        _initialize();

        uint256 bal0 = token0.balanceOf(lp);
        uint256 bal1 = token1.balanceOf(lp);
        _mint(lp, LOWER, UPPER, LIQUIDITY);
        uint256 paid0 = bal0 - token0.balanceOf(lp);
        uint256 paid1 = bal1 - token1.balanceOf(lp);

        vm.prank(lp);
        pool.burn(LOWER, UPPER, LIQUIDITY);

        assertEq(_positionLiquidity(lp, LOWER, UPPER), 0);

        (uint128 owed0, uint128 owed1) = _tokensOwed(lp, LOWER, UPPER);
        assertLe(paid0 - owed0, 1, "at most 1 wei retained in the pool's favour");
        assertLe(paid1 - owed1, 1, "at most 1 wei retained in the pool's favour");

        vm.prank(lp);
        pool.collect(lp, LOWER, UPPER, owed0, owed1);
        assertEq(pool.liquidity(), 0);
    }

    function test_burn_cannotExceedPositionLiquidity() public {
        _seedLiquidity();
        vm.prank(lp);
        vm.expectRevert();
        pool.burn(LOWER, UPPER, LIQUIDITY + 1);
    }

    function test_collect_capsAtAmountOwedAndPaysTheRecipient() public {
        _seedLiquidity();

        vm.prank(lp);
        pool.burn(LOWER, UPPER, LIQUIDITY / 2);
        (uint128 owed0,) = _tokensOwed(lp, LOWER, UPPER);

        uint256 balBefore = token0.balanceOf(other);
        vm.prank(lp);
        pool.collect(other, LOWER, UPPER, owed0 + 1e18, 0);
        assertEq(token0.balanceOf(other) - balBefore, owed0, "capped at what is owed");
    }

    /*//////////////////////////////////////////////////////////////
                                 FLASH
    //////////////////////////////////////////////////////////////*/

    function test_flash_lendsBothTokensAndTakesTheFee() public {
        _seedLiquidity();
        uint256 amount = 1e15;
        uint256 poolBal0Before = token0.balanceOf(address(pool));

        vm.prank(trader);
        vm.expectEmit(true, true, false, false, address(pool));
        emit ICLAMMPool.Flash(address(callee), address(callee), amount, amount, 0, 0);
        callee.flash(address(pool), address(callee), amount, amount);

        assertGt(token0.balanceOf(address(pool)), poolBal0Before, "pool ends richer by the fee");
        assertGt(pool.feeGrowthGlobal0X128(), 0);
        assertGt(pool.feeGrowthGlobal1X128(), 0);
    }

    function test_flash_revertsWithoutLiquidity() public {
        _initialize();
        vm.prank(trader);
        vm.expectRevert("CLAMMPool: L");
        callee.flash(address(pool), address(callee), 1000, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Minting then immediately burning the same liquidity returns the
    ///         principal up to at most 1 wei per token, always in the pool's favour.
    function testFuzz_mintBurn_roundTripLosesAtMostOneWei(uint128 liquidityAmount) public {
        liquidityAmount = uint128(bound(liquidityAmount, 1e6, 1e24));
        _initialize();

        uint256 bal0 = token0.balanceOf(lp);
        uint256 bal1 = token1.balanceOf(lp);
        _mint(lp, LOWER, UPPER, liquidityAmount);
        uint256 paid0 = bal0 - token0.balanceOf(lp);
        uint256 paid1 = bal1 - token1.balanceOf(lp);

        vm.prank(lp);
        pool.burn(LOWER, UPPER, liquidityAmount);
        (uint128 owed0, uint128 owed1) = _tokensOwed(lp, LOWER, UPPER);

        assertLe(owed0, paid0, "never returns more than was paid");
        assertLe(owed1, paid1, "never returns more than was paid");
        assertLe(paid0 - owed0, 1);
        assertLe(paid1 - owed1, 1);
    }

    /// @notice An exact-input swap always spends exactly the requested amount and
    ///         moves the price strictly in the expected direction.
    /// @dev The ceiling is deliberate. A [-600, 600] position holding 1e18 liquidity
    ///      only has ~3.06e16 of either token inside its range; beyond that the price
    ///      exits the range, liquidity hits zero and the swap partially fills, so
    ///      "spends exactly" would no longer hold. 1e15 keeps a wide safety margin.
    function testFuzz_swap_exactInputSpendsExactlyAndMovesPrice(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 1e15);
        _seedLiquidity();

        uint160 priceBefore = _sqrtPrice();
        uint256 balInBefore = zeroForOne ? token0.balanceOf(trader) : token1.balanceOf(trader);

        _swap(trader, zeroForOne, int256(amountIn));

        uint256 spent = balInBefore - (zeroForOne ? token0.balanceOf(trader) : token1.balanceOf(trader));
        assertEq(spent, amountIn, "exact input is fully spent");

        if (zeroForOne) {
            assertLt(_sqrtPrice(), priceBefore);
        } else {
            assertGt(_sqrtPrice(), priceBefore);
        }
    }

    /// @notice A swap never lets the price cross the caller's limit.
    function testFuzz_swap_respectsThePriceLimit(uint256 amountIn, uint256 limitPct) public {
        amountIn = bound(amountIn, 1e12, 1e21);
        limitPct = bound(limitPct, 900, 999); // 90%..99.9% of the current price
        _seedLiquidity();

        uint160 limit = uint160(uint256(Q96) * limitPct / 1000);

        vm.prank(trader);
        callee.swap(address(pool), trader, true, int256(amountIn), limit);

        assertGe(_sqrtPrice(), limit, "price never crosses the limit");
    }
}
