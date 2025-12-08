// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "pauser/interfaces/IPausable.sol";
import "./interfaces/IStableYieldAccumulator.sol";

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
contract StableYieldAccumulator is Ownable, Pausable, IPausable, IStableYieldAccumulator {
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
     * @notice Tracks the original principal deposited to each yield strategy
     * @dev Used to calculate yield as: totalDeposits - principalDeposited
     */
    mapping(address => uint256) public principalDeposited;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the pauser address is updated
     * @param oldPauser Previous pauser address (may be address(0))
     * @param newPauser New pauser address (may be address(0) to remove pauser)
     */
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);

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
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param strategy Address of the yield strategy to add
     */
    function addYieldStrategy(address strategy) external override onlyOwner {
        revert NotImplemented();
    }

    /**
     * @notice Removes a yield strategy from the registry
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param strategy Address of the yield strategy to remove
     */
    function removeYieldStrategy(address strategy) external override onlyOwner {
        revert NotImplemented();
    }

    /**
     * @notice Gets all registered yield strategies
     * @dev RED PHASE STUB - Returns empty array
     * @return Empty array of yield strategy addresses
     */
    function getYieldStrategies() external view override returns (address[] memory) {
        address[] memory empty;
        return empty;
    }

    /*//////////////////////////////////////////////////////////////
                        TOKEN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets or updates the configuration for a token
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param token Address of the token
     * @param decimals Number of decimal places
     * @param normalizedExchangeRate Exchange rate normalized to 18 decimals
     */
    function setTokenConfig(address token, uint8 decimals, uint256 normalizedExchangeRate)
        external
        override
        onlyOwner
    {
        revert NotImplemented();
    }

    /**
     * @notice Pauses a token, preventing claims with it
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param token Address of the token to pause
     */
    function pauseToken(address token) external override onlyOwner {
        revert NotImplemented();
    }

    /**
     * @notice Unpauses a token, allowing claims with it
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param token Address of the token to unpause
     */
    function unpauseToken(address token) external override onlyOwner {
        revert NotImplemented();
    }

    /**
     * @notice Gets the configuration for a token
     * @dev RED PHASE STUB - Returns empty/zero values
     * @param token Address of the token
     * @return Empty TokenConfig struct
     */
    function getTokenConfig(address token) external view override returns (TokenConfig memory) {
        TokenConfig memory empty;
        return empty;
    }

    /*//////////////////////////////////////////////////////////////
                            DISCOUNT RATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the discount rate for claims
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param rate Discount rate in basis points
     */
    function setDiscountRate(uint256 rate) external override onlyOwner {
        revert NotImplemented();
    }

    /**
     * @notice Gets the current discount rate
     * @dev RED PHASE STUB - Returns 0
     * @return Zero
     */
    function getDiscountRate() external view override returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims pending yield from all strategies by paying with reward token
     * @dev RED PHASE STUB - Reverts with NotImplemented()
     * @param token Token to use for payment
     * @param amount Amount of reward token to pay
     */
    function claim(address token, uint256 amount) external override whenNotPaused {
        revert NotImplemented();
    }

    /**
     * @notice Calculates how much can be claimed for a given input amount
     * @dev RED PHASE STUB - Returns 0
     * @param token Token that would be used for payment
     * @param inputAmount Amount of reward token to pay
     * @return Zero
     */
    function calculateClaimAmount(address token, uint256 inputAmount)
        external
        view
        override
        returns (uint256)
    {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the pending yield for a specific strategy
     * @dev RED PHASE STUB - Returns 0
     * @param strategy Address of the yield strategy
     * @return Zero
     */
    function getYield(address strategy) external view override returns (uint256) {
        return 0;
    }

    /**
     * @notice Gets the total pending yield across all strategies
     * @dev RED PHASE STUB - Returns 0
     * @return Zero
     */
    function getTotalYield() external view override returns (uint256) {
        return 0;
    }

    /**
     * @notice Updates the principal amount for a strategy
     * @dev RED PHASE STUB - Does nothing
     * @param strategy Address of the yield strategy
     * @param amount Amount to track
     */
    function updatePrincipal(address strategy, uint256 amount) internal {
        // Stub - will be implemented in green phase
    }
}
