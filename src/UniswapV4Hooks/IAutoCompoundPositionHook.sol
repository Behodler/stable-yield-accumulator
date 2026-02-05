// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IAutoCompoundPositionHook
/// @notice Interface for the AutoCompoundPositionHook - a Uniswap V4 hook that charges
/// an additional fee on swaps and auto-compounds collected fees into its own liquidity position.
interface IAutoCompoundPositionHook {
    // ============ Events ============

    /// @notice Emitted when the hook's active status is changed
    /// @param active The new active status
    event ActiveSet(bool active);

    /// @notice Emitted when the tax rate is changed
    /// @param taxBps The new tax rate in basis points
    event TaxBpsSet(uint256 taxBps);

    /// @notice Emitted when the threshold token index is changed
    /// @param index The new threshold token index (0 or 1)
    event ThresholdTokenSet(uint256 index);

    /// @notice Emitted when the threshold amount is changed
    /// @param amount The new threshold amount
    event ThresholdAmountSet(uint256 amount);

    /// @notice Emitted when position parameters are changed
    /// @param tickLower The new lower tick
    /// @param tickUpper The new upper tick
    /// @param salt The new position salt
    event PositionParamsSet(int24 tickLower, int24 tickUpper, bytes32 salt);

    /// @notice Emitted when the hook successfully compounds fees into liquidity
    /// @param used0 Amount of token0 used for compounding
    /// @param used1 Amount of token1 used for compounding
    /// @param liquidityAdded Amount of liquidity added to the position
    event Compounded(uint256 used0, uint256 used1, uint128 liquidityAdded);

    /// @notice Emitted when liquidity is withdrawn from the hook's position
    /// @param recipient The address receiving the withdrawn tokens
    /// @param liquidityRemoved Amount of liquidity removed
    /// @param amount0 Amount of token0 withdrawn
    /// @param amount1 Amount of token1 withdrawn
    event LiquidityWithdrawn(address indexed recipient, uint128 liquidityRemoved, uint256 amount0, uint256 amount1);

    // ============ State Variable Getters ============

    /// @notice Returns the pool key this hook is bound to
    /// @return currency0 The first currency of the pool
    /// @return currency1 The second currency of the pool
    /// @return fee The pool fee
    /// @return tickSpacing The tick spacing
    /// @return hooks The hooks address
    function poolKey()
        external
        view
        returns (
            address currency0,
            address currency1,
            uint24 fee,
            int24 tickSpacing,
            address hooks
        );

    /// @notice Returns the pool ID this hook is bound to
    /// @return The immutable pool ID
    function poolId() external view returns (PoolId);

    /// @notice Returns whether the hook is currently active
    /// @return True if the hook is active, false otherwise
    function active() external view returns (bool);

    /// @notice Returns the current tax rate in basis points
    /// @return The tax rate (e.g., 5 = 0.05%)
    function taxBps() external view returns (uint256);

    /// @notice Returns which token is used for threshold checking
    /// @return 0 for token0, 1 for token1
    function thresholdTokenIndex() external view returns (uint256);

    /// @notice Returns the minimum balance required to trigger compounding
    /// @return The threshold amount in raw token units
    function thresholdAmount() external view returns (uint256);

    /// @notice Returns the lower tick of the hook's position
    /// @return The lower tick boundary
    function tickLower() external view returns (int24);

    /// @notice Returns the upper tick of the hook's position
    /// @return The upper tick boundary
    function tickUpper() external view returns (int24);

    /// @notice Returns the salt used for the hook's position
    /// @return The position salt
    function positionSalt() external view returns (bytes32);

    // ============ Owner Functions ============

    /// @notice Sets which token is used for threshold checking
    /// @dev Only callable by owner. Emits ThresholdTokenSet event.
    /// @param index The token index (0 or 1)
    function setThresholdToken(uint256 index) external;

    /// @notice Changes the minimum balance required to trigger compounding
    /// @dev Only callable by owner. Emits ThresholdAmountSet event.
    /// @param amount The new threshold amount
    function changeThreshold(uint256 amount) external;

    /// @notice Modifies the hook's position parameters
    /// @dev Only callable by owner. Emits PositionParamsSet event.
    /// @param _tickLower The new lower tick
    /// @param _tickUpper The new upper tick
    /// @param _salt The new position salt
    function modifyPosition(int24 _tickLower, int24 _tickUpper, bytes32 _salt) external;

    /// @notice Enables or disables the hook
    /// @dev Only callable by owner. Emits ActiveSet event.
    /// @param _active The new active status
    function setActive(bool _active) external;

    /// @notice Sets the tax rate in basis points
    /// @dev Only callable by owner. Emits TaxBpsSet event. Max 10000 (100%).
    /// @param basisPoints The new tax rate
    function setTaxPercentage(uint256 basisPoints) external;

    /// @notice Withdraws all liquidity from the hook's position
    /// @dev Only callable by owner. Emits LiquidityWithdrawn event.
    /// @param recipient The address to receive the withdrawn tokens
    function withdrawLiquidity(address recipient) external;

    // ============ Public Functions ============

    /// @notice Triggers a compounding attempt
    /// @dev Anyone can call this. Compounding only occurs if:
    ///      - Hook is active
    ///      - Current tick is within position range
    ///      - Threshold token balance meets threshold amount
    function poke() external;
}
