// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableYieldAccumulator.sol";
import "../src/interfaces/IStableYieldAccumulator.sol";
import "vault/interfaces/IYieldStrategy.sol";
import "phlimbo-ea/interfaces/IPhlimbo.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

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
        // The strategy must hold the tokens for this to work
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

    address public owner;
    address public pauser;
    address public user1;
    address public user2;
    address public phlimboAddr;
    address public minterAddr;

    // Events to test
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
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
     * @notice Helper to set up a complete claim scenario
     * @dev Sets up strategies with yield, claimer with reward tokens, and all configs
     */
    function _setupClaimScenario(uint256 yieldAmount) internal returns (address claimer) {
        claimer = makeAddr("claimer");

        // Setup accumulator config
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2% discount

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
        accumulator.claim();

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
        accumulator.claim();

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

        // Claim
        vm.prank(claimer);
        accumulator.claim();

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

        accumulator.claim();
    }

    function test_claim_RevertIf_Paused() public {
        address claimer = _setupClaimScenario(100e18);

        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        vm.prank(claimer);
        vm.expectRevert();
        accumulator.claim();
    }

    function test_claim_RevertIf_NoYield() public {
        address claimer = makeAddr("claimer");

        // Setup without any yield
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);

        // No yield set
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 0);

        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.ZeroAmount.selector);
        accumulator.claim();
    }

    function test_claim_RevertIf_PhlimboNotSet() public {
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);

        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.claim();
    }

    function test_claim_RevertIf_RewardTokenNotSet() public {
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setMinter(minterAddr);

        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.claim();
    }

    function test_claim_RevertIf_MinterNotSet() public {
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));

        vm.expectRevert(IStableYieldAccumulator.ZeroAddress.selector);
        accumulator.claim();
    }

    function test_claim_RevertIf_AllTokensPaused() public {
        address claimer = _setupClaimScenario(100e18);

        // Pause the only strategy token — claim skips it, yielding zero total
        accumulator.pauseToken(address(strategyToken1));

        vm.prank(claimer);
        vm.expectRevert(IStableYieldAccumulator.ZeroAmount.selector);
        accumulator.claim();
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

        // 6. Setup yield: 100e18 yield in strategy
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, 100e18);
        strategyToken1.mint(address(mockStrategy1), 100e18);

        // 7. Fund claimer with reward tokens (98e18 needed for 2% discount)
        rewardToken.mint(claimer, 100e18);
        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        // 7.5. Approve Phlimbo to pull tokens from accumulator
        accumulator.approvePhlimbo(type(uint256).max);

        // 8. Claim and verify actual token transfers
        uint256 phlimboBalanceBefore = rewardToken.balanceOf(phlimboAddr);
        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);

        vm.prank(claimer);
        accumulator.claim();

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
        accumulator.claim();

        // Unpause
        vm.prank(pauser);
        accumulator.unpause();

        // Claim should now work and transfer actual tokens
        uint256 phlimboBalanceBefore = rewardToken.balanceOf(phlimboAddr);
        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);

        vm.prank(claimer);
        accumulator.claim();

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
     * @dev This test verifies the fix for the bug where getTotalYield() summed raw token amounts
     *      without normalizing them to a common 18-decimal base.
     *
     *      Scenario:
     *      - Strategy 1: 6-decimal token (like USDC) with 300 USDC yield (300e6 raw)
     *      - Strategy 2: 18-decimal token (like DOLA) with 4000 DOLA yield (4000e18 raw)
     *
     *      Bug behavior (before fix):
     *      - Returns 300e6 + 4000e18 = ~4000e18 (treating 300e6 as negligible)
     *
     *      Correct behavior (after fix):
     *      - Normalizes 300e6 to 300e18 (scales up by 10^12)
     *      - Returns 300e18 + 4000e18 = 4300e18
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

        // Claim should succeed, collecting only from unpaused strategy2
        vm.prank(claimer);
        accumulator.claim();

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

        // Record claimer's reward token balance before claim
        uint256 claimerBalanceBefore = rewardToken.balanceOf(claimer);

        // Execute claim
        vm.prank(claimer);
        accumulator.claim();

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

        // Claim — no tokens paused, should collect from both strategies
        vm.prank(claimer);
        accumulator.claim();

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
}

