// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @title  BullsEthHandler
/// @notice The wrapper the invariant fuzzer calls into. Its whole job is to make only LEGAL
///         calls in legal orders, so the fuzzer spends its runs on the game's logic rather
///         than on bouncing off its phase guards.
///
/// @dev    WHY A HANDLER AT ALL. Point Foundry straight at the contract and it generates
///         random calls with random arguments: roughly everything reverts on WrongPhase,
///         DrawInProgress or PicksLocked, and the campaign proves only that the guards
///         guard. The handler is where the 423 unit tests get spent: they are how we know
///         which call is legal in which phase, and this file is that knowledge written down
///         as executable code.
///
///         EVERY ACTION RETURNS SILENTLY RATHER THAN REVERTING when its preconditions are
///         not met. A reverted handler call teaches the fuzzer nothing and, under
///         fail_on_revert, aborts the campaign outright. Silence keeps the sequence moving.
///
///         THE CUTOFF PROBLEM, and it is the one thing that shapes this file. The suite's
///         standard draw submits fixed cutoffs (9e6/39e6/99e6, counts 10/40/100), which
///         reconcile ONLY because every player buys exactly one ticket and predictions form
///         the unique BASE_PREDICTION + i ladder. A fuzzer that varies WHO buys changes the
///         entry count on every draw and those constants stop reconciling immediately.
///
///         So the cutoffs are computed from the actual buyer set instead. The ladder makes
///         that exact rather than approximate: player i predicts BASE + i, so their entry
///         sits at diff i * 1e6, and buyers are recorded in ascending index order. The k-th
///         recorded buyer's index therefore IS the diff that admits exactly k entries. The
///         counts are taken at 2% / 8% / 20%, comfortably inside T1 [0.5,4], T2 [4,12] and
///         T3 [10,50] whatever the buyer count turns out to be.
///
///         SCOPE: LIVE SEASON ONLY. Buy, predict, resolve, submit, step, claim. No emergency
///         reset and no dormancy. Those are where the interesting ordering bugs live, but a
///         handler that cannot complete a clean season first will produce failures nobody
///         can interpret. Second pass.
contract BullsEthHandler is Test {
    BullsEth      public immutable bulls;
    MockERC20     public immutable usdc;
    MockAggregator public immutable ethFeed;

    uint256 internal constant TICKET_PRICE   = 10_000_000;
    uint256 internal constant BASE_PREDICTION = 300_000;
    uint256 internal constant DRAW_COOLDOWN  = 72 hours;
    uint256 internal constant PICK_DEADLINE  = 48 hours;

    /// @dev Below this many buyers the count bands cannot all be satisfied at once, so the
    ///      draw is left un-submitted rather than submitted with numbers that would bounce.
    uint256 internal constant MIN_BUYERS_TO_SETTLE = 60;

    address[] public players;

    /// @dev Buyer indices for the CURRENT draw, ascending. Ascending order is what makes the
    ///      cutoff derivation exact, and it comes for free from iterating players in order.
    uint256[] internal _bought;
    uint256 internal _trackedDraw;

    // ── ghosts, for the invariant file to read ────────────────────────────
    uint256 public ghost_drawsCompleted;
    uint256 public ghost_buysMade;
    uint256 public ghost_claimsMade;

    constructor(BullsEth bulls_, MockERC20 usdc_, MockAggregator feed_, address[] memory players_) {
        bulls   = bulls_;
        usdc    = usdc_;
        ethFeed = feed_;
        for (uint256 i = 0; i < players_.length; i++) players.push(players_[i]);
        _trackedDraw = bulls_.currentDraw();
    }

    // ── internal ──────────────────────────────────────────────────────────

    function _syncDraw() internal {
        uint256 d = bulls.currentDraw();
        if (d != _trackedDraw) { delete _bought; _trackedDraw = d; }
    }

    function _isActiveIdle() internal view returns (bool) {
        return bulls.gamePhase() == IBullsEthCRE.GamePhase.ACTIVE
            && bulls.drawPhase() == IBullsEthCRE.DrawPhase.IDLE;
    }

    function _boughtThisWeek(address p) internal view returns (bool b) {
        (,,,,,,,,,,, b,,) = bulls.getPlayerInfo(p);
    }

    // ── actions ───────────────────────────────────────────────────────────

    /// @notice A pseudo-random slice of the field buys into the open draw. Callable more
    ///         than once per draw: later calls top up the buyer set, which is what a real
    ///         draw window looks like.
    function buy(uint256 seed) external {
        _syncDraw();
        if (!_isActiveIdle()) return;
        if (block.timestamp > bulls.lastDrawTimestamp() + PICK_DEADLINE) return;

        uint256 want = bound(seed, MIN_BUYERS_TO_SETTLE, players.length);
        for (uint256 i = 0; i < want; i++) {
            if (_boughtThisWeek(players[i])) continue;
            vm.prank(players[i]);
            try bulls.buyTickets(1) {
                _bought.push(i);
                ghost_buysMade++;
                // ON THE LADDER AT THE MOMENT OF BUYING, not later and not optionally.
                // The cutoff derivation below is exact only while every buyer's diff is
                // index * 1e6. predict() is optional and prefix-only, so any buyer the
                // fuzzer never reached settled on the global auto-default instead, sat off
                // the ladder, and made the derived counts diverge from what matching
                // actually produced. The draw then bounced until attempts exhausted.
                // Proven by the first campaign run: 488 buys, zero completed draws.
                vm.prank(players[i]);
                try bulls.submitPrediction(BASE_PREDICTION + i) {} catch {}
            } catch { /* cap, lapse or window: not this handler's business */ }
        }
    }

    /// @notice Some buyers change their number mid-window. Kept ON the ladder: a player
    ///         moving off it would break the diff derivation, and the point of this action
    ///         is to exercise submitPrediction, not to scramble the fixture.
    function predict(uint256 seed) external {
        _syncDraw();
        if (!_isActiveIdle()) return;
        if (block.timestamp > bulls.lastDrawTimestamp() + PICK_DEADLINE) return;
        if (_bought.length == 0) return;

        uint256 n = bound(seed, 1, _bought.length);
        for (uint256 k = 0; k < n; k++) {
            uint256 idx = _bought[k];
            vm.prank(players[idx]);
            try bulls.submitPrediction(BASE_PREDICTION + idx) {} catch {}
        }
    }

    /// @notice Settle the draw once the cooldown has run. Publishes a feed round at the slot
    ///         and pins to it, exactly as an honest off-chain caller would.
    function resolve() external {
        _syncDraw();
        if (!_isActiveIdle()) return;
        if (block.timestamp < bulls.lastDrawTimestamp() + DRAW_COOLDOWN) return;
        if (_bought.length == 0) return; // an empty draw is refused by the contract anyway

        uint80 rid = ethFeed.pushRound(ethFeed.latestAnswer());
        try bulls.resolveWeek(rid) {} catch {}
    }

    /// @notice Cutoffs derived from the live buyer set. See the header: the ladder makes the
    ///         k-th buyer's index the exact diff that admits k entries, so the submitted
    ///         counts and the counts matching produces are the same number by construction
    ///         rather than by tuning.
    function submitCutoffs() external {
        _syncDraw();
        if (bulls.drawPhase() != IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION) return;

        uint256 n = _bought.length;
        if (n < MIN_BUYERS_TO_SETTLE) return;

        uint256 c1 = n * 200 / 10000; if (c1 == 0) c1 = 1;   // 2%,  band [0.5, 4]
        uint256 c2 = n * 800 / 10000;                        // 8%,  band [4, 12]
        uint256 c3 = n * 2000 / 10000;                       // 20%, band [10, 50]
        if (c1 > c2 || c2 > c3 || c3 > n) return;

        uint256 d1 = _bought[c1 - 1] * 1e6;
        uint256 d2 = _bought[c2 - 1] * 1e6;
        uint256 d3 = _bought[c3 - 1] * 1e6;

        try bulls.submitCutoffDiffs(d1, d2, d3, c1, c2, c3) {} catch {}
    }

    /// @notice Drive whichever step is due. Permissionless in the contract, so the fuzzer
    ///         drives it as itself rather than as the owner.
    function step() external {
        uint256 before = bulls.currentDraw();
        try bulls.completeDrawStep() {} catch { return; }
        if (bulls.currentDraw() > before) { ghost_drawsCompleted++; _syncDraw(); }
    }

    /// @notice A winner takes their money out. The one action that moves USDC off the
    ///         contract during a live season, so it is where a balance invariant would
    ///         actually break if the accounting were wrong.
    function claim(uint256 seed) external {
        uint256 idx = bound(seed, 0, players.length - 1);
        vm.prank(players[idx]);
        try bulls.claimPrize() { ghost_claimsMade++; } catch {}
    }

    /// @notice Time passes. Bounded so a single jump cannot skip an entire draw window,
    ///         which would starve every other action.
    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1 hours, 30 hours));
    }

    // ── views for the invariant file ──────────────────────────────────────

    function playerCount() external view returns (uint256) { return players.length; }
    function buyersThisDraw() external view returns (uint256) { return _bought.length; }
}
