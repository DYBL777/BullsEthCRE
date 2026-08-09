// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

/// @title  Prize distribution mechanics
/// @notice What a winner actually RECEIVES. DrawMachinery proves how MANY winners each tier
///         has and that value is conserved across a cycle. Between those two facts sat the
///         entire payout calculation, untested.
///
/// @dev    This is the last area where a bug means someone is paid the wrong amount rather
///         than a call reverting, which is why it led the backlog.
///
///         The standard fixture gives 500 single-ticket casuals predicting on a
///         BASE_PREDICTION + i ladder, so entry i has diff exactly i * 1e6 from the settled
///         price. Cutoffs 9e6 / 39e6 / 99e6 with counts 10 / 40 / 100 therefore produce
///         tiers of 10 / 30 / 60, and every boundary is landed on exactly rather than
///         approached. That precision is what makes the tie test below possible.
///
///         Pool split, from _calculatePrizePools:
///           distributable = weeklyPool * 87%   (10% seed rollover, 3% draw-30 bonus)
///           T1 = 40.00% of distributable
///           T2 = 35.56% of distributable
///           T3 = the remainder, ~24.44%
contract DistributionTest is SmartEarnBase {
    using stdStorage for StdStorage;

    /// @dev Drives a draw to DISTRIBUTING and stops, so a test can inspect or step the
    ///      distribution itself rather than having a helper run past it.
    function _reachDistributing(
        uint256 d1, uint256 d2, uint256 d3,
        uint256 c1, uint256 c2, uint256 c3
    ) internal {
        _buyAllPlayers(1);
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(d1, d2, d3, c1, c2, c3);
        bulls.processMatches(); // MATCHING -> DISTRIBUTING (500 entries, one pass at cap 500)
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.DISTRIBUTING),
            "fixture precondition: sitting in DISTRIBUTING"
        );
    }

    function _unclaimed(address who) internal view returns (uint256) {
        (,,,,,,,,, uint256 unclaimed,,,,) = bulls.getPlayerInfo(who);
        return unclaimed;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  What each tier pays
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE HEADLINE STRUCTURE, and nothing asserted it. T1 must pay more per winner
    ///         than T2, which must pay more than T3. Transpose the tier indices anywhere in
    ///         _getWinnersForTier or the tierPools assignment and no other test in the suite
    ///         fails: winner COUNTS stay correct, value is still conserved, and the draw
    ///         still finalises. Only the amounts change, and only this test looks at them.
    ///
    /// @dev    Uses the ladder to pick one known member of each tier: entry 0 is deep inside
    ///         T1, entry 20 sits between the T1 and T2 cutoffs, entry 50 between T2 and T3.
    function test_Tiers_PayInDescendingOrderPerWinner() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.distributePrizes();

        uint256 t1Each = _unclaimed(players[0]);
        uint256 t2Each = _unclaimed(players[20]);
        uint256 t3Each = _unclaimed(players[50]);

        assertGt(t1Each, 0, "T1 winner was actually paid");
        assertGt(t1Each, t2Each, "T1 pays more per winner than T2");
        assertGt(t2Each, t3Each, "T2 pays more per winner than T3");
        assertGt(t3Each, 0, "and T3 is not zero");

        // A losing entry gets nothing. Without this the ordering above would still hold if
        // everyone were paid the same non-zero amount by a broken split.
        assertEq(_unclaimed(players[150]), 0, "an entry outside t3CutoffDiff is paid nothing");
    }

    /// @notice Each winner in a tier receives exactly pool / count, and every winner in the
    ///         same tier receives the identical amount. Pinned on two members of each tier.
    function test_Tiers_EveryWinnerInATierGetsTheSameAmount() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.distributePrizes();

        assertEq(_unclaimed(players[0]), _unclaimed(players[5]), "T1 members paid equally");
        assertEq(_unclaimed(players[15]), _unclaimed(players[35]), "T2 members paid equally");
        assertEq(_unclaimed(players[45]), _unclaimed(players[95]), "T3 members paid equally");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Dust
    // ══════════════════════════════════════════════════════════════════════

    /// @notice DUST IS REAL MONEY AND MUST NOT VANISH. A tier pool rarely divides evenly by
    ///         its winner count, and the remainder is returned to prizePot rather than left
    ///         stranded in tierPools. Asserted as exact conservation: everything that was in
    ///         the three tier pools plus the seed rollover must end up either credited to
    ///         winners or back in the pot, to the wei.
    ///
    /// @dev    An earlier shape of this test asserted only that prizePot rose. That passes
    ///         if dust is returned AND if some larger amount is wrongly returned, so it
    ///         proves the direction and not the quantity. The equality below is the claim
    ///         worth making.
    function test_Dust_EveryUnitIsEitherPaidOrReturnedToThePot() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);

        uint256 poolsBefore = bulls.tierPools(0) + bulls.tierPools(1) + bulls.tierPools(2);
        uint256 seedBefore  = bulls.currentDrawSeedReturn();
        uint256 potBefore   = bulls.prizePot();
        uint256 owedBefore  = bulls.totalUnclaimedPrizes();

        bulls.distributePrizes();

        assertEq(
            bulls.prizePot() + bulls.totalUnclaimedPrizes(),
            potBefore + owedBefore + poolsBefore + seedBefore,
            "tier pools plus the seed rollover land entirely in payouts or the pot"
        );
    }

    /// @notice And the tier pools are emptied rather than left holding the remainder.
    ///         Together with the conservation test above this pins both halves: nothing is
    ///         lost, and nothing is stranded.
    function test_Dust_TierPoolsAreEmptyOnceDistributionCompletes() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.distributePrizes();

        assertEq(bulls.tierPools(0), 0, "T1 pool emptied");
        assertEq(bulls.tierPools(1), 0, "T2 pool emptied");
        assertEq(bulls.tierPools(2), 0, "T3 pool emptied");
        assertEq(bulls.currentDrawSeedReturn(), 0, "and the seed rollover was consumed");
    }

    /// @notice The seed rollover returns to prizePot only AFTER all three tiers are done,
    ///         at the same moment the phase advances. Pinned because it sits inside the
    ///         `distTierIndex >= 3` block and would be easy to move somewhere that pays it
    ///         out mid-distribution.
    function test_Seed_RollsBackIntoThePotAtTheEndOfDistribution() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);

        uint256 seedOwed = bulls.currentDrawSeedReturn();
        assertGt(seedOwed, 0, "precondition: there is a rollover to return");

        bulls.distributePrizes();

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.FINALIZING),
            "distribution finished and the phase advanced"
        );
        assertEq(bulls.currentDrawSeedReturn(), 0, "rollover consumed at that same moment");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Batched resumption
    // ══════════════════════════════════════════════════════════════════════

    /// @notice MAX_DISTRIBUTE_PER_TX IS 200 AND THE STANDARD DRAW NEVER REACHES IT. The usual
    ///         fixture produces 100 winners, so every existing test completes distribution in
    ///         a single call and the resumption logic has never run. Untested resumption is
    ///         how half a tier gets paid twice, or not at all.
    ///
    /// @dev    Widening t3 to 250 cumulative gives tiers of 10 / 30 / 210, so 250 winners
    ///         across two calls. Bounds check: on a 500-entry snapshot that reads
    ///         200 / 800 / 5000 bps, inside T1 [50,400], T2 [400,1200] and T3 [1000,5000] --
    ///         the T3 ceiling is landed on exactly, which is legal (the check is a strict
    ///         `>` on the max).
    function test_Batching_CreditsExactlyTheCapOnTheFirstCall() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 249e6, 10, 40, 250);

        (uint256 t1, uint256 t2, uint256 t3) = bulls.getWinnerCounts();
        assertEq(t1 + t2 + t3, 250, "precondition: 250 winners, past the 200 cap");

        bulls.distributePrizes();

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.DISTRIBUTING),
            "still distributing: the cap was hit, not the end"
        );
        assertEq(bulls.distTierIndex(), 2, "parked inside T3");
        assertEq(bulls.distWinnerIndex(), 160, "160 of T3's 210 done (10 + 30 + 160 = 200)");
    }

    /// @notice And the second call finishes the job without paying anyone twice. The exact
    ///         claim: total credited equals the sum of the three pools, which is only true
    ///         if each winner was credited exactly once across the two calls.
    function test_Batching_ResumesAndPaysEachWinnerExactlyOnce() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 249e6, 10, 40, 250);

        uint256 poolsBefore = bulls.tierPools(0) + bulls.tierPools(1) + bulls.tierPools(2);
        uint256 seedBefore  = bulls.currentDrawSeedReturn();
        uint256 potBefore   = bulls.prizePot();
        uint256 owedBefore  = bulls.totalUnclaimedPrizes();

        bulls.distributePrizes();
        bulls.distributePrizes();

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.FINALIZING),
            "two calls completed the distribution"
        );
        assertEq(
            bulls.prizePot() + bulls.totalUnclaimedPrizes(),
            potBefore + owedBefore + poolsBefore + seedBefore,
            "nothing paid twice and nothing dropped across the batch boundary"
        );
    }

    /// @notice A winner sitting either side of the batch boundary is paid the SAME amount as
    ///         their tier-mates. The per-winner figure is recomputed from `pool` on the
    ///         second call, and `pool` has not been zeroed yet, so this holds -- but it is
    ///         exactly the kind of thing a refactor breaks silently.
    function test_Batching_TheBoundaryDoesNotChangeWhatAWinnerReceives() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 249e6, 10, 40, 250);

        bulls.distributePrizes();
        // T3 spans entries 40..249. Index 160 within T3 is entry 200, the first one paid on
        // the second call; entry 100 was paid on the first.
        uint256 beforeBoundary = _unclaimed(players[100]);
        assertGt(beforeBoundary, 0, "paid in the first batch");
        assertEq(_unclaimed(players[200]), 0, "and not yet paid in the second");

        bulls.distributePrizes();

        assertEq(
            _unclaimed(players[200]),
            beforeBoundary,
            "the same tier pays the same amount either side of the batch boundary"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Boundary ties
    // ══════════════════════════════════════════════════════════════════════

    /// @notice TIES AT A CUTOFF ARE INCLUSIVE. The contract states it plainly ("ties at
    ///         boundary: all entries at exactly boundary diff included") and nothing tested
    ///         it. `diff <= t1CutoffDiff` means an entry landing EXACTLY on the cutoff wins
    ///         the higher tier, not the lower one.
    ///
    /// @dev    The ladder makes this exact rather than approximate: entry 9 has diff exactly
    ///         9e6, which is t1CutoffDiff, and entry 10 has 10e6, which is one unit past it.
    ///         So the pair straddles the boundary with nothing in between.
    ///
    ///         This also matters beyond payout size: it is the mechanism by which a cluster
    ///         of identical predictions can push actual counts past T1_COUNT_MAX_BPS and
    ///         bounce a draw, which is the H-01 family.
    function test_Ties_AnEntryExactlyOnTheCutoffWinsTheHigherTier() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.distributePrizes();

        uint256 onTheLine = _unclaimed(players[9]);   // diff == t1CutoffDiff exactly
        uint256 justPast  = _unclaimed(players[10]);  // diff == t1CutoffDiff + 1e6
        uint256 deepT1    = _unclaimed(players[0]);

        assertEq(onTheLine, deepT1, "the entry ON the cutoff is paid as T1");
        assertLt(justPast, onTheLine, "the next entry out is paid as T2, strictly less");
    }

    /// @notice Same rule at the T2/T3 boundary, so the behaviour is pinned as a rule rather
    ///         than as a one-off property of the first cutoff.
    function test_Ties_TheRuleHoldsAtEveryCutoff() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);
        bulls.distributePrizes();

        assertEq(_unclaimed(players[39]), _unclaimed(players[20]), "entry 39 is on t2 and paid as T2");
        assertLt(_unclaimed(players[40]), _unclaimed(players[39]), "entry 40 drops to T3");
        assertEq(_unclaimed(players[99]), _unclaimed(players[50]), "entry 99 is on t3 and paid as T3");
        assertEq(_unclaimed(players[100]), 0, "entry 100 is one past t3 and wins nothing");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The zero-per-winner safety valve
    // ══════════════════════════════════════════════════════════════════════

    /// @notice `perWinner == 0` returns the WHOLE pool to prizePot and emits TierSkippedDust.
    ///         It fires when a tier pool is smaller than its winner count, so nobody can be
    ///         paid a whole unit. Unreachable organically at these pool sizes, so the pool is
    ///         injected directly.
    ///
    /// @dev    STATE INJECTION, disclosed. tierPools[2] is overwritten with a value below the
    ///         T3 winner count. The injection only makes a gate FIRE that could not otherwise
    ///         be reached; it does not loosen anything. Everything else in the draw is
    ///         untouched, and the assertion is that the injected amount lands back in the pot
    ///         rather than being silently lost.
    function test_ZeroPerWinner_ReturnsTheWholePoolRatherThanPayingNothing() public {
        _bootstrapAndStart();
        _reachDistributing(9e6, 39e6, 99e6, 10, 40, 100);

        (,, uint256 t3Count) = bulls.getWinnerCounts();
        assertEq(t3Count, 60, "precondition: 60 winners in T3");

        // Below the winner count, so pool / winners floors to zero.
        uint256 crumbs = 59;
        stdstore.target(address(bulls)).sig("tierPools(uint256)").with_key(uint256(2))
            .checked_write(crumbs);

        uint256 potBefore = bulls.prizePot();
        bulls.distributePrizes();

        assertEq(_unclaimed(players[50]), 0, "no T3 winner was paid, because nobody could be");
        assertEq(bulls.tierPools(2), 0, "the pool was cleared");
        assertGe(
            bulls.prizePot(),
            potBefore + crumbs,
            "and the whole pool went back to prizePot rather than vanishing"
        );
    }
}
