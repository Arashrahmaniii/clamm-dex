// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {ICLAMMPool} from "../contracts/interfaces/ICLAMMPool.sol";
import {NonfungiblePositionManager} from "../contracts/periphery/NonfungiblePositionManager.sol";
import {SwapRouter} from "../contracts/periphery/SwapRouter.sol";

/// @notice ERC-721 position management and routed swaps, including authorization,
///         slippage and deadline guards, and callback caller validation.
contract PeripheryTests is Base {
    NonfungiblePositionManager internal npm;
    SwapRouter internal router;

    uint256 internal constant DESIRED = 1e18;

    function setUp() public {
        _deployPool();
        pool.initialize(Q96);

        npm = new NonfungiblePositionManager(address(factory));
        router = new SwapRouter(address(factory));

        address[] memory users = _defaultUsers();
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

    function _mintParams(address t0, address t1, address recipient, uint256 deadline)
        internal
        pure
        returns (NonfungiblePositionManager.MintParams memory)
    {
        return NonfungiblePositionManager.MintParams({
            token0: t0,
            token1: t1,
            fee: FEE_MEDIUM,
            tickLower: LOWER,
            tickUpper: UPPER,
            amount0Desired: DESIRED,
            amount1Desired: DESIRED,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: deadline
        });
    }

    /// @dev Mints token id 1 to `lp` and returns it.
    function _mintPosition() internal returns (uint256 tokenId) {
        vm.prank(lp);
        (tokenId,,,) = npm.mint(_mintParams(address(token0), address(token1), lp, _deadline()));
    }

    function _positionLiquidityOf(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,, liquidity,,,,) = npm.positions(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_createsAnNftBackedByPoolLiquidity() public {
        uint256 tokenId = _mintPosition();

        assertEq(npm.ownerOf(tokenId), lp);
        (address positionPool,,, uint128 liquidity,,,,) = npm.positions(tokenId);
        assertEq(positionPool, address(pool));
        assertGt(liquidity, 0);
        assertEq(pool.liquidity(), liquidity);
    }

    function test_mint_enforcesDeadlineTokenOrderAndPoolExistence() public {
        vm.startPrank(lp);

        vm.expectRevert("NPM: DEADLINE_EXPIRED");
        npm.mint(_mintParams(address(token0), address(token1), lp, 1));

        vm.expectRevert("NPM: TOKEN_ORDER");
        npm.mint(_mintParams(address(token1), address(token0), lp, _deadline()));

        NonfungiblePositionManager.MintParams memory params =
            _mintParams(address(token0), address(token1), lp, _deadline());
        params.fee = FEE_LOW; // no pool exists at this tier
        vm.expectRevert("NPM: POOL_NOT_FOUND");
        npm.mint(params);

        vm.stopPrank();
    }

    function test_mint_enforcesTheSlippageMinimum() public {
        NonfungiblePositionManager.MintParams memory params =
            _mintParams(address(token0), address(token1), lp, _deadline());
        params.amount0Min = DESIRED * 2; // unreachable

        vm.prank(lp);
        vm.expectRevert("NPM: SLIPPAGE");
        npm.mint(params);
    }

    function test_mint_rejectsDirectCallsToTheCallback() public {
        vm.prank(other);
        vm.expectRevert("NPM: INVALID_CALLBACK");
        npm.clammMintCallback(1, 1, "");
    }

    /*//////////////////////////////////////////////////////////////
                        INCREASE / DECREASE
    //////////////////////////////////////////////////////////////*/

    function test_increaseLiquidity_addsToAnExistingPosition() public {
        uint256 tokenId = _mintPosition();
        uint128 before = _positionLiquidityOf(tokenId);

        vm.prank(lp);
        npm.increaseLiquidity(
            NonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: DESIRED,
                amount1Desired: DESIRED,
                amount0Min: 0,
                amount1Min: 0,
                deadline: _deadline()
            })
        );

        uint128 afterLiquidity = _positionLiquidityOf(tokenId);
        assertGt(afterLiquidity, before);
        assertEq(pool.liquidity(), afterLiquidity);
    }

    function test_decreaseLiquidity_accountsPrincipalAsOwed() public {
        uint256 tokenId = _mintPosition();
        uint128 liquidity = _positionLiquidityOf(tokenId);

        vm.prank(lp);
        npm.decreaseLiquidity(
            NonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity / 2, amount0Min: 0, amount1Min: 0, deadline: _deadline()
            })
        );

        (,,, uint128 remaining,,, uint128 owed0, uint128 owed1) = npm.positions(tokenId);
        assertEq(remaining, liquidity - liquidity / 2);
        assertGt(owed0, 0);
        assertGt(owed1, 0);
    }

    function test_decreaseAndCollect_blockNonOwners() public {
        uint256 tokenId = _mintPosition();

        vm.prank(other);
        vm.expectRevert("NPM: NOT_AUTHORIZED");
        npm.decreaseLiquidity(
            NonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: _deadline()
            })
        );

        vm.prank(other);
        vm.expectRevert("NPM: NOT_AUTHORIZED");
        npm.collect(
            NonfungiblePositionManager.CollectParams({tokenId: tokenId, recipient: other, amount0Max: 1, amount1Max: 1})
        );
    }

    function test_approvedOperatorCanManageThePosition() public {
        uint256 tokenId = _mintPosition();

        vm.prank(lp);
        npm.approve(other, tokenId);

        vm.prank(other);
        npm.decreaseLiquidity(
            NonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: _deadline()
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ROUTED SWAPS
    //////////////////////////////////////////////////////////////*/

    function test_exactInputSingle_swapsWithSlippageProtection() public {
        _mintPosition();
        uint256 amountIn = 1e15;

        uint256 bal1 = token1.balanceOf(trader);
        vm.prank(trader);
        router.exactInputSingle(
            SwapRouter.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountIn: amountIn,
                amountOutMinimum: amountIn * 99 / 100,
                sqrtPriceLimitX96: 0
            })
        );

        assertGe(token1.balanceOf(trader) - bal1, amountIn * 99 / 100);
    }

    function test_exactInputSingle_revertsBelowTheMinimumOutput() public {
        _mintPosition();
        uint256 amountIn = 1e15;

        vm.prank(trader);
        vm.expectRevert("SwapRouter: TOO_LITTLE_RECEIVED");
        router.exactInputSingle(
            SwapRouter.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountIn: amountIn,
                amountOutMinimum: amountIn, // impossible: fees make out < in at price 1
                sqrtPriceLimitX96: 0
            })
        );
    }

    function test_exactOutputSingle_respectsTheMaximumInput() public {
        _mintPosition();
        uint256 amountOut = 1e15;

        uint256 bal0Before = token0.balanceOf(trader);
        uint256 bal1Before = token1.balanceOf(trader);

        vm.prank(trader);
        router.exactOutputSingle(
            SwapRouter.ExactOutputSingleParams({
                tokenIn: address(token1),
                tokenOut: address(token0),
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountOut: amountOut,
                amountInMaximum: amountOut * 102 / 100,
                sqrtPriceLimitX96: 0
            })
        );

        assertEq(token0.balanceOf(trader) - bal0Before, amountOut, "exact output delivered");
        assertLe(bal1Before - token1.balanceOf(trader), amountOut * 102 / 100);
    }

    function test_router_enforcesDeadlineAndRejectsUnknownPools() public {
        _mintPosition();

        SwapRouter.ExactInputSingleParams memory params = SwapRouter.ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: FEE_MEDIUM,
            recipient: trader,
            deadline: 1,
            amountIn: 1000,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        vm.prank(trader);
        vm.expectRevert("SwapRouter: DEADLINE_EXPIRED");
        router.exactInputSingle(params);

        params.deadline = _deadline();
        params.fee = FEE_LOW; // no pool at this tier
        vm.prank(trader);
        vm.expectRevert("SwapRouter: POOL_NOT_FOUND");
        router.exactInputSingle(params);
    }

    function test_router_rejectsDirectCallsToTheSwapCallback() public {
        _mintPosition();

        bytes memory data = abi.encode(
            SwapRouter.SwapCallbackData({tokenIn: address(0), tokenOut: address(0), fee: FEE_MEDIUM, payer: other})
        );

        vm.prank(other);
        vm.expectRevert();
        router.clammSwapCallback(1, -1, data);
    }

    /*//////////////////////////////////////////////////////////////
                            FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_lifecycle_lpEarnsFeesThenExitsAndBurnsTheNft() public {
        uint256 tokenId = _mintPosition();

        // Generate fees with round-trip trades.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader);
            router.exactInputSingle(
                SwapRouter.ExactInputSingleParams({
                    tokenIn: address(token0),
                    tokenOut: address(token1),
                    fee: FEE_MEDIUM,
                    recipient: trader,
                    deadline: _deadline(),
                    amountIn: 1e16,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            vm.prank(trader);
            router.exactInputSingle(
                SwapRouter.ExactInputSingleParams({
                    tokenIn: address(token1),
                    tokenOut: address(token0),
                    fee: FEE_MEDIUM,
                    recipient: trader,
                    deadline: _deadline(),
                    amountIn: 1e16,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        uint128 liquidity = _positionLiquidityOf(tokenId);
        vm.prank(lp);
        npm.decreaseLiquidity(
            NonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: _deadline()
            })
        );

        uint256 bal0 = token0.balanceOf(lp);
        uint256 bal1 = token1.balanceOf(lp);
        vm.prank(lp);
        npm.collect(
            NonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: lp, amount0Max: MAX_UINT128, amount1Max: MAX_UINT128
            })
        );

        assertGt(token0.balanceOf(lp) - bal0, 0, "principal plus fees returned");
        assertGt(token1.balanceOf(lp) - bal1, 0, "principal plus fees returned");

        vm.prank(lp);
        npm.burn(tokenId);

        vm.expectRevert();
        npm.ownerOf(tokenId);

        (address clearedPool,,,,,,,) = npm.positions(tokenId);
        assertEq(clearedPool, address(0), "position storage cleared");
    }

    function test_burn_refusesWhileLiquidityOrTokensRemain() public {
        uint256 tokenId = _mintPosition();
        vm.prank(lp);
        vm.expectRevert("NPM: NOT_CLEARED");
        npm.burn(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice A routed exact-input swap never delivers less than the caller's
    ///         stated minimum — either it clears the bar or it reverts.
    function testFuzz_exactInputSingle_neverBreachesTheMinimum(uint256 amountIn, uint256 minOutPct) public {
        amountIn = bound(amountIn, 1e6, 1e15);
        minOutPct = bound(minOutPct, 1, 100);
        _mintPosition();

        uint256 minOut = amountIn * minOutPct / 100;
        uint256 bal1 = token1.balanceOf(trader);

        vm.prank(trader);
        try router.exactInputSingle(
            SwapRouter.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: FEE_MEDIUM,
                recipient: trader,
                deadline: _deadline(),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        ) {
            assertGe(token1.balanceOf(trader) - bal1, minOut, "delivered at least the minimum");
        } catch {
            // Reverting instead of under-delivering is the other acceptable outcome.
            assertEq(token1.balanceOf(trader), bal1, "no partial transfer on revert");
        }
    }
}
