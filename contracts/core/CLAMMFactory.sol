// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLAMMFactory} from "../interfaces/ICLAMMFactory.sol";
import {CLAMMPoolDeployer} from "./CLAMMPoolDeployer.sol";

/// @title CLAMMFactory
/// @notice Deploys CLAMM pools and manages ownership and control over pool protocol fees.
contract CLAMMFactory is ICLAMMFactory, CLAMMPoolDeployer {
    /// @inheritdoc ICLAMMFactory
    address public override owner;

    /// @inheritdoc ICLAMMFactory
    mapping(uint24 => int24) public override feeAmountTickSpacing;

    /// @inheritdoc ICLAMMFactory
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        // Seed the canonical fee tiers, mirroring the widely adopted defaults.
        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc ICLAMMFactory
    function createPool(address tokenA, address tokenB, uint24 fee) external override returns (address pool) {
        require(tokenA != tokenB, "CLAMMFactory: SAME_TOKEN");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "CLAMMFactory: ZERO_ADDRESS");
        int24 tickSpacing = feeAmountTickSpacing[fee];
        require(tickSpacing != 0, "CLAMMFactory: FEE_NOT_ENABLED");
        require(getPool[token0][token1][fee] == address(0), "CLAMMFactory: POOL_EXISTS");
        pool = deploy(address(this), token0, token1, fee, tickSpacing);
        getPool[token0][token1][fee] = pool;
        // Populate mapping in the reverse direction, deliberate choice to avoid the cost
        // of comparing addresses. The pool addresses are the same regardless of order.
        getPool[token1][token0][fee] = pool;
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc ICLAMMFactory
    function setOwner(address _owner) external override {
        require(msg.sender == owner, "CLAMMFactory: NOT_OWNER");
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc ICLAMMFactory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner, "CLAMMFactory: NOT_OWNER");
        require(fee < 1_000_000, "CLAMMFactory: FEE_TOO_LARGE");
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick.
        require(tickSpacing > 0 && tickSpacing < 16384, "CLAMMFactory: INVALID_TICK_SPACING");
        require(feeAmountTickSpacing[fee] == 0, "CLAMMFactory: FEE_ALREADY_ENABLED");

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}
