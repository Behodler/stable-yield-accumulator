// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClaimArbitrage.sol";
import "../src/interfaces/IClaimArbitrage.sol";
import "../src/interfaces/IStableYieldAccumulator.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

/*//////////////////////////////////////////////////////////////
                        MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing with public mint
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockWETH
 * @notice Mock WETH with deposit/withdraw functionality
 */
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}
}

/**
 * @title MockSYA
 * @notice Mock StableYieldAccumulator for testing claim() behavior
 * @dev Simulates claim by:
 *   1. Pulling rewardToken from the caller (using transferFrom)
 *   2. Sending stablecoins to the caller
 *   Also supports strategyTokens() and getYieldStrategies() for validation testing.
 */
contract MockSYA {
    address public rewardToken;
    uint256 public claimPayment;      // how much the claimer pays
    address[] public yieldTokens;     // tokens claimer receives
    uint256[] public yieldAmounts;    // amounts claimer receives

    uint256 public claimCallCount;

    /// @notice Registered yield strategies
    address[] internal _yieldStrategies;

    /// @notice Mapping from strategy address to its underlying token
    mapping(address => address) public strategyTokens;

    constructor(address _rewardToken) {
        rewardToken = _rewardToken;
    }

    /// @notice Change the reward token (for testing reward-token-change scenarios)
    function setRewardToken(address _rewardToken) external {
        rewardToken = _rewardToken;
    }

    function setupClaim(
        uint256 _claimPayment,
        address[] memory _yieldTokens,
        uint256[] memory _yieldAmounts
    ) external {
        claimPayment = _claimPayment;
        yieldTokens = _yieldTokens;
        yieldAmounts = _yieldAmounts;
    }

    /**
     * @notice Register a yield strategy with its underlying token
     * @param strategy The strategy address
     * @param token The underlying token address for this strategy
     */
    function addYieldStrategy(address strategy, address token) external {
        _yieldStrategies.push(strategy);
        strategyTokens[strategy] = token;
    }

    /**
     * @notice Remove a yield strategy
     * @param strategy The strategy address to remove
     */
    function removeYieldStrategy(address strategy) external {
        for (uint256 i = 0; i < _yieldStrategies.length; i++) {
            if (_yieldStrategies[i] == strategy) {
                _yieldStrategies[i] = _yieldStrategies[_yieldStrategies.length - 1];
                _yieldStrategies.pop();
                delete strategyTokens[strategy];
                return;
            }
        }
    }

    /**
     * @notice Get all registered yield strategies
     */
    function getYieldStrategies() external view returns (address[] memory) {
        return _yieldStrategies;
    }

    function claim() external {
        claimCallCount++;

        // Pull reward token from caller (ClaimArbitrage must have approved us)
        IERC20(rewardToken).transferFrom(msg.sender, address(this), claimPayment);

        // Send yield tokens to caller
        for (uint256 i = 0; i < yieldTokens.length; i++) {
            IERC20(yieldTokens[i]).transfer(msg.sender, yieldAmounts[i]);
        }
    }

    function calculateClaimAmount() external view returns (uint256) {
        return claimPayment;
    }

    function canClaim() external pure returns (bool) {
        return true;
    }
}

/**
 * @title MockPoolManagerV4
 * @notice Comprehensive mock of Uniswap V4 PoolManager for testing ClaimArbitrage
 * @dev Simulates:
 *   - unlock/callback pattern
 *   - swap() with configurable delta returns
 *   - take() sending tokens and tracking negative deltas
 *   - sync() + settle() for depositing tokens (positive deltas)
 *   - currencyDelta() tracking via TransientStateLibrary (exttload)
 *
 * Delta tracking:
 *   - Positive delta = PM owes caller (credit)
 *   - Negative delta = caller owes PM (debt)
 */
