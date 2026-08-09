// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Weekly OG lifecycle
/// @notice The loyalty track. An upfront OG pays $600 once and is qualified from day one.
///         A weekly OG pays $20 a draw and has to earn it: buy EVERY single draw for the
///         whole season, and one miss ends it permanently.
///
/// @dev    WEEKLY_OG_QUALIFICATION_WEEKS equals TOTAL_DRAWS (both 30), which is the whole
///         design. Qualification is only reachable on the final draw, and there is no
///         mulligan: a single missed buy window sets weeklyOGStatusLost during that draw's
///         matching and it never comes back on its own. 72-hour windows across 90 days mean
///         a missed window is a real signal, not bad luck.
///
///         Three counters move together and drifting them apart is the failure mode this
///         file exists to catch:
///           weeklyOGCount          active weekly OGs
///           earnedOGCount          feeds the OG ratio, so it feeds the return curve
///           qualifiedWeeklyOGCount who actually gets paid at the endgame
///
///         Constants are read from the contract rather than redeclared here. Declaring them
///         locally is how two compile errors got shipped in this suite: one for a constant
///         the base already had, one for a constant it didn't. Reading removes the guess.
contract WeeklyOgLifecycleTest is SmartEarnBase {
    // ══════════════════════════════════════════════════════════════════════
    //  Registration and the starting state
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Registration credits draw 1 immediately: lastBoughtDraw, the streak and the
    ///         prediction slots are all set as though they had already bought. That is why
    ///         a weekly OG must NOT buy in draw 1 (it reverts AlreadyBoughtThisWeek), a trap
    ///         that has caught two fixtures in this project.
    function test_Register_CreditsDrawOneImmediately() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70001, 0);
        _startTheGame();

        (,, bool isWeekly, bool statusLost,,,,, uint256 streak,,,,, ) = bulls.getPlayerInfo(wog);
        assertTrue(isWeekly, "flagged as a weekly OG");
        assertFalse(statusLost, "and status is intact");
        assertEq(streak, 1, "streak starts at 1: registration counts as draw 1");
    }

    function test_Register_IncrementsBothOgCounters() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        uint256 weeklyBefore = bulls.weeklyOGCount();
        uint256 earnedBefore = bulls.earnedOGCount();

        _newWeeklyOg(70002, 0);

        assertEq(bulls.weeklyOGCount(), weeklyBefore + 1, "weeklyOGCount up");
        assertEq(bulls.earnedOGCount(), earnedBefore + 1, "and earnedOGCount with it");
    }

    /// @notice Not qualified at registration, and this is the point of the whole track. An
    ///         upfront OG is qualified from the moment they pay; a weekly OG is not, and
    ///         cannot be until draw 30.
    function test_Register_IsNotQualifiedYet() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70003, 0);
        _startTheGame();

        (,,,,,,,,,,,,, bool qualified) = bulls.getPlayerInfo(wog);
        assertFalse(qualified, "paying in does not qualify you, finishing does");
        assertEq(bulls.qualifiedWeeklyOGCount(), 0, "and nobody is counted as qualified");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The two-ticket minimum
    // ══════════════════════════════════════════════════════════════════════

    /// @notice An active weekly OG must buy the full two tickets every draw. Buying one is
    ///         refused rather than quietly accepted, because a half-price weekly OG would
    ///         still be counted in the OG ratio and would drag the return curve down for
    ///         everyone who paid properly.
    function test_Buy_ActiveWeeklyOgMustTakeTheFullMinimum() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70010, 0);
        _startTheGame();
        _runStandardDraw(); // draw 1 done, they were credited for it

        vm.prank(wog);
        vm.expectRevert(IBullsEthCRE.MinimumTicketsRequired.selector);
        bulls.buyTickets(1);
    }

    /// @notice And the same player CAN buy one ticket once status is lost, because they are
    ///         a casual from that point. The rule follows the status, not the address.
    function test_Buy_AStatusLostOgMayBuyASingleTicket() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70011, 0);
        _startTheGame();
        _runStandardDraw();
        _driveDrawSkippingWeeklies(); // draw 2: they miss, status is stripped in matching

        (,,, bool statusLost,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertTrue(statusLost, "precondition: status is genuinely lost");

        vm.prank(wog);
        bulls.buyTickets(1); // no revert: they are a casual now

        // Confirm it actually landed rather than relying on the absence of a revert.
        (,,,,,,,,,,, bool boughtThisWeek,,) = bulls.getPlayerInfo(wog);
        assertTrue(boughtThisWeek, "the single-ticket buy was accepted and recorded");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Streaks and the gap detector
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A consecutive buy advances the streak by exactly one. Asserted across several
    ///         draws rather than one, so an increment that fired twice or not at all shows up.
    function test_Streak_AdvancesByOnePerConsecutiveDraw() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70020, 0);
        _startTheGame();

        address[] memory cohort = new address[](1);
        cohort[0] = wog;

        _runStandardDraw(); // draw 1, credited at registration
        for (uint256 expected = 2; expected <= 5; expected++) {
            _driveDrawWithWeeklies(cohort);
            (,,,,,,,, uint256 streak,,,,,) = bulls.getPlayerInfo(wog);
            assertEq(streak, expected, "streak tracks the draw count exactly");
        }
    }

    /// @notice Buying twice in one draw cannot happen (AlreadyBoughtThisWeek), so the streak
    ///         has no double-count path. Pinned because the tracker's own guard for it
    ///         (`lastActive == current` returns early) would otherwise be untested.
    function test_Streak_CannotBeDoubleCountedInOneDraw() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70021, 0);
        _startTheGame();
        _runStandardDraw();

        uint256 twoTickets = bulls.MIN_TICKETS_WEEKLY_OG();
        vm.prank(wog);
        bulls.buyTickets(twoTickets);

        vm.prank(wog);
        vm.expectRevert(IBullsEthCRE.AlreadyBoughtThisWeek.selector);
        bulls.buyTickets(twoTickets);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Status loss
    // ══════════════════════════════════════════════════════════════════════

    /// @notice One missed draw ends it. The flag is set during MATCHING, not at the buy
    ///         deadline, because that is when the contract walks the OG list and notices.
    function test_StatusLoss_OneMissedDrawStripsTheStatus() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70030, 0);
        _startTheGame();
        _runStandardDraw();

        uint256 weeklyBefore = bulls.weeklyOGCount();
        uint256 earnedBefore = bulls.earnedOGCount();

        _driveDrawSkippingWeeklies();

        (,,, bool statusLost,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertTrue(statusLost, "status lost after a single miss");
        assertEq(bulls.weeklyOGCount(), weeklyBefore - 1, "weeklyOGCount fell");
        assertEq(bulls.earnedOGCount(), earnedBefore - 1, "and earnedOGCount with it");
    }

    /// @notice Status loss is PERMANENT. Buying again does not restore it, and that is the
    ///         difference between this and lapsing, which reverses automatically. Only an
    ///         emergency reset can undo a status loss, and only for the draw it voided.
    function test_StatusLoss_IsNotUndoneByBuyingAgain() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70031, 0);
        _startTheGame();
        _runStandardDraw();
        _driveDrawSkippingWeeklies();

        // They come back and buy, as a casual.
        vm.prank(wog);
        bulls.buyTickets(1);

        (,, bool isWeekly, bool statusLost,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertTrue(isWeekly, "the flag is still set until a prune clears it");
        assertTrue(statusLost, "but the status stays lost: no way back through play");
    }

    /// @notice The OG's accumulated principal leaves totalOGPrincipal at the moment of loss.
    ///         That figure sizes the dormancy waterfall, so an OG who is no longer an OG must
    ///         not still be reserved for.
    function test_StatusLoss_RemovesTheirPrincipalFromTheOgTotal() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        _newWeeklyOg(70032, 0);
        _startTheGame();
        _runStandardDraw();

        uint256 principalBefore = bulls.totalOGPrincipal();
        _driveDrawSkippingWeeklies();

        assertLt(
            bulls.totalOGPrincipal(),
            principalBefore,
            "their stake left the OG total when the status did"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Qualification: the full 30-draw zero-miss run
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE WHOLE POINT OF THE TRACK, and the most expensive test in the suite. A
    ///         weekly OG who buys every draw of the season qualifies on the LAST one, which
    ///         is the only draw at which it is reachable: the threshold equals the season
    ///         length, so the streak hits 30 exactly as the game closes.
    ///
    /// @dev    Asserts NOT qualified at draw 29 first. Without that, "qualified at 30" could
    ///         be true from any earlier draw and the test would not notice.
    function test_Qualification_RequiresEveryDrawAndLandsOnTheLast() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70040, 0);
        _startTheGame();

        address[] memory cohort = new address[](1);
        cohort[0] = wog;

        _runStandardDraw(); // draw 1, credited at registration

        // Draws 2 through 29: buying every one, never qualified along the way.
        for (uint256 d = 2; d <= 29; d++) {
            _driveDrawWithWeeklies(cohort);
        }
        assertEq(bulls.currentDraw(), 30, "at the final draw");
        assertEq(bulls.qualifiedWeeklyOGCount(), 0, "still NOT qualified after 29 perfect draws");

        // Draw 30: the buy that crosses the threshold.
        uint256 twoTickets = bulls.MIN_TICKETS_WEEKLY_OG();
        vm.prank(wog);
        bulls.buyTickets(twoTickets);

        (,,,,,,,, uint256 streak,,,,,) = bulls.getPlayerInfo(wog);
        assertEq(streak, bulls.WEEKLY_OG_QUALIFICATION_WEEKS(), "streak reached the threshold");
        assertEq(bulls.qualifiedWeeklyOGCount(), 1, "and they are counted as qualified");
    }

    /// @notice A single miss at draw 29 costs the whole season. Same fixture as the test
    ///         above with one draw skipped near the end, so the comparison is exact: draw 1
    ///         credited at registration plus draws 2 through 28 bought is 28 perfect draws,
    ///         and one miss at draw 29 earns nothing at all.
    function test_Qualification_OneMissNearTheEndForfeitsEverything() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70041, 0);
        _startTheGame();

        address[] memory cohort = new address[](1);
        cohort[0] = wog;

        _runStandardDraw();
        for (uint256 d = 2; d <= 28; d++) {
            _driveDrawWithWeeklies(cohort);
        }

        // Draw 29: they miss. Matching strips the status.
        _driveDrawSkippingWeeklies();

        (,,, bool statusLost,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertTrue(statusLost, "28 perfect draws undone by one miss");
        assertEq(bulls.qualifiedWeeklyOGCount(), 0, "nothing earned");

        (,,,,,,,,,,,,, bool qualified) = bulls.getPlayerInfo(wog);
        assertFalse(qualified, "and not qualified for the endgame");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The cap, and its order dependence
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The documented direction. Once upfront OGs consume the 18% total-OG headroom,
    ///         weekly registration is refused. This is the direction the contract's own
    ///         NatSpec describes.
    function test_Cap_UpfrontRegistrationsCanExhaustTheWeeklySlots() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        // 110, NOT 100, and the arithmetic is the whole trap. Each registerAsOG by a player
        // with no prior commitment does committedPlayerCount++, so every upfront OG RAISES
        // the denominator the 18% cap is measured against. Registering upfront OGs enlarges
        // the cap they are trying to exhaust.
        //
        // At 100: committed 600, maxTotal = 108, upfront 100, so 8 weekly slots are STILL
        // FREE and the registration below would succeed. The test would fail while looking
        // like it had the right idea.
        //
        // Need N >= (500 + N) * 0.18, so 0.82N >= 90, so N >= 110.
        // At 110: committed 610, maxTotal = 109, upfront 110 exceeds it, maxEarned = 0.
        for (uint256 i = 0; i < 110; i++) {
            address og = _newFundedPlayer(70050 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }

        address late = _newFundedPlayer(70200);
        vm.prank(late); bulls.register();
        vm.prank(late);
        vm.expectRevert(IBullsEthCRE.OGCapReached.selector);
        bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000, BASE_PREDICTION + 7001);
    }

    /// @notice THE UNDOCUMENTED DIRECTION, and the reason this test exists. The cap is
    ///         evaluated ONLY inside registerAsWeeklyOG and is never re-checked afterwards.
    ///         So registering weekly OGs FIRST, while the upfront count is still low, and
    ///         then surging upfront registrations, legally lands the combined OG share above
    ///         the nominal 18% ceiling.
    ///
    ///         Not a vulnerability: the return curve prices ratios continuously to 100% and
    ///         the real solvency constraints are elsewhere. But a reader would reasonably
    ///         assume the cap binds in both directions, and it does not. Recorded in
    ///         KNOWN_ISSUES and pinned here so the behaviour cannot drift silently.
    function test_Cap_IsBypassableByRegisteringWeeklyFirst() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        // Weekly first: at this point the cap is ~18% of ~500 and the upfront count is 0.
        for (uint256 i = 0; i < 10; i++) {
            _newWeeklyOg(70300 + i, i);
        }
        // Then the uncapped upfront surge.
        for (uint256 i = 0; i < 140; i++) {
            address og = _newFundedPlayer(70400 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }

        uint256 committed = bulls.committedPlayerCount();
        uint256 totalOgs = bulls.upfrontOGCount() + bulls.weeklyOGCount();
        uint256 ratioBps = totalOgs * 10000 / committed;

        assertGt(
            ratioBps,
            bulls.TOTAL_OG_CAP_BPS(),
            "combined OG share is legally above the nominal 18% ceiling"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  After the fall: pruning
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Pruning is what finally clears the weekly OG flag. Until then a status-lost
    ///         OG still occupies a slot in ogList that matching walks past every draw, which
    ///         is the cost the prune exists to remove.
    function test_Prune_ClearsTheFlagAndFreesTheListSlot() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address wog = _newWeeklyOg(70060, 0);
        _startTheGame();
        _runStandardDraw();
        _driveDrawSkippingWeeklies();

        assertEq(bulls.countStaleOGs(), 1, "precondition: one stale entry");

        bulls.pruneStaleOGs(10);

        (,, bool isWeekly, bool statusLost,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertFalse(isWeekly, "the weekly OG flag is cleared by the prune");
        assertFalse(statusLost, "and the lost-status marker with it");
        assertEq(bulls.countStaleOGs(), 0, "no stale entries remain");
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    /// @dev Registers one weekly OG. `slot` spaces their two predictions apart so several
    ///      in a cohort do not collide on the same number.
    function _newWeeklyOg(uint256 seed, uint256 slot) internal returns (address wog) {
        wog = _newFundedPlayer(seed);
        vm.prank(wog); bulls.register();
        vm.prank(wog);
        bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000 + slot, BASE_PREDICTION + 7500 + slot);
    }

    function _startTheGame() internal {
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();
    }

    /// @dev One full draw where the casuals buy one ticket and the named weekly OGs buy their
    ///      two-ticket minimum. The constant read is HOISTED out of the prank line: vm.prank
    ///      applies to the next external call, and a getter in the argument position would be
    ///      that call, leaving buyTickets to run as the test contract.
    function _driveDrawWithWeeklies(address[] memory weeklies) internal {
        uint256 twoTickets = bulls.MIN_TICKETS_WEEKLY_OG();
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        for (uint256 i = 0; i < weeklies.length; i++) {
            vm.prank(weeklies[i]); bulls.buyTickets(twoTickets);
        }
        _settleTheDraw();
    }

    /// @dev One full draw where the casuals buy and NO weekly OG does, which is what strips
    ///      status during matching.
    function _driveDrawSkippingWeeklies() internal {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _settleTheDraw();
    }

    /// @dev Resolve, submit cutoffs, and drive to IDLE. Counts are sized for 500 casuals plus
    ///      a small weekly cohort: at 500-520 snapshot entries, 10/40/100 reads as roughly
    ///      190-200 / 770-800 / 1920-2000 bps, inside T1 [50,400], T2 [400,1200] and
    ///      T3 [1000,5000] throughout. The loop stops on a bounce back to CUTOFF_SUBMISSION
    ///      rather than calling completeDrawStep there, which reverts DrawNotProgressing.
    function _settleTheDraw() internal {
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }
    }
}
