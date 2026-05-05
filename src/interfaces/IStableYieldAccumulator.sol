// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStableYieldAccumulator
 * @notice Interface for the StableYieldAccumulator contract
 * @dev Defines all events, errors, and function signatures for the core logic
 */
interface IStableYieldAccumulator {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration for a reward token
     * @param decimals Number of decimal places for the token (max 18)
     * @param normalizedExchangeRate Exchange rate normalized to 18 decimals
     * @param paused Whether the token is currently paused
     */
    struct TokenConfig {
        uint8 decimals;
        uint256 normalizedExchangeRate;
        bool paused;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a yield strategy is added to the registry
     * @param strategy Address of the added yield strategy
     */
    event YieldStrategyAdded(address indexed strategy);

    /**
     * @notice Emitted when a yield strategy is removed from the registry
     * @param strategy Address of the removed yield strategy
     */
    event YieldStrategyRemoved(address indexed strategy);

    /**
     * @notice Emitted when a token configuration is set or updated
     * @param token Address of the token
     * @param decimals Number of decimal places
     * @param normalizedExchangeRate Exchange rate normalized to 18 decimals
     */
    event TokenConfigSet(address indexed token, uint8 decimals, uint256 normalizedExchangeRate);

    /**
     * @notice Emitted when a token is paused
     * @param token Address of the paused token
     */
    event TokenPaused(address indexed token);

    /**
     * @notice Emitted when a token is unpaused
     * @param token Address of the unpaused token
     */
    event TokenUnpaused(address indexed token);

    /**
     * @notice Emitted when the discount rate is updated
     * @param oldRate Previous discount rate in basis points
     * @param newRate New discount rate in basis points
     */
    event DiscountRateSet(uint256 oldRate, uint256 newRate);

    /**
     * @notice Emitted when the phlimbo address is updated
     * @param oldPhlimbo Previous phlimbo address
     * @param newPhlimbo New phlimbo address
     */
    event PhlimboUpdated(address indexed oldPhlimbo, address indexed newPhlimbo);

    /**
     * @notice Emitted when the nudge address is updated
     * @param oldNudge Previous nudge address (may be address(0))
     * @param newNudge New nudge address (may be address(0) to clear)
     */
    event NudgeUpdated(address indexed oldNudge, address indexed newNudge);

    /**
     * @notice Emitted when the nudge split percentage is updated
     * @param oldSplit Previous split percentage (0-100)
     * @param newSplit New split percentage (0-100)
     */
    event NudgeSplitUpdated(uint256 oldSplit, uint256 newSplit);

    /**
     * @notice Emitted when a user claims rewards
     * @param claimer Address that performed the claim
     * @param amountPaid Amount of reward token paid
     * @param strategiesClaimed Number of strategies claimed from
     */
    event RewardsClaimed(address indexed claimer, uint256 amountPaid, uint256 strategiesClaimed);

    /**
     * @notice Emitted when yield is collected from a strategy
     * @param strategy Address of the yield strategy
     * @param amount Amount collected
     */
    event RewardsCollected(address indexed strategy, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when a function is not yet implemented (red phase stub)
     */
    error NotImplemented();

    /**
     * @notice Thrown when a zero address is provided where it's not allowed
     */
    error ZeroAddress();

    /**
     * @notice Thrown when token decimals exceed 18
     */
    error InvalidDecimals();

    /**
     * @notice Thrown when discount rate exceeds 10000 basis points (100%)
     */
    error ExceedsMaxDiscount();

    /**
     * @notice Thrown when trying to interact with a strategy that's not registered
     */
    error StrategyNotRegistered();

    /**
     * @notice Thrown when trying to add a strategy that's already registered
     */
    error StrategyAlreadyRegistered();

    /**
     * @notice Thrown when claim() is called with an exemptStrategies entry that is not a registered strategy
     * @dev Distinct from StrategyNotRegistered so offchain callers can disambiguate
     *      "I passed garbage in exemptStrategies" from internal lookup failures
     */
    error ExemptStrategyNotRegistered();

    /**
     * @notice Thrown when trying to claim more than available pending rewards
     */
    error InsufficientPending();

    /**
     * @notice Thrown when trying to claim zero amount
     */
    error ZeroAmount();

    /**
     * @notice Thrown when caller has no valid NFT for claiming
     */
    error NoValidNFT();

    /**
     * @notice Thrown when actual yield payment is less than the caller's minimum acceptable amount
     * @dev Used for slippage protection against MEV front-running during claim
     */
    error InsufficientYield();

    /**
     * @notice Thrown when nudgeSplit is set above the maximum allowed value of 100
     */
    error InvalidNudgeSplit();

    /**
     * @notice Thrown during claim when nudgeSplit > 0 but the nudge address has not been set
     */
    error NudgeNotConfigured();

    /*//////////////////////////////////////////////////////////////
                        YIELD STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new yield strategy to the registry
     * @param strategy Address of the yield strategy to add
     * @param token Address of the underlying token that the strategy handles
     */
    function addYieldStrategy(address strategy, address token) external;

    /**
     * @notice Removes a yield strategy from the registry
     * @param strategy Address of the yield strategy to remove
     */
    function removeYieldStrategy(address strategy) external;

    /**
     * @notice Gets all registered yield strategies
     * @return Array of yield strategy addresses
     */
    function getYieldStrategies() external view returns (address[] memory);

    /**
     * @notice Gets the token address associated with a yield strategy
     * @param strategy Address of the yield strategy
     * @return Address of the token the strategy handles
     */
    function strategyTokens(address strategy) external view returns (address);

    /*//////////////////////////////////////////////////////////////
                        TOKEN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets or updates the configuration for a token
     * @param token Address of the token
     * @param decimals Number of decimal places (must be <= 18)
     * @param normalizedExchangeRate Exchange rate normalized to 18 decimals
     */
    function setTokenConfig(address token, uint8 decimals, uint256 normalizedExchangeRate) external;

    /**
     * @notice Pauses a token, preventing claims with it
     * @param token Address of the token to pause
     */
    function pauseToken(address token) external;

    /**
     * @notice Unpauses a token, allowing claims with it
     * @param token Address of the token to unpause
     */
    function unpauseToken(address token) external;

    /**
     * @notice Gets the configuration for a token
     * @param token Address of the token
     * @return TokenConfig struct with decimals, normalizedExchangeRate, and paused status
     */
    function getTokenConfig(address token) external view returns (TokenConfig memory);

    /*//////////////////////////////////////////////////////////////
                            DISCOUNT RATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the discount rate for claims
     * @param rate Discount rate in basis points (e.g., 200 = 2%)
     */
    function setDiscountRate(uint256 rate) external;

    /**
     * @notice Gets the current discount rate
     * @return Discount rate in basis points
     */
    function getDiscountRate() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        PHLIMBO MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the phlimbo address where claimed reward tokens are transferred
     * @param _phlimbo Address of the Phlimbo contract
     */
    function setPhlimbo(address _phlimbo) external;

    /**
     * @notice Gets the current phlimbo address
     * @return Address of the Phlimbo contract
     */
    function phlimbo() external view returns (address);

    /**
     * @notice Sets the minter address that holds deposits in yield strategies
     * @param _minter Address of the minter contract
     */
    function setMinter(address _minter) external;

    /**
     * @notice Gets the current minter address
     * @return Address of the minter contract
     */
    function minterAddress() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                            NUDGE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the auxiliary "nudge" recipient that receives a configurable share of every claim payment
     * @dev May be set to address(0) to clear. While the address is unset, nudgeSplit must remain 0
     *      or claim() will revert with NudgeNotConfigured.
     * @param _nudge Address that receives the nudge share of claim payments
     */
    function setNudgeAddress(address _nudge) external;

    /**
     * @notice Sets the percentage of each claim payment routed to the nudge address
     * @dev Must be in the inclusive range [0, 100]. Reverts with InvalidNudgeSplit otherwise.
     *      A value of 0 (the default) preserves pre-existing behavior (full payment to phlimbo).
     *      A value of 100 routes the full payment to the nudge address and skips the phlimbo collectReward call.
     * @param _split Percentage in the inclusive range [0, 100]
     */
    function setNudgeSplit(uint256 _split) external;

    /**
     * @notice Gets the current nudge recipient address
     * @return Address of the nudge recipient (address(0) if unset)
     */
    function nudge() external view returns (address);

    /**
     * @notice Gets the current nudge split percentage
     * @return Split percentage in the inclusive range [0, 100]
     */
    function nudgeSplit() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            CLAIM MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the reward token address used for claim payments
     * @return Address of the reward token (e.g., USDC)
     */
    function rewardToken() external view returns (address);

    /**
     * @notice Claims all pending yield from all strategies by paying with reward token
     * @dev Full flow:
     *      1. Validate every entry in exemptStrategies is currently registered (BEFORE the NFT burn)
     *      2. Verify caller holds a valid NFT at the given index and burn 1 unit
     *      3. Iterate registered strategies, skipping any present in exemptStrategies
     *      4. Calculate total pending yield (normalized) from non-exempt strategies
     *      5. Apply discount to get claimer payment
     *      6. TransferFrom claimer to phlimbo
     *      7. WithdrawFrom each non-exempt strategy to claimer
     * @param nftIndex The dispatcher config index in NFTMinter identifying which NFT to validate and burn
     * @param minRewardTokenSupplied Minimum acceptable payment amount in reward token decimals.
     *        Reverts with InsufficientYield if actual payment is less than this value.
     *        Pass 0 to disable slippage protection.
     * @param exemptStrategies List of registered strategies to skip during the iteration.
     *        Empty array preserves pre-existing behavior (no filtering).
     *        Each entry must satisfy isRegisteredStrategy[entry] == true or the call reverts
     *        with ExemptStrategyNotRegistered. Validation runs before the NFT is burned so a
     *        bad input does not consume the caller's NFT. Intended use: route around a
     *        misbehaving strategy (e.g. one whose withdrawFrom reverts) until owner remediation
     *        via removeYieldStrategy or per-token paused flag.
     */
    function claim(uint256 nftIndex, uint256 minRewardTokenSupplied, address[] calldata exemptStrategies) external;

    /**
     * @notice Calculates how much the claimer would pay for total pending yield
     * @dev Returns the discounted amount in reward token decimals. Mirrors claim() so
     *      claimers can preview the payment they'll commit to with the same exemptions
     *      they'll pass to claim() (used to compute minRewardTokenSupplied for slippage).
     * @param exemptStrategies List of registered strategies to skip during the calculation.
     *        Empty array preserves pre-existing behavior. Each entry must satisfy
     *        isRegisteredStrategy[entry] == true or the call reverts with
     *        ExemptStrategyNotRegistered.
     * @return Amount of reward token claimer would pay
     */
    function calculateClaimAmount(address[] calldata exemptStrategies) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        YIELD CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the pending yield for a specific strategy
     * @dev Returns yield in the strategy's native token decimals (NOT normalized)
     * @param strategy Address of the yield strategy
     * @return Pending yield amount in native token decimals
     */
    function getYield(address strategy) external view returns (uint256);

    /**
     * @notice Gets the total pending yield across all strategies
     * @dev Returns yield normalized to 18 decimals for cross-token comparison
     * @return Total pending yield normalized to 18 decimals
     */
    function getTotalYield() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        NFT MINTER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the NFTMinter contract address for claim gating
     * @param _nftMinter Address of the NFTMinter ERC1155 contract
     */
    function setNFTMinter(address _nftMinter) external;

    /**
     * @notice Gets the current NFTMinter address
     * @return Address of the NFTMinter contract
     */
    function nftMinter() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                        BOT HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if a specific caller can claim based on NFT holdings
     * @dev Returns true if the caller holds any valid NFT from the minter
     * @param caller Address to check
     * @return True if the caller holds a valid NFT
     */
    function canClaim(address caller) external view returns (bool);
}
