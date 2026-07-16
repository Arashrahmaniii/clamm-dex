// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title The interface for a CLAMM Pool
/// @notice A CLAMM pool facilitates swapping and automated market making between two
///         assets that use concentrated liquidity within discrete price ranges (ticks).
interface ICLAMMPool {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted exactly once by a pool when #initialize is first called on the pool.
    event Initialize(uint160 sqrtPriceX96, int24 tick);

    /// @notice Emitted when liquidity is minted for a given position.
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when fees are collected by the owner of a position.
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount0,
        uint128 amount1
    );

    /// @notice Emitted when a position's liquidity is removed.
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted by the pool for any swaps between token0 and token1.
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    /// @notice Emitted by the pool for any flash loans of token0/token1.
    event Flash(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 paid0,
        uint256 paid1
    );

    /// @notice Emitted when the protocol fee is changed by the pool.
    event SetFeeProtocol(uint8 feeProtocol0Old, uint8 feeProtocol1Old, uint8 feeProtocol0New, uint8 feeProtocol1New);

    /// @notice Emitted when the collected protocol fees are withdrawn by the factory owner.
    event CollectProtocol(address indexed sender, address indexed recipient, uint128 amount0, uint128 amount1);

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES / STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract that deployed the pool, which must adhere to the ICLAMMFactory interface.
    function factory() external view returns (address);

    /// @notice The first of the two tokens of the pool, sorted by address.
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address.
    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6.
    function fee() external view returns (uint24);

    /// @notice The pool tick spacing.
    function tickSpacing() external view returns (int24);

    /// @notice The maximum amount of position liquidity that can use any tick in the range.
    function maxLiquidityPerTick() external view returns (uint128);

    /// @notice The 0th storage slot in the pool stores many values, and is exposed as a single method to save gas when accessed externally.
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint8 feeProtocol, bool unlocked);

    /// @notice The fee growth as a Q128.128 fees of token0 collected per unit of liquidity for the entire life of the pool.
    function feeGrowthGlobal0X128() external view returns (uint256);

    /// @notice The fee growth as a Q128.128 fees of token1 collected per unit of liquidity for the entire life of the pool.
    function feeGrowthGlobal1X128() external view returns (uint256);

    /// @notice The amounts of token0 and token1 that are owed to the protocol.
    function protocolFees() external view returns (uint128 token0, uint128 token1);

    /// @notice The currently in range liquidity available to the pool.
    function liquidity() external view returns (uint128);

    /// @notice Look up information about a specific tick in the pool.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            bool initialized
        );

    /// @notice Returns 256 packed tick initialized boolean values. See TickBitmap for more information.
    function tickBitmap(int16 wordPosition) external view returns (uint256);

    /// @notice Returns the information about a position by the position's key.
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the initial price for the pool.
    /// @param sqrtPriceX96 The initial sqrt price of the pool as a Q64.96.
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Adds liquidity for the given recipient/tickLower/tickUpper position.
    /// @param recipient The address for which the liquidity will be created.
    /// @param tickLower The lower tick of the position in which to add liquidity.
    /// @param tickUpper The upper tick of the position in which to add liquidity.
    /// @param amount The amount of liquidity to mint.
    /// @param data Any data that should be passed through to the callback.
    /// @return amount0 The amount of token0 that was paid to mint the given amount of liquidity.
    /// @return amount1 The amount of token1 that was paid to mint the given amount of liquidity.
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects tokens owed to a position.
    /// @param recipient The address which should receive the fees collected.
    /// @param tickLower The lower tick of the position for which to collect fees.
    /// @param tickUpper The upper tick of the position for which to collect fees.
    /// @param amount0Requested How much token0 should be withdrawn from the fees owed.
    /// @param amount1Requested How much token1 should be withdrawn from the fees owed.
    /// @return amount0 The amount of fees collected in token0.
    /// @return amount1 The amount of fees collected in token1.
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Burn liquidity from the sender and account tokens owed for the liquidity to the position.
    /// @param tickLower The lower tick of the position for which to burn liquidity.
    /// @param tickUpper The upper tick of the position for which to burn liquidity.
    /// @param amount How much liquidity to burn.
    /// @return amount0 The amount of token0 sent to the recipient.
    /// @return amount1 The amount of token1 sent to the recipient.
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Swap token0 for token1, or token1 for token0.
    /// @param recipient The address to receive the output of the swap.
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0.
    /// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative).
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit.
    /// @param data Any data to be passed through to the callback.
    /// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive.
    /// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback.
    /// @param recipient The address which will receive the token0 and token1 amounts.
    /// @param amount0 The amount of token0 to send.
    /// @param amount1 The amount of token1 to send.
    /// @param data Any data to be passed through to the callback.
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;

    /// @notice Set the denominator of the protocol's % share of the fees.
    /// @param feeProtocol0 New protocol fee for token0 of the pool.
    /// @param feeProtocol1 New protocol fee for token1 of the pool.
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external;

    /// @notice Collect the protocol fee accrued to the pool.
    /// @param recipient The address to which collected protocol fees should be sent.
    /// @param amount0Requested The maximum amount of token0 to send, can be 0 to collect fees in only token1.
    /// @param amount1Requested The maximum amount of token1 to send, can be 0 to collect fees in only token0.
    /// @return amount0 The protocol fee collected in token0.
    /// @return amount1 The protocol fee collected in token1.
    function collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1);
}
