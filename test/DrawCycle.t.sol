// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "./BullsEthBase.t.sol";
import {BullsEth} from "../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../src/IBullsEthCRE.sol";

/// @notice End-to-end happy-path draw cycle.
/// @dev    HAND-TRACED, NOT YET EXECUTED (the Foundry binary host was blocked in the
///         authoring environment). The distribution is engineered so the cutoff maths
///         is deterministic:
///           - player i commits prediction (BASE_PREDICTION + i)
///           - resolved price is exactly BASE_PREDICTION * 1e6 (= 3000e8)
///           - so player i's diff == i * 1e6
///         With 500 single-ticket casuals, snapshotTotalEntries == 500, and cutoffs
///         (9e6, 39e6, 99e6) with counts (10, 40, 100) fall inside every bound:
///           T1 10/500 = 200bps, T2 40/500 = 800bps, T3 100/500 = 2000bps.
///         If a bound or reconciliation constant differs in your build, treat this as a
///         fixture to retune, not a contract bug, and adjust the three cutoffs/counts.
contract DrawCycleTest is BullsEthBase {
    function test_FullDrawCycle_HappyPath() public {
        _bootstrapAndStart();
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.ACTIVE));
        assertEq(bulls.currentDraw(), 1);

        // All 500 committed casuals buy one ticket in draw 1 (commitment credit covers it).
        _buyAllPlayers(1);

        // Wait out the cooldown, then resolve.
        _warpToCooldownEnd();
        _resolvePinned();

        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION));
        assertEq(bulls.snapshotTotalEntries(), 500);
        _assertSolvent();

        // Submit the hand-traced cutoffs. diff_i = i * 1e6.
        // t1: i<=9  -> 10 winners; t2: i<=39 -> 40; t3: i<=99 -> 100.
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.MATCHING));

        // Advance matching -> distribution -> finalization via the phase dispatcher.
        for (uint256 i = 0; i < 12 && bulls.drawPhase() != IBullsEthCRE.DrawPhase.IDLE; i++) {
            bulls.completeDrawStep();
        }

        // Draw 1 finalized; the game is back to IDLE on draw 2.
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.IDLE));
        assertEq(bulls.currentDraw(), 2);
        _assertSolvent();
    }

    function _assertSolvent() internal view {
        (,, bool isSolvent) = bulls.getSolvencyStatus();
        assertTrue(isSolvent, "SYNC solvency invariant violated");
    }
}
