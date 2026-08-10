// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Seed deposit guards and the live solvency check
/// @notice Two small clusters, both written specifically as prerequisites for invariant
///         fuzzing rather than for their own sake.
///
/// @dev    `SolvencyCheckFailed` is the LIVE ENFORCEMENT SITE of the headline fuzz
///         invariant: that the contract's USDC balance covers every allocated pool. The
///         fuzz will run thousands of legal sequences and assert that check never trips.
///         That claim is only worth anything if the check works, and nothing had ever seen
///         it fire. Proving it fires, then proving the fuzz never makes it fire, is the
///         pair. On its own the second half proves nothing.
///
///         `seedPot` is the other prerequisite: the handler needs to know seeding is
///         one-shot and pregame-only, or it will generate sequences that revert for
///         uninteresting reasons and waste runs.
contract SeedAndSolvencyTest is SmartEarnBase {
    // ══════════════════════════════════════════════════════════════════════
    //  seedPot
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Seeding is ONE-SHOT. A second deposit would inflate prizePot without the
    ///         VC's return obligation rising to match, so the contract would owe less than
    ///         it holds and the difference would settle to the beneficiary.
    function test_Seed_CannotBeDepositedTwice() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        assertTrue(bulls.potSeeded(), "precondition: the fixture has already seeded");

        vm.expectRevert(IBullsEthCRE.PotAlreadySeeded.selector);
        bulls.seedPot();
    }

    /// @notice And the deposit is reflected in both places it needs to be: the flag that
    ///         gates startGame, and the pot itself.
    ///
    /// @dev    Asserted on the post-bootstrap state rather than by seeding here, because the
    ///         fixture seeds during setup and there is no unseeded moment to observe from
    ///         outside. `>=` on the pot, not `==`: pregame commitments have also landed in it
    ///         by this point, so the seed is a floor rather than the whole balance.
    function test_Seed_IsRecordedInTheFlagAndThePot() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        assertTrue(bulls.potSeeded(), "the flag that gates startGame is set");
        assertGe(
            bulls.prizePot(),
            bulls.VC_SEED(),
            "and the seed is in the pot, at minimum"
        );
    }

    /// @notice Seeding is PREGAME-only. Once the season is running the solvency floor has
    ///         already been computed from the seeded pot, so a late deposit would sit outside
    ///         every figure the solver is defending.
    function test_Seed_IsRefusedOnceTheGameIsRunning() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.seedPot();
    }

    /// @notice Owner-only, and worth pinning next to the others so the whole guard set reads
    ///         in one place.
    function test_Seed_IsOwnerOnly() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address stranger = _newFundedPlayer(74001);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.seedPot();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SolvencyCheckFailed
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE CHECK THE FUZZ WILL LEAN ON, proven to actually fire. `_captureYieldAndCheck`
    ///         runs inside `_resolveWeekGate`, so every settlement passes through it. If the
    ///         contract's USDC balance falls below what it has allocated, the draw refuses to
    ///         resolve rather than distributing money it does not hold.
    ///
    /// @dev    STATE INJECTION, disclosed in full. USDC is moved out of the contract by
    ///         pranking as the contract itself. Nothing else is touched, and the injection
    ///         only makes a gate FIRE that honest play cannot reach: it never loosens
    ///         anything.
    ///
    ///         This is deliberately unreachable through legal calls. That IS the point. A
    ///         guard against a state the contract's own accounting forbids can only be
    ///         demonstrated by manufacturing that state, and the alternative is shipping a
    ///         safety check nothing has ever executed.
    function test_Solvency_ResolutionRefusesWhenTheBalanceCannotCoverAllocations() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        // Drain well past SOLVENCY_TOLERANCE so the shortfall is unambiguous.
        uint256 held = usdc.balanceOf(address(bulls));
        uint256 drain = held / 2;
        assertGt(drain, bulls.SOLVENCY_TOLERANCE(), "precondition: the drain clears the dust tolerance");

        address sink = _newFundedPlayer(74002);
        vm.prank(address(bulls));
        usdc.transfer(sink, drain);

        uint80 rid = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.SolvencyCheckFailed.selector);
        bulls.resolveWeek(rid);
    }

    /// @notice And it does NOT fire on a healthy contract. Without this the test above would
    ///         be satisfied by a check that refuses everything, which is a different bug with
    ///         the same symptom.
    function test_Solvency_ResolutionProceedsWhenTheBalanceIsIntact() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION),
            "an intact contract resolves normally"
        );
    }

    /// @notice A shortfall INSIDE the tolerance is absorbed rather than blocking the season.
    ///         SOLVENCY_TOLERANCE exists because USDC rounding leaves dust, and a check that
    ///         halted the game over a fraction of a cent would be worse than no check.
    ///
    /// @dev    Drains strictly less than the tolerance, so the sum stays satisfied. This is
    ///         the boundary that makes the tolerance meaningful rather than decorative.
    function test_Solvency_DustSizedShortfallsAreAbsorbed() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        address sink = _newFundedPlayer(74003);
        // HOISTED. vm.prank attaches to the next EXTERNAL call, and a contract read in the
        // argument position IS that call: the prank would be spent on the getter and the
        // transfer would run as the test contract, which holds nothing. Fourth landing of
        // this in the project, and the test directly above gets it right, so the two sit
        // here as a matched pair.
        uint256 dust = bulls.SOLVENCY_TOLERANCE() / 2;
        vm.prank(address(bulls));
        usdc.transfer(sink, dust);

        _resolvePinned(); // must not revert

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION),
            "a sub-tolerance shortfall does not halt the season"
        );
    }
}
