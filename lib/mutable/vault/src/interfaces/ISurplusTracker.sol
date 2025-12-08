// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ISurplusTracker
 * @notice Interface for surplus tracking across vault types
 * @dev Provides view functions to calculate yield surplus that has accumulated in vaults
 */
interface ISurplusTracker {
    /**
     * @notice Calculate the surplus for a given client in a vault
     * @param vault The vault address
     * @param token The token address
     * @param client The client address
     * @param clientInternalBalance The client's internal accounting balance
     * @return The surplus amount (vault balance - client internal balance)
     * @dev Surplus represents yield that has accrued in the vault but is not tracked in client's internal accounting
     *      For example: Behodler's virtualInputTokens (internal) vs vault's balanceOf (actual with yield)
     */
    function getSurplus(
        address vault,
        address token,
        address client,
        uint256 clientInternalBalance
    ) external view returns (uint256);
}
