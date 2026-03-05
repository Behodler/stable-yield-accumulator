// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "pauser/interfaces/IPausable.sol";
import "./interfaces/IStableYieldAccumulator.sol";
import "vault/interfaces/IYieldStrategy.sol";
import "phlimbo-ea/interfaces/IPhlimbo.sol";
import "yield-claim-nft/interfaces/INFTMinter.sol";

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
 * 5. **NFT Gate** - Claims require holding a valid NFT from the NFTMinter contract; exactly 1 NFT is burned per claim
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
                        NFT MINTER STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC1155 NFTMinter contract address for claim gating
     * @dev Claims require holding at least 1 NFT from this contract; exactly 1 is burned per claim
     */
    address public nftMinter;

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

    /**
     * @notice Emitted when the NFT minter address is updated
     * @param oldNFTMinter Previous NFT minter address
     * @param newNFTMinter New NFT minter address
     */
    event NFTMinterUpdated(address indexed oldNFTMinter, address indexed newNFTMinter);

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
     */
    function pause() external override onlyPauser {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming normal operations
     * @dev Callable by EITHER the owner OR the pauser (Behodler3 pattern)
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
     * @param token Address of the token to pause
     */
    function pauseToken(address token) external override onlyOwner {
        tokenConfigs[token].paused = true;
        emit TokenPaused(token);
    }

    /**
     * @notice Unpauses a token, allowing claims with it
     * @param token Address of the token to unpause
     */
    function unpauseToken(address token) external override onlyOwner {
        tokenConfigs[token].paused = false;
        emit TokenUnpaused(token);
    }

    /**
     * @notice Gets the configuration for a token
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
     * @param _rewardToken Address of the reward token (e.g., USDC)
     */
    function setRewardToken(address _rewardToken) external onlyOwner {
        if (_rewardToken == address(0)) revert ZeroAddress();
        rewardToken = _rewardToken;
    }

    /**
     * @notice Approves Phlimbo to spend reward tokens from this contract
     * @param amount Amount of reward tokens to approve
     */
    function approvePhlimbo(uint256 amount) external onlyOwner {
        if (phlimbo == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert ZeroAddress();

        IERC20(rewardToken).forceApprove(phlimbo, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        NFT MINTER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the NFTMinter contract address for claim gating
     * @dev The NFTMinter must be an ERC1155 contract that also implements INFTMinter.
     *      The StableYieldAccumulator must be registered as an authorized burner on the NFTMinter.
     * @param _nftMinter Address of the NFTMinter contract
     */
    function setNFTMinter(address _nftMinter) external onlyOwner {
        address oldNFTMinter = nftMinter;
        nftMinter = _nftMinter;
        emit NFTMinterUpdated(oldNFTMinter, _nftMinter);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims all pending yield from all strategies by paying with reward token
     * @dev Full claim flow:
     *      1. Verify caller holds a valid NFT and burn 1 unit
     *      2. Calculate total pending yield across all strategies (normalized to 18 decimals)
     *      3. Apply discount to get claimer payment amount
     *      4. Transfer rewardToken FROM claimer TO phlimbo
     *      5. Withdraw yield FROM each strategy TO claimer
     */
    function claim(uint256 nftIndex, uint256 minRewardTokenSupplied) external override whenNotPaused nonReentrant {
        if (phlimbo == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert ZeroAddress();
        if (minterAddress == address(0)) revert ZeroAddress();

        // NFT gate: verify caller holds a valid NFT and burn 1 unit
        _validateAndBurnNFT(msg.sender, nftIndex);

        uint256 totalNormalizedYield = 0;
        uint256 strategiesWithYield = 0;

        // Single pass: withdraw yield from each strategy and accumulate total
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (token == address(0)) continue;

            if (tokenConfigs[token].paused) continue;

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
        uint256 claimerPayment = totalNormalizedYield * (10000 - discountRate) / 10000;
        uint256 actualPayment = _denormalizeAmount(claimerPayment, rewardToken);

        // Slippage protection: revert if actual payment is below caller's minimum
        if (actualPayment < minRewardTokenSupplied) revert InsufficientYield();

        // Transfer reward tokens FROM claimer TO this contract, then have Phlimbo collect them
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), actualPayment);
        IPhlimbo(phlimbo).collectReward(actualPayment);

        emit RewardsClaimed(msg.sender, actualPayment, strategiesWithYield);
    }

    /**
     * @notice Internal helper to validate NFT ownership and burn 1 unit
     * @dev Uses the provided index for O(1) lookup instead of iterating all dispatcher configs
     * @param caller The address to check for NFT ownership
     * @param index The dispatcher config index in NFTMinter
     */
    function _validateAndBurnNFT(address caller, uint256 index) internal {
        require(nftMinter != address(0), "NFT minter not configured");
        INFTMinter minter = INFTMinter(nftMinter);

        (address dispatcher, , ) = minter.configs(index);
        if (dispatcher == address(0)) revert NoValidNFT();

        uint256 tokenId = minter.dispatcherTokenIdOverride(dispatcher);
        if (tokenId == 0) {
            tokenId = index;
        }

        if (IERC1155(nftMinter).balanceOf(caller, tokenId) > 0) {
            minter.burn(caller, tokenId, 1);
        } else {
            revert NoValidNFT();
        }
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
     * @notice Internal helper to get normalized yield for a specific strategy
     * @param strategy Address of the yield strategy
     * @param token Address of the strategy's underlying token
     * @return Yield amount normalized to 18 decimals
     */
    function _getNormalizedYieldForStrategy(address strategy, address token) internal view returns (uint256) {
        uint256 yield = _getYieldForStrategy(strategy, token);
        if (yield > 0) {
            return _normalizeAmount(yield, token);
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
                        BOT HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if a specific caller can claim based on NFT holdings
     * @dev Returns true if the caller holds any valid NFT from the minter
     * @param caller Address to check
     * @return True if the caller holds a valid NFT
     */
    function canClaim(address caller) external view returns (bool) {
        if (nftMinter == address(0)) {
            return false;
        }

        INFTMinter minter = INFTMinter(nftMinter);
        uint256 count = minter.nextIndex();
        for (uint256 i = 1; i < count; i++) {
            (address dispatcher, , ) = minter.configs(i);
            if (dispatcher == address(0)) continue;

            uint256 tokenId = minter.dispatcherTokenIdOverride(dispatcher);
            if (tokenId == 0) {
                tokenId = i;
            }

            if (IERC1155(nftMinter).balanceOf(caller, tokenId) > 0) {
                return true;
            }
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the pending yield for a specific strategy
     * @param strategy Address of the yield strategy
     * @return Pending yield amount (in native token decimals)
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
     * @return Total pending yield normalized to 18 decimals
     */
    function getTotalYield() external view override returns (uint256) {
        if (minterAddress == address(0)) return 0;

        uint256 total = 0;
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (token == address(0)) continue;

            total += _getNormalizedYieldForStrategy(strategy, token);
        }
        return total;
    }
}
