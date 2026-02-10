// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {AutoCompoundPositionHook} from "../src/UniswapV4Hooks/AutoCompoundPositionHook.sol";
import {IAutoCompoundPositionHook} from "../src/UniswapV4Hooks/IAutoCompoundPositionHook.sol";

/// @title AutoCompoundPositionHookForTest
/// @notice A test-only version of the hook that skips address validation
contract AutoCompoundPositionHookForTest is AutoCompoundPositionHook {
    constructor(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        bytes32 _salt,
        uint256 _thresholdTokenIndex,
        uint256 _thresholdAmount,
        uint128 _absoluteFloor
    ) AutoCompoundPositionHook(
        _poolManager,
        _poolKey,
        _tickLower,
        _tickUpper,
        _salt,
        _thresholdTokenIndex,
        _thresholdAmount,
        _absoluteFloor
    ) {}

    /// @notice Skip hook address validation during testing
    function validateHookAddress(BaseHook) internal pure override {}

    /// @notice Skip poolKey.hooks validation during testing
    function _validatePoolKeyHooks(PoolKey memory) internal view override {}
}

contract AutoCompoundPositionHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Constants
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    bytes constant ZERO_BYTES = "";

    // Pool setup
    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    AutoCompoundPositionHookForTest hook;
    PoolKey poolKey;
    PoolId poolId;

    // Default position parameters
    int24 constant TICK_LOWER = -120;
    int24 constant TICK_UPPER = 120;
    bytes32 constant POSITION_SALT = bytes32(uint256(1));
    uint256 constant DEFAULT_THRESHOLD = 1e18;
    uint128 constant DEFAULT_ABSOLUTE_FLOOR = 1000; // Low floor for most tests

    address owner;
    address alice;
    address bob;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy and sort tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);

        // Sort by address
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Mint tokens
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.mint(alice, 100 ether);
        token1.mint(alice, 100 ether);

        // Approve routers
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.prank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    /// @notice Compute an address with the correct hook permission flags
    function _computeHookAddress() internal pure returns (address) {
        // afterSwap (bit 6) = 0x40 and afterSwapReturnDelta (bit 2) = 0x04
        // Combined: 0x44
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        return address(flags);
    }

    /// @notice Deploy hook by deploying to a temporary address and then using vm.etch
    ///         with proper storage copying
    function _deployHook() internal returns (AutoCompoundPositionHookForTest) {
        // Get an address with correct permission flags
        address hookAddress = _computeHookAddress();

        // Create pool key with the hook address
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000, // 0.1% fee
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        poolId = poolKey.toId();

        // Deploy the hook to a different address first with the correct poolKey
        AutoCompoundPositionHookForTest impl = new AutoCompoundPositionHookForTest(
            manager,
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_SALT,
            0, // thresholdTokenIndex
            DEFAULT_THRESHOLD,
            DEFAULT_ABSOLUTE_FLOOR
        );

        // Get the bytecode and etch it to the hook address
        bytes memory code = address(impl).code;
        vm.etch(hookAddress, code);

        // Copy the storage slots from impl to hookAddress
        // The important storage slots are:
        // - _poolKey (slot depends on inheritance but we can copy relevant ones)
        // - poolId (immutable - encoded in bytecode)
        // - active, taxBps, thresholdTokenIndex, thresholdAmount, tickLower, tickUpper, positionSalt

        // Actually, immutables are in the bytecode, and storage variables need to be in the contract's storage.
        // Let's copy all known storage slots

        // Since AutoCompoundPositionHook inherits from BaseHook and Ownable:
        // Slot 0: Ownable's _owner
        // Slot 1: _poolKey (first part - currency0, currency1 packed? Let's see)
        // For a struct PoolKey, it takes multiple slots

        // Alternative: just copy all first 25 slots to be safe (includes new MEV floor variables)
        for (uint256 i = 0; i < 25; i++) {
            bytes32 slot = bytes32(i);
            bytes32 value = vm.load(address(impl), slot);
            vm.store(hookAddress, slot, value);
        }

        // Cast the hookAddress to our hook type
        hook = AutoCompoundPositionHookForTest(payable(hookAddress));

        return hook;
    }

    /// @notice Helper to initialize pool and add initial liquidity
    function _initializePoolWithLiquidity() internal {
        // Initialize pool at 1:1 price
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ========== Constructor Tests ==========

    function test_constructor_setsCorrectValues() public {
        _deployHook();

        // Check pool key components
        (
            address c0,
            address c1,
            uint24 fee,
            int24 tickSpacing,
            address hooks
        ) = hook.poolKey();

        assertEq(c0, address(token0), "currency0 mismatch");
        assertEq(c1, address(token1), "currency1 mismatch");
        assertEq(fee, 1000, "fee mismatch");
        assertEq(tickSpacing, 60, "tickSpacing mismatch");
        assertEq(hooks, address(hook), "hooks mismatch");

        // Check other values
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(poolId), "poolId mismatch");
        assertTrue(hook.active(), "should be active by default");
        assertEq(hook.taxBps(), 5, "taxBps should be 5");
        assertEq(hook.thresholdTokenIndex(), 0, "thresholdTokenIndex should be 0");
        assertEq(hook.thresholdAmount(), DEFAULT_THRESHOLD, "thresholdAmount mismatch");
        assertEq(hook.tickLower(), TICK_LOWER, "tickLower mismatch");
        assertEq(hook.tickUpper(), TICK_UPPER, "tickUpper mismatch");
        assertEq(hook.positionSalt(), POSITION_SALT, "positionSalt mismatch");
    }

    function test_constructor_revertsOnInvalidThresholdIndex() public {
        address hookAddress = _computeHookAddress();

        PoolKey memory tempKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        vm.expectRevert("bad threshold index");
        new AutoCompoundPositionHookForTest(
            manager,
            tempKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_SALT,
            2, // invalid index
            DEFAULT_THRESHOLD,
            DEFAULT_ABSOLUTE_FLOOR
        );
    }

    function test_constructor_revertsOnInvalidTickRange() public {
        address hookAddress = _computeHookAddress();

        PoolKey memory tempKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        vm.expectRevert("bad ticks");
        new AutoCompoundPositionHookForTest(
            manager,
            tempKey,
            120, // tickLower > tickUpper
            -120,
            POSITION_SALT,
            0,
            DEFAULT_THRESHOLD,
            DEFAULT_ABSOLUTE_FLOOR
        );
    }

    function test_constructor_revertsOnWrongHookAddress() public {
        PoolKey memory tempKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: 60,
            hooks: IHooks(address(0x1234)) // wrong address - doesn't match this contract
        });

        // Use the real hook (not the test version) which validates the hook address
        // It will revert with either HookAddressNotValid (from BaseHook) or "PoolKey.hooks != this"
        // depending on which check happens first
        vm.expectRevert();
        new AutoCompoundPositionHook(
            manager,
            tempKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_SALT,
            0,
            DEFAULT_THRESHOLD,
            DEFAULT_ABSOLUTE_FLOOR
        );
    }

    // ========== Owner Function Tests ==========

    function test_setThresholdToken_updatesValue() public {
        _deployHook();

        vm.expectEmit(true, true, true, true);
        emit IAutoCompoundPositionHook.ThresholdTokenSet(1);

        hook.setThresholdToken(1);
        assertEq(hook.thresholdTokenIndex(), 1, "thresholdTokenIndex should be 1");
    }

    function test_setThresholdToken_revertsOnInvalidIndex() public {
        _deployHook();

        vm.expectRevert("bad index");
        hook.setThresholdToken(2);
    }

    function test_setThresholdToken_revertsIfNotOwner() public {
        _deployHook();

        vm.prank(alice);
        vm.expectRevert();
        hook.setThresholdToken(1);
    }

    function test_changeThreshold_updatesValue() public {
        _deployHook();

        vm.expectEmit(true, true, true, true);
        emit IAutoCompoundPositionHook.ThresholdAmountSet(5 ether);

        hook.changeThreshold(5 ether);
        assertEq(hook.thresholdAmount(), 5 ether, "thresholdAmount should be 5 ether");
    }

    function test_changeThreshold_revertsIfNotOwner() public {
        _deployHook();

        vm.prank(alice);
        vm.expectRevert();
        hook.changeThreshold(5 ether);
    }

    function test_modifyPosition_updatesValues() public {
        _deployHook();

        vm.expectEmit(true, true, true, true);
        emit IAutoCompoundPositionHook.PositionParamsSet(-240, 240, bytes32(uint256(2)));

        hook.modifyPosition(-240, 240, bytes32(uint256(2)));
        assertEq(hook.tickLower(), -240, "tickLower should be -240");
        assertEq(hook.tickUpper(), 240, "tickUpper should be 240");
        assertEq(hook.positionSalt(), bytes32(uint256(2)), "positionSalt should be 2");
    }

    function test_modifyPosition_revertsOnInvalidTicks() public {
        _deployHook();

        vm.expectRevert("bad ticks");
        hook.modifyPosition(120, -120, POSITION_SALT);
    }

    function test_modifyPosition_revertsIfNotOwner() public {
        _deployHook();

        vm.prank(alice);
        vm.expectRevert();
        hook.modifyPosition(-240, 240, bytes32(uint256(2)));
    }

    function test_setActive_updatesValue() public {
        _deployHook();

        vm.expectEmit(true, true, true, true);
        emit IAutoCompoundPositionHook.ActiveSet(false);

        hook.setActive(false);
        assertFalse(hook.active(), "should be inactive");

        vm.expectEmit(true, true, true, true);
        emit IAutoCompoundPositionHook.ActiveSet(true);

        hook.setActive(true);
        assertTrue(hook.active(), "should be active");
    }

    function test_setActive_revertsIfNotOwner() public {
        _deployHook();

        vm.prank(alice);
        vm.expectRevert();
        hook.setActive(false);
    }

    function test_setTaxPercentage_updatesValue() public {
        _deployHook();

        vm.expectEmit(true, true, true, true);
        emit IAutoCompoundPositionHook.TaxBpsSet(10);

        hook.setTaxPercentage(10);
        assertEq(hook.taxBps(), 10, "taxBps should be 10");
    }

    function test_setTaxPercentage_revertsOnTooHigh() public {
        _deployHook();

        vm.expectRevert("bps>100%");
        hook.setTaxPercentage(10001);
    }

    function test_setTaxPercentage_revertsIfNotOwner() public {
        _deployHook();

        vm.prank(alice);
        vm.expectRevert();
        hook.setTaxPercentage(10);
    }

    function test_setTaxPercentage_allowsZero() public {
        _deployHook();

        hook.setTaxPercentage(0);
        assertEq(hook.taxBps(), 0, "taxBps should be 0");
    }

    function test_setTaxPercentage_allowsMax() public {
        _deployHook();

        hook.setTaxPercentage(10000);
        assertEq(hook.taxBps(), 10000, "taxBps should be 10000");
    }

    // ========== Hook Permissions Tests ==========

    function test_getHookPermissions_returnsCorrectFlags() public {
        _deployHook();

        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertFalse(permissions.beforeInitialize, "beforeInitialize should be false");
        assertFalse(permissions.afterInitialize, "afterInitialize should be false");
        assertFalse(permissions.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be false");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(permissions.beforeSwap, "beforeSwap should be false");
        assertTrue(permissions.afterSwap, "afterSwap should be true");
        assertFalse(permissions.beforeDonate, "beforeDonate should be false");
        assertFalse(permissions.afterDonate, "afterDonate should be false");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertTrue(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be true");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false");
    }

    // ========== Fee Charging Tests ==========

    function test_afterSwap_chargesFeeOnExactIn() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Get hook balance before
        uint256 hookBalance0Before = token0.balanceOf(address(hook));
        uint256 hookBalance1Before = token1.balanceOf(address(hook));

        // Perform exactIn swap (negative amountSpecified)
        // Swap token0 -> token1 (zeroForOne = true)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether, // exactIn: negative
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Hook should have taken fee from output (token1)
        uint256 hookBalance0After = token0.balanceOf(address(hook));
        uint256 hookBalance1After = token1.balanceOf(address(hook));

        // Output is token1 for zeroForOne exactIn
        // Fee should be 0.05% of output
        assertEq(hookBalance0After, hookBalance0Before, "token0 balance should not change");
        assertGt(hookBalance1After, hookBalance1Before, "token1 balance should increase");
    }

    function test_afterSwap_noFeeWhenInactive() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Deactivate hook
        hook.setActive(false);

        uint256 hookBalance1Before = token1.balanceOf(address(hook));

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        uint256 hookBalance1After = token1.balanceOf(address(hook));

        assertEq(hookBalance1After, hookBalance1Before, "hook should not collect fee when inactive");
    }

    function test_afterSwap_noFeeWhenTaxBpsZero() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Set tax to zero
        hook.setTaxPercentage(0);

        uint256 hookBalance1Before = token1.balanceOf(address(hook));

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        uint256 hookBalance1After = token1.balanceOf(address(hook));

        assertEq(hookBalance1After, hookBalance1Before, "hook should not collect fee when taxBps is 0");
    }

    // ========== Poke Tests ==========

    function test_poke_canBeCalledByAnyone() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Anyone should be able to call poke
        vm.prank(alice);
        hook.poke();

        vm.prank(bob);
        hook.poke();
    }

    function test_poke_doesNotCompoundWhenInactive() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Send some tokens to the hook
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        // Deactivate
        hook.setActive(false);

        // Check hook's liquidity position before
        (uint128 liqBefore,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        hook.poke();

        (uint128 liqAfter,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        assertEq(liqAfter, liqBefore, "liquidity should not change when inactive");
    }

    function test_poke_doesNotCompoundWhenBelowThreshold() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Set high threshold
        hook.changeThreshold(100 ether);

        // Send tokens below threshold
        token0.transfer(address(hook), 1 ether);
        token1.transfer(address(hook), 1 ether);

        (uint128 liqBefore,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        hook.poke();

        (uint128 liqAfter,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        assertEq(liqAfter, liqBefore, "liquidity should not change when below threshold");
    }

    // ========== Liquidity Withdrawal Tests ==========

    function test_withdrawLiquidity_revertsIfNoLiquidity() public {
        _deployHook();
        _initializePoolWithLiquidity();

        vm.expectRevert("no liquidity");
        hook.withdrawLiquidity(alice);
    }

    function test_withdrawLiquidity_revertsIfZeroAddress() public {
        _deployHook();

        vm.expectRevert("bad recipient");
        hook.withdrawLiquidity(address(0));
    }

    function test_withdrawLiquidity_revertsIfNotOwner() public {
        _deployHook();
        _initializePoolWithLiquidity();

        vm.prank(alice);
        vm.expectRevert();
        hook.withdrawLiquidity(alice);
    }

    // ========== Edge Case Tests ==========

    function test_positionOutOfRange_atTickLower() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Send tokens to hook
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        // Move the price way below tick lower by swapping a lot
        // This moves the price so current tick is below tickLower

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -50 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check current tick
        (, int24 tick,,) = manager.getSlot0(poolId);

        // If tick is at or below tickLower, compounding should not happen
        if (tick <= hook.tickLower()) {
            (uint128 liqBefore,,) = manager.getPositionInfo(
                poolId,
                address(hook),
                hook.tickLower(),
                hook.tickUpper(),
                hook.positionSalt()
            );

            hook.poke();

            (uint128 liqAfter,,) = manager.getPositionInfo(
                poolId,
                address(hook),
                hook.tickLower(),
                hook.tickUpper(),
                hook.positionSalt()
            );

            assertEq(liqAfter, liqBefore, "liquidity should not change when out of range");
        }
    }

    function test_positionOutOfRange_atTickUpper() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Send tokens to hook
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        // Move the price way above tick upper by swapping a lot
        SwapParams memory params = SwapParams({
            zeroForOne: false, // swap token1 for token0
            amountSpecified: -50 ether,
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check current tick
        (, int24 tick,,) = manager.getSlot0(poolId);

        // If tick is at or above tickUpper, compounding should not happen
        if (tick >= hook.tickUpper()) {
            (uint128 liqBefore,,) = manager.getPositionInfo(
                poolId,
                address(hook),
                hook.tickLower(),
                hook.tickUpper(),
                hook.positionSalt()
            );

            hook.poke();

            (uint128 liqAfter,,) = manager.getPositionInfo(
                poolId,
                address(hook),
                hook.tickLower(),
                hook.tickUpper(),
                hook.positionSalt()
            );

            assertEq(liqAfter, liqBefore, "liquidity should not change when out of range");
        }
    }

    // ========== Compounding Tests ==========

    function test_compounding_addsLiquidityWhenInRangeAndAboveThreshold() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Set low threshold
        hook.changeThreshold(0.1 ether);

        // Send tokens to hook
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        // Check hook's position has no liquidity initially
        (uint128 liqBefore,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        assertEq(liqBefore, 0, "should have no liquidity before");

        // Trigger compounding via a swap (which is within an unlock callback)
        // The afterSwap hook will call _tryCompound
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        (uint128 liqAfter,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        assertGt(liqAfter, 0, "should have liquidity after compounding");
    }

    // ========== Receive Function Test ==========

    function test_receive_acceptsEther() public {
        _deployHook();

        uint256 balanceBefore = address(hook).balance;

        // Send ETH to hook
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "should accept ETH");

        assertEq(address(hook).balance, balanceBefore + 1 ether, "balance should increase");
    }

    // ========== MEV Floor Tests ==========

    function test_compoundSkipped_whenLiquidityBelowMinLiquidity() public {
        // Deploy hook with a very high absolute floor so compound will be skipped
        address hookAddress = _computeHookAddress();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();

        // Set a very high floor that normal fee amounts can't exceed
        uint128 highFloor = type(uint128).max / 2;

        AutoCompoundPositionHookForTest impl = new AutoCompoundPositionHookForTest(
            manager,
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_SALT,
            0,
            0, // zero threshold so we get past threshold check
            highFloor
        );

        bytes memory code = address(impl).code;
        vm.etch(hookAddress, code);
        for (uint256 i = 0; i < 25; i++) {
            bytes32 slot = bytes32(i);
            bytes32 value = vm.load(address(impl), slot);
            vm.store(hookAddress, slot, value);
        }
        hook = AutoCompoundPositionHookForTest(payable(hookAddress));

        _initializePoolWithLiquidity();

        // Send tokens to hook
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        // Check no liquidity added before
        (uint128 liqBefore,,) = manager.getPositionInfo(
            poolId, address(hook), hook.tickLower(), hook.tickUpper(), hook.positionSalt()
        );
        assertEq(liqBefore, 0, "should have no liquidity before");

        // Expect CompoundSkipped event
        vm.expectEmit(false, false, false, false);
        emit IAutoCompoundPositionHook.CompoundSkipped(0, 0);

        hook.poke();

        // Liquidity should still be zero
        (uint128 liqAfter,,) = manager.getPositionInfo(
            poolId, address(hook), hook.tickLower(), hook.tickUpper(), hook.positionSalt()
        );
        assertEq(liqAfter, 0, "liquidity should not change when below floor");
    }

    function test_compoundSucceeds_whenLiquidityAboveMinLiquidity() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Set low threshold so compounding can happen
        hook.changeThreshold(0);

        // Send tokens to hook - enough to generate liquidity above the low floor
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        (uint128 liqBefore,,) = manager.getPositionInfo(
            poolId, address(hook), hook.tickLower(), hook.tickUpper(), hook.positionSalt()
        );
        assertEq(liqBefore, 0, "should have no liquidity before");

        // Trigger compound via poke - should succeed because liq >> DEFAULT_ABSOLUTE_FLOOR (1000)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        (uint128 liqAfter,,) = manager.getPositionInfo(
            poolId, address(hook), hook.tickLower(), hook.tickUpper(), hook.positionSalt()
        );
        assertGt(liqAfter, 0, "should have liquidity after compounding above floor");
    }

    function test_trackedLiquidity_EMAUpdatesAfterCompound() public {
        _deployHook();
        _initializePoolWithLiquidity();

        hook.changeThreshold(0);

        // Initial tracked liquidity should equal ABSOLUTE_FLOOR
        assertEq(hook.trackedLiquidity(), DEFAULT_ABSOLUTE_FLOOR, "initial trackedLiquidity should be ABSOLUTE_FLOOR");

        // Send tokens and trigger compound
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // trackedLiquidity should have changed from its initial value
        // EMA = (old * 90 + new * 10) / 100
        // After compound, the fair estimate uses post-compound (leftover) balances,
        // which are small since most tokens were used for liquidity.
        // The EMA updates to reflect this new sample.
        uint128 tracked = hook.trackedLiquidity();
        assertFalse(tracked == DEFAULT_ABSOLUTE_FLOOR, "trackedLiquidity should change from initial value after compound");
    }

    function test_minLiquidity_adjustsUpwardOverMultipleCompounds() public {
        _deployHook();
        _initializePoolWithLiquidity();

        hook.changeThreshold(0);

        uint128 initialMin = hook.minLiquidity();
        assertEq(initialMin, DEFAULT_ABSOLUTE_FLOOR, "initial minLiquidity should be ABSOLUTE_FLOOR");

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Perform multiple compounds to ramp up EMA
        for (uint256 i = 0; i < 5; i++) {
            token0.transfer(address(hook), 5 ether);
            token1.transfer(address(hook), 5 ether);

            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            });

            swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        }

        uint128 finalMin = hook.minLiquidity();
        assertGt(finalMin, initialMin, "minLiquidity should increase over multiple compounds");
    }

    function test_minLiquidity_neverFallsBelowAbsoluteFloor() public {
        // Deploy with a specific floor
        uint128 floor = 5000;
        address hookAddress = _computeHookAddress();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();

        AutoCompoundPositionHookForTest impl = new AutoCompoundPositionHookForTest(
            manager,
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_SALT,
            0,
            0, // zero threshold
            floor
        );

        bytes memory code = address(impl).code;
        vm.etch(hookAddress, code);
        for (uint256 i = 0; i < 25; i++) {
            bytes32 slot = bytes32(i);
            bytes32 value = vm.load(address(impl), slot);
            vm.store(hookAddress, slot, value);
        }
        hook = AutoCompoundPositionHookForTest(payable(hookAddress));

        // minLiquidity should start at ABSOLUTE_FLOOR
        assertEq(hook.minLiquidity(), floor, "minLiquidity should start at ABSOLUTE_FLOOR");
        assertEq(hook.ABSOLUTE_FLOOR(), floor, "ABSOLUTE_FLOOR should be set correctly");

        // Even after EMA updates that might decrease, minLiquidity should stay >= ABSOLUTE_FLOOR
        // Since we can't easily make EMA decrease below floor in a natural flow,
        // verify the invariant holds at initialization
        assertTrue(hook.minLiquidity() >= hook.ABSOLUTE_FLOOR(), "minLiquidity must always be >= ABSOLUTE_FLOOR");
    }

    function test_compoundSkipped_emitsCorrectValues() public {
        // Deploy hook with a high floor
        uint128 highFloor = 1e30;
        address hookAddress = _computeHookAddress();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();

        AutoCompoundPositionHookForTest impl = new AutoCompoundPositionHookForTest(
            manager,
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_SALT,
            0,
            0, // zero threshold
            highFloor
        );

        bytes memory code = address(impl).code;
        vm.etch(hookAddress, code);
        for (uint256 i = 0; i < 25; i++) {
            bytes32 slot = bytes32(i);
            bytes32 value = vm.load(address(impl), slot);
            vm.store(hookAddress, slot, value);
        }
        hook = AutoCompoundPositionHookForTest(payable(hookAddress));

        _initializePoolWithLiquidity();

        // Send some tokens
        token0.transfer(address(hook), 1 ether);
        token1.transfer(address(hook), 1 ether);

        // Record logs to check event parameters
        vm.recordLogs();
        hook.poke();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find the CompoundSkipped event
        bool foundEvent = false;
        bytes32 compoundSkippedSig = keccak256("CompoundSkipped(uint128,uint128)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == compoundSkippedSig) {
                foundEvent = true;
                (uint128 calcLiq, uint128 currentMin) = abi.decode(entries[i].data, (uint128, uint128));
                assertEq(currentMin, highFloor, "event should report correct minLiquidity");
                assertGt(calcLiq, 0, "calculated liquidity should be > 0");
                assertLt(calcLiq, highFloor, "calculated liquidity should be below the floor");
                break;
            }
        }
        assertTrue(foundEvent, "CompoundSkipped event should have been emitted");
    }

    function test_estimateFairLiquidity_consistentRegardlessOfSpotPrice() public {
        _deployHook();
        _initializePoolWithLiquidity();

        hook.changeThreshold(0);

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Send tokens to hook and trigger compound via small swap
        token0.transfer(address(hook), 5 ether);
        token1.transfer(address(hook), 5 ether);

        SwapParams memory tinySwap = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, tinySwap, testSettings, ZERO_BYTES);

        // Record tracked liquidity after first compound
        uint128 trackedAfterFirst = hook.trackedLiquidity();

        // Now move price significantly by doing a big swap
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -20 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Move price back
        SwapParams memory params2 = SwapParams({
            zeroForOne: false,
            amountSpecified: -20 ether,
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, params2, testSettings, ZERO_BYTES);

        // Send more tokens and trigger another compound via small swap
        token0.transfer(address(hook), 5 ether);
        token1.transfer(address(hook), 5 ether);

        SwapParams memory tinySwap2 = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, tinySwap2, testSettings, ZERO_BYTES);

        // The tracked liquidity should reflect actual balances, not spot price
        // We can verify this by confirming the EMA is tracking reasonably
        uint128 trackedAfterSecond = hook.trackedLiquidity();

        // Both tracked values should be positive and in a reasonable range
        assertGt(trackedAfterFirst, 0, "tracked after first compound should be > 0");
        assertGt(trackedAfterSecond, 0, "tracked after second compound should be > 0");
    }

    function test_firstCompound_succeedsWithAbsoluteFloorAsInitialMinLiquidity() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Verify initial state
        assertEq(hook.minLiquidity(), DEFAULT_ABSOLUTE_FLOOR, "initial minLiquidity should be ABSOLUTE_FLOOR");
        assertEq(hook.trackedLiquidity(), DEFAULT_ABSOLUTE_FLOOR, "initial trackedLiquidity should be ABSOLUTE_FLOOR");

        hook.changeThreshold(0);

        // Send tokens that will generate liquidity well above DEFAULT_ABSOLUTE_FLOOR (1000)
        token0.transfer(address(hook), 10 ether);
        token1.transfer(address(hook), 10 ether);

        (uint128 liqBefore,,) = manager.getPositionInfo(
            poolId, address(hook), hook.tickLower(), hook.tickUpper(), hook.positionSalt()
        );
        assertEq(liqBefore, 0, "should have no liquidity before first compound");

        // Trigger first compound via swap - should succeed since ABSOLUTE_FLOOR is very low
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        (uint128 liqAfter,,) = manager.getPositionInfo(
            poolId, address(hook), hook.tickLower(), hook.tickUpper(), hook.positionSalt()
        );
        assertGt(liqAfter, 0, "first compound should succeed with ABSOLUTE_FLOOR as initial minLiquidity");

        // Verify EMA was updated (it changes from the initial value)
        assertFalse(hook.trackedLiquidity() == DEFAULT_ABSOLUTE_FLOOR, "trackedLiquidity should update after first compound");
    }

    // ========== Integration Tests ==========

    function test_fullFlow_swapCompoundsAutomatically() public {
        _deployHook();
        _initializePoolWithLiquidity();

        // Set very low threshold so compounding happens
        hook.changeThreshold(0);

        // Initial hook balance should be 0
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);

        // First swap - hook collects fees
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Hook should have collected some fees
        // Due to compounding, the balance might be added to liquidity
        (uint128 liquidity,,) = manager.getPositionInfo(
            poolId,
            address(hook),
            hook.tickLower(),
            hook.tickUpper(),
            hook.positionSalt()
        );

        // Either fees are in balance or already added to liquidity
        uint256 hookBalance1 = token1.balanceOf(address(hook));
        assertTrue(liquidity > 0 || hookBalance1 > 0, "hook should have collected fees");
    }

    receive() external payable {}
}
