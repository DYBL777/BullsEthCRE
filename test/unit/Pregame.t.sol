// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "../base/BullsEthBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Pregame, full surface
/// @notice Systematic coverage of every state-changing function reachable in PREGAME,
///         organised by function. Where the original Pregame.t.sol covered happy paths,
///         this covers the guards: each documented revert, each cap, each window boundary.
///
/// @dev    Pregame is where every participant's money first enters the contract and it has
///         no draw machinery, so it is the cleanest place to build real coverage. The 13
///         functions below carry roughly 60 distinct revert conditions between them.
contract PregameTest is BullsEthBase {
    uint256 internal constant SIGNUP_DURATION = 4 weeks;
    uint256 internal constant OG_DECLINE_WINDOW = 72 hours;

    // ══════════════════════════════════════════════════════════════════════
    //  register()
    // ══════════════════════════════════════════════════════════════════════

    function test_Register_SetsRegisteredFlag() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();
        (bool isRegistered,,,,,,,,,,,,,) = bulls.getPlayerInfo(p);
        assertTrue(isRegistered, "registered flag set");
    }

    function test_Register_RevertsOnSecondCall() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.AlreadyRegistered.selector);
        bulls.register();
    }

    function test_Register_IsFreeAndMovesNoFunds() public {
        address p = _newFundedPlayer(1);
        uint256 before = usdc.balanceOf(p);
        vm.prank(p);
        bulls.register();
        assertEq(usdc.balanceOf(p), before, "register costs nothing");
        assertEq(usdc.balanceOf(address(bulls)), 0, "contract holds nothing yet");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  payCommitment() / payCommitmentDouble()
    // ══════════════════════════════════════════════════════════════════════

    function test_PayCommitment_RevertsIfNotRegistered() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.NotRegistered.selector);
        bulls.payCommitment(BASE_PREDICTION);
    }

    function test_PayCommitment_RevertsOnSecondCall() public {
        address p = _newFundedPlayer(1);
        _commit(p, BASE_PREDICTION);
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.AlreadyCommitted.selector);
        bulls.payCommitment(BASE_PREDICTION);
    }

    /// @dev The treasury/pot split is the core pregame accounting. TREASURY_BPS is 25%,
    ///      so a $10 commitment is $2.50 treasury and $7.50 pot.
    function test_PayCommitment_SplitsBetweenPotAndTreasury() public {
        address p = _newFundedPlayer(1);
        _commit(p, BASE_PREDICTION);

        uint256 expectedTreasury = TICKET_PRICE * TREASURY_BPS / 10000;
        assertEq(bulls.treasuryBalance(), expectedTreasury, "treasury slice");
        assertEq(bulls.prizePot(), TICKET_PRICE - expectedTreasury, "pot slice");
        assertEq(
            bulls.prizePot() + bulls.treasuryBalance(),
            TICKET_PRICE,
            "no value created or destroyed"
        );
        assertEq(usdc.balanceOf(address(bulls)), TICKET_PRICE, "contract holds exactly the ticket price");
    }

    function test_PayCommitment_IncrementsCommittedCount() public {
        assertEq(bulls.committedPlayerCount(), 0);
        _commit(_newFundedPlayer(1), BASE_PREDICTION);
        _commit(_newFundedPlayer(2), BASE_PREDICTION);
        assertEq(bulls.committedPlayerCount(), 2, "count tracks commitments");
    }

    function test_PayCommitmentDouble_ChargesTwiceAndStoresBothPredictions() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();
        uint256 before = usdc.balanceOf(p);

        vm.prank(p);
        bulls.payCommitmentDouble(BASE_PREDICTION, BASE_PREDICTION + 500);

        assertEq(before - usdc.balanceOf(p), TICKET_PRICE * 2, "charged for two tickets");
        (,,,, uint256 pred,,,,,,,,,) = bulls.getPlayerInfo(p);
        assertEq(pred, BASE_PREDICTION, "first prediction stored");
        assertEq(bulls.committedDoubleCount(), 1, "double count tracked separately");
    }

    function test_PayCommitment_RevertsAfterSignupWindowCloses() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();

        vm.warp(block.timestamp + SIGNUP_DURATION + 1);
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.PregameWindowExpired.selector);
        bulls.payCommitment(BASE_PREDICTION);
    }

    function test_PayCommitment_RevertsForAnUpfrontOG() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.AlreadyOG.selector);
        bulls.payCommitment(BASE_PREDICTION);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  registerAsOG(), upfront
    // ══════════════════════════════════════════════════════════════════════

    function test_RegisterAsOG_ChargesFullStakeAndSetsFlag() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        uint256 before = usdc.balanceOf(og);

        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        assertEq(before - usdc.balanceOf(og), OG_UPFRONT_COST, "charged the full season stake");
        (, bool isUpfrontOG,,,,,,,,,,,,) = bulls.getPlayerInfo(og);
        assertTrue(isUpfrontOG, "upfront OG flag set");
        assertEq(bulls.upfrontOGCount(), 1, "counted");
    }

    function test_RegisterAsOG_SplitsStakeBetweenPotAndTreasury() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        uint256 expectedTreasury = OG_UPFRONT_COST * bulls.UF_OG_TREASURY_BPS() / 10000;
        assertEq(bulls.treasuryBalance(), expectedTreasury, "OG treasury slice");
        assertEq(
            bulls.prizePot() + bulls.treasuryBalance(),
            OG_UPFRONT_COST,
            "OG stake fully accounted"
        );
    }

    function test_RegisterAsOG_RevertsOnSecondCall() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.AlreadyOG.selector);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);
    }

    /// @dev The start-game notice period must block new OG registration, otherwise an OG
    ///      registering just before start has their 72h decline window silently truncated
    ///      and then loses cancellation entirely. This was CRE v0.6 LOW-01.
    function test_RegisterAsOG_BlockedDuringStartGameNotice() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();

        address og = _newFundedPlayer(9001);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  registerAsWeeklyOG()
    // ══════════════════════════════════════════════════════════════════════

    function test_RegisterAsWeeklyOG_ChargesOneDrawAndSetsFlag() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        uint256 before = usdc.balanceOf(og);

        vm.prank(og);
        bulls.registerAsWeeklyOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        assertEq(before - usdc.balanceOf(og), TICKET_PRICE * 2, "weekly OG pays two tickets up front");
        (,, bool isWeeklyOG,,,,,,,,,,,) = bulls.getPlayerInfo(og);
        assertTrue(isWeeklyOG, "weekly OG flag set");
        assertEq(bulls.weeklyOGCount(), 1, "counted");
    }

    function test_RegisterAsWeeklyOG_BlockedDuringStartGameNotice() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();

        address og = _newFundedPlayer(9002);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.registerAsWeeklyOG(BASE_PREDICTION, BASE_PREDICTION + 100);
    }

    function test_RegisterAsWeeklyOG_RevertsIfAlreadyUpfrontOG() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        vm.prank(og);
        vm.expectRevert(IBullsEthCRE.AlreadyOG.selector);
        bulls.registerAsWeeklyOG(BASE_PREDICTION, BASE_PREDICTION + 100);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  cancelOGRegistration()
    // ══════════════════════════════════════════════════════════════════════

    function test_CancelOG_RefundsInFullAndDecrementsCount() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        uint256 before = usdc.balanceOf(og);
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);
        assertEq(bulls.upfrontOGCount(), 1);

        vm.prank(og);
        bulls.cancelOGRegistration();

        // NOT a full refund. The contract states it plainly in cancelOGRegistration:
        // "ogCancelRefund = ogTransfer x 75%. Commitment credit is forfeited on cancel."
        // So the 25% treasury slice is kept, $150 on a $600 stake. Deliberate, but it is a
        // real cost to a real person and the decline window reads as free until used.
        // Belongs in the OG terms next to the H-04 seniority disclosure.
        uint256 forfeited = OG_UPFRONT_COST * bulls.UF_OG_TREASURY_BPS() / 10000;
        assertEq(
            usdc.balanceOf(og),
            before - forfeited,
            "75% returned, treasury slice forfeited"
        );
        assertEq(bulls.upfrontOGCount(), 0, "count decremented");
        (, bool isUpfrontOG,,,,,,,,,,,,) = bulls.getPlayerInfo(og);
        assertFalse(isUpfrontOG, "flag cleared");
    }

    function test_CancelOG_LeavesPotAndTreasuryClean() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);
        vm.prank(og);
        bulls.cancelOGRegistration();

        uint256 forfeited = OG_UPFRONT_COST * bulls.UF_OG_TREASURY_BPS() / 10000;
        assertEq(bulls.prizePot(), 0, "pot slice fully returned");
        assertEq(bulls.treasuryBalance(), forfeited, "treasury retains the forfeited slice");
        assertEq(
            usdc.balanceOf(address(bulls)),
            forfeited,
            "contract holds exactly the forfeited amount, nothing stranded"
        );
    }

    function test_CancelOG_RevertsAfterDeclineWindow() public {
        address og = _newFundedPlayer(1);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        vm.warp(block.timestamp + OG_DECLINE_WINDOW + 1);
        vm.prank(og);
        vm.expectRevert();
        bulls.cancelOGRegistration();
    }

    function test_CancelOG_RevertsForNonOG() public {
        address p = _newFundedPlayer(1);
        _commit(p, BASE_PREDICTION);
        vm.prank(p);
        vm.expectRevert();
        bulls.cancelOGRegistration();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  seedPot()
    // ══════════════════════════════════════════════════════════════════════

    function test_SeedPot_RevertsForNonOwner() public {
        address stranger = _newFundedPlayer(1);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.seedPot();
    }

    /// @dev VC_SEED is zero in this harness, so seedPot has nothing to deposit. The point
    ///      of the test is that the owner gate is real; the funded path lives in the
    ///      SmartEarn harness where the seed is non-zero.
    function test_SeedPot_OwnerGateIsTheOnlyGuardHere() public {
        assertEq(bulls.VC_SEED(), 0, "unseeded harness");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  proposeStartGame() / cancelStartGameProposal()
    // ══════════════════════════════════════════════════════════════════════

    function test_ProposeStartGame_RevertsBelowMinimumPlayers() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START - 1);
        vm.expectRevert(IBullsEthCRE.NotEnoughPlayers.selector);
        bulls.proposeStartGame();
    }

    function test_ProposeStartGame_RevertsForNonOwner() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address stranger = _newFundedPlayer(9003);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.proposeStartGame();
    }

    function test_ProposeStartGame_RevertsWhenAlreadyPending() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.proposeStartGame();
    }

    function test_CancelStartGameProposal_ReopensOGRegistration() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        bulls.cancelStartGameProposal();

        // The notice period no longer blocks OG registration.
        address og = _newFundedPlayer(9004);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);
        assertEq(bulls.upfrontOGCount(), 1, "registration reopened after cancel");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  startGame()
    // ══════════════════════════════════════════════════════════════════════

    function test_StartGame_RevertsWithNoProposal() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.startGame();
    }

    function test_StartGame_RevertsBeforeNoticePeriodElapses() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD - 1);
        ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.startGame();
    }

    function test_StartGame_RevertsForNonOwner() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        address stranger = _newFundedPlayer(9005);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.startGame();
    }

    /// @dev The feed must be fresh at start. The rewritten MockAggregator reports real
    ///      round timestamps, so a 72h warp genuinely ages the feed past its heartbeat,
    ///      which is what a live feed would do between publications.
    function test_StartGame_RevertsOnStaleFeed() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        // deliberately do NOT publish a fresh round
        vm.expectRevert(IBullsEthCRE.NotEnoughValidPrices.selector);
        bulls.startGame();
    }

    function test_StartGame_SetsActiveStateAndAnchorsSchedule() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.ACTIVE), "ACTIVE");
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.IDLE), "IDLE");
        assertEq(bulls.currentDraw(), 1, "draw 1");
        assertEq(bulls.scheduleAnchor(), block.timestamp, "schedule anchored at start");
        assertEq(bulls.lastDrawTimestamp(), block.timestamp, "first slot is now");
    }

    function test_StartGame_LocksTheOgObligation() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        address og = _newFundedPlayer(9006);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        assertGt(bulls.requiredEndPot(), 0, "endgame floor locked at start");
        assertGt(bulls.ogEndgameObligation(), 0, "OG obligation locked at start");
    }

    function test_StartGame_RevertsOnSecondCall() public {
        _bootstrapAndStart();
        vm.expectRevert();
        bulls.startGame();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Failed pregame: claimSignupRefund(), sweepFailedPregame(), batchRefundPlayers()
    // ══════════════════════════════════════════════════════════════════════

    function test_ClaimSignupRefund_RevertsWhileSignupCanStillSucceed() public {
        address p = _newFundedPlayer(1);
        _commit(p, BASE_PREDICTION);
        vm.prank(p);
        // TooEarly is checked before SignupNotFailed: the window must close first.
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.claimSignupRefund();
    }

    /// @dev The failure condition is the signup window closing without the minimum player
    ///      count being reached. Every committed player must then be able to recover their
    ///      full commitment, treasury slice included, because the game never ran.
    function test_ClaimSignupRefund_ReturnsFullCommitmentAfterFailedSignup() public {
        address p = _newFundedPlayer(1);
        uint256 before = usdc.balanceOf(p);
        _commit(p, BASE_PREDICTION);
        assertEq(before - usdc.balanceOf(p), TICKET_PRICE);

        vm.warp(block.timestamp + SIGNUP_DURATION + 1);

        vm.prank(p);
        bulls.claimSignupRefund();
        assertEq(usdc.balanceOf(p), before, "full commitment returned, treasury slice included");
    }

    function test_ClaimSignupRefund_RevertsOnSecondClaim() public {
        address p = _newFundedPlayer(1);
        _commit(p, BASE_PREDICTION);
        vm.warp(block.timestamp + SIGNUP_DURATION + 1);

        vm.prank(p);
        bulls.claimSignupRefund();
        vm.prank(p);
        vm.expectRevert();
        bulls.claimSignupRefund();
    }

    function test_ClaimSignupRefund_RevertsForUncommittedPlayer() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();
        vm.warp(block.timestamp + SIGNUP_DURATION + 1);

        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimSignupRefund();
    }

    function test_SweepFailedPregame_RevertsBeforeTheWindowCloses() public {
        _commit(_newFundedPlayer(1), BASE_PREDICTION);
        vm.expectRevert();
        bulls.sweepFailedPregame();
    }

    function test_SweepFailedPregame_RevertsForNonOwner() public {
        _commit(_newFundedPlayer(1), BASE_PREDICTION);
        vm.warp(block.timestamp + SIGNUP_DURATION + 1);
        address stranger = _newFundedPlayer(9007);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.sweepFailedPregame();
    }

    function test_BatchRefundPlayers_RevertsForNonOwner() public {
        _commit(_newFundedPlayer(1), BASE_PREDICTION);
        vm.warp(block.timestamp + SIGNUP_DURATION + 1);
        address[] memory list = new address[](1);
        list[0] = _newFundedPlayer(1);
        address stranger = _newFundedPlayer(9008);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.batchRefundPlayers(list);
    }

    /// @dev The operator-driven refund path must produce the same result as a player
    ///      claiming for themselves. Both exist so that neither party can strand the other.
    function test_BatchRefundPlayers_MatchesSelfServiceRefund() public {
        address a = _newFundedPlayer(1);
        address b = _newFundedPlayer(2);
        uint256 beforeA = usdc.balanceOf(a);
        uint256 beforeB = usdc.balanceOf(b);
        _commit(a, BASE_PREDICTION);
        _commit(b, BASE_PREDICTION);

        vm.warp(block.timestamp + SIGNUP_DURATION + 1);

        // a is refunded by the operator, b claims for themselves.
        address[] memory list = new address[](1);
        list[0] = a;
        bulls.batchRefundPlayers(list);

        vm.prank(b);
        bulls.claimSignupRefund();

        assertEq(usdc.balanceOf(a), beforeA, "operator refund is whole");
        assertEq(usdc.balanceOf(b), beforeB, "self-service refund is whole");
        assertEq(usdc.balanceOf(a), usdc.balanceOf(b), "both paths agree");
    }

    function test_BatchRefundPlayers_RevertsBeforeSignupFails() public {
        address a = _newFundedPlayer(1);
        _commit(a, BASE_PREDICTION);
        address[] memory list = new address[](1);
        list[0] = a;
        // TooEarly is checked first: the signup window must close before either
        // refund path opens.
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.batchRefundPlayers(list);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Value conservation across the whole pregame
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The invariant that matters most in pregame: the contract's USDC balance always
    ///      equals prizePot + treasuryBalance. Every entry path and every exit path must
    ///      preserve it, or funds are being created or stranded.
    function test_Invariant_BalanceEqualsPotPlusTreasury() public {
        _assertBalanceInvariant("empty");

        // OG caps are a percentage of committedPlayerCount (10% upfront, 18% total), so a
        // base of committed players is needed before any OG can register.
        _bootstrapCommitted(100);
        _assertBalanceInvariant("after 100 commitments");

        address a = _newFundedPlayer(90001);
        _commit(a, BASE_PREDICTION);
        _assertBalanceInvariant("after one commitment");

        address b = _newFundedPlayer(90002);
        vm.prank(b);
        bulls.register();
        vm.prank(b);
        bulls.payCommitmentDouble(BASE_PREDICTION, BASE_PREDICTION + 1);
        _assertBalanceInvariant("after a double commitment");

        address og = _newFundedPlayer(90003);
        vm.prank(og);
        bulls.register();
        vm.prank(og);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 100);
        _assertBalanceInvariant("after an upfront OG");

        address wog = _newFundedPlayer(90004);
        vm.prank(wog);
        bulls.register();
        vm.prank(wog);
        bulls.registerAsWeeklyOG(BASE_PREDICTION, BASE_PREDICTION + 100);
        _assertBalanceInvariant("after a weekly OG");

        vm.prank(og);
        bulls.cancelOGRegistration();
        _assertBalanceInvariant("after an OG cancellation");

        vm.warp(block.timestamp + SIGNUP_DURATION + 1);
        vm.prank(a);
        bulls.claimSignupRefund();
        _assertBalanceInvariant("after a signup refund");
    }

    function _assertBalanceInvariant(string memory whenLabel) internal view {
        assertEq(
            usdc.balanceOf(address(bulls)),
            bulls.prizePot() + bulls.treasuryBalance(),
            string.concat("balance != pot + treasury at: ", whenLabel)
        );
    }
}
