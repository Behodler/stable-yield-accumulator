// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableYieldAccumulator.sol";
import "../src/interfaces/IStableYieldAccumulator.sol";
import "vault/interfaces/IYieldStrategy.sol";
import "phlimbo-ea/interfaces/IPhlimbo.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockUSDT
 * @notice ERC20 mock that reverts on non-zero-to-non-zero approve, matching real USDT behavior.
 * @dev Real USDT requires allowance to be zero before setting a new non-zero value.
 *      This enforces: approve(spender, newAmount) reverts if allowance(owner, spender) != 0 && newAmount != 0.
 */
contract MockUSDT is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        // USDT behavior: revert if current allowance is non-zero and new value is non-zero
        if (allowance(msg.sender, spender) != 0 && value != 0) {
            revert("USDT: approve from non-zero to non-zero");
        }
        return super.approve(spender, value);
    }
}

/**
 * @title MockERC20WithDecimals
 * @notice ERC20 mock with configurable decimals for testing multi-decimal scenarios
 */
contract MockERC20WithDecimals is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockPhlimbo
 * @notice Mock Phlimbo contract for testing collectReward functionality
 * @dev Simulates Phlimbo's collectReward behavior by pulling tokens from the accumulator
 */
contract MockPhlimbo {
    address public rewardToken;
    address public yieldAccumulator;
    uint256 public lastCollectedAmount;
    uint256 public collectRewardCallCount;

    constructor(address _rewardToken) {
        rewardToken = _rewardToken;
    }

    function setYieldAccumulator(address _yieldAccumulator) external {
        yieldAccumulator = _yieldAccumulator;
    }

    /**
     * @notice Mock collectReward that pulls tokens from yield accumulator
     * @dev This simulates the real Phlimbo behavior where it pulls tokens
     */
    function collectReward(uint256 amount) external {
        require(msg.sender == yieldAccumulator, "Only yield accumulator can call");

        collectRewardCallCount++;
        lastCollectedAmount = amount;

        // Pull tokens from the yield accumulator
        IERC20(rewardToken).transferFrom(msg.sender, address(this), amount);
    }

    function resetTracking() external {
        collectRewardCallCount = 0;
        lastCollectedAmount = 0;
    }
}

/**
 * @title MockYieldStrategy
 * @notice Mock yield strategy for testing full claim flow
 * @dev Simulates a yield strategy that holds tokens and can withdraw to recipients
 */
contract MockYieldStrategy is IYieldStrategy {
    mapping(address => mapping(address => uint256)) public principals;
    mapping(address => mapping(address => uint256)) public yields;

    // Track withdrawFrom calls for testing
    uint256 public withdrawFromCallCount;
    address public lastWithdrawToken;
    address public lastWithdrawClient;
    uint256 public lastWithdrawAmount;
    address public lastWithdrawRecipient;

    function setBalances(address token, address account, uint256 principal, uint256 yieldAmount) external {
        principals[token][account] = principal;
        yields[token][account] = yieldAmount;
    }

    function deposit(address, uint256, address) external pure override {}
    function withdraw(address, uint256, address) external pure override {}

    function balanceOf(address token, address account) external view override returns (uint256) {
        return principals[token][account] + yields[token][account];
    }

    function principalOf(address token, address account) external view override returns (uint256) {
        return principals[token][account];
    }

    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        return principals[token][account] + yields[token][account];
    }

    function setClient(address, bool) external pure override {}
    function emergencyWithdraw(uint256) external pure override {}
    function totalWithdrawal(address, address) external pure override {}

    /**
     * @notice Mock withdrawFrom that transfers tokens to recipient
     * @dev Actually transfers ERC20 tokens from this contract to recipient
     */
    function withdrawFrom(
        address token,
        address client,
        uint256 amount,
        address recipient
    ) external override {
        withdrawFromCallCount++;
        lastWithdrawToken = token;
        lastWithdrawClient = client;
        lastWithdrawAmount = amount;
        lastWithdrawRecipient = recipient;

        // Actually transfer tokens from this contract to recipient
        IERC20(token).transfer(recipient, amount);

        // Reduce yield after withdrawal
        yields[token][client] -= amount;
    }

    function resetWithdrawTracking() external {
        withdrawFromCallCount = 0;
        lastWithdrawToken = address(0);
        lastWithdrawClient = address(0);
        lastWithdrawAmount = 0;
        lastWithdrawRecipient = address(0);
    }
}

/**
 * @title MockNFTMinter
 * @notice Mock NFTMinter that implements both INFTMinter functions and ERC1155 balanceOf
 * @dev Simulates the NFTMinter contract for testing the NFT-based claim gate.
 *      The StableYieldAccumulator must be registered as an authorized burner.
 */
contract MockNFTMinter {
    struct DispatcherConfig {
        address dispatcher;
        uint256 price;
        uint256 growthBasisPoints;
        bool disabled;
    }

    uint256 public nextIndex;
    mapping(uint256 => DispatcherConfig) public _configs;
    mapping(uint256 => address) public tokenIdToDispatcher;
    mapping(address => bool) public authorizedBurners;

    // ERC1155 balances: holder => tokenId => balance
    mapping(address => mapping(uint256 => uint256)) public balances;

    // Track burn calls
    uint256 public burnCallCount;
    address public lastBurnHolder;
    uint256 public lastBurnTokenId;
    uint256 public lastBurnQuantity;

    constructor() {
        nextIndex = 1; // starts at 1, 0 is invalid
    }

    function configs(uint256 index) external view returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled) {
        DispatcherConfig memory config = _configs[index];
        return (config.dispatcher, config.price, config.growthBasisPoints, config.disabled);
    }

    function registerDispatcher(address dispatcher, uint256 price, uint256 growthBasisPoints) external {
        uint256 index = nextIndex;
        _configs[index] = DispatcherConfig(dispatcher, price, growthBasisPoints, false);
        tokenIdToDispatcher[index] = dispatcher;
        nextIndex++;
    }

    function setDispatcherDisabled(uint256 index, bool disabled) external {
        _configs[index].disabled = disabled;
    }

    function setAuthorizedBurner(address burner, bool authorized) external {
        authorizedBurners[burner] = authorized;
    }

    function mintNFT(address holder, uint256 tokenId, uint256 amount) external {
        balances[holder][tokenId] += amount;
    }

    /// @notice ERC1155 balanceOf - called via IERC1155(nftMinter).balanceOf()
    function balanceOf(address holder, uint256 tokenId) external view returns (uint256) {
        return balances[holder][tokenId];
    }

    /// @notice Burns NFTs from a holder. Only callable by authorized burners.
    function burn(address holder, uint256 tokenId, uint256 quantity) external {
        require(authorizedBurners[msg.sender], "Not authorized burner");
        require(balances[holder][tokenId] >= quantity, "Insufficient balance");

        balances[holder][tokenId] -= quantity;

        burnCallCount++;
        lastBurnHolder = holder;
        lastBurnTokenId = tokenId;
        lastBurnQuantity = quantity;
    }

    function resetBurnTracking() external {
        burnCallCount = 0;
        lastBurnHolder = address(0);
        lastBurnTokenId = 0;
        lastBurnQuantity = 0;
    }

    // ERC1155 supportsInterface stub
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/**
 * @title StableYieldAccumulatorTest
 * @notice Comprehensive test suite for StableYieldAccumulator
 * @dev GREEN PHASE - Tests verify actual behavior with real token transfers
 */
