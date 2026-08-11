// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Reset refund paths
/// @notice The two money routes that exist ONLY after an emergency reset, and neither had
///         any coverage. `claimCommitmentRefund` gives a pregame commitment back to a player
///         whose draw was voided before they ever played. `sweepResetRefundRemainder` closes
///         the pools out once their 30-day window expires.
///
/// @dev    Both drain pools that sit inside the contract's balance accounting
///         (`commitmentRefundPool`, `resetDrawRefundPool`, `resetDrawRefundPool2` are all in
///         the SYNC list). Untested drains of tracked pools are how a balance check starts
///         disagreeing with reality.
///
///         THE FIXTURE POINT, and it is not obvious: a player who BUYS in draw 1 spends
///         their commitment credit, and `buyTickets` clears `commitmentPaid` when it does.
///         `claimCommitmentRefund` requires `commitmentPaid`, so a buyer is NOT eligible.
///         Only a player who committed in pregame and then never bought can claim. But
///         `resolveWeek` refuses a draw with no entries at all, so some players must buy for
///         the draw to be resolvable and resettable in the first place.
///
///         So the fixture splits the field: 100 buy (making the draw real), 400 do not
///         (staying eligible). That split is the whole reason this path is awkward to reach
///         and, presumably, the reason it was never tested.
contract ResetRefundsTest is SmartEarnBase {
    uint256 internal constant BUYERS = 100;

    /// @dev Committed net value of one single commitment, which is what one claimant is owed.
    function _commitmentNet() internal view returns (uint256) {
        return TICKET_PRICE * (10000 - TREASURY_BPS) / 10000; // $7.50
    }

    /// @dev Drives draw 1 into MATCHING with a partial field, then stalls it out and resets.
    ///      Leaves the contract in RESET_FINALIZING with both refund pools funded.
    ///
    ///      Cutoffs are sized for the 100-entry snapshot this fixture produces, NOT the usual
    ///      500: on 100 entries, counts of 2 / 6 / 15 read as 200 / 600 / 1500 bps, inside
    ///      T1 [50,400], T2 [400,1200] and T3 [1000,5000]. Diffs follow the same ladder, so
    ///      entry i has diff exactly i * 1e6.
    function _resetDrawOne() internal {
        for (uint256 i = 0; i < BUYERS; i++) {
            vm.prank(players[i]); bulls.buyTickets(1);
            vm.prank(players[i]); bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(1e6, 5e6, 14e6, 2, 6, 15); // -> MATCHING, then stall

        vm.warp(block.timestamp + bulls.DRAW_STUCK_TIMEOUT() + 1);
        bulls.emergencyResetDraw();
    }

    /// @dev Finishes the reset so the game returns to IDLE at draw 2.
    function _finishReset() internal {
        for (uint256 i = 0; i < 20; i++) {
            if (uint256(bulls.drawPhase()) == uint256(IBullsEthCRE.DrawPhase.IDLE)) break;
            bulls.completeDrawStep();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  claimCommitmentRefund
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A player who paid a pregame commitment and never got to play gets it back,
    ///         net of the treasury slice. They funded a draw that was voided before it
    ///         reached them, so the money is theirs.
    function test_Commitment_ANonBuyerIsRefundedTheirNetCommitment() public {
        _bootstrapAndStart();
        _resetDrawOne();

        assertGt(bulls.commitmentRefundPool(), 0, "precondition: the reset funded a pool");

        address claimant = players[300]; // never bought, so still holds the credit
        uint256 before = usdc.balanceOf(claimant);

        vm.prank(claimant);
        bulls.claimCommitmentRefund();

        assertEq(
            usdc.balanceOf(claimant) - before,
            _commitmentNet(),
            "refunded exactly the net commitment, treasury slice retained"
        );
    }

    /// @notice The pool falls by exactly what was paid out. A drain that outpaces the payment
    ///         is how a pool empties early and later claimants are refused money that exists.
    function test_Commitment_ThePoolFallsByExactlyWhatIsPaid() public {
        _bootstrapAndStart();
        _resetDrawOne();

        uint256 poolBefore = bulls.commitmentRefundPool();
        address claimant = players[300];
        uint256 balBefore = usdc.balanceOf(claimant);

        vm.prank(claimant);
        bulls.claimCommitmentRefund();

        uint256 paid = usdc.balanceOf(claimant) - balBefore;
        assertEq(bulls.commitmentRefundPool(), poolBefore - paid, "drawdown equals payout exactly");
    }

    /// @notice A player who BOUGHT in draw 1 is not eligible, and this is the fixture point
    ///         made into an assertion. Buying spends the commitment credit and clears
    ///         `commitmentPaid`, so there is nothing left to refund: their ticket money is
    ///         covered by the separate reset refund pool instead.
    function test_Commitment_ABuyerIsNotEligible() public {
        _bootstrapAndStart();
        _resetDrawOne();

        // NARROWER THAN THE NAME, deliberately. buyTickets clears commitmentPaid at TWO
        // sites and only this one is unconditional: at draw 1 the credit is SPENT, so the
        // flag always goes. The draw-2+ site clears it as EXPIRED but only when no refund
        // pool exists, which means a player who buys again AFTER a reset keeps the flag and
        // stays eligible. That is deliberate in the contract (its own comment says so) and
        // is a separate case, logged in the backlog rather than asserted here.
        vm.prank(players[0]); // bought in draw 1, credit spent
        vm.expectRevert(IBullsEthCRE.ResetRefundNotEligible.selector);
        bulls.claimCommitmentRefund();
    }

    function test_Commitment_RevertsOnASecondClaim() public {
        _bootstrapAndStart();
        _resetDrawOne();

        address claimant = players[300];
        vm.prank(claimant);
        bulls.claimCommitmentRefund();

        vm.prank(claimant);
        vm.expectRevert(IBullsEthCRE.ResetRefundNotEligible.selector);
        bulls.claimCommitmentRefund();
    }

    /// @notice THE 30-DAY WINDOW CLOSES. Past the deadline the claim is refused, because the
    ///         remainder is about to be swept and paying out after that point would mean
    ///         paying from a pool the contract no longer accounts for.
    function test_Commitment_RevertsOnceTheWindowHasClosed() public {
        _bootstrapAndStart();
        _resetDrawOne();

        vm.warp(block.timestamp + bulls.RESET_REFUND_WINDOW() + 1);

        vm.prank(players[300]);
        vm.expectRevert(IBullsEthCRE.ResetRefundExpired.selector);
        bulls.claimCommitmentRefund();
    }

    /// @notice And with no reset having happened there is no pool at all, so the whole path
    ///         is inert during a normal season.
    function test_Commitment_RevertsWithNoPoolInANormalSeason() public {
        _bootstrapAndStart();

        vm.prank(players[300]);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimCommitmentRefund();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  sweepResetRefundRemainder
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Nothing may be swept while a claimant could still turn up. The window is the
    ///         only thing standing between a slow claimant and their money being reallocated.
    function test_Sweep_RefusesWhileTheWindowsAreStillOpen() public {
        _bootstrapAndStart();
        _resetDrawOne();

        // PRECONDITION, and the test is vacuous without it: NothingToClaim is also what a
        // reset that funded nothing would produce. Asserting the pools are real first is
        // what makes this "too early" rather than "there was never anything here".
        assertGt(bulls.commitmentRefundPool(), 0, "a commitment pool exists to be swept");
        assertGt(bulls.resetDrawRefundPool(), 0, "and a ticket pool alongside it");

        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.sweepResetRefundRemainder();
    }

    /// @notice While the game is still ACTIVE the unclaimed remainder goes back into the
    ///         PRIZE POT, not to the protocol. Money that players put in and did not reclaim
    ///         stays in the game and is paid out to players in later draws.
    ///
    /// @dev    Asserted as exact conservation across both pools rather than a floor on the
    ///         pot, so it fails if either pool's remainder goes astray.
    function test_Sweep_ReturnsRemaindersToThePotWhileTheGameRuns() public {
        _bootstrapAndStart();
        _resetDrawOne();
        _finishReset(); // back to IDLE at draw 2, still ACTIVE

        uint256 commitRemainder = bulls.commitmentRefundPool();
        uint256 resetRemainder  = bulls.resetDrawRefundPool();
        assertGt(commitRemainder, 0, "precondition: a commitment remainder exists");
        assertGt(resetRemainder, 0, "precondition: a ticket remainder exists too");

        uint256 potBefore = bulls.prizePot();
        vm.warp(block.timestamp + bulls.RESET_REFUND_WINDOW() + 1);
        bulls.sweepResetRefundRemainder();

        assertEq(
            bulls.prizePot(),
            potBefore + commitRemainder + resetRemainder,
            "both remainders returned to the pot, exactly and in full"
        );
    }

    /// @notice And the pools are cleared rather than left holding a figure that is no longer
    ///         backed. Both the amount and the draw marker go, so nothing can claim against
    ///         them afterwards.
    function test_Sweep_ClearsThePoolsAndTheirMarkers() public {
        _bootstrapAndStart();
        _resetDrawOne();
        _finishReset();

        vm.warp(block.timestamp + bulls.RESET_REFUND_WINDOW() + 1);
        bulls.sweepResetRefundRemainder();

        assertEq(bulls.commitmentRefundPool(), 0, "commitment pool cleared");
        assertEq(bulls.commitmentRefundDraw(), 0, "and its draw marker");
        assertEq(bulls.commitmentRefundDeadline(), 0, "and its deadline, which gates the sweep");
        assertEq(bulls.resetDrawRefundPool(), 0, "reset pool cleared");
        assertEq(bulls.resetDrawRefundDraw(), 0, "and its draw marker");
        assertEq(bulls.resetDrawRefundDeadline(), 0, "and its deadline too");
    }

    /// @notice THE DESTINATION FLIPS ON PHASE. Once the game is DORMANT or CLOSED there is no
    ///         longer a season to pay the money back into, so an unclaimed remainder goes to
    ///         the beneficiary instead of the pot. Same function, opposite recipient, decided
    ///         entirely by what phase the game is in when it is called.
    ///
    /// @dev    The ordering is deliberate and a little delicate: the 30-day window has to
    ///         expire BEFORE dormancy is activated, because activation requires the game to
    ///         still be ACTIVE and IDLE.
    function test_Sweep_PaysTheBeneficiaryOnceTheGameIsDormant() public {
        _bootstrapAndStart();
        _resetDrawOne();
        _finishReset();

        // Let the refund window lapse while the game is still running.
        vm.warp(block.timestamp + bulls.RESET_REFUND_WINDOW() + 1);

        uint256 commitRemainder = bulls.commitmentRefundPool();
        uint256 resetRemainder  = bulls.resetDrawRefundPool();
        assertGt(commitRemainder + resetRemainder, 0, "precondition: something is left to sweep");

        // Then wind the game down. NOTE the warp is FORWARD from here, not to an absolute
        // slot: lastDrawTimestamp was re-anchored at reset-finalize and the 30-day window
        // above has already carried the clock well past it, so
        // `warp(lastDrawTimestamp + PICK_DEADLINE + 1)` would jump BACKWARDS to before
        // dormancyEffectiveTime and revert TooEarly. The pick-deadline condition is already
        // satisfied by the 30 days; only the 24h timelock still has to elapse.
        bulls.proposeDormancy();
        vm.warp(block.timestamp + bulls.DORMANCY_TIMELOCK() + 1);
        bulls.activateDormancy();

        // Read from the contract rather than a fixture variable: PROTOCOL_BENEFICIARY is a
        // public immutable and cannot drift from what the sweep actually pays.
        address payee = bulls.PROTOCOL_BENEFICIARY();
        uint256 beneficiaryBefore = usdc.balanceOf(payee);
        bulls.sweepResetRefundRemainder();

        assertEq(
            usdc.balanceOf(payee) - beneficiaryBefore,
            commitRemainder + resetRemainder,
            "with no season left to fund, the remainder goes to the beneficiary"
        );
    }

    /// @notice The sweep is PERMISSIONLESS. It has no owner gate, deliberately: it is
    ///         housekeeping that anyone can trigger once the window has closed, so a
    ///         disengaged operator cannot strand the money indefinitely.
    function test_Sweep_CanBeCalledByAnyone() public {
        _bootstrapAndStart();
        _resetDrawOne();
        _finishReset();

        vm.warp(block.timestamp + bulls.RESET_REFUND_WINDOW() + 1);

        address stranger = _newFundedPlayer(75001);
        vm.prank(stranger);
        bulls.sweepResetRefundRemainder();

        assertEq(bulls.commitmentRefundPool(), 0, "a stranger completed the housekeeping");
    }
}
