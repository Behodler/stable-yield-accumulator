// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IClaimArbitrage
 * @notice Interface for the ClaimArbitrage contract that atomically pumps phUSD price,
 *         claims discounted stablecoins, unwinds the price pump, and converts profit to ETH.
 */
interface IClaimArbitrage {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Parameters for executing the atomic arbitrage
     * @param pumpAmount sUSDS to sell for phUSD (calibrated off-chain to just cross targetPrice)
     * @param rewardTokenNeeded Reward token to borrow for claim payment (= calculateClaimAmount())
     * @param pumpPriceLimit max sqrtPriceX96 willing to pay when buying phUSD
     * @param unwindPriceLimit min sqrtPriceX96 willing to accept when selling phUSD back
     */
    struct ExecuteParams {
        uint256 pumpAmount;
        uint256 rewardTokenNeeded;
        uint160 pumpPriceLimit;
        uint160 unwindPriceLimit;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an arbitrage is successfully executed
     * @param caller The address that initiated the arbitrage
     * @param ethProfit The amount of ETH profit sent to the caller
     */
    event ArbitrageExecuted(address indexed caller, uint256 ethProfit);

    /**
     * @notice Emitted when a stable-to-reward-token pool mapping is updated
     * @param stable The stablecoin address
     */
    event StableToRewardTokenPoolSet(address indexed stable);

    /**
     * @notice Emitted when a known stablecoin is added
     * @param stable The stablecoin address added
     */
    event KnownStableAdded(address indexed stable);

    /**
     * @notice Emitted when a known stablecoin is removed
     * @param stable The stablecoin address removed
     */
    event KnownStableRemoved(address indexed stable);

    /**
     * @notice Emitted when pool keys are updated
     */
    event PoolKeysUpdated();

    /**
     * @notice Emitted when stranded tokens are rescued from the contract
     * @param token The rescued token address
     * @param to The recipient of the rescued tokens
     * @param amount The amount of tokens rescued
     */
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when the callback caller is not the PoolManager
     */
    error OnlyPoolManager();

    /**
     * @notice Thrown when the arbitrage produces no reward-token profit
     */
    error NoProfit();

    /**
     * @notice Thrown when the reward-token-to-WETH conversion produces no WETH
     */
    error NoWETHProfit();

    /**
     * @notice Thrown when ETH transfer to the caller fails
     */
    error ETHTransferFailed();

    /**
     * @notice Thrown when a SYA strategy token is not present in knownStables[]
     * @param token The strategy token address missing from knownStables[]
     */
    error StrategyTokenNotInKnownStables(address token);

    /**
     * @notice Thrown when rescue recipient is the zero address
     */
    error InvalidRecipient();

    /**
     * @notice Thrown when _settleResidualDelta encounters a token with no configured pool
     *         and no hardcoded fallback (not sUSDS or phUSD)
     * @param token The token address that has no settlement path
     */
    error UnsettledResidualForUnconfiguredToken(address token);

    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute the atomic arbitrage. Permissionless -- anyone (including MEV bots) can call.
     * @param params The calibrated parameters for the arbitrage
     */
    function execute(ExecuteParams calldata params) external;

    /**
     * @notice Rescue stranded ERC20 tokens from the contract (owner-only safety net)
     * @param token The ERC20 token to rescue
     * @param to The recipient address
     * @param amount The amount to rescue
     */
    function rescueToken(address token, address to, uint256 amount) external;

    /**
     * @notice Validates that every SYA strategy token is present in knownStables[]
     * @dev Reverts with StrategyTokenNotInKnownStables if any strategy token is missing.
     *      This is a one-directional check: knownStables[] CAN be a superset of SYA strategy
     *      tokens, but SYA strategy tokens must never be absent from knownStables[].
     */
    function validateKnownStablesCoverage() external view;
}
