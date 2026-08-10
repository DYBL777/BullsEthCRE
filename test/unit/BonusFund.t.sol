// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  The draw-30 bonus fund
/// @notice 3% of every draw's weekly pool is siphoned away from that draw's winners and
///         held back, so draw 30 is the largest prize event of the season by construction
///         rather than by luck.
///
/// @dev    Written BEFORE invariant fuzzing, deliberately. `draw30BonusFund` sits inside
///         the balance invariant the fuzz will assert (it is in the SYNC list in
///         _computeBalanceAndAllocated), and the handler will drive seasons straight
///         through draw 30. Fuzzing against accounting nothing has verified makes a
///         failure ambiguous: you cannot tell whether the sequence broke the contract or
///         the invariant was mis-stated.
///
///         Four movements, and every one of them touches money:
///           accumulate   3% of weeklyPool, every non-reset draw 1-29
///           consume      added to draw 30's pool, fund zeroed
///           return       back to prizePot if dormancy arrives before draw 30
///           roll back    reversed if the draw it came from is voided
contract BonusFundTest is SmartEarnBase {
    // Declared locally because the base does NOT carry it. Third landing of the
    // base-collision class, and the second in the assumed-present direction. The rule is
    // recorded in three files already and is per-constant, not per-lesson: check each one
    // against the base before declaring OR before assuming it is inherited.
    uint256 internal constant DRAW_STUCK_TIMEOUT = 48 hours;

    /// @dev Drives a draw as far as resolveWeek and stops. _calculatePrizePools runs inside
    ///      resolveWeek, so this is the moment the bonus has been siphoned and is readable.
    function _resolveOnly() internal {
        _buyAllPlayers(1);
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
    }

    /// @dev Finishes a draw that _resolveOnly has already resolved.
    function _finishDraw() internal {
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Accumulation
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The fund grows by exactly this draw's recorded contribution. Asserted as an
    ///         equality against `currentDrawBonusContribution` rather than against a
    ///         recomputed 3% figure, because the two are the same number written to two
    ///         places and the risk worth pinning is them diverging.
    function test_Bonus_FundGrowsByExactlyThisDrawsContribution() public {
        _bootstrapAndStart();

        uint256 fundBefore = bulls.draw30BonusFund();
        _resolveOnly();
        uint256 contribution = bulls.currentDrawBonusContribution();

        assertGt(contribution, 0, "a real contribution was siphoned");
        assertEq(
            bulls.draw30BonusFund(),
            fundBefore + contribution,
            "the fund rose by exactly the recorded contribution, no more and no less"
        );
    }

    /// @notice The 3% siphon and the 10% seed rollover come off the SAME weekly pool, so
    ///         their ratio is fixed at DRAW30_BONUS_BPS : SEED_BPS regardless of pool size.
    ///         Cross-multiplied to avoid asserting on a division that has already floored.
    ///
    /// @dev    This is what actually pins the RATE. The test above proves the fund and the
    ///         contribution agree with each other, which would still hold if both were
    ///         computed at the wrong percentage.
    function test_Bonus_IsSiphonedAtTheStatedRateRelativeToTheSeed() public {
        _bootstrapAndStart();
        _resolveOnly();

        uint256 bonus = bulls.currentDrawBonusContribution();
        uint256 seed  = bulls.currentDrawSeedReturn();
        assertGt(seed, 0, "precondition: a seed rollover exists to compare against");

        // bonus / seed must equal 300 / 1000. Allow one unit of slack in each direction:
        // both figures are floored divisions of the same pool, so they can disagree by at
        // most one unit of the smaller term.
        assertApproxEqAbs(
            bonus * bulls.SEED_BPS(),
            seed * bulls.DRAW30_BONUS_BPS(),
            bulls.SEED_BPS(),
            "bonus and seed are the stated fractions of one shared weekly pool"
        );
    }

    /// @notice It accumulates across draws rather than being replaced each time. Three draws,
    ///         strictly increasing, and the last increment matched to its own contribution so
    ///         a fund that merely grew for some other reason would not satisfy this.
    function test_Bonus_AccumulatesAcrossSuccessiveDraws() public {
        _bootstrapAndStart();

        _resolveOnly(); _finishDraw();
        uint256 afterOne = bulls.draw30BonusFund();

        _resolveOnly(); _finishDraw();
        uint256 afterTwo = bulls.draw30BonusFund();

        _resolveOnly();
        uint256 thirdContribution = bulls.currentDrawBonusContribution();
        uint256 afterThree = bulls.draw30BonusFund();

        assertGt(afterTwo, afterOne, "draw 2 added to draw 1's fund");
        assertEq(afterThree, afterTwo + thirdContribution, "and draw 3 added exactly its own");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Reset rollback
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A VOIDED DRAW MUST NOT LEAVE ITS CONTRIBUTION BEHIND. If it did, replaying the
    ///         draw would siphon a second time and the fund would double-count. The rollback
    ///         removes it from the fund and returns it to prizePot.
    ///
    /// @dev    The draw is driven to MATCHING and left stuck, then reset after the timeout.
    ///         The contribution is read before the reset because emergencyResetDraw clears it.
    function test_Bonus_AVoidedDrawsContributionIsRolledBack() public {
        _bootstrapAndStart();
        _resolveOnly();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100); // -> MATCHING, then stall

        uint256 contribution = bulls.currentDrawBonusContribution();
        uint256 fundBefore   = bulls.draw30BonusFund();
        assertGt(contribution, 0, "precondition: this draw did contribute");

        // Everything that will flow back INTO the pot at reset. The first version of this
        // test asserted `prizePot >= potBefore + contribution` and failed, because a reset
        // moves money in BOTH directions: tier pools, the seed rollover and this
        // contribution return to the pot, while the voided draw's ticket money and (at draw
        // 1) the entire commitment pool are carved OUT into refund pools. On this fixture
        // the carve-outs dwarf the returned contribution, so the pot legitimately ends up
        // LOWER. The rollback was working; the assertion was measuring the wrong thing.
        uint256 inflowsBefore = bulls.prizePot()
            + bulls.tierPools(0) + bulls.tierPools(1) + bulls.tierPools(2)
            + bulls.currentDrawSeedReturn();

        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);
        bulls.emergencyResetDraw();

        assertEq(
            bulls.draw30BonusFund(),
            fundBefore - contribution,
            "the voided draw's contribution left the fund"
        );
        // Exact equality across every destination, rather than a floor on one of them.
        // Fails if anything vanishes AND if anything is double-counted, which the original
        // one-sided assert could not do.
        assertEq(
            bulls.prizePot() + bulls.commitmentRefundPool() + bulls.resetDrawRefundPool(),
            inflowsBefore + contribution,
            "every unit accounted for: pot inflows plus the refund carve-outs balance exactly"
        );
        assertEq(bulls.currentDrawBonusContribution(), 0, "and the marker was cleared");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Dormancy return
    // ══════════════════════════════════════════════════════════════════════

    /// @notice IF DRAW 30 NEVER ARRIVES THE FUND MUST NOT BE STRANDED. It was siphoned out of
    ///         prize pools that players funded, and it is not in prizePot, so a dormancy that
    ///         did not return it would quietly hand it to the beneficiary at the sweep.
    ///         Returned before the waterfall runs, so it is available to every tier.
    function test_Bonus_ReturnsToThePotWhenDormancyArrivesFirst() public {
        _bootstrapAndStart();
        _resolveOnly(); _finishDraw();
        _resolveOnly(); _finishDraw();

        uint256 fund = bulls.draw30BonusFund();
        assertGt(fund, 0, "precondition: two draws have built a fund");

        bulls.proposeDormancy();
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);

        vm.expectEmit(false, false, false, true, address(bulls));
        emit IBullsEthCRE.Draw30BonusReturned(fund);
        bulls.activateDormancy();

        assertEq(bulls.draw30BonusFund(), 0, "the fund was emptied into the waterfall");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Consumption at draw 30
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE WHOLE POINT: at draw 30 the accumulated fund is added to that draw's pool
    ///         and zeroed. Twenty-nine draws of siphoning arrive at once, which is what makes
    ///         the finale the season's largest prize event.
    ///
    /// @dev    The most expensive test in this file by a wide margin. It also pins the
    ///         defensive zero: `currentDrawBonusContribution` must be 0 at draw 30, so an
    ///         emergency reset during the finale cannot deduct from an already-emptied fund.
    function test_Bonus_IsConsumedIntoTheFinalDraw() public {
        _bootstrapAndStart();

        for (uint256 d = 1; d <= 29; d++) {
            _resolveOnly();
            _finishDraw();
        }
        assertEq(bulls.currentDraw(), 30, "at the final draw");

        uint256 fundCarried = bulls.draw30BonusFund();
        assertGt(fundCarried, 0, "29 draws of siphoning are waiting");

        _resolveOnly(); // draw 30 runs the surplus path

        assertEq(bulls.draw30BonusFund(), 0, "the fund was consumed into draw 30's pool");
        assertEq(
            bulls.currentDrawBonusContribution(),
            0,
            "and draw 30 siphons nothing itself, so a reset here cannot double-deduct"
        );
        assertEq(bulls.currentDrawSeedReturn(), 0, "draw 30 takes no seed rollover either");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The view
    // ══════════════════════════════════════════════════════════════════════

    /// @notice `getDraw30BonusStatus` reports the live fund and an estimate of the next
    ///         draw's contribution. Frontend-facing, so a wrong figure misleads without
    ///         anything reverting.
    function test_View_ReportsTheAccumulatedFundAndAPerDrawEstimate() public {
        _bootstrapAndStart();
        _resolveOnly(); _finishDraw();

        (uint256 accumulated, uint256 perDrawEstimate) = bulls.getDraw30BonusStatus();

        assertEq(accumulated, bulls.draw30BonusFund(), "reports the live fund exactly");
        assertGt(perDrawEstimate, 0, "and a non-zero estimate for the next draw");
    }
}