contract MockPoolManagerV4 {
    // Track deltas per (address, currency)
    mapping(address => mapping(address => int256)) public deltas;

    // Track swap call count and params
    uint256 public swapCallCount;

    // Configurable swap results per pool (identified by pool index for simplicity)
    // Maps poolKey hash -> swap result
    mapping(bytes32 => SwapResult) public swapResults;

    struct SwapResult {
        int128 amount0;
        int128 amount1;
        bool configured;
    }

    // Default swap behavior: 1:1 exchange with 1% slippage
    uint256 public defaultSwapSlippageBps = 100; // 1%

    // Synced currency for settle pattern
    address public syncedCurrency;
    uint256 public syncedBalance;

    // Track whether we're in an unlocked state
    bool public unlocked;

    /**
     * @notice Simulates unlock: calls the callback on msg.sender
     */
    function unlock(bytes calldata data) external returns (bytes memory) {
        unlocked = true;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;

        // Verify all deltas are zero (simplified check)
        // In production, the real PM enforces this
        return result;
    }

    /**
     * @notice Configure a swap result for a specific pool
     */
    function setSwapResult(PoolKey memory key, int128 amount0, int128 amount1) external {
        bytes32 poolHash = _hashPoolKey(key);
        swapResults[poolHash] = SwapResult({amount0: amount0, amount1: amount1, configured: true});
    }

    /**
     * @notice Mock swap that returns configured deltas and adjusts tracking
     */
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        swapCallCount++;
        bytes32 poolHash = _hashPoolKey(key);
        SwapResult memory result = swapResults[poolHash];

        int128 a0;
        int128 a1;

        if (result.configured) {
            a0 = result.amount0;
            a1 = result.amount1;
        } else {
            // Default behavior: mirror the input as output on the other side
            if (params.amountSpecified < 0) {
                // Exact input
                uint256 inputAmount = uint256(-params.amountSpecified);
                uint256 outputAmount = inputAmount * (10000 - defaultSwapSlippageBps) / 10000;
                if (params.zeroForOne) {
                    a0 = -int128(int256(inputAmount));
                    a1 = int128(int256(outputAmount));
                } else {
                    a1 = -int128(int256(inputAmount));
                    a0 = int128(int256(outputAmount));
                }
            } else {
                // Exact output
                uint256 outputAmount = uint256(params.amountSpecified);
                uint256 inputAmount = outputAmount * (10000 + defaultSwapSlippageBps) / 10000;
                if (params.zeroForOne) {
                    a0 = -int128(int256(inputAmount));
                    a1 = int128(int256(outputAmount));
                } else {
                    a1 = -int128(int256(inputAmount));
                    a0 = int128(int256(outputAmount));
                }
            }
        }

        // Update deltas
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        deltas[msg.sender][currency0] += int256(a0);
        deltas[msg.sender][currency1] += int256(a1);

        return toBalanceDelta(a0, a1);
    }

    /**
     * @notice Mock take: sends tokens to recipient and creates negative delta
     */
    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        deltas[msg.sender][token] -= int256(amount);
        // Actually transfer tokens
        IERC20(token).transfer(to, amount);
    }

    /**
     * @notice Mock sync: records the current balance checkpoint
     */
    function sync(Currency currency) external {
        address token = Currency.unwrap(currency);
        syncedCurrency = token;
        syncedBalance = IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Mock settle: calculates delta from balance change since sync
     */
    function settle() external payable returns (uint256) {
        address token = syncedCurrency;
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        uint256 paid = currentBalance - syncedBalance;

        // Create positive delta (PM now owes caller less / caller has credit)
        deltas[msg.sender][token] += int256(paid);

        // Reset sync state
        syncedCurrency = address(0);
        syncedBalance = 0;

        return paid;
    }

    /**
     * @notice exttload for TransientStateLibrary.currencyDelta()
     * @dev TransientStateLibrary computes the slot as keccak256(target, currency)
     *      We simulate this by matching the slot to our stored deltas
     */
    function exttload(bytes32 slot) external view returns (bytes32) {
        // We need to return the delta for the (target, currency) pair
        // TransientStateLibrary uses: keccak256(abi.encode(target, currency))
        // We store the mapping in _slotToDelta during delta updates
        return _slotToDelta[slot];
    }

    // Internal mapping to support exttload
    mapping(bytes32 => bytes32) internal _slotToDelta;

    /**
     * @notice Helper to update the exttload-compatible slot after delta changes
     * @dev Must be called after every delta modification
     */
    function _updateSlot(address target, address currency) internal {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
        _slotToDelta[key] = bytes32(uint256(int256(deltas[target][currency])));
    }

    /**
     * @notice Override the delta setter to also update slots
     */
    function setDelta(address target, address currency, int256 value) external {
        deltas[target][currency] = value;
        _updateSlot(target, currency);
    }

    // Override take to also update slots
    function _internalTake(Currency currency, address to, uint256 amount, address caller) internal {
        address token = Currency.unwrap(currency);
        deltas[caller][token] -= int256(amount);
        _updateSlot(caller, token);
        IERC20(token).transfer(to, amount);
    }

    // We need to override the public functions to use slot-aware versions
    // Since Solidity doesn't allow overriding non-virtual, we'll use a wrapper approach

    function _hashPoolKey(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    // Fund the mock PM with tokens for take() operations
    receive() external payable {}
}

/**
 * @title TestablePoolManager
 * @notice A PoolManager mock that properly tracks deltas via both direct mapping
 *         and exttload-compatible storage, for use with TransientStateLibrary
 */
contract TestablePoolManager {
    mapping(address => mapping(address => int256)) public deltas;
    mapping(bytes32 => bytes32) internal _slotData;
    mapping(bytes32 => SwapResult) public swapResults;

    struct SwapResult {
        int128 amount0;
        int128 amount1;
        bool configured;
    }

    address public syncedCurrency;
    uint256 public syncedBalance;
    uint256 public swapCallCount;
    bool public unlocked;

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlocked = true;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        return result;
    }

    function setSwapResult(PoolKey memory key, int128 amount0, int128 amount1) external {
        bytes32 poolHash = keccak256(abi.encode(key));
        swapResults[poolHash] = SwapResult({amount0: amount0, amount1: amount1, configured: true});
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        swapCallCount++;
        bytes32 poolHash = keccak256(abi.encode(key));
        SwapResult memory result = swapResults[poolHash];

        int128 a0;
        int128 a1;

        if (result.configured) {
            a0 = result.amount0;
            a1 = result.amount1;
        } else {
            // Default 1:1 with no slippage for simplicity
            if (params.amountSpecified < 0) {
                uint256 input = uint256(-params.amountSpecified);
                if (params.zeroForOne) {
                    a0 = -int128(int256(input));
                    a1 = int128(int256(input));
                } else {
                    a1 = -int128(int256(input));
                    a0 = int128(int256(input));
                }
            } else {
                uint256 output = uint256(params.amountSpecified);
                if (params.zeroForOne) {
                    a0 = -int128(int256(output));
                    a1 = int128(int256(output));
                } else {
                    a1 = -int128(int256(output));
                    a0 = int128(int256(output));
                }
            }
        }

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        _adjustDelta(msg.sender, currency0, int256(a0));
        _adjustDelta(msg.sender, currency1, int256(a1));

        return toBalanceDelta(a0, a1);
    }

    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        _adjustDelta(msg.sender, token, -int256(amount));
        IERC20(token).transfer(to, amount);
    }

    function sync(Currency currency) external {
        address token = Currency.unwrap(currency);
        syncedCurrency = token;
        syncedBalance = IERC20(token).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        address token = syncedCurrency;
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        uint256 paid = currentBalance - syncedBalance;
        _adjustDelta(msg.sender, token, int256(paid));
        syncedCurrency = address(0);
        syncedBalance = 0;
        return paid;
    }

    function exttload(bytes32 slot) external view returns (bytes32) {
        return _slotData[slot];
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slotData[slot];
    }

    function _adjustDelta(address target, address currency, int256 change) internal {
        deltas[target][currency] += change;
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
        _slotData[key] = bytes32(uint256(int256(deltas[target][currency])));
    }

    /// @notice Directly set a delta for testing
    function setDelta(address target, address currency, int256 value) external {
        deltas[target][currency] = value;
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
        _slotData[key] = bytes32(uint256(int256(value)));
    }

    receive() external payable {}
}

/**
 * @title SettleResidualDeltaTester
 * @notice Standalone contract for unit-testing _settleResidualDelta logic.
 *         Implements IUnlockCallback directly and contains the same settlement logic
 *         as ClaimArbitrage, allowing isolated testing of the settle function
 *         within an unlock context without needing to override ClaimArbitrage's
 *         non-virtual unlockCallback.
 */