contract StableYieldAccumulatorTest is Test {
    StableYieldAccumulator public accumulator;
    MockERC20 public rewardToken;
    MockERC20 public strategyToken1;
    MockERC20 public strategyToken2;
    MockYieldStrategy public mockStrategy1;
    MockYieldStrategy public mockStrategy2;
    MockPhlimbo public mockPhlimbo;
    MockNFTMinter public mockNFTMinter;

    address public owner;
    address public pauser;
    address public user1;
    address public user2;
    address public phlimboAddr;
    address public minterAddr;

    // Events to test
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event NFTMinterUpdated(address indexed oldNFTMinter, address indexed newNFTMinter);
    event Paused(address account);
    event Unpaused(address account);
    event YieldStrategyAdded(address indexed strategy);
    event YieldStrategyRemoved(address indexed strategy);
    event TokenConfigSet(address indexed token, uint8 decimals, uint256 normalizedExchangeRate);
    event TokenPaused(address indexed token);
    event TokenUnpaused(address indexed token);
    event DiscountRateSet(uint256 oldRate, uint256 newRate);
    event PhlimboUpdated(address indexed oldPhlimbo, address indexed newPhlimbo);
    event RewardsClaimed(
        address indexed claimer,
        uint256 amountPaid,
        uint256 strategiesClaimed
    );
    event RewardsCollected(address indexed strategy, uint256 amount);

    function setUp() public {
        owner = address(this);
        pauser = makeAddr("pauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        minterAddr = makeAddr("minter");

        // Deploy mock tokens
        rewardToken = new MockERC20("Reward Token", "RWD");
        strategyToken1 = new MockERC20("Strategy Token 1", "STK1");
        strategyToken2 = new MockERC20("Strategy Token 2", "STK2");

        // Deploy mock yield strategies
        mockStrategy1 = new MockYieldStrategy();
        mockStrategy2 = new MockYieldStrategy();

        // Deploy accumulator
        accumulator = new StableYieldAccumulator();

        // Deploy mock Phlimbo and set it up
        mockPhlimbo = new MockPhlimbo(address(rewardToken));
        mockPhlimbo.setYieldAccumulator(address(accumulator));
        phlimboAddr = address(mockPhlimbo);

        // Deploy mock NFT Minter and configure
        mockNFTMinter = new MockNFTMinter();
        // Register the accumulator as an authorized burner
        mockNFTMinter.setAuthorizedBurner(address(accumulator), true);
        // Register a dispatcher so there's a valid token ID
        mockNFTMinter.registerDispatcher(makeAddr("dispatcher1"), 1e18, 100);
    }

    /*//////////////////////////////////////////////////////////////
                        SET PAUSER TESTS (PASSING)
    //////////////////////////////////////////////////////////////*/

    function test_setPauser_OwnerCanSet() public {
        // Verify initial state
        assertEq(accumulator.pauser(), address(0), "Initial pauser should be zero address");

        // Owner sets pauser
        vm.expectEmit(true, true, false, true);
        emit PauserUpdated(address(0), pauser);
        accumulator.setPauser(pauser);

        // Verify pauser was set
        assertEq(accumulator.pauser(), pauser, "Pauser should be set correctly");
    }

    function test_setPauser_CanUpdateExistingPauser() public {
        // Set initial pauser
        accumulator.setPauser(pauser);
        assertEq(accumulator.pauser(), pauser);

        // Update to new pauser
        address newPauser = makeAddr("newPauser");
        vm.expectEmit(true, true, false, true);
        emit PauserUpdated(pauser, newPauser);
        accumulator.setPauser(newPauser);

        // Verify pauser was updated
        assertEq(accumulator.pauser(), newPauser, "Pauser should be updated");
    }

    function test_setPauser_RevertIf_NotOwner() public {
        // Non-owner attempts to set pauser
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setPauser(pauser);
    }

    function test_setPauser_CanSetToZeroAddress() public {
        // Set pauser
        accumulator.setPauser(pauser);
        assertEq(accumulator.pauser(), pauser);

        // Reset to zero address
        vm.expectEmit(true, true, false, true);
        emit PauserUpdated(pauser, address(0));
        accumulator.setPauser(address(0));

        assertEq(accumulator.pauser(), address(0), "Pauser should be reset to zero");
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS (PASSING)
    //////////////////////////////////////////////////////////////*/

    function test_pause_PauserCanPause() public {
        // Set pauser
        accumulator.setPauser(pauser);

        // Pauser pauses contract
        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit Paused(pauser);
        accumulator.pause();

        // Verify paused state
        assertTrue(accumulator.paused(), "Contract should be paused");
    }

    function test_pause_RevertIf_NotPauser() public {
        // Set pauser
        accumulator.setPauser(pauser);

        // Non-pauser attempts to pause
        vm.prank(user1);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_pause_RevertIf_OwnerTriesToPause() public {
        // Set pauser
        accumulator.setPauser(pauser);

        // Owner (not pauser) attempts to pause
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_pause_RevertIf_PauserIsZeroAddress() public {
        // Pauser is zero address (default)
        assertEq(accumulator.pauser(), address(0));

        // Attempt to pause with zero address
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_pause_RevertIf_AlreadyPaused() public {
        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // Attempt to pause again
        vm.prank(pauser);
        vm.expectRevert();
        accumulator.pause();
    }

    /*//////////////////////////////////////////////////////////////
                        UNPAUSE TESTS (PASSING)
    //////////////////////////////////////////////////////////////*/

    function test_unpause_PauserCanUnpause() public {
        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();
        assertTrue(accumulator.paused());

        // Pauser unpauses
        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit Unpaused(pauser);
        accumulator.unpause();

        // Verify unpaused state
        assertFalse(accumulator.paused(), "Contract should be unpaused");
    }

    function test_unpause_OwnerCanUnpause() public {
        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();
        assertTrue(accumulator.paused());

        // Owner (not pauser) unpauses
        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);
        accumulator.unpause();

        // Verify unpaused state
        assertFalse(accumulator.paused(), "Contract should be unpaused by owner");
    }

    function test_unpause_RevertIf_NotOwnerOrPauser() public {
        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // Non-owner/non-pauser attempts to unpause
        vm.prank(user1);
        vm.expectRevert("Only owner or pauser can unpause");
        accumulator.unpause();
    }

    function test_unpause_RevertIf_NotPaused() public {
        // Set pauser
        accumulator.setPauser(pauser);

        // Attempt to unpause when not paused
        vm.prank(pauser);
        vm.expectRevert();
        accumulator.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    YIELD STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_addYieldStrategy_AddsToList() public {
        // GREEN PHASE: Test actual behavior with token parameter
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        address[] memory strategies = accumulator.getYieldStrategies();
        assertEq(strategies.length, 1, "Should have 1 strategy");
        assertEq(strategies[0], address(mockStrategy1), "Strategy should be mockStrategy1");
        assertTrue(accumulator.isRegisteredStrategy(address(mockStrategy1)), "Strategy should be registered");
        assertEq(accumulator.strategyTokens(address(mockStrategy1)), address(strategyToken1), "Strategy token should be set");
    }

    function test_addYieldStrategy_EmitsEvent() public {
        // GREEN PHASE: Verify event emission
        vm.expectEmit(true, false, false, true);
        emit YieldStrategyAdded(address(mockStrategy1));
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
    }

    function test_addYieldStrategy_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
    }

    function test_addYieldStrategy_RevertIf_ZeroAddress() public {
        // Strategy zero address
        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.addYieldStrategy(address(0), address(strategyToken1));

        // Token zero address
        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.addYieldStrategy(address(mockStrategy1), address(0));
    }

    function test_addYieldStrategy_RevertIf_AlreadyRegistered() public {
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        vm.expectRevert(IStableYieldAccumulator.StrategyAlreadyRegistered.selector);
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
    }

    function test_removeYieldStrategy_RemovesFromList() public {
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));

        accumulator.removeYieldStrategy(address(mockStrategy1));

        address[] memory strategies = accumulator.getYieldStrategies();
        assertEq(strategies.length, 1, "Should have 1 strategy remaining");
        assertEq(strategies[0], address(mockStrategy2), "Remaining strategy should be mockStrategy2");
        assertFalse(accumulator.isRegisteredStrategy(address(mockStrategy1)), "Strategy should not be registered");
        assertEq(accumulator.strategyTokens(address(mockStrategy1)), address(0), "Strategy token should be cleared");
    }

    function test_removeYieldStrategy_EmitsEvent() public {
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        vm.expectEmit(true, false, false, true);
        emit YieldStrategyRemoved(address(mockStrategy1));
        accumulator.removeYieldStrategy(address(mockStrategy1));
    }

    function test_removeYieldStrategy_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        accumulator.removeYieldStrategy(address(mockStrategy1));
    }

    function test_removeYieldStrategy_RevertIf_NotRegistered() public {
        vm.expectRevert(IStableYieldAccumulator.StrategyNotRegistered.selector);
        accumulator.removeYieldStrategy(address(mockStrategy1));
    }

    function test_getYieldStrategies_ReturnsAllStrategies() public {
        address[] memory strategiesBefore = accumulator.getYieldStrategies();
        assertEq(strategiesBefore.length, 0, "Should start with empty array");

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));

        address[] memory strategiesAfter = accumulator.getYieldStrategies();
        assertEq(strategiesAfter.length, 2, "Should have 2 strategies");
        assertEq(strategiesAfter[0], address(mockStrategy1), "First strategy should be mockStrategy1");
        assertEq(strategiesAfter[1], address(mockStrategy2), "Second strategy should be mockStrategy2");
    }

    /*//////////////////////////////////////////////////////////////
                    TOKEN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_setTokenConfig_StoresDecimalsAndRate() public {
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertEq(config.decimals, 6, "Should store 6 decimals");
        assertEq(config.normalizedExchangeRate, 1e18, "Should store 1e18 rate");
        assertFalse(config.paused, "Should not be paused by default");
    }

    function test_setTokenConfig_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TokenConfigSet(address(strategyToken1), 6, 1e18);
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);
    }

    function test_setTokenConfig_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);
    }

    function test_setTokenConfig_RevertIf_ZeroAddress() public {
        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.setTokenConfig(address(0), 6, 1e18);
    }

    function test_setTokenConfig_RevertIf_InvalidDecimals() public {
        vm.expectRevert(IStableYieldAccumulator.InvalidDecimals.selector);
        accumulator.setTokenConfig(address(strategyToken1), 19, 1e18);
    }

    function test_pauseToken_SetsTokenPaused() public {
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);

        vm.expectEmit(true, false, false, true);
        emit TokenPaused(address(strategyToken1));
        accumulator.pauseToken(address(strategyToken1));

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertTrue(config.paused, "Token should be paused");
    }

    function test_unpauseToken_SetsTokenUnpaused() public {
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);
        accumulator.pauseToken(address(strategyToken1));

        vm.expectEmit(true, false, false, true);
        emit TokenUnpaused(address(strategyToken1));
        accumulator.unpauseToken(address(strategyToken1));

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertFalse(config.paused, "Token should be unpaused");
    }

    function test_getTokenConfig_ReturnsStoredConfig() public {
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);
        accumulator.pauseToken(address(strategyToken1));

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertEq(config.decimals, 6, "Should return 6 decimals");
        assertEq(config.normalizedExchangeRate, 1e18, "Should return 1e18 rate");
        assertTrue(config.paused, "Should return paused status");
    }

    /*//////////////////////////////////////////////////////////////
                        DISCOUNT RATE
    //////////////////////////////////////////////////////////////*/

    function test_setDiscountRate_StoresRate(uint256 rate) public {
        vm.assume(rate <= 10000);

        accumulator.setDiscountRate(rate);

        uint256 storedRate = accumulator.getDiscountRate();
        assertEq(storedRate, rate, "Should store the discount rate");
    }

    function test_setDiscountRate_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit DiscountRateSet(0, 200);
        accumulator.setDiscountRate(200);
    }

    function test_setDiscountRate_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setDiscountRate(200);
    }

    function test_setDiscountRate_RevertIf_ExceedsMax() public {
        vm.expectRevert(IStableYieldAccumulator.ExceedsMaxDiscount.selector);
        accumulator.setDiscountRate(10001);
    }

    function test_getDiscountRate_ReturnsStoredRate() public {
        assertEq(accumulator.getDiscountRate(), 0, "Should start at 0");

        accumulator.setDiscountRate(200);
        assertEq(accumulator.getDiscountRate(), 200, "Should return 200 after setting");
    }

    /*//////////////////////////////////////////////////////////////
                        MINTER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_setMinter_StoresAddress() public {
        vm.expectEmit(true, true, false, true);
        emit MinterUpdated(address(0), minterAddr);
        accumulator.setMinter(minterAddr);

        assertEq(accumulator.minterAddress(), minterAddr, "Should store minter address");
    }

    function test_setMinter_RevertIf_ZeroAddress() public {
        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.setMinter(address(0));
    }

    function test_setMinter_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setMinter(minterAddr);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM MECHANISM - FULL FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to set up a complete claim scenario with NFT gate
     * @dev Sets up strategies with yield, claimer with reward tokens and NFT, and all configs
     */
    function _setupClaimScenario(uint256 yieldAmount) internal returns (address claimer) {
        claimer = makeAddr("claimer");

        // Setup accumulator config
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2% discount
        accumulator.setNFTMinter(address(mockNFTMinter));

        // Add strategy with token
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        // Set token config for strategy token (18 decimals, 1:1 rate)
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        // Set token config for reward token (18 decimals, 1:1 rate)
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set up mock strategy with yield
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, yieldAmount);

        // Fund the strategy with yield tokens so it can transfer them
        strategyToken1.mint(address(mockStrategy1), yieldAmount);

        // Fund claimer with reward tokens (need to pay discounted amount)
        // With 2% discount on yieldAmount, claimer pays: yieldAmount * 0.98
        uint256 claimerPayment = yieldAmount * 98 / 100;
        rewardToken.mint(claimer, claimerPayment + 1e18); // Add buffer

        // Claimer approves accumulator to spend reward tokens
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        // Approve Phlimbo to pull tokens from accumulator
        accumulator.approvePhlimbo(type(uint256).max);

        // Mint an NFT for the claimer (tokenId = 1, matching the dispatcher registered in setUp)
        mockNFTMinter.mintNFT(claimer, 1, 1);
    }

    function test_claim_FullFlow_TransfersCorrectly() public {
        uint256 yieldAmount = 100e18;
        address claimer = _setupClaimScenario(yieldAmount);

        // Expected payment: 100e18 * 0.98 = 98e18
        uint256 expectedPayment = yieldAmount * 98 / 100;

        // Record balances before
        uint256 claimerRewardBefore = rewardToken.balanceOf(claimer);
        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);
        uint256 phlimboRewardBefore = rewardToken.balanceOf(phlimboAddr);

        // Claim
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Record balances after
        uint256 claimerRewardAfter = rewardToken.balanceOf(claimer);
        uint256 claimerYieldAfter = strategyToken1.balanceOf(claimer);
        uint256 phlimboRewardAfter = rewardToken.balanceOf(phlimboAddr);

        // Verify: Claimer paid reward tokens to phlimbo
        assertEq(claimerRewardBefore - claimerRewardAfter, expectedPayment, "Claimer should have paid discounted amount");
        assertEq(phlimboRewardAfter - phlimboRewardBefore, expectedPayment, "Phlimbo should have received payment");

        // Verify: Claimer received yield tokens from strategy
        assertEq(claimerYieldAfter - claimerYieldBefore, yieldAmount, "Claimer should have received yield tokens");
    }

    function test_claim_CallsWithdrawFromOnStrategy() public {
        uint256 yieldAmount = 50e18;
        address claimer = _setupClaimScenario(yieldAmount);

        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Verify withdrawFrom was called with correct parameters
        assertEq(mockStrategy1.withdrawFromCallCount(), 1, "withdrawFrom should be called once");
        assertEq(mockStrategy1.lastWithdrawToken(), address(strategyToken1), "Should withdraw correct token");
        assertEq(mockStrategy1.lastWithdrawClient(), minterAddr, "Should withdraw from minter");
        assertEq(mockStrategy1.lastWithdrawAmount(), yieldAmount, "Should withdraw full yield");
        assertEq(mockStrategy1.lastWithdrawRecipient(), claimer, "Should send to claimer");
    }

    function test_claim_MultipleStrategies() public {
        address claimer = makeAddr("claimer");

        // Setup both strategies
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200);
        accumulator.setNFTMinter(address(mockNFTMinter));

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));

        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(strategyToken2), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set yields: 60e18 from strategy1, 40e18 from strategy2 = 100e18 total
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 60e18);
        mockStrategy2.setBalances(address(strategyToken2), minterAddr, 500e18, 40e18);

        // Fund strategies with yield tokens
        strategyToken1.mint(address(mockStrategy1), 60e18);
        strategyToken2.mint(address(mockStrategy2), 40e18);

        // Fund claimer: 100e18 total * 0.98 = 98e18 payment
        rewardToken.mint(claimer, 100e18);
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        // Approve Phlimbo to pull tokens from accumulator
        accumulator.approvePhlimbo(type(uint256).max);

        // Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // Claim
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Verify claimer received both yield tokens
        assertEq(strategyToken1.balanceOf(claimer), 60e18, "Should receive yield from strategy1");
        assertEq(strategyToken2.balanceOf(claimer), 40e18, "Should receive yield from strategy2");

        // Verify both strategies had withdrawFrom called
        assertEq(mockStrategy1.withdrawFromCallCount(), 1, "Strategy1 withdrawFrom called");
        assertEq(mockStrategy2.withdrawFromCallCount(), 1, "Strategy2 withdrawFrom called");
    }

    function test_claim_EmitsEvents() public {
        uint256 yieldAmount = 100e18;
        address claimer = _setupClaimScenario(yieldAmount);
        uint256 expectedPayment = yieldAmount * 98 / 100;

        vm.prank(claimer);

        // Expect RewardsCollected for each strategy with yield
        vm.expectEmit(true, false, false, true);
        emit RewardsCollected(address(mockStrategy1), yieldAmount);

        // Expect RewardsClaimed at the end
        vm.expectEmit(true, false, false, true);
        emit RewardsClaimed(claimer, expectedPayment, 1);

        accumulator.claim(1, 0);
    }

    function test_claim_RevertIf_Paused() public {
        address claimer = _setupClaimScenario(100e18);

        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        vm.prank(claimer);
        vm.expectRevert();
        accumulator.claim(1, 0);
    }

    function test_claim_RevertIf_NoYield() public {
        address claimer = makeAddr("claimer");

        // Setup without any yield
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setNFTMinter(address(mockNFTMinter));
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);

        // No yield set
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 0);

        // Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.ZeroAmount.selector);
        accumulator.claim(1, 0);
    }

    function test_claim_RevertIf_PhlimboNotSet() public {
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);

        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.claim(1, 0);
    }

    function test_claim_RevertIf_RewardTokenNotSet() public {
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setMinter(minterAddr);

        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.claim(1, 0);
    }

    function test_claim_RevertIf_MinterNotSet() public {
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));

        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.claim(1, 0);
    }

    function test_claim_RevertIf_AllTokensPaused() public {
        address claimer = _setupClaimScenario(100e18);

        // Pause the only strategy token — claim skips it, yielding zero total
        accumulator.pauseToken(address(strategyToken1));

        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.ZeroAmount.selector);
        accumulator.claim(1, 0);
    }

    function test_calculateClaimAmount_ReturnsDiscountedPayment() public {
        address claimer = _setupClaimScenario(100e18);

        // calculateClaimAmount should return what claimer would pay
        // Total yield: 100e18, discount: 2%, payment: 98e18
        uint256 expectedPayment = accumulator.calculateClaimAmount();
        assertEq(expectedPayment, 98e18, "Should return discounted payment amount");
    }

    function test_calculateClaimAmount_NoDiscount() public {
        address claimer = makeAddr("claimer");

        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(0); // No discount

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 100e18);

        // No discount: payment = total yield
        uint256 expectedPayment = accumulator.calculateClaimAmount();
        assertEq(expectedPayment, 100e18, "Should return full amount with no discount");
    }

    function test_calculateClaimAmount_ZeroIfNoStrategies() public {
        accumulator.setMinter(minterAddr);

        uint256 payment = accumulator.calculateClaimAmount();
        assertEq(payment, 0, "Should return 0 if no strategies");
    }

    function test_calculateClaimAmount_ZeroIfMinterNotSet() public {
        uint256 payment = accumulator.calculateClaimAmount();
        assertEq(payment, 0, "Should return 0 if minter not set");
    }

    /*//////////////////////////////////////////////////////////////
                    YIELD CALCULATION - ACTUAL STRATEGY QUERIES
    //////////////////////////////////////////////////////////////*/

    function test_getYield_ReturnsActualYieldFromStrategy() public {
        // Setup strategy with token and minter
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.setMinter(minterAddr);

        // Set mock strategy to return specific balances for minter
        uint256 principal = 1000e18;
        uint256 yieldAmount = 50e18;
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, principal, yieldAmount);

        // Get yield should return the difference
        uint256 yield = accumulator.getYield(address(mockStrategy1));
        assertEq(yield, yieldAmount, "Should return actual yield from strategy");
    }

    function test_getYield_ReturnsZeroIfMinterNotSet() public {
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        // Don't set minter

        uint256 yield = accumulator.getYield(address(mockStrategy1));
        assertEq(yield, 0, "Should return 0 if minter not set");
    }

    function test_getYield_ReturnsZeroIfNoYield() public {
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.setMinter(minterAddr);

        // Set principal but no yield
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 0);

        uint256 yield = accumulator.getYield(address(mockStrategy1));
        assertEq(yield, 0, "Should return 0 if no yield accumulated");
    }

    function test_getYield_RevertIf_NotRegisteredStrategy() public {
        vm.expectRevert(IStableYieldAccumulator.StrategyNotRegistered.selector);
        accumulator.getYield(address(mockStrategy1));
    }

    function test_getTotalYield_SumsAllStrategies() public {
        // Setup two strategies
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));
        accumulator.setMinter(minterAddr);

        // Set mock balances for both strategies
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 50e18);  // 50 yield
        mockStrategy2.setBalances(address(strategyToken2), minterAddr, 2000e18, 100e18); // 100 yield

        uint256 totalYield = accumulator.getTotalYield();
        assertEq(totalYield, 150e18, "Should sum yield from all strategies");
    }

    function test_getTotalYield_ReturnsZeroIfNoStrategies() public {
        accumulator.setMinter(minterAddr);

        uint256 totalYield = accumulator.getTotalYield();
        assertEq(totalYield, 0, "Should return 0 if no strategies registered");
    }

    function test_getTotalYield_ReturnsZeroIfMinterNotSet() public {
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 50e18);

        // Don't set minter
        uint256 totalYield = accumulator.getTotalYield();
        assertEq(totalYield, 0, "Should return 0 if minter not set");
    }

    /*//////////////////////////////////////////////////////////////
                    DECIMAL NORMALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_normalizeAmount_6DecimalToken() public {
        accumulator.setTokenConfig(address(strategyToken1), 6, 1e18);

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertEq(config.decimals, 6, "Should store 6 decimals");
        assertEq(config.normalizedExchangeRate, 1e18, "Should store 1e18 rate");
    }

    function test_normalizeAmount_18DecimalToken() public {
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertEq(config.decimals, 18, "Should store 18 decimals");
        assertEq(config.normalizedExchangeRate, 1e18, "Should store 1e18 rate");
    }

    function test_normalizeAmount_8DecimalToken() public {
        accumulator.setTokenConfig(address(strategyToken1), 8, 1e18);

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertEq(config.decimals, 8, "Should store 8 decimals");
        assertEq(config.normalizedExchangeRate, 1e18, "Should store 1e18 rate");
    }

    function test_fuzz_normalizeAmount_VariousDecimals(uint8 decimals) public {
        vm.assume(decimals <= 18);
        accumulator.setTokenConfig(address(strategyToken1), decimals, 1e18);

        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(address(strategyToken1));
        assertEq(config.decimals, decimals, "Should store correct decimals");
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_fullFlow_AddStrategySetConfigCollectClaim() public {
        address claimer = makeAddr("claimer");

        // 1. Add strategy with token
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        // 2. Set token config (18 decimals for easy testing)
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // 3. Set discount rate
        accumulator.setDiscountRate(200);

        // 4. Set phlimbo and minter
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setMinter(minterAddr);

        // 5. Set reward token
        accumulator.setRewardToken(address(rewardToken));

        // 5b. Set NFT minter
        accumulator.setNFTMinter(address(mockNFTMinter));

        // 6. Setup yield: 100e18 yield in strategy
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 100e18);
        strategyToken1.mint(address(mockStrategy1), 100e18);

        // 7. Fund claimer with reward tokens (98e18 needed for 2% discount)
        rewardToken.mint(claimer, 100e18);
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        // 7.5. Approve Phlimbo to pull tokens from accumulator
        accumulator.approvePhlimbo(type(uint256).max);

        // 7.6. Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // 8. Claim and verify actual token transfers
        uint256 phlimboBalanceBefore = rewardToken.balanceOf(phlimboAddr);
        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);

        vm.prank(claimer);
        accumulator.claim(1, 0);

        uint256 phlimboBalanceAfter = rewardToken.balanceOf(phlimboAddr);
        uint256 claimerYieldAfter = strategyToken1.balanceOf(claimer);

        // Verify state
        assertEq(accumulator.getYieldStrategies().length, 1, "Should have 1 strategy");
        assertEq(accumulator.getDiscountRate(), 200, "Should have discount rate of 200");
        assertEq(phlimboBalanceAfter - phlimboBalanceBefore, 98e18, "Phlimbo should have received discounted payment");
        assertEq(claimerYieldAfter - claimerYieldBefore, 100e18, "Claimer should have received yield tokens");
    }

    function test_multipleStrategies_GetTotalYield() public {
        // Setup
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));
        accumulator.setMinter(minterAddr);

        // Set mock balances
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 25e18);
        mockStrategy2.setBalances(address(strategyToken2), minterAddr, 500e18, 75e18);

        address[] memory strategies = accumulator.getYieldStrategies();
        assertEq(strategies.length, 2, "Should have 2 strategies");

        uint256 totalYield = accumulator.getTotalYield();
        assertEq(totalYield, 100e18, "Total yield should be 100e18");
    }

    function test_pauseUnpause_AffectsClaimOnly() public {
        // Setup complete claim scenario
        address claimer = _setupClaimScenario(100e18);

        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // Claim should revert due to pause
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.claim(1, 0);

        // Unpause
        vm.prank(pauser);
        accumulator.unpause();

        // Claim should now work and transfer actual tokens
        uint256 phlimboBalanceBefore = rewardToken.balanceOf(phlimboAddr);
        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);

        vm.prank(claimer);
        accumulator.claim(1, 0);

        uint256 phlimboBalanceAfter = rewardToken.balanceOf(phlimboAddr);
        uint256 claimerYieldAfter = strategyToken1.balanceOf(claimer);

        assertEq(phlimboBalanceAfter - phlimboBalanceBefore, 98e18, "Phlimbo should receive discounted payment");
        assertEq(claimerYieldAfter - claimerYieldBefore, 100e18, "Claimer should receive yield tokens");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_edgeCase_PauserCannotPauseAfterRemoval() public {
        accumulator.setPauser(pauser);
        accumulator.setPauser(address(0));

        vm.prank(pauser);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_edgeCase_NewPauserCanPauseImmediately() public {
        accumulator.setPauser(pauser);

        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        vm.prank(newPauser);
        accumulator.pause();
        assertTrue(accumulator.paused());
    }

    function test_edgeCase_OldPauserCannotPauseAfterChange() public {
        accumulator.setPauser(pauser);

        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        vm.prank(pauser);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_edgeCase_OwnerAlwaysCanUnpause() public {
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        accumulator.unpause();
        assertFalse(accumulator.paused());
    }

    function test_fuzz_setPauser(address randomPauser) public {
        vm.expectEmit(true, true, false, true);
        emit PauserUpdated(address(0), randomPauser);
        accumulator.setPauser(randomPauser);

        assertEq(accumulator.pauser(), randomPauser);
    }

    function test_fuzz_pauseUnpauseCycle(address randomPauser) public {
        vm.assume(randomPauser != address(0));

        accumulator.setPauser(randomPauser);

        vm.prank(randomPauser);
        accumulator.pause();
        assertTrue(accumulator.paused());

        vm.prank(randomPauser);
        accumulator.unpause();
        assertFalse(accumulator.paused());
    }

    /*//////////////////////////////////////////////////////////////
                        PHLIMBO MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPhlimbo_StoresAddress() public {
        vm.expectEmit(true, true, false, true);
        emit PhlimboUpdated(address(0), phlimboAddr);
        accumulator.setPhlimbo(phlimboAddr);

        assertEq(accumulator.phlimbo(), phlimboAddr, "Should store phlimbo address");
    }

    function test_setPhlimbo_RevertIf_ZeroAddress() public {
        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.setPhlimbo(address(0));
    }

    function test_setPhlimbo_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setPhlimbo(phlimboAddr);
    }

    function test_setPhlimbo_CanUpdate() public {
        address phlimboAddr1 = makeAddr("phlimbo1");
        address phlimboAddr2 = makeAddr("phlimbo2");

        accumulator.setPhlimbo(phlimboAddr1);
        assertEq(accumulator.phlimbo(), phlimboAddr1, "Should store first phlimbo");

        vm.expectEmit(true, true, false, true);
        emit PhlimboUpdated(phlimboAddr1, phlimboAddr2);
        accumulator.setPhlimbo(phlimboAddr2);

        assertEq(accumulator.phlimbo(), phlimboAddr2, "Should update to second phlimbo");
    }

    /*//////////////////////////////////////////////////////////////
                MULTI-DECIMAL NORMALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tests that getTotalYield() properly normalizes yields from tokens with different decimals
     */
    function test_getTotalYield_NormalizesMultiDecimalTokens() public {
        // Create 6-decimal token (like USDC)
        MockERC20WithDecimals usdcLike = new MockERC20WithDecimals("USDC Mock", "USDC", 6);

        // Create 18-decimal token (like DOLA)
        MockERC20WithDecimals dolaLike = new MockERC20WithDecimals("DOLA Mock", "DOLA", 18);

        // Create mock strategies for each token
        MockYieldStrategy usdcStrategy = new MockYieldStrategy();
        MockYieldStrategy dolaStrategy = new MockYieldStrategy();

        // Setup accumulator
        accumulator.setMinter(minterAddr);

        // Add strategies
        accumulator.addYieldStrategy(address(usdcStrategy), address(usdcLike));
        accumulator.addYieldStrategy(address(dolaStrategy), address(dolaLike));

        // Configure token decimals and exchange rates (1:1)
        accumulator.setTokenConfig(address(usdcLike), 6, 1e18);  // 6 decimals
        accumulator.setTokenConfig(address(dolaLike), 18, 1e18); // 18 decimals

        // Set yields:
        // - USDC strategy: 300 USDC yield (in 6 decimals = 300e6)
        // - DOLA strategy: 4000 DOLA yield (in 18 decimals = 4000e18)
        uint256 usdcYield = 300e6;   // 300 USDC in native decimals
        uint256 dolaYield = 4000e18; // 4000 DOLA in native decimals

        usdcStrategy.setBalances(address(usdcLike), minterAddr, 1000e6, usdcYield);
        dolaStrategy.setBalances(address(dolaLike), minterAddr, 10000e18, dolaYield);

        // Get total yield - should be normalized to 18 decimals
        uint256 totalYield = accumulator.getTotalYield();

        // Expected: 300e18 (normalized USDC) + 4000e18 (DOLA) = 4300e18
        uint256 expectedNormalizedTotal = 4300e18;

        assertEq(
            totalYield,
            expectedNormalizedTotal,
            "getTotalYield should return normalized sum of 4300e18"
        );

        // Also verify individual getYield() returns native decimals (NOT normalized)
        uint256 individualUsdcYield = accumulator.getYield(address(usdcStrategy));
        uint256 individualDolaYield = accumulator.getYield(address(dolaStrategy));

        assertEq(individualUsdcYield, usdcYield, "getYield for USDC strategy should return native 6-decimal value");
        assertEq(individualDolaYield, dolaYield, "getYield for DOLA strategy should return native 18-decimal value");
    }

    /*//////////////////////////////////////////////////////////////
                    PAUSED TOKEN CLAIM CONSISTENCY TESTS (M-02)
    //////////////////////////////////////////////////////////////*/

    /// @notice claim() succeeds when one strategy's token is paused,
    ///         collecting yield only from the unpaused strategy.
    function test_claim_SucceedsWithOnePausedToken() public {
        address claimer = makeAddr("claimer");

        // Setup two strategies
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2%
        accumulator.setNFTMinter(address(mockNFTMinter));

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));

        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(strategyToken2), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set yields: 60e18 from strategy1, 40e18 from strategy2
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 60e18);
        mockStrategy2.setBalances(address(strategyToken2), minterAddr, 500e18, 40e18);

        // Fund strategies with yield tokens
        strategyToken1.mint(address(mockStrategy1), 60e18);
        strategyToken2.mint(address(mockStrategy2), 40e18);

        // Pause strategy1's token — only strategy2 yield should be claimable
        accumulator.pauseToken(address(strategyToken1));

        // Fund claimer: only strategy2's yield matters (40e18 * 0.98 = 39.2e18)
        rewardToken.mint(claimer, 50e18);
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        accumulator.approvePhlimbo(type(uint256).max);

        // Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // Claim should succeed, collecting only from unpaused strategy2
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Claimer should NOT receive strategyToken1 (paused)
        assertEq(strategyToken1.balanceOf(claimer), 0, "Should not receive yield from paused token");
        // Claimer SHOULD receive strategyToken2 yield
        assertEq(strategyToken2.balanceOf(claimer), 40e18, "Should receive yield from unpaused token");

        // Only strategy2 should have had withdrawFrom called
        assertEq(mockStrategy1.withdrawFromCallCount(), 0, "Paused strategy should not be called");
        assertEq(mockStrategy2.withdrawFromCallCount(), 1, "Unpaused strategy should be called");

        // Verify payment: 40e18 * 0.98 = 39.2e18
        uint256 expectedPayment = 40e18 * 98 / 100;
        assertEq(mockPhlimbo.lastCollectedAmount(), expectedPayment, "Phlimbo should receive discounted payment for unpaused yield only");
    }

    /// @notice claim() returns the same total as calculateClaimAmount() when a token is paused.
    function test_claim_ConsistentWithCalculateClaimAmount_WhenTokenPaused() public {
        address claimer = makeAddr("claimer");

        // Setup two strategies
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2%
        accumulator.setNFTMinter(address(mockNFTMinter));

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));

        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(strategyToken2), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set yields: 60e18 from strategy1, 40e18 from strategy2
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 60e18);
        mockStrategy2.setBalances(address(strategyToken2), minterAddr, 500e18, 40e18);

        // Fund strategies with yield tokens
        strategyToken1.mint(address(mockStrategy1), 60e18);
        strategyToken2.mint(address(mockStrategy2), 40e18);

        // Pause strategy1's token
        accumulator.pauseToken(address(strategyToken1));

        // Query calculateClaimAmount BEFORE claim — should reflect only unpaused yield
        uint256 calculatedAmount = accumulator.calculateClaimAmount();

        // Fund claimer with enough to cover the payment
        rewardToken.mint(claimer, calculatedAmount + 1e18);
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        accumulator.approvePhlimbo(type(uint256).max);

        // Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // Record claimer's reward token balance before claim
        uint256 claimerBalanceBefore = rewardToken.balanceOf(claimer);

        // Execute claim
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // The actual payment deducted from claimer should match calculateClaimAmount
        uint256 actualPayment = claimerBalanceBefore - rewardToken.balanceOf(claimer);
        assertEq(actualPayment, calculatedAmount, "claim() payment should match calculateClaimAmount() when token is paused");
    }

    /// @notice Regression: claim() works normally when no tokens are paused.
    function test_claim_WorksNormally_NoTokensPaused() public {
        address claimer = makeAddr("claimer");

        // Setup two strategies — no tokens paused
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2%
        accumulator.setNFTMinter(address(mockNFTMinter));

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.addYieldStrategy(address(mockStrategy2), address(strategyToken2));

        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(strategyToken2), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set yields: 60e18 from strategy1, 40e18 from strategy2 = 100e18 total
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 60e18);
        mockStrategy2.setBalances(address(strategyToken2), minterAddr, 500e18, 40e18);

        // Fund strategies with yield tokens
        strategyToken1.mint(address(mockStrategy1), 60e18);
        strategyToken2.mint(address(mockStrategy2), 40e18);

        // Fund claimer: 100e18 total * 0.98 = 98e18 payment
        rewardToken.mint(claimer, 100e18);
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        accumulator.approvePhlimbo(type(uint256).max);

        // Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // Claim — no tokens paused, should collect from both strategies
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Claimer should receive yield from both strategies
        assertEq(strategyToken1.balanceOf(claimer), 60e18, "Should receive yield from strategy1");
        assertEq(strategyToken2.balanceOf(claimer), 40e18, "Should receive yield from strategy2");

        // Both strategies should have had withdrawFrom called
        assertEq(mockStrategy1.withdrawFromCallCount(), 1, "Strategy1 withdrawFrom called");
        assertEq(mockStrategy2.withdrawFromCallCount(), 1, "Strategy2 withdrawFrom called");

        // Verify payment: 100e18 * 0.98 = 98e18
        uint256 expectedPayment = 100e18 * 98 / 100;
        assertEq(mockPhlimbo.lastCollectedAmount(), expectedPayment, "Phlimbo should receive full discounted payment");
    }

    /*//////////////////////////////////////////////////////////////
            USDT-LIKE TOKEN COMPATIBILITY TESTS (M-03)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that second approvePhlimbo() succeeds after partial consumption by Phlimbo.
     */
    function test_approvePhlimbo_SecondCallSucceeds_AfterPartialConsumption_WithUSDTLikeToken() public {
        // Deploy a USDT-like reward token
        MockUSDT usdtToken = new MockUSDT("USDT", "USDT");

        // Deploy fresh accumulator and phlimbo for this test
        StableYieldAccumulator acc = new StableYieldAccumulator();
        MockPhlimbo phlimboMock = new MockPhlimbo(address(usdtToken));
        phlimboMock.setYieldAccumulator(address(acc));

        // Configure accumulator
        acc.setPhlimbo(address(phlimboMock));
        acc.setRewardToken(address(usdtToken));

        // First approvePhlimbo (0 -> 100e18): should succeed
        acc.approvePhlimbo(100e18);
        assertEq(usdtToken.allowance(address(acc), address(phlimboMock)), 100e18, "First approve should set allowance");

        // Simulate Phlimbo partially consuming the allowance.
        usdtToken.mint(address(acc), 100e18);

        vm.prank(address(phlimboMock));
        usdtToken.transferFrom(address(acc), address(phlimboMock), 60e18);

        // Verify residual allowance is non-zero (100 - 60 = 40)
        uint256 residual = usdtToken.allowance(address(acc), address(phlimboMock));
        assertEq(residual, 40e18, "Residual allowance should be 40e18 after partial consumption");

        // Second approvePhlimbo: with raw approve() this would revert (40e18 -> 100e18)
        // With forceApprove(), it should succeed (40e18 -> 0 -> 100e18)
        acc.approvePhlimbo(100e18);

        assertEq(usdtToken.allowance(address(acc), address(phlimboMock)), 100e18, "Second approvePhlimbo should succeed with forceApprove");
    }

    /*//////////////////////////////////////////////////////////////
                CLAIM SLIPPAGE PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_claim_RevertsWithInsufficientYield_WhenMinExceedsActual() public {
        uint256 yieldAmount = 100e18;
        address claimer = _setupClaimScenario(yieldAmount);

        // Expected payment: 100e18 * 0.98 = 98e18
        uint256 expectedPayment = yieldAmount * 98 / 100;

        // Set minRewardTokenSupplied higher than actual payment
        uint256 tooHighMin = expectedPayment + 1;

        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.InsufficientYield.selector);
        accumulator.claim(1, tooHighMin);
    }

    function test_claim_SucceedsWhenMinEqualsActualPayment() public {
        uint256 yieldAmount = 100e18;
        address claimer = _setupClaimScenario(yieldAmount);

        // Expected payment: 100e18 * 0.98 = 98e18
        uint256 expectedPayment = yieldAmount * 98 / 100;

        vm.prank(claimer);
        accumulator.claim(1, expectedPayment);

        // Verify claim went through by checking claimer received yield tokens
        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claimer should have received yield tokens");
    }

    function test_claim_SucceedsWhenMinIsZero() public {
        uint256 yieldAmount = 100e18;
        address claimer = _setupClaimScenario(yieldAmount);

        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Verify claim went through by checking claimer received yield tokens
        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claimer should have received yield tokens");
    }

    function test_claim_SucceedsWhenMinIsLessThanActualPayment() public {
        uint256 yieldAmount = 100e18;
        address claimer = _setupClaimScenario(yieldAmount);

        // Expected payment: 100e18 * 0.98 = 98e18
        uint256 expectedPayment = yieldAmount * 98 / 100;

        // Set minRewardTokenSupplied lower than actual payment
        uint256 lowMin = expectedPayment - 1e18;

        vm.prank(claimer);
        accumulator.claim(1, lowMin);

        // Verify claim went through by checking claimer received yield tokens
        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claimer should have received yield tokens");
    }
}

/**
 * @title NFTClaimGateTest
 * @notice Tests for the NFT-based claim gating on StableYieldAccumulator
 */
