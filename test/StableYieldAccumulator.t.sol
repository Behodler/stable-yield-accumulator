// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableYieldAccumulator.sol";

/**
 * @title StableYieldAccumulatorTest
 * @notice Comprehensive test suite for StableYieldAccumulator pausable functionality
 * @dev Following TDD principles - these tests are written before implementation
 */
contract StableYieldAccumulatorTest is Test {
    StableYieldAccumulator public accumulator;

    address public owner;
    address public pauser;
    address public user1;
    address public user2;

    // Events to test
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        owner = address(this);
        pauser = makeAddr("pauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        accumulator = new StableYieldAccumulator();
    }

    /*//////////////////////////////////////////////////////////////
                        SET PAUSER TESTS
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
                        PAUSE TESTS
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
                        UNPAUSE TESTS
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
                        STATE PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    // Note: Since the contract is a stub, we'll create a mock state-changing function
    // In a real scenario, these would test actual deposit/withdraw/claim functions

    function test_pause_BlocksStateChangingFunctions() public {
        // This test is a placeholder for when state-changing functions exist
        // It verifies the concept that whenNotPaused modifier blocks operations

        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // Once we have state-changing functions, we would test them here
        // Example: vm.expectRevert(); accumulator.deposit(100);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_viewFunctions_WorkWhenPaused() public {
        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // View functions should still work
        assertEq(accumulator.pauser(), pauser, "Pauser getter should work when paused");
        assertTrue(accumulator.paused(), "Paused getter should work when paused");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_edgeCase_PauserCannotPauseAfterRemoval() public {
        // Set and then remove pauser
        accumulator.setPauser(pauser);
        accumulator.setPauser(address(0));

        // Old pauser cannot pause
        vm.prank(pauser);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_edgeCase_NewPauserCanPauseImmediately() public {
        // Set initial pauser
        accumulator.setPauser(pauser);

        // Change pauser
        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        // New pauser can pause immediately
        vm.prank(newPauser);
        accumulator.pause();
        assertTrue(accumulator.paused());
    }

    function test_edgeCase_OldPauserCannotPauseAfterChange() public {
        // Set initial pauser
        accumulator.setPauser(pauser);

        // Change pauser
        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        // Old pauser cannot pause
        vm.prank(pauser);
        vm.expectRevert("Only pauser can call this function");
        accumulator.pause();
    }

    function test_edgeCase_OwnerAlwaysCanUnpause() public {
        // Set pauser and pause
        accumulator.setPauser(pauser);
        vm.prank(pauser);
        accumulator.pause();

        // Change pauser while paused
        address newPauser = makeAddr("newPauser");
        accumulator.setPauser(newPauser);

        // Owner can still unpause
        accumulator.unpause();
        assertFalse(accumulator.paused());
    }

    function test_fuzz_setPauser(address randomPauser) public {
        // Fuzz test for setting any address as pauser
        vm.expectEmit(true, true, false, true);
        emit PauserUpdated(address(0), randomPauser);
        accumulator.setPauser(randomPauser);

        assertEq(accumulator.pauser(), randomPauser);
    }

    function test_fuzz_pauseUnpauseCycle(address randomPauser) public {
        // Skip zero address as pauser for this test
        vm.assume(randomPauser != address(0));

        // Set pauser and test pause/unpause cycle
        accumulator.setPauser(randomPauser);

        // Pause
        vm.prank(randomPauser);
        accumulator.pause();
        assertTrue(accumulator.paused());

        // Unpause
        vm.prank(randomPauser);
        accumulator.unpause();
        assertFalse(accumulator.paused());
    }
}
