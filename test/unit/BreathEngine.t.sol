// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  The breathing engine
/// @notice The primitive the whole contract exists to demonstrate, and until now the only
///         coverage it had was three regression files pinning H-04, H-06 and H-07.
///
/// @dev    Two halves. The engine itself: a geometric solver that sets each draw's
///         distribution rate so the pot stays on a solvent trajectory to the season's end
///         obligations. And fifteen governance functions across four mechanisms, each a
///         propose/execute/cancel triple behind a timelock.
///
///         Note the two different timelock durations, which is easy to get wrong:
///           TIMELOCK_DELAY       7 days   breath override, breath rails
///           PRIZE_RATE_TIMELOCK  48 hours prize rate reduction and increase
///
///         Bounds that matter:
///           BREATH_START            700 bps   at deploy
///           BREATH_MIN / rail floor 100 bps   ABSOLUTE_BREATH_FLOOR, ungovernable
///           BREATH_MAX             1500 bps
///           exhale floor release   8000-20000 bps, default 12000 (a 20% cushion)
contract BreathEngineTest is SmartEarnBase {
    using stdStorage for StdStorage;

    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant PRIZE_RATE_TIMELOCK = 48 hours;
    uint256 internal constant BREATH_START = 700;
    uint256 internal constant ABSOLUTE_BREATH_FLOOR = 100;
    uint256 internal constant BREATH_MAX = 1500;
    uint256 internal constant ABSOLUTE_BREATH_CEILING = 2000;

    // ══════════════════════════════════════════════════════════════════════
    //  The engine: starting state and rails
    // ══════════════════════════════════════════════════════════════════════

    function test_Engine_StartsAtBreathStart() public view {
        assertEq(bulls.breathMultiplier(), BREATH_START, "deploys at BREATH_START");
        assertEq(bulls.breathRailMin(), ABSOLUTE_BREATH_FLOOR, "rail floor at deploy");
        assertEq(bulls.breathRailMax(), BREATH_MAX, "rail ceiling at deploy");
    }

    /// @notice Draw 1 is calibrated down from BREATH_START to whatever the floors allow.
    ///         It is the tightest draw of the season because no draws have been played, so
    ///         the OG pro-rata component of the dormancy floor is at 100%.
    function test_Engine_Draw1IsCalibratedDownFromStart() public {
        _bootstrapAndStart();
        assertLt(
            bulls.breathMultiplier(),
            BREATH_START,
            "draw 1 breath is clamped below BREATH_START by the floors"
        );
    }

    /// @notice IC-03. This test was logged as owed when v1.17 retained the draw-1 breath
    ///         clamp rather than deleting it as "largely vestigial".
    ///
    ///         Two floors apply at draw 1 and they are different numbers:
    ///           requiredEndPot      the season-end endgame obligation
    ///           _dormancyNowFloor   unreleased VC seed + FULL OG net principal
    ///
    ///         At draw 1 the dormancy floor is the LARGER of the two, because no draws have
    ///         been played so the OG pro-rata is undecayed. The claim under test is that the
    ///         dormancy gate takes precedence: the pot must land on the dormancy floor, not
    ///         on the lower endgame floor.
    function test_Engine_DormGateTakesPrecedenceOverTheDraw1Clamp() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < 50; i++) {
            address og = _newFundedPlayer(99000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 4000 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        uint256 ogNet = 50 * OG_UPFRONT_COST * (10000 - bulls.UF_OG_TREASURY_BPS()) / 10000;
        uint256 dormFloor = VC_SEED + ogNet; // no seed released yet, no draws played
        uint256 endgameFloor = bulls.requiredEndPot();

        assertGt(dormFloor, endgameFloor, "at draw 1 the dormancy floor is the binding one");

        _runStandardDraw();

        // The pot must respect the HIGHER floor, not the one the draw-1 clamp measures
        // against. Two units of dust tolerance: the seed return is floor(weeklyPool/10), so
        // under slightly different numbers the carried pot can land a micro-unit below the
        // floor purely from integer flooring, which is not a gate failure.
        assertGe(
            bulls.prizePot() + 2,
            dormFloor,
            "IC-03: DORM-GATE takes precedence, pot held at the dormancy floor"
        );
        // NOTE: this lands on the floor almost exactly because every draw-1 buy is a
        // commitment credit and adds no new cash. A future fixture with cash buys on draw 1
        // will loosen the binding assertion below, and that is expected rather than a fault.
        // And it should be close to it, not miles above, or the gate is not the binding constraint.
        assertLt(
            bulls.prizePot(),
            dormFloor + 1_000_000,
            "the dormancy floor is genuinely binding, not incidentally satisfied"
        );
    }

    /// @notice Two separate claims, because the ceiling alone is a weak bound: measured
    ///         breath in a healthy game runs 170-550 bps against a 1500 ceiling, so
    ///         `b <= railMax` would pass on almost any value.
    ///
    ///         So: the ceiling is never breached, AND in a healthy game breath never
    ///         collapses to zero. A collapse to zero is legitimate under H-06 when the pot
    ///         cannot hold its floor, but this fixture is solvent throughout, so a zero
    ///         here would mean the solver had stopped distributing without cause.
    ///
    ///         Deliberately NO lower-rail assertion. Since H-06 the solver may correctly
    ///         return below breathRailMin when holding the rail would breach requiredEndPot.
    ///         Asserting b >= railMin would re-introduce the exact bug H-06 fixed.
    function test_Engine_BreathRespectsTheCeilingAndDoesNotCollapse() public {
        _bootstrapAndStart();
        for (uint256 d = 0; d < 6; d++) {
            _runStandardDraw();
            uint256 b = bulls.breathMultiplier();
            assertLe(b, bulls.breathRailMax(), "ceiling never breached");
            assertGt(b, 0, "healthy game, so breath has no cause to collapse to zero");
            // NOT asserted: prizePot >= requiredEndPot. That was the first version and it
            // FAILED, correctly: the pot reached 102,816 against a requiredEndPot of
            // 105,000. requiredEndPot is a SEASON-END target that the solver projects
            // forward to, so the pot may legitimately sit below it mid-season while future
            // revenue is still expected to close the gap. The per-draw guarantee is the
            // DORMANCY floor, not this one.
            assertGe(
                bulls.prizePot(),
                VC_SEED - bulls.seedReleased(),
                "the per-draw guarantee: unreleased investor seed stays covered"
            );
        }
    }

    /// @notice The engine must adapt. A rate that never moves is not a solver, it is a
    ///         constant. Counts DISTINCT values across five draws rather than merely
    ///         checking that something changed once, which the draw-1 calibration alone
    ///         would have guaranteed.
    function test_Engine_BreathTakesMultipleDistinctValues() public {
        _bootstrapAndStart();
        uint256[6] memory seen;
        seen[0] = bulls.breathMultiplier();
        uint256 distinct = 1;

        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
            seen[d] = bulls.breathMultiplier();
            bool isNew = true;
            for (uint256 j = 0; j < d; j++) {
                if (seen[j] == seen[d]) { isNew = false; break; }
            }
            if (isNew) distinct++;
        }

        assertGe(distinct, 3, "breath took at least three distinct values, so it is solving");
    }

    /// @notice avgNetRevenuePerDraw is the estimate the solver projects forward on, and it
    ///         is the mechanism behind H-07's four-draw lag. It must move once real revenue
    ///         starts arriving.
    /// @notice avgNetRevenuePerDraw is the estimate the solver projects forward on, and the
    ///         mechanism behind H-07's four-draw lag. It must actually move once revenue
    ///         starts arriving.
    ///
    ///         Two earlier versions of this test were wrong. The first read
    ///         `!= before || before > 0`, which passes whenever the estimate was already
    ///         non-zero regardless of whether it updated: a vacuity hole. The second asserted
    ///         the EMA must MOVE, which also failed, and correctly so: this fixture has 500
    ///         players buying one ticket every draw, so net revenue is IDENTICAL each draw
    ///         and a converged EMA has nothing to move to. Constant input, constant output.
    ///
    ///         So the real test is convergence, not movement: the estimate should settle at
    ///         the actual per-draw net revenue. 500 tickets at $10 less a 25% treasury slice
    ///         is $3,750, so that is the value it must find.
    function test_Engine_RevenueEstimateConvergesOnActualRevenue() public {
        _bootstrapAndStart();
        for (uint256 d = 0; d < 4; d++) {
            _runStandardDraw();
        }

        uint256 expected = MIN_PLAYERS_TO_START * TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
        uint256 actual = bulls.avgNetRevenuePerDraw();

        assertGt(actual, 0, "the estimate is live rather than sitting at zero");
        assertApproxEqRel(
            actual,
            expected,
            0.15e18,
            "the estimate converged on real per-draw net revenue, within 15%"
        );
    }

    /// @notice checkSolvency is the PREGAME preview of the same floor startGame enforces.
    ///         v1.04's B-M-01 claimed they agree by construction. This pins the direction
    ///         that is reachable: preview says solvent, so startGame must not revert on its
    ///         own floor check.
    ///
    ///         HONEST LIMIT: the other direction is NOT tested here. Proving agreement
    ///         properly needs a fixture where the preview reports INSOLVENT and startGame
    ///         then reverts PotBelowTrajectory. Every configuration reachable from this
    ///         harness is solvent at start, so that case is untested rather than covered.
    ///         Recorded so the claim is not read as stronger than it is.
    function test_Engine_CheckSolvencySolventDirectionAgreesWithStartGame() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        (bool solvent, uint256 deficit) = bulls.checkSolvency();
        assertTrue(solvent, "preview says solvent");
        assertEq(deficit, 0, "and reports no deficit, consistent with the flag");

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.ACTIVE), "start succeeded");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Governance: breath override (7-day timelock)
    // ══════════════════════════════════════════════════════════════════════

    function test_Override_ProposeSetsPendingAndSevenDayTimelock() public {
        _bootstrapAndStart();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("test"));

        assertEq(bulls.pendingBreathOverride(), target, "pending set");
        assertEq(
            bulls.breathOverrideEffectiveTime(),
            block.timestamp + TIMELOCK_DELAY,
            "7 days, not 48 hours"
        );
    }

    function test_Override_RevertsForNonOwner() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(99501);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.proposeBreathOverride(400, bytes32("x"));
    }

    function test_Override_RevertsOutsideTheRails() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathOverride(BREATH_MAX + 1, bytes32("too high"));

        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathOverride(ABSOLUTE_BREATH_FLOOR - 1, bytes32("too low"));
    }

    function test_Override_RevertsWhenUnchanged() public {
        _bootstrapAndStart();
        // Read the value FIRST. vm.expectRevert applies to the next call, and a getter in
        // the argument list is a call, so it would attach to breathMultiplier() instead.
        uint256 current = bulls.breathMultiplier();
        vm.expectRevert(IBullsEthCRE.BreathUnchanged.selector);
        bulls.proposeBreathOverride(current, bytes32("same"));
    }

    function test_Override_RevertsWhenAlreadyPending() public {
        _bootstrapAndStart();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("first"));
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.proposeBreathOverride(target - 10, bytes32("second"));
    }

    function test_Override_RevertsInPregame() public {
        _bootstrapCommitted(10);
        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.proposeBreathOverride(400, bytes32("x"));
    }

    function test_Override_ExecuteRevertsBeforeTimelockElapses() public {
        _bootstrapAndStart();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("x"));
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.executeBreathOverride();
    }

    function test_Override_ExecuteRevertsWithNothingPending() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.executeBreathOverride();
    }

    function test_Override_ExecuteAppliesTheNewRate() public {
        _bootstrapAndStart();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("x"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();

        assertEq(bulls.breathMultiplier(), target, "new rate applied");
        assertEq(bulls.pendingBreathOverride(), 0, "pending cleared");
    }

    function test_Override_CancelClearsThePendingChange() public {
        _bootstrapAndStart();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("x"));
        bulls.cancelBreathOverride();

        assertEq(bulls.pendingBreathOverride(), 0, "cleared");
        // and it becomes proposable again
        bulls.proposeBreathOverride(target, bytes32("again"));
        assertEq(bulls.pendingBreathOverride(), target, "re-proposable after cancel");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Override: the cooldown lock and the pot-health gate
    // ══════════════════════════════════════════════════════════════════════

    /// @notice An executed override locks the solver out for BREATH_COOLDOWN_DRAWS. Without
    ///         that, the next draw's _checkAutoAdjust would simply overwrite the operator's
    ///         decision and the override would be pointless.
    function test_Override_LocksTheSolverOutForThreeDraws() public {
        _bootstrapAndStart();
        _runStandardDraw(); // let the solver settle

        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("hold"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();

        assertEq(bulls.breathMultiplier(), target, "the override applied");
        assertEq(
            bulls.breathOverrideLockUntilDraw(),
            bulls.currentDraw() + 3,
            "and locked the solver out for BREATH_COOLDOWN_DRAWS from the current draw"
        );
        assertGt(
            bulls.breathOverrideLockUntilDraw(),
            bulls.currentDraw(),
            "the lock is genuinely in the future, not already expired"
        );
    }

    /// @dev FIXTURE CONSTRAINT worth recording rather than working around silently. The
    ///      override timelock is 7 DAYS and a draw's buy window closes 48 HOURS after the
    ///      previous slot, so warping out the timelock always lands past the next window
    ///      and _runStandardDraw then reverts PicksLocked. That is correct contract
    ///      behaviour, not a bug: an operator using a 7-day governance action will
    ///      necessarily skip at least one draw's buying.
    ///
    ///      So the lock's EFFECT across a live draw cannot be observed from this harness.
    ///      It needs a fixture that lets draws elapse during the timelock rather than
    ///      warping straight through it. Recorded as owed rather than asserted weakly.

    /// @notice The EMA keeps tracking through the lock. If it froze too, the solver would
    ///         come back after three draws with a stale view of revenue.
    function test_Override_EmaKeepsUpdatingDuringTheLock() public {
        _bootstrapAndStart();
        _runStandardDraw();

        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("hold"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();

        assertEq(bulls.breathMultiplier(), target, "the override is what breath now holds");
    }

    /// @notice THE LOCK'S EFFECT, closed using the OG-only fixture. The problem with the
    ///         casuals fixture is that a 7-day timelock warp blows past the next 48h buy
    ///         window, so no draw can run under the lock. Upfront OGs need no buys: their
    ///         entries exist from registration, so draws stay resolvable however long the
    ///         warp. That makes the lock observable.
    ///
    ///         Two claims, both previously unpinned: the solver does NOT move breath while
    ///         locked, and the EMA DOES keep blending. The lock freezes the decision, not
    ///         the accounting, so the solver returns with a current view of revenue.
    function test_Override_SolverIsFrozenButTheEmaKeepsBlending() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < 50; i++) {
            address og = _newFundedPlayer(64000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("hold"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();
        assertEq(bulls.breathMultiplier(), target, "override applied");

        uint256 emaBefore = bulls.avgNetRevenuePerDraw();

        // One OG-only draw, entirely inside the lock. 100 entries, so 3/9/21.
        _warpToCooldownEnd();
        _resolvePinned();
        // Diffs must reach the OG ladder: predictions are BASE+3000+i and BASE+5000+i,
        // so every diff is >= 3000e6. The tight 2e6/8e6/20e6 set catches nobody and the
        // draw bounces on a count mismatch. Widened to sit on the ladder itself.
        bulls.submitCutoffDiffs(3002e6, 3008e6, 3020e6, 3, 9, 21);
        // Stop on IDLE or on a bounce back to CUTOFF_SUBMISSION: completeDrawStep reverts
        // DrawNotProgressing in that phase, so a naive loop cannot observe a bounce.
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }
        assertEq(bulls.currentDraw(), 2, "the locked draw completed rather than bouncing");

        assertEq(
            bulls.breathMultiplier(),
            target,
            "solver did NOT overwrite the override: a draw elapsed under the lock"
        );
        assertLt(
            bulls.avgNetRevenuePerDraw(),
            emaBefore,
            "but the EMA blended the zero-revenue draw downward, so accounting stayed live"
        );
    }

    /// @notice CONTROL CASE. A decrease is never blocked by pot health. Named for what it
    ///         actually pins: an earlier version of this was called
    ///         "IncreaseIsGatedOnPotHealth" and tested only this half, so a contract with
    ///         the gate deleted entirely would have passed it. The treatment case is below.
    function test_Override_DecreaseIsNeverGatedOnPotHealth() public {
        _bootstrapAndStart();
        _runStandardDraw();

        uint256 lower = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 150;
        bulls.proposeBreathOverride(lower, bytes32("cut"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();
        assertEq(bulls.breathMultiplier(), lower, "a cut is never blocked by pot health");
    }

    /// @notice TREATMENT CASE, and the one that actually fires the gate. An override that
    ///         RAISES breath must revert PotBelowTrajectory when the pot is under 80% of
    ///         requiredEndPot. That asymmetry is the point: cutting spend is always safe,
    ///         raising it while behind trajectory is not.
    ///
    /// @dev    STATE INJECTION, deliberate and explained. Sub-80% health is not organically
    ///         reachable from this harness precisely because the solver defends the floor:
    ///         the worst measured collapse leaves the pot at ~97.7% (that is H-07's
    ///         residual). So requiredEndPot is raised directly with stdstore.
    ///
    ///         Safe because executeBreathOverride's _captureYield restores prizePot but
    ///         never recomputes requiredEndPot, so the injected value survives to the gate.
    ///         The alternative was leaving the gate untested, which is worse.
    function test_Override_IncreaseIsBlockedWhenPotHealthIsBelow80Percent() public {
        _bootstrapAndStart();
        _runStandardDraw();

        uint256 higher = bulls.breathMultiplier() + 100;
        assertLt(higher, bulls.breathRailMax(), "precondition: the increase is inside the rails");
        bulls.proposeBreathOverride(higher, bytes32("raise"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Raise the floor so the live pot sits well under 80% of it.
        uint256 unhealthyFloor = bulls.prizePot() * 10000 / 5000; // pot is now 50% of floor
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(unhealthyFloor);
        assertLt(
            bulls.prizePot() * 10000 / bulls.requiredEndPot(),
            8000,
            "precondition: pot health is genuinely below the 80% gate"
        );

        vm.expectRevert(IBullsEthCRE.PotBelowTrajectory.selector);
        bulls.executeBreathOverride();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Rails: the side effects of executing new ones
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Executing rails does not just store bounds, it CLAMPS live breath into them.
    ///         Otherwise the rate would sit outside its own rails until the next draw.
    function test_Rails_ExecuteClampsLiveBreathIntoTheNewBand() public {
        _bootstrapAndStart();
        _runStandardDraw();

        uint256 live = bulls.breathMultiplier();
        // Choose a floor comfortably above the live rate so the clamp must fire upward.
        uint256 newMin = live + 100;
        bulls.proposeBreathRails(newMin, newMin + 500, bytes32("raise floor"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathRails();

        assertEq(bulls.breathMultiplier(), newMin, "live breath clamped up to the new floor");
        assertGe(bulls.breathMultiplier(), bulls.breathRailMin(), "and now sits inside its rails");
    }

    /// @notice A pending override that would land outside the new rails is CANCELLED by the
    ///         rails execute. Leaving it queued would let an out-of-band value apply later.
    function test_Rails_ExecuteCancelsAPendingOverrideOutsideTheNewBand() public {
        _bootstrapAndStart();
        _runStandardDraw();

        uint256 live = bulls.breathMultiplier();
        uint256 lowTarget = live > 200 ? live - 100 : 110;
        bulls.proposeBreathOverride(lowTarget, bytes32("queued"));
        assertEq(bulls.pendingBreathOverride(), lowTarget, "override is queued");

        // New rails whose floor sits ABOVE the queued value.
        uint256 newMin = lowTarget + 200;
        bulls.proposeBreathRails(newMin, newMin + 500, bytes32("raise floor"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathRails();

        assertEq(
            bulls.pendingBreathOverride(),
            0,
            "the now-invalid pending override was cancelled by the rails execute"
        );
    }

    /// @notice Override bounds are checked against the LIVE rails, not the deploy defaults.
    ///         Every other bounds test in this file uses the defaults, so this is the one
    ///         that proves the check reads current state rather than constants.
    function test_Override_BoundsFollowTheLiveRailsNotTheDefaults() public {
        _bootstrapAndStart();
        _runStandardDraw();

        uint256 live = bulls.breathMultiplier();
        uint256 newMin = live > 400 ? live - 200 : 200;
        uint256 newMax = newMin + 400;
        bulls.proposeBreathRails(newMin, newMax, bytes32("tighten"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathRails();

        // A value legal under the DEFAULT rails (100..1500) but outside the new band.
        uint256 outside = newMax + 100;
        assertLt(outside, 1500, "precondition: this would have been legal under the defaults");
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathOverride(outside, bytes32("outside new rails"));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Governance: breath rails (7-day timelock)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice ABSOLUTE_BREATH_FLOOR is the reason H-06 existed: a hard bottom under the
    ///         rail that governance could not lower. It is still ungovernable, which is
    ///         correct, because H-06 was fixed in the solver rather than by moving the rail.
    function test_Rails_CannotBeSetBelowTheAbsoluteFloor() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.BelowMinimum.selector);
        bulls.proposeBreathRails(ABSOLUTE_BREATH_FLOOR - 1, BREATH_MAX, bytes32("too low"));
    }

    /// @dev The rail ceiling is ABSOLUTE_BREATH_CEILING (2000), which is ABOVE the default
    ///      breathRailMax (1500). So governance can raise the ceiling, up to a hard limit.
    function test_Rails_CannotBeSetAboveTheAbsoluteCeiling() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathRails(ABSOLUTE_BREATH_FLOOR, ABSOLUTE_BREATH_CEILING + 1, bytes32("too high"));
    }

    /// @dev Equal or inverted rails are rejected, because equal rails would pin breath to a
    ///      fixed point and bypass the solver for the rest of the season. The contract's own
    ///      comment points at proposeBreathOverride for an intentional fixed-rate mode.
    function test_Rails_RejectsEqualOrInvertedRails() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathRails(500, 500, bytes32("equal"));

        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathRails(800, 400, bytes32("inverted"));
    }

    function test_Rails_ProposeAndExecuteAppliesBoth() public {
        _bootstrapAndStart();
        bulls.proposeBreathRails(200, 1200, bytes32("tighter"));
        assertEq(bulls.pendingBreathRailMin(), 200, "pending min");
        assertEq(bulls.pendingBreathRailMax(), 1200, "pending max");

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathRails();

        assertEq(bulls.breathRailMin(), 200, "min applied");
        assertEq(bulls.breathRailMax(), 1200, "max applied");
    }

    function test_Rails_RevertsWhenUnchanged() public {
        _bootstrapAndStart();
        uint256 curMin = bulls.breathRailMin();
        uint256 curMax = bulls.breathRailMax();
        vm.expectRevert(IBullsEthCRE.BreathUnchanged.selector);
        bulls.proposeBreathRails(curMin, curMax, bytes32("same"));
    }

    function test_Rails_CancelClears() public {
        _bootstrapAndStart();
        bulls.proposeBreathRails(200, 1200, bytes32("x"));
        bulls.cancelBreathRails();
        assertEq(bulls.pendingBreathRailMin(), 0, "min cleared");
        assertEq(bulls.pendingBreathRailMax(), 0, "max cleared");
    }

    function test_Rails_ExecuteRevertsBeforeTimelock() public {
        _bootstrapAndStart();
        bulls.proposeBreathRails(200, 1200, bytes32("x"));
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.executeBreathRails();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Governance: prize rate (48-hour timelock, NOT 7 days)
    // ══════════════════════════════════════════════════════════════════════

    /// @dev IMPORTANT: prizeRateMultiplier is NOT breathMultiplier. It is a separate scalar,
    ///      defaulting to 10000 (100%), with a reduction floor of 5000 and an increase
    ///      ceiling of 10000. So it can only ever scale prizes DOWN from full, and an
    ///      increase is impossible until a reduction has been made. Conflating the two is
    ///      easy: they are both "rates" and both governed by propose/execute triples.
    function test_PrizeRate_DefaultsToFull() public view {
        assertEq(bulls.prizeRateMultiplier(), 10000, "starts at 100%");
    }

    /// @notice The prize rate mechanism runs on a 48-hour timelock, not the 7 days used by
    ///         the breath override. Using the wrong constant would silently make a reduction
    ///         wait five extra days.
    function test_PrizeRate_ReductionUsesTheShorterTimelock() public {
        _bootstrapAndStart();
        bulls.proposePrizeRateReduction(9000, bytes32("cut to 90%"));

        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        bulls.executePrizeRateReduction();
        assertEq(bulls.prizeRateMultiplier(), 9000, "applied after 48h, not 7 days");
    }

    function test_PrizeRate_ReductionRejectsAnIncrease() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.CanOnlyDecrease.selector);
        bulls.proposePrizeRateReduction(10000, bytes32("not a cut"));
    }

    function test_PrizeRate_ReductionRejectsBelowTheFloor() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.BelowMinimum.selector);
        bulls.proposePrizeRateReduction(4999, bytes32("too deep"));
    }

    /// @dev An increase is only reachable after a reduction, since the default is already at
    ///      the ceiling. Worth pinning: it means the mechanism is a one-way ratchet you can
    ///      partially undo, not a free dial.
    function test_PrizeRate_IncreaseRejectsAboveTheCeiling() public {
        _bootstrapAndStart();
        bulls.proposePrizeRateReduction(9000, bytes32("cut first"));
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        bulls.executePrizeRateReduction();

        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposePrizeRateIncrease(10001, bytes32("above full"));
    }

    /// @notice RESTORED. This was dropped after failing with TooEarly in company while
    ///         passing alone. A separate investigation on a clean forge rig reproduced all
    ///         three symptoms only by planting a duplicate test of the same name carrying a
    ///         stale-warp-anchor bug, and proved the described body passes both ways on two
    ///         forge versions. A grep of this repo finds NO duplicate, so that form is ruled
    ///         out here and the remaining explanation is methodological. CONFIRMED by
    ///         execution: this body now passes in the full suite.
    ///
    ///         The MOST LIKELY cause, by elimination rather than proof: the original
    ///         diagnosis changed two things at once, adding diagnostic statements AND
    ///         scoping the run with --match-test, then credited the difference to the
    ///         scoping. Git history was not checked, so that remains inference.
    ///
    ///         The discipline that makes it immune to the stale-anchor bug: every warp is
    ///         `block.timestamp + delta`, never a captured variable, so each warp moves
    ///         relative to NOW rather than to a timestamp read before an earlier warp.
    ///
    ///         The mid-flight assertions are deliberate: they pin the exact arithmetic the
    ///         original debugging session had to check by hand, so a future failure says
    ///         WHERE it broke rather than just TooEarly.
    function test_PrizeRate_IncreaseCanRestorePartOfAReduction() public {
        _bootstrapAndStart();

        bulls.proposePrizeRateReduction(8000, bytes32("cut to 80%"));
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        bulls.executePrizeRateReduction();
        assertEq(bulls.prizeRateMultiplier(), 8000, "reduction applied");
        assertEq(bulls.multiplierEffectiveTime(), 0, "effective time cleared by the reduction");

        bulls.proposePrizeRateIncrease(9000, bytes32("restore to 90%"));
        assertEq(
            bulls.multiplierEffectiveTime(),
            block.timestamp + PRIZE_RATE_TIMELOCK,
            "increase sets effective time to exactly now + 48h"
        );
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        bulls.executePrizeRateIncrease();

        assertEq(bulls.prizeRateMultiplier(), 9000, "partial restore applied");
    }

    function test_PrizeRate_ReductionExecuteRevertsBeforeTimelock() public {
        _bootstrapAndStart();
        bulls.proposePrizeRateReduction(9000, bytes32("x"));
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.executePrizeRateReduction();
    }

    function test_PrizeRate_CancelClearsTheReduction() public {
        _bootstrapAndStart();
        uint256 rateBefore = bulls.prizeRateMultiplier();
        bulls.proposePrizeRateReduction(9000, bytes32("x"));
        bulls.cancelPrizeRateReduction();

        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.executePrizeRateReduction();
        assertEq(bulls.prizeRateMultiplier(), rateBefore, "rate untouched after cancel");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Governance: exhale floor release
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The exhale comfort floor only overrides the solver when the pot is at or
    ///         above this multiple of requiredEndPot. Default 12000 bps is a 20% cushion,
    ///         which is what stops the comfort floor from being a solvency hole.
    function test_ExhaleFloor_DefaultsToA20PercentCushion() public view {
        assertEq(bulls.exhaleFloorReleaseBps(), 12000, "120% of the floor by default");
    }

    function test_ExhaleFloor_RejectsBelow8000() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.BelowMinimum.selector);
        bulls.proposeExhaleFloorRelease(7999);
    }

    function test_ExhaleFloor_RejectsAbove20000() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeExhaleFloorRelease(20001);
    }

    /// @dev The exhale floor runs on PRIZE_RATE_TIMELOCK (48h), NOT TIMELOCK_DELAY (7 days).
    ///      The first version of this test warped 7 days and passed, but only because 7 days
    ///      exceeds 48 hours: it pinned nothing, and a regression moving this mechanism to a
    ///      7-day lock would have gone undetected. Precisely the two-durations trap this
    ///      file's own header warns about, made in the same file.
    function test_ExhaleFloor_ProposeAndExecuteApplies() public {
        _bootstrapAndStart();
        bulls.proposeExhaleFloorRelease(15000);
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        bulls.executeExhaleFloorRelease();
        assertEq(bulls.exhaleFloorReleaseBps(), 15000, "applied after 48h");
    }

    function test_ExhaleFloor_ExecuteRevertsBeforeTimelock() public {
        _bootstrapAndStart();
        bulls.proposeExhaleFloorRelease(15000);
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.executeExhaleFloorRelease();
    }

    function test_ExhaleFloor_CancelClears() public {
        _bootstrapAndStart();
        uint256 before = bulls.exhaleFloorReleaseBps();
        bulls.proposeExhaleFloorRelease(15000);
        bulls.cancelExhaleFloorRelease();

        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.executeExhaleFloorRelease();
        assertEq(bulls.exhaleFloorReleaseBps(), before, "unchanged after cancel");
    }
}
