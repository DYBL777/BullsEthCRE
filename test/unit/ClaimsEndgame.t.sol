// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Claims and endgame
/// @notice Every path by which money leaves the contract to a participant, and the
///         settlement that opens them.
///
/// @dev    Four claim paths, one settlement, two sweeps:
///           claimPrize        winners, during ACTIVE, per draw
///           claimEndgame      qualified OGs, after settlement only
///           claimVCReturn     the investor, after settlement, permissionless
///           closeGame         the settlement itself
///           sweepUnclaimed*   the operator, only after ENDGAME_SWEEP_WINDOW
///
///         Two shapes matter here and are easy to get wrong. A second claim must REVERT
///         rather than pay zero, because a silent zero leaves no signal that something
///         was wrong. And a sweep must not be reachable while a claimant could still
///         appear, since the window is the only thing standing between a slow claimant
///         and having their money given away.
contract ClaimsEndgameTest is SmartEarnBase {
    uint256 internal constant ENDGAME_SWEEP_WINDOW = 180 days;

    address[] internal ogs;

    // ── fixtures ─────────────────────────────────────────────────────────

    /// @dev Casuals only. Cheap, and enough for the prize-claim paths.
    function _startCasualsOnly() internal {
        _bootstrapAndStart();
    }

    /// @dev 50 upfront OGs plus 500 casuals. OG predictions are deliberately parked far
    ///      from the settled price so they never win a tier: the endgame payout is a
    ///      separate mechanism from prizes and mixing the two makes cutoffs unreconcilable.
    function _startWithOGs(uint256 n) internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        for (uint256 i = 0; i < n; i++) {
            address og = _newFundedPlayer(97000 + i);
            vm.prank(og); bulls.register();
            vm.prank(og); bulls.registerAsOG(BASE_PREDICTION + 3000 + i, BASE_PREDICTION + 4000 + i);
            ogs.push(og);
        }
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();
    }

    /// @dev Runs the season to its end and settles. Slow by nature: thirty draws with
    ///      500 players is the only way to reach the endgame paths at all.
    function _runSeasonAndClose() internal {
        for (uint256 d = 0; d < bulls.TOTAL_DRAWS(); d++) {
            if (uint256(bulls.gamePhase()) != uint256(IBullsEthCRE.GamePhase.ACTIVE)) break;
            _runStandardDraw();
        }
        // Guard against a vacuous fixture. If a draw bounced and the loop broke early,
        // closeGame can still succeed and every assertion below would be testing a
        // half-played season rather than a completed one.
        assertEq(
            bulls.currentDraw(),
            bulls.TOTAL_DRAWS() + 1,
            "season did not run to completion, fixture is not testing the endgame"
        );
        if (!bulls.gameSettled()) bulls.closeGame();
    }

    /// @dev Finds a player holding an unclaimed prize after a draw.
    function _findWinner() internal view returns (address) {
        for (uint256 i = 0; i < players.length; i++) {
            (,,,,,,,,, uint256 unclaimed,,,,) = bulls.getPlayerInfo(players[i]);
            if (unclaimed > 0) return players[i];
        }
        return address(0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  claimPrize
    // ══════════════════════════════════════════════════════════════════════

    function test_ClaimPrize_WinnerIsPaidAndBalanceZeroed() public {
        _startCasualsOnly();
        _runStandardDraw();

        address w = _findWinner();
        assertTrue(w != address(0), "the draw produced at least one winner");

        (,,,,,,,,, uint256 owed,,,,) = bulls.getPlayerInfo(w);
        uint256 before = usdc.balanceOf(w);

        vm.prank(w);
        bulls.claimPrize();

        assertEq(usdc.balanceOf(w) - before, owed, "paid exactly what was owed");
        (,,,,,,,,, uint256 after_,,,,) = bulls.getPlayerInfo(w);
        assertEq(after_, 0, "balance zeroed");
    }

    function test_ClaimPrize_DecrementsTheGlobalTotal() public {
        _startCasualsOnly();
        _runStandardDraw();

        address w = _findWinner();
        (,,,,,,,,, uint256 owed,,,,) = bulls.getPlayerInfo(w);
        uint256 totalBefore = bulls.totalUnclaimedPrizes();

        vm.prank(w);
        bulls.claimPrize();

        assertEq(
            totalBefore - bulls.totalUnclaimedPrizes(),
            owed,
            "global unclaimed total falls by exactly the payout"
        );
    }

    /// @notice A second claim must revert, not pay zero. Silent zero-payment gives a
    ///         caller no way to tell a double-claim from a genuine empty balance.
    function test_ClaimPrize_RevertsOnSecondClaim() public {
        _startCasualsOnly();
        _runStandardDraw();

        address w = _findWinner();
        vm.prank(w);
        bulls.claimPrize();
        vm.prank(w);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimPrize();
    }

    function test_ClaimPrize_RevertsForANonWinner() public {
        _startCasualsOnly();
        _runStandardDraw();

        address nobody = _newFundedPlayer(98001);
        vm.prank(nobody);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimPrize();
    }

    /// @notice HONEST NAME. This proves a prize is never REDUCED by a later draw. It does
    ///         NOT prove accumulation, because assertGe is satisfied when the player simply
    ///         does not win again, which is the common case. Proving accumulation needs the
    ///         same address to win twice, which this fixture cannot guarantee.
    ///
    ///         The earlier name claimed accumulation and the assertion did not support it.
    ///         Recorded as a gap rather than dressed up.
    function test_ClaimPrize_IsNeverReducedByALaterDraw() public {
        _startCasualsOnly();
        _runStandardDraw();

        address w = _findWinner();
        (,,,,,,,,, uint256 afterOne,,,,) = bulls.getPlayerInfo(w);

        _runStandardDraw();
        (,,,,,,,,, uint256 afterTwo,,,,) = bulls.getPlayerInfo(w);

        assertGe(afterTwo, afterOne, "an unclaimed prize is never reduced by a later draw");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  closeGame
    // ══════════════════════════════════════════════════════════════════════

    function test_CloseGame_RevertsForAStranger() public {
        _startCasualsOnly();
        address stranger = _newFundedPlayer(98002);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.closeGame();
    }

    function test_CloseGame_SetsSettledAndClosed() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        assertTrue(bulls.gameSettled(), "settled");
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.CLOSED), "CLOSED");
    }

    function test_CloseGame_SetsTheEndgamePerOG() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        uint256 perOG = bulls.endgamePerOG();
        uint256 owed = bulls.endgameOwed();
        assertGt(perOG, 0, "a per-OG endgame figure was computed");

        // Tightened from a bare `> 0` on the total. The real invariant is structural: the
        // reserved total must be an exact whole number of per-OG shares, since every
        // qualified OG is paid the identical figure. A remainder would mean the reserve and
        // the share had drifted apart.
        assertEq(owed % perOG, 0, "total owed is an exact multiple of the per-OG share");
        assertGe(owed, perOG, "and covers at least one claimant");
    }

    /// @notice The endgame payout must be capped at the targeted return rather than
    ///         handing out whatever happens to be left. closeGame's own NatSpec is explicit
    ///         that a shortfall branch exists, so the cap is the thing worth pinning.
    function test_CloseGame_EndgamePerOgIsCappedAtTheTarget() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        uint256 maxTarget = OG_UPFRONT_COST * bulls.MAX_TARGET_RETURN_BPS() / 10000;
        // Bound it on BOTH sides. assertLe alone is satisfied by zero, so a contract that
        // paid OGs nothing would have passed the cap test.
        assertGt(bulls.endgamePerOG(), 0, "OGs are actually paid something");
        assertLe(bulls.endgamePerOG(), maxTarget, "never exceeds the maximum targeted return");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  claimEndgame
    // ══════════════════════════════════════════════════════════════════════

    function test_ClaimEndgame_RevertsBeforeSettlement() public {
        _startWithOGs(5);
        vm.prank(ogs[0]);
        vm.expectRevert(IBullsEthCRE.GameNotClosed.selector);
        bulls.claimEndgame();
    }

    function test_ClaimEndgame_RevertsForANonOG() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        vm.prank(players[0]);
        vm.expectRevert(IBullsEthCRE.NotQualifiedForEndgame.selector);
        bulls.claimEndgame();
    }

    function test_ClaimEndgame_QualifiedOgIsPaid() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        uint256 perOG = bulls.endgamePerOG();
        uint256 before = usdc.balanceOf(ogs[0]);

        vm.prank(ogs[0]);
        bulls.claimEndgame();

        assertEq(usdc.balanceOf(ogs[0]) - before, perOG, "paid exactly the per-OG figure");
    }

    function test_ClaimEndgame_RevertsOnSecondClaim() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        vm.prank(ogs[0]);
        bulls.claimEndgame();
        vm.prank(ogs[0]);
        vm.expectRevert(IBullsEthCRE.AlreadyClaimed.selector);
        bulls.claimEndgame();
    }

    function test_ClaimEndgame_DrawsDownTheOwedTotal() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        uint256 owedBefore = bulls.endgameOwed();
        uint256 perOG = bulls.endgamePerOG();

        vm.prank(ogs[0]);
        bulls.claimEndgame();

        assertEq(owedBefore - bulls.endgameOwed(), perOG, "owed falls by exactly one share");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  claimVCReturn
    // ══════════════════════════════════════════════════════════════════════

    function test_ClaimVcReturn_RevertsBeforeSettlement() public {
        _startWithOGs(5);
        vm.expectRevert(IBullsEthCRE.GameNotClosed.selector);
        bulls.claimVCReturn();
    }

    function test_ClaimVcReturn_PaysTheImmutableAddress() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        uint256 owed = bulls.vcReturnOwed();
        // Tightened from `> 0`. At minimum the investor is owed their unreleased seed, which
        // is exactly computable. A bare positive would have passed on a single wei.
        assertGe(
            owed,
            VC_SEED - bulls.seedReleased(),
            "at least the unreleased seed is owed"
        );

        uint256 before = usdc.balanceOf(vcWallet);
        bulls.claimVCReturn();

        assertEq(usdc.balanceOf(vcWallet) - before, owed, "paid in full");
        assertEq(bulls.vcReturnOwed(), 0, "debt cleared");
    }

    /// @notice Permissionless by design since v1.0. The destination is immutable, so the
    ///         gate would add no security while creating a way for a lost owner key to
    ///         strand the investor's principal permanently.
    function test_ClaimVcReturn_IsPermissionless() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        address stranger = _newFundedPlayer(98003);
        uint256 owed = bulls.vcReturnOwed();
        uint256 before = usdc.balanceOf(vcWallet);
        uint256 strangerBefore = usdc.balanceOf(stranger);
        vm.prank(stranger);
        bulls.claimVCReturn();

        // Exact, not `> 0`. The point is that a stranger triggering it changes WHERE nothing
        // and HOW MUCH nothing: the full amount still reaches the immutable destination.
        assertEq(
            usdc.balanceOf(vcWallet) - before,
            owed,
            "a stranger can trigger it, and the full amount still goes to the VC"
        );
        assertEq(
            usdc.balanceOf(stranger),
            strangerBefore,
            "and the caller gains nothing by triggering it"
        );
    }

    function test_ClaimVcReturn_RevertsOnSecondCall() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        bulls.claimVCReturn();
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimVCReturn();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Sweeps
    // ══════════════════════════════════════════════════════════════════════

    function test_SweepEndgame_RevertsBeforeTheWindowElapses() public {
        _startWithOGs(50);
        _runSeasonAndClose();
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.sweepUnclaimedEndgame();
    }

    function test_SweepEndgame_RevertsForNonOwner() public {
        _startWithOGs(50);
        _runSeasonAndClose();
        vm.warp(block.timestamp + ENDGAME_SWEEP_WINDOW + 1);

        address stranger = _newFundedPlayer(98004);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.sweepUnclaimedEndgame();
    }

    function test_SweepPrizes_RevertsBeforeSettlement() public {
        _startCasualsOnly();
        _runStandardDraw();
        vm.expectRevert(IBullsEthCRE.GameNotClosed.selector);
        bulls.sweepUnclaimedPrizes();
    }

    /// @notice The window is the only protection a slow claimant has. A claimant who has
    ///         already been paid must be unaffected by a later sweep.
    function test_Sweep_DoesNotTouchAnAlreadyPaidClaimant() public {
        _startWithOGs(50);
        _runSeasonAndClose();

        vm.prank(ogs[0]);
        bulls.claimEndgame();
        uint256 held = usdc.balanceOf(ogs[0]);

        vm.warp(block.timestamp + ENDGAME_SWEEP_WINDOW + 1);
        bulls.sweepUnclaimedEndgame();

        assertEq(usdc.balanceOf(ogs[0]), held, "a paid OG is untouched by the sweep");
    }
}
