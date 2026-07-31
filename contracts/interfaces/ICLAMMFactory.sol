// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title The interface for the CLAMM Factory
/// @notice The factory facilitates creation of CLAMM pools and control over the protocol fees.
interface ICLAMMFactory {
    /// @notice Emitted when the owner of the factory is changed.
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when a pool is created.
    event PoolCreated(
        address indexed token0, address indexed token1, uint24 indexed fee, int24 tickSpacing, address pool
    );

    /// @notice Emitted when a new fee amount is enabled for pool creation via the factory.
    event FeeAmountEnabled(uint24 indexed fee, int24 indexed tickSpacing);

    /// @notice Returns the current owner of the factory.
    function owner() external view returns (address);

    /// @notice Returns the tick spacing for a given fee amount, if enabled, or 0 if not enabled.
    /// @dev A fee amount can never be removed, so this value should be hard coded or cached in the calling context.
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);

    /// @notice Returns the pool address for a given pair of tokens and a fee, or address 0 if it does not exist.
    /// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

    /// @notice Creates a pool for the given two tokens and fee.
    /// @param tokenA One of the two tokens in the desired pool.
    /// @param tokenB The other of the two tokens in the desired pool.
    /// @param fee The desired fee for the pool.
    /// @return pool The address of the newly created pool.
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);

    /// @notice Updates the owner of the factory.
    /// @param _owner The new owner of the factory.
    function setOwner(address _owner) external;

    /// @notice Enables a fee amount with the given tickSpacing.
    /// @param fee The fee amount to enable, denominated in hundredths of a bip (i.e. 1e-6).
    /// @param tickSpacing The spacing between ticks to be enforced for all pools created with the given fee amount.
    function enableFeeAmount(uint24 fee, int24 tickSpacing) external;
}
