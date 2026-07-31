// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {ICLAMMFactory} from "../interfaces/ICLAMMFactory.sol";
import {ICLAMMPool} from "../interfaces/ICLAMMPool.sol";
import {IMintCallback} from "../interfaces/callback/IMintCallback.sol";

import {TickMath} from "../libraries/TickMath.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {FixedPoint128} from "../libraries/FixedPoint128.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {Multicall} from "./base/Multicall.sol";

/// @title NonfungiblePositionManager
/// @notice Wraps CLAMM positions in the ERC-721 non-fungible token interface,
///         allowing positions to be transferred and composed like any NFT.
contract NonfungiblePositionManager is ERC721, IMintCallback, Multicall {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct PositionData {
        // The pool the position belongs to.
        address pool;
        // The tick range of the position.
        int24 tickLower;
        int24 tickUpper;
        // The liquidity of the position.
        uint128 liquidity;
        // The fee growth of the aggregate position as of the last action on the individual position.
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // How many uncollected tokens are owed to the position, as of the last computation.
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @dev Data passed through the pool's mint callback.
    struct MintCallbackData {
        address token0;
        address token1;
        address payer;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when liquidity is increased for a position NFT.
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when liquidity is decreased for a position NFT.
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when tokens are collected for a position NFT.
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The factory whose pools this manager operates on.
    ICLAMMFactory public immutable factory;

    /// @notice Position data per token id.
    mapping(uint256 => PositionData) public positions;

    /// @dev The id of the next token that will be minted. Skips 0.
    uint256 private _nextId = 1;

    /// @dev The pool expected to invoke the mint callback for the current
    ///      in-flight mint; zeroed afterwards. Guards against arbitrary callers.
    address private _expectedCallbackPool;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "NPM: DEADLINE_EXPIRED");
        _;
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "NPM: NOT_AUTHORIZED");
        _;
    }

    constructor(address _factory) ERC721("CLAMM Positions NFT", "CLAMM-POS") {
        factory = ICLAMMFactory(_factory);
    }

    /*//////////////////////////////////////////////////////////////
                            POOL INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a pool for the given tokens and fee if it does not exist
    ///         yet, and initializes it if it holds no price. Typically batched
    ///         with `mint` via `multicall`.
    /// @param token0 The first token of the pool by address sort order.
    /// @param token1 The second token of the pool by address sort order.
    /// @param fee The fee tier of the pool.
    /// @param sqrtPriceX96 The initial price for the pool if it must be initialized.
    /// @return pool The pool for the given parameters.
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        require(token0 < token1, "NPM: TOKEN_ORDER");
        pool = factory.getPool(token0, token1, fee);

        if (pool == address(0)) {
            pool = factory.createPool(token0, token1, fee);
            ICLAMMPool(pool).initialize(sqrtPriceX96);
        } else {
            (uint160 sqrtPriceX96Existing,,,) = ICLAMMPool(pool).slot0();
            if (sqrtPriceX96Existing == 0) {
                ICLAMMPool(pool).initialize(sqrtPriceX96);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             MINT CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintCallback
    function clammMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        require(msg.sender == _expectedCallbackPool && msg.sender != address(0), "NPM: INVALID_CALLBACK");
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));

        if (amount0Owed > 0) TransferHelper.safeTransferFrom(decoded.token0, decoded.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) TransferHelper.safeTransferFrom(decoded.token1, decoded.payer, msg.sender, amount1Owed);
    }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Adds liquidity to an initialized pool on behalf of `recipient`.
    function _addLiquidity(
        address pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) private returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Compute the liquidity amount from desired token amounts at current price.
        {
            (uint160 sqrtPriceX96,,,) = ICLAMMPool(pool).slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
            );
        }
        require(liquidity > 0, "NPM: ZERO_LIQUIDITY");

        _expectedCallbackPool = pool;
        (amount0, amount1) = ICLAMMPool(pool)
            .mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(MintCallbackData({token0: token0, token1: token1, payer: msg.sender}))
            );
        _expectedCallbackPool = address(0);

        require(amount0 >= amount0Min && amount1 >= amount1Min, "NPM: SLIPPAGE");
    }

    /// @notice Creates a new position wrapped in an NFT.
    /// @dev The pool must already exist and be initialized. Call via a multicall
    ///      pattern or directly after `factory.createPool` + `pool.initialize`.
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata.
    /// @return tokenId The ID of the token that represents the minted position.
    /// @return liquidity The amount of liquidity for this position.
    /// @return amount0 The amount of token0 used to mint the position.
    /// @return amount1 The amount of token1 used to mint the position.
    function mint(MintParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(params.token0 < params.token1, "NPM: TOKEN_ORDER");
        address pool = factory.getPool(params.token0, params.token1, params.fee);
        require(pool != address(0), "NPM: POOL_NOT_FOUND");

        (liquidity, amount0, amount1) = _addLiquidity(
            pool,
            params.token0,
            params.token1,
            params.tickLower,
            params.tickUpper,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min
        );

        _mint(params.recipient, (tokenId = _nextId++));

        // The position's fee snapshot starts at the pool's current inside growth.
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), params.tickLower, params.tickUpper));
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) =
            ICLAMMPool(pool).positions(positionKey);

        positions[tokenId] = PositionData({
            pool: pool,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Increases the amount of liquidity in a position, with tokens paid by the `msg.sender`.
    /// @param params tokenId The ID of the token for which liquidity is being increased,
    ///        amount0Desired The desired amount of token0 to be spent,
    ///        amount1Desired The desired amount of token1 to be spent,
    ///        amount0Min The minimum amount of token0 to spend, which serves as a slippage check,
    ///        amount1Min The minimum amount of token1 to spend, which serves as a slippage check,
    ///        deadline The time by which the transaction must be included to effect the change.
    /// @return liquidity The new liquidity amount as a result of the increase.
    /// @return amount0 The amount of token0 to achieve resulting liquidity.
    /// @return amount1 The amount of token1 to achieve resulting liquidity.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        PositionData storage position = positions[params.tokenId];
        address pool = position.pool;
        require(pool != address(0), "NPM: INVALID_TOKEN");

        (liquidity, amount0, amount1) = _addLiquidity(
            pool,
            ICLAMMPool(pool).token0(),
            ICLAMMPool(pool).token1(),
            position.tickLower,
            position.tickUpper,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min
        );

        _updateFees(position, pool);
        position.liquidity += liquidity;

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @notice Decreases the amount of liquidity in a position and accounts it to the position.
    /// @param params tokenId The ID of the token for which liquidity is being decreased,
    ///        liquidity The amount by which liquidity will be decreased,
    ///        amount0Min The minimum amount of token0 that should be accounted for the burned liquidity,
    ///        amount1Min The minimum amount of token1 that should be accounted for the burned liquidity,
    ///        deadline The time by which the transaction must be included to effect the change.
    /// @return amount0 The amount of token0 accounted to the position's tokens owed.
    /// @return amount1 The amount of token1 accounted to the position's tokens owed.
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.liquidity > 0, "NPM: ZERO_LIQUIDITY");
        PositionData storage position = positions[params.tokenId];
        require(position.liquidity >= params.liquidity, "NPM: INSUFFICIENT_LIQUIDITY");

        address pool = position.pool;
        (amount0, amount1) = ICLAMMPool(pool).burn(position.tickLower, position.tickUpper, params.liquidity);

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "NPM: SLIPPAGE");

        _updateFees(position, pool);
        // The tokens from the burn itself are also owed to this position.
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);
        position.liquidity -= params.liquidity;

        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1);
    }

    /// @notice Collects up to a maximum amount of fees owed to a specific position to the recipient.
    /// @param params tokenId The ID of the NFT for which tokens are being collected,
    ///        recipient The account that should receive the tokens,
    ///        amount0Max The maximum amount of token0 to collect,
    ///        amount1Max The maximum amount of token1 to collect.
    /// @return amount0 The amount of fees collected in token0.
    /// @return amount1 The amount of fees collected in token1.
    function collect(CollectParams calldata params)
        external
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.amount0Max > 0 || params.amount1Max > 0, "NPM: ZERO_COLLECT");
        PositionData storage position = positions[params.tokenId];
        address pool = position.pool;

        // Trigger an update of the position fees owed if it has any liquidity.
        if (position.liquidity > 0) {
            ICLAMMPool(pool).burn(position.tickLower, position.tickUpper, 0);
            _updateFees(position, pool);
        }

        uint128 amount0Collect = params.amount0Max > position.tokensOwed0 ? position.tokensOwed0 : params.amount0Max;
        uint128 amount1Collect = params.amount1Max > position.tokensOwed1 ? position.tokensOwed1 : params.amount1Max;

        // The pool pays the recipient directly.
        (amount0, amount1) = ICLAMMPool(pool)
            .collect(params.recipient, position.tickLower, position.tickUpper, amount0Collect, amount1Collect);

        // Underflow-safe: collected amounts are bounded by tokensOwed above.
        position.tokensOwed0 -= amount0Collect;
        position.tokensOwed1 -= amount1Collect;

        emit Collect(params.tokenId, params.recipient, amount0Collect, amount1Collect);
    }

    /// @notice Burns a token ID, which deletes it from the NFT contract. The token
    ///         must have 0 liquidity and all tokens must be collected first.
    /// @param tokenId The ID of the token that is being burned.
    function burn(uint256 tokenId) external isAuthorizedForToken(tokenId) {
        PositionData storage position = positions[tokenId];
        require(position.liquidity == 0 && position.tokensOwed0 == 0 && position.tokensOwed1 == 0, "NPM: NOT_CLEARED");
        delete positions[tokenId];
        _burn(tokenId);
    }

    /// @dev Syncs a position's fee snapshot against the pool's current inside
    ///      growth, accruing any newly earned fees to tokensOwed.
    function _updateFees(PositionData storage position, address pool) private {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), position.tickLower, position.tickUpper));
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) =
            ICLAMMPool(pool).positions(positionKey);

        unchecked {
            position.tokensOwed0 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128, position.liquidity, FixedPoint128.Q128
                )
            );
            position.tokensOwed1 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128, position.liquidity, FixedPoint128.Q128
                )
            );
        }

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
    }
}