/**
 * @title MockPoolManager
 * @notice Mock Uniswap V4 PoolManager for testing price queries
 * @dev Provides configurable sqrtPriceX96 for slot0 queries
 */
contract MockPoolManager {
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint24 public protocolFee;
    uint24 public lpFee;

    // Mapping for extsload simulation
    mapping(bytes32 => bytes32) public slots;

    function setSqrtPriceX96(uint160 _sqrtPriceX96) external {
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function setSlot0(uint160 _sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _lpFee) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = _tick;
        protocolFee = _protocolFee;
        lpFee = _lpFee;
    }

    /**
     * @notice Mock extsload that returns packed slot0 data
     * @dev StateLibrary.getSlot0 uses this to get pool data
     */
    function extsload(bytes32 slot) external view returns (bytes32) {
        // Pack slot0 data: sqrtPriceX96 (160 bits) | tick (24 bits) | protocolFee (24 bits) | lpFee (24 bits)
        // Layout: lpFee (24) | protocolFee (24) | tick (24) | sqrtPriceX96 (160)
        uint256 packed = uint256(sqrtPriceX96);
        packed |= uint256(uint24(tick)) << 160;
        packed |= uint256(protocolFee) << 184;
        packed |= uint256(lpFee) << 208;
        return bytes32(packed);
    }

    function extsload(bytes32, uint256) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }
}

/**
 * @title MockSUSDS
 * @notice Mock sUSDS ERC4626 vault for testing convertToAssets
 * @dev Provides configurable exchange rate for sUSDS -> USDS conversion
 */
