// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "pauser/interfaces/IPausable.sol";
import "./interfaces/IStableYieldAccumulator.sol";
import "vault/interfaces/IYieldStrategy.sol";
import "phlimbo-ea/interfaces/IPhlimbo.sol";

/**
 * @title StableYieldAccumulator
 * @notice Consolidates yield strategy rewards into a single stablecoin for simplified distribution
 * @dev Implements pausable functionality following the Behodler3 pattern where both owner and pauser
 *      can unpause the contract, providing redundancy in case the pauser is compromised or unavailable.
 *
 * ## Pausable Architecture
 *
 * This contract inherits from both OpenZeppelin's Pausable and implements IPausable from the pauser
 * dependency. The pausable functionality provides an emergency stop mechanism that can halt
 * state-changing operations when needed.
 *
 * ### Pause Permissions
 * - **Pause**: Only the designated pauser address can pause the contract
 * - **Unpause**: Both the owner AND the pauser can unpause (Behodler3 pattern for redundancy)
 *
 * ### Protected Functions
 * State-changing functions that could pose risk are protected with the `whenNotPaused` modifier.
 * View functions remain operational even when paused to allow monitoring and inspection.
 *
 * ## Purpose and Architecture
 *
 * In the Phoenix architecture, multiple yield strategies exist, each corresponding to a different
 * stablecoin. Phlimbo distributes these rewards, but as yield strategies grow in number, this becomes
 * unwieldy and gas-intensive. Additionally, Limbo stakers would need to manage many different reward tokens.
 *
 * StableYieldAccumulator consolidates all yield strategy rewards into a single stablecoin before
 * Phlimbo distribution. This provides:
 *
 * 1. **Simplified rewards** - Limbo stakers only deal with 2 tokens: phUSD and one stablecoin
 * 2. **Future-proof Phlimbo** - No upgrades/migrations needed when yield strategies change
 * 3. **Decentralized conversion** - External actors perform the token swaps, not the protocol
 *
 * ### How It Works
 *
 * 1. **Yield Strategy Registry** - Maintains a dynamic list of yield strategies
 * 2. **Exchange Rate Mappings** - Tracks decimal places (6 for USDC, 18 for Dola, etc.) and exchange rates
 * 3. **No Oracles/AMMs** - Uses assumed 1:1 exchange rates for stablecoins (owner can adjust for permanent depegs)
 * 4. **Claim Mechanism** - External users swap their reward token holdings for pending yield strategy rewards
 */
