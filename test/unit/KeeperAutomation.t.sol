// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Keeper and automation
/// @notice The machinery that keeps the game moving without anyone watching it. If
///         checkUpkeep reports the wrong thing, the game silently stops advancing: no
///         revert, no event, just a season that quietly stalls.
///
/// @dev    checkUpkeep answers ONE question: is there work to do, and which kind. It
///         returns an action byte that performUpkeep then dispatches on:
///
///           1  advance the current draw one step (matching, distributing, finalizing,
///              unwinding). NOT cutoff submission, which needs numbers a keeper cannot
///              invent, so that phase deliberately reports "nothing to do".
///           2  apply auto-picks, signalled in the hour before the pick deadline.
///           3  prune stale OGs, once enough have accumulated to slow matching down.
///
///         The CRE seam beside this (onReport, CreReportGuard) already has coverage; the
///         Chainlink Automation path did not.
contract KeeperAutomationTest is SmartEarnBase {
    // PICK_DEADLINE is NOT declared here: BullsEthBase already has it, and a second
    // declaration is a compile error. The base-collision class landing for the second time,
    // one file after the NOTE in Treasury.t.sol warning about exactly this. The lesson I
    // wrote down was "check the base in both directions" and I applied it only to the one
    // constant I had already been burned on, not to the other three I was declaring.
    // Checking is per-constant, not per-lesson.
    //
    // AUTO_PICK_BUFFER and MAX_LAPSE_BATCH are genuinely absent from the base, so these two
    // are correctly local.
    uint256 internal constant AUTO_PICK_BUFFER = 1 hours;
    uint256 internal constant MAX_LAPSE_BATCH = 500;

    // ══════════════════════════════════════════════════════════════════════
    //  checkUpkeep: which work is reported, and when
    // ══════════════════════════════════════════════════════════════════════

    function test_CheckUpkeep_ReportsNothingBeforeTheGameStarts() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        (bool needed, bytes memory data) = bulls.checkUpkeep("");
        assertFalse(needed, "no upkeep in PREGAME");
        assertEq(data.length, 0, "and no action payload");
    }

    /// @notice A draw mid-flight reports action 1: there is a step to take.
    function test_CheckUpkeep_ReportsAdvanceWhenADrawIsMidFlight() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100); // now MATCHING

        (bool needed, bytes memory data) = bulls.checkUpkeep("");
        assertTrue(needed, "work is available");
        assertEq(abi.decode(data, (uint8)), 1, "action 1: advance the draw");
    }

    /// @notice THE DELIBERATE SILENCE. Cutoff submission needs figures a keeper computes
    ///         off-chain from every prediction; automation cannot invent them. So this phase
    ///         reports NO work rather than handing back an action that would revert.
    ///
    ///         That is why a stuck cutoff phase needs emergencyResetDraw rather than more
    ///         automation: nothing is going to come along and unstick it.
    function test_CheckUpkeep_ReportsNothingDuringCutoffSubmission() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned(); // CUTOFF_SUBMISSION

        (bool needed, bytes memory data) = bulls.checkUpkeep("");
        assertFalse(needed, "automation deliberately reports nothing here");
        assertEq(data.length, 0, "and no action payload");
    }

    /// @notice Action 2 fires only inside the hour before the pick deadline, which is the
    ///         last moment auto-picks can still be applied for the current draw.
    function test_CheckUpkeep_ReportsAutoPicksInsideTheBufferWindow() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);

        // Just inside the window: deadline minus half the buffer.
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE - (AUTO_PICK_BUFFER / 2));
        (bool needed, bytes memory data) = bulls.checkUpkeep("");
        assertTrue(needed, "inside the buffer, auto-picks are due");
        assertEq(abi.decode(data, (uint8)), 2, "action 2: apply auto-picks");
    }

    /// @notice And NOT before the window opens. Asserted separately so the test above cannot
    ///         be passing simply because action 2 is reported all the time.
    function test_CheckUpkeep_ReportsNothingBeforeTheBufferWindowOpens() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);

        // Comfortably before the window: two hours ahead of it opening.
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE - AUTO_PICK_BUFFER - 2 hours);
        (bool needed,) = bulls.checkUpkeep("");
        assertFalse(needed, "outside the buffer there is nothing due");
    }

    /// @notice And the window CLOSES. Past the pick deadline there is nothing to apply, so
    ///         the signal stops. Pairs with the two tests above to pin both edges: reported
    ///         inside, silent before, silent after. Without this the window could have been
    ///         open-ended from its start and the earlier tests would not have noticed.
    function test_CheckUpkeep_ReportsNothingOnceThePickDeadlinePasses() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);

        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);
        (bool needed,) = bulls.checkUpkeep("");
        assertFalse(needed, "past the deadline the auto-pick signal stops");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  performUpkeep: authorisation and dispatch
    // ══════════════════════════════════════════════════════════════════════

    function test_PerformUpkeep_RevertsForAnUnauthorisedCaller() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(91001);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.performUpkeep(abi.encode(uint8(1)));
    }

    /// @notice Only three actions exist. Anything else is rejected by name rather than
    ///         falling through to a silent no-op, so a misconfigured keeper is visible.
    function test_PerformUpkeep_RejectsAnUnknownAction() public {
        _bootstrapAndStart();
        vm.expectRevert(abi.encodeWithSelector(IBullsEthCRE.UnknownAction.selector, uint8(9)));
        bulls.performUpkeep(abi.encode(uint8(9)));
    }

    function test_PerformUpkeep_RejectsActionZero() public {
        _bootstrapAndStart();
        vm.expectRevert(abi.encodeWithSelector(IBullsEthCRE.UnknownAction.selector, uint8(0)));
        bulls.performUpkeep(abi.encode(uint8(0)));
    }

    /// @notice Action 1 refuses in cutoff submission, matching what checkUpkeep reports. The
    ///         two must agree: if checkUpkeep said "nothing here" and performUpkeep happily
    ///         advanced anyway, a keeper acting on stale data could push a draw forward
    ///         without its cutoffs.
    function test_PerformUpkeep_ActionOneRefusesDuringCutoffSubmission() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.DrawNotProgressing.selector);
        bulls.performUpkeep(abi.encode(uint8(1)));
    }

    /// @notice And in IDLE, where there is genuinely no step to take.
    function test_PerformUpkeep_ActionOneRefusesWhenIdle() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.DrawNotProgressing.selector);
        bulls.performUpkeep(abi.encode(uint8(1)));
    }

    /// @notice The happy path: action 1 in MATCHING actually advances the draw phase.
    function test_PerformUpkeep_ActionOneAdvancesAMidFlightDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.MATCHING), "in MATCHING");

        bulls.performUpkeep(abi.encode(uint8(1)));

        assertTrue(
            uint256(bulls.drawPhase()) != uint256(IBullsEthCRE.DrawPhase.MATCHING),
            "the draw moved on"
        );
    }

    function test_PerformUpkeep_ActionTwoRefusesMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.performUpkeep(abi.encode(uint8(2)));
    }

    /// @notice A bare action-2 payload with no player list is a no-op rather than a revert.
    ///         Chainlink sends back exactly 32 bytes, so this is the ordinary case: the
    ///         signal arrives, the list is empty, and matching's own fallback handles
    ///         unpicked players later.
    function test_PerformUpkeep_ActionTwoWithNoPlayerListIsANoOp() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        bulls.performUpkeep(abi.encode(uint8(2)));
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.IDLE), "still idle, nothing broke");
    }

    function test_PerformUpkeep_ActionThreeRefusesMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.performUpkeep(abi.encode(uint8(3)));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Forwarder configuration
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Both forwarder setters reject the same four addresses, and each rejection is
    ///         a real hazard rather than defensive noise: pointing the forwarder at the
    ///         contract itself, the token, the beneficiary or the sequencer feed would each
    ///         give an unrelated address authority over keeper-only entry points.
    /// @dev SPLIT INTO TWO, one per setter, and each keeps its four checks in a helper so
    ///      the assertions stay adjacent to what they test. Eight vm.expectRevert pairs in a
    ///      single body is the shape that already bit this project once in DrawMachinery:
    ///      the cheatcode applies to the very next call and gets unreliable after a caught
    ///      revert, so later pairs can silently stop being enforced.
    function test_Forwarders_AutomationSetterRejectsTheDangerousAddresses() public {
        address usdcAddr = bulls.USDC();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setAutomationForwarder(address(bulls));

        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setAutomationForwarder(usdcAddr);
    }

    function test_Forwarders_AutomationSetterRejectsTheProtocolAddresses() public {
        address beneficiary = bulls.PROTOCOL_BENEFICIARY();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setAutomationForwarder(beneficiary);

        address sequencer = bulls.SEQUENCER_FEED();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setAutomationForwarder(sequencer);
    }

    function test_Forwarders_CreSetterRejectsTheDangerousAddresses() public {
        address usdcAddr = bulls.USDC();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(address(bulls));

        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(usdcAddr);
    }

    function test_Forwarders_CreSetterRejectsTheProtocolAddresses() public {
        address beneficiary = bulls.PROTOCOL_BENEFICIARY();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(beneficiary);

        address sequencer = bulls.SEQUENCER_FEED();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(sequencer);
    }

    /// @notice address(0) is ALLOWED on both, and deliberately so: it is the kill switch.
    ///         Zeroing a forwarder disables that delivery path in one transaction, which is
    ///         the incident response if a forwarder is ever compromised.
    function test_Forwarders_ZeroAddressIsPermittedAsAKillSwitch() public {
        address keeper = _newFundedPlayer(91010);
        bulls.setAutomationForwarder(keeper);
        assertEq(bulls.automationForwarder(), keeper, "forwarder set");

        bulls.setAutomationForwarder(address(0));
        assertEq(bulls.automationForwarder(), address(0), "and disabled again");

        bulls.setCreForwarder(keeper);
        assertEq(bulls.creForwarder(), keeper, "CRE forwarder set");
        bulls.setCreForwarder(address(0));
        assertEq(bulls.creForwarder(), address(0), "and disabled again");
    }

    /// @notice A configured automation forwarder gains the same keeper authority the owner
    ///         has. This is the point of the setter, and it is worth proving rather than
    ///         assuming, because it is the only thing that lets the game run unattended.
    function test_Forwarders_AConfiguredForwarderCanDriveTheGame() public {
        _bootstrapAndStart();
        address keeper = _newFundedPlayer(91011);
        bulls.setAutomationForwarder(keeper);

        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        // The forwarder can submit cutoffs, which is owner-or-keeper only.
        vm.prank(keeper);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.MATCHING), "keeper advanced it");

        // And drive the upkeep step. ASSERTED, because an unasserted final call is the
        // shape that passes on silence: if performUpkeep did nothing at all this test would
        // still have gone green while claiming a forwarder can drive the game.
        vm.prank(keeper);
        bulls.performUpkeep(abi.encode(uint8(1)));
        assertTrue(
            uint256(bulls.drawPhase()) != uint256(IBullsEthCRE.DrawPhase.MATCHING),
            "the forwarder's upkeep call actually moved the draw on"
        );
    }

    /// @notice The forwarder's authority covers the OTHER keeper entry points too, not just
    ///         the two already proven. Each of these carries the same three-way auth check,
    ///         and a forwarder that could submit cutoffs but not prune would leave the game
    ///         half-automatable.
    function test_Forwarders_AuthorityCoversPruneAndAutoPicks() public {
        _bootstrapAndStart();
        address keeper = _newFundedPlayer(91013);
        bulls.setAutomationForwarder(keeper);

        // Prune: nothing stale to remove, but the AUTH is what is under test, so reaching
        // the end without OwnableUnauthorizedAccount is the result.
        vm.prank(keeper);
        bulls.pruneStaleOGs(10);

        address[] memory list = new address[](1);
        list[0] = players[0];
        vm.prank(keeper);
        bulls.applyAutoPicksForDraw(list);
    }

    /// @notice The CRE forwarder carries the SAME authority as the automation one. It was
    ///         configured in the tests above but never exercised as a caller, so the two
    ///         setters were proven symmetrical in what they REJECT and not in what they
    ///         grant.
    function test_Forwarders_CreForwarderHasKeeperAuthorityToo() public {
        _bootstrapAndStart();
        address creKeeper = _newFundedPlayer(91014);
        bulls.setCreForwarder(creKeeper);

        vm.prank(creKeeper);
        bulls.pruneStaleOGs(10);

        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        vm.prank(creKeeper);
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.MATCHING),
            "the CRE forwarder drove the draw forward"
        );
    }

    function test_Forwarders_SettersAreOwnerOnly() public {
        address stranger = _newFundedPlayer(91012);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.setAutomationForwarder(stranger);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.setCreForwarder(stranger);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  pruneStaleOGs and applyAutoPicksForDraw
    // ══════════════════════════════════════════════════════════════════════

    function test_Prune_RevertsForAnUnauthorisedCaller() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(91020);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.pruneStaleOGs(10);
    }

    function test_Prune_RevertsMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.pruneStaleOGs(10);
    }

    function test_Prune_RevertsAboveTheBatchCap() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.pruneStaleOGs(MAX_LAPSE_BATCH + 1);
    }

    function test_AutoPicks_RevertsForAnUnauthorisedCaller() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(91021);
        address[] memory list = new address[](1);
        list[0] = players[0];

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.applyAutoPicksForDraw(list);
    }

    function test_AutoPicks_RevertsAboveTheBatchCap() public {
        _bootstrapAndStart();
        address[] memory oversized = new address[](501);
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.applyAutoPicksForDraw(oversized);
    }

    function test_AutoPicks_RevertsMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();

        address[] memory list = new address[](1);
        list[0] = players[0];
        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.applyAutoPicksForDraw(list);
    }

    /// @notice ACTION 3, the branch nothing reached. Stale OGs are weekly OGs who lost
    ///         status but are still sitting in ogList, where matching walks past them every
    ///         draw for nothing. Once enough pile up, checkUpkeep starts asking for a prune.
    ///
    /// @dev    Needs STALE_OG_PRUNE_THRESHOLD (50) of them, so the fixture registers 55
    ///         weekly OGs and then lets them all miss draw 2. Matching flips statusLost on
    ///         every one, and they stay in ogList until pruned. Weekly-first registration
    ///         order, for the cap reason recorded in the recalibration tests.
    function test_CheckUpkeep_ReportsPruneOnceStaleOgsAccumulate() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < 55; i++) {
            address wog = _newFundedPlayer(92000 + i);
            vm.prank(wog); bulls.register();
            vm.prank(wog); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000 + i, BASE_PREDICTION + 7500 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        // Draw 1: the weekly OGs are credited by registration, so only casuals buy.
        _runStandardDraw();

        // Draw 2: casuals buy, the weekly cohort does not. Matching strips all 55.
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        // 500 casuals + 55 weekly OGs x2 = 610 snapshot entries.
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 12, 48, 120);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }

        assertGe(bulls.countStaleOGs(), 50, "precondition: the threshold is genuinely crossed");

        (bool needed, bytes memory data) = bulls.checkUpkeep("");
        assertTrue(needed, "a prune is now due");
        assertEq(abi.decode(data, (uint8)), 3, "action 3: prune stale OGs");
    }

    /// @notice And the prune itself does the work: stale entries leave ogList, so matching
    ///         stops paying for them. Only ever shown refusing before this.
    function test_Prune_ActuallyRemovesStaleEntriesFromTheList() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < 55; i++) {
            address wog = _newFundedPlayer(92100 + i);
            vm.prank(wog); bulls.register();
            vm.prank(wog); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000 + i, BASE_PREDICTION + 7500 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        _runStandardDraw();
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 12, 48, 120);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }

        uint256 staleBefore = bulls.countStaleOGs();
        assertGe(staleBefore, 50, "precondition: there is real work to do");

        bulls.pruneStaleOGs(20);

        assertEq(
            bulls.countStaleOGs(),
            staleBefore - 20,
            "exactly the batch size was pruned, not more and not none"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  markLapsed and batchMarkLapsed
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Lapsing frees a player's slot against MAX_PLAYERS once they have stopped
    ///         playing, and it is reversible: buying again un-lapses them.
    function test_MarkLapsed_FlagsAPlayerWhoMissedTheCurrentDraw() public {
        _bootstrapAndStart();
        _runStandardDraw(); // everyone bought draw 1, currentDraw is now 2

        address idle = players[0];
        uint256 lapsedBefore = bulls.lapsedPlayerCount();

        bulls.markLapsed(idle);

        assertEq(bulls.lapsedPlayerCount(), lapsedBefore + 1, "counted as lapsed");
    }

    /// @notice LAPSING IS REVERSIBLE, and nothing tested that. A lapsed player who comes
    ///         back and buys is un-lapsed automatically inside buyTickets, which is what
    ///         makes lapsing safe to apply liberally: it frees a slot against MAX_PLAYERS
    ///         without shutting anyone out. If the reversal did not work, a keeper tidying
    ///         up would be permanently ejecting returning players.
    function test_MarkLapsed_IsReversedWhenThePlayerBuysAgain() public {
        _bootstrapAndStart();
        _runStandardDraw();

        address returner = players[0];
        bulls.markLapsed(returner);
        uint256 lapsedWhileAway = bulls.lapsedPlayerCount();
        assertGt(lapsedWhileAway, 0, "precondition: genuinely lapsed");

        // They come back and buy the current draw.
        vm.prank(returner);
        bulls.buyTickets(1);

        assertEq(
            bulls.lapsedPlayerCount(),
            lapsedWhileAway - 1,
            "buying again un-lapsed them, so the slot is theirs once more"
        );
    }

    function test_MarkLapsed_RevertsForNonOwner() public {
        _bootstrapAndStart();
        _runStandardDraw();
        address stranger = _newFundedPlayer(91030);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.markLapsed(players[0]);
    }

    /// @notice A player who has never bought cannot lapse. There is no slot to free, and
    ///         flagging them would corrupt the count.
    function test_MarkLapsed_RevertsForSomeoneWhoNeverBought() public {
        _bootstrapAndStart();
        address neverPlayed = _newFundedPlayer(91031);
        vm.prank(neverPlayed);
        bulls.register();

        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.markLapsed(neverPlayed);
    }

    /// @notice A player who bought THIS draw is active by definition, so lapsing them is
    ///         refused. This is the guard that stops a keeper freeing the slot of someone
    ///         who is currently playing.
    function test_MarkLapsed_RevertsForSomeoneWhoBoughtThisDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);

        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.markLapsed(players[0]);
    }

    function test_MarkLapsed_RevertsOnASecondCall() public {
        _bootstrapAndStart();
        _runStandardDraw();

        bulls.markLapsed(players[0]);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.markLapsed(players[0]);
    }

    /// @notice The batch variant SKIPS ineligible entries rather than reverting, so one bad
    ///         address in a list of five hundred does not throw away the whole call. That is
    ///         the right shape for a keeper batch and it is worth pinning, because the
    ///         single-address version does the opposite.
    function test_BatchMarkLapsed_SkipsIneligibleEntriesRatherThanReverting() public {
        _bootstrapAndStart();
        _runStandardDraw();

        address neverPlayed = _newFundedPlayer(91040);
        vm.prank(neverPlayed);
        bulls.register();

        address[] memory mixed = new address[](3);
        mixed[0] = players[0];   // eligible
        mixed[1] = neverPlayed;  // ineligible: never bought
        mixed[2] = players[1];   // eligible

        uint256 before = bulls.lapsedPlayerCount();
        bulls.batchMarkLapsed(mixed); // must NOT revert

        assertEq(
            bulls.lapsedPlayerCount(),
            before + 2,
            "the two eligible entries were lapsed and the ineligible one was skipped"
        );
    }

    function test_BatchMarkLapsed_RevertsAboveTheBatchCap() public {
        _bootstrapAndStart();
        _runStandardDraw();
        address[] memory oversized = new address[](MAX_LAPSE_BATCH + 1);
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.batchMarkLapsed(oversized);
    }

    function test_BatchMarkLapsed_RevertsForNonOwner() public {
        _bootstrapAndStart();
        _runStandardDraw();
        address stranger = _newFundedPlayer(91041);
        address[] memory list = new address[](1);
        list[0] = players[0];

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.batchMarkLapsed(list);
    }
}
