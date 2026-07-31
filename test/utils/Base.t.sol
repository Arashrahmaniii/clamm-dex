// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CLAMMFactory} from "../../contracts/core/CLAMMFactory.sol";
import {ICLAMMPool} from "../../contracts/interfaces/ICLAMMPool.sol";
import {FullMath} from "../../contracts/libraries/FullMath.sol";

import {TestERC20} from "./TestERC20.sol";
import {PoolTestCallee} from "./PoolTestCallee.sol";

/// @title Base
/// @notice Shared constants, price helpers and pool fixtures for the suite.
///         Replaces what test/helpers.ts provided under Hardhat.
abstract contract Base is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint160 internal constant Q96 = uint160(1) << 96;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    uint24 internal constant FEE_LOW = 500;
    uint24 internal constant FEE_MEDIUM = 3000;
    uint24 internal constant FEE_HIGH = 10000;

    int24 internal constant SPACING_LOW = 10;
    int24 internal constant SPACING_MEDIUM = 60;
    int24 internal constant SPACING_HIGH = 200;

    /// @dev The canonical wide range used by most tests: ±600 ticks around price 1.
    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;

    uint128 internal constant LIQUIDITY = 1e18;
    uint256 internal constant INITIAL_BALANCE = 1e24;
    uint128 internal constant MAX_UINT128 = type(uint128).max;

    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal other = makeAddr("other");

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    CLAMMFactory internal factory;
    TestERC20 internal token0;
    TestERC20 internal token1;
    ICLAMMPool internal pool;
    PoolTestCallee internal callee;

    /*//////////////////////////////////////////////////////////////
                               FIXTURES
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys a factory, a sorted token pair and an (uninitialized) medium-fee pool.
    ///      The test contract is the factory owner, standing in for Hardhat's `deployer`.
    function _deployPool() internal {
        // Foundry starts the chain at timestamp 1. Move to a realistic epoch so
        // deadline arguments in the past are actually in the past, and so the
        // oracle's uint32 timestamp accumulator is exercised at realistic values.
        vm.warp(1_700_000_000);

        factory = new CLAMMFactory();
        (token0, token1) = _deploySortedTokens("Token A", "TKA", "Token B", "TKB");
        pool = ICLAMMPool(factory.createPool(address(token0), address(token1), FEE_MEDIUM));
        callee = new PoolTestCallee();
    }

    /// @dev Deploys two tokens and returns them ordered by address, as the pool requires.
    function _deploySortedTokens(string memory nameA, string memory symbolA, string memory nameB, string memory symbolB)
        internal
        returns (TestERC20 t0, TestERC20 t1)
    {
        TestERC20 a = new TestERC20(nameA, symbolA);
        TestERC20 b = new TestERC20(nameB, symbolB);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
    }

    /// @dev Mints the initial balance to each user and approves `spender` for both tokens.
    function _fundAndApprove(address[] memory users, address spender) internal {
        for (uint256 i = 0; i < users.length; i++) {
            token0.mint(users[i], INITIAL_BALANCE);
            token1.mint(users[i], INITIAL_BALANCE);
            vm.startPrank(users[i]);
            token0.approve(spender, type(uint256).max);
            token1.approve(spender, type(uint256).max);
            vm.stopPrank();
        }
    }

    function _defaultUsers() internal view returns (address[] memory users) {
        users = new address[](3);
        users[0] = lp;
        users[1] = trader;
        users[2] = other;
    }

    /*//////////////////////////////////////////////////////////////
                             POOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    function _mint(address payer, int24 tickLower, int24 tickUpper, uint128 amount) internal {
        vm.prank(payer);
        callee.mint(address(pool), payer, tickLower, tickUpper, amount);
    }

    function _swap(address payer, bool zeroForOne, int256 amountSpecified) internal {
        uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
        vm.prank(payer);
        callee.swap(address(pool), payer, zeroForOne, amountSpecified, limit);
    }

    /*//////////////////////////////////////////////////////////////
                                 MATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes sqrt(reserve1 / reserve0) * 2^96, as consumed by `initialize`.
    /// @dev Uses 512-bit mulDiv so `reserve1 << 192` cannot overflow intermediately.
    function encodePriceSqrt(uint256 reserve1, uint256 reserve0) internal pure returns (uint160) {
        return uint160(_sqrt(FullMath.mulDiv(reserve1, uint256(1) << 192, reserve0)));
    }

    /// @dev Babylonian integer square root (floor).
    function _sqrt(uint256 value) internal pure returns (uint256 x) {
        if (value == 0) return 0;
        x = value;
        uint256 y = (x + 1) / 2;
        while (y < x) {
            x = y;
            y = (x + value / x) / 2;
        }
    }

    /// @notice The pool's storage key for a position, matching Position.get().
    function positionKey(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    /*//////////////////////////////////////////////////////////////
                               ACCESSORS
    //////////////////////////////////////////////////////////////*/

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pool.slot0();
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = pool.slot0();
    }

    function _positionLiquidity(address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        (liquidity,,,,) = pool.positions(positionKey(owner, tickLower, tickUpper));
    }

    function _tokensOwed(address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 owed0, uint128 owed1)
    {
        (,,, owed0, owed1) = pool.positions(positionKey(owner, tickLower, tickUpper));
    }
}
