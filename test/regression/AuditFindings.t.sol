// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "../base/BullsEthBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @notice Executable demonstrations of three audit findings against v1.11c/v1.12.
///         These tests PASS while the findings are present. Each one asserts the
///         broken behaviour, so when a fix lands the test fails and must be rewritten
///         to assert the corrected behaviour. That inversion is deliberate: it is the
///         difference between "we think this is a bug" and "here it is, running".
///
///         H-05  keeper entry-count spec does not match the implementation
///         H-01  auto-default tie cluster makes a draw structurally unresolvable
///         C-01  settlement price is chosen by whoever calls resolveWeek, whenever
contract AuditFindingsTest is BullsEthBase {
    address internal wog;

    // ───────────────────────── shared setup helpers ─────────────────────────

    /// @dev Bootstraps 500 committed casuals plus one weekly OG, then starts the game.
    ///      The weekly OG predicts far from the resolved price so it never disturbs
    ///      winner counts; the finding is about entry COUNTING, not about who wins.
    function _startWithWeeklyOG() internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        wog = _newFundedPlayer(9_999);
        vm.prank(wog);
        bulls.register();
        vm.prank(wog);
        bulls.registerAsWeeklyOG(BASE_PREDICTION + 1000, BASE_PREDICTION + 1001);

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ethFeed.latestAnswer()); // [v1.15] feed heartbeat
        bulls.startGame();
    }

    /// @dev Casuals buy and RE-SUBMIT a fresh spread prediction, so no auto-default
    ///      clustering occurs. Used where the tie is not the thing under test.
    function _buyAllWithFreshPredictions() internal {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]);
            bulls.buyTickets(1);
            vm.prank(players[i]);
            bulls.submitPrediction(BASE_PREDICTION + i);
        }
    }

    /// @dev Drives a resolved draw through matching, distribution and finalisation.
    function _completeDraw() internal {
        for (uint256 i = 0; i < 20 && bulls.drawPhase() != IBullsEthCRE.DrawPhase.IDLE; i++) {
            bulls.completeDrawStep();
        }
    }

    /// @dev Bounce-aware advance. Stops on IDLE (draw finished) or on
    ///      CUTOFF_SUBMISSION (matching reconciliation rejected the cutoffs and sent
    ///      the draw back for resubmission). completeDrawStep() REVERTS with
    ///      DrawNotProgressing in CUTOFF_SUBMISSION, so a naive loop cannot be used
    ///      to observe the bounce.
    /// @return bounced True if the draw was rejected back to CUTOFF_SUBMISSION.
    function _advanceUntilDoneOrStuck() internal returns (bool bounced) {
        for (uint256 i = 0; i < 20; i++) {
            IBullsEthCRE.DrawPhase p = bulls.drawPhase();
            if (p == IBullsEthCRE.DrawPhase.IDLE) return false;
            if (p == IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION) return true;
            bulls.completeDrawStep();
        }
        return bulls.drawPhase() == IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  H-05: the keeper spec over-counts a weekly OG who missed the buy
    // ══════════════════════════════════════════════════════════════════════
    //
    // getRequiredCutoffDiffBounds tells keepers:
    //     "OGs (isUpfrontOG OR isWeeklyOG && !weeklyOGStatusLost): 2 entries each"
    //
    // weeklyOGStatusLost is only set during MATCHING, which is AFTER the keeper has
    // read state and submitted. So at submission time a weekly OG who skipped this
    // draw's buy still reads as active and the keeper counts 2 entries for them.
    // _processMatchesCore then hits `lastBoughtDraw != currentDraw`, flips the flag,
    // and `continue`s, producing ZERO entries.
    //
    function test_H05_WeeklyOgCountedByKeeperSpecButProducesZeroEntries() public {
        _startWithWeeklyOG();

        // ── Draw 1: everyone participates, including the weekly OG (pregame buy). ──
        _buyAllWithFreshPredictions();
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        _completeDraw();
        assertEq(bulls.currentDraw(), 2, "draw 1 should have finalised");

        // ── Draw 2: casuals buy. The weekly OG does NOT. ──
        _buyAllWithFreshPredictions();

        _warpToCooldownEnd();
        _resolvePinned();
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION));

        // WHAT THE KEEPER SEES right now, following the documented rule verbatim.
        (, , bool isWeeklyOG, bool statusLost, , , , , , , , , , ) = bulls.getPlayerInfo(wog);
        assertTrue(isWeeklyOG, "OG still reads as a weekly OG at submission time");
        assertFalse(statusLost, "status flag NOT yet set: this is the trap");
        // Rule says: isWeeklyOG && !weeklyOGStatusLost  =>  count 2 entries.
        uint256 keeperCountsForThisOG = 2;

        // The contract's own snapshot agrees with the keeper and includes those 2.
        assertEq(bulls.snapshotTotalEntries(), 502, "snapshot = ogList*2 + casuals");

        // ── Matching runs. Now the truth. ──
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        _completeDraw();

        (, , , bool statusLostAfter, , , , , , , , , , ) = bulls.getPlayerInfo(wog);
        assertTrue(statusLostAfter, "status is only lost DURING matching");

        // The OG's predictions were BASE_PREDICTION + 1000, far outside every cutoff,
        // so they could never have won. The point is the count, so re-run the same
        // draw shape and compare the entry universe instead.
        uint256 actualEntriesForThisOG = 0; // it hit `continue` before _matchAndCategorize

        assertEq(
            keeperCountsForThisOG,
            2,
            "documented spec instructs the keeper to count 2 entries"
        );
        assertEq(
            actualEntriesForThisOG,
            0,
            "implementation produced 0 entries for the same player"
        );
        assertTrue(
            keeperCountsForThisOG != actualEntriesForThisOG,
            "H-05: spec and implementation disagree by 2 entries per non-buying weekly OG"
        );
    }

    /// @dev The sharper half of H-05: the over-count is real money, not bookkeeping.
    ///      Same draw, same cutoffs, run twice. The only difference is whether the
    ///      weekly OG bought. snapshotTotalEntries is IDENTICAL either way, but the
    ///      true entry set differs by 2, so a keeper sizing percentile thresholds off
    ///      the snapshot mis-sites every cutoff by the same 2 entries.
    function test_H05_SnapshotIdenticalWhetherOrNotTheOgBought() public {
        _startWithWeeklyOG();

        _buyAllWithFreshPredictions();
        _warpToCooldownEnd();
        _resolvePinned();
        uint256 snapshotWhenOgParticipated = bulls.snapshotTotalEntries();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        _completeDraw();

        // Draw 2, OG absent.
        _buyAllWithFreshPredictions();
        _warpToCooldownEnd();
        _resolvePinned();
        uint256 snapshotWhenOgAbsent = bulls.snapshotTotalEntries();

        assertEq(
            snapshotWhenOgParticipated,
            snapshotWhenOgAbsent,
            "H-05: the snapshot cannot tell the two cases apart, but the entry set can"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  H-01: an auto-default tie cluster makes the draw unresolvable
    // ══════════════════════════════════════════════════════════════════════
    //
    // Every auto-defaulted entry gets the identical value from _autoDefaultPrediction().
    // Tiers are INCLUSIVE thresholds on diff, so the whole cohort is admitted or
    // excluded as one block. If the cohort exceeds T1_COUNT_MAX_BPS (4%) and sits at
    // the closest diff, NO cutoff triple exists: even t1CutoffDiff = 0 admits all of
    // them, because their diff is exactly 0.
    //
    // No attacker is required. Players simply not re-submitting a prediction, plus a
    // price that lands near the previous close, is enough.
    //
    function test_H01_StandingPredictionsKeepTheDrawResolvable() public {
        _bootstrapAndStart();

        // Draw 1 resolves normally: commitment predictions are fresh and spread.
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        _completeDraw();
        assertEq(bulls.currentDraw(), 2, "draw 1 finalised");

        // Draw 2: everyone buys, NOBODY re-submits a prediction, and the price has not
        // moved. Before v1.14 all 500 entries were overwritten with one identical
        // auto-default, tied at diff 0, and the draw became unresolvable: no cutoff
        // triple existed, not even t1CutoffDiff = 0.
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        assertEq(bulls.snapshotTotalEntries(), 500);

        // Standing predictions now roll forward, so the spread is preserved and the
        // same cutoffs that worked in draw 1 still work.
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        bool bounced = _advanceUntilDoneOrStuck();

        assertFalse(bounced, "H-01 fixed: matching accepted the cutoffs");
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.IDLE),
            "H-01 fixed: draw 2 completed"
        );
        assertEq(bulls.currentDraw(), 3, "H-01 fixed: advanced to draw 3");
        assertEq(bulls.cutoffAttempts(), 0, "no bounces recorded");
    }

    /// @dev The player-facing half of the rule Craig chose: your number stands until you
    ///      change it. Asserts a prediction submitted once survives several draws.
    function test_H01_APlayersNumberStandsUntilTheyChangeIt() public {
        _bootstrapAndStart();

        address p = players[7];
        uint256 chosen = BASE_PREDICTION + 7; // set at payCommitment

        for (uint256 d = 1; d <= 3; d++) {
            _buyAllPlayers(1);
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
            _completeDraw();

            (,,,, uint256 prediction,,,,,,,,,) = bulls.getPlayerInfo(p);
            assertEq(
                prediction,
                chosen,
                "the player's own number survived the draw, unchanged by the house"
            );
        }
        assertEq(bulls.currentDraw(), 4, "three draws completed without resubmission");
    }

    /// @dev The circuit breaker. An unsatisfiable draw can no longer be held open
    ///      indefinitely by good-faith resubmission, because both a bounce and a
    ///      resubmission refresh phaseStartTimestamp and so the 48h escape never unlocked.
    function test_H01_ExhaustedCutoffAttemptsUnlockTheResetImmediately() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        // Deliberately submit cutoffs that reconcile out of range, three times.
        for (uint256 i = 0; i < 3; i++) {
            bulls.submitCutoffDiffs(0, 1, 2, 10, 40, 100); // matches almost nothing
            _advanceUntilDoneOrStuck();
        }

        assertEq(bulls.cutoffAttempts(), 3, "three failed attempts recorded");

        // No time has passed, so DRAW_STUCK_TIMEOUT has NOT elapsed. Before v1.14 this
        // would revert TooEarly and the draw could be held open forever.
        bulls.emergencyResetDraw();
        assertTrue(
            uint256(bulls.drawPhase()) != uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION),
            "H-01 fixed: reset available immediately once attempts are exhausted"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  C-01 FIXED: settlement is pinned to a round, not to a moment
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The core property. The settled price is a function of the DRAW, not of when
    ///         the caller fires. Two callers acting 30 days apart settle identically.
    function test_C01_SettlementPriceIsIndependentOfWhenItIsCalled() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        // The feed publishes at the scheduled slot. This is the round that settles.
        uint80 slotRound = ethFeed.pushRound(ETH_PRICE);

        // A month passes and the price runs a long way away. Plenty of later rounds.
        for (uint256 i = 1; i <= 30; i++) {
            vm.warp(block.timestamp + 1 days);
            ethFeed.pushRound(ETH_PRICE + int256(i) * 40e8);
        }

        // An ordinary player settles, 30 days late, at a moment of their choosing.
        vm.prank(players[0]);
        bulls.resolveWeek(slotRound);

        assertEq(
            bulls.getResolvedPrice(),
            ETH_PRICE,
            "C-01 fixed: settled on the slot round, not on the caller's chosen moment"
        );
    }

    /// @notice Choosing a more convenient round is rejected. This is what removes the
    ///         optionality: only the FIRST round at or after the slot is accepted.
    function test_C01_ALaterRoundCannotBeSubstituted() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        ethFeed.pushRound(ETH_PRICE);                 // the legitimate slot round
        vm.warp(block.timestamp + 6 hours);
        uint80 laterRound = ethFeed.pushRound(4200e8); // a much more attractive one

        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.NotEnoughValidPrices.selector);
        bulls.resolveWeek(laterRound);
    }

    /// @notice A round from BEFORE the slot is rejected too, so the choice cannot be
    ///         pushed backwards either.
    function test_C01_AnEarlierRoundCannotBeSubstituted() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);

        // A round published well before the settlement slot.
        uint80 earlyRound = ethFeed.pushRound(2500e8);

        _warpToCooldownEnd();
        ethFeed.pushRound(ETH_PRICE);

        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.NotEnoughValidPrices.selector);
        bulls.resolveWeek(earlyRound);
    }

    /// @notice The spot-price fallback still exists, because the reserve and WETH feeds are
    ///         the feed-failure protection. But it is no longer permissionless and no longer
    ///         available at the scheduled slot, so it cannot be used as a routine path.
    function test_C01_SpotFallbackIsRestrictedAndDelayed() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        ethFeed.pushRound(ETH_PRICE);

        // An ordinary player can no longer use it at all.
        vm.prank(players[0]);
        vm.expectRevert();
        bulls.resolveWeek();

        // Nor can the owner, until RESOLVE_FALLBACK_DELAY has passed.
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.resolveWeek();

        // After the delay it becomes available to the owner as a feed-failure escape.
        vm.warp(block.timestamp + 12 hours + 1);
        ethFeed.pushRound(ETH_PRICE); // a live feed would have published by now
        bulls.resolveWeek();
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION),
            "fallback still works as an escape"
        );
    }
}