contract StableYieldAccumulator is Ownable, Pausable, ReentrancyGuard, IPausable, IStableYieldAccumulator {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Address authorized to pause the contract
     * @dev Starts as address(0), requiring explicit setPauser() call by owner
     *      This prevents accidental pausing before a pauser is designated
     *      The public visibility satisfies IPausable.pauser() getter requirement
     */
    address public pauser;

    /**
     * @notice The single stablecoin used for consolidated reward distribution
     * @dev This is the token that claimers pay with to receive yield strategy rewards
     */
    address public rewardToken;

    /**
     * @notice Dynamic array tracking all registered yield strategies
     * @dev Used to iterate over strategies for yield collection and calculation
     */
    address[] public yieldStrategies;

    /**
     * @notice Mapping of token addresses to their configuration
     * @dev Stores decimals, normalized exchange rate, and pause status for each token
     */
    mapping(address => TokenConfig) public tokenConfigs;

    /**
     * @notice Global discount rate applied to all claims
     * @dev Stored in basis points (e.g., 200 = 2%), max 10000 (100%)
     */
    uint256 public discountRate;

    /**
     * @notice Address where claimed reward tokens are transferred to
     * @dev This is the Phlimbo contract that distributes rewards to Limbo stakers
     */
    address public phlimbo;

    /**
     * @notice Address of the minter contract that holds deposits in yield strategies
     * @dev Used to query yield strategies for the minter's accumulated yield
     */
    address public minterAddress;

    /**
     * @notice Mapping to check if a strategy is registered (O(1) lookup)
     * @dev Used to avoid O(n) iteration for duplicate/existence checks
     */
    mapping(address => bool) public isRegisteredStrategy;

    /**
     * @notice Mapping from strategy address to its underlying token address
     * @dev Each yield strategy handles a specific token (e.g., USDC, USDT, DAI)
     */
    mapping(address => address) public strategyTokens;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the pauser address is updated
     * @param oldPauser Previous pauser address (may be address(0))
     * @param newPauser New pauser address (may be address(0) to remove pauser)
     */
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);

    /**
     * @notice Emitted when the minter address is updated
     * @param oldMinter Previous minter address (may be address(0))
     * @param newMinter New minter address
     */
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the contract with msg.sender as owner
     * @dev Pauser starts as address(0) and must be explicitly set via setPauser()
     */
    constructor() Ownable(msg.sender) {
        // Pauser defaults to address(0), requiring explicit initialization
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to only the designated pauser
     * @dev Reverts with descriptive error if caller is not the pauser
     */
    modifier onlyPauser() {
        require(msg.sender == pauser, "Only pauser can call this function");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets or updates the authorized pauser address
     * @dev Only callable by the contract owner
     *      Emits PauserUpdated event with old and new pauser addresses
     *      Can be set to address(0) to effectively disable pausing
     * @param _pauser New pauser address (use address(0) to remove pausing capability)
     */
    function setPauser(address _pauser) external onlyOwner {
        address oldPauser = pauser;
        pauser = _pauser;
        emit PauserUpdated(oldPauser, _pauser);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE/UNPAUSE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pauses all state-changing operations protected by whenNotPaused
     * @dev Only callable by the designated pauser address
     *      Reverts if caller is not the pauser
     *      Reverts if contract is already paused
     *      Calls internal OpenZeppelin _pause() function
     *      Emits Paused event from OpenZeppelin Pausable
     *
     * ## Usage
     * Should be called in emergency situations where contract operations need to be halted:
     * - Security vulnerability discovered
     * - Unexpected behavior in yield strategies
     * - Need to prevent further state changes during investigation
     */
    function pause() external override onlyPauser {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming normal operations
     * @dev Callable by EITHER the owner OR the pauser (Behodler3 pattern)
     *      This dual-authority approach provides redundancy:
     *      - If pauser is compromised/unavailable, owner can restore operations
     *      - If owner is unavailable, pauser can restore operations
     *      Reverts if contract is not paused
     *      Calls internal OpenZeppelin _unpause() function
     *      Emits Unpaused event from OpenZeppelin Pausable
     *
     * ## Rationale for Dual Authority
     * Following the Behodler3 pattern, both owner and pauser can unpause to ensure the contract
     * can always be restored to operational state, even if one of the authorized addresses is
     * compromised or unavailable.
     */
    function unpause() external override {
        require(msg.sender == owner() || msg.sender == pauser, "Only owner or pauser can unpause");
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    YIELD STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new yield strategy to the registry
     * @dev Validates zero address and duplicate registration
     * @param strategy Address of the yield strategy to add
     * @param token Address of the underlying token that the strategy handles
     */
    function addYieldStrategy(address strategy, address token) external override onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (isRegisteredStrategy[strategy]) revert StrategyAlreadyRegistered();

        yieldStrategies.push(strategy);
        isRegisteredStrategy[strategy] = true;
        strategyTokens[strategy] = token;
        emit YieldStrategyAdded(strategy);
    }

    /**
     * @notice Removes a yield strategy from the registry
     * @dev Validates existence and removes from array by swapping with last element
     * @param strategy Address of the yield strategy to remove
     */
    function removeYieldStrategy(address strategy) external override onlyOwner {
        if (!isRegisteredStrategy[strategy]) revert StrategyNotRegistered();

        // Find and remove strategy from array
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            if (yieldStrategies[i] == strategy) {
                // Swap with last element and pop
                yieldStrategies[i] = yieldStrategies[yieldStrategies.length - 1];
                yieldStrategies.pop();
                break;
            }
        }

        isRegisteredStrategy[strategy] = false;
        delete strategyTokens[strategy];
        emit YieldStrategyRemoved(strategy);
    }

    /**
     * @notice Gets all registered yield strategies
     * @return Array of yield strategy addresses
     */
    function getYieldStrategies() external view override returns (address[] memory) {
        return yieldStrategies;
    }

    /*//////////////////////////////////////////////////////////////
                        TOKEN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets or updates the configuration for a token
     * @dev Validates zero address and decimal constraints
     * @param token Address of the token
     * @param decimals Number of decimal places (must be <= 18)
     * @param normalizedExchangeRate Exchange rate normalized to 18 decimals
     */
    function setTokenConfig(address token, uint8 decimals, uint256 normalizedExchangeRate)
        external
        override
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (decimals > 18) revert InvalidDecimals();

        tokenConfigs[token].decimals = decimals;
        tokenConfigs[token].normalizedExchangeRate = normalizedExchangeRate;
        emit TokenConfigSet(token, decimals, normalizedExchangeRate);
    }

    /**
     * @notice Pauses a token, preventing claims with it
     * @dev Sets the paused flag in tokenConfigs mapping
     * @param token Address of the token to pause
     */
    function pauseToken(address token) external override onlyOwner {
        tokenConfigs[token].paused = true;
        emit TokenPaused(token);
    }

    /**
     * @notice Unpauses a token, allowing claims with it
     * @dev Clears the paused flag in tokenConfigs mapping
     * @param token Address of the token to unpause
     */
    function unpauseToken(address token) external override onlyOwner {
        tokenConfigs[token].paused = false;
        emit TokenUnpaused(token);
    }

    /**
     * @notice Gets the configuration for a token
     * @dev Returns stored TokenConfig from mapping
     * @param token Address of the token
     * @return TokenConfig struct with decimals, normalizedExchangeRate, and paused status
     */
    function getTokenConfig(address token) external view override returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    /*//////////////////////////////////////////////////////////////
                            DISCOUNT RATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the discount rate for claims
     * @dev Validates rate does not exceed 10000 basis points (100%)
     * @param rate Discount rate in basis points (e.g., 200 = 2%)
     */
    function setDiscountRate(uint256 rate) external override onlyOwner {
        if (rate > 10000) revert ExceedsMaxDiscount();

        uint256 oldRate = discountRate;
        discountRate = rate;
        emit DiscountRateSet(oldRate, rate);
    }

    /**
     * @notice Gets the current discount rate
     * @return Discount rate in basis points
     */
    function getDiscountRate() external view override returns (uint256) {
        return discountRate;
    }

    /*//////////////////////////////////////////////////////////////
                        PHLIMBO MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the phlimbo address where claimed reward tokens are transferred
     * @dev Validates non-zero address
     * @param _phlimbo Address of the Phlimbo contract
     */
    function setPhlimbo(address _phlimbo) external onlyOwner {
        if (_phlimbo == address(0)) revert ZeroAddress();

        address oldPhlimbo = phlimbo;
        phlimbo = _phlimbo;
        emit PhlimboUpdated(oldPhlimbo, _phlimbo);
    }

    /**
     * @notice Sets the minter address that holds deposits in yield strategies
     * @dev Used for querying yield from strategies
     * @param _minter Address of the minter contract
     */
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert ZeroAddress();

        address oldMinter = minterAddress;
        minterAddress = _minter;
        emit MinterUpdated(oldMinter, _minter);
    }

    /**
     * @notice Sets the reward token address
     * @dev This is the single stablecoin used for consolidated reward distribution
     * @param _rewardToken Address of the reward token (e.g., USDC)
     */
    function setRewardToken(address _rewardToken) external onlyOwner {
        if (_rewardToken == address(0)) revert ZeroAddress();
        rewardToken = _rewardToken;
    }

    /**
     * @notice Approves Phlimbo to spend reward tokens from this contract
     * @dev Only callable by owner. Required for Phlimbo to pull tokens via collectReward
     * @param amount Amount of reward tokens to approve
     */
    function approvePhlimbo(uint256 amount) external onlyOwner {
        if (phlimbo == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert ZeroAddress();

        IERC20(rewardToken).approve(phlimbo, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims all pending yield from all strategies by paying with reward token
     * @dev Full claim flow:
     *      1. Calculate total pending yield across all strategies (normalized to 18 decimals)
     *      2. Apply discount to get claimer payment amount
     *      3. Transfer rewardToken FROM claimer TO phlimbo
     *      4. Withdraw yield FROM each strategy TO claimer
     *
     * Example with 2% discount:
     * - Strategy A has 10 USDT pending, Strategy B has 5 USDS pending
     * - Total = 15 USD equivalent (normalized)
     * - Claimer pays: 15 * 0.98 = 14.7 USDC to phlimbo
     * - Claimer receives: 10 USDT + 5 USDS from strategies
     */
    function claim() external override whenNotPaused nonReentrant {
        if (phlimbo == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert ZeroAddress();
        if (minterAddress == address(0)) revert ZeroAddress();

        uint256 totalNormalizedYield = 0;
        uint256 strategiesWithYield = 0;

        // Single pass: withdraw yield from each strategy and accumulate total
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (token == address(0)) continue;

            if (tokenConfigs[token].paused) revert TokenIsPaused();

            uint256 yield = _getYieldForStrategy(strategy, token);
            if (yield > 0) {
                // Withdraw yield from strategy to claimer
                IYieldStrategy(strategy).withdrawFrom(token, minterAddress, yield, msg.sender);
                emit RewardsCollected(strategy, yield);

                // Accumulate normalized yield for payment calculation
                totalNormalizedYield += _normalizeAmount(yield, token);
                strategiesWithYield++;
            }
        }

        if (totalNormalizedYield == 0) revert ZeroAmount();

        // Calculate and collect claimer payment (apply discount)
        // discountRate is in basis points (e.g., 200 = 2%)
        uint256 claimerPayment = totalNormalizedYield * (10000 - discountRate) / 10000;
        uint256 actualPayment = _denormalizeAmount(claimerPayment, rewardToken);

        // Transfer reward tokens FROM claimer TO this contract, then have Phlimbo collect them
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), actualPayment);
        IPhlimbo(phlimbo).collectReward(actualPayment);

        emit RewardsClaimed(msg.sender, actualPayment, strategiesWithYield);
    }

    /**
     * @notice Internal helper to get yield for a specific strategy
     * @param strategy Address of the yield strategy
     * @param token Address of the strategy's underlying token
     * @return yield The pending yield amount
     */
    function _getYieldForStrategy(address strategy, address token) internal view returns (uint256) {
        IYieldStrategy yieldStrategy = IYieldStrategy(strategy);
        uint256 totalBalance = yieldStrategy.totalBalanceOf(token, minterAddress);
        uint256 principal = yieldStrategy.principalOf(token, minterAddress);

        if (totalBalance > principal) {
            return totalBalance - principal;
        }
        return 0;
    }

    /**
     * @notice Normalizes an amount from token decimals to 18 decimals
     * @param amount The amount in token decimals
     * @param token The token address to get decimals from
     * @return The amount normalized to 18 decimals
     */
    function _normalizeAmount(uint256 amount, address token) internal view returns (uint256) {
        uint8 decimals = tokenConfigs[token].decimals;
        uint256 exchangeRate = tokenConfigs[token].normalizedExchangeRate;

        // If no config set, assume 18 decimals and 1:1 rate
        if (decimals == 0 && exchangeRate == 0) {
            return amount;
        }

        // Scale to 18 decimals
        uint256 scaled = amount;
        if (decimals < 18) {
            scaled = amount * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            scaled = amount / (10 ** (decimals - 18));
        }

        // Apply exchange rate (already normalized to 18 decimals)
        // exchangeRate of 1e18 means 1:1
        if (exchangeRate > 0 && exchangeRate != 1e18) {
            scaled = scaled * exchangeRate / 1e18;
        }

        return scaled;
    }

    /**
     * @notice Denormalizes an amount from 18 decimals to token decimals
     * @param amount The amount in 18 decimals
     * @param token The token address to get decimals from
     * @return The amount in token decimals
     */
    function _denormalizeAmount(uint256 amount, address token) internal view returns (uint256) {
        uint8 decimals = tokenConfigs[token].decimals;
        uint256 exchangeRate = tokenConfigs[token].normalizedExchangeRate;

        // If no config set, assume 18 decimals and 1:1 rate
        if (decimals == 0 && exchangeRate == 0) {
            return amount;
        }

        // Reverse exchange rate first
        uint256 scaled = amount;
        if (exchangeRate > 0 && exchangeRate != 1e18) {
            scaled = scaled * 1e18 / exchangeRate;
        }

        // Scale from 18 decimals to token decimals
        if (decimals < 18) {
            scaled = scaled / (10 ** (18 - decimals));
        } else if (decimals > 18) {
            scaled = scaled * (10 ** (decimals - 18));
        }

        return scaled;
    }

    /**
     * @notice Calculates how much the claimer would pay for total pending yield
     * @dev Returns the discounted amount in reward token that claimer would pay
     * @return paymentAmount Amount of reward token claimer would pay (in reward token decimals)
     */
    function calculateClaimAmount()
        external
        view
        override
        returns (uint256)
    {
        if (minterAddress == address(0)) return 0;

        uint256 totalNormalizedYield = 0;

        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (token == address(0)) continue;
            if (tokenConfigs[token].paused) continue;

            uint256 yield = _getYieldForStrategy(strategy, token);
            if (yield > 0) {
                totalNormalizedYield += _normalizeAmount(yield, token);
            }
        }

        if (totalNormalizedYield == 0) return 0;

        // Apply discount
        uint256 claimerPayment = totalNormalizedYield * (10000 - discountRate) / 10000;

        // Denormalize to reward token decimals
        return _denormalizeAmount(claimerPayment, rewardToken);
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the pending yield for a specific strategy
     * @dev Simplified implementation - returns 0 as yield strategies track their own balances
     *      In production, this would query the strategy's interface for pending yield
     * @param strategy Address of the yield strategy
     * @return Pending yield amount (currently 0 as strategies handle their own accounting)
     */
    function getYield(address strategy) external view override returns (uint256) {
        if (!isRegisteredStrategy[strategy]) revert StrategyNotRegistered();
        if (minterAddress == address(0)) return 0;

        address token = strategyTokens[strategy];
        if (token == address(0)) return 0;

        // Query the yield strategy for minter's total balance and principal
        IYieldStrategy yieldStrategy = IYieldStrategy(strategy);
        uint256 totalBalance = yieldStrategy.totalBalanceOf(token, minterAddress);
        uint256 principal = yieldStrategy.principalOf(token, minterAddress);

        // Yield = total balance - principal (accumulated yield)
        if (totalBalance > principal) {
            return totalBalance - principal;
        }
        return 0;
    }

    /**
     * @notice Gets the total pending yield across all strategies
     * @dev Sums getYield() across all registered strategies
     * @return Total pending yield amount
     */
    function getTotalYield() external view override returns (uint256) {
        if (minterAddress == address(0)) return 0;

        uint256 total = 0;
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (token == address(0)) continue;

            // Query each strategy for minter's yield
            IYieldStrategy yieldStrategy = IYieldStrategy(strategy);
            uint256 totalBalance = yieldStrategy.totalBalanceOf(token, minterAddress);
            uint256 principal = yieldStrategy.principalOf(token, minterAddress);

            if (totalBalance > principal) {
                total += totalBalance - principal;
            }
        }
        return total;
    }
}
