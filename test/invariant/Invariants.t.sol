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

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0]  = handler.buy.selector;
        selectors[1]  = handler.predict.selector;
        selectors[2]  = handler.resolve.selector;
        selectors[3]  = handler.submitCutoffs.selector;
        selectors[4]  = handler.step.selector;
        selectors[5]  = handler.claim.selector;
        selectors[6]  = handler.warp.selector;
        // Pass two: the destructive paths and the claims they unlock.
        selectors[7]  = handler.sabotageCutoffs.selector;
        selectors[8]  = handler.reset.selector;
        selectors[9]  = handler.dormancy.selector;
        selectors[10] = handler.claimRefund.selector;
        selectors[11] = handler.sweep.selector;
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

    /// @notice THE CONTRACT'S OWN IDENTITY, asserted for the first time. activateDormancy's
    ///         NatSpec states that draws played plus reset draws equals currentDraw - 1, and
    ///         sizes every OG's pro-rata refund on it. Nothing checked it.
    ///
    /// @dev    It could not be checked before pass two, for a reason worth recording:
    ///         drawsPlayed is NOT a state variable. There is no increment site. It is derived
    ///         at dormancy as (currentDraw - 1) - resetDrawCount, so asserting the identity
    ///         against the contract's own figures is circular.
    ///
    ///         The ghosts break the circle. The handler counts clean finalisations and
    ///         reset-driven advances separately, by reading resetDrawCount either side of
    ///         each step. Pass one conflated them -- any currentDraw advance counted as a
    ///         completed draw -- which is exactly why this invariant is new here rather than
    ///         written earlier.
    function invariant_EveryDrawNumberIsEitherPlayedOrVoided() public view {
        assertEq(
            handler.ghost_drawsCompleted() + handler.ghost_resetsCompleted(),
            bulls.currentDraw() - 1,
            "a draw number was consumed without being either played or voided"
        );
    }

    /// @notice DORMANCY SENIORITY. No junior tier may be funded while a senior tier is short.
    ///         VC seed is senior to OG principal, which is senior to casual refunds, which is
    ///         senior to the commitment pool. That ordering is a promise made to an investor
    ///         and to committed players, and it is the reason the waterfall exists at all.
    ///
    /// @dev    VACUITY GUARD, and the dormancy register's own lesson applied to itself. On a
    ///         contract that has never gone dormant every pool is zero and the implication
    ///         holds trivially, so the property would read as coverage while proving nothing.
    ///         The early return makes it explicit that this asserts only where there is
    ///         something to assert about.
    function invariant_SeniorTiersAreFundedBeforeJuniorOnes() public view {
        if (bulls.gamePhase() != IBullsEthCRE.GamePhase.DORMANT) return;

        // Full cover is the contract's own flag for "this tier was satisfied in full".
        // A junior pool holding money while a senior one was short is the violation.
        if (!bulls.dormancyPrincipalFullCover()) {
            assertEq(
                bulls.dormancyCasualRefundPool(),
                0,
                "casual pool funded while OG principal was short"
            );
            assertEq(
                bulls.dormancyCommitmentPool(),
                0,
                "commitment pool funded while OG principal was short"
            );
        }
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
    //  Campaign visibility, asserted rather than printed
    // ══════════════════════════════════════════════════════════════════════

    /// @notice RUNS ONCE AT THE END OF EACH SEQUENCE, and that timing is the whole point.
    ///
    /// @dev    This replaces an invariant_CallSummary that logged the same figures. It was
    ///         wrong, and wrong in a way worth recording. invariant_ functions are checked
    ///         after EVERY call INCLUDING THE FIRST, when the fuzzer has done nothing yet.
    ///         A summary logged there reports draw 1, zero buys, zero draws -- whether or
    ///         not the campaign was actually empty. The printout looked like a stuck handler
    ///         on a campaign that was completing draws perfectly well.
    ///
    ///         afterInvariant runs once per sequence, after the calls, so the numbers are
    ///         the campaign's real output.
    ///
    ///         AND IT ASSERTS RATHER THAN PRINTS. A campaign that never completes a draw
    ///         satisfies every property above trivially: nothing happened, so nothing broke.
    ///         That is the single most common way an invariant suite lies, and a log only
    ///         catches it if somebody reads the log. This makes CI catch it instead.
    function afterInvariant() public view {
        console.log("-- progress --");
        console.log("draws completed :", handler.ghost_drawsCompleted());
        console.log("buys made       :", handler.ghost_buysMade());
        console.log("resolves        :", handler.ghost_resolvesMade());
        console.log("cutoffs taken   :", handler.ghost_cutoffsAccepted());
        console.log("draws voided    :", handler.ghost_resetsCompleted());
        console.log("resets fired    :", handler.ghost_resetsTriggered());
        console.log("sabotages taken :", handler.ghost_sabotages());
        console.log("dormancies      :", handler.ghost_dormancyActivated());
        console.log("prizes claimed  :", handler.ghost_claimsMade());
        console.log("refunds claimed :", handler.ghost_refundClaims());
        console.log("final draw      :", bulls.currentDraw());

        // WHY nothing happened, if nothing happened. The first campaign reported 12,800
        // calls, zero reverts and zero effect, and the cause had to be guessed at. These
        // turn the next stall into a diagnosis rather than a theory.
        console.log("-- skipped because --");
        console.log("wrong phase     :", handler.ghost_skipWrongPhase());
        console.log("window shut     :", handler.ghost_skipWindowShut());
        console.log("too few buyers  :", handler.ghost_skipTooFewBuyers());
        console.log("cooldown        :", handler.ghost_skipCooldown());
        console.log("dice            :", handler.ghost_skipDice());
        console.log("-- swallowed reverts --");
        console.log("buy             :", handler.ghost_failBuy());
        console.log("resolve         :", handler.ghost_failResolve());
        console.log("cutoffs         :", handler.ghost_failCutoffs());
        console.log("step            :", handler.ghost_failStep());
        console.log("reset           :", handler.ghost_failReset());
        console.log("dormancy        :", handler.ghost_failDormancy());

        // THE ASSERT WIDENS IN PASS TWO, and it has to. "Completed a draw" was the right
        // bar for a live-season handler, where nothing else could happen. It is now WRONG:
        // a sequence that strands its pick window and goes dormant, or that voids its only
        // draws by reset, has explored exactly the paths this pass adds. Holding the old
        // bar would fail the stall-then-dormancy sequence BY DESIGN, which is the one most
        // worth reaching.
        //
        // The bar is instead "something irreversible happened". A campaign that neither
        // played a draw nor voided one nor wound the game down did nothing at all, and every
        // property above passed trivially.
        bool didSomething = handler.ghost_drawsCompleted() > 0
            || handler.ghost_resetsCompleted() > 0
            || handler.ghost_dormancyActivated() > 0;

        assertTrue(
            didSomething,
            "campaign was inert: no draw played, none voided, no wind-down"
        );
    }
}
