// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Draw machinery
/// @notice The nine functions a normal draw passes through, every draw, all season. Until
///         this file the whole lot was covered by exactly ONE happy-path test.
///
/// @dev    That is the wrong shape of risk. The failure paths get audited because they look
///         dangerous; the code that runs 30 times a season gets one test because it
///         obviously works. It obviously works on ONE path.
///
///         The order, and each step's gate:
///           buyTickets          ACTIVE + IDLE, before PICK_DEADLINE
///           submitPrediction    same window, must have bought
///           submitPrediction2   same, and only with two tickets
///           resolveWeek         after DRAW_COOLDOWN, pins a feed round -> CUTOFF_SUBMISSION
///           submitCutoffDiffs   keeper only, validated -> MATCHING
///           processMatches      permissionless, batched at MAX_MATCH_PER_TX (500)
///           distributePrizes    batched at MAX_DISTRIBUTE_PER_TX (200)
///           finalizeWeek        -> IDLE, next draw
///           completeDrawStep    drives whichever of the above is due
contract DrawMachineryTest is SmartEarnBase {
    // ══════════════════════════════════════════════════════════════════════
    //  buyTickets
    // ══════════════════════════════════════════════════════════════════════

    function test_Buy_RevertsForAnUnregisteredAddress() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(70001);
        vm.prank(stranger);
        vm.expectRevert(IBullsEthCRE.NotRegistered.selector);
        bulls.buyTickets(1);
    }

    function test_Buy_RevertsOnASecondBuyInTheSameDraw() public {
        _bootstrapAndStart();
        vm.prank(players[0]);
        bulls.buyTickets(1);
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.AlreadyBoughtThisWeek.selector);
        bulls.buyTickets(1);
    }

    /// @dev Zero and over-cap share ONE guard:
    ///      `if (ticketCount == 0 || ticketCount > MAX_TICKETS_PER_WEEK) revert ExceedsLimit()`.
    ///      I expected MinimumTicketsRequired for zero; that error is a weekly-OG-only rule
    ///      (an active weekly OG must buy at least MIN_TICKETS_WEEKLY_OG), not a floor on
    ///      everyone. Both bounds asserted here so the shared guard is pinned end to end.
    function test_Buy_RevertsAboveTheTicketCap() public {
        _bootstrapAndStart();
        uint256 tooMany = bulls.MAX_TICKETS_PER_WEEK() + 1; // cap is 2, so 3
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.buyTickets(tooMany);
    }

    function test_Buy_RevertsOnZeroTickets() public {
        _bootstrapAndStart();
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.buyTickets(0);
    }

    /// @notice The 48-hour lock. After it, nobody can buy into the draw being settled,
    ///         which is what stops anyone entering once the price is near-known.
    function test_Buy_RevertsAfterThePickDeadline() public {
        _bootstrapAndStart();
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.PicksLocked.selector);
        bulls.buyTickets(1);
    }

    function test_Buy_RevertsMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned(); // now CUTOFF_SUBMISSION, not IDLE

        address p = _newFundedPlayer(70002);
        vm.prank(p); bulls.register();
        vm.prank(p);
        // DrawInProgress, not PicksLocked: the phase check runs first. Both would be
        // correct refusals; this pins which one a caller actually sees.
        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.buyTickets(1);
    }

    function test_Buy_RevertsForAnUpfrontOG() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address og = _newFundedPlayer(70003);
        vm.prank(og); bulls.register();
        vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000, BASE_PREDICTION + 4000);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.AlreadyOG.selector);
        bulls.buyTickets(1);
    }

    /// @notice Draw 1 is paid by pregame commitment credit, so no USDC moves and no
    ///         in-season treasury accrues. Draw 2 onward is a real transfer. This is the
    ///         fact the H-02 cold-start finding turned on, so it is worth pinning.
    /// @dev The credit is consumed by a player's FIRST buy and every later one is a real
    ///      charge. An earlier version bought in draw 1 and again in draw 2 by hand, which
    ///      reverted AlreadyBoughtThisWeek because _runStandardDraw had already bought for
    ///      everyone. Driving the draw through the helper avoids double-buying.
    ///
    function test_Buy_Draw1UsesCreditAndDraw2Charges() public {
        _bootstrapAndStart();

        uint256 before1 = usdc.balanceOf(players[0]);
        vm.prank(players[0]); bulls.buyTickets(1);
        assertEq(usdc.balanceOf(players[0]), before1, "draw 1 costs nothing: commitment credit");
        assertEq(bulls.cumulativeSeasonTreasury(), 0, "and no in-season treasury accrues");

        // Everyone ELSE buys too, so the entry count matches the fixed cutoff constants
        // (they assume 500 single-ticket entries). players[0] is skipped: they already
        // bought above, and buying twice reverts AlreadyBoughtThisWeek.
        for (uint256 i = 1; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) bulls.completeDrawStep();
        assertEq(bulls.currentDraw(), 2, "draw 1 finalised");

        uint256 before2 = usdc.balanceOf(players[0]);
        vm.prank(players[0]); bulls.buyTickets(1);
        assertEq(
            before2 - usdc.balanceOf(players[0]),
            TICKET_PRICE,
            "draw 2 is a real charge, the credit is spent"
        );
        assertGt(bulls.cumulativeSeasonTreasury(), 0, "and treasury starts accruing");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  submitPrediction
    // ══════════════════════════════════════════════════════════════════════

    function test_Predict_RevertsForSomeoneWhoHasNotBought() public {
        _bootstrapAndStart();
        address p = _newFundedPlayer(70004);
        vm.prank(p); bulls.register();
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.NotEligible.selector);
        bulls.submitPrediction(BASE_PREDICTION);
    }

    function test_Predict_RevertsAfterThePickDeadline() public {
        _bootstrapAndStart();
        vm.prank(players[0]); bulls.buyTickets(1);
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.PicksLocked.selector);
        bulls.submitPrediction(BASE_PREDICTION + 5);
    }

    function test_Predict_CanBeChangedWhileTheWindowIsOpen() public {
        _bootstrapAndStart();
        vm.prank(players[0]); bulls.buyTickets(1);
        vm.prank(players[0]); bulls.submitPrediction(BASE_PREDICTION + 11);
        vm.prank(players[0]); bulls.submitPrediction(BASE_PREDICTION + 22);

        (,,,, uint256 pred,,,,,,,,,) = bulls.getPlayerInfo(players[0]);
        assertEq(pred, BASE_PREDICTION + 22, "the later submission wins");
    }

    /// @notice A second entry can only be predicted for if two tickets were bought.
    function test_Predict2_RevertsWithOnlyOneTicket() public {
        _bootstrapAndStart();
        vm.prank(players[0]); bulls.buyTickets(1);
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.NotEligible.selector);
        bulls.submitPrediction2(BASE_PREDICTION + 5);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  submitCutoffDiffs, the validation heart
    // ══════════════════════════════════════════════════════════════════════

    function test_Cutoffs_RevertsForAStranger() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        address stranger = _newFundedPlayer(70005);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
    }

    function test_Cutoffs_RevertsInTheWrongPhase() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
    }

    /// @notice Tiers are nested: every T1 winner is also inside T2's range, and so on. So
    ///         the diffs must ascend. A descending set would make the tiers overlap
    ///         incoherently rather than nest.
    function test_Cutoffs_RevertsOnDescendingDiffs() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.InvalidCutoffOrder.selector);
        bulls.submitCutoffDiffs(99e6, 39e6, 9e6, 10, 40, 100);
    }

    function test_Cutoffs_RevertsOnDescendingCounts() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.InvalidCutoffOrder.selector);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 100, 40, 10);
    }

    /// @notice The count bands are what stop a keeper handing the jackpot to half the field
    ///         or to nobody. T1 must land between 0.5% and 4% of entries.
    function test_Cutoffs_RevertsWhenT1IsTooLarge() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        // 500 entries, so 4% is 20. 100 is far outside.
        vm.expectRevert(IBullsEthCRE.CutoffOutOfRange.selector);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 100, 150, 200);
    }

    function test_Cutoffs_RevertsWhenT1IsTooSmall() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        // 500 entries, so the 50 bps floor needs at least 3 (ceiling of 2.5).
        vm.expectRevert(IBullsEthCRE.CutoffOutOfRange.selector);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 1, 40, 100);
    }

    function test_Cutoffs_AcceptedSetAdvancesToMatching() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.MATCHING),
            "advanced to MATCHING"
        );
        assertEq(bulls.t1CutoffDiff(), 9e6, "t1 stored");
        assertEq(bulls.t3CutoffDiff(), 99e6, "t3 stored");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Phase gating: each step refuses out of turn
    // ══════════════════════════════════════════════════════════════════════

    function test_Phase_ProcessMatchesRefusesBeforeCutoffs() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned(); // CUTOFF_SUBMISSION, not MATCHING

        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.processMatches();
    }

    function test_Phase_DistributeRefusesBeforeMatching() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100); // MATCHING, not DISTRIBUTING

        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.distributePrizes();
    }

    function test_Phase_FinalizeRefusesMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.finalizeWeek();
    }

    /// @notice completeDrawStep is the keeper's single entry point: it works out which step
    ///         is due. It refuses in CUTOFF_SUBMISSION because that step needs a human or a
    ///         workflow to supply the numbers, not just a nudge.
    function test_Phase_CompleteDrawStepRefusesInCutoffSubmission() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.DrawNotProgressing.selector);
        bulls.completeDrawStep();
    }

    function test_Phase_ResolveRefusesBeforeTheCooldown() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        // no warp: the 72h cooldown has not elapsed
        uint80 rid = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.CooldownActive.selector);
        bulls.resolveWeek(rid);
    }

    function test_Phase_ResolveRefusesTwiceForTheSameDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        uint80 rid2 = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.resolveWeek(rid2);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The draw as a whole
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Anyone can drive a draw forward once the cutoffs are in. The steps are
    ///         permissionless by design so a keeper going offline cannot freeze the game,
    ///         which is the same reasoning behind the unwind continuation.
    function test_Draw_StepsArePermissionlessAfterCutoffs() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);

        address stranger = _newFundedPlayer(70006);
        for (uint256 i = 0; i < 20; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            vm.prank(stranger);
            bulls.completeDrawStep();
        }
        assertEq(bulls.currentDraw(), 2, "a stranger drove the whole draw to completion");
    }

    /// @notice Winner counts must match the cutoffs that were accepted. If matching produced
    ///         different numbers the reconciliation would bounce the draw, so equality here
    ///         is the proof that the keeper's numbers and the contract's agree.
    function test_Draw_WinnerCountsMatchTheSubmittedCutoffs() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.completeDrawStep(); // matching

        (uint256 t1, uint256 t2, uint256 t3) = bulls.getWinnerCounts();
        assertEq(t1, 10, "T1 count as submitted");
        assertEq(t2, 30, "T2 is the band between t1 and t2 counts");
        assertEq(t3, 60, "T3 is the band between t2 and t3 counts");
    }

    /// @notice Value conservation across a whole draw. Prizes move from the pot to players'
    ///         unclaimed balances; nothing is created and nothing leaves the contract until
    ///         someone actually claims.
    function test_Draw_ConservesValueAcrossAFullCycle() public {
        _bootstrapAndStart();
        uint256 balBefore = usdc.balanceOf(address(bulls));

        _runStandardDraw();

        // Draw 1 buys are credit, so no USDC enters. Nothing should have left either.
        assertEq(
            usdc.balanceOf(address(bulls)),
            balBefore,
            "no USDC entered or left across the draw"
        );
        assertGt(bulls.totalUnclaimedPrizes(), 0, "but prizes were allocated to winners");
    }

    function test_Draw_AdvancesTheScheduleByExactlyOneCooldown() public {
        _bootstrapAndStart();
        uint256 slotBefore = bulls.lastDrawTimestamp();

        _runStandardDraw();

        assertEq(
            bulls.lastDrawTimestamp(),
            slotBefore + DRAW_COOLDOWN,
            "the schedule advances by one fixed cooldown, not by elapsed time"
        );
    }

    /// @notice The fixed schedule is the point: slots come off the launch anchor, so a draw
    ///         that settles late does not push every later draw back. Also the mechanism
    ///         H-03 concerns, since a late finalise can leave the next buy window closed.
    ///
    /// @dev    MUST settle a draw LATE, and an earlier version did not. It ran two normal
    ///         draws and asserted anchor + 2 cooldowns, which passes on a DRIFTING
    ///         implementation too: the fixture settles every draw exactly at its slot, and
    ///         at that instant anchored and drifting produce identical timestamps. The
    ///         assertion was real but the counterfactual was unreachable, so the word
    ///         "regardless" was untested. The subtlest vacuity case in this suite so far.
    ///
    ///         Draw 2 now settles ten hours after its slot. The pinned path accepts that
    ///         round correctly, because with no round published between the slot and then,
    ///         it IS the first round at or after the slot. A drifting implementation would
    ///         set lastDrawTimestamp to the settlement instant and this would fail.
    function test_Draw_ScheduleIsAnchoredEvenWhenADrawSettlesLate() public {
        _bootstrapAndStart();
        uint256 anchor = bulls.scheduleAnchor();

        _runStandardDraw(); // draw 1, settled on time

        // Draw 2: buy inside the window, then let the slot pass by ten hours.
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        uint256 slot2 = bulls.lastDrawTimestamp() + DRAW_COOLDOWN;
        vm.warp(slot2 + 10 hours);

        uint80 rid = ethFeed.pushRound(ETH_PRICE); // first round at or after the slot
        bulls.resolveWeek(rid);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) bulls.completeDrawStep();

        assertEq(
            bulls.lastDrawTimestamp(),
            anchor + 2 * DRAW_COOLDOWN,
            "slot 2 is anchor + 2 cooldowns even though the draw settled 10h late"
        );
        assertLt(
            bulls.lastDrawTimestamp(),
            block.timestamp,
            "and it is NOT the settlement instant, which is what drifting would give"
        );
    }
}
