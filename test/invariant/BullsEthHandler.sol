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
/// @dev    THE BUG THIS VERSION FIXES, because it is the interesting part.
///
///         The first handler had a `warp` action that advanced 1 to 30 hours blindly, picked
///         roughly one call in seven. Three or four of those before the first `buy` and the
///         48-hour pick window had shut. From that moment the draw was UNRECOVERABLE: `buy`
///         returns early because picks are locked, and `resolve` cannot fire because the
///         contract refuses a draw with no entries. Draw 1 forever, 12,800 calls, zero buys.
///
///         Two lessons, both worth keeping.
///
///         TIME IS AN ACTION AND NEEDS THE SAME CARE AS THE OTHERS. A handler action that
///         moves the clock without regard to phase can close a window nothing reopens.
///         `warp` below is now phase-aware: while a draw is open and under-bought it may
///         only move WITHIN the window, and once there are enough buyers it jumps straight
///         to the cooldown so settlement becomes reachable.
///
///         AND SILENCE HID IT. Every action returns quietly when its preconditions fail,
///         which is right, but it made "not applicable now" and "cannot ever work" look
///         identical: 1,829 buy calls, zero reverts, zero buys. Every action now counts WHY
///         it did nothing, so the next failure names its own cause instead of needing a
///         theory.
///
///         THE CUTOFF DERIVATION. The suite's standard draw submits fixed cutoffs, which
///         reconcile only because everyone buys one ticket on the BASE_PREDICTION + i
///         ladder. A fuzzer that varies who buys breaks those constants immediately, so
///         cutoffs are computed from the live buyer set: buyers are recorded in ascending
///         index order, so the k-th recorded index IS the diff admitting exactly k entries.
///         Buyers join the ladder AT THE MOMENT OF BUYING, because a buyer who never
///         predicted settles on the auto-default, sits off the ladder, and makes the derived
///         counts diverge from what matching produces.
///
///         SCOPE: LIVE SEASON ONLY. No emergency reset, no dormancy. Second pass.
contract BullsEthHandler is Test {
    BullsEth       public immutable bulls;
    MockERC20      public immutable usdc;
    MockAggregator public immutable ethFeed;

    uint256 internal constant BASE_PREDICTION = 300_000;
    uint256 internal constant DRAW_COOLDOWN   = 72 hours;
    uint256 internal constant PICK_DEADLINE   = 48 hours;

    /// @dev Below this many buyers the three count bands cannot all be satisfied at once.
    uint256 internal constant MIN_BUYERS_TO_SETTLE = 60;
    /// @dev Ceiling on one buy call, so a single handler action cannot exhaust the gas
    ///      budget iterating the whole field.
    uint256 internal constant MAX_BUYERS_PER_CALL  = 160;

    address[] public players;

    uint256[] internal _bought;
    uint256 internal _trackedDraw;

    // ── progress ghosts ──────────────────────────────────────────────────
    uint256 public ghost_drawsCompleted;
    uint256 public ghost_buysMade;
    uint256 public ghost_claimsMade;
    uint256 public ghost_resolvesMade;
    uint256 public ghost_cutoffsAccepted;

    // ── diagnostic ghosts: WHY an action did nothing ─────────────────────
    // Without these, a stuck campaign reports thousands of calls, zero reverts and zero
    // effect, and the cause has to be guessed. These make the next failure self-describing.
    uint256 public ghost_skipWrongPhase;
    uint256 public ghost_skipWindowShut;
    uint256 public ghost_skipTooFewBuyers;
    uint256 public ghost_skipCooldown;
    uint256 public ghost_failBuy;
    uint256 public ghost_failResolve;
    uint256 public ghost_failCutoffs;
    uint256 public ghost_failStep;

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

    function _pickDeadline() internal view returns (uint256) {
        return bulls.lastDrawTimestamp() + PICK_DEADLINE;
    }

    function _cooldownEnd() internal view returns (uint256) {
        return bulls.lastDrawTimestamp() + DRAW_COOLDOWN;
    }

    // ── actions ───────────────────────────────────────────────────────────

    /// @notice A prefix of the field buys into the open draw. A PREFIX rather than a random
    ///         subset, deliberately: the cutoff derivation needs buyer indices in ascending
    ///         order, and iterating from zero gives that for free. Callable repeatedly to
    ///         top the set up, which is what a real draw window looks like.
    function buy(uint256 seed) external {
        _syncDraw();
        if (!_isActiveIdle())                  { ghost_skipWrongPhase++;  return; }
        if (block.timestamp > _pickDeadline()) { ghost_skipWindowShut++;  return; }

        uint256 want = bound(seed, MIN_BUYERS_TO_SETTLE, MAX_BUYERS_PER_CALL);
        if (want > players.length) want = players.length;

        for (uint256 i = 0; i < want; i++) {
            if (_boughtThisWeek(players[i])) continue;
            vm.prank(players[i]);
            try bulls.buyTickets(1) {
                _bought.push(i);
                ghost_buysMade++;
                // ON THE LADDER AT THE MOMENT OF BUYING. A buyer who never predicts settles
                // on the global auto-default, sits off the ladder, and breaks the derivation.
                vm.prank(players[i]);
                try bulls.submitPrediction(BASE_PREDICTION + i) {} catch {}
            } catch { ghost_failBuy++; }
        }
    }

    /// @notice Some buyers move their number. Kept ON the ladder: this action exists to
    ///         exercise submitPrediction, not to scramble the fixture.
    function predict(uint256 seed) external {
        _syncDraw();
        if (!_isActiveIdle())                  { ghost_skipWrongPhase++;   return; }
        if (block.timestamp > _pickDeadline()) { ghost_skipWindowShut++;   return; }
        if (_bought.length == 0)               { ghost_skipTooFewBuyers++; return; }

        uint256 n = bound(seed, 1, _bought.length);
        for (uint256 k = 0; k < n; k++) {
            uint256 idx = _bought[k];
            vm.prank(players[idx]);
            try bulls.submitPrediction(BASE_PREDICTION + idx) {} catch {}
        }
    }

    /// @notice Settle once the cooldown has run, pinning to a round published at the slot.
    function resolve() external {
        _syncDraw();
        if (!_isActiveIdle())                      { ghost_skipWrongPhase++;   return; }
        if (block.timestamp < _cooldownEnd())      { ghost_skipCooldown++;     return; }
        if (_bought.length < MIN_BUYERS_TO_SETTLE) { ghost_skipTooFewBuyers++; return; }

        uint80 rid = ethFeed.pushRound(ethFeed.latestAnswer());
        try bulls.resolveWeek(rid) { ghost_resolvesMade++; } catch { ghost_failResolve++; }
    }

    /// @notice Cutoffs derived from the live buyer set. The ladder makes the k-th buyer's
    ///         index the exact diff admitting k entries, so submitted counts and matched
    ///         counts agree by construction rather than by tuning.
    function submitCutoffs() external {
        _syncDraw();
        if (bulls.drawPhase() != IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION) {
            ghost_skipWrongPhase++; return;
        }

        uint256 n = _bought.length;
        if (n < MIN_BUYERS_TO_SETTLE) { ghost_skipTooFewBuyers++; return; }

        uint256 c1 = n * 200 / 10000; if (c1 == 0) c1 = 1;   // 2%,  band [0.5, 4]
        uint256 c2 = n * 800 / 10000;                        // 8%,  band [4, 12]
        uint256 c3 = n * 2000 / 10000;                       // 20%, band [10, 50]
        if (c1 > c2 || c2 > c3 || c3 > n) { ghost_skipTooFewBuyers++; return; }

        try bulls.submitCutoffDiffs(
            _bought[c1 - 1] * 1e6,
            _bought[c2 - 1] * 1e6,
            _bought[c3 - 1] * 1e6,
            c1, c2, c3
        ) { ghost_cutoffsAccepted++; } catch { ghost_failCutoffs++; }
    }

    /// @notice Drive whichever step is due. Permissionless in the contract.
    function step() external {
        uint256 before = bulls.currentDraw();
        try bulls.completeDrawStep() {} catch { ghost_failStep++; return; }
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

    /// @notice TIME, AND THIS IS THE ACTION THAT BROKE THE FIRST CAMPAIGN.
    ///
    /// @dev    A blind clock advance can close the pick window while a draw is still
    ///         under-bought, and nothing reopens it: buying is locked and the contract
    ///         refuses to settle a draw with no entries. The season stalls at draw 1 and
    ///         every invariant passes trivially forever.
    ///
    ///         So time is phase-aware. Under-bought and open: move only WITHIN the window,
    ///         never past it. Enough buyers: jump straight to the cooldown so settlement
    ///         becomes reachable. Mid-draw: a small step, since those phases advance on
    ///         calls rather than on the clock.
    ///
    ///         This constrains the fuzzer, which is a real cost and worth stating plainly:
    ///         the campaign no longer explores "what if everyone stops buying". That belongs
    ///         in a separate campaign with its own invariants, not smuggled in as a deadlock
    ///         that silently disables every property at once.
    function warp(uint256 seed) external {
        _syncDraw();

        if (_isActiveIdle()) {
            uint256 deadline = _pickDeadline();

            if (_bought.length < MIN_BUYERS_TO_SETTLE) {
                // The window must stay open or this draw can never settle.
                if (block.timestamp + 1 >= deadline) { ghost_skipWindowShut++; return; }
                uint256 room = deadline - block.timestamp - 1;
                vm.warp(block.timestamp + bound(seed, 1, room));
                return;
            }

            // Enough buyers: make settlement reachable rather than drifting toward it.
            uint256 slot = _cooldownEnd();
            if (block.timestamp < slot) { vm.warp(slot); return; }
        }

        vm.warp(block.timestamp + bound(seed, 1 hours, 6 hours));
    }

    // ── views ─────────────────────────────────────────────────────────────

    function playerCount() external view returns (uint256) { return players.length; }
    function buyersThisDraw() external view returns (uint256) { return _bought.length; }
}
