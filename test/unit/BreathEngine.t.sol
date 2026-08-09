// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  The breathing engine
/// @notice The primitive the whole contract exists to demonstrate.
///
/// @dev    Two halves. The engine itself: a geometric solver that sets each draw's
///         distribution rate so the pot stays on a solvent trajectory to the season's end
///         obligations. And fifteen governance functions across four mechanisms, each a
///         propose/execute/cancel triple behind a timelock.
///
///         TIMELOCK_DELAY 7 days (breath override, breath rails).
///         PRIZE_RATE_TIMELOCK 48 hours (prize rate, exhale floor release).
///
///         Bounds: BREATH_START 700 bps. Rail floor 100 (ABSOLUTE_BREATH_FLOOR,
///         ungovernable). BREATH_MAX 1500 default, ABSOLUTE_BREATH_CEILING 2000 hard limit.
///         exhale floor release 8000-20000 bps, default 12000 (a 20% cushion).
///
///         BATCH 7 STATUS: X-01 (both exhale-floor behaviour tests), X-02 and X-03 (both
///         recalibration tests) were rewritten this pass to actually exercise the
///         branch/mechanism their names claim, following an external review that proved by
///         executed probe that the earlier versions missed their target. Each fix's @dev
///         explains what the earlier version got wrong.
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

    function test_Engine_Draw1IsCalibratedDownFromStart() public {
        _bootstrapAndStart();
        assertLt(
            bulls.breathMultiplier(),
            BREATH_START,
            "draw 1 breath is clamped below BREATH_START by the floors"
        );
    }

    /// @notice IC-03. At draw 1 the dormancy floor (unreleased VC seed + FULL OG net
    ///         principal) exceeds requiredEndPot (the season-end target), because no draws
    ///         have been played so the OG pro-rata is undecayed. The claim under test is
    ///         that the dormancy gate takes precedence: the pot lands on the HIGHER floor.
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
        uint256 dormFloor = VC_SEED + ogNet;
        uint256 endgameFloor = bulls.requiredEndPot();
        assertGt(dormFloor, endgameFloor, "at draw 1 the dormancy floor is the binding one");

        _runStandardDraw();

        // 2 units of dust tolerance: seed return is floor(weeklyPool/10), so the carried
        // pot can land a micro-unit below the floor purely from integer flooring.
        assertGe(
            bulls.prizePot() + 2,
            dormFloor,
            "IC-03: DORM-GATE takes precedence, pot held at the dormancy floor"
        );
        assertLt(
            bulls.prizePot(),
            dormFloor + 1_000_000,
            "the dormancy floor is genuinely binding, not incidentally satisfied"
        );
    }

    /// @notice The ceiling is never breached, and in a healthy game breath never collapses
    ///         to zero without cause. Deliberately NO lower-rail assertion: since H-06 the
    ///         solver may correctly return below breathRailMin, and asserting b >= railMin
    ///         would re-introduce the exact bug H-06 fixed.
    function test_Engine_BreathRespectsTheCeilingAndDoesNotCollapse() public {
        _bootstrapAndStart();
        for (uint256 d = 0; d < 6; d++) {
            _runStandardDraw();
            uint256 b = bulls.breathMultiplier();
            assertLe(b, bulls.breathRailMax(), "ceiling never breached");
            assertGt(b, 0, "healthy game, so breath has no cause to collapse to zero");
            assertGe(
                bulls.prizePot(),
                VC_SEED - bulls.seedReleased(),
                "the per-draw guarantee: unreleased investor seed stays covered"
            );
        }
    }

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

    /// @notice The estimate should CONVERGE, not merely move. 500 tickets at $10 less a 25%
    ///         treasury slice is $3,750 net per draw.
    function test_Engine_RevenueEstimateConvergesOnActualRevenue() public {
        _bootstrapAndStart();
        for (uint256 d = 0; d < 4; d++) {
            _runStandardDraw();
        }
        uint256 expected = MIN_PLAYERS_TO_START * TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
        uint256 actual = bulls.avgNetRevenuePerDraw();
        assertGt(actual, 0, "the estimate is live rather than sitting at zero");
        assertApproxEqRel(actual, expected, 0.15e18, "the estimate converged on real net revenue, within 15%");
    }

    /// @notice HONEST LIMIT: only the solvent direction is tested. Every configuration
    ///         reachable from this harness is solvent at start, so the insolvent
    ///         checkSolvency/startGame agreement is untested rather than covered.
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
    //  One-shot calibrations: draw 7 and draw 28
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Draw 7 recalibrates targetReturnBps from the LIVE OG ratio. v1.61 removed the
    ///         breathMultiplier write here specifically to avoid a draw-7 breath bump
    ///         artefact; completeDrawStep at draw 8 applies the new target normally.
    function test_Recalibration_Draw7UpdatesTargetReturnFromLiveRatio() public {
        _bootstrapAndStart();
        uint256 targetBefore = bulls.targetReturnBps();
        for (uint256 d = 1; d <= 7; d++) {
            _runStandardDraw();
        }
        assertEq(bulls.currentDraw(), 8, "seven draws completed, now entering draw 8");
        assertEq(bulls.targetReturnBps(), targetBefore, "unchanged: the ratio did not move (no OGs at all)");
    }

    /// @notice X-02 REWRITE. The earlier version registered ten OGs, cancelled NONE, and
    ///         asserted the target unchanged while calling itself the case where the ratio
    ///         "has cancelled" -- that is just the no-op control the test above already
    ///         covers. Its stated route was also impossible on v1.17:
    ///         cancelOGRegistration is PREGAME-only
    ///         (`if (gamePhase != GamePhase.PREGAME) revert WrongPhase()`).
    ///
    /// @dev    THE REAL ROUTE: weekly OG STATUS LOSS. upfrontOGCount + earnedOGCount is the
    ///         ratio's numerator; ogCapDenominator is fixed at startGame. A weekly OG who
    ///         skips a buy loses status during that draw's matching, decrementing the
    ///         numerator without moving the denominator, so the live ratio genuinely falls.
    ///
    ///         110 upfront OGs against 500 committed puts the ratio at 22%, comfortably
    ///         above the curve's 20% knee, so a fall in ratio is a fall in target (below the
    ///         knee the curve is flat and a small move would not register).
    function test_Recalibration_Draw7ReactsWhenAWeeklyOgHasLostStatus() public {
        // ORDERING IS LOAD-BEARING. _weeklyOGCapReached() is evaluated ONLY inside
        // registerAsWeeklyOG, and TOTAL_OG_CAP_BPS (18%) is measured against
        // upfrontOGCount + weeklyOGCount. Registering the upfront cohort first consumes
        // the whole cap and every weekly registration then reverts OGCapReached. Weekly
        // first, upfront after, is the order that works: the cap is never re-checked
        // afterwards, so the weekly OGs are legitimately grandfathered above the knee.
        // 500 casuals + 10 weekly + 140 upfront = committedPlayerCount 650.
        // maxOGs 150, ratio 150*10000/650 = 2307 bps, above the 2000 knee, so
        // targetReturnBps at start = 5000 - (2307-2000)*4000/8000 = 4847.
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address[] memory wogs = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            wogs[i] = _newFundedPlayer(65200 + i);
            vm.prank(wogs[i]); bulls.register();
            vm.prank(wogs[i]); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000 + i, BASE_PREDICTION + 7500 + i);
        }
        for (uint256 i = 0; i < 140; i++) {
            address og = _newFundedPlayer(65000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        uint256 targetBefore = bulls.targetReturnBps();

        _runStandardDraw(); // draw 1: pregame weekly OG already credited
        assertEq(bulls.currentDraw(), 2, "draw 1 finalised");

        // Draw 2: the weekly OG deliberately does NOT buy. Casuals still do, so the draw
        // remains resolvable and matching runs, which is what flips statusLost.
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        // 500 casuals + 150 OGs x2 = 800 snapshot entries. Counts 10/40/100 read as
        // 125/500/1250 bps: T1 inside [50,400], T2 inside [400,1200], T3 inside
        // [1000,5000]. OG predictions sit at BASE+3000 and up, far outside t3CutoffDiff,
        // so they never win and reconciliation is unaffected.
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }
        assertEq(bulls.currentDraw(), 3, "draw 2 finalised, status loss should have fired in matching");

        for (uint256 d = 3; d <= 6; d++) {
            _runStandardDraw();
        }
        assertEq(bulls.currentDraw(), 7, "entering draw 7");
        assertEq(bulls.targetReturnBps(), targetBefore, "target still holds the ORIGINAL ratio through draw 6");

        _runStandardDraw(); // draw 7 recalibrates
        assertEq(bulls.currentDraw(), 8, "draw 7 completed");

        // DIRECTION is the load-bearing claim, not the exact bps. Losing OGs above the 20%
        // knee lowers the ratio, and the curve pays MORE per OG at a lower ratio, so the
        // target must RISE. Hand-derived: ratio 2307 -> 2153, target 4847 -> 4924. Asserted
        // as a rise rather than a literal so a rounding difference does not read as a
        // regression, while a move in the wrong direction still fails loudly.
        assertGt(
            bulls.targetReturnBps(),
            targetBefore,
            "ratio fell (10 weekly OGs lost status), so draw 7 recalibrated the target UP"
        );
    }

    /// @notice X-03 REWRITE. The earlier version asserted requiredEndPot >= floorBefore - 1
    ///         after draw 28, which CANNOT FAIL: requiredEndPot is recomputed every draw by
    ///         _snapshotOGObligation regardless of draw 28's own logic. This rewrite times a
    ///         status loss to fire AFTER draw 7, so the target is stale through 8-27 and
    ///         jumps specifically at 28, proving draw 28's OWN recalibration ran.
    function test_Recalibration_Draw28UpdatesTheFinalFloor() public {
        // Weekly-first ordering, same reason as the draw-7 test, plus TWO cohorts of five.
        // Cohort A is lost at draw 2 (its effect on draw 7 is incidental here). Cohort B
        // keeps buying through draw 8 and is lost at draw 9, so the ONLY ratio movement
        // left for draw 28 to react to lands strictly after draw 7. Without that, the
        // draw-28 assertion cannot distinguish _finalReturnCalibration from the routine
        // per-draw snapshot, which recomputes requiredEndPot every draw anyway.
        //
        // 500 casuals + 10 weekly + 140 upfront = committedPlayerCount 650.
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address[] memory wogsEarly = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            wogsEarly[i] = _newFundedPlayer(65500 + i);
            vm.prank(wogsEarly[i]); bulls.register();
            vm.prank(wogsEarly[i]); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7000 + i, BASE_PREDICTION + 7500 + i);
        }
        address[] memory wogsLate = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            wogsLate[i] = _newFundedPlayer(65600 + i);
            vm.prank(wogsLate[i]); bulls.register();
            vm.prank(wogsLate[i]); bulls.registerAsWeeklyOG(BASE_PREDICTION + 7100 + i, BASE_PREDICTION + 7600 + i);
        }
        for (uint256 i = 0; i < 140; i++) {
            address og = _newFundedPlayer(65300 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        // Draw 1: everyone is already credited by registration (lastBoughtDraw = 1), so the
        // weekly cohorts must NOT buy here or they revert AlreadyBoughtThisWeek.
        _runStandardDraw();
        assertEq(bulls.currentDraw(), 2, "draw 1 finalised");

        // Draws 2-8: casuals buy, cohort B buys (2 tickets, the weekly-OG minimum), cohort A
        // does not. Cohort A is therefore lost during draw 2's matching.
        for (uint256 d = 2; d <= 8; d++) {
            _driveDrawWithWeeklies(wogsLate);
        }
        assertEq(bulls.currentDraw(), 9, "seven more draws done, past draw 7's recalibration");
        uint256 targetAfterDraw7 = bulls.targetReturnBps();

        // Draw 9: cohort B stops buying too, so it is lost here. This is the move draw 28
        // has left to see.
        address[] memory none = new address[](0);
        _driveDrawWithWeeklies(none);
        assertEq(bulls.currentDraw(), 10, "draw 9 finalised, cohort B lost status in matching");

        // Draws 10-27: nothing further moves the ratio, so the target must sit stale.
        for (uint256 d = 10; d <= 27; d++) {
            _driveDrawWithWeeklies(none);
        }
        assertEq(bulls.currentDraw(), 28, "27 draws completed, entering draw 28");
        assertEq(
            bulls.targetReturnBps(),
            targetAfterDraw7,
            "target is STALE through draw 27: the ratio moved at draw 9 but nothing recalibrated it"
        );
        uint256 floorBeforeDraw28 = bulls.requiredEndPot();

        _driveDrawWithWeeklies(none); // draw 28: _finalReturnCalibration must fire here

        assertEq(bulls.currentDraw(), 29, "draw 28 completed");
        assertTrue(
            bulls.targetReturnBps() != targetAfterDraw7,
            "target JUMPED at exactly draw 28, proving _finalReturnCalibration ran there"
        );
        assertTrue(
            bulls.requiredEndPot() != floorBeforeDraw28,
            "requiredEndPot moved with the target, through _requiredEndPotFloor"
        );
    }

    /// @dev Drives one full draw where the casuals buy one ticket each and the supplied
    ///      weekly OGs buy their two-ticket minimum. Any weekly OG NOT in the list simply
    ///      does not buy, which is what makes it lose status during this draw's matching.
    ///
    ///      Needed because _runStandardDraw only buys for the bootstrapped `players` array;
    ///      separately-registered weekly OGs are invisible to it. An earlier version of the
    ///      draw-28 test relied on _runStandardDraw to keep its weekly cohort alive through
    ///      draw 8, so the whole cohort was actually lost at draw 2 and the test measured
    ///      the opposite of what it claimed.
    function _driveDrawWithWeeklies(address[] memory weeklies) internal {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        // Constant read hoisted OUT of the prank line. Two bugs live here, both real:
        // (1) MIN_TICKETS_WEEKLY_OG is a CONTRACT constant, not one this test declares, so
        //     using it bare does not compile.
        // (2) The obvious fix -- bulls.MIN_TICKETS_WEEKLY_OG() inline in the argument --
        //     compiles and then fails at runtime with NotRegistered, because vm.prank
        //     applies to the NEXT external call and a getter in the argument position IS
        //     that call. The prank is consumed by the getter and buyTickets then executes
        //     as the (unregistered) test contract. Same footgun as putting a getter inside
        //     vm.expectRevert's arguments; hoist the read and the problem disappears.
        uint256 wogTickets = bulls.MIN_TICKETS_WEEKLY_OG();
        for (uint256 i = 0; i < weeklies.length; i++) {
            vm.prank(weeklies[i]); bulls.buyTickets(wogTickets);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        // 500 casuals + up to 150 OGs x2 = at most 800 snapshot entries; the OG count only
        // falls as status is lost. Counts 10/40/100 read as 125/500/1250 bps at 800 and
        // rise as the snapshot shrinks, staying inside T1 [50,400], T2 [400,1200],
        // T3 [1000,5000] throughout. OG predictions sit at BASE+3000 and up, outside t3.
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Exhale floor: the behaviour, not just the governance around it
    // ══════════════════════════════════════════════════════════════════════

    /// @notice X-01 REWRITE. Two earlier versions missed their branch, PROVEN by executed
    ///         probes: HOLD injected the floor DOWN (more headroom, solver went UP, hold
    ///         block never entered -- a probe proved breath rose). RELEASE injected 2x floor
    ///         (H-06 insolvency territory, solver returned 0, and 0 < railMin means the
    ///         RAIL-RELEASE path bypasses the exhale block entirely -- a probe proved breath
    ///         landed exactly 0, and that test asserted nothing about breath anyway).
    ///
    ///         Both branches need the solver to want LOWER than the CURRENT rate, which
    ///         needs breath ELEVATED first. Recipe: OG-only fixture, 20 zero-revenue draws
    ///         past INHALE_DRAWS, override breath UP, ride the 3-draw cooldown, THEN inject
    ///         requiredEndPot per arm so health sits either side of 12000 bps.
    function _elevateBreathThenClearTheLock() internal returns (uint256 elevated) {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < 50; i++) {
            address og = _newFundedPlayer(66000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 5000 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        for (uint256 d = 1; d <= 20; d++) {
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(3002e6, 3008e6, 3020e6, 3, 9, 21);
            for (uint256 i = 0; i < 20; i++) {
                uint256 ph = uint256(bulls.drawPhase());
                if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
                if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
                bulls.completeDrawStep();
            }
        }
        assertEq(bulls.currentDraw(), 21, "twenty draws completed, past INHALE_DRAWS");

        // ABSOLUTE, not relative. `breathMultiplier() + 100` was the earlier version and it
        // is exactly what made the release arm assert "100 >= 100": after 20 zero-revenue
        // draws the solver has already driven breath to 0, so +100 elevates to 100, which IS
        // breathRailMin. The release arm then compared breath against railMin and passed
        // while breath was actually 0 -- the H-06 rail-release path, not the exhale release
        // the test claims to be checking. A fixed value clear of the rail removes that.
        elevated = 1200;
        assertLt(elevated, bulls.breathRailMax(), "precondition: the raise is inside the rails");
        assertGt(elevated, bulls.breathRailMin(), "precondition: and clear of the rail floor");
        bulls.proposeBreathOverride(elevated, bytes32("elevate for exhale test"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();
        assertEq(bulls.breathMultiplier(), elevated, "breath is now elevated above the solver's own answer");

        // FOUR draws, not one. executeBreathOverride sets
        // breathOverrideLockUntilDraw = currentDraw + BREATH_COOLDOWN_DRAWS (3), and
        // _checkAutoAdjust returns early while `currentDraw <= breathOverrideLockUntilDraw`.
        // The override lands at draw 21, so the lock covers draws 22-24 and the solver only
        // runs freely again from draw 25. One draw left it locked, so the arm's injected
        // draw never reached the exhale gate at all.
        for (uint256 d = 0; d < 4; d++) {
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(3002e6, 3008e6, 3020e6, 3, 9, 21);
            for (uint256 i = 0; i < 20; i++) {
                uint256 ph = uint256(bulls.drawPhase());
                if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
                if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
                bulls.completeDrawStep();
            }
        }
        assertEq(bulls.currentDraw(), 25, "four draws elapsed, override lock cleared");
        assertGt(
            bulls.currentDraw(),
            bulls.breathOverrideLockUntilDraw(),
            "precondition: the solver is genuinely free to run again"
        );
        assertEq(bulls.breathMultiplier(), elevated, "and breath is still the elevated value");
    }

    /// @notice HOLD ARM. Pot healthy (>= 120% of floor), solver wants lower than elevated
    ///         breath: the comfort floor must hold it at exactly the elevated value.
    function test_ExhaleFloor_HoldsTheElevatedBreathWhenThePotIsHealthy() public {
        uint256 elevated = _elevateBreathThenClearTheLock();

        uint256 healthyFloor = bulls.prizePot() * 10000 / 13000; // pot now 130% of floor
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(healthyFloor);
        assertGe(
            bulls.prizePot() * 10000 / bulls.requiredEndPot(),
            bulls.exhaleFloorReleaseBps(),
            "precondition: genuinely healthy by the gate's own threshold"
        );

        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(3002e6, 3008e6, 3020e6, 3, 9, 21);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }

        assertEq(
            bulls.breathMultiplier(),
            elevated,
            "HOLD: equality, not >=. The floor held against a solver that provably wanted lower."
        );
    }

    /// @notice RELEASE ARM. Pot unhealthy (<120%, nowhere near H-06 insolvency), solver
    ///         wants lower than elevated breath: the comfort floor must stand down.
    function test_ExhaleFloor_ReleasesTheElevatedBreathWhenThePotIsUnhealthy() public {
        uint256 elevated = _elevateBreathThenClearTheLock();

        uint256 unhealthyFloor = bulls.prizePot() * 10000 / 11000; // pot now 110% of floor
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(unhealthyFloor);
        assertLt(
            bulls.prizePot() * 10000 / bulls.requiredEndPot(),
            bulls.exhaleFloorReleaseBps(),
            "precondition: genuinely unhealthy by the gate's own threshold"
        );

        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(3002e6, 3008e6, 3020e6, 3, 9, 21);
        for (uint256 i = 0; i < 20; i++) {
            uint256 ph = uint256(bulls.drawPhase());
            if (ph == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            if (ph == uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION)) break;
            bulls.completeDrawStep();
        }

        assertLt(bulls.breathMultiplier(), elevated, "RELEASE: breath fell from the elevated value");
        assertGe(
            bulls.breathMultiplier(),
            bulls.breathRailMin(),
            "and stayed >= railMin: this is the EXHALE release, not an H-06 rail-release bypass"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Governance: breath override (7-day timelock)
    // ══════════════════════════════════════════════════════════════════════

    function test_Override_ProposeSetsPendingAndSevenDayTimelock() public {
        _bootstrapAndStart();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("test"));
        assertEq(bulls.pendingBreathOverride(), target, "pending set");
        assertEq(bulls.breathOverrideEffectiveTime(), block.timestamp + TIMELOCK_DELAY, "7 days, not 48 hours");
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
        bulls.proposeBreathOverride(target, bytes32("again"));
        assertEq(bulls.pendingBreathOverride(), target, "re-proposable after cancel");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Override: the cooldown lock and the pot-health gate
    // ══════════════════════════════════════════════════════════════════════

    function test_Override_LocksTheSolverOutForThreeDraws() public {
        _bootstrapAndStart();
        _runStandardDraw();
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

    /// @notice Pins the override applying. The lock's live effect on a draw is closed below
    ///         by the OG-only fixture test, since a 7-day timelock warp on the casuals
    ///         fixture blows past the next 48h buy window and no draw can run under it.
    function test_Override_EmaKeepsUpdatingDuringTheLock() public {
        _bootstrapAndStart();
        _runStandardDraw();
        uint256 target = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 400;
        bulls.proposeBreathOverride(target, bytes32("hold"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();
        assertEq(bulls.breathMultiplier(), target, "the override is what breath now holds");
    }

    /// @notice THE LOCK'S EFFECT, closed using the OG-only fixture. Upfront OGs need no
    ///         buys, so draws stay resolvable however long the warp, which makes the lock
    ///         observable. Two claims, both previously unpinned: the solver does NOT move
    ///         breath while locked, and the EMA DOES keep blending.
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

        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(3002e6, 3008e6, 3020e6, 3, 9, 21);
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
    ///         actually pins: an earlier version tested only this half under the name
    ///         "IncreaseIsGatedOnPotHealth". The treatment case is below.
    function test_Override_DecreaseIsNeverGatedOnPotHealth() public {
        _bootstrapAndStart();
        _runStandardDraw();
        uint256 lower = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 150;
        bulls.proposeBreathOverride(lower, bytes32("cut"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathOverride();
        assertEq(bulls.breathMultiplier(), lower, "a cut is never blocked by pot health");
    }

    /// @notice TREATMENT CASE. An override that RAISES breath must revert
    ///         PotBelowTrajectory when the pot is under 80% of requiredEndPot.
    ///
    /// @dev    STATE INJECTION. Sub-80% health is not organically reachable from this
    ///         harness (the worst measured collapse leaves the pot at ~97.7%, H-07's
    ///         residual). Safe because executeBreathOverride's _captureYield restores
    ///         prizePot but never recomputes requiredEndPot.
    function test_Override_IncreaseIsBlockedWhenPotHealthIsBelow80Percent() public {
        _bootstrapAndStart();
        _runStandardDraw();
        uint256 higher = bulls.breathMultiplier() + 100;
        assertLt(higher, bulls.breathRailMax(), "precondition: the increase is inside the rails");
        bulls.proposeBreathOverride(higher, bytes32("raise"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

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

    function test_Rails_ExecuteClampsLiveBreathIntoTheNewBand() public {
        _bootstrapAndStart();
        _runStandardDraw();
        uint256 live = bulls.breathMultiplier();
        uint256 newMin = live + 100;
        bulls.proposeBreathRails(newMin, newMin + 500, bytes32("raise floor"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathRails();
        assertEq(bulls.breathMultiplier(), newMin, "live breath clamped up to the new floor");
        assertGe(bulls.breathMultiplier(), bulls.breathRailMin(), "and now sits inside its rails");
    }

    function test_Rails_ExecuteCancelsAPendingOverrideOutsideTheNewBand() public {
        _bootstrapAndStart();
        _runStandardDraw();
        uint256 live = bulls.breathMultiplier();
        uint256 lowTarget = live > 200 ? live - 100 : 110;
        bulls.proposeBreathOverride(lowTarget, bytes32("queued"));
        assertEq(bulls.pendingBreathOverride(), lowTarget, "override is queued");

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

    function test_Override_BoundsFollowTheLiveRailsNotTheDefaults() public {
        _bootstrapAndStart();
        _runStandardDraw();
        uint256 live = bulls.breathMultiplier();
        uint256 newMin = live > 400 ? live - 200 : 200;
        uint256 newMax = newMin + 400;
        bulls.proposeBreathRails(newMin, newMax, bytes32("tighten"));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeBreathRails();

        uint256 outside = newMax + 100;
        assertLt(outside, 1500, "precondition: this would have been legal under the defaults");
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathOverride(outside, bytes32("outside new rails"));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Governance: breath rails (7-day timelock)
    // ══════════════════════════════════════════════════════════════════════

    function test_Rails_CannotBeSetBelowTheAbsoluteFloor() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.BelowMinimum.selector);
        bulls.proposeBreathRails(ABSOLUTE_BREATH_FLOOR - 1, BREATH_MAX, bytes32("too low"));
    }

    function test_Rails_CannotBeSetAboveTheAbsoluteCeiling() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeBreathRails(ABSOLUTE_BREATH_FLOOR, ABSOLUTE_BREATH_CEILING + 1, bytes32("too high"));
    }

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

    function test_PrizeRate_DefaultsToFull() public view {
        assertEq(bulls.prizeRateMultiplier(), 10000, "starts at 100%");
    }

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

    function test_PrizeRate_IncreaseRejectsAboveTheCeiling() public {
        _bootstrapAndStart();
        bulls.proposePrizeRateReduction(9000, bytes32("cut first"));
        vm.warp(block.timestamp + PRIZE_RATE_TIMELOCK + 1);
        bulls.executePrizeRateReduction();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposePrizeRateIncrease(10001, bytes32("above full"));
    }

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
