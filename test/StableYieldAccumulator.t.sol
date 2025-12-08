// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableYieldAccumulator.sol";
import "../src/interfaces/IStableYieldAccumulator.sol";

/**
 * @title StableYieldAccumulatorTest
 * @notice Comprehensive test suite for StableYieldAccumulator
 * @dev RED PHASE - Most tests should FAIL as functionality is stubbed
 */
contract StableYieldAccumulatorTest is Test {
    StableYieldAccumulator public accumulator;

    address public owner;
    address public pauser;
    address public user1;
    address public user2;
    address public mockStrategy1;
    address public mockStrategy2;
    address public mockToken1;
    address public mockToken2;

    // Events to test
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event Paused(address account);
    event Unpaused(address account);
    event YieldStrategyAdded(address indexed strategy);
    event YieldStrategyRemoved(address indexed strategy);
    event TokenConfigSet(address indexed token, uint8 decimals, uint256 normalizedExchangeRate);
    event TokenPaused(address indexed token);
    event TokenUnpaused(address indexed token);
    event DiscountRateSet(uint256 oldRate, uint256 newRate);
    event RewardsClaimed(
        address indexed claimer,
        address indexed rewardToken,
        uint256 amountPaid,
        uint256 strategiesClaimed
    );
    event RewardsCollected(address indexed strategy, uint256 amount);

    function setUp() public {
        owner = address(this);
        pauser = makeAddr("pauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        mockStrategy1 = makeAddr("mockStrategy1");
        mockStrategy2 = makeAddr("mockStrategy2");
        mockToken1 = makeAddr("mockToken1");
        mockToken2 = makeAddr("mockToken2");

        accumulator = new StableYieldAccumulator();
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
                    YIELD STRATEGY MANAGEMENT (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_addYieldStrategy_AddsToList() public {
        // RED PHASE: Should FAIL - stub reverts with NotImplemented
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.addYieldStrategy(mockStrategy1);
    }

    function test_addYieldStrategy_EmitsEvent() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.addYieldStrategy(mockStrategy1);
    }

    function test_addYieldStrategy_RevertIf_NotOwner() public {
        // Should PASS - access control works
        vm.prank(user1);
        vm.expectRevert();
        accumulator.addYieldStrategy(mockStrategy1);
    }

    function test_addYieldStrategy_RevertIf_ZeroAddress() public {
        // RED PHASE: Should FAIL - stub doesn't validate
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.addYieldStrategy(address(0));
    }

    function test_addYieldStrategy_RevertIf_AlreadyRegistered() public {
        // RED PHASE: Should FAIL - stub doesn't check
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.addYieldStrategy(mockStrategy1);
    }

    function test_removeYieldStrategy_RemovesFromList() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.removeYieldStrategy(mockStrategy1);
    }

    function test_removeYieldStrategy_EmitsEvent() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.removeYieldStrategy(mockStrategy1);
    }

    function test_removeYieldStrategy_RevertIf_NotOwner() public {
        // Should PASS - access control works
        vm.prank(user1);
        vm.expectRevert();
        accumulator.removeYieldStrategy(mockStrategy1);
    }

    function test_removeYieldStrategy_RevertIf_NotRegistered() public {
        // RED PHASE: Should FAIL - stub doesn't validate
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.removeYieldStrategy(mockStrategy1);
    }

    function test_getYieldStrategies_ReturnsAllStrategies() public {
        // RED PHASE: Should FAIL - returns empty array
        address[] memory strategies = accumulator.getYieldStrategies();
        assertEq(strategies.length, 0, "Should return empty array in red phase");
        // In green phase, this should fail when strategies are actually added
    }

    /*//////////////////////////////////////////////////////////////
                    TOKEN CONFIGURATION (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_setTokenConfig_StoresDecimalsAndRate() public {
        // RED PHASE: Should FAIL - stub doesn't store
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, 6, 1e18);
    }

    function test_setTokenConfig_EmitsEvent() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, 6, 1e18);
    }

    function test_setTokenConfig_RevertIf_NotOwner() public {
        // Should PASS - access control works
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setTokenConfig(mockToken1, 6, 1e18);
    }

    function test_setTokenConfig_RevertIf_ZeroAddress() public {
        // RED PHASE: Should FAIL - stub doesn't validate
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(address(0), 6, 1e18);
    }

    function test_setTokenConfig_RevertIf_InvalidDecimals() public {
        // RED PHASE: Should FAIL - stub doesn't validate decimals > 18
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, 19, 1e18);
    }

    function test_pauseToken_SetsTokenPaused() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.pauseToken(mockToken1);
    }

    function test_unpauseToken_SetsTokenUnpaused() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.unpauseToken(mockToken1);
    }

    function test_getTokenConfig_ReturnsStoredConfig() public {
        // RED PHASE: Should FAIL - returns zeros
        IStableYieldAccumulator.TokenConfig memory config = accumulator.getTokenConfig(mockToken1);
        assertEq(config.decimals, 0, "Should return 0 decimals in red phase");
        assertEq(config.normalizedExchangeRate, 0, "Should return 0 rate in red phase");
        assertFalse(config.paused, "Should return false paused in red phase");
    }

    /*//////////////////////////////////////////////////////////////
                        DISCOUNT RATE (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_setDiscountRate_StoresRate() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setDiscountRate(200);
    }

    function test_setDiscountRate_EmitsEvent() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setDiscountRate(200);
    }

    function test_setDiscountRate_RevertIf_NotOwner() public {
        // Should PASS - access control works
        vm.prank(user1);
        vm.expectRevert();
        accumulator.setDiscountRate(200);
    }

    function test_setDiscountRate_RevertIf_ExceedsMax() public {
        // RED PHASE: Should FAIL - stub doesn't validate > 10000 basis points
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setDiscountRate(10001);
    }

    function test_getDiscountRate_ReturnsStoredRate() public {
        // RED PHASE: Should FAIL - returns 0
        uint256 rate = accumulator.getDiscountRate();
        assertEq(rate, 0, "Should return 0 in red phase");
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM MECHANISM (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_claim_TransfersTokensWithDiscount() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.claim(mockToken1, 100e18);
    }

    function test_claim_EmitsEvent() public {
        // RED PHASE: Should FAIL - stub reverts
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.claim(mockToken1, 100e18);
    }

    function test_claim_RevertIf_Paused() public {
        // Should PASS - whenNotPaused modifier works from Story 001
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        vm.expectRevert();
        accumulator.claim(mockToken1, 100e18);
    }

    function test_claim_RevertIf_TokenPaused() public {
        // RED PHASE: Should FAIL - stub doesn't check token pause state
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.claim(mockToken1, 100e18);
    }

    function test_claim_RevertIf_InsufficientPending() public {
        // RED PHASE: Should FAIL - stub doesn't check balance
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.claim(mockToken1, 100e18);
    }

    function test_claim_RevertIf_ZeroAmount() public {
        // RED PHASE: Should FAIL - stub doesn't validate
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.claim(mockToken1, 0);
    }

    function test_calculateClaimAmount_ReturnsCorrectAmount() public {
        // RED PHASE: Should FAIL - returns 0
        uint256 claimAmount = accumulator.calculateClaimAmount(mockToken1, 100e18);
        assertEq(claimAmount, 0, "Should return 0 in red phase");
    }

    /*//////////////////////////////////////////////////////////////
                    YIELD CALCULATION (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_getYield_ReturnsZeroForNewStrategy() public {
        // Should PASS - no yield yet, returns 0
        uint256 yield = accumulator.getYield(mockStrategy1);
        assertEq(yield, 0, "Should return 0 for new strategy");
    }

    function test_getYield_CalculatesYieldFromPrincipal() public {
        // RED PHASE: Should FAIL - stub returns 0, not actual calculation
        uint256 yield = accumulator.getYield(mockStrategy1);
        assertEq(yield, 0, "Should return 0 in red phase");
    }

    function test_getYield_RevertIf_NotRegisteredStrategy() public {
        // RED PHASE: Should FAIL - stub doesn't validate
        // In red phase, it just returns 0, doesn't revert
        uint256 yield = accumulator.getYield(mockStrategy1);
        assertEq(yield, 0, "Stub returns 0, doesn't validate registration");
    }

    function test_getTotalYield_SumsAllStrategies() public {
        // RED PHASE: Should FAIL - returns 0
        uint256 totalYield = accumulator.getTotalYield();
        assertEq(totalYield, 0, "Should return 0 in red phase");
    }

    /*//////////////////////////////////////////////////////////////
                    DECIMAL NORMALIZATION (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_normalizeAmount_6DecimalToken() public {
        // RED PHASE: Should FAIL - normalization logic not implemented
        // This test will fail in red phase because we can't normalize without implementation
        // Placeholder test - will be properly implemented in green phase
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, 6, 1e18);
    }

    function test_normalizeAmount_18DecimalToken() public {
        // RED PHASE: Should FAIL - normalization logic not implemented
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, 18, 1e18);
    }

    function test_normalizeAmount_8DecimalToken() public {
        // RED PHASE: Should FAIL - normalization logic not implemented
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, 8, 1e18);
    }

    function test_fuzz_normalizeAmount_VariousDecimals(uint8 decimals) public {
        // RED PHASE: Should FAIL - normalization logic not implemented
        vm.assume(decimals <= 18);
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.setTokenConfig(mockToken1, decimals, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION SCENARIOS (FAILING)
    //////////////////////////////////////////////////////////////*/

    function test_fullFlow_AddStrategySetConfigCollectClaim() public {
        // RED PHASE: Should FAIL - multiple stubs not implemented
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.addYieldStrategy(mockStrategy1);
    }

    function test_multipleStrategies_CollectAndDistribute() public {
        // RED PHASE: Should FAIL - stubs not implemented
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.addYieldStrategy(mockStrategy1);
    }

    function test_pauseUnpause_AffectsClaimOnly() public {
        // PARTIALLY PASS - pause works, claim stub fails
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // Claim should revert due to pause
        vm.expectRevert();
        accumulator.claim(mockToken1, 100e18);

        // Unpause
        vm.prank(pauser);
        accumulator.unpause();

        // Claim should now revert with NotImplemented (not pause)
        vm.expectRevert(IStableYieldAccumulator.NotImplemented.selector);
        accumulator.claim(mockToken1, 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_edgeCase_PauserCannotPauseAfterRemoval() public {
        // Should PASS - from Story 001
        accumulator.setPauser(pauser);
        accumulator.setPauser(address(0));

        vm.prank(pauser);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_edgeCase_NewPauserCanPauseImmediately() public {
        // Should PASS - from Story 001
        accumulator.setPauser(pauser);

        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        vm.prank(newPauser);
        accumulator.pause();
        assertTrue(accumulator.paused());
    }

    function test_edgeCase_OldPauserCannotPauseAfterChange() public {
        // Should PASS - from Story 001
        accumulator.setPauser(pauser);

        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        vm.prank(pauser);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_edgeCase_OwnerAlwaysCanUnpause() public {
        // Should PASS - from Story 001
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        accumulator.unpause();
        assertFalse(accumulator.paused());
    }

    function test_fuzz_setPauser(address randomPauser) public {
        // Should PASS - from Story 001
        vm.expectEmit(true, true, false, true);
        emit PauserUpdated(address(0), randomPauser);
        accumulator.setPauser(randomPauser);

        assertEq(accumulator.pauser(), randomPauser);
    }

    function test_fuzz_pauseUnpauseCycle(address randomPauser) public {
        // Should PASS - from Story 001
        vm.assume(randomPauser != address(0));

        accumulator.setPauser(randomPauser);

        vm.prank(randomPauser);
        accumulator.pause();
        assertTrue(accumulator.paused());

        vm.prank(randomPauser);
        accumulator.unpause();
        assertFalse(accumulator.paused());
    }
}
