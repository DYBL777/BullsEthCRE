// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {BullsEthHandler} from "./BullsEthHandler.sol";

/// @title  Invariants, live season
/// @notice The properties that must hold after EVERY call, in every order the fuzzer can
///         reach. Not scenarios with predicted answers: statements about what can never be
///         false, checked against thousands of sequences nobody wrote.
///
/// @dev    This is the last testing item and it goes last for a reason. The handler beside
///         this file has to drive calls in legal orders, and knowing what "legal" means in
///         a nine-phase state machine is precisely what the 423 unit tests produced. Written
///         first, it would have been guesswork.
///
///         WHAT THIS FINDS THAT UNITS CANNOT: orderings. A unit test asks "does this
///         function work". An invariant asks "is there ANY sequence of legal calls that
///         breaks this". The bugs that survive a good unit suite are almost always the
///         second kind, because nobody thinks to write the sequence that breaks them.
///
///         PRECONDITIONS, and the reason the last few suites were written when they were.
///         An invariant asserting a check never trips is worth nothing unless something has
///         seen that check trip: SolvencyCheckFailed was pinned firing in SeedAndSolvency
///         for exactly this. The bonus fund was verified because it sits inside the balance
///         sum below. The reset conservation was pinned because these pools appear here.
///         Each of those was written to make an assertion here mean something.
contract InvariantsTest is SmartEarnBase {
    BullsEthHandler internal handler;

    function setUp() public override {
        super.setUp();
        _bootstrapAndStart();

        handler = new BullsEthHandler(bulls, usdc, ethFeed, players);

        // THE HANDLER MUST BE A KEEPER, and this line is why the first campaign completed
        // zero draws. submitCutoffDiffs is owner-or-forwarder only -- KeeperAutomation
        // proves exactly that in test_Cutoffs_RevertsForAStranger. The handler is a separate
        // contract and therefore a stranger, so every submission reverted into its own
        // silent catch and the campaign parked in CUTOFF_SUBMISSION forever. resolveWeek is
        // permissionless, which is precisely why it got that far and died there.
        //
        // Appointing it as the automation forwarder is the honest fix: it is what an
        // operator does on mainnet, and it is the role the contract already models.
        bulls.setAutomationForwarder(address(handler));

        // The handler pranks as players, so it needs no allowance of its own. It DOES need
        // to be the only target: pointing the fuzzer at the game directly would generate
        // calls that bounce off phase guards and prove nothing.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.predict.selector;
        selectors[2] = handler.resolve.selector;
        selectors[3] = handler.submitCutoffs.selector;
        selectors[4] = handler.step.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The headline property
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE CONTRACT ALWAYS HOLDS WHAT IT HAS PROMISED. Every pool it tracks, summed,
    ///         must be covered by the USDC it actually has. If this ever fails, somebody's
    ///         claim is unbacked.
    ///
    /// @dev    The pool list mirrors _computeBalanceAndAllocated exactly, including
    ///         draw30BonusFund, which is why that fund's accounting was verified before this
    ///         file existed. SOLVENCY_TOLERANCE absorbs USDC rounding dust, the same
    ///         allowance the contract's own check uses.
    ///
    ///         The contract enforces this live, at _captureYieldAndCheck, and reverts
    ///         SolvencyCheckFailed if it breaks. That check has been seen to fire. So this
    ///         invariant is the other half of the pair: proven capable of failing, then
    ///         proven never to.
    function invariant_BalanceCoversEveryAllocatedPool() public view {
        uint256 tiers = bulls.tierPools(0) + bulls.tierPools(1) + bulls.tierPools(2);

        uint256 allocated = bulls.prizePot()
            + bulls.treasuryBalance()
            + bulls.totalUnclaimedPrizes()
            + bulls.endgameOwed()
            + tiers
            + bulls.currentDrawSeedReturn()
            + bulls.draw30BonusFund()
            + bulls.dormancyOGPool()
            + bulls.dormancyCasualRefundPool()
            + bulls.dormancyCommitmentPool()
            + bulls.dormancyPerHeadPool()
            + bulls.dormancyVCPool()
            + bulls.vcReturnOwed()
            + bulls.resetDrawRefundPool()
            + bulls.resetDrawRefundPool2()
            + bulls.commitmentRefundPool()
            + bulls.totalForceDeclineRefundOwed();

        assertGe(
            usdc.balanceOf(address(bulls)) + bulls.SOLVENCY_TOLERANCE(),
            allocated,
            "the contract holds less than it owes"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The investor's bounds
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A game cannot spend more seed than it was given. The upper bound on the whole
    ///         SmartEarn layer, and the thing the VC's return is computed against.
    function invariant_SeedReleasedNeverExceedsTheSeed() public view {
        assertLe(bulls.seedReleased(), bulls.VC_SEED(), "spent more seed than exists");
    }

    /// @notice AND THE RATIO CEILING, which is the bound the constructor's own solvency proof
    ///         rests on. The VC is owed spent seed plus a return; the constructor only
    ///         guarantees treasury can fund that IF release stays inside this ratio.
    ///
    /// @dev    This is exactly the invariant that was FALSIFIED at v1.09 and stayed broken
    ///         for four versions: the T3 cold-start floor released seed without the ratio
    ///         clamp the supplement path obeyed, so the obligation could outrun the treasury
    ///         funding it. Fixed at v1.13 (H-02). Asserting it here across random sequences
    ///         is what stops it drifting a third time.
    function invariant_SeedReleaseStaysInsideTheRatioCeiling() public view {
        uint256 ceiling = bulls.cumulativeSeasonTreasury()
            * bulls.MAX_SEED_RELEASE_RATIO_BPS() / 10000;
        assertLe(
            bulls.seedReleased(),
            ceiling,
            "seed released beyond what the earned treasury can fund"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Counter coupling
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A qualified weekly OG is a subset of the active ones. The two counters move
    ///         in different places (qualification at a buy, status loss during matching), so
    ///         a missed decrement would let the endgame owe more heads than exist.
    function invariant_QualifiedIsASubsetOfActive() public view {
        assertLe(
            bulls.qualifiedWeeklyOGCount(),
            bulls.weeklyOGCount(),
            "more qualified weekly OGs than there are weekly OGs"
        );
    }

    /// @notice The treasury is an accounting figure and the balance is real money. The figure
    ///         may never exceed the money, or a withdrawal would move USDC that is not there
    ///         and revert inside the token rather than at a gate.
    function invariant_TreasuryNeverExceedsHoldings() public view {
        assertLe(
            bulls.treasuryBalance(),
            usdc.balanceOf(address(bulls)),
            "treasury claims more than the contract holds"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Season boundaries
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A season is thirty draws and stops. currentDraw reaching 31 is the closed
    ///         state; anything beyond means the finalize that closes the game was skipped.
    function invariant_TheSeasonNeverRunsPastItsEnd() public view {
        assertLe(
            bulls.currentDraw(),
            bulls.TOTAL_DRAWS() + 1,
            "the season advanced past its own final draw"
        );
    }

    /// @notice Distribution is bounded by its own tier count. distTierIndex above 3 would
    ///         mean the loop walked off the end of tierPools.
    function invariant_DistributionIndicesStayInBounds() public view {
        assertLe(bulls.distTierIndex(), 3, "distribution walked past the last tier");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Campaign visibility
    // ══════════════════════════════════════════════════════════════════════

    /// @notice NOT AN INVARIANT, a report. Prints what the campaign actually managed to do,
    ///         because an invariant suite that never got past draw 1 passes everything above
    ///         while proving nothing at all. A run showing zero completed draws means the
    ///         handler is stuck, not that the contract is sound.
    ///
    /// @dev    The single most common way an invariant campaign lies to you, and the reason
    ///         this is here rather than left to be noticed later.
    function invariant_CallSummary() public view {
        console.log("draws completed :", handler.ghost_drawsCompleted());
        console.log("buys made       :", handler.ghost_buysMade());
        console.log("prizes claimed  :", handler.ghost_claimsMade());
        console.log("current draw    :", bulls.currentDraw());
        console.log("draw phase      :", uint256(bulls.drawPhase()));
    }
}
