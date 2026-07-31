// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICLAMMPool} from "../interfaces/ICLAMMPool.sol";
import {ICLAMMPoolDeployer} from "../interfaces/ICLAMMPoolDeployer.sol";
import {ICLAMMFactory} from "../interfaces/ICLAMMFactory.sol";
import {IMintCallback} from "../interfaces/callback/IMintCallback.sol";
import {ISwapCallback} from "../interfaces/callback/ISwapCallback.sol";
import {IFlashCallback} from "../interfaces/callback/IFlashCallback.sol";

import {TickMath} from "../libraries/TickMath.sol";
import {Tick} from "../libraries/Tick.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {Position} from "../libraries/Position.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {FixedPoint128} from "../libraries/FixedPoint128.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../libraries/SqrtPriceMath.sol";
import {SwapMath} from "../libraries/SwapMath.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

/// @title CLAMMPool
/// @notice A concentrated-liquidity AMM pool between two ERC20 tokens.
/// @dev Implements tick-based concentrated liquidity with Q64.96 sqrt-price
///      accounting. Only ever deployed by the CLAMMFactory via CREATE2.
contract CLAMMPool is ICLAMMPool {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLAMMPool
    address public immutable override factory;
    /// @inheritdoc ICLAMMPool
    address public immutable override token0;
    /// @inheritdoc ICLAMMPool
    address public immutable override token1;
    /// @inheritdoc ICLAMMPool
    uint24 public immutable override fee;
    /// @inheritdoc ICLAMMPool
    int24 public immutable override tickSpacing;
    /// @inheritdoc ICLAMMPool
    uint128 public immutable override maxLiquidityPerTick;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    struct Slot0 {
        // The current price.
        uint160 sqrtPriceX96;
        // The current tick.
        int24 tick;
        // The protocol fee for both tokens of the pool, packed as two 4-bit values.
        uint8 feeProtocol;
        // Whether the pool is locked (reentrancy guard).
        bool unlocked;
    }
    /// @inheritdoc ICLAMMPool
    Slot0 public override slot0;

    /// @inheritdoc ICLAMMPool
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc ICLAMMPool
    uint256 public override feeGrowthGlobal1X128;

    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc ICLAMMPool
    ProtocolFees public override protocolFees;

    /// @inheritdoc ICLAMMPool
    uint128 public override liquidity;

    /// @inheritdoc ICLAMMPool
    int56 public override tickCumulativeLast;
    /// @inheritdoc ICLAMMPool
    uint32 public override blockTimestampLast;

    /// @inheritdoc ICLAMMPool
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc ICLAMMPool
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc ICLAMMPool
    mapping(bytes32 => Position.Info) public override positions;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a
    ///      method. This method also prevents entrance to a function before the
    ///      pool is initialized. The reentrancy guard is required throughout the
    ///      contract because we use balance checks to determine the payment status.
    modifier lock() {
        require(slot0.unlocked, "CLAMMPool: LOK");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Restricts a method to the factory owner.
    modifier onlyFactoryOwner() {
        require(msg.sender == ICLAMMFactory(factory).owner(), "CLAMMPool: NOT_OWNER");
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = ICLAMMPoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, "CLAMMPool: TLU");
        require(tickLower >= TickMath.MIN_TICK, "CLAMMPool: TLM");
        require(tickUpper <= TickMath.MAX_TICK, "CLAMMPool: TUM");
    }

    /// @dev Returns the pool's balance of token0.
    function balance0() private view returns (uint256) {
        return IERC20(token0).balanceOf(address(this));
    }

    /// @dev Returns the pool's balance of token1.
    function balance1() private view returns (uint256) {
        return IERC20(token1).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @dev Folds the time elapsed since the last observation into the tick
    ///      accumulator at the given (still-current) tick. Must be called before
    ///      any action that can move the price.
    function _advanceOracle(int24 tick) private {
        uint32 blockTimestamp = uint32(block.timestamp);
        unchecked {
            // Both the timestamp subtraction (uint32 wrap) and the accumulator
            // addition (int56 wrap) are designed to overflow.
            tickCumulativeLast += int56(tick) * int56(uint56(blockTimestamp - blockTimestampLast));
        }
        blockTimestampLast = blockTimestamp;
    }

    /// @inheritdoc ICLAMMPool
    function observe() external view override returns (int56 tickCumulative, uint32 blockTimestamp) {
        require(slot0.sqrtPriceX96 != 0, "CLAMMPool: NI"); // not initialized
        blockTimestamp = uint32(block.timestamp);
        unchecked {
            tickCumulative = tickCumulativeLast + int56(slot0.tick) * int56(uint56(blockTimestamp - blockTimestampLast));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLAMMPool
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, "CLAMMPool: AI"); // already initialized

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        blockTimestampLast = uint32(block.timestamp);

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, feeProtocol: 0, unlocked: true});

        emit Initialize(sqrtPriceX96, tick);
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    struct ModifyPositionParams {
        // The address that owns the position.
        address owner;
        // The lower and upper tick of the position.
        int24 tickLower;
        int24 tickUpper;
        // Any change in liquidity.
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position.
    /// @param params The position details and the change to the position's liquidity to effect.
    /// @return position A storage pointer referencing the position with the given owner and tick range.
    /// @return amount0 The amount of token0 owed to the pool, negative if the pool should pay the recipient.
    /// @return amount1 The amount of token1 owed to the pool, negative if the pool should pay the recipient.
    function _modifyPosition(ModifyPositionParams memory params)
        private
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, _slot0.tick);

        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // Current tick is below the passed range; liquidity can only become
                // in range by crossing from left to right, when we'll need _more_
                // token0 (it's becoming more valuable) so the user must provide it.
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // Current tick is inside the passed range.
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), _slot0.sqrtPriceX96, params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(liquidity, params.liquidityDelta);
            } else {
                // Current tick is above the passed range; liquidity can only become
                // in range by crossing from right to left, when we'll need _more_
                // token1 (it's becoming more valuable) so user must provide it.
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta.
    /// @param owner The owner of the position.
    /// @param tickLower The lower tick of the position's tick range.
    /// @param tickUpper The upper tick of the position's tick range.
    /// @param tick The current tick, passed to avoid sloads.
    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        private
        returns (Position.Info storage position)
    {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // If we need to update the ticks, do it.
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper, tick, liquidityDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, true, maxLiquidityPerTick
            );

            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // Clear any tick data that is no longer needed.
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc ICLAMMPool
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        override
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        require(amount > 0, "CLAMMPool: ZERO_LIQUIDITY");
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IMintCallback(msg.sender).clammMintCallback(amount0, amount1, data);
        if (amount0 > 0) require(balance0Before + amount0 <= balance0(), "CLAMMPool: M0");
        if (amount1 > 0) require(balance1Before + amount1 <= balance1(), "CLAMMPool: M1");

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc ICLAMMPool
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // We don't need to checkTicks here because invalid positions will never have non-zero tokensOwed.
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc ICLAMMPool
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        override
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(amount)).toInt128()
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) =
            (position.tokensOwed0 + uint128(amount0), position.tokensOwed1 + uint128(amount1));
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAP
    //////////////////////////////////////////////////////////////*/

    // The top level state of the swap, the results of which are recorded in storage at the end.
    struct SwapCache {
        // The protocol fee for the input token.
        uint8 feeProtocol;
        // Liquidity at the beginning of the swap.
        uint128 liquidityStart;
    }

    // The top level state of the swap, the results of which are recorded in storage at the end.
    struct SwapState {
        // The amount remaining to be swapped in/out of the input/output asset.
        int256 amountSpecifiedRemaining;
        // The amount already swapped out/in of the output/input asset.
        int256 amountCalculated;
        // Current sqrt(price).
        uint160 sqrtPriceX96;
        // The tick associated with the current price.
        int24 tick;
        // The global fee growth of the input token.
        uint256 feeGrowthGlobalX128;
        // Amount of input token paid as protocol fee.
        uint128 protocolFee;
        // The current liquidity in range.
        uint128 liquidity;
    }

    struct StepComputations {
        // The price at the beginning of the step.
        uint160 sqrtPriceStartX96;
        // The next tick to swap to from the current tick in the swap direction.
        int24 tickNext;
        // Whether tickNext is initialized or not.
        bool initialized;
        // sqrt(price) for the next tick (1/0).
        uint160 sqrtPriceNextX96;
        // How much is being swapped in in this step.
        uint256 amountIn;
        // How much is being swapped out.
        uint256 amountOut;
        // How much fee is being paid in.
        uint256 feeAmount;
    }

    /// @inheritdoc ICLAMMPool
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "CLAMMPool: AS");

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, "CLAMMPool: LOK");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "CLAMMPool: SPL"
        );

        slot0.unlocked = false;

        // Accumulate time spent at the pre-swap tick before the price moves.
        _advanceOracle(slot0Start.tick);

        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4)
        });

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        // Continue swapping as long as we haven't used the entire input/output and haven't reached the price limit.
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);

            // Ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds.
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // Get the price for the next tick.
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // Compute values to swap to the target tick, price limit, or point where input/output amount is exhausted.
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                // Safe because both are always positive and bounded by amountSpecifiedRemaining.
                unchecked {
                    state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                }
                state.amountCalculated -= step.amountOut.toInt256();
            } else {
                unchecked {
                    state.amountSpecifiedRemaining += step.amountOut.toInt256();
                }
                state.amountCalculated += (step.amountIn + step.feeAmount).toInt256();
            }

            // If the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee.
            if (cache.feeProtocol > 0) {
                unchecked {
                    uint256 delta = step.feeAmount / cache.feeProtocol;
                    step.feeAmount -= delta;
                    state.protocolFee += uint128(delta);
                }
            }

            // Update global fee tracker.
            if (state.liquidity > 0) {
                unchecked {
                    state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
                }
            }

            // Shift tick if we reached the next price.
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // If the tick is initialized, run the tick transition.
                if (step.initialized) {
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128)
                    );
                    // If we're moving leftward, we interpret liquidityNet as the opposite sign.
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                unchecked {
                    state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // Recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved.
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // Update tick and write an oracle entry if the tick changes.
        if (state.tick != slot0Start.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            // Otherwise just update the price.
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // Update liquidity if it changed.
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // Update fee growth global and, if necessary, protocol fees.
        // Overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees.
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            unchecked {
                if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
            }
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            unchecked {
                if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
            }
        }

        unchecked {
            (amount0, amount1) = zeroForOne == exactInput
                ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
                : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);
        }

        // Do the transfers and collect payment.
        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).clammSwapCallback(amount0, amount1, data);
            require(balance0Before + uint256(amount0) <= balance0(), "CLAMMPool: IIA"); // insufficient input amount
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).clammSwapCallback(amount0, amount1, data);
            require(balance1Before + uint256(amount1) <= balance1(), "CLAMMPool: IIA"); // insufficient input amount
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true;
    }

    /*//////////////////////////////////////////////////////////////
                                 FLASH
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLAMMPool
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override lock {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, "CLAMMPool: L");

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IFlashCallback(msg.sender).clammFlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before + fee0 <= balance0After, "CLAMMPool: F0");
        require(balance1Before + fee1 <= balance1After, "CLAMMPool: F1");

        // Sub is safe because we know balanceAfter is gt balanceBefore by at least fee.
        unchecked {
            uint256 paid0 = balance0After - balance0Before;
            uint256 paid1 = balance1After - balance1Before;

            if (paid0 > 0) {
                uint8 feeProtocol0 = slot0.feeProtocol % 16;
                uint256 pFees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
                if (uint128(pFees0) > 0) protocolFees.token0 += uint128(pFees0);
                feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - pFees0, FixedPoint128.Q128, _liquidity);
            }
            if (paid1 > 0) {
                uint8 feeProtocol1 = slot0.feeProtocol >> 4;
                uint256 pFees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
                if (uint128(pFees1) > 0) protocolFees.token1 += uint128(pFees1);
                feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - pFees1, FixedPoint128.Q128, _liquidity);
            }

            emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL FEES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLAMMPool
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10))
                && (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10)),
            "CLAMMPool: FP"
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc ICLAMMPool
    function collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        override
        lock
        onlyFactoryOwner
        returns (uint128 amount0, uint128 amount1)
    {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        unchecked {
            if (amount0 > 0) {
                if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
                protocolFees.token0 -= amount0;
                TransferHelper.safeTransfer(token0, recipient, amount0);
            }
            if (amount1 > 0) {
                if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
                protocolFees.token1 -= amount1;
                TransferHelper.safeTransfer(token1, recipient, amount1);
            }
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
