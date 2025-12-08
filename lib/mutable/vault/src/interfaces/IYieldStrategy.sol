// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IYieldStrategy
 * @notice Interface for yield strategy adapter that handles token deposits and withdrawals
 */
interface IYieldStrategy {
    /**
     * @notice Deposit tokens into the vault
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     */
    function deposit(address token, uint256 amount, address recipient) external;

    /**
     * @notice Withdraw tokens from the vault
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external;

    /**
     * @notice Get the balance of a token for a specific address
     * @param token The token address
     * @param account The account address
     * @return The token balance
     * @dev DEPRECATED: This method's semantics are ambiguous (principal vs principal+yield).
     *      Use principalOf() for principal-only queries or totalBalanceOf() for principal+yield.
     *      For backward compatibility, existing implementations should maintain current behavior,
     *      but new code should use the explicit methods instead.
     */
    function balanceOf(address token, address account) external view returns (uint256);

    /**
     * @notice Returns the principal balance for a specific address
     * @dev Principal represents the amount originally deposited, excluding any accumulated yield.
     *      This is the basis for calculating surplus yield in the SurplusTracker system.
     * @param token The token address to query
     * @param account The account address to query the principal balance for
     * @return The principal balance of the account (deposits only, no yield)
     */
    function principalOf(address token, address account) external view returns (uint256);

    /**
     * @notice Returns the total balance including accumulated yield for a specific address
     * @dev Total balance represents principal + yield. This is the amount that would be
     *      received if the account withdrew all their funds. The difference between
     *      totalBalanceOf() and principalOf() represents the accumulated yield that can
     *      be extracted via the SurplusWithdrawer system.
     * @param token The token address to query
     * @param account The account address to query the total balance for
     * @return The total balance of the account (principal + accumulated yield)
     */
    function totalBalanceOf(address token, address account) external view returns (uint256);

    /**
     * @notice Set client authorization for deposit/withdraw operations
     * @param client The address of the client contract
     * @param _auth Whether to authorize (true) or deauthorize (false) the client
     * @dev This function should be restricted to the contract owner
     */
    function setClient(address client, bool _auth) external;

    /**
     * @notice Emergency withdraw function for owner to withdraw funds
     * @param amount The amount of tokens to withdraw
     * @dev This function should be restricted to the contract owner
     */
    function emergencyWithdraw(uint256 amount) external;

    /**
     * @notice Two-phase total withdrawal function for emergency fund migration
     * @param token The token address to withdraw from
     * @param client The client address whose tokens to withdraw
     * @dev Phase 1: Initiates 24-hour waiting period. Phase 2: Executes withdrawal within 48-hour window.
     *      This provides community protection against rugpulls while allowing legitimate fund migrations.
     *      Only the contract owner can initiate this process.
     */
    function totalWithdrawal(address token, address client) external;

    /**
     * @notice Withdraw surplus from a client's balance to a specified recipient
     * @param token The token address to withdraw
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw
     * @param recipient The address that will receive the withdrawn tokens
     * @dev Only authorized withdrawers can call this function. This is used to extract surplus yield.
     */
    function withdrawFrom(
        address token,
        address client,
        uint256 amount,
        address recipient
    ) external;
}