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
     * @notice Emitted when a user claims rewards
     * @param claimer Address that performed the claim
     * @param amountPaid Amount of reward token paid
     * @param strategiesClaimed Number of strategies claimed from
     */
    event RewardsClaimed(
        address indexed claimer,
        uint256 amountPaid,
        uint256 strategiesClaimed
    );

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
     * @notice Thrown when trying to claim more than available pending rewards
     */
    error InsufficientPending();

    /**
     * @notice Thrown when a token is paused and an operation is attempted
     */
    error TokenIsPaused();

    /**
     * @notice Thrown when trying to claim zero amount
     */
    error ZeroAmount();

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
                            CLAIM MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims all pending yield from all strategies by paying with reward token
     * @dev Full flow:
     *      1. Calculate total pending yield (normalized)
     *      2. Apply discount to get claimer payment
     *      3. TransferFrom claimer to phlimbo
     *      4. WithdrawFrom each strategy to claimer
     */
    function claim() external;

    /**
     * @notice Calculates how much the claimer would pay for total pending yield
     * @dev Returns the discounted amount in reward token decimals
     * @return Amount of reward token claimer would pay
     */
    function calculateClaimAmount()
        external
        view
        returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        YIELD CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the pending yield for a specific strategy
     * @param strategy Address of the yield strategy
     * @return Amount of pending yield
     */
    function getYield(address strategy) external view returns (uint256);

    /**
     * @notice Gets the total pending yield across all strategies
     * @return Total amount of pending yield
     */
    function getTotalYield() external view returns (uint256);
}
