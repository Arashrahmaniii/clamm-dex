// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {ICLAMMPool} from "../../contracts/interfaces/ICLAMMPool.sol";
import {TestERC20} from "./TestERC20.sol";
import {PoolTestCallee} from "./PoolTestCallee.sol";

/// @title PoolHandler
/// @notice Bounded action surface driven by Foundry's invariant fuzzer. Each
///         entrypoint maps a raw fuzz seed onto a legal-ish pool call; illegal
///         ones are allowed to revert and are simply not recorded.
/// @dev Positions are owned by the handler itself, so it can burn and collect
///      them during the exit sweep.
contract PoolHandler is CommonBase, StdCheats, StdUtils {
    ICLAMMPool public immutable pool;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;
    PoolTestCallee public immutable callee;
    int24 public immutable spacing;

    struct Range {
        int24 lower;
        int24 upper;
    }

    Range[] public ranges;
    mapping(bytes32 => bool) internal _known;

    // Call counters, surfaced by the invariant run summary.
    uint256 public mints;
    uint256 public swaps;
    uint256 public flashes;
    uint256 public burns;

    constructor(ICLAMMPool pool_, TestERC20 token0_, TestERC20 token1_, PoolTestCallee callee_) {
        pool = pool_;
        token0 = token0_;
        token1 = token1_;
        callee = callee_;
        spacing = pool_.tickSpacing();

        uint256 supply = 2 ** 120;
        token0_.mint(address(this), supply);
        token1_.mint(address(this), supply);
        token0_.approve(address(callee_), type(uint256).max);
        token1_.approve(address(callee_), type(uint256).max);
    }

    function rangeCount() external view returns (uint256) {
        return ranges.length;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 lowerSeed, uint256 upperSeed, uint256 liquiditySeed) external {
        // Tick indices live in [-800, 800] and are scaled by the pool's spacing,
        // keeping both bounds well inside [MIN_TICK, MAX_TICK] and always aligned.
        int256 lowerIdx = int256(bound(lowerSeed, 0, 1599)) - 800; // [-800, 799]
        int256 upperIdx = int256(bound(upperSeed, uint256(lowerIdx + 801), 1600)) - 800; // (lowerIdx, 800]

        int24 lower = int24(lowerIdx) * spacing;
        int24 upper = int24(upperIdx) * spacing;
        uint128 liquidity = uint128(bound(liquiditySeed, 1e6, 1e21));

        try callee.mint(address(pool), address(this), lower, upper, liquidity) {
            _record(lower, upper);
            mints++;
        } catch {}
    }

    function swap(uint256 amountSeed, bool zeroForOne, bool exactInput) external {
        uint256 amount = bound(amountSeed, 1e3, 1e19);
        int256 amountSpecified = exactInput ? int256(amount) : -int256(amount);
        uint160 limit = zeroForOne ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1;

        try callee.swap(address(pool), address(this), zeroForOne, amountSpecified, limit) {
            swaps++;
        } catch {}
    }

    function flash(uint256 amount0Seed, uint256 amount1Seed) external {
        try callee.flash(address(pool), address(callee), bound(amount0Seed, 0, 1e15), bound(amount1Seed, 0, 1e15)) {
            flashes++;
        } catch {}
    }

    function burn(uint256 indexSeed, uint256 partSeed) external {
        if (ranges.length == 0) return;
        Range memory r = ranges[bound(indexSeed, 0, ranges.length - 1)];

        uint128 liquidity = _liquidityOf(r);
        if (liquidity <= 1) return;

        try pool.burn(r.lower, r.upper, uint128(bound(partSeed, 1, liquidity))) {
            burns++;
        } catch {}
    }

    function setFeeProtocol(uint256 fee0Seed, uint256 fee1Seed) external {
        try pool.setFeeProtocol(uint8(bound(fee0Seed, 4, 10)), uint8(bound(fee1Seed, 4, 10))) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              EXIT SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Burns and collects every position the handler holds. Excluded from
    ///         the fuzz target selectors; the invariant calls it explicitly.
    function exitAll() external {
        for (uint256 i = 0; i < ranges.length; i++) {
            Range memory r = ranges[i];
            uint128 liquidity = _liquidityOf(r);
            if (liquidity > 0) {
                pool.burn(r.lower, r.upper, liquidity);
            }
            pool.collect(address(this), r.lower, r.upper, type(uint128).max, type(uint128).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _record(int24 lower, int24 upper) private {
        bytes32 key = keccak256(abi.encodePacked(lower, upper));
        if (!_known[key]) {
            _known[key] = true;
            ranges.push(Range({lower: lower, upper: upper}));
        }
    }

    /// @dev Reads liquidity from the pool rather than from local bookkeeping, so
    ///      the exit sweep can never disagree with the pool's own accounting.
    function _liquidityOf(Range memory r) private view returns (uint128 liquidity) {
        (liquidity,,,,) = pool.positions(keccak256(abi.encodePacked(address(this), r.lower, r.upper)));
    }
}