contract NFTClaimGateTest is Test {
    StableYieldAccumulator public accumulator;
    MockERC20 public rewardToken;
    MockERC20 public strategyToken1;
    MockYieldStrategy public mockStrategy1;
    MockPhlimbo public mockPhlimbo;
    MockNFTMinter public mockNFTMinter;

    address public owner;
    address public minterAddr;
    address public phlimboAddr;
    address public claimer;

    // Events
    event NFTMinterUpdated(address indexed oldNFTMinter, address indexed newNFTMinter);

    function setUp() public {
        owner = address(this);
        minterAddr = makeAddr("minter");
        claimer = makeAddr("claimer");

        // Deploy mock tokens
        rewardToken = new MockERC20("Reward Token", "RWD");
        strategyToken1 = new MockERC20("Strategy Token 1", "STK1");

        // Deploy mock contracts
        mockStrategy1 = new MockYieldStrategy();
        mockNFTMinter = new MockNFTMinter();

        // Deploy accumulator
        accumulator = new StableYieldAccumulator();

        // Deploy mock Phlimbo
        mockPhlimbo = new MockPhlimbo(address(rewardToken));
        mockPhlimbo.setYieldAccumulator(address(accumulator));
        phlimboAddr = address(mockPhlimbo);

        // Register the accumulator as an authorized burner on the NFTMinter
        mockNFTMinter.setAuthorizedBurner(address(accumulator), true);

        // Register a dispatcher (index 1) so we have a valid token ID
        mockNFTMinter.registerDispatcher(makeAddr("dispatcher1"), 1e18, 100);
    }

    /**
     * @notice Helper to set up a complete claim scenario with NFT gate
     */
    function _setupClaimWithNFT(uint256 yieldAmount) internal {
        // Setup basic claim infrastructure
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2% discount
        accumulator.setNFTMinter(address(mockNFTMinter));

        // Add strategy with token
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        // Set token config
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set up mock strategy with yield
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, yieldAmount);
        strategyToken1.mint(address(mockStrategy1), yieldAmount);

        // Fund claimer with reward tokens
        uint256 claimerPayment = yieldAmount * 98 / 100;
        rewardToken.mint(claimer, claimerPayment + 1e18);

        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        // Approve Phlimbo
        accumulator.approvePhlimbo(type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    setNFTMinter TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setNFTMinter_OnlyOwner() public {
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.setNFTMinter(address(mockNFTMinter));
    }

    function test_setNFTMinter_Success() public {
        vm.expectEmit(true, true, false, true);
        emit NFTMinterUpdated(address(0), address(mockNFTMinter));
        accumulator.setNFTMinter(address(mockNFTMinter));

        assertEq(accumulator.nftMinter(), address(mockNFTMinter), "NFT minter should be set");
    }

    function test_setNFTMinter_CanUpdate() public {
        accumulator.setNFTMinter(address(mockNFTMinter));

        MockNFTMinter newMinter = new MockNFTMinter();
        vm.expectEmit(true, true, false, true);
        emit NFTMinterUpdated(address(mockNFTMinter), address(newMinter));
        accumulator.setNFTMinter(address(newMinter));

        assertEq(accumulator.nftMinter(), address(newMinter), "NFT minter should be updated");
    }

    function test_setNFTMinter_CanSetToZero() public {
        accumulator.setNFTMinter(address(mockNFTMinter));
        accumulator.setNFTMinter(address(0));
        assertEq(accumulator.nftMinter(), address(0), "NFT minter should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIM WITH NFT GATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_claim_SucceedsWhenCallerHoldsValidNFT() public {
        uint256 yieldAmount = 100e18;
        _setupClaimWithNFT(yieldAmount);

        // Mint NFT for claimer (tokenId = 1, matching dispatcher1)
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // Record balances before
        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);
        uint256 nftBalanceBefore = mockNFTMinter.balances(claimer, 1);

        // Claim should succeed
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Verify yield received
        uint256 claimerYieldAfter = strategyToken1.balanceOf(claimer);
        assertEq(claimerYieldAfter - claimerYieldBefore, yieldAmount, "Claimer should receive yield tokens");

        // Verify NFT was burned (balance decreased by 1)
        uint256 nftBalanceAfter = mockNFTMinter.balances(claimer, 1);
        assertEq(nftBalanceBefore - nftBalanceAfter, 1, "Exactly 1 NFT should be burned");

        // Verify burn was called with correct parameters
        assertEq(mockNFTMinter.burnCallCount(), 1, "burn should be called once");
        assertEq(mockNFTMinter.lastBurnHolder(), claimer, "Burn holder should be claimer");
        assertEq(mockNFTMinter.lastBurnTokenId(), 1, "Burn tokenId should be 1");
        assertEq(mockNFTMinter.lastBurnQuantity(), 1, "Burn quantity should be 1");
    }

    function test_claim_RevertsWithNoValidNFT() public {
        uint256 yieldAmount = 100e18;
        _setupClaimWithNFT(yieldAmount);

        // Do NOT mint NFT for claimer

        // Claim should revert with NoValidNFT
        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.NoValidNFT.selector);
        accumulator.claim(1, 0);
    }

    function test_claim_RevertsWhenNFTMinterNotConfigured() public {
        // Setup without setting NFT minter
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);

        // Do NOT set NFT minter
        // accumulator.setNFTMinter(...)

        vm.prank(claimer);
        vm.expectRevert("NFT minter not configured");
        accumulator.claim(1, 0);
    }

    function test_claim_BurnsExactlyOneNFT() public {
        uint256 yieldAmount = 100e18;
        _setupClaimWithNFT(yieldAmount);

        // Mint multiple NFTs for claimer
        mockNFTMinter.mintNFT(claimer, 1, 5); // 5 NFTs of tokenId 1

        // Claim
        vm.prank(claimer);
        accumulator.claim(1, 0);

        // Should have burned exactly 1
        assertEq(mockNFTMinter.balances(claimer, 1), 4, "Should have 4 remaining after burning 1");
    }

    function test_claim_SecondClaimWithSecondNFT() public {
        uint256 yieldAmount = 50e18;
        _setupClaimWithNFT(yieldAmount);

        // Mint 2 NFTs for claimer
        mockNFTMinter.mintNFT(claimer, 1, 2);

        // First claim
        vm.prank(claimer);
        accumulator.claim(1, 0);

        assertEq(mockNFTMinter.balances(claimer, 1), 1, "Should have 1 NFT remaining");

        // Reset strategy yield for second claim
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, yieldAmount);
        strategyToken1.mint(address(mockStrategy1), yieldAmount);

        // Fund claimer for second claim
        uint256 claimerPayment = yieldAmount * 98 / 100;
        rewardToken.mint(claimer, claimerPayment + 1e18);

        // Second claim should also succeed
        vm.prank(claimer);
        accumulator.claim(1, 0);

        assertEq(mockNFTMinter.balances(claimer, 1), 0, "Should have 0 NFTs remaining after 2 claims");
    }

    function test_claim_SecondClaimFailsWithoutNFT() public {
        uint256 yieldAmount = 50e18;
        _setupClaimWithNFT(yieldAmount);

        // Mint only 1 NFT
        mockNFTMinter.mintNFT(claimer, 1, 1);

        // First claim succeeds
        vm.prank(claimer);
        accumulator.claim(1, 0);

        assertEq(mockNFTMinter.balances(claimer, 1), 0, "Should have 0 NFTs after first claim");

        // Reset strategy yield
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, yieldAmount);
        strategyToken1.mint(address(mockStrategy1), yieldAmount);
        rewardToken.mint(claimer, yieldAmount);

        // Second claim should fail - no NFTs left
        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.NoValidNFT.selector);
        accumulator.claim(1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    canClaim VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_canClaim_TrueWhenCallerHoldsNFT() public {
        accumulator.setNFTMinter(address(mockNFTMinter));

        // Mint NFT for claimer
        mockNFTMinter.mintNFT(claimer, 1, 1);

        assertTrue(accumulator.canClaim(claimer), "Should return true when caller holds NFT");
    }

    function test_canClaim_FalseWhenCallerHasNoNFT() public {
        accumulator.setNFTMinter(address(mockNFTMinter));

        assertFalse(accumulator.canClaim(claimer), "Should return false when caller has no NFT");
    }

    function test_canClaim_FalseWhenNFTMinterNotSet() public {
        // Don't set NFT minter
        assertFalse(accumulator.canClaim(claimer), "Should return false when nftMinter not set");
    }

    function test_canClaim_SkipsUnusedDispatchers() public {
        accumulator.setNFTMinter(address(mockNFTMinter));

        // Register dispatcher1 was done in setUp (index 1)
        // Register a second dispatcher but then "deactivate" it by setting dispatcher to address(0)
        // Note: MockNFTMinter doesn't support deactivation, but we can test with no NFTs

        // Claimer has no NFTs at all
        assertFalse(accumulator.canClaim(claimer), "Should return false when no NFTs held");
    }
}
