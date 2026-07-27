// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @notice H-06 (breath rail release) and H-04 (VC seniority at close).
///
/// H-06 in one line: `breathRailMin` is a prize-experience floor, but it was being
/// applied as if it were a solvency constraint, so the contract was REQUIRED to
/// distribute about 0.9% of the pot every draw even when doing so breached
/// `requiredEndPot`. `ABSOLUTE_BREATH_FLOOR` put a hard bottom under it that not even
/// governance could lower, and the distress branch returned `breathRailMin` too, so the
/// solver spent hardest at the exact moment it should have stopped.
contract BreathSolvencyTest is SmartEarnBase {
    uint256 internal constant SEED_BPS = 1000;
    uint256 internal constant RAIL_MIN = 100; // ABSOLUTE_BREATH_FLOOR, 1%

    // ══════════════════════════════════════════════════════════════════════
    //  PART 1: the algorithm, fuzzed
    // ══════════════════════════════════════════════════════════════════════
    //
    // HONESTY NOTE, read before trusting these. Part 1 fuzzes a MIRROR of
    // _simGeomPot and _solveGeometricBps, because both are internal and cannot be
    // called from a test. It proves the ALGORITHM is now correct. It does not prove
    // the contract wires it up. Part 2 does that, on the real contract, and the two
    // together are the claim. The mirror is transcribed line for line and any drift
    // between it and the contract would be a real risk, so it is kept short.

    /// @dev Exact mirror of _simGeomPot.
    function _simGeom(uint256 pot, uint256 breathBps, uint256 n, uint256 rev)
        internal pure returns (uint256)
    {
        for (uint256 i = 0; i < n; i++) {
            uint256 lost = (pot * breathBps * (10000 - SEED_BPS)) / 100_000_000;
            pot = pot > lost ? pot - lost : 0;
            pot += rev;
        }
        return pot;
    }

    /// @dev Mirror of _solveGeometricBps AFTER the H-06 fix.
    function _solveFixed(uint256 pot, uint256 drawsLeft, uint256 floorV, uint256 rev)
        internal pure returns (uint256)
    {
        if (drawsLeft == 0 || pot == 0) return RAIL_MIN;
        uint256 projEnd = pot + rev * drawsLeft;
        if (projEnd <= floorV) return 0; // was: RAIL_MIN
        uint256 lo = 0;
        uint256 hi = 1500; // breathRailMax default
        for (uint256 i = 0; i < 24; i++) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_simGeom(pot, mid, drawsLeft, rev) >= floorV) lo = mid;
            else hi = mid - 1;
        }
        if (lo < RAIL_MIN) return lo; // was: return RAIL_MIN
        if (lo > 1500) return 1500;
        return lo;
    }

    /// @dev Mirror of the PRE-fix behaviour, for the differential test below.
    function _solveOld(uint256 pot, uint256 drawsLeft, uint256 floorV, uint256 rev)
        internal pure returns (uint256)
    {
        if (drawsLeft == 0 || pot == 0) return RAIL_MIN;
        uint256 projEnd = pot + rev * drawsLeft;
        if (projEnd <= floorV) return RAIL_MIN;
        uint256 lo = 0;
        uint256 hi = 1500;
        for (uint256 i = 0; i < 24; i++) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_simGeom(pot, mid, drawsLeft, rev) >= floorV) lo = mid;
            else hi = mid - 1;
        }
        if (lo < RAIL_MIN) return RAIL_MIN;
        if (lo > 1500) return 1500;
        return lo;
    }

    /// @notice THE PROPERTY. Whatever the solver returns must leave the pot at or above
    ///         the floor, for every reachable input. This is the guarantee Craig believed
    ///         the breathing already provided.
    function testFuzz_H06_SolverAnswerAlwaysHoldsTheFloor(
        uint256 potRaw,
        uint256 floorRaw,
        uint256 revRaw,
        uint8 drawsRaw
    ) public pure {
        uint256 pot   = bound(potRaw,   1_000e6, 5_000_000e6);
        uint256 floorV= bound(floorRaw, 1_000e6, 5_000_000e6);
        uint256 rev   = bound(revRaw,   0,          50_000e6);
        uint256 draws = bound(uint256(drawsRaw), 1, 29);

        uint256 b = _solveFixed(pot, draws, floorV, rev);
        uint256 end = _simGeom(pot, b, draws, rev);

        // Either the floor is genuinely unreachable (distress, breath 0, nothing more
        // the solver can do) or the answer holds the floor.
        if (pot + rev * draws > floorV) {
            assertGe(end, floorV, "H-06: solver answer must hold requiredEndPot");
        } else {
            assertEq(b, 0, "H-06: unreachable floor must distribute nothing, not rail min");
        }
    }

    /// @notice DIFFERENTIAL. The same inputs under the old rule. Every case where the
    ///         old code breaches the floor and the new code does not is a case H-06
    ///         would have cost real money. Counts them so the finding is quantified
    ///         rather than asserted.
    function testFuzz_H06_OldRuleBreachesWhereNewRuleHolds(
        uint256 potRaw,
        uint256 floorRaw,
        uint256 revRaw,
        uint8 drawsRaw
    ) public {
        uint256 pot   = bound(potRaw,   50_000e6, 500_000e6);
        uint256 floorV= bound(floorRaw, 50_000e6, 500_000e6);
        uint256 rev   = bound(revRaw,   0,          5_000e6);
        uint256 draws = bound(uint256(drawsRaw), 5, 29);

        uint256 endNew = _simGeom(pot, _solveFixed(pot, draws, floorV, rev), draws, rev);
        uint256 endOld = _simGeom(pot, _solveOld(pot, draws, floorV, rev), draws, rev);

        // The new rule is never worse than the old one.
        assertGe(endNew, endOld, "H-06: fixed solver must never end below the old one");

        // And where the floor was reachable at all, the new rule holds it.
        if (pot + rev * draws > floorV) {
            assertGe(endNew, floorV, "H-06: fixed solver holds the floor");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  MIRROR DRIFT GUARD
    // ══════════════════════════════════════════════════════════════════════
    //
    // The fuzz tests above are only worth anything if _simGeom stays identical to the
    // contract's _simGeomPot. Nothing enforced that. If someone edits the contract's
    // arithmetic, the mirror silently diverges and the fuzz keeps passing while testing
    // a function that no longer exists. That is a worse failure than having no fuzz at
    // all, because it looks like coverage.
    //
    // checkSolvency() is external and calls the REAL _simGeomPot, so it can be used to
    // pin the mirror. This test reconstructs checkSolvency's whole calculation from
    // public state using _simGeom, and asserts it agrees with the contract. If the two
    // implementations ever drift, this fails and the fuzz results become suspect.

    /// @dev Mirror of _computeTargetReturnBps, needed to reconstruct checkSolvency.
    function _targetReturnBps(uint256 ratioBps) internal pure returns (uint256) {
        if (ratioBps <= 2000) return 5000;
        uint256 reduction = ((ratioBps - 2000) * 4000) / 8000;
        return reduction < 5000 ? 5000 - reduction : 1000;
    }

    function test_MirrorMatchesTheContractsRealSimGeomPot() public {
        // PREGAME only, which is what checkSolvency requires. Vary the state so the
        // mirror is exercised at more than one point.
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        _assertMirrorAgrees("500 casuals, no OGs");

        for (uint256 i = 0; i < 10; i++) {
            address og = _newFundedPlayer(70_000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + i, BASE_PREDICTION + 500 + i);
        }
        _assertMirrorAgrees("500 casuals, 10 upfront OGs");

        for (uint256 i = 0; i < 40; i++) {
            address og = _newFundedPlayer(80_000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + i, BASE_PREDICTION + 500 + i);
        }
        _assertMirrorAgrees("500 casuals, 50 upfront OGs");
    }

    function _assertMirrorAgrees(string memory label) internal view {
        // Reconstruct checkSolvency() exactly, from public state, using the mirror.
        uint256 maxOGs = bulls.upfrontOGCount() + bulls.earnedOGCount();
        uint256 obligation = maxOGs * bulls.OG_UPFRONT_COST();
        uint256 committed = bulls.committedPlayerCount();
        uint256 curTargetBps = committed > 0
            ? _targetReturnBps((maxOGs * 10000) / committed)
            : bulls.MAX_TARGET_RETURN_BPS();
        uint256 vcUnreleased = VC_SEED > bulls.seedReleased() ? VC_SEED - bulls.seedReleased() : 0;
        uint256 floorV = (obligation * curTargetBps) / 10000 + bulls.DRAW30_PRIZE_RESERVE() + vcUnreleased;

        uint256 casualCount = committed > maxOGs ? committed - maxOGs : 0;
        uint256 dbl = bulls.committedDoubleCount() < casualCount ? bulls.committedDoubleCount() : casualCount;
        uint256 rev = ((casualCount - dbl + dbl * 2) * bulls.TICKET_PRICE() * (10000 - bulls.TREASURY_BPS())) / 10000;

        // THE PIN: our mirror, against the contract's real _simGeomPot.
        uint256 mirrorEnd = _simGeom(bulls.prizePot(), bulls.breathRailMin(), bulls.TOTAL_DRAWS(), rev);

        (bool solventOnChain, uint256 deficitOnChain) = bulls.checkSolvency();
        bool solventMirror = mirrorEnd >= floorV;

        assertEq(
            solventMirror,
            solventOnChain,
            string.concat("MIRROR DRIFT: _simGeom disagrees with _simGeomPot at: ", label)
        );
        if (!solventOnChain) {
            uint256 expected = (floorV - mirrorEnd) / bulls.TOTAL_DRAWS() + 1;
            assertEq(deficitOnChain, expected, string.concat("MIRROR DRIFT on deficit at: ", label));
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PART 2: the contract, wired up
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Drives the game into distress: the game starts on a healthy revenue
    ///      estimate, then casual buying stops entirely. Only the upfront OGs remain,
    ///      and they pay nothing per draw, so real revenue is zero while the EMA
    ///      decays. This is the shape H-06 describes.
    function _startWithUpfrontOGsAndStall(uint256 ogCount) internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < ogCount; i++) {
            address og = _newFundedPlayer(50_000 + i);
            vm.prank(og);
            bulls.register();
            vm.prank(og);
            // Spread OG predictions so cutoffs remain satisfiable with casuals absent.
            bulls.registerAsOG(BASE_PREDICTION + i, BASE_PREDICTION + 1000 + i);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ethFeed.latestAnswer()); // [v1.15] feed heartbeat
        bulls.startGame();
    }

    /// @notice THE FIX, on the real contract. Before v1.14, breathMultiplier could never
    ///         fall below ABSOLUTE_BREATH_FLOOR (100 bps) under any circumstances, so the
    ///         contract was forced to keep spending into a collapse. It can now reach zero.
    ///
    ///         Measured trajectory in this scenario, revenue stopping dead after start:
    ///         550, 264, 199, 149, 110, 80, 56, 38, 25, 15, 7, 1, 0.
    ///         The rail is crossed at draw 5 and the pot stabilises instead of bleeding.
    function test_H06_BreathCanNowFallBelowTheOldHardFloor() public {
        _startWithUpfrontOGsAndStall(50);

        uint256 lowest = type(uint256).max;
        for (uint256 d = 0; d < 14; d++) {
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(2e6, 8e6, 20e6, 3, 9, 21);
            for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) {
                bulls.completeDrawStep();
            }
            uint256 b = bulls.breathMultiplier();
            if (b < lowest) lowest = b;
        }

        assertLt(lowest, RAIL_MIN, "H-06: breath went below the old hard floor of 100 bps");
        assertEq(bulls.breathMultiplier(), 0, "H-06: and reached zero, distributing nothing");
    }

    /// @notice The pot must STABILISE rather than bleed. This is the value the fix
    ///         preserves. Pinned at the old rail the pot loses ~0.9% every draw forever;
    ///         released, it converges once breath reaches zero.
    function test_H06_PotStabilisesInsteadOfBleeding() public {
        _startWithUpfrontOGsAndStall(50);

        for (uint256 d = 0; d < 14; d++) {
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(2e6, 8e6, 20e6, 3, 9, 21);
            for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) {
                bulls.completeDrawStep();
            }
        }
        uint256 potA = bulls.prizePot();

        // Three more dry draws. With breath at zero the pot must not move materially.
        for (uint256 d = 0; d < 3; d++) {
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(2e6, 8e6, 20e6, 3, 9, 21);
            for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) {
                bulls.completeDrawStep();
            }
        }
        uint256 potB = bulls.prizePot();

        assertApproxEqRel(potB, potA, 0.001e18, "H-06: pot has stabilised, not bleeding");

        // What the old rail would have done to the same pot over those three draws.
        uint256 wouldHaveBeen = _simGeom(potA, RAIL_MIN, 3, 0);
        assertGt(potB, wouldHaveBeen, "H-06: strictly better than the pinned rail");
        emit log_named_uint("pot held      (6dp USDC)", potB);
        emit log_named_uint("pot if pinned (6dp USDC)", wouldHaveBeen);
    }

    /// @notice HONEST RESIDUAL, asserted so it is not forgotten. The rail release stops
    ///         the bleeding but does NOT fully hold requiredEndPot in a hard collapse,
    ///         because avgNetRevenuePerDraw is an exponential moving average and lags a
    ///         collapse by roughly four draws. The solver spends the headroom on revenue
    ///         that never arrives before the estimate catches up, and with no revenue that
    ///         is unrecoverable. Logged as finding H-07. This test records the size of the
    ///         residual so a future change can be measured against it.
    function test_H07_EmaLagLeavesAResidualShortfall() public {
        _startWithUpfrontOGsAndStall(50);

        for (uint256 d = 0; d < 14; d++) {
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(2e6, 8e6, 20e6, 3, 9, 21);
            for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) {
                bulls.completeDrawStep();
            }
        }

        uint256 pot = bulls.prizePot();
        uint256 floorV = bulls.requiredEndPot();

        // The residual exists. Bound it so a regression that widens it is caught.
        assertLt(pot, floorV, "H-07: residual shortfall is real, not theoretical");
        assertGt(pot * 10000 / floorV, 9700, "H-07: but it stays within 3% of the floor");

        emit log_named_uint("pot            (6dp USDC)", pot);
        emit log_named_uint("requiredEndPot (6dp USDC)", floorV);
        emit log_named_uint("shortfall      (6dp USDC)", floorV - pot);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  H-04: VC ranks above OGs at close, matching dormancy
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The investor's unreturned principal must be reserved out of the pot
    ///         BEFORE the OG endgame payout is computed, so both settlement paths
    ///         agree on seniority.
    function test_H04_VcPrincipalIsReservedBeforeOgPayout() public {
        _startWithUpfrontOGsAndStall(50);

        // Run the full season so the game reaches CLOSED.
        for (uint256 d = 0; d < 30; d++) {
            if (uint256(bulls.gamePhase()) != 1) break; // 1 == ACTIVE
            _warpToCooldownEnd();
            _resolvePinned();
            bulls.submitCutoffDiffs(2e6, 8e6, 20e6, 3, 9, 21);
            for (uint256 i = 0; i < 25 && uint256(bulls.drawPhase()) != 0; i++) {
                bulls.completeDrawStep();
            }
        }

        uint256 unreleased = VC_SEED - bulls.seedReleased();
        bulls.closeGame();

        assertGe(
            bulls.vcReturnOwed(),
            unreleased,
            "H-04: full unreturned VC principal is owed at close"
        );

        // And it is actually payable, not just recorded.
        uint256 before = usdc.balanceOf(vcWallet);
        bulls.claimVCReturn();
        assertGe(
            usdc.balanceOf(vcWallet) - before,
            unreleased,
            "H-04: the VC can actually withdraw it"
        );
    }
}
