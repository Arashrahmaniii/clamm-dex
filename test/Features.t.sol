// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {ICLAMMPool} from "../contracts/interfaces/ICLAMMPool.sol";
import {NonfungiblePositionManager} from "../contracts/periphery/NonfungiblePositionManager.sol";
import {SwapRouter} from "../contracts/periphery/SwapRouter.sol";
import {Quoter} from "../contracts/periphery/Quoter.sol";
import {TestERC20} from "./utils/TestERC20.sol";

/// @notice The TWAP oracle, the revert-and-catch quoter, and multicall batching.
contract FeatureTests is Base {
    NonfungiblePositionManager internal npm;
    SwapRouter internal router;
    Quoter internal quoter;

    uint256 internal constant DESIRED = 1e18;

    function setUp() public {
        _deployPool();
        pool.initialize(Q96);

        npm = new NonfungiblePositionManager(address(factory));
        router = new SwapRouter(address(factory));
        quoter = new Quoter(address(factory));

        address[] memory users = new address[](2);
        users[0] = lp;
        users[1] = trader;
        _fundAndApprove(users, address(npm));
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 3600;
    }

    function _seedLiquidity() internal {
        vm.prank(lp);
        npm.mint(
            NonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: FEE_MEDIUM,
                tickLower: LOWER,
                tickUpper: UPPER,
                amount0Desired: DESIRED,
                amount1Desired: DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: _deadline()
            })
        );
    }

    function _swapExactInput(address tokenIn, address tokenOut, uint256 amountIn) internal {
        vm.prank(trader);
        router.exactInputSingle(
            SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                                ORACLE
    //////////////////////////////////////////////////////////////*/

    function test_observe_revertsOnAnUninitializedPool() public {
        address fresh = factory.createPool(address(token0), address(token1), FEE_HIGH);
        vm.expectRevert("CLAMMPool: NI");
        ICLAMMPool(fresh).observe();
    }

    function test_observe_accumulatesZeroWhileTheTickIsZero() public {
        _seedLiquidity();
        vm.warp(block.timestamp + 1000);

        (int56 tickCumulative,) = pool.observe();
        assertEq(tickCumulative, int56(0));
    }

    function test_observe_accumulatesTickSecondsAcrossASwap() public {
        _seedLiquidity();

        (int56 c1, uint32 t1) = pool.observe();
        assertEq(c1, int56(0));

        // The accumulator folds in the pre-swap tick (0) at swap time, so it is
        // still zero immediately after the swap.
        uint256 swapTime = uint256(t1) + 100;
        vm.warp(swapTime);
        _swapExactInput(address(token0), address(token1), 1e17);

        assertEq(pool.tickCumulativeLast(), int56(0));
        assertEq(pool.blockTimestampLast(), uint32(swapTime));

        int24 tick = _tick();
        assertLt(tick, int24(0));

        // Sample 2: the new tick has been in effect for 500 seconds.
        vm.warp(swapTime + 500);
        (int56 c2, uint32 t2) = pool.observe();
        assertEq(c2 - c1, int56(tick) * int56(uint56(t2 - t1 - 100)), "tick * seconds");

        // The time-weighted average tick over a window spanning the swap sits
        // between the pre-swap tick (0) and the post-swap tick.
        int56 twat = (c2 - c1) / int56(uint56(t2 - t1));
        assertLe(twat, int56(0));
        assertGe(twat, int56(tick));
    }

    function test_observe_doesNotAdvanceForMintsAndBurns() public {
        _seedLiquidity();
        vm.warp(block.timestamp + 300);
        _seedLiquidity(); // a second mint into the same range

        // Lazy accumulation: storage is untouched and observe() extrapolates.
        assertEq(pool.tickCumulativeLast(), int56(0));
        (int56 tickCumulative,) = pool.observe();
        assertEq(tickCumulative, int56(0), "tick is still zero");
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTER
    //////////////////////////////////////////////////////////////*/

    function test_quoter_quotesExactInputToTheWeiWithoutMutatingState() public {
        _seedLiquidity();
        uint256 amountIn = 1e16;

        uint160 priceBefore = _sqrtPrice();
        uint256 quoted = quoter.quoteExactInputSingle(address(token0), address(token1), FEE_MEDIUM, amountIn, 0);
        assertEq(_sqrtPrice(), priceBefore, "quoting leaves pool state untouched");

        uint256 balanceBefore = token1.balanceOf(trader);
        _swapExactInput(address(token0), address(token1), amountIn);
        uint256 received = token1.balanceOf(trader) - balanceBefore;

        assertEq(quoted, received, "quote matches the executed swap exactly");
    }

    function test_quoter_quotesExactOutputToTheWei() public {
        _seedLiquidity();
        uint256 amountOut = 1e16;

        uint256 quoted = quoter.quoteExactOutputSingle(address(token1), address(token0), FEE_MEDIUM, amountOut, 0);

        uint256 balanceBefore = token1.balanceOf(trader);
        vm.prank(trader);
        router.exactOutputSingle(
            SwapRouter.ExactOutputSingleParams({
                tokenIn: address(token1),
                tokenOut: address(token0),
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountOut: amountOut,
                amountInMaximum: type(uint256).max,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 spent = balanceBefore - token1.balanceOf(trader);

        assertEq(quoted, spent, "quote matches the executed swap exactly");
    }

    function test_quoter_rejectsUnknownPoolsAndImpossibleOutputs() public {
        _seedLiquidity();

        vm.expectRevert("Quoter: POOL_NOT_FOUND");
        quoter.quoteExactInputSingle(address(token0), address(token1), FEE_LOW, 1000, 0);

        // More output than the range holds cannot be quoted as complete.
        vm.expectRevert("Quoter: INCOMPLETE_OUTPUT");
        quoter.quoteExactOutputSingle(address(token0), address(token1), FEE_MEDIUM, INITIAL_BALANCE, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
    //////////////////////////////////////////////////////////////*/

    function test_multicall_createsInitializesAndMintsAtomically() public {
        (TestERC20 n0, TestERC20 n1) = _deploySortedTokens("Token C", "TKC", "Token D", "TKD");
        n0.mint(lp, INITIAL_BALANCE);
        n1.mint(lp, INITIAL_BALANCE);

        vm.startPrank(lp);
        n0.approve(address(npm), type(uint256).max);
        n1.approve(address(npm), type(uint256).max);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            npm.createAndInitializePoolIfNecessary, (address(n0), address(n1), FEE_MEDIUM, encodePriceSqrt(1, 1))
        );
        calls[1] = abi.encodeCall(
            npm.mint,
            NonfungiblePositionManager.MintParams({
                token0: address(n0),
                token1: address(n1),
                fee: FEE_MEDIUM,
                tickLower: LOWER,
                tickUpper: UPPER,
                amount0Desired: DESIRED,
                amount1Desired: DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: _deadline()
            })
        );
        npm.multicall(calls);
        vm.stopPrank();

        assertEq(npm.ownerOf(1), lp);
        (,,, uint128 liquidity,,,,) = npm.positions(1);
        assertGt(liquidity, 0);
    }

    function test_createAndInitialize_isIdempotentAndRejectsUnsortedTokens() public {
        address existing = npm.createAndInitializePoolIfNecessary(address(token0), address(token1), FEE_MEDIUM, Q96);
        assertEq(existing, factory.getPool(address(token0), address(token1), FEE_MEDIUM));

        vm.expectRevert("NPM: TOKEN_ORDER");
        npm.createAndInitializePoolIfNecessary(address(token1), address(token0), FEE_MEDIUM, Q96);
    }

    function test_createAndInitialize_initializesAnExistingButPricelessPool() public {
        factory.createPool(address(token0), address(token1), FEE_HIGH);
        npm.createAndInitializePoolIfNecessary(address(token0), address(token1), FEE_HIGH, Q96);

        ICLAMMPool fresh = ICLAMMPool(factory.getPool(address(token0), address(token1), FEE_HIGH));
        (uint160 sqrtPriceX96,,,) = fresh.slot0();
        assertEq(sqrtPriceX96, Q96);
    }

    function test_multicall_bubblesTheInnerRevertReason() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            npm.mint,
            NonfungiblePositionManager.MintParams({
                token0: address(token1), // deliberately unsorted
                token1: address(token0),
                fee: FEE_MEDIUM,
                tickLower: LOWER,
                tickUpper: UPPER,
                amount0Desired: DESIRED,
                amount1Desired: DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: _deadline()
            })
        );

        vm.prank(lp);
        vm.expectRevert("NPM: TOKEN_ORDER");
        npm.multicall(calls);
    }

    function test_multicall_batchesARoutedSwap() public {
        _seedLiquidity();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            router.exactInputSingle,
            SwapRouter.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountIn: 1e15,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 balanceBefore = token1.balanceOf(trader);
        vm.prank(trader);
        router.multicall(calls);
        assertGt(token1.balanceOf(trader), balanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice The quoter must agree with the router to the wei for any input the
    ///         pool can actually fill.
    function testFuzz_quoter_matchesTheExecutedSwap(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 1e15);
        _seedLiquidity();

        uint256 quoted = quoter.quoteExactInputSingle(address(token0), address(token1), FEE_MEDIUM, amountIn, 0);

        uint256 balanceBefore = token1.balanceOf(trader);
        _swapExactInput(address(token0), address(token1), amountIn);

        assertEq(quoted, token1.balanceOf(trader) - balanceBefore, "quote is drift-free");
    }
}
