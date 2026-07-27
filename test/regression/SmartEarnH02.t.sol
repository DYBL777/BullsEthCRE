// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @notice H-02 regression suite. Asserts the FIXED behaviour, post-v1.13 clamp.
///
/// THE INVARIANT under test, which the constructor's VC-SPENT-CAP guard silently
/// assumes and which v1.09 broke:
///
///     seedReleased <= cumulativeSeasonTreasury * MAX_SEED_RELEASE_RATIO_BPS / 10000
///
/// If that holds at every point then _vcTreasuryObligation(), at most seedReleased
/// * 1.5, can never exceed the treasury earned to fund it.
///
/// Measured before the fix (v1.12): one draw released $1,552.37 of seed against a
/// ratio ceiling of $0, producing a $1,940.46 obligation against a $1,250.00
/// treasury. A $690.46 shortfall after a single draw.
contract SmartEarnH02Test is SmartEarnBase {
    /// @dev The single assertion everything else exists to protect.
    function _assertRatioInvariant(string memory whenLabel) internal view {
        assertLe(
            bulls.seedReleased(),
            _ratioCeiling(),
            string.concat("H-02 invariant broken at: ", whenLabel)
        );
    }

    /// @dev The consequence of the invariant: the obligation is always fundable.
    function _assertObligationFundable(string memory whenLabel) internal view {
        assertLe(
            _vcObligation(),
            bulls.treasuryBalance(),
            string.concat("VC obligation exceeds treasury at: ", whenLabel)
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The fix itself
    // ══════════════════════════════════════════════════════════════════════
    function test_H02_NoSeedReleasedWithoutRatioBacking() public {
        _bootstrapAndStart();

        assertEq(bulls.cumulativeSeasonTreasury(), 0, "no in-season treasury before draw 1");
        _assertRatioInvariant("start of draw 1");

        _runStandardDraw();
        assertEq(bulls.currentDraw(), 2, "draw 1 finalised");

        // Draw-1 buys are covered by pregame commitment credit, so no in-season
        // treasury accrued and the ceiling is zero. The T3 floor must therefore
        // release nothing, where before the fix it released $1,552.37.
        assertEq(bulls.cumulativeSeasonTreasury(), 0, "still no in-season treasury");
        assertEq(bulls.seedReleased(), 0, "T3 floor correctly released nothing");
        _assertRatioInvariant("end of draw 1");
        _assertObligationFundable("end of draw 1");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The invariant holds across the whole cold-start window
    // ══════════════════════════════════════════════════════════════════════
    // The T3 floor is only eligible while currentDraw <= WITHDRAW_START_DRAW (5).
    // From draw 2 onwards casuals pay real USDC, so cumulativeSeasonTreasury grows
    // and the ceiling lifts off zero. This walks the entire eligible window and
    // checks the invariant after every single draw.
    function test_H02_InvariantHoldsAcrossTheEntireColdStartWindow() public {
        _bootstrapAndStart();

        for (uint256 d = 1; d <= WITHDRAW_START_DRAW; d++) {
            _runStandardDraw();
            _assertRatioInvariant(string.concat("after draw ", vm.toString(d)));
            _assertObligationFundable(string.concat("after draw ", vm.toString(d)));
        }

        assertEq(bulls.currentDraw(), WITHDRAW_START_DRAW + 1, "walked the full window");

        // By now real treasury has accrued, so the ceiling is genuinely non-zero and
        // the invariant is being tested against something, not trivially satisfied.
        assertGt(
            bulls.cumulativeSeasonTreasury(),
            0,
            "in-season treasury accrued once players paid rather than used credit"
        );
        assertGt(_ratioCeiling(), 0, "so the ratio ceiling is a real bound by now");

        emit log_named_uint("season treasury (6dp USDC)", bulls.cumulativeSeasonTreasury());
        emit log_named_uint("ratio ceiling   (6dp USDC)", _ratioCeiling());
        emit log_named_uint("seed released   (6dp USDC)", bulls.seedReleased());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Any release that does happen stays fundable
    // ══════════════════════════════════════════════════════════════════════
    function test_H02_ObligationNeverExceedsTreasury() public {
        _bootstrapAndStart();

        for (uint256 d = 1; d <= WITHDRAW_START_DRAW; d++) {
            _runStandardDraw();
        }

        _assertObligationFundable("end of cold-start window");

        emit log_named_uint("VC obligation    (6dp USDC)", _vcObligation());
        emit log_named_uint("treasury balance (6dp USDC)", bulls.treasuryBalance());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The accepted consequence, asserted rather than left implicit
    // ══════════════════════════════════════════════════════════════════════
    // The clamp materially weakens the cold-start floor in draw 1. That is a
    // deliberate trade and it is recorded here so a future reader does not
    // "restore" the old behaviour thinking it was an oversight.
    function test_H02_ColdStartFloorIsSuppressedInDrawOneByDesign() public {
        _bootstrapAndStart();
        _runStandardDraw();

        assertEq(
            bulls.seedReleased(),
            0,
            "cold-start floor cannot fire in draw 1: no earned treasury backs it, by design"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The supplement path is unaffected by the fix
    // ══════════════════════════════════════════════════════════════════════
    function test_H02_SupplementPathGatesUnchanged() public {
        _bootstrapAndStart();
        _runStandardDraw();

        (uint256 ratioBps,,,, bool thresholdMet,,) = bulls.getSeedReleaseStatus();
        assertEq(ratioBps, 0, "supplement governance still defaults to off");
        assertFalse(thresholdMet, "SEED_RELEASE_THRESHOLD still gates the supplement");
    }
}
