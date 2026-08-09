// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

/// @title  Treasury withdrawal
/// @notice The only path by which the operator moves money to themselves, and until this
///         file none of the four gates protecting it had a test.
///
/// @dev    withdrawTreasury runs FOUR independent locks in sequence. A withdrawal must
///         clear all of them, and the ORDER matters because it decides which revert a
///         caller actually sees:
///
///           1. WITHDRAW_START_DRAW  nothing before draw 5 while the game is live.
///                                   "Protocol eats last": the game gets on its feet
///                                   before the operator takes anything.
///           2. PREGAME              blocked outright. requiredEndPot is still 0 there,
///                                   so gate 4 cannot fire, and two refund paths lean on
///                                   treasuryBalance as their backstop.
///           3. VC-SPENT RESERVE     treasury minus the amount must still cover the
///                                   investor's spent-seed obligation plus a 5% buffer.
///                                   Sized on what COULD be released from earned treasury
///                                   at the immutable max ratio, not on what has been.
///           4. requiredEndPot       blocked while the pot is below its solvency floor.
///                                   Treasury cannot be drained ahead of the pot covering
///                                   what participants are owed.
///
///         Every lock lifts once gameSettled is true, which is the point: at settlement
///         the obligations have been paid or reserved, so the protocol can take its share.
contract TreasuryTest is SmartEarnBase {
    using stdStorage for StdStorage;

    // NOTE: WITHDRAW_START_DRAW is NOT declared here. SmartEarnBase already declares it and
    // a second declaration is an "Identifier already declared" compile error. The exact
    // mirror of the MIN_TICKETS_WEEKLY_OG lesson in KeeperAutomation's sibling work: that
    // constant was assumed present and wasn't, this one was assumed absent and isn't.
    // Check the base before declaring, in both directions.

    // ══════════════════════════════════════════════════════════════════════
    //  Argument validation
    // ══════════════════════════════════════════════════════════════════════

    function test_Withdraw_RevertsForNonOwner() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(90001);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.withdrawTreasury(1, stranger);
    }

    function test_Withdraw_RevertsOnZeroAmount() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.InsufficientBalance.selector);
        bulls.withdrawTreasury(0, address(this));
    }

    /// @notice Asking for more than the recorded balance is refused before any of the
    ///         solvency locks are consulted, so the caller gets the honest reason.
    function test_Withdraw_RevertsAboveTheRecordedBalance() public {
        _bootstrapAndStart();
        // Read FIRST: a getter in the argument position would consume the expectation.
        uint256 balance = bulls.treasuryBalance();
        assertGt(balance, 0, "precondition: pregame commitments accrued a treasury balance");

        vm.expectRevert(IBullsEthCRE.InsufficientBalance.selector);
        bulls.withdrawTreasury(balance + 1, address(this));
    }

    function test_Withdraw_RevertsOnZeroRecipient() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.withdrawTreasury(1, address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Gate 1: the WITHDRAW_START_DRAW window
    // ══════════════════════════════════════════════════════════════════════

    /// @notice "Protocol eats last." No treasury withdrawal at all until after draw 5 while
    ///         the game is live, so the operator cannot pay themselves out of a season that
    ///         has barely begun.
    function test_Withdraw_BlockedBeforeTheStartDraw() public {
        _bootstrapAndStart();
        assertLe(bulls.currentDraw(), WITHDRAW_START_DRAW, "precondition: inside the locked window");

        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(1, address(this));
    }

    /// @notice The comparison is `currentDraw <= WITHDRAW_START_DRAW`, so draw 5 ITSELF is
    ///         still locked and the window only opens at draw 6. This half pins the locked
    ///         side; test_Withdraw_TheWindowGenuinelyReleasesAtDrawSix pins the release, on
    ///         the unseeded deployment where nothing else can be responsible.
    ///
    /// @dev    An earlier version tried to do both halves here and could not: after the
    ///         draw-5 revert it ran one more draw and asserted currentDraw == 6, which
    ///         proves the loop ran, not that the gate opened. Named for one half now, with
    ///         the other half where it can actually be isolated.
    function test_Withdraw_StillLockedAtDrawFiveItself() public {
        _bootstrapAndStart();
        for (uint256 d = 1; d <= 4; d++) {
            _runStandardDraw();
        }
        assertEq(bulls.currentDraw(), 5, "at draw 5, the boundary itself");

        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(1, address(this));
    }

    /// @dev The draw-6 half of the boundary is proven on the UNSEEDED deployment, where
    ///      gate 3 is absent, so "it went through" can only mean gate 1 released. Doing it
    ///      on the seeded fixture would have been half-vacuous: re-asserting currentDraw > 5
    ///      after running a draw proves the loop ran, not that the gate opened.
    function test_Withdraw_TheWindowGenuinelyReleasesAtDrawSix() public {
        _deployUnseededAndStart();
        for (uint256 d = 1; d <= 4; d++) {
            _runStandardDraw();
        }
        assertEq(bulls.currentDraw(), 5, "at draw 5, still locked");
        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(1, address(this));

        _runStandardDraw();
        assertEq(bulls.currentDraw(), 6, "past the window");
        _forceTrajectoryGateClear();
        assertGe(bulls.prizePot(), bulls.requiredEndPot(), "trajectory gate clear, so only the window was in play");

        uint256 before = bulls.treasuryBalance();
        bulls.withdrawTreasury(1, address(this));
        assertEq(bulls.treasuryBalance(), before - 1, "the identical call now succeeds");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Gate 2: PREGAME
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A pregame withdrawal is blocked. That much is certain and it is what matters
    ///         operationally: two refund paths (claimSignupRefund, cancelOGRegistration)
    ///         fall back on treasuryBalance when the pot is short, so it must not be
    ///         drainable before the game starts.
    ///
    /// @dev    NAMED FOR WHAT IT PROVES, which is NOT the PREGAME guard specifically. An
    ///         earlier version claimed to test that guard and could not: in PREGAME
    ///         currentDraw is 0, and the WINDOW gate above it checks
    ///         `currentDraw <= WITHDRAW_START_DRAW`, so 0 <= 5 fires FIRST and the PREGAME
    ///         branch is never reached. Both revert TreasuryLocked, so the test passed while
    ///         proving the gate above the one it was named after.
    ///
    ///         CONTRACT OBSERVATION worth recording rather than "fixing": the PREGAME guard
    ///         appears to be unreachable in practice, because currentDraw is only non-zero
    ///         once startGame has run and by then the phase is ACTIVE. It is harmless
    ///         defensive depth and the two guards agree on the revert, but no test can
    ///         distinguish them from outside, and this one no longer pretends to.
    function test_Withdraw_BlockedBeforeTheGameStarts() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.PREGAME), "in PREGAME");
        assertEq(bulls.currentDraw(), 0, "and currentDraw is 0, which is why the window gate fires first");
        assertGt(bulls.treasuryBalance(), 0, "there is a real balance to attempt against");

        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(1, address(this));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Gate 3: the VC-spent reserve
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE INVESTOR'S PROTECTION. Treasury may not be drained below the spent-seed
    ///         obligation plus a 5% buffer while the game runs, so the money to reconstitute
    ///         released seed and pay its return is always present at settlement.
    ///
    /// @dev    Deliberately does NOT recompute the reserve formula. Mirroring contract
    ///         arithmetic in a test is how the H-06 solver mirror silently drifted, so this
    ///         asks for the WHOLE balance, which must breach any non-zero reserve, and lets
    ///         the contract decide the figure.
    ///
    ///         THE OTHER GATES ARE RULED OUT FIRST, which an earlier version of this test
    ///         did not do. It used a bare vm.expectRevert(), which is satisfied by ANY
    ///         revert, so it would have passed just as happily on gate 1 or gate 4 and
    ///         proved nothing about the reserve. The preconditions below close that off.
    ///
    ///         This also covers the v1.08 sizing fix in passing: the reserve is computed
    ///         from what COULD be released at the immutable max ratio, not from what HAS
    ///         been, so it exists while seedReleased is still zero. Asserted as a
    ///         precondition rather than as a second near-identical test.
    function test_Withdraw_ReserveBlocksDrainingTheWholeBalance() public {
        _bootstrapAndStart();
        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
        }

        // Rule out the other gates so a revert here can only be the reserve.
        assertGt(bulls.currentDraw(), WITHDRAW_START_DRAW, "window gate clear: past the start draw");
        assertEq(
            uint256(bulls.gamePhase()),
            uint256(IBullsEthCRE.GamePhase.ACTIVE),
            "phase gate clear: not PREGAME"
        );
        // The trajectory gate is FORCED clear rather than assumed. On a seeded deployment
        // requiredEndPot carries the whole unreleased VC seed, so whether the pot organically
        // clears it at draw 6 depends on the fixture's economics and is not something this
        // test should be betting on. Injecting the floor below the pot makes the isolation
        // deterministic: if the withdrawal reverts, only the reserve can be responsible.
        _forceTrajectoryGateClear();
        assertGe(bulls.prizePot(), bulls.requiredEndPot(), "trajectory gate clear: pot above its floor");

        // The reserve is genuinely in force despite nothing having been released yet.
        assertEq(bulls.seedReleased(), 0, "no seed released, yet a reserve still applies");
        assertGt(bulls.cumulativeSeasonTreasury(), 0, "because season treasury has been earned");

        // NAME THE ERROR. Gate 3 reverts TreasuryBonusProtected, which no other gate uses:
        // 1, 2 and 4 all share TreasuryLocked. So the selector alone distinguishes the
        // reserve from everything else, which is exactly what the preconditions above were
        // approximating. An earlier version used a bare expectRevert on the reasoning that
        // naming things invites mirror drift -- but that lesson (H-06) is about not
        // duplicating the reserve FORMULA, which involves arithmetic. A selector involves
        // none. The preconditions stay as belt and braces.
        //
        // expectPARTIALRevert, not expectRevert, and the distinction is not cosmetic.
        // vm.expectRevert(selector) does EXACT matching on the whole revert payload. That
        // works everywhere else in these suites only because TreasuryLocked,
        // InsufficientBalance and friends take no arguments, so their payload IS the bare
        // four-byte selector. TreasuryBonusProtected carries two uint256s, so its payload is
        // selector + 64 bytes and can never equal a naked selector -- the contract reverts
        // with exactly the right error and the expectation rejects it anyway.
        //
        // RULE, alongside the getter-hoist one: typed expectations on errors that carry
        // arguments need expectPartialRevert. Plain expectRevert(selector) is exact-match
        // and only suits argument-less errors.
        uint256 whole = bulls.treasuryBalance();
        vm.expectPartialRevert(IBullsEthCRE.TreasuryBonusProtected.selector);
        bulls.withdrawTreasury(whole, address(this));

        // And the balance is untouched, so the revert genuinely blocked the transfer rather
        // than being swallowed somewhere after a partial state change.
        assertEq(bulls.treasuryBalance(), whole, "nothing left the treasury");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Gate 4: the requiredEndPot trajectory lock
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Treasury seals while the pot sits below its solvency floor, so the operator
    ///         cannot take money out ahead of the pot covering what participants are owed.
    ///         It unlocks by itself when the pot recovers.
    ///
    /// @dev    STATE INJECTION, and the reason is the same one the breath tests give: the
    ///         solver actively defends this floor, so driving the pot genuinely below it
    ///         means fighting the mechanism under test. Raising requiredEndPot directly is
    ///         the honest way to reach the branch. Uses the unseeded deployment so gate 3
    ///         is out of the picture and a failure here can only be gate 4.
    function test_Withdraw_BlockedWhileThePotIsBelowItsFloor() public {
        _deployUnseededAndStart();
        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
        }
        assertGt(bulls.currentDraw(), WITHDRAW_START_DRAW, "past gate 1");
        assertGt(bulls.treasuryBalance(), 0, "there is a balance to attempt against");

        // Raise the floor above the live pot.
        uint256 unreachableFloor = bulls.prizePot() * 2;
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(unreachableFloor);
        assertLt(bulls.prizePot(), bulls.requiredEndPot(), "precondition: pot is genuinely below the floor");

        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(1, address(this));
    }

    /// @notice And it releases on its own. Same fixture, floor put back under the pot, and
    ///         the identical withdrawal now succeeds. Without this the test above would only
    ///         prove that SOMETHING blocked it, not that this gate was the thing.
    function test_Withdraw_UnlocksWhenThePotRecoversAboveTheFloor() public {
        _deployUnseededAndStart();
        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
        }

        uint256 unreachableFloor = bulls.prizePot() * 2;
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(unreachableFloor);
        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(1, address(this));

        // Drop the floor back under the pot: the same call now goes through.
        uint256 reachableFloor = bulls.prizePot() / 2;
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(reachableFloor);
        assertGe(bulls.prizePot(), bulls.requiredEndPot(), "pot has recovered above the floor");

        uint256 before = bulls.treasuryBalance();
        bulls.withdrawTreasury(1, address(this));
        assertEq(bulls.treasuryBalance(), before - 1, "the lock released without any other change");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The successful path, and its accounting
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A withdrawal that clears all four gates moves the exact amount and keeps the
    ///         books straight: the recorded balance falls by exactly what left, the lifetime
    ///         total rises by the same, and the recipient receives it.
    function test_Withdraw_MovesTheExactAmountAndUpdatesBothCounters() public {
        _deployUnseededAndStart();
        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
        }

        _forceTrajectoryGateClear();

        uint256 balanceBefore = bulls.treasuryBalance();
        uint256 withdrawnBefore = bulls.totalTreasuryWithdrawn();
        uint256 amount = balanceBefore / 4;
        assertGt(amount, 0, "precondition: there is a meaningful amount to take");

        address recipient = address(0xCAFE);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        bulls.withdrawTreasury(amount, recipient);

        assertEq(bulls.treasuryBalance(), balanceBefore - amount, "recorded balance fell by exactly the amount");
        assertEq(
            bulls.totalTreasuryWithdrawn(),
            withdrawnBefore + amount,
            "lifetime withdrawn rose by exactly the amount"
        );
        assertEq(usdc.balanceOf(recipient) - recipientBefore, amount, "and the recipient got it");
    }

    /// @notice The recipient is a free parameter, not forced to be the owner. Worth pinning
    ///         because it means a compromised owner key can direct funds anywhere, which is
    ///         exactly why the four gates above are the protection rather than the recipient
    ///         check being it.
    function test_Withdraw_CanDirectFundsToAnyNonZeroRecipient() public {
        _deployUnseededAndStart();
        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
        }

        _forceTrajectoryGateClear();

        address elsewhere = _newFundedPlayer(90020);
        uint256 before = usdc.balanceOf(elsewhere);
        uint256 amount = bulls.treasuryBalance() / 4;

        bulls.withdrawTreasury(amount, elsewhere);

        assertEq(usdc.balanceOf(elsewhere) - before, amount, "paid to an arbitrary address");
        assertTrue(elsewhere != bulls.owner(), "and that address is not the owner");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Settlement: every lock stands down at once
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE HEADER'S OWN CLAIM, and until now nothing tested it. The NatSpec at the
    ///         top of this file organises all four gates around one sentence: every lock
    ///         lifts once gameSettled is true. That is the whole design -- the gates exist
    ///         to hold the operator off while obligations are outstanding, and at settlement
    ///         those obligations have been paid or reserved, so the protocol takes its share.
    ///
    ///         Proven at the HARDEST point: draw 1 on the seeded fixture, which is inside
    ///         the window gate, with the reserve inputs live and the trajectory floor
    ///         carrying the full unreleased VC seed. Every gate that could fire, does not.
    ///
    /// @dev    STATE INJECTION of the settled flag, disclosed like the others. Reaching
    ///         settlement honestly means a full 30-draw season or a 90-day dormancy wind-down;
    ///         neither belongs inside a gate test. The injection only ever LOOSENS, so it
    ///         cannot manufacture a pass: if a lock still bit afterwards, that would be a
    ///         real finding rather than a fixture artefact.
    function test_Withdraw_EveryLockStandsDownOnceSettled() public {
        _bootstrapAndStart();
        assertEq(bulls.currentDraw(), 1, "draw 1: deep inside the window gate");
        assertGt(bulls.VC_SEED(), 0, "seeded, so the reserve gate has live inputs");

        uint256 whole = bulls.treasuryBalance();
        assertGt(whole, 0, "and there is a real balance at stake");

        // Confirm it is genuinely locked first, or "it worked after settling" proves nothing.
        vm.expectRevert(IBullsEthCRE.TreasuryLocked.selector);
        bulls.withdrawTreasury(whole, address(this));

        stdstore.target(address(bulls)).sig("gameSettled()").checked_write(true);

        uint256 recipientBefore = usdc.balanceOf(address(0xFEED));
        bulls.withdrawTreasury(whole, address(0xFEED));

        assertEq(bulls.treasuryBalance(), 0, "the ENTIRE balance was withdrawable");
        assertEq(
            usdc.balanceOf(address(0xFEED)) - recipientBefore,
            whole,
            "and all of it reached the recipient: window, reserve and trajectory all stood down"
        );
    }

    /// @notice THE RESERVE PERMITTING, not just refusing. Every other successful withdrawal
    ///         in this file runs on the unseeded deployment where gate 3 does not exist, so
    ///         without this the reserve was only ever shown blocking. That is the same
    ///         both-sides-of-the-boundary discipline the governance suite applied to the seed
    ///         ratio cap: cap+1 must revert AND cap itself must pass, or a rejection could be
    ///         an off-by-one refusing the legal maximum.
    ///
    /// @dev    Takes ONE unit rather than computing the headroom, deliberately: working out
    ///         the largest legal amount would mean reproducing the reserve formula, which is
    ///         the drift hazard H-06 taught. The headroom at draw 6 is real but not enormous,
    ///         so if the fixture's economics ever shift far enough that even a single unit is
    ///         illegal, this fails loudly -- which is itself worth knowing.
    function test_Withdraw_ReservePermitsALegalAmount() public {
        _bootstrapAndStart();
        for (uint256 d = 1; d <= 5; d++) {
            _runStandardDraw();
        }
        assertGt(bulls.currentDraw(), WITHDRAW_START_DRAW, "window gate clear");
        assertGt(bulls.VC_SEED(), 0, "and the reserve gate is genuinely in play");
        _forceTrajectoryGateClear();

        uint256 before = bulls.treasuryBalance();
        bulls.withdrawTreasury(1, address(this));

        assertEq(
            bulls.treasuryBalance(),
            before - 1,
            "the reserve permits a withdrawal that leaves it covered"
        );
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    /// @dev Puts requiredEndPot safely BELOW the live pot so the trajectory gate cannot fire,
    ///      leaving whichever gate a test is actually about as the only one in play.
    ///
    ///      Needed because several of these tests were originally asserting
    ///      `prizePot >= requiredEndPot` and hoping it held. On a SEEDED deployment
    ///      requiredEndPot carries the entire unreleased VC seed ($100k), so whether the pot
    ///      organically clears it a few draws in depends on the fixture's economics rather
    ///      than on anything the test is trying to prove. A test that can fail on an
    ///      unrelated precondition is not isolating what it claims to.
    ///
    ///      This is state injection and is disclosed as such, same as the breath-engine
    ///      tests. It only ever makes a gate MORE permissive, so it cannot manufacture a
    ///      pass: a withdrawal that still reverts afterwards reverted for another reason,
    ///      which is exactly the isolation being bought.
    function _forceTrajectoryGateClear() internal {
        uint256 safeFloor = bulls.prizePot() / 2;
        stdstore.target(address(bulls)).sig("requiredEndPot()").checked_write(safeFloor);
    }

    /// @dev A deployment with SmartEarn switched off, so gate 3 is absent and gates 1, 2 and
    ///      4 can be observed in isolation. vcSeed 0 makes both cap params inert, and
    ///      seedPot() would revert BelowMinimum on such a deployment, so the bootstrap to
    ///      ACTIVE is done by hand rather than through the seeded helper.
    function _deployUnseededAndStart() internal {
        bulls = new BullsEth(
            bulls.USDC(),
            address(ethFeed),
            address(0),                // no reserve fallback
            address(0),                // no weth fallback
            BASE_PREDICTION,
            bulls.SEQUENCER_FEED(),
            bulls.PROTOCOL_BENEFICIARY(),
            0,                         // vcSeed: SmartEarn disabled
            address(0),
            0,
            0
        );
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();
    }
}
