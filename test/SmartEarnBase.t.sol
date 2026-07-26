// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "./BullsEthBase.t.sol";
import {BullsEth} from "../src/BullsEthCRE.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockSequencer} from "./mocks/MockSequencer.sol";

/// @title  SmartEarnBase
/// @notice The VC-enabled harness BullsEthBase asks for in its own header note.
///         Deploys with a non-zero VC_SEED and calls seedPot(), which turns on the
///         whole SmartEarn layer: seed supplement, T3 cold-start floor, spent-seed
///         return, and the withdraw-treasury reserve.
///
/// @dev    Deployment parameters are the ones Craig recorded as the intended mainnet
///         configuration, not convenient test values:
///           MAX_SEED_RELEASE_RATIO_BPS = 6349, the constructor's own ceiling as of v1.17.
///           The VC-SPENT-CAP guard requires
///           ratio * (10000 + 2500 + 2500) * (10000 + VC_RESERVE_BUFFER_BPS) <= 10000^3
///           (the M-02 fix folded the 5% withdraw-reserve buffer in), so 6349 is now the
///           largest value that deploys. It was 6666 before v1.17.
///           MAX_SEED_PER_DRAW_BPS = 500, the value the SEED-CAP note specifies.
///
///         Inherits every player and lifecycle helper from BullsEthBase. Only setUp
///         is replaced.
abstract contract SmartEarnBase is BullsEthBase {
    /// @dev $100,000 at 6 decimals.
    uint256 internal constant VC_SEED = 100_000_000_000;
    uint256 internal constant MAX_SEED_RELEASE_RATIO_BPS = 6349; // [v1.17/M-02] was 6666
    uint256 internal constant MAX_SEED_PER_DRAW_BPS = 500;

    /// @dev Mirrors of the spent-return constants, for asserting the obligation.
    uint256 internal constant VC_SPENT_RETURN_BPS = 2500;
    uint256 internal constant VC_SPENT_BONUS_BPS = 2500;
    uint256 internal constant VC_SPENT_BONUS_THRESHOLD = 2_000_000_000_000; // $2m

    uint256 internal constant WITHDRAW_START_DRAW = 5;

    address internal vcWallet;

    function setUp() public virtual override {
        vm.warp(1_700_000_000);

        beneficiary = makeAddr("beneficiary");
        vcWallet = makeAddr("vcWallet");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        ethFeed = new MockAggregator(8, ETH_PRICE);
        sequencer = new MockSequencer();

        bulls = new BullsEth(
            address(usdc),
            address(ethFeed),
            address(0), // _ethReserveFeed disabled
            address(0), // _wethFeed disabled
            BASE_PREDICTION,
            address(sequencer),
            beneficiary,
            VC_SEED,
            vcWallet,
            MAX_SEED_RELEASE_RATIO_BPS,
            MAX_SEED_PER_DRAW_BPS
        );

        // The test contract is the deployer and therefore the owner, so it is the
        // party that funds seedPot(). On mainnet this is the operator forwarding
        // the investor's capital.
        usdc.mint(address(this), VC_SEED);
        usdc.approve(address(bulls), type(uint256).max);
        bulls.seedPot();

        vm.label(address(bulls), "BullsEth");
        vm.label(address(usdc), "USDC");
        vm.label(vcWallet, "VC");
    }

    /// @dev Reimplementation of _vcTreasuryObligation(), which is internal. Mirrors
    ///      the contract formula exactly so the assertion tracks the real thing:
    ///      seedReleased + 25% return + 25% bonus when the season is big enough.
    function _vcObligation() internal view returns (uint256) {
        uint256 released = bulls.seedReleased();
        if (released == 0) return 0;
        uint256 ret = (released * VC_SPENT_RETURN_BPS) / 10000;
        uint256 bonus =
            bulls.cumulativeSeasonTreasury() >= VC_SPENT_BONUS_THRESHOLD
                ? (released * VC_SPENT_BONUS_BPS) / 10000
                : 0;
        return released + ret + bonus;
    }

    /// @dev The ceiling the constructor's solvency proof assumes seedReleased obeys.
    function _ratioCeiling() internal view returns (uint256) {
        uint256 c = (bulls.cumulativeSeasonTreasury() * MAX_SEED_RELEASE_RATIO_BPS) / 10000;
        return c > VC_SEED ? VC_SEED : c;
    }

    /// @dev Runs one full draw: buy, resolve, submit the standard cutoffs, complete.
    ///
    ///      NOTE, and it is not incidental: every player must RE-SUBMIT a spread
    ///      prediction each draw. From draw 2 onward a stored prediction is stale, so
    ///      without this every entry auto-defaults to one identical value, ties at a
    ///      difference of zero, and the draw becomes unresolvable (finding H-01). The
    ///      first version of this helper omitted the resubmission and every multi-draw
    ///      test died on DrawNotProgressing. H-01 is not merely a theoretical brick: it
    ///      blocks writing multi-draw tests at all until it is worked around.
    function _runStandardDraw() internal {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]);
            bulls.buyTickets(1);
            vm.prank(players[i]);
            bulls.submitPrediction(BASE_PREDICTION + i);
        }
        _warpToCooldownEnd();
        _resolvePinned();
        bulls.submitCutoffDiffs(9e6, 39e6, 99e6, 10, 40, 100);
        for (uint256 i = 0; i < 20 && uint256(bulls.drawPhase()) != 0; i++) {
            bulls.completeDrawStep();
        }
    }
}