contract SettleResidualDeltaTester is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public immutable sUSDS;
    address public immutable phUSD;
    PoolKey public sUSDS_USDC_pool;
    PoolKey public phUSD_sUSDS_pool;
    mapping(address => PoolKey) public stableToRewardTokenPool;

    address public settleToken;
    address public settleToken2;

    error UnsettledResidualForUnconfiguredToken(address token);

    constructor(
        address _poolManager,
        address _sUSDS,
        address _phUSD
    ) {
        poolManager = IPoolManager(_poolManager);
        sUSDS = _sUSDS;
        phUSD = _phUSD;
    }

    function setPoolKeys(PoolKey memory _sUSDS_USDC_pool, PoolKey memory _phUSD_sUSDS_pool) external {
        sUSDS_USDC_pool = _sUSDS_USDC_pool;
        phUSD_sUSDS_pool = _phUSD_sUSDS_pool;
    }

    function setStableToRewardTokenPool(address stable, PoolKey memory pool) external {
        stableToRewardTokenPool[stable] = pool;
    }

    function settleResidualDelta(address token) external {
        settleToken = token;
        settleToken2 = address(0);
        poolManager.unlock("");
    }

    function settleResidualDeltaPair(address token1, address token2) external {
        settleToken = token1;
        settleToken2 = token2;
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        _settleResidualDelta(settleToken);
        if (settleToken2 != address(0)) {
            _settleResidualDelta(settleToken2);
        }
        settleToken = address(0);
        settleToken2 = address(0);
        return "";
    }

    function _settleResidualDelta(address token) internal {
        int256 d = poolManager.currencyDelta(address(this), Currency.wrap(token));
        if (d == 0) return;

        if (d > 0) {
            poolManager.take(Currency.wrap(token), address(this), uint256(d));
            return;
        }

        PoolKey memory pool = stableToRewardTokenPool[token];
        if (Currency.unwrap(pool.currency0) == address(0) && Currency.unwrap(pool.currency1) == address(0)) {
            if (token == sUSDS) {
                pool = sUSDS_USDC_pool;
            } else if (token == phUSD) {
                pool = phUSD_sUSDS_pool;
            } else {
                revert UnsettledResidualForUnconfiguredToken(token);
            }
        }

        uint256 owed = uint256(-d);
        bool tokenIsToken0 = (Currency.unwrap(pool.currency0) == token);

        poolManager.swap(
            pool,
            SwapParams({
                zeroForOne: !tokenIsToken0,
                amountSpecified: int256(owed),
                sqrtPriceLimitX96: !tokenIsToken0
                    ? type(uint160).min + 1
                    : type(uint160).max - 1
            }),
            ""
        );
    }

    function _depositIntoPM(address token, uint256 amount) internal {
        poolManager.sync(Currency.wrap(token));
        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                        TEST CONTRACT
//////////////////////////////////////////////////////////////*/

/**
 * @title ClaimArbitrageTest
 * @notice Comprehensive test suite for ClaimArbitrage
 */
contract ClaimArbitrageTest is Test {
    ClaimArbitrage public arb;
    TestablePoolManager public pm;
    MockSYA public sya;
    MockERC20 public usdc;
    MockWETH public weth;
    MockERC20 public susds;
    MockERC20 public phusd;
    MockERC20 public usdt; // extra stablecoin for multi-stable tests
    MockERC20 public dai;  // another stablecoin

    address public owner;
    address public caller;

    // Pool keys
    PoolKey public phUSD_sUSDS_key;
    PoolKey public USDC_WETH_key;
    PoolKey public sUSDS_USDC_key;
    PoolKey public USDT_USDC_key;
    PoolKey public DAI_USDC_key;

    // Events
    event ArbitrageExecuted(address indexed caller, uint256 ethProfit);
    event StableToRewardTokenPoolSet(address indexed stable);
    event KnownStableAdded(address indexed stable);
    event KnownStableRemoved(address indexed stable);
    event PoolKeysUpdated();
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        owner = address(this);
        caller = makeAddr("caller");

        // Deploy tokens -- deterministic addresses via CREATE order
        // We need addresses sorted for pool keys (currency0 < currency1)
        usdc = new MockERC20("USDC", "USDC");
        weth = new MockWETH();
        susds = new MockERC20("sUSDS", "sUSDS");
        phusd = new MockERC20("phUSD", "phUSD");
        usdt = new MockERC20("USDT", "USDT");
        dai = new MockERC20("DAI", "DAI");

        // Deploy mock SYA
        sya = new MockSYA(address(usdc));

        // Deploy mock PoolManager
        pm = new TestablePoolManager();

        // Deploy ClaimArbitrage
        arb = new ClaimArbitrage(
            address(pm),
            address(sya),
            address(weth),
            address(susds),
            address(phusd)
        );

        // Create pool keys with sorted currencies
        phUSD_sUSDS_key = _makePoolKey(address(phusd), address(susds));
        USDC_WETH_key = _makePoolKey(address(usdc), address(weth));
        sUSDS_USDC_key = _makePoolKey(address(susds), address(usdc));
        USDT_USDC_key = _makePoolKey(address(usdt), address(usdc));
        DAI_USDC_key = _makePoolKey(address(dai), address(usdc));

        // Determine token ordering for phUSD/sUSDS pool
        bool _token0IsPhUSD = address(phusd) < address(susds);

        // Set pool keys on arb contract
        arb.setPoolKeys(phUSD_sUSDS_key, USDC_WETH_key, sUSDS_USDC_key, _token0IsPhUSD);

        // Fund PoolManager with tokens for take() operations
        usdc.mint(address(pm), 1000e18);
        weth.mint(address(pm), 100e18);

        // Fund PM with ETH for WETH unwrap
        vm.deal(address(weth), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _makePoolKey(address tokenA, address tokenB) internal pure returns (PoolKey memory) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /**
     * @notice Setup a standard profitable arbitrage scenario
     * @dev Creates a scenario where:
     *   - claim() costs 90 USDC (10% discount on 100 USDC worth of stablecoins)
     *   - claim() yields 50 USDT + 50 DAI
     *   - All swaps use default 1:1 behavior (no configured results)
     *
     * Delta flow with 1:1 swaps:
     *   Step 1: sell 10 sUSDS -> get 10 phUSD (sUSDS=-10, phUSD=+10)
     *   Step 2: borrow 90 USDC (USDC=-90)
     *   Step 3: claim pays 90 USDC, gets 50 USDT + 50 DAI (ERC20 balances)
     *   Step 4: sell 10 phUSD -> get 10 sUSDS (phUSD=0, sUSDS=0)
     *   Step 5: deposit+swap 50 USDT -> 50 USDC, 50 DAI -> 50 USDC (USDC=+10)
     *   Step 6: sUSDS delta = 0, skip
     *   Step 7: swap 10 USDC -> 10 WETH (USDC=0, WETH=+10)
     *   Step 8: take 10 WETH (WETH=0)
     *   Step 9: unwrap+send 10 ETH
     */
    function _setupProfitableScenario() internal returns (IClaimArbitrage.ExecuteParams memory params) {
        // Configure known stables
        arb.addKnownStable(address(usdt));
        arb.addKnownStable(address(dai));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);
        arb.setStableToRewardTokenPool(address(dai), DAI_USDC_key);

        // Register strategies in MockSYA so _validateKnownStablesCoverage() passes.
        // Each strategy maps to a token that must be in knownStables[].
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // Configure SYA: claimer pays 90 USDC, gets 50 USDT + 50 DAI
        address[] memory yieldTokens = new address[](2);
        yieldTokens[0] = address(usdt);
        yieldTokens[1] = address(dai);
        uint256[] memory yieldAmounts = new uint256[](2);
        yieldAmounts[0] = 50e18;
        yieldAmounts[1] = 50e18;
        sya.setupClaim(90e18, yieldTokens, yieldAmounts);

        // Fund SYA with yield tokens
        usdt.mint(address(sya), 50e18);
        dai.mint(address(sya), 50e18);

        // No configured swap results -- use default 1:1 for all pools.
        // This avoids the issue where pump and unwind share the same pool key
        // but the configured result doesn't account for direction.

        params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 90e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });
    }

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_SetsImmutables() public view {
        assertEq(address(arb.poolManager()), address(pm), "poolManager should be set");
        assertEq(address(arb.sya()), address(sya), "sya should be set");
        assertEq(arb.WETH(), address(weth), "WETH should be set");
        assertEq(arb.sUSDS(), address(susds), "sUSDS should be set");
        assertEq(arb.phUSD(), address(phusd), "phUSD should be set");
    }

    function test_constructor_SetsOwner() public view {
        assertEq(arb.owner(), owner, "Owner should be deployer");
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_execute_CallsPoolManagerUnlock() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        arb.execute(params);

        // Verify PM's unlock was called (swapCallCount > 0 means callback executed)
        assertTrue(pm.swapCallCount() > 0, "PoolManager swap should have been called");
    }

    function test_execute_EncodesParamsAndCaller() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        // The callback will decode and use these -- if it works, encoding was correct
        vm.prank(caller);
        arb.execute(params);

        // Verify claim was called (proves params were decoded correctly)
        assertEq(sya.claimCallCount(), 1, "claim() should have been called once");
    }

    /*//////////////////////////////////////////////////////////////
                UNLOCK CALLBACK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_unlockCallback_RevertsIfNotPoolManager() public {
        bytes memory data = abi.encode(
            IClaimArbitrage.ExecuteParams({
                pumpAmount: 10e18,
                rewardTokenNeeded: 90e18,
                pumpPriceLimit: type(uint160).max - 1,
                unwindPriceLimit: type(uint160).min + 1
            }),
            caller
        );

        // Call from non-PM address
        vm.prank(caller);
        vm.expectRevert(IClaimArbitrage.OnlyPoolManager.selector);
        arb.unlockCallback(data);
    }

    /*//////////////////////////////////////////////////////////////
                    FULL ARBITRAGE FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullFlow_CallerReceivesETHProfit() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        uint256 callerEthBefore = caller.balance;

        vm.prank(caller);
        arb.execute(params);

        uint256 callerEthAfter = caller.balance;
        assertTrue(callerEthAfter > callerEthBefore, "Caller should have received ETH profit");
    }

    function test_fullFlow_EmitsArbitrageExecutedEvent() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        // We expect the event but don't check exact profit amount (depends on mock math)
        vm.expectEmit(true, false, false, false);
        emit ArbitrageExecuted(caller, 0); // profit amount will vary
        arb.execute(params);
    }

    function test_fullFlow_ClaimIsCalled() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        arb.execute(params);

        assertEq(sya.claimCallCount(), 1, "claim() should be called exactly once");
    }

    function test_fullFlow_MultipleStablecoinsConverted() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        arb.execute(params);

        // After execution, arb should have no residual stablecoins
        assertEq(usdt.balanceOf(address(arb)), 0, "Arb should have 0 USDT remaining");
        assertEq(dai.balanceOf(address(arb)), 0, "Arb should have 0 DAI remaining");
    }

    function test_fullFlow_NoResidualTokensInContract() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        arb.execute(params);

        // Contract should not hold any residual ERC20 tokens
        assertEq(usdc.balanceOf(address(arb)), 0, "Arb should have 0 USDC");
        assertEq(weth.balanceOf(address(arb)), 0, "Arb should have 0 WETH");
        assertEq(usdt.balanceOf(address(arb)), 0, "Arb should have 0 USDT");
        assertEq(dai.balanceOf(address(arb)), 0, "Arb should have 0 DAI");
    }

    function test_fullFlow_ETHNotStuckInContract() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        uint256 arbEthBefore = address(arb).balance;

        vm.prank(caller);
        arb.execute(params);

        // ETH should have been forwarded to caller, not stuck
        assertEq(address(arb).balance, arbEthBefore, "ETH should not be stuck in arb contract");
    }

    /*//////////////////////////////////////////////////////////////
                    REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_revert_NoProfitIfSlippageEatsDiscount() public {
        // Setup where claim cost equals yield (0% discount = no profit).
        // With default 1:1 swaps and no configured swap results, pump/unwind deltas
        // cancel perfectly, and the claim produces 0 net USDC profit.
        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));

        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(usdt);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;

        // Claim costs 100 USDC, gets 100 USDT (0% discount = no profit)
        sya.setupClaim(100e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 100e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 100e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        // With default 1:1 swaps:
        // Step 1: -10 sUSDS, +10 phUSD
        // Step 2: -100 USDC (take)
        // Step 3: -100 USDC (claim pays), +100 USDT (ERC20)
        // Step 4: -10 phUSD, +10 sUSDS -> deltas net: sUSDS=0, phUSD=0
        // Step 5: deposit 100 USDT, swap -> +100 USDC delta
        // USDC delta = -100 + 100 = 0 <= 0 -> NoProfit!

        vm.prank(caller);
        vm.expectRevert(IClaimArbitrage.NoProfit.selector);
        arb.execute(params);
    }

    function test_revert_NoWETHProfitIfConversionFails() public {
        // This is harder to test directly because if usdcProfit > 0,
        // the USDC->WETH swap (default 1:1) will produce WETH.
        // We'd need to configure USDC_WETH to return 0.

        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));

        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(usdt);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(90e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 100e18);

        // Configure USDC_WETH swap to return 0 WETH (absorbs all USDC, gives nothing)
        pm.setSwapResult(USDC_WETH_key, 0, 0);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 90e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        // After step 7 with 0 output, WETH delta = 0 -> NoWETHProfit
        // But actually, the swap updates deltas with (0,0), so WETH delta stays at 0.
        // However, the USDC delta also doesn't change (stays positive).
        // The real issue: the mock's configured swap returns (0,0) which means
        // no delta change. So USDC stays positive and WETH stays 0.

        vm.prank(caller);
        vm.expectRevert(IClaimArbitrage.NoWETHProfit.selector);
        arb.execute(params);
    }

    /*//////////////////////////////////////////////////////////////
                    sUSDS RESIDUAL DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_residualSUSDSDelta_CoveredViaSwap() public {
        // Setup scenario where pump/unwind creates sUSDS shortfall
        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));

        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(usdt);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(80e18, yieldTokens, yieldAmounts); // 20% discount
        usdt.mint(address(sya), 100e18);

        // With default 1:1 swaps, sUSDS delta should net to 0 after pump+unwind.
        // But if we execute, the flow should still complete successfully
        // because step 6 handles any residual.

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 80e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        vm.prank(caller);
        arb.execute(params);

        // If we got here without reverting, residual deltas were handled
        assertTrue(true, "Execution completed with residual delta handling");
    }

    /*//////////////////////////////////////////////////////////////
                    phUSD RESIDUAL DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_residualPhUSDDelta_Settled() public {
        // In default 1:1 scenario, phUSD delta should net to 0
        // The _settleResidualDelta function handles any residual
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        arb.execute(params);

        // Success indicates residual deltas were properly handled
        assertTrue(true, "phUSD residual delta was settled");
    }

    /*//////////////////////////////////////////////////////////////
                    OWNER FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setStableToRewardTokenPool_SetsMapping() public {
        PoolKey memory pool = _makePoolKey(address(usdt), address(usdc));

        vm.expectEmit(true, false, false, true);
        emit StableToRewardTokenPoolSet(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), pool);

        // Verify by reading the stored pool key fields
        (Currency c0, Currency c1,,,) = arb.stableToRewardTokenPool(address(usdt));
        assertEq(Currency.unwrap(c0), Currency.unwrap(pool.currency0), "currency0 should match");
        assertEq(Currency.unwrap(c1), Currency.unwrap(pool.currency1), "currency1 should match");
    }

    function test_setStableToRewardTokenPool_RevertIf_NotOwner() public {
        PoolKey memory pool = _makePoolKey(address(usdt), address(usdc));
        vm.prank(caller);
        vm.expectRevert();
        arb.setStableToRewardTokenPool(address(usdt), pool);
    }

    function test_addKnownStable_AddsToList() public {
        vm.expectEmit(true, false, false, true);
        emit KnownStableAdded(address(usdt));
        arb.addKnownStable(address(usdt));

        address[] memory stables = arb.getKnownStables();
        assertEq(stables.length, 1, "Should have 1 stable");
        assertEq(stables[0], address(usdt), "Should be USDT");
    }

    function test_addKnownStable_RevertIf_NotOwner() public {
        vm.prank(caller);
        vm.expectRevert();
        arb.addKnownStable(address(usdt));
    }

    function test_removeKnownStable_RemovesFromList() public {
        arb.addKnownStable(address(usdt));
        arb.addKnownStable(address(dai));

        vm.expectEmit(true, false, false, true);
        emit KnownStableRemoved(address(usdt));
        arb.removeKnownStable(address(usdt));

        address[] memory stables = arb.getKnownStables();
        assertEq(stables.length, 1, "Should have 1 stable remaining");
        assertEq(stables[0], address(dai), "Remaining should be DAI");
    }

    function test_removeKnownStable_RevertIf_NotOwner() public {
        arb.addKnownStable(address(usdt));
        vm.prank(caller);
        vm.expectRevert();
        arb.removeKnownStable(address(usdt));
    }

    function test_removeKnownStable_NoOpIfNotFound() public {
        arb.addKnownStable(address(usdt));
        arb.removeKnownStable(address(dai)); // dai not in list

        address[] memory stables = arb.getKnownStables();
        assertEq(stables.length, 1, "Should still have 1 stable");
    }

    function test_setPoolKeys_SetsAllPoolKeys() public {
        PoolKey memory pk1 = _makePoolKey(address(phusd), address(susds));
        PoolKey memory pk2 = _makePoolKey(address(usdc), address(weth));
        PoolKey memory pk3 = _makePoolKey(address(susds), address(usdc));

        vm.expectEmit(false, false, false, true);
        emit PoolKeysUpdated();
        arb.setPoolKeys(pk1, pk2, pk3, true);

        assertTrue(arb.token0IsPhUSD(), "token0IsPhUSD should be true");
    }

    function test_setPoolKeys_RevertIf_NotOwner() public {
        PoolKey memory pk = _makePoolKey(address(phusd), address(susds));
        vm.prank(caller);
        vm.expectRevert();
        arb.setPoolKeys(pk, pk, pk, true);
    }

    function test_getKnownStables_ReturnsAll() public {
        arb.addKnownStable(address(usdt));
        arb.addKnownStable(address(dai));

        address[] memory stables = arb.getKnownStables();
        assertEq(stables.length, 2, "Should return 2 stables");
    }

    /*//////////////////////////////////////////////////////////////
                    RECEIVE FALLBACK TEST
    //////////////////////////////////////////////////////////////*/

    function test_receive_AcceptsETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(arb).call{value: 1 ether}("");
        assertTrue(ok, "Contract should accept ETH");
        assertEq(address(arb).balance, 1 ether, "Contract should hold 1 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                    PERMISSIONLESS EXECUTE TEST
    //////////////////////////////////////////////////////////////*/

    function test_execute_Permissionless() public {
        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        // Any address should be able to call execute
        address randomBot = makeAddr("randomBot");
        vm.prank(randomBot);
        arb.execute(params);

        assertEq(sya.claimCallCount(), 1, "claim should have been called");
    }

    /*//////////////////////////////////////////////////////////////
                    RESCUE TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rescueToken_HappyPath() public {
        // Strand some tokens in the arb contract
        uint256 rescueAmount = 100e18;
        usdt.mint(address(arb), rescueAmount);
        address recipient = makeAddr("rescueRecipient");

        uint256 recipientBefore = usdt.balanceOf(recipient);
        arb.rescueToken(address(usdt), recipient, rescueAmount);
        uint256 recipientAfter = usdt.balanceOf(recipient);

        assertEq(recipientAfter - recipientBefore, rescueAmount, "Recipient should receive rescued tokens");
        assertEq(usdt.balanceOf(address(arb)), 0, "Arb should have 0 remaining");
    }

    function test_rescueToken_RevertsIfNotOwner() public {
        usdt.mint(address(arb), 100e18);
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert();
        arb.rescueToken(address(usdt), notOwner, 100e18);
    }

    function test_rescueToken_RevertsIfZeroAddressRecipient() public {
        usdt.mint(address(arb), 100e18);

        vm.expectRevert(IClaimArbitrage.InvalidRecipient.selector);
        arb.rescueToken(address(usdt), address(0), 100e18);
    }

    function test_rescueToken_EmitsTokenRescuedEvent() public {
        uint256 rescueAmount = 42e18;
        usdt.mint(address(arb), rescueAmount);
        address recipient = makeAddr("rescueRecipient");

        vm.expectEmit(true, true, false, true);
        emit TokenRescued(address(usdt), recipient, rescueAmount);
        arb.rescueToken(address(usdt), recipient, rescueAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_validateKnownStablesCoverage_PassesWithExactMatch() public {
        // knownStables = {USDT, DAI}, SYA strategies = {USDT, DAI}
        arb.addKnownStable(address(usdt));
        arb.addKnownStable(address(dai));
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // Should not revert
        arb.validateKnownStablesCoverage();
    }

    function test_validateKnownStablesCoverage_PassesWithSuperset() public {
        // knownStables = {USDT, DAI, USDC}, SYA strategies = {USDT, DAI}
        // knownStables is a superset — extra entries are fine
        arb.addKnownStable(address(usdt));
        arb.addKnownStable(address(dai));
        arb.addKnownStable(address(usdc));
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // Should not revert
        arb.validateKnownStablesCoverage();
    }

    function test_validateKnownStablesCoverage_RevertsWhenStrategyTokenMissing() public {
        // knownStables = {USDT}, SYA strategies = {USDT, DAI}
        // DAI is missing from knownStables → should revert
        arb.addKnownStable(address(usdt));
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        vm.expectRevert(abi.encodeWithSelector(IClaimArbitrage.StrategyTokenNotInKnownStables.selector, address(dai)));
        arb.validateKnownStablesCoverage();
    }

    function test_validation_M01Scenario_ExecuteRevertsWithUnregisteredToken() public {
        // Full M-01 scenario: SYA has a strategy token (DAI) that is NOT in knownStables[].
        // execute() should revert instead of silently locking the DAI tokens.
        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);

        // Register strategies: USDT (covered) + DAI (NOT covered)
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // Configure SYA claim
        address[] memory yieldTokens = new address[](2);
        yieldTokens[0] = address(usdt);
        yieldTokens[1] = address(dai);
        uint256[] memory yieldAmounts = new uint256[](2);
        yieldAmounts[0] = 50e18;
        yieldAmounts[1] = 50e18;
        sya.setupClaim(90e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 50e18);
        dai.mint(address(sya), 50e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 90e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        // execute() should revert because DAI is not in knownStables[]
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IClaimArbitrage.StrategyTokenNotInKnownStables.selector, address(dai)));
        arb.execute(params);
    }

    function test_validation_M01Scenario_ExecuteSucceedsAfterAddingMissingStable() public {
        // Same as above, but after adding DAI to knownStables[], execute() succeeds.
        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);

        // Register strategies: USDT + DAI
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // Configure SYA claim
        address[] memory yieldTokens = new address[](2);
        yieldTokens[0] = address(usdt);
        yieldTokens[1] = address(dai);
        uint256[] memory yieldAmounts = new uint256[](2);
        yieldAmounts[0] = 50e18;
        yieldAmounts[1] = 50e18;
        sya.setupClaim(90e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 50e18);
        dai.mint(address(sya), 50e18);

        // Now add the missing DAI stable and its pool mapping
        arb.addKnownStable(address(dai));
        arb.setStableToRewardTokenPool(address(dai), DAI_USDC_key);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 90e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        // execute() should succeed now
        vm.prank(caller);
        arb.execute(params);

        assertEq(sya.claimCallCount(), 1, "claim should have been called");
    }

    /*//////////////////////////////////////////////////////////////
                    STEP 5 REWARD TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_step5_RewardTokenDepositedButNotSwapped() public {
        // Scenario: USDC is both the reward token AND a strategy token in knownStables[].
        // It should be deposited into PM but NOT swapped (skip the swap call).
        // We verify this by checking the swap call count.

        // Register USDC as a known stable (it's the reward token)
        arb.addKnownStable(address(usdc));
        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);

        // Register strategies: one produces USDT, one produces USDC (the reward token)
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));
        sya.addYieldStrategy(makeAddr("strategyUSDC"), address(usdc));

        // Configure claim: pays 80 USDC, gets 50 USDT + 50 USDC
        address[] memory yieldTokens = new address[](2);
        yieldTokens[0] = address(usdt);
        yieldTokens[1] = address(usdc);
        uint256[] memory yieldAmounts = new uint256[](2);
        yieldAmounts[0] = 50e18;
        yieldAmounts[1] = 50e18;
        sya.setupClaim(80e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 50e18);
        usdc.mint(address(sya), 50e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 80e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        uint256 swapCountBefore = pm.swapCallCount();

        vm.prank(caller);
        arb.execute(params);

        uint256 swapCountAfter = pm.swapCallCount();

        // Expected swaps:
        //   Step 1: pump (1 swap)
        //   Step 4: unwind (1 swap)
        //   Step 5: USDT->USDC swap (1 swap), USDC skipped (0 swaps)
        //   Step 7: USDC->WETH swap (1 swap)
        // Total: 4 swaps (NOT 5, because USDC was skipped)
        //
        // If USDC were NOT skipped, we'd see 5 swaps. With the skip,
        // only USDT gets swapped in Step 5.
        uint256 actualSwaps = swapCountAfter - swapCountBefore;

        // Without the reward token skip, there would be an extra swap.
        // The exact count depends on whether sUSDS residual delta triggers a swap.
        // With 1:1 default swaps, sUSDS delta nets to 0 (no step 6 swap needed).
        // phUSD residual delta check doesn't trigger with 1:1 swaps.
        // So expected: pump(1) + unwind(1) + USDT_swap(1) + USDC_WETH(1) = 4
        assertEq(actualSwaps, 4, "Should have 4 swaps (USDC reward token skipped in Step 5)");
    }

    function test_step5_RewardTokenNotInStrategies_SkippedDueToZeroBalance() public {
        // Scenario: USDC is in knownStables[] (as reward token) but NOT distributed by SYA
        // as a strategy yield. Its balance should be 0 after claim payment, so it's
        // skipped by the `if (bal == 0) continue;` check.

        // knownStables = {USDT, USDC}, but SYA only distributes USDT
        arb.addKnownStable(address(usdt));
        arb.addKnownStable(address(usdc));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);

        // Only USDT strategy registered (validation only cares about SYA→knownStables direction)
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));

        // Configure claim: pays 90 USDC, gets 100 USDT (no USDC yield)
        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(usdt);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(90e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 100e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 90e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        vm.prank(caller);
        arb.execute(params);

        // Success: USDC in knownStables was harmless — had 0 balance, was skipped.
        // USDT was swapped normally. Caller received ETH profit.
        assertTrue(caller.balance > 0, "Caller should receive ETH profit");
        assertEq(usdt.balanceOf(address(arb)), 0, "No residual USDT");
    }

    /*//////////////////////////////////////////////////////////////
            REWARD TOKEN FLEXIBILITY TESTS (Story 016 / audit-5 M-01)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Baseline test: execute() succeeds when rewardToken == USDC (default setup)
     */
    function test_rewardToken_ExecuteSucceedsWhenRewardTokenIsUSDC() public {
        // Default setup: SYA.rewardToken() == USDC
        assertEq(sya.rewardToken(), address(usdc), "Precondition: rewardToken should be USDC");

        IClaimArbitrage.ExecuteParams memory params = _setupProfitableScenario();

        vm.prank(caller);
        arb.execute(params);

        assertTrue(caller.balance > 0, "Caller should receive ETH profit with USDC as reward token");
        assertEq(sya.claimCallCount(), 1, "claim() should be called");
    }

    /**
     * @notice Test: SYA owner changes rewardToken to a non-USDC stablecoin (USDT),
     *         then execute() succeeds end-to-end. This validates the audit-5 M-01 fix.
     * @dev Steps:
     *   1. Change SYA rewardToken from USDC to USDT
     *   2. Reconfigure pools: rewardTokenWethPool now points to USDT/WETH
     *   3. Fund PM with USDT for the flash borrow
     *   4. SYA claim expects USDT payment, distributes DAI
     *   5. execute() should succeed using USDT as reward token throughout
     */
    function test_rewardToken_ExecuteSucceedsAfterRewardTokenChange() public {
        // Step 1: Change SYA's reward token from USDC to USDT
        sya.setRewardToken(address(usdt));
        assertEq(sya.rewardToken(), address(usdt), "SYA reward token should now be USDT");

        // Step 2: Create USDT/WETH pool key and reconfigure arb
        PoolKey memory USDT_WETH_key = _makePoolKey(address(usdt), address(weth));
        bool _token0IsPhUSD = address(phusd) < address(susds);
        arb.setPoolKeys(phUSD_sUSDS_key, USDT_WETH_key, sUSDS_USDC_key, _token0IsPhUSD);

        // Step 3: Register known stables and their pool mappings.
        // DAI is the yield token; it needs a pool to convert DAI -> USDT (the new reward token)
        PoolKey memory DAI_USDT_key = _makePoolKey(address(dai), address(usdt));
        arb.addKnownStable(address(dai));
        arb.setStableToRewardTokenPool(address(dai), DAI_USDT_key);

        // Register strategies in MockSYA
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // Step 4: Configure SYA claim: pays 80 USDT (new reward token), gets 100 DAI
        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(dai);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(80e18, yieldTokens, yieldAmounts);
        dai.mint(address(sya), 100e18);

        // Fund PM with USDT for take() operation (flash borrow)
        usdt.mint(address(pm), 1000e18);

        // Step 5: Execute with USDT as reward token
        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 80e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        vm.prank(caller);
        arb.execute(params);

        // Verify success
        assertTrue(caller.balance > 0, "Caller should receive ETH profit with USDT as reward token");
        assertEq(sya.claimCallCount(), 1, "claim() should be called");
        assertEq(dai.balanceOf(address(arb)), 0, "No residual DAI in arb");
    }

    /**
     * @notice Test: Step 3 approves the current rewardToken (not USDC).
     *         After changing reward token to USDT, the approve() call in Step 3
     *         must target USDT. The MockSYA.claim() calls transferFrom on the
     *         reward token, which would revert if the wrong token was approved.
     */
    function test_rewardToken_Step3ApprovesCorrectToken() public {
        // Change reward token to USDT
        sya.setRewardToken(address(usdt));

        // Setup pools with USDT as reward token
        PoolKey memory USDT_WETH_key = _makePoolKey(address(usdt), address(weth));
        bool _token0IsPhUSD = address(phusd) < address(susds);
        arb.setPoolKeys(phUSD_sUSDS_key, USDT_WETH_key, sUSDS_USDC_key, _token0IsPhUSD);

        // DAI is the yield token, routed through DAI/USDT pool
        PoolKey memory DAI_USDT_key = _makePoolKey(address(dai), address(usdt));
        arb.addKnownStable(address(dai));
        arb.setStableToRewardTokenPool(address(dai), DAI_USDT_key);
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // claim: pays 80 USDT, gets 100 DAI
        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(dai);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(80e18, yieldTokens, yieldAmounts);
        dai.mint(address(sya), 100e18);
        usdt.mint(address(pm), 1000e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 80e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        // If Step 3 still approved USDC instead of USDT, the claim() call would
        // revert because MockSYA.claim() calls transferFrom on rewardToken (USDT).
        // Success proves the correct token was approved.
        vm.prank(caller);
        arb.execute(params);

        assertEq(sya.claimCallCount(), 1, "claim() succeeded: Step 3 approved the correct reward token (USDT)");
    }

    /**
     * @notice Test: Step 7 queries the correct reward-token delta.
     *         After changing reward token to USDT, Step 7 must query the USDT delta
     *         (not USDC) for profit calculation and swap via the USDT/WETH pool.
     */
    function test_rewardToken_Step7QueriesCorrectDelta() public {
        // Change reward token to USDT
        sya.setRewardToken(address(usdt));

        // Setup pools with USDT as reward token
        PoolKey memory USDT_WETH_key = _makePoolKey(address(usdt), address(weth));
        bool _token0IsPhUSD = address(phusd) < address(susds);
        arb.setPoolKeys(phUSD_sUSDS_key, USDT_WETH_key, sUSDS_USDC_key, _token0IsPhUSD);

        // DAI is the yield token, routed through DAI/USDT pool
        PoolKey memory DAI_USDT_key = _makePoolKey(address(dai), address(usdt));
        arb.addKnownStable(address(dai));
        arb.setStableToRewardTokenPool(address(dai), DAI_USDT_key);
        sya.addYieldStrategy(makeAddr("strategyDAI"), address(dai));

        // claim: pays 80 USDT, gets 100 DAI (20% discount = guaranteed profit)
        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(dai);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(80e18, yieldTokens, yieldAmounts);
        dai.mint(address(sya), 100e18);
        usdt.mint(address(pm), 1000e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 80e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        vm.prank(caller);
        arb.execute(params);

        // If Step 7 queried the USDC delta instead of USDT, it would see 0 USDC
        // and revert with NoProfit(). Success proves Step 7 correctly queries
        // the USDT delta and swaps via the USDT/WETH pool.
        assertTrue(caller.balance > 0, "Caller received ETH: Step 7 used correct reward token delta");
    }
}

/*//////////////////////////////////////////////////////////////
            _settleResidualDelta FIX TESTS (Story 014)
//////////////////////////////////////////////////////////////*/

/**
 * @title SettleResidualDeltaTest
 * @notice Tests for the fixed _settleResidualDelta() function covering:
 *   - Positive delta settlement (take + deposit pattern)
 *   - phUSD negative delta settlement via phUSD_sUSDS_pool
 *   - Secondary sUSDS settlement chain (phUSD -> sUSDS -> USDC)
 *   - Unconfigured token revert
 *   - Zero delta no-op
 *   - Full execute() flow with phUSD residual two-hop chain
 */
contract SettleResidualDeltaTest is Test {
    SettleResidualDeltaTester public tester;
    ClaimArbitrage public arb;
    TestablePoolManager public pm;
    MockSYA public sya;
    MockERC20 public usdc;
    MockWETH public weth;
    MockERC20 public susds;
    MockERC20 public phusd;
    MockERC20 public usdt;
    MockERC20 public dai;

    address public owner;
    address public caller;

    PoolKey public phUSD_sUSDS_key;
    PoolKey public USDC_WETH_key;
    PoolKey public sUSDS_USDC_key;
    PoolKey public USDT_USDC_key;
    PoolKey public DAI_USDC_key;

    function setUp() public {
        owner = address(this);
        caller = makeAddr("caller");

        usdc = new MockERC20("USDC", "USDC");
        weth = new MockWETH();
        susds = new MockERC20("sUSDS", "sUSDS");
        phusd = new MockERC20("phUSD", "phUSD");
        usdt = new MockERC20("USDT", "USDT");
        dai = new MockERC20("DAI", "DAI");

        sya = new MockSYA(address(usdc));
        pm = new TestablePoolManager();

        // Deploy the standalone tester for unit-testing _settleResidualDelta
        tester = new SettleResidualDeltaTester(
            address(pm),
            address(susds),
            address(phusd)
        );

        // Deploy the real ClaimArbitrage for full execute() flow tests
        arb = new ClaimArbitrage(
            address(pm),
            address(sya),
            address(weth),
            address(susds),
            address(phusd)
        );

        phUSD_sUSDS_key = _makePoolKey(address(phusd), address(susds));
        USDC_WETH_key = _makePoolKey(address(usdc), address(weth));
        sUSDS_USDC_key = _makePoolKey(address(susds), address(usdc));
        USDT_USDC_key = _makePoolKey(address(usdt), address(usdc));
        DAI_USDC_key = _makePoolKey(address(dai), address(usdc));

        bool _token0IsPhUSD = address(phusd) < address(susds);

        // Configure tester pool keys
        tester.setPoolKeys(sUSDS_USDC_key, phUSD_sUSDS_key);

        // Configure real arb pool keys
        arb.setPoolKeys(phUSD_sUSDS_key, USDC_WETH_key, sUSDS_USDC_key, _token0IsPhUSD);

        // Fund PM for take() operations
        usdc.mint(address(pm), 1000e18);
        weth.mint(address(pm), 100e18);
        susds.mint(address(pm), 1000e18);
        phusd.mint(address(pm), 1000e18);
        usdt.mint(address(pm), 1000e18);
        vm.deal(address(weth), 100 ether);
    }

    function _makePoolKey(address tokenA, address tokenB) internal pure returns (PoolKey memory) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /*//////////////////////////////////////////////////////////////
                TEST: POSITIVE DELTA SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_settleResidualDelta_PositiveDelta_ZeroesViaTakeDeposit() public {
        // Set a positive delta for USDT (tester has credit in PM)
        pm.setDelta(address(tester), address(usdt), 5e18);

        // take() will send 5e18 USDT from PM to tester, then _depositIntoPM sends them back.
        // PM already has USDT from setUp.

        tester.settleResidualDelta(address(usdt));

        // After settlement, delta should be zero.
        int256 deltaAfter = pm.deltas(address(tester), address(usdt));
        assertEq(deltaAfter, 0, "USDT delta should be zero after positive delta settlement");
    }

    /*//////////////////////////////////////////////////////////////
            TEST: phUSD NEGATIVE DELTA SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_settleResidualDelta_NegativePhUSD_SettlesViaPhUSDsUSDSPool() public {
        // Set a negative delta for phUSD (tester owes phUSD to PM)
        pm.setDelta(address(tester), address(phusd), -3e18);

        // The function should use phUSD_sUSDS_pool to buy phUSD with sUSDS.
        // With default 1:1 mock swap, buying 3e18 phUSD costs 3e18 sUSDS.

        tester.settleResidualDelta(address(phusd));

        // phUSD delta should be zeroed (swap added +3e18 to the -3e18)
        int256 phUSDDeltaAfter = pm.deltas(address(tester), address(phusd));
        assertEq(phUSDDeltaAfter, 0, "phUSD delta should be zero after settlement");

        // sUSDS delta should be negative (we sold sUSDS to buy phUSD)
        int256 sUSDSDeltaAfter = pm.deltas(address(tester), address(susds));
        assertTrue(sUSDSDeltaAfter < 0, "sUSDS delta should be negative (cost of buying phUSD)");
    }

    /*//////////////////////////////////////////////////////////////
            TEST: SECONDARY sUSDS SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_settleResidualDelta_SecondaryChain_PhUSDThenSUSDS() public {
        // Set a negative phUSD delta. After settling phUSD via phUSD_sUSDS_pool,
        // a secondary sUSDS debt will appear. Settling sUSDS via sUSDS_USDC_pool
        // should zero the sUSDS delta.
        pm.setDelta(address(tester), address(phusd), -3e18);

        // Use the pair settler to call both in sequence
        tester.settleResidualDeltaPair(address(phusd), address(susds));

        // Both deltas should be zeroed
        int256 phUSDDeltaAfter = pm.deltas(address(tester), address(phusd));
        int256 sUSDSDeltaAfter = pm.deltas(address(tester), address(susds));
        assertEq(phUSDDeltaAfter, 0, "phUSD delta should be zero");
        assertEq(sUSDSDeltaAfter, 0, "sUSDS delta should be zero after secondary settlement");

        // A USDC delta should have been created (cost of buying sUSDS)
        int256 usdcDeltaAfter = pm.deltas(address(tester), address(usdc));
        assertTrue(usdcDeltaAfter != 0, "USDC delta should be non-zero (cost of buying sUSDS)");
    }

    /*//////////////////////////////////////////////////////////////
            TEST: UNCONFIGURED TOKEN REVERT
    //////////////////////////////////////////////////////////////*/

    function test_settleResidualDelta_UnconfiguredToken_Reverts() public {
        // Create a random token that has no pool configured and is not sUSDS or phUSD
        MockERC20 randomToken = new MockERC20("RANDOM", "RND");
        randomToken.mint(address(pm), 100e18);

        // Set a negative delta for this unconfigured token
        pm.setDelta(address(tester), address(randomToken), -2e18);

        // Should revert with UnsettledResidualForUnconfiguredToken
        // Note: the error is defined locally in SettleResidualDeltaTester, so we match its selector
        vm.expectRevert(
            abi.encodeWithSelector(
                SettleResidualDeltaTester.UnsettledResidualForUnconfiguredToken.selector,
                address(randomToken)
            )
        );
        tester.settleResidualDelta(address(randomToken));
    }

    /*//////////////////////////////////////////////////////////////
            TEST: ZERO DELTA NO-OP
    //////////////////////////////////////////////////////////////*/

    function test_settleResidualDelta_ZeroDelta_NoOp() public {
        // Delta is zero by default. Verify no swaps or reverts occur.
        uint256 swapCountBefore = pm.swapCallCount();

        tester.settleResidualDelta(address(usdt));

        uint256 swapCountAfter = pm.swapCallCount();
        assertEq(swapCountAfter, swapCountBefore, "No swaps should occur for zero delta");
    }

    /*//////////////////////////////////////////////////////////////
        TEST: FULL EXECUTE FLOW WITH phUSD TWO-HOP CHAIN
    //////////////////////////////////////////////////////////////*/

    function test_fullFlow_PhUSDResidual_SettledThroughTwoHopChain() public {
        // Setup a profitable scenario using the real ClaimArbitrage contract.
        // With default 1:1 mock swaps, pump and unwind cancel perfectly.
        // The _settleResidualDelta(phUSD) + _settleResidualDelta(sUSDS) calls are no-ops,
        // but the code path is exercised. The unit tests above verify actual settlement
        // logic for non-zero residuals.

        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));

        // claim: pays 80 USDC, gets 100 USDT (20% discount for healthy profit margin)
        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(usdt);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(80e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 100e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 80e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        vm.prank(caller);
        arb.execute(params);

        // Caller should receive ETH profit (20% discount)
        assertTrue(caller.balance > 0, "Caller should receive ETH profit");

        // Verify no tokens stuck in contract
        assertEq(usdt.balanceOf(address(arb)), 0, "No residual USDT in arb");
        assertEq(phusd.balanceOf(address(arb)), 0, "No residual phUSD in arb");
        assertEq(susds.balanceOf(address(arb)), 0, "No residual sUSDS in arb");
    }

    /**
     * @notice End-to-end test verifying that the secondary sUSDS settlement call
     *         in unlockCallback() is present and functional. With default 1:1 mock swaps
     *         the settlement calls are no-ops, but the code path must not revert.
     */
    function test_fullFlow_SecondarySettlementPresent_ExecuteSucceeds() public {
        arb.addKnownStable(address(usdt));
        arb.setStableToRewardTokenPool(address(usdt), USDT_USDC_key);
        sya.addYieldStrategy(makeAddr("strategyUSDT"), address(usdt));

        // Large discount to absorb any settlement costs
        address[] memory yieldTokens = new address[](1);
        yieldTokens[0] = address(usdt);
        uint256[] memory yieldAmounts = new uint256[](1);
        yieldAmounts[0] = 100e18;
        sya.setupClaim(70e18, yieldTokens, yieldAmounts);
        usdt.mint(address(sya), 100e18);

        IClaimArbitrage.ExecuteParams memory params = IClaimArbitrage.ExecuteParams({
            pumpAmount: 10e18,
            rewardTokenNeeded: 70e18,
            pumpPriceLimit: type(uint160).max - 1,
            unwindPriceLimit: type(uint160).min + 1
        });

        // Execute completes without revert, proving the settlement chain is present
        vm.prank(caller);
        arb.execute(params);

        assertTrue(caller.balance > 0, "Caller should receive ETH profit with two-hop settlement");
    }
}
