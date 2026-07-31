// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @title  Dormancy with a live VC seed
/// @notice The half of the waterfall the unseeded harness cannot reach: TIER 0, and the
///         subordination rules that decide who gets nothing when a senior tier is short.
///
/// @dev    activateDormancy sizes each tier in strict order, and the shape is the same
///         at every level:
///
///           if the pot covers the tier in full  -> pool = target, FullCover = true
///           if it does not                      -> pool = whatever is left, FullCover = false
///
///         and a tier that is not fully covered zeroes every junior tier beneath it. That
///         is the promise: seniors are made whole before juniors receive anything at all,
///         rather than everyone taking a proportional haircut.
///
///         TIER 0 is the VC's unreleased seed. It is also the tier the per-draw dormancy
///         floor (_dormancyNowFloor) reserves on every single draw, so the interesting
///         question is not whether the pro-rata branch pays correctly but whether the
///         floor makes it unreachable in the first place. These tests check both.
contract SmartEarnDormancyTest is SmartEarnBase {
    uint256 internal constant DORMANCY_TIMELOCK = 24 hours;
    uint256 internal constant DORMANCY_CLAIM_WINDOW = 90 days;

    address internal ogA;

    function _proposeAndActivate() internal {
        bulls.proposeDormancy();
        vm.warp(bulls.lastDrawTimestamp() + PICK_DEADLINE + 1);
        bulls.activateDormancy();
    }

    function _startSeededWithOG() internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        ogA = _newFundedPlayer(80001);
        vm.prank(ogA); bulls.register();
        vm.prank(ogA); bulls.registerAsOG(BASE_PREDICTION + 41, BASE_PREDICTION + 42);

        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  TIER 0, the VC seed
    // ══════════════════════════════════════════════════════════════════════

    function test_VcTier_PoolSizedToUnreleasedSeed() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        uint256 unreleased = VC_SEED - bulls.seedReleased();
        assertEq(bulls.dormancyVCPool(), unreleased, "TIER 0 sized to unreleased seed exactly");
        assertEq(bulls.dormancyVCPoolSnapshot(), unreleased, "snapshot matches at activation");
    }

    /// @notice The guarantee that matters. The per-draw dormancy floor reserves the
    ///         unreleased seed on every draw, so by the time dormancy fires the pot must
    ///         still cover it. If this ever fails, the floor is not doing its job.
    function test_VcTier_IsAlwaysFullyCovered() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();
        assertTrue(bulls.dormancyVCFullCover(), "VC seed fully covered, the floor held");
    }

    function test_VcTier_StaysCoveredAfterSeveralDraws() public {
        _startSeededWithOG();
        for (uint256 d = 0; d < 4; d++) {
            _runStandardDraw();
        }
        _buyAllPlayers(1);
        _proposeAndActivate();

        assertTrue(bulls.dormancyVCFullCover(), "still covered after four draws of distribution");
        assertEq(
            bulls.dormancyVCPool(),
            VC_SEED - bulls.seedReleased(),
            "pool tracks what is still owed, not the original seed"
        );
    }

    /// @notice TIER 0 is carved before TIER 1. If the pot could only cover one, it would
    ///         be the VC. This asserts the ordering rather than the outcome.
    function test_Seniority_VcIsCarvedBeforeOG() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        // Both funded here, which is the healthy case. The ordering claim is that the VC
        // pool is satisfied in full before anything reaches the OG tier.
        assertTrue(bulls.dormancyVCFullCover(), "VC settled first");
        assertGt(bulls.dormancyVCPool(), 0, "and is non-zero");
        assertGt(bulls.dormancyOGPool(), 0, "OG funded from what remained");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Subordination: a short senior tier zeroes everything junior
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The rule, asserted as an implication rather than a fixed outcome, so it
    ///         holds whatever state the fixture reaches. A junior tier may only be funded
    ///         if every tier above it was covered in full.
    function test_Subordination_JuniorTiersOnlyFundedWhenSeniorsAreWhole() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();
        _assertSubordination("draw 1 dormancy");
    }

    function test_Subordination_HoldsAfterSeveralDraws() public {
        _startSeededWithOG();
        for (uint256 d = 0; d < 5; d++) {
            _runStandardDraw();
        }
        _buyAllPlayers(1);
        _proposeAndActivate();
        _assertSubordination("dormancy after five draws");
    }

    function _assertSubordination(string memory whenLabel) internal view {
        // Guard against a vacuous pass. Every check below is an implication of the form
        // "if this tier is funded then...", so with all pools at zero they would all hold
        // while testing nothing. At least one junior tier must actually be funded for this
        // assertion to mean anything.
        assertTrue(
            bulls.dormancyOGPool() > 0
                || bulls.dormancyCasualRefundPool() > 0
                || bulls.dormancyCommitmentPool() > 0
                || bulls.dormancyPerHeadPool() > 0,
            string.concat("no junior tier funded, subordination check would be vacuous at: ", whenLabel)
        );
        // A funded OG tier implies the VC tier was covered.
        if (bulls.dormancyOGPool() > 0) {
            assertTrue(
                bulls.dormancyVCFullCover(),
                string.concat("OG funded while VC short at: ", whenLabel)
            );
        }
        // A funded casual tier implies the OG tier was covered.
        if (bulls.dormancyCasualRefundPool() > 0) {
            assertTrue(
                bulls.dormancyPrincipalFullCover(),
                string.concat("casual funded while OG short at: ", whenLabel)
            );
        }
        // A funded commitment tier implies the casual tier was covered.
        if (bulls.dormancyCommitmentPool() > 0) {
            assertTrue(
                bulls.dormancyCasualFullCover(),
                string.concat("commitment funded while casual short at: ", whenLabel)
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Claims against a seeded game
    // ══════════════════════════════════════════════════════════════════════

    function test_Claim_OgStillPaidWithASeedInPlay() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        uint256 before = usdc.balanceOf(ogA);
        vm.prank(ogA);
        bulls.claimDormancyRefund();
        assertGt(usdc.balanceOf(ogA) - before, 0, "OG refunded from TIER 1");
    }

    function test_Claim_CasualStillPaidWithASeedInPlay() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        address c = players[5];
        uint256 before = usdc.balanceOf(c);
        vm.prank(c);
        bulls.claimDormancyRefund();
        assertGt(usdc.balanceOf(c) - before, 0, "casual refunded from TIER 2");
    }

    /// @notice The VC is not a claimant. Their seed is returned through the settlement
    ///         path, not through claimDormancyRefund, so the wallet has nothing to claim.
    function test_Claim_VcWalletIsNotAClaimant() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        vm.prank(vcWallet);
        vm.expectRevert(IBullsEthCRE.NothingToClaim.selector);
        bulls.claimDormancyRefund();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Settlement: the seed actually gets back to the investor
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The whole point of TIER 0. Reserving a pool is not the same as the money
    ///         reaching the investor, and only the sweep moves it.
    function test_Sweep_MakesTheVcSeedClaimable() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        uint256 reserved = bulls.dormancyVCPool();
        assertGt(reserved, 0, "something is owed");

        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        bulls.sweepDormancyRemainder();

        assertGe(bulls.vcReturnOwed(), reserved, "sweep records the debt to the VC");
    }

    function test_Sweep_VcCanThenWithdraw() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();

        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        bulls.sweepDormancyRemainder();

        uint256 owed = bulls.vcReturnOwed();
        uint256 before = usdc.balanceOf(vcWallet);
        bulls.claimVCReturn();

        assertEq(usdc.balanceOf(vcWallet) - before, owed, "investor receives exactly what was owed");
        assertEq(bulls.vcReturnOwed(), 0, "debt cleared");
    }

    /// @notice L-02 in v1.17 changed this to accumulate rather than assign. The path is
    ///         phase-exclusive today so the bug was latent, but the accumulate behaviour
    ///         is what stops a future writer being silently clobbered.
    function test_Sweep_VcReturnAccumulates() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();
        assertEq(bulls.vcReturnOwed(), 0, "nothing owed before the sweep");

        vm.warp(block.timestamp + DORMANCY_CLAIM_WINDOW + 1);
        bulls.sweepDormancyRemainder();
        assertGt(bulls.vcReturnOwed(), 0, "sweep is what creates the debt");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Conservation with a seed in play
    // ══════════════════════════════════════════════════════════════════════

    function test_Invariant_BalanceCoversAllPoolsIncludingTierZero() public {
        _startSeededWithOG();
        _buyAllPlayers(1);
        _proposeAndActivate();
        _assertSolvent("at activation");

        vm.prank(ogA); bulls.claimDormancyRefund();
        _assertSolvent("after the OG claim");

        vm.prank(players[5]); bulls.claimDormancyRefund();
        _assertSolvent("after a casual claim");
    }

    function _assertSolvent(string memory whenLabel) internal view {
        // Includes treasuryBalance, matching Dormancy.t.sol. The two helpers had diverged:
        // this one summed pools only while its sibling included treasury, so the same-named
        // invariant meant two different things in two files.
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
}
