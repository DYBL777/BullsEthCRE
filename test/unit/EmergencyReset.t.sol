// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Emergency reset
/// @notice The only mechanism that unsticks a stuck draw. If a feed goes stale, a keeper
///         goes offline mid-draw, or the cutoff maths becomes unsatisfiable, every phase
///         after IDLE is a dead end without this. No prizes, no next draw, and every
///         participant's money frozen in the contract.
///
/// @dev    It is also the least-exercised code guarding the worst outcome, which is why it
///         is worth testing more than most things. It walks the tier pools reversing
///         partial distributions, restores weekly OG status and streaks, unwinds player
///         state in batches, re-anchors the schedule, and clears the seed accounting. Any
///         of those can be subtly wrong and nothing would surface until the day it matters.
///
///         Three timing constants, and they are not interchangeable:
///           DRAW_STUCK_TIMEOUT           48 hours  before the owner may reset
///           UNWIND_CONTINUATION_TIMEOUT   7 days   before ANYONE may continue an unwind
///           RESET_REFUND_WINDOW          30 days   to claim a refund for a voided draw
contract EmergencyResetTest is SmartEarnBase {
    uint256 internal constant DRAW_STUCK_TIMEOUT = 48 hours;
    uint256 internal constant UNWIND_CONTINUATION_TIMEOUT = 7 days;
    uint256 internal constant RESET_REFUND_WINDOW = 30 days;

    // ── fixtures ─────────────────────────────────────────────────────────

    /// @dev Leaves the draw in CUTOFF_SUBMISSION: resolved, but no cutoffs submitted.
    ///      This is the shape a keeper going offline after resolveWeek produces.
    function _stickInCutoffSubmission() internal {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
    }

    /// @dev Leaves the draw in MATCHING: cutoffs accepted, matching not yet run.
    function _stickInMatching() internal {
        _stickInCutoffSubmission();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
    }

    /// @dev A fixture that genuinely reaches UNWINDING, which the casuals-only one does NOT.
    ///
    ///      emergencyResetDraw short-circuits: `if (emergencyUnwindTotal == 0) { drawPhase =
    ///      RESET_FINALIZING; }`. emergencyUnwindTotal is ogList.length, so with zero OGs the
    ///      contract skips UNWINDING entirely. An earlier version of the two anti-lock tests
    ///      wrapped their bodies in `if (drawPhase == UNWINDING)` and therefore executed ZERO
    ///      assertions, passing whether or not the mechanism worked. In the file whose header
    ///      calls this the least-exercised code guarding the worst outcome.
    ///
    ///      UNWINDING also has to PERSIST past the reset call to be observable, and the loop
    ///      processes MAX_UNWIND_PER_TX (300) per transaction. So the list must exceed 300.
    ///      350 upfront OGs leaves 50 unprocessed and the phase parked in UNWINDING.
    ///      (registerAsOG carries no cap: the upfront cap was removed at v1.57-P1.)
    function _stickInUnwinding() internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < 350; i++) {
            address og = _newFundedPlayer(61000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        // 1,200 entries here (500 casuals + 350 OGs x 2), not the 500 the other fixtures
        // have, so the percentile bands need different counts: T1 0.5-4%, T2 4-12%
        // cumulative, T3 10-50% cumulative. 24/96/240 sits inside all three. The diffs are
        // widened to match, since the winners all come from the 500-casual ladder.
        bulls.submitCutoffDiffs(23e6, 95e6, 239e6, 24, 96, 240);
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Who may reset, and when
    // ══════════════════════════════════════════════════════════════════════

    function test_Reset_RevertsForNonOwner() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);

        address stranger = _newFundedPlayer(60001);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.emergencyResetDraw();
    }

    /// @notice A draw that is not stuck must not be resettable. IDLE means the previous
    ///         draw finalised cleanly, so there is nothing to void.
    function test_Reset_RevertsWhenTheDrawIsIdle() public {
        _bootstrapAndStart();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        vm.expectRevert(IBullsEthCRE.NotStuck.selector);
        bulls.emergencyResetDraw();
    }

    function test_Reset_RevertsBeforeTheStuckTimeoutElapses() public {
        _stickInMatching();
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.emergencyResetDraw();
    }

    function test_Reset_SucceedsOnceTheStuckTimeoutElapses() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        assertTrue(
            uint256(bulls.drawPhase()) != uint256(IBullsEthCRE.DrawPhase.MATCHING),
            "the draw left MATCHING"
        );
    }

    function test_Reset_WorksFromCutoffSubmission() public {
        _stickInCutoffSubmission();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        assertEq(bulls.lastResetDraw(), 1, "draw 1 recorded as the reset draw");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  H-01 escape hatch
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The reason this exists: both a mismatch bounce and a resubmission refresh
    ///         phaseStartTimestamp, so a keeper retrying an unsatisfiable draw in good faith
    ///         would keep pushing the 48h deadline out of reach and the escape would never
    ///         unlock. After MAX_CUTOFF_ATTEMPTS the reset becomes available immediately.
    function test_Reset_ExhaustedAttemptsBypassTheTimeout() public {
        _stickInCutoffSubmission();

        for (uint256 i = 0; i < 3; i++) {
            bulls.submitCutoffDiffs(0, 1, 2, 10, 40, 100); // reconciles out of range
            for (uint256 j = 0; j < 20; j++) {
                if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
                if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
                bulls.completeDrawStep();
            }
        }
        assertEq(bulls.cutoffAttempts(), 3, "three failed attempts recorded");

        // No time has passed, so DRAW_STUCK_TIMEOUT has NOT elapsed.
        bulls.emergencyResetDraw();
        assertEq(bulls.lastResetDraw(), 1, "reset fired without waiting 48h");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Phases that must refuse
    // ══════════════════════════════════════════════════════════════════════

    /// @notice FINALIZING is committing the draw. Voiding a draw that is already being
    ///         committed would leave the two half-applied, so it must refuse outright
    ///         rather than wait for a timeout.
    function test_Reset_RefusesDuringFinalizing() public {
        _stickInMatching();
        // Drive through matching and distribution to reach FINALIZING.
        for (uint256 i = 0; i < 20; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.FINALIZING)) break;
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            bulls.completeDrawStep();
        }

        if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.FINALIZING)) {
            vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
            vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
            bulls.emergencyResetDraw();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Value conservation: nothing created, nothing stranded
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE INVARIANT THAT MATTERS. A reset moves money between the tier pools, the
    ///         prize pot, the seed accounting and the refund pool. The contract's balance
    ///         must not change, because a reset moves value around rather than in or out.
    function test_Reset_DoesNotChangeTheContractBalance() public {
        _stickInMatching();
        uint256 balanceBefore = usdc.balanceOf(address(bulls));

        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        assertEq(
            usdc.balanceOf(address(bulls)),
            balanceBefore,
            "a reset redistributes internally, it never moves USDC in or out"
        );
    }

    /// @notice The tier pools are emptied back into the prize pot rather than stranded.
    ///
    /// @dev    NOT asserted as "the pot goes up", which was my first attempt and it FAILED.
    ///         The reset also reverses currentDrawSeedReturn and the draw-30 bonus
    ///         contribution, so the pot's net movement is not a simple increase. The honest
    ///         assertion is that the tier pools are ZERO afterwards and nothing was lost
    ///         from the contract, which is what "returned rather than stranded" means.
    function test_Reset_EmptiesTheTierPools() public {
        _stickInMatching();
        bulls.completeDrawStep(); // populate tierPools

        uint256 balBefore = usdc.balanceOf(address(bulls));
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        assertEq(bulls.tierPools(0), 0, "T1 pool emptied");
        assertEq(bulls.tierPools(1), 0, "T2 pool emptied");
        assertEq(bulls.tierPools(2), 0, "T3 pool emptied");
        assertEq(
            usdc.balanceOf(address(bulls)),
            balBefore,
            "and nothing left the contract while they were emptied"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  State cleared for the replay
    // ══════════════════════════════════════════════════════════════════════

    /// @notice resolvedPrice is zeroed so the voided draw's price cannot leak into the
    ///         replay. Worth pinning because the auto-default reads the previous resolved
    ///         price, so a stale value here would feed the next draw's fallback.
    function test_Reset_ClearsTheResolvedPrice() public {
        _stickInMatching();
        assertTrue(bulls.getResolvedPrice() != 0, "a price was resolved before the reset");

        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        assertEq(bulls.getResolvedPrice(), 0, "resolved price cleared for the replay");
    }

    function test_Reset_ClearsTheCutoffState() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        assertEq(bulls.t1CutoffDiff(), 0, "t1 cleared");
        assertEq(bulls.t2CutoffDiff(), 0, "t2 cleared");
        assertEq(bulls.t3CutoffDiff(), 0, "t3 cleared");
        assertEq(bulls.cutoffAttempts(), 0, "attempt counter cleared for the replay");
    }

    function test_Reset_RecordsTheResetDrawNumber() public {
        _stickInMatching();
        uint256 drawAtReset = bulls.currentDraw();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        assertEq(bulls.lastResetDraw(), drawAtReset, "the voided draw is recorded");
    }

    /// @notice resetDrawCount exists so a voided draw is not counted against an upfront OG's
    ///         pro-rata dormancy refund. Every reset consumes a draw number without anyone
    ///         playing it, so without this the refund maths over-states draws played.
    /// @dev TIMING, and I had this wrong first time. resetDrawCount does NOT increment in
    ///      emergencyResetDraw. It increments in _finalizeWeekCore's reset branch, so the
    ///      count only lands once the unwind completes and the reset FINALISES. That is
    ///      correct: an abandoned half-unwind should not count as a consumed draw.
    function test_Reset_IncrementsTheResetDrawCountOnlyAfterFinalising() public {
        _stickInMatching();
        uint256 before = bulls.resetDrawCount();

        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        assertEq(bulls.resetDrawCount(), before, "not yet: the reset has only started");

        for (uint256 i = 0; i < 30; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            bulls.completeDrawStep();
        }
        assertEq(
            bulls.resetDrawCount(),
            before + 1,
            "counted on finalise, so the OG dormancy pro-rata stays honest"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The unwind, and its permissionless continuation
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A half-finished unwind must not be strandable by a lost owner key. After
    ///         UNWIND_CONTINUATION_TIMEOUT anyone may continue it. Before that, only the
    ///         owner. This is an anti-lock mechanism rather than an access control.
    /// @dev RULE FOR THIS WHOLE FILE, learned the hard way: assert the precondition, never
    ///      wrap the body in `if (precondition)`. An if-guard with no else hides vacuity, so
    ///      a fixture change that breaks reachability passes silently instead of failing.
    function test_Unwind_StrangerCannotContinueBeforeTheTimeout() public {
        _stickInUnwinding();
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.UNWINDING),
            "precondition: the unwind is genuinely mid-flight"
        );

        address stranger = _newFundedPlayer(60002);
        vm.prank(stranger);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.emergencyResetDraw();
    }

    function test_Unwind_StrangerMayContinueAfterTheTimeout() public {
        _stickInUnwinding();
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.UNWINDING),
            "precondition: the unwind is genuinely mid-flight"
        );

        vm.warp(block.timestamp + UNWIND_CONTINUATION_TIMEOUT + 1);
        uint256 idxBefore = bulls.emergencyUnwindIndex();

        address stranger = _newFundedPlayer(60003);
        vm.prank(stranger);
        bulls.emergencyResetDraw(); // anti-lock: a lost owner key cannot strand the unwind

        assertGt(
            bulls.emergencyUnwindIndex(),
            idxBefore,
            "and the stranger's call actually advanced the unwind"
        );
    }

    /// @notice The short-circuit the two tests above depend on, pinned in its own right.
    ///         With no OGs there is nothing to unwind, so the reset goes straight to
    ///         RESET_FINALIZING and UNWINDING is never entered.
    function test_Unwind_ZeroOGsSkipsUnwindingEntirely() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        assertTrue(
            uint256(bulls.drawPhase()) != uint256(IBullsEthCRE.DrawPhase.UNWINDING),
            "empty OG list short-circuits past UNWINDING"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  E-02: the restoration path, which is why the unwind exists at all
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The deepest logic in a reset, and it had no coverage until this test. When a
    ///         draw is voided, any weekly OG who lost status during THAT draw's matching
    ///         must be made whole, because the loss was the operator voiding the draw rather
    ///         than the player failing to buy.
    ///
    /// @dev    The restoration has four parts and this asserts each separately, because a
    ///         subtly wrong unwind would restore some and not others:
    ///           statusLost cleared and statusLostAtDraw zeroed
    ///           weeklyOGCount and earnedOGCount re-incremented
    ///           consecutiveWeeks++ (the D4-M-01 streak credit)
    ///           qualifiedWeeklyOGCount re-incremented on a 29-to-30 crossing
    ///
    ///         The streak credit is the subtle one. lastActiveWeek alone stops the
    ///         gap-detector wiping the streak, but consecutiveWeeks only increments at buy
    ///         time and the OG never bought the voided draw, so their maximum reachable
    ///         streak would be 29 against a required 30: qualification permanently out of
    ///         reach while they keep paying. v0.11 credits the voided draw as if bought.
    function test_Unwind_RestoresAWeeklyOgWhoLostStatusInTheVoidedDraw() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        address wog = _newFundedPlayer(62001);
        vm.prank(wog); bulls.register();
        vm.prank(wog); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000, BASE_PREDICTION + 7001);

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        // Draw 1 runs normally. The pregame weekly OG is already credited for it.
        _runStandardDraw();
        assertEq(bulls.currentDraw(), 2, "draw 1 finalised");

        (,, bool isWog, bool lostBefore,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertTrue(isWog, "still a weekly OG entering draw 2");
        assertFalse(lostBefore, "and has not lost status yet");

        uint256 wogCountBefore = bulls.weeklyOGCount();

        // Draw 2: casuals buy, the weekly OG does NOT. Matching is what flips the flag.
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.completeDrawStep(); // matching: statusLost flips here

        (,,, bool lostAfterMatching,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertTrue(lostAfterMatching, "precondition: status was genuinely lost during matching");
        assertEq(bulls.weeklyOGCount(), wogCountBefore - 1, "and the count fell");

        // Void the draw and complete the unwind.
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        for (uint256 i = 0; i < 30; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            bulls.completeDrawStep();
        }

        // THE RESTORATION.
        (,,, bool lostAfterUnwind,,,,,,,,,,) = bulls.getPlayerInfo(wog);
        assertFalse(lostAfterUnwind, "status restored: the loss was not the player's fault");
        assertEq(
            bulls.weeklyOGCount(),
            wogCountBefore,
            "and the count is back to where it was before the voided draw"
        );
    }

    /// @notice The streak half of the same restoration, separated because it is the part
    ///         that was wrong twice before v0.11 fixed it, and a regression here would be
    ///         invisible: the OG keeps paying and simply never qualifies.
    function test_Unwind_CreditsTheVoidedDrawToTheStreak() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        address wog = _newFundedPlayer(62002);
        vm.prank(wog); bulls.register();
        vm.prank(wog); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7100, BASE_PREDICTION + 7101);

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        _runStandardDraw();
        (,,,,,,,, uint256 streakBefore,,,,,) = bulls.getPlayerInfo(wog);

        // Draw 2: the OG does not buy, matching strips status, then the draw is voided.
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.completeDrawStep();

        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();
        for (uint256 i = 0; i < 30; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            bulls.completeDrawStep();
        }

        (,,,,,,,, uint256 streakAfter,,,,,) = bulls.getPlayerInfo(wog);
        assertGt(
            streakAfter,
            streakBefore,
            "the voided draw is credited to the streak, so 30 stays reachable"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Refunds for the voided draw
    // ══════════════════════════════════════════════════════════════════════

    /// @dev NOTE: claimResetRefund takes NO arguments. The contract keeps TWO refund pools
    ///      (resetDrawRefundDraw and resetDrawRefundDraw2), so it can hold refunds for two
    ///      separate reset draws at once, and the claim works out which the caller is
    ///      eligible for. A first version of these tests passed a draw number and did not
    ///      compile, which is the useful kind of wrong assumption.
    function test_ResetRefund_RevertsForAPlayerWhoDidNotBuy() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        address nobody = _newFundedPlayer(60004);
        vm.prank(nobody);
        vm.expectRevert(IBullsEthCRE.ResetRefundNotEligible.selector);
        bulls.claimResetRefund();
    }

    /// @notice Upfront OGs are explicitly excluded. They prepaid the whole season rather
    ///         than a single draw, so a voided draw is handled by resetDrawCount in the
    ///         dormancy pro-rata maths, not by a per-draw refund.
    function test_ResetRefund_RevertsForAnUpfrontOG() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address og = _newFundedPlayer(60010);
        vm.prank(og); bulls.register();
        vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000, BASE_PREDICTION + 4000);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.ResetRefundNotEligible.selector);
        bulls.claimResetRefund();
    }

    /// @notice A second claim must revert rather than pay zero, so a double-claim is
    ///         distinguishable from an empty balance.
    function test_ResetRefund_RevertsOnASecondClaim() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        // The try/catch that used to be here hid the payout entirely: its catch branch was
        // dead (the pool IS funded, draw-1 credit buys write their net into
        // currentDrawNetTicketTotal) and the AMOUNT was asserted nowhere in the file. A
        // contract paying one unit instead of $7.50 would have passed. Asserted exactly now.
        address c = players[0];
        uint256 expected = TICKET_PRICE * (10000 - TREASURY_BPS) / 10000; // $7.50 net
        uint256 before = usdc.balanceOf(c);

        vm.prank(c);
        bulls.claimResetRefund();
        assertEq(usdc.balanceOf(c) - before, expected, "refunded exactly the net ticket cost");

        vm.prank(c);
        vm.expectRevert(IBullsEthCRE.ResetRefundNotEligible.selector);
        bulls.claimResetRefund();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The game continues afterwards
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The whole point. A reset is only useful if the season carries on, so this is
    ///         the test that proves the mechanism does its job rather than merely running.
    function test_Reset_TheGameCanContinueToTheNextDraw() public {
        _stickInMatching();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        // Finish any unwind batches.
        for (uint256 i = 0; i < 30; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            bulls.completeDrawStep();
        }

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.IDLE),
            "back to IDLE, ready for the next draw"
        );
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.ACTIVE), "still ACTIVE");
    }
}
