// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {CLAMMFactory} from "../contracts/core/CLAMMFactory.sol";
import {ICLAMMPool} from "../contracts/interfaces/ICLAMMPool.sol";

import {TestERC20} from "./utils/TestERC20.sol";
import {PoolTestCallee} from "./utils/PoolTestCallee.sol";
import {PoolHandler} from "./utils/PoolHandler.sol";

/// @notice Solvency invariants driven by Foundry's invariant fuzzer.
///
/// The core property is the one that matters for a pool holding other people's
/// money: whatever sequence of mints, swaps, flashes and partial burns it has
/// been through, every position must still be fully exitable. The pool must
/// honour every burn and collect, and end up holding nothing but rounding dust
/// — all of it retained in the pool's favour, never the user's.
contract InvariantTests is Test {
    uint160 internal constant Q96 = uint160(1) << 96;
    uint24 internal constant FEE_MEDIUM = 3000;

    /// @dev Rounding dust tolerated after a complete exit, plus the one wei per
    ///      token that collectProtocol deliberately leaves to keep its slot warm.
    uint256 internal constant DUST_LIMIT = 1e6;

    CLAMMFactory internal factory;
    TestERC20 internal token0;
    TestERC20 internal token1;
    ICLAMMPool internal pool;
    PoolTestCallee internal callee;
    PoolHandler internal handler;

    function setUp() public {
        factory = new CLAMMFactory();

        TestERC20 a = new TestERC20("A", "A");
        TestERC20 b = new TestERC20("B", "B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        pool = ICLAMMPool(factory.createPool(address(token0), address(token1), FEE_MEDIUM));
        pool.initialize(Q96);

        callee = new PoolTestCallee();
        handler = new PoolHandler(pool, token0, token1, callee);

        // Drive only the action surface; exitAll() is reserved for the invariant.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PoolHandler.mint.selector;
        selectors[1] = PoolHandler.swap.selector;
        selectors[2] = PoolHandler.flash.selector;
        selectors[3] = PoolHandler.burn.selector;
        selectors[4] = PoolHandler.setFeeProtocol.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Every position can be fully exited, and the pool is left empty.
    /// @dev Performs the exit against a snapshot so the sweep does not disturb
    ///      the sequence the fuzzer is building up.
    function invariant_poolHonoursAFullExit() public {
        uint256 snapshot = vm.snapshotState();

        handler.exitAll();
        // This contract deployed the factory, so it is the owner entitled to sweep.
        pool.collectProtocol(address(this), type(uint128).max, type(uint128).max);

        assertEq(pool.liquidity(), 0, "active liquidity fully withdrawn");
        assertLe(token0.balanceOf(address(pool)), DUST_LIMIT, "token0 dust only");
        assertLe(token1.balanceOf(address(pool)), DUST_LIMIT, "token1 dust only");

        vm.revertToState(snapshot);
    }

    /// @notice The pool always physically holds at least the protocol fees it has
    ///         credited, so collectProtocol can never fail for lack of balance.
    function invariant_poolCoversAccruedProtocolFees() public view {
        (uint128 protocol0, uint128 protocol1) = pool.protocolFees();
        assertGe(token0.balanceOf(address(pool)), protocol0, "token0 protocol fees are backed");
        assertGe(token1.balanceOf(address(pool)), protocol1, "token1 protocol fees are backed");
    }

    /// @notice The price never leaves the representable tick range.
    function invariant_priceStaysWithinTickBounds() public view {
        (uint160 sqrtPriceX96,,,) = pool.slot0();
        assertGe(sqrtPriceX96, 4295128739, "above MIN_SQRT_RATIO");
        assertLt(sqrtPriceX96, 1461446703485210103287273052203988822378723970342, "below MAX_SQRT_RATIO");
    }

    function invariant_callSummary() public view {
        console.log("mints    ", handler.mints());
        console.log("swaps    ", handler.swaps());
        console.log("flashes  ", handler.flashes());
        console.log("burns    ", handler.burns());
        console.log("ranges   ", handler.rangeCount());
    }
}