contract MockSUSDS {
    // Exchange rate: 1 sUSDS = exchangeRate / 1e18 USDS
    // e.g., 1.05e18 means 1 sUSDS = 1.05 USDS
    uint256 public exchangeRate = 1e18;

    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /**
     * @notice Convert sUSDS shares to USDS assets
     * @param shares Amount of sUSDS shares
     * @return Amount of USDS assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * exchangeRate / 1e18;
    }
}

/**
 * @title ConditionalClaimTest
 * @notice Tests for the conditional claim execution feature based on phUSD/sUSDS spot price
 */
contract ConditionalClaimTest is Test {
    StableYieldAccumulator public accumulator;
    MockERC20 public rewardToken;
    MockERC20 public strategyToken1;
    MockYieldStrategy public mockStrategy1;
    MockPhlimbo public mockPhlimbo;
    MockPoolManager public mockPoolManager;
    MockSUSDS public mockSUSDS;

    address public owner;
    address public minterAddr;
    address public phlimboAddr;
    address public claimer;
    address public phUSDAddr;

    // Events
    event PoolManagerUpdated(address indexed oldPoolManager, address indexed newPoolManager);
    event PricePoolUpdated(PoolId indexed poolId, bool token0IsPhUSD);
    event SUSDSUpdated(address indexed oldSUSDS, address indexed newSUSDS);
    event TargetPriceUpdated(uint256 oldTargetPrice, uint256 newTargetPrice);
    event PhUSDUpdated(address indexed oldPhUSD, address indexed newPhUSD);

    function setUp() public {
        owner = address(this);
        minterAddr = makeAddr("minter");
        claimer = makeAddr("claimer");
        phUSDAddr = makeAddr("phUSD");

        // Deploy mock tokens
        rewardToken = new MockERC20("Reward Token", "RWD");
        strategyToken1 = new MockERC20("Strategy Token 1", "STK1");

        // Deploy mock contracts
        mockStrategy1 = new MockYieldStrategy();
        mockPoolManager = new MockPoolManager();
        mockSUSDS = new MockSUSDS();

        // Deploy accumulator
        accumulator = new StableYieldAccumulator();

        // Deploy mock Phlimbo
        mockPhlimbo = new MockPhlimbo(address(rewardToken));
        mockPhlimbo.setYieldAccumulator(address(accumulator));
        phlimboAddr = address(mockPhlimbo);
    }

    /*//////////////////////////////////////////////////////////////
                    OWNER FUNCTION ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPoolManager_OnlyOwner() public {
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.setPoolManager(address(mockPoolManager));
    }

    function test_setPoolManager_Success() public {
        vm.expectEmit(true, true, false, true);
        emit PoolManagerUpdated(address(0), address(mockPoolManager));
        accumulator.setPoolManager(address(mockPoolManager));

        assertEq(address(accumulator.poolManager()), address(mockPoolManager));
    }

    function test_setPoolManager_CanSetToZero() public {
        accumulator.setPoolManager(address(mockPoolManager));
        accumulator.setPoolManager(address(0));
        assertEq(address(accumulator.poolManager()), address(0));
    }

    function test_setPricePool_OnlyOwner() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.setPricePool(poolId, true);
    }

    function test_setPricePool_Success() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(123)));

        vm.expectEmit(true, false, false, true);
        emit PricePoolUpdated(poolId, true);
        accumulator.setPricePool(poolId, true);

        assertTrue(PoolId.unwrap(accumulator.pricePoolId()) == bytes32(uint256(123)));
        assertTrue(accumulator.token0IsPhUSD());
    }

    function test_setSUSDS_OnlyOwner() public {
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.setSUSDS(address(mockSUSDS));
    }

    function test_setSUSDS_Success() public {
        vm.expectEmit(true, true, false, true);
        emit SUSDSUpdated(address(0), address(mockSUSDS));
        accumulator.setSUSDS(address(mockSUSDS));

        assertEq(address(accumulator.sUSDS()), address(mockSUSDS));
    }

    function test_setTargetPrice_OnlyOwner() public {
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.setTargetPrice(1e18);
    }

    function test_setTargetPrice_Success() public {
        vm.expectEmit(false, false, false, true);
        emit TargetPriceUpdated(0, 1e18);
        accumulator.setTargetPrice(1e18);

        assertEq(accumulator.targetPrice(), 1e18);
    }

    function test_setPhUSD_OnlyOwner() public {
        vm.prank(claimer);
        vm.expectRevert();
        accumulator.setPhUSD(phUSDAddr);
    }

    function test_setPhUSD_Success() public {
        vm.expectEmit(true, true, false, true);
        emit PhUSDUpdated(address(0), phUSDAddr);
        accumulator.setPhUSD(phUSDAddr);

        assertEq(accumulator.phUSD(), phUSDAddr);
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to set up price check infrastructure
     */
    function _setupPriceCheck(uint160 sqrtPriceX96, uint256 sUSDSRate, bool token0IsPhUSD) internal {
        accumulator.setPoolManager(address(mockPoolManager));
        accumulator.setSUSDS(address(mockSUSDS));
        accumulator.setPhUSD(phUSDAddr);

        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        accumulator.setPricePool(poolId, token0IsPhUSD);

        mockPoolManager.setSqrtPriceX96(sqrtPriceX96);
        mockSUSDS.setExchangeRate(sUSDSRate);
    }

    function test_claimPrice_ReturnsZeroIfPoolManagerNotSet() public {
        uint256 price = accumulator.claimPrice();
        assertEq(price, 0, "Should return 0 if poolManager not set");
    }

    function test_claimPrice_ReturnsPriceWhenConfigured() public {
        // Set sqrtPriceX96 for price = 1.0 (1e18)
        // sqrtPriceX96 = sqrt(1) * 2^96 = 2^96 = 79228162514264337593543950336
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        _setupPriceCheck(sqrtPriceX96, 1e18, true);

        uint256 price = accumulator.claimPrice();
        // Price should be approximately 1e18 (within precision tolerance)
        assertApproxEqRel(price, 1e18, 0.01e18, "Price should be approximately 1e18");
    }

    function test_claimPrice_Token0IsPhUSD_PriceAbove1() public {
        // sqrtPriceX96 for price = 1.1 (phUSD is worth 1.1 sUSDS)
        // sqrt(1.1) * 2^96 ≈ 83077498137502453155780008628
        uint160 sqrtPriceX96 = 83077498137502453155780008628;

        _setupPriceCheck(sqrtPriceX96, 1e18, true);

        uint256 price = accumulator.claimPrice();
        // Should be approximately 1.1e18
        assertApproxEqRel(price, 1.1e18, 0.01e18, "Price should be approximately 1.1e18");
    }

    function test_claimPrice_Token1IsPhUSD_PriceAbove1() public {
        // When token1 is phUSD, sqrtPriceX96 represents sqrt(phUSD/sUSDS)
        // For phUSD price = 1.1 sUSDS, sqrtPriceX96 = sqrt(1.1) * 2^96
        uint160 sqrtPriceX96 = 83077498137502453155780008628;

        _setupPriceCheck(sqrtPriceX96, 1e18, false);

        uint256 price = accumulator.claimPrice();
        // When token1IsPhUSD, we need 1/price, so price in sUSDS ≈ 0.909e18
        // But wait - if token1 is phUSD, then sqrtPriceX96 represents sqrt(phUSD/sUSDS)
        // So phUSD price = (sqrtPriceX96)^2 / 2^192 = 1.1
        // But we invert it: price = 2^192 / sqrtPriceX96^2 ≈ 0.909
        assertApproxEqRel(price, 0.909e18, 0.02e18, "Price should be approximately 0.909e18");
    }

    function test_claimPrice_WithSUSDSConversion() public {
        // sqrtPriceX96 for price = 1.0 in sUSDS terms
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        // sUSDS exchange rate: 1 sUSDS = 1.05 USDS
        _setupPriceCheck(sqrtPriceX96, 1.05e18, true);

        uint256 price = accumulator.claimPrice();
        // 1 phUSD = 1 sUSDS, and 1 sUSDS = 1.05 USDS
        // So 1 phUSD = 1.05 USDS
        assertApproxEqRel(price, 1.05e18, 0.01e18, "Price should be approximately 1.05e18 with sUSDS conversion");
    }

    /*//////////////////////////////////////////////////////////////
                    canClaim TESTS
    //////////////////////////////////////////////////////////////*/

    function test_canClaim_TrueWhenPoolManagerNotSet() public {
        assertTrue(accumulator.canClaim(), "Should return true when poolManager not set");
    }

    function test_canClaim_TrueWhenTargetPriceIsZero() public {
        accumulator.setPoolManager(address(mockPoolManager));
        // Don't set targetPrice (stays 0)
        assertTrue(accumulator.canClaim(), "Should return true when targetPrice is 0");
    }

    function test_canClaim_TrueWhenPriceAboveTarget() public {
        // Price = 1.1e18
        uint160 sqrtPriceX96 = 83077498137502453155780008628;
        _setupPriceCheck(sqrtPriceX96, 1e18, true);

        // Target = 1.0e18
        accumulator.setTargetPrice(1e18);

        assertTrue(accumulator.canClaim(), "Should return true when price >= target");
    }

    function test_canClaim_TrueWhenPriceEqualsTarget() public {
        // Price = 1.0e18
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        _setupPriceCheck(sqrtPriceX96, 1e18, true);

        // Target = 1.0e18
        accumulator.setTargetPrice(1e18);

        assertTrue(accumulator.canClaim(), "Should return true when price == target");
    }

    function test_canClaim_FalseWhenPriceBelowTarget() public {
        // Price = 0.9e18
        // sqrt(0.9) * 2^96 ≈ 75166920096232236089664808974
        uint160 sqrtPriceX96 = 75166920096232236089664808974;
        _setupPriceCheck(sqrtPriceX96, 1e18, true);

        // Target = 1.0e18
        accumulator.setTargetPrice(1e18);

        assertFalse(accumulator.canClaim(), "Should return false when price < target");
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIM WITH PRICE CHECK TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to set up a complete claim scenario with price check
     */
    function _setupClaimWithPriceCheck(uint256 yieldAmount, uint160 sqrtPriceX96, uint256 targetPriceValue) internal {
        // Setup basic claim infrastructure
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200); // 2% discount

        // Add strategy with token
        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));

        // Set token config
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        // Set up mock strategy with yield
        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, yieldAmount);
        strategyToken1.mint(address(mockStrategy1), yieldAmount);

        // Setup price check
        _setupPriceCheck(sqrtPriceX96, 1e18, true);
        accumulator.setTargetPrice(targetPriceValue);

        // Fund claimer with reward tokens
        uint256 claimerPayment = yieldAmount * 98 / 100;
        rewardToken.mint(claimer, claimerPayment + 1e18);

        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        // Approve Phlimbo
        accumulator.approvePhlimbo(type(uint256).max);
    }

    function test_claim_SucceedsWhenPriceAboveTarget() public {
        uint256 yieldAmount = 100e18;
        // Price = 1.1e18
        uint160 sqrtPriceX96 = 83077498137502453155780008628;
        // Target = 1.0e18
        uint256 targetPriceValue = 1e18;

        _setupClaimWithPriceCheck(yieldAmount, sqrtPriceX96, targetPriceValue);

        uint256 claimerYieldBefore = strategyToken1.balanceOf(claimer);

        vm.prank(claimer);
        accumulator.claim();

        uint256 claimerYieldAfter = strategyToken1.balanceOf(claimer);
        assertEq(claimerYieldAfter - claimerYieldBefore, yieldAmount, "Claimer should receive yield tokens");
    }

    function test_claim_RevertsWhenPriceBelowTarget() public {
        uint256 yieldAmount = 100e18;
        // Price = 0.9e18
        uint160 sqrtPriceX96 = 75166920096232236089664808974;
        // Target = 1.0e18
        uint256 targetPriceValue = 1e18;

        _setupClaimWithPriceCheck(yieldAmount, sqrtPriceX96, targetPriceValue);

        vm.prank(claimer);
        vm.expectRevert(abi.encodeWithSelector(
            IStableYieldAccumulator.phUSDPriceBelowTarget.selector,
            phUSDAddr,
            address(mockPoolManager),
            uint256(PoolId.unwrap(PoolId.wrap(bytes32(uint256(1)))))
        ));
        accumulator.claim();
    }

    function test_claim_SucceedsWhenPoolManagerNotSet() public {
        uint256 yieldAmount = 100e18;

        // Setup basic claim infrastructure WITHOUT price check
        accumulator.setPhlimbo(phlimboAddr);
        accumulator.setRewardToken(address(rewardToken));
        accumulator.setMinter(minterAddr);
        accumulator.setDiscountRate(200);

        accumulator.addYieldStrategy(address(mockStrategy1), address(strategyToken1));
        accumulator.setTokenConfig(address(strategyToken1), 18, 1e18);
        accumulator.setTokenConfig(address(rewardToken), 18, 1e18);

        mockStrategy1.setBalances(address(strategyToken1), minterAddr, 1000e18, yieldAmount);
        strategyToken1.mint(address(mockStrategy1), yieldAmount);

        uint256 claimerPayment = yieldAmount * 98 / 100;
        rewardToken.mint(claimer, claimerPayment + 1e18);

        vm.prank(claimer);
        rewardToken.approve(address(accumulator), type(uint256).max);

        accumulator.approvePhlimbo(type(uint256).max);

        // Set target price but NOT pool manager
        accumulator.setTargetPrice(1e18);

        // Should succeed because pool manager not set (graceful skip)
        vm.prank(claimer);
        accumulator.claim();

        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claim should succeed with poolManager not set");
    }

    function test_claim_SucceedsWhenTargetPriceIsZero() public {
        uint256 yieldAmount = 100e18;
        // Price = 0.9e18 (below typical target)
        uint160 sqrtPriceX96 = 75166920096232236089664808974;
        // Target = 0 (disabled)
        uint256 targetPriceValue = 0;

        _setupClaimWithPriceCheck(yieldAmount, sqrtPriceX96, targetPriceValue);

        // Should succeed because targetPrice is 0 (graceful skip)
        vm.prank(claimer);
        accumulator.claim();

        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claim should succeed with targetPrice = 0");
    }

    function test_claim_SucceedsWhenPriceExactlyEqualsTarget() public {
        uint256 yieldAmount = 100e18;
        // Price = 1.0e18
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        // Target = 1.0e18
        uint256 targetPriceValue = 1e18;

        _setupClaimWithPriceCheck(yieldAmount, sqrtPriceX96, targetPriceValue);

        vm.prank(claimer);
        accumulator.claim();

        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claim should succeed when price == target");
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullFlow_ConditionalClaimWithPriceIncrease() public {
        uint256 yieldAmount = 100e18;

        // Initial price = 0.9e18 (below target)
        uint160 lowPriceX96 = 75166920096232236089664808974;
        // Target = 1.0e18
        uint256 targetPriceValue = 1e18;

        _setupClaimWithPriceCheck(yieldAmount, lowPriceX96, targetPriceValue);

        // First attempt should fail - price below minimum
        vm.prank(claimer);
        vm.expectRevert(abi.encodeWithSelector(
            IStableYieldAccumulator.phUSDPriceBelowTarget.selector,
            phUSDAddr,
            address(mockPoolManager),
            uint256(PoolId.unwrap(PoolId.wrap(bytes32(uint256(1)))))
        ));
        accumulator.claim();

        // Price increases to 1.1e18
        uint160 highPriceX96 = 83077498137502453155780008628;
        mockPoolManager.setSqrtPriceX96(highPriceX96);

        // Now canClaim should return true
        assertTrue(accumulator.canClaim(), "canClaim should return true after price increase");

        // Second attempt should succeed
        vm.prank(claimer);
        accumulator.claim();

        assertEq(strategyToken1.balanceOf(claimer), yieldAmount, "Claim should succeed after price increase");
    }

    /*//////////////////////////////////////////////////////////////
                USDT-LIKE TOKEN COMPATIBILITY TESTS (M-03)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that second approvePhlimbo() succeeds after partial consumption by Phlimbo.
     * @dev With a USDT-like reward token, the first approvePhlimbo() sets a non-zero allowance.
     *      After Phlimbo partially consumes it via collectReward(), a residual allowance remains.
     *      A raw approve() would revert (non-zero -> non-zero). forceApprove() must handle this.
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
        // Mint tokens to accumulator and have Phlimbo pull 60 of the 100 approved.
        usdtToken.mint(address(acc), 100e18);

        // Phlimbo calls transferFrom via collectReward to pull 60e18
        // We need to prank as the accumulator to call collectReward
        // Instead, directly simulate: Phlimbo calls transferFrom on the USDT token
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

    /**
     * @notice Test that forceApprove pattern works correctly with MockUSDT.
     * @dev Validates that the approve-to-zero-then-to-new-value pattern handles
     *      USDT's non-standard behavior. Demonstrates the MockUSDT reverts on
     *      non-zero-to-non-zero and that the forceApprove workaround succeeds.
     */
    function test_forceApprove_PatternWorksCorrectly_WithUSDTMock() public {
        MockUSDT usdtToken = new MockUSDT("USDT", "USDT");
        usdtToken.mint(address(this), 1000e18);

        address spender = makeAddr("spender");

        // First approve (0 -> non-zero): should work
        usdtToken.approve(spender, 100e18);
        assertEq(usdtToken.allowance(address(this), spender), 100e18);

        // Raw non-zero-to-non-zero approve: should revert
        vm.expectRevert("USDT: approve from non-zero to non-zero");
        usdtToken.approve(spender, 200e18);

        // forceApprove pattern: approve to 0 first, then to new value
        usdtToken.approve(spender, 0);
        assertEq(usdtToken.allowance(address(this), spender), 0);

        usdtToken.approve(spender, 200e18);
        assertEq(usdtToken.allowance(address(this), spender), 200e18, "forceApprove pattern works");
    }

    function test_configurationUpdate_TargetPriceChange() public {
        // Setup with price = 0.95e18
        uint160 sqrtPriceX96 = 77193234817629166689178055120; // sqrt(0.95) * 2^96
        _setupPriceCheck(sqrtPriceX96, 1e18, true);

        // Target = 1.0e18 (price below target)
        accumulator.setTargetPrice(1e18);
        assertFalse(accumulator.canClaim(), "Should be false with target = 1.0e18");

        // Lower target to 0.9e18 (price now above target)
        accumulator.setTargetPrice(0.9e18);
        assertTrue(accumulator.canClaim(), "Should be true after lowering target");
    }
}
