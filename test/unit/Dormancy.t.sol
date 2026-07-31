// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "../base/BullsEthBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Dormancy, the early-shutdown waterfall
/// @notice The path that decides who gets paid what if the game winds down before its
///         season completes. Four claimant classes, five pools, strict seniority.
///
/// @dev    This had no coverage at all before this file. It is the highest-value gap in
///         the suite because it is the only path where every participant class is repaid
///         at once, and because the ordering between them is a promise made to an investor
///         and to committed players rather than an implementation detail.
///
///         Pools, senior first:
///           TIER 0  dormancyVCPool          unreleased VC seed
///           TIER 1  dormancyOGPool          upfront OG principal, pro-rata by unplayed draws
///           TIER 2  dormancyCasualRefundPool current-draw ticket refunds
///           TIER 3  dormancyCommitmentPool  commitment refunds for players who never played
///           TIER 4  dormancyPerHeadPool     remainder, split per claimable head
contract DormancyTest is BullsEthBase {
    uint256 internal constant DORMANCY_TIMELOCK = 24 hours;
    uint256 internal constant DORMANCY_CLAIM_WINDOW = 90 days;

    address internal ogA;
    address internal ogB;
    address internal wog;

    /// @dev Computed expectations, so assertions can be exact rather than `> 0`.
    ///      Net of the non-refundable treasury slice in each case.
    function _ogNetPrincipal() internal view returns (uint256) {
        return OG_UPFRONT_COST * (10000 - bulls.UF_OG_TREASURY_BPS()) / 10000;   // $450
    }
    function _casualNet() internal view returns (uint256) {
        return TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;                    // $7.50
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev activateDormancy needs BOTH the 24h timelock elapsed AND picks closed
    ///      (block.timestamp > lastDrawTimestamp + PICK_DEADLINE). PICK_DEADLINE is 48h,
    ///      so it is the binding constraint, not the timelock.
    function _proposeAndActivate() internal {
        bulls.proposeDormancy();
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);
        bulls.activateDormancy();
    }

    /// @dev A game with two upfront OGs, one weekly OG and 500 casuals, started and with
    ///      draw 1 bought. Gives every claim branch a live participant.
    function _startWithAllClasses() internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        ogA = _newFundedPlayer(70001);
        vm.prank(ogA); bulls.register();
        vm.prank(ogA); bulls.registerAsOG(BASE_PREDICTION + 11, BASE_PREDICTION + 12);

        ogB = _newFundedPlayer(70002);
        vm.prank(ogB); bulls.register();
        vm.prank(ogB); bulls.registerAsOG(BASE_PREDICTION + 21, BASE_PREDICTION + 22);

        wog = _newFundedPlayer(70003);
        vm.prank(wog); bulls.register();
        vm.prank(wog); bulls.registerAsWeeklyOG(BASE_PREDICTION + 31, BASE_PREDICTION + 32);

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  proposeDormancy / cancelDormancy
    // ══════════════════════════════════════════════════════════════════════

    function test_ProposeDormancy_SetsEffectiveTime() public {
        _bootstrapAndStart();
        bulls.proposeDormancy();
        assertEq(
            bulls.dormancyEffectiveTime(),
            block.timestamp + DORMANCY_TIMELOCK,
            "effective 24h out"
        );
    }

    function test_ProposeDormancy_RevertsForNonOwner() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(71001);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.proposeDormancy();
    }

    function test_ProposeDormancy_RevertsInPregame() public {
        _bootstrapCommitted(10);
        vm.expectRevert(IBullsEthCRE.GameNotActive.selector);
        bulls.proposeDormancy();
    }

    function test_ProposeDormancy_RevertsMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned(); // draw now in CUTOFF_SUBMISSION
        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.proposeDormancy();
    }

    function test_ProposeDormancy_RevertsWhenAlreadyPending() public {
        _bootstrapAndStart();
        bulls.proposeDormancy();
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.proposeDormancy();
    }

    function test_CancelDormancy_ClearsTheProposal() public {
        _bootstrapAndStart();
        bulls.proposeDormancy();
        bulls.cancelDormancy();
        assertEq(bulls.dormancyEffectiveTime(), 0, "cleared");

        // and it can be proposed again
        bulls.proposeDormancy();
        assertGt(bulls.dormancyEffectiveTime(), 0, "re-proposable");
    }

    function test_CancelDormancy_RevertsWithNothingPending() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.cancelDormancy();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  activateDormancy
    // ══════════════════════════════════════════════════════════════════════

    function test_ActivateDormancy_RevertsWithNoProposal() public {
        _bootstrapAndStart();
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.activateDormancy();
    }

    function test_ActivateDormancy_RevertsBeforeTimelockElapses() public {
        _bootstrapAndStart();
        bulls.proposeDormancy();
        vm.warp(block.timestamp + DORMANCY_TIMELOCK - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.activateDormancy();
    }

    /// @dev Players must not be able to buy into a draw that is about to be voided, so
    ///      activation is blocked until the pick window has closed.
    function test_ActivateDormancy_RevertsWhilePicksAreOpen() public {
        _bootstrapAndStart();
        bulls.proposeDormancy();
        vm.warp(block.timestamp + DORMANCY_TIMELOCK + 1); // past timelock, picks still open
        vm.expectRevert(IBullsEthCRE.PicksLocked.selector);
        bulls.activateDormancy();
    }

    function test_ActivateDormancy_SetsDormantAndStamps() public {
        _bootstrapAndStart();
        _proposeAndActivate();
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.DORMANT), "DORMANT");
        assertEq(bulls.dormancyTimestamp(), block.timestamp, "stamped");
        assertEq(bulls.dormancyEffectiveTime(), 0, "proposal consumed");
    }

    function test_ActivateDormancy_RecordsDrawsPlayed() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();
        // dormancy in draw 1 means zero completed draws
        assertEq(bulls.dormancyDrawsPlayed(), 0, "no draws completed yet");
    }

    function test_ActivateDormancy_SizesTheOgPool() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();
        // `> 0` was the first version and would pass on 1 wei. Two upfront OGs, zero draws
        // played, so each is owed their FULL net principal pro-rata by 30/30 unplayed.
        assertEq(
            bulls.dormancyOGPool(),
            2 * _ogNetPrincipal(),
            "OG pool is exactly two full net principals"
        );
        assertEq(bulls.dormancyOGPool(), bulls.dormancyOGPoolSnapshot(), "snapshot matches at activation");
    }

    function test_ActivateDormancy_SizesTheCasualPool() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();
        // Tightened from `> 0`. 500 casuals each bought one ticket this draw, so the pool
        // must cover at least their combined net cost. Asserted as a floor rather than an
        // equality because the weekly OG's current-draw cost also routes through this pool.
        assertGe(
            bulls.dormancyCasualRefundPool(),
            MIN_PLAYERS_TO_START * _casualNet(),
            "casual pool covers 500 net ticket costs at minimum"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  claimDormancyRefund, the four branches
    // ══════════════════════════════════════════════════════════════════════

    function test_Claim_RevertsWhenNotDormant() public {
        _bootstrapAndStart();
        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.GameNotDormant.selector);
        bulls.claimDormancyRefund();
    }

    /// BRANCH 1: upfront OG. Principal pro-rata by unplayed draws.
    function test_Claim_UpfrontOG_ReceivesPrincipal() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        uint256 before = usdc.balanceOf(ogA);
        vm.prank(ogA);
        bulls.claimDormancyRefund();
        uint256 got = usdc.balanceOf(ogA) - before;

        // Tightened from `> 0`, which spanned everything from 1 wei to $599.99. Zero draws
        // played, so this OG is owed their full net principal, plus ANY per-head slice of
        // the remainder, which is zero in this fixture because the pot is consumed exactly
        // by the OG and casual pools. So net principal is a hard floor and the gross stake a
        // hard ceiling.
        assertGe(got, _ogNetPrincipal(), "at least the full net principal");
        // Treasury slice is non-refundable, so a full-season stake never returns whole.
        assertLt(got, OG_UPFRONT_COST, "treasury slice is not refunded");
    }

    function test_Claim_UpfrontOG_DecrementsCount() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();
        assertEq(bulls.upfrontOGCount(), 2);

        vm.prank(ogA);
        bulls.claimDormancyRefund();
        assertEq(bulls.upfrontOGCount(), 1, "count decremented on claim");
    }

    function test_Claim_RevertsOnSecondAttempt() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        vm.prank(ogA);
        bulls.claimDormancyRefund();
        vm.prank(ogA);
        vm.expectRevert(IBullsEthCRE.AlreadyRefunded.selector);
        bulls.claimDormancyRefund();
    }

    /// BRANCH 2: weekly OG who bought this draw.
    function test_Claim_WeeklyOG_ReceivesTicketRefund() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        // NOTE: no buyTickets for wog. A weekly OG who registers in PREGAME is credited
        // for draw 1 at startGame (lastBoughtDraw = 1, lastTicketCost = 2 tickets), so
        // buying again reverts AlreadyBoughtThisWeek. They are already a live participant
        // in the draw dormancy is about to void.
        _proposeAndActivate();

        uint256 before = usdc.balanceOf(wog);
        vm.prank(wog);
        bulls.claimDormancyRefund();
        // A weekly OG pays for two entries at registration, so their current-draw net cost
        // is two tickets less treasury. Tightened from `> 0`.
        assertGe(
            usdc.balanceOf(wog) - before,
            2 * _casualNet(),
            "at least the net cost of the two entries they hold in the voided draw"
        );
    }

    /// BRANCH 3: casual who bought this draw.
    function test_Claim_Casual_ReceivesTicketRefund() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        address c = players[3];
        uint256 before = usdc.balanceOf(c);
        vm.prank(c);
        bulls.claimDormancyRefund();
        assertGe(
            usdc.balanceOf(c) - before,
            _casualNet(),
            "at least the net cost of the ticket in the voided draw"
        );
    }

    /// BRANCH 4: committed but never played. Different pool, different rule.
    function test_Claim_CommitmentOnly_ReceivesCommitmentRefund() public {
        _startWithAllClasses();
        // deliberately do NOT buy: these players committed in pregame and never played
        _proposeAndActivate();

        address c = players[7];
        uint256 before = usdc.balanceOf(c);
        vm.prank(c);
        bulls.claimDormancyRefund();
        assertGe(
            usdc.balanceOf(c) - before,
            _casualNet(),
            "at least the net commitment they never got to play"
        );
    }

    function test_Claim_RevertsForAStranger() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        address nobody = _newFundedPlayer(72001);
        vm.prank(nobody);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimDormancyRefund();
    }

    function test_Claim_RevertsAfterTheClaimWindowCloses() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        bulls.sweepDormancyRemainder(); // closes the game
        vm.prank(ogA);
        vm.expectRevert(IBullsEthCRE.DormancyWindowExpired.selector);
        bulls.claimDormancyRefund();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Seniority and conservation
    // ══════════════════════════════════════════════════════════════════════

    /// @dev THE PARTITION INVARIANT. The contract's USDC must always cover everything it
    ///      still owes: the unclaimed pools plus treasury. If this drifts, either value is
    ///      being created or somebody's refund has been stranded.
    function test_Invariant_BalanceCoversAllRemainingPools() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        _assertSolventForPools("at activation");

        vm.prank(ogA); bulls.claimDormancyRefund();
        _assertSolventForPools("after an OG claim");

        vm.prank(players[3]); bulls.claimDormancyRefund();
        _assertSolventForPools("after a casual claim");

        vm.prank(wog); bulls.claimDormancyRefund();
        _assertSolventForPools("after a weekly OG claim");
    }

    function _assertSolventForPools(string memory whenLabel) internal view {
        // treasuryBalance is included deliberately. An earlier version summed the five
        // pools only while the @dev above claimed "pools plus treasury", so the assertion
        // was weaker than its own description. Including it is the stronger invariant and
        // it should hold: after activation the balance is exactly pools plus treasury.
        uint256 owed = bulls.dormancyVCPool()
            + bulls.dormancyOGPool()
            + bulls.dormancyCasualRefundPool()
            + bulls.dormancyCommitmentPool()
            + bulls.dormancyPerHeadPool()
            + bulls.treasuryBalance();
        assertGe(
            usdc.balanceOf(address(bulls)),
            owed,
            string.concat("balance does not cover outstanding pools at: ", whenLabel)
        );
    }

    /// @dev Every claim must draw down a pool by exactly what it pays out. Pools shrinking
    ///      by more than was paid means value is being stranded.
    function test_Claim_DrawsDownPoolsByExactlyWhatItPays() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        uint256 poolsBefore = bulls.dormancyOGPool() + bulls.dormancyPerHeadPool();
        uint256 balBefore = usdc.balanceOf(ogA);

        vm.prank(ogA);
        bulls.claimDormancyRefund();

        uint256 paid = usdc.balanceOf(ogA) - balBefore;
        uint256 poolsAfter = bulls.dormancyOGPool() + bulls.dormancyPerHeadPool();
        assertEq(poolsBefore - poolsAfter, paid, "pool drawdown equals payout exactly");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  sweepDormancyRemainder
    // ══════════════════════════════════════════════════════════════════════

    function test_Sweep_RevertsBeforeTheClaimWindowCloses() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.sweepDormancyRemainder();
    }

    function test_Sweep_RevertsWhenNotDormant() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.GameNotDormant.selector);
        bulls.sweepDormancyRemainder();
    }

    function test_Sweep_ClosesTheGameAndPaysTheBeneficiary() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        uint256 before = usdc.balanceOf(beneficiary);
        bulls.sweepDormancyRemainder();

        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.CLOSED), "CLOSED");
        assertGt(usdc.balanceOf(beneficiary) - before, 0, "unclaimed remainder swept");
    }

    function test_Sweep_RevertsOnSecondCall() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();
        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        bulls.sweepDormancyRemainder();
        // The DORMANT phase check runs first, so a second call reports GameNotDormant
        // rather than GameAlreadyClosed. Both are correct refusals; this pins which.
        vm.expectRevert(IBullsEthCRE.GameNotDormant.selector);
        bulls.sweepDormancyRemainder();
    }

    /// @dev Nothing may be swept while a claimant could still turn up. The window is the
    ///      only thing protecting a slow claimant from having their refund given away.
    function test_Sweep_LeavesClaimedRefundsUntouched() public {
        _startWithAllClasses();
        _buyAllPlayers(1);
        _proposeAndActivate();

        uint256 before = usdc.balanceOf(ogA);
        vm.prank(ogA);
        bulls.claimDormancyRefund();
        uint256 afterClaim = usdc.balanceOf(ogA);

        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        bulls.sweepDormancyRemainder();

        assertEq(usdc.balanceOf(ogA), afterClaim, "a paid claimant is unaffected by the sweep");
        assertGt(afterClaim, before, "and they were genuinely paid");
    }
}
