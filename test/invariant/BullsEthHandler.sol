// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @title  BullsEthHandler
/// @notice The wrapper the invariant fuzzer calls into. Makes only LEGAL calls in legal
///         orders, so the fuzzer spends its runs on the game's logic rather than bouncing
///         off its phase guards.
///
/// @dev    PASS TWO. Adds the destructive paths: emergency reset, dormancy, and the refund
///         claims they unlock. This is where the interesting bugs are, because it is where
///         pools multiply and phases interleave.
///
///         WHAT PASS ONE GOT WRONG ABOUT RECOVERY, since it shaped this design.
///
///         Pass one's warp was blind and could close the 48-hour pick window on an
///         under-bought draw, which stalled the season at draw 1 forever. The stated plan
///         for pass two was that reset would make that stall recoverable. IT DOES NOT. The
///         reset gate reverts NotStuck on IDLE, so a stalled draw sitting in IDLE cannot be
///         reset at all: reset requires a draw IN FLIGHT.
///
///         So recovery is phase-dependent, and the handler routes accordingly:
///           stalled in IDLE, window shut  -> dormancy is the only legal exit
///           stalled mid-draw              -> reset, via timeout or exhausted attempts
///
///         Which is why `sabotageCutoffs` exists. Submitting deliberately wrong counts three
///         times trips CutoffAttemptsExhausted and unlocks the reset IMMEDIATELY, bypassing
///         the 48-hour timeout. That is the organic way to reach a mid-draw stall, and it
///         exercises both arms of the reset gate rather than only the timeout one.
///
///         GHOST SPLIT, and it matters. Pass one counted any currentDraw advance as a
///         completed draw. A reset ALSO advances currentDraw, past a draw nobody played, so
///         that counter conflated clean finalisations with voided ones. Split here, because
///         the identity the contract claims in prose -- clean completions plus resets equals
///         currentDraw - 1 -- cannot be checked otherwise. Note drawsPlayed is NOT a state
///         variable: it is derived at dormancy, so the invariant has to be built from ghosts.
///
///         THE CUTOFF DERIVATION, unchanged from pass one and proven in practice (nine
///         accepted, zero failed). Buyers are recorded in ascending index order and join the
///         BASE_PREDICTION + i ladder at the moment of buying, so the k-th recorded index IS
///         the diff admitting exactly k entries.
contract BullsEthHandler is Test {
    BullsEth       public immutable bulls;
    MockERC20      public immutable usdc;
    MockAggregator public immutable ethFeed;

    uint256 internal constant BASE_PREDICTION   = 300_000;
    uint256 internal constant DRAW_COOLDOWN     = 72 hours;
    uint256 internal constant PICK_DEADLINE     = 48 hours;
    uint256 internal constant DRAW_STUCK_TIMEOUT = 48 hours;
    uint256 internal constant DORMANCY_TIMELOCK = 24 hours;

    uint256 internal constant MIN_BUYERS_TO_SETTLE = 60;
    uint256 internal constant MAX_BUYERS_PER_CALL  = 160;

    /// @dev Forge picks selectors uniformly, so a destructive action needs its own dice gate
    ///      or it fires roughly one call in twelve and every sequence ends in the first few
    ///      draws. These are tuned so the campaign mostly plays a season and occasionally
    ///      breaks one.
    uint256 internal constant DORMANCY_ODDS = 40; // ~2.5% of dormancy calls
    // Raised from 12 after the first campaign observed ZERO sabotages: the honest
    // submitCutoffs fires on every selection while sabotage needs selection AND the dice, so
    // the honest path won the race into MATCHING nearly every time. CutoffAttemptsExhausted
    // under fuzz was a stated goal of this pass, and at 1-in-12 it could sit unexecuted for
    // many campaigns.
    uint256 internal constant SABOTAGE_ODDS = 4;  // ~25% of sabotage calls

    address[] public players;

    uint256[] internal _bought;
    uint256 internal _trackedDraw;

    // ── progress ghosts ──────────────────────────────────────────────────
    /// @dev CLEAN finalisations only. A reset-driven advance is counted separately below,
    ///      because conflating the two is what made pass one's identity uncheckable.
    uint256 public ghost_drawsCompleted;
    uint256 public ghost_resetsCompleted;
    uint256 public ghost_buysMade;
    uint256 public ghost_claimsMade;
    uint256 public ghost_resolvesMade;
    uint256 public ghost_cutoffsAccepted;
    uint256 public ghost_resetsTriggered;
    uint256 public ghost_dormancyActivated;
    uint256 public ghost_refundClaims;
    uint256 public ghost_sabotages;

    // ── diagnostic ghosts: WHY an action did nothing ─────────────────────
    uint256 public ghost_skipWrongPhase;
    uint256 public ghost_skipWindowShut;
    uint256 public ghost_skipTooFewBuyers;
    uint256 public ghost_skipCooldown;
    uint256 public ghost_skipDice;
    uint256 public ghost_failBuy;
    uint256 public ghost_failResolve;
    uint256 public ghost_failCutoffs;
    uint256 public ghost_failStep;
    uint256 public ghost_failReset;
    uint256 public ghost_failDormancy;

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

    function _isDormant() internal view returns (bool) {
        return bulls.gamePhase() == IBullsEthCRE.GamePhase.DORMANT;
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

    // ══════════════════════════════════════════════════════════════════════
    //  Live season
    // ══════════════════════════════════════════════════════════════════════

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
                vm.prank(players[i]);
                try bulls.submitPrediction(BASE_PREDICTION + i) {} catch {}
            } catch { ghost_failBuy++; }
        }
    }

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

    function resolve() external {
        _syncDraw();
        if (!_isActiveIdle())                      { ghost_skipWrongPhase++;   return; }
        if (block.timestamp < _cooldownEnd())      { ghost_skipCooldown++;     return; }
        if (_bought.length < MIN_BUYERS_TO_SETTLE) { ghost_skipTooFewBuyers++; return; }

        uint80 rid = ethFeed.pushRound(ethFeed.latestAnswer());
        try bulls.resolveWeek(rid) { ghost_resolvesMade++; } catch { ghost_failResolve++; }
    }

    function submitCutoffs() external {
        _syncDraw();
        if (bulls.drawPhase() != IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION) {
            ghost_skipWrongPhase++; return;
        }
        uint256 n = _bought.length;
        if (n < MIN_BUYERS_TO_SETTLE) { ghost_skipTooFewBuyers++; return; }

        uint256 c1 = n * 200 / 10000; if (c1 == 0) c1 = 1;
        uint256 c2 = n * 800 / 10000;
        uint256 c3 = n * 2000 / 10000;
        if (c1 > c2 || c2 > c3 || c3 > n) { ghost_skipTooFewBuyers++; return; }

        try bulls.submitCutoffDiffs(
            _bought[c1 - 1] * 1e6, _bought[c2 - 1] * 1e6, _bought[c3 - 1] * 1e6, c1, c2, c3
        ) { ghost_cutoffsAccepted++; } catch { ghost_failCutoffs++; }
    }

    /// @notice Drive whichever step is due, and record WHICH KIND of advance happened.
    ///
    /// @dev    A reset-finalize advances currentDraw exactly as a clean finalize does, past a
    ///         draw nobody played. Pass one counted both as completions, which made the
    ///         contract's own identity (clean + resets == currentDraw - 1) impossible to
    ///         check. resetDrawCount is the contract's own counter for the voided kind, so
    ///         reading it either side of the step is what separates them.
    function step() external {
        uint256 drawBefore  = bulls.currentDraw();
        uint256 resetBefore = bulls.resetDrawCount();

        try bulls.completeDrawStep() {} catch { ghost_failStep++; return; }

        if (bulls.currentDraw() > drawBefore) {
            if (bulls.resetDrawCount() > resetBefore) ghost_resetsCompleted++;
            else                                      ghost_drawsCompleted++;
            _syncDraw();
        }
    }

    function claim(uint256 seed) external {
        uint256 idx = bound(seed, 0, players.length - 1);
        vm.prank(players[idx]);
        try bulls.claimPrize() { ghost_claimsMade++; } catch {}
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Destructive paths
    // ══════════════════════════════════════════════════════════════════════

    /// @notice DELIBERATELY WRONG CUTOFFS, and the only organic route to a mid-draw stall.
    ///
    /// @dev    Counts inside the accepted bands but diffs that admit the wrong number of
    ///         entries: the submission passes validation, matching then produces counts that
    ///         reconcile against nothing, and the draw bounces to CUTOFF_SUBMISSION. Three
    ///         bounces trip CutoffAttemptsExhausted and unlock the reset IMMEDIATELY, without
    ///         the 48-hour timeout.
    ///
    ///         That is what makes both arms of the reset gate reachable. It also fires
    ///         CutoffAttemptsExhausted, which no test had reached.
    function sabotageCutoffs(uint256 seed) external {
        if (seed % SABOTAGE_ODDS != 0) { ghost_skipDice++; return; }
        _syncDraw();
        if (bulls.drawPhase() != IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION) {
            ghost_skipWrongPhase++; return;
        }
        uint256 n = _bought.length;
        if (n < MIN_BUYERS_TO_SETTLE) { ghost_skipTooFewBuyers++; return; }

        // Legal counts, but diffs far too wide for them: T1 claims 2% while its diff admits
        // roughly everyone.
        uint256 c1 = n * 200 / 10000; if (c1 == 0) c1 = 1;
        uint256 c2 = n * 800 / 10000;
        uint256 c3 = n * 2000 / 10000;
        if (c1 > c2 || c2 > c3) { ghost_skipTooFewBuyers++; return; }

        uint256 wide = _bought[n - 1] * 1e6;
        try bulls.submitCutoffDiffs(wide, wide, wide, c1, c2, c3) {
            ghost_sabotages++;
        } catch { ghost_failCutoffs++; }
    }

    /// @notice Emergency reset, which requires a draw IN FLIGHT.
    ///
    /// @dev    The gate reverts NotStuck on IDLE, so this can never rescue a stalled pick
    ///         window: that state's only legal exit is dormancy. Reachable two ways, and the
    ///         handler takes whichever is available: attempts exhausted (immediate, via
    ///         sabotage) or the 48-hour timeout (warped to below).
    function reset() external {
        _syncDraw();
        IBullsEthCRE.DrawPhase p = bulls.drawPhase();
        if (p == IBullsEthCRE.DrawPhase.IDLE
            || p == IBullsEthCRE.DrawPhase.FINALIZING
            || p == IBullsEthCRE.DrawPhase.RESET_FINALIZING) { ghost_skipWrongPhase++; return; }

        // OWNER CEREMONY. emergencyResetDraw is owner-gated; only the UNWINDING
        // continuation opens to anyone else, and then only after a timeout. The handler is
        // the automation forwarder, not the owner, so as first written every reset reverted
        // into its own fail ghost and this entire path was dead. Pranking the owner is the
        // same modelling honesty as the forwarder appointment: this IS an owner operation
        // on mainnet.
        address own = bulls.owner();
        vm.prank(own);
        try bulls.emergencyResetDraw() { ghost_resetsTriggered++; } catch { ghost_failReset++; }
    }

    /// @notice Wind the season down. Dice-gated, because this is terminal for the live
    ///         season and an ungated selector would end most sequences in the first draws.
    ///
    /// @dev    Two calls with a 24-hour timelock between them, and activation additionally
    ///         requires the pick window to have passed. A stalled draw satisfies that
    ///         naturally, which is exactly why this is the stall's exit.
    function dormancy(uint256 seed) external {
        _syncDraw();
        if (!_isActiveIdle()) { ghost_skipWrongPhase++; return; }

        // THE DICE MUST NOT GUARD THE ONLY EXIT. In a STRANDED season -- window shut,
        // under-bought -- dormancy is the sole productive action that remains: buying is
        // locked, the contract refuses to settle an empty draw, and reset reverts NotStuck
        // on IDLE. Gating it behind 1-in-40 left roughly a quarter of stranded sequences
        // with no legal move at all, and the progress assert failed exactly as it should.
        //
        // Found by this suite's own instruments on their first outing: the assert caught the
        // inert sequence and the diagnostic ghosts named the cause without a theory.
        //
        // So the dice apply to a HEALTHY season, where dormancy is one choice among many and
        // an ungated selector would end most sequences in the first few draws. When stranded,
        // it is the only choice, and is always available.
        bool stranded = block.timestamp > _pickDeadline()
            && _bought.length < MIN_BUYERS_TO_SETTLE;
        if (!stranded && seed % DORMANCY_ODDS != 0) { ghost_skipDice++; return; }

        address own = bulls.owner();

        if (bulls.dormancyEffectiveTime() == 0) {
            vm.prank(own);
            try bulls.proposeDormancy() {} catch { ghost_failDormancy++; }
            return;
        }

        if (block.timestamp < bulls.dormancyEffectiveTime()) {
            vm.warp(bulls.dormancyEffectiveTime() + 1);
        }
        if (block.timestamp <= _pickDeadline()) { vm.warp(_pickDeadline() + 1); }

        vm.prank(own);
        try bulls.activateDormancy() { ghost_dormancyActivated++; } catch { ghost_failDormancy++; }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Refund claims
    // ══════════════════════════════════════════════════════════════════════

    /// @notice The waterfall and the reset pools. THE TERMINAL TAIL MATTERS: once dormant,
    ///         every live-season action becomes a wrong-phase skip, so a run that goes
    ///         dormant at draw 6 would waste its remaining 300 calls doing nothing. This is
    ///         what makes those calls productive, and claiming through the waterfall with
    ///         the invariants live is the whole point of allowing dormancy in the campaign.
    function claimRefund(uint256 seed) external {
        uint256 idx = bound(seed, 0, players.length - 1);
        address p = players[idx];

        if (_isDormant()) {
            vm.prank(p);
            try bulls.claimDormancyRefund() { ghost_refundClaims++; } catch {}
            return;
        }

        vm.prank(p);
        try bulls.claimResetRefund() { ghost_refundClaims++; } catch {}
        vm.prank(p);
        try bulls.claimCommitmentRefund() { ghost_refundClaims++; } catch {}
    }

    /// @notice Sweeps, which are permissionless and phase-sensitive: the reset remainder
    ///         returns to the pot while the game runs and to the beneficiary once it does
    ///         not, so this is worth reaching in both states.
    function sweep() external {
        try bulls.sweepResetRefundRemainder() {} catch {}
        try bulls.sweepDormancyRemainder() {} catch {}
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Time
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Phase-aware, and now with the stall DELIBERATELY reachable.
    ///
    /// @dev    Pass one forbade closing the pick window because the stall was a dead end
    ///         with no legal continuation. It still is not reset-recoverable -- the gate
    ///         reverts NotStuck on IDLE -- but dormancy IS a legal exit from it, and that
    ///         exit is now in the handler. So a small share of warps are allowed to strand
    ///         the window on purpose, which is how stall-then-dormancy gets explored.
    ///
    ///         Mid-draw, time is pushed past DRAW_STUCK_TIMEOUT often enough that the
    ///         timeout arm of the reset gate is reachable and not only the sabotage arm.
    function warp(uint256 seed) external {
        _syncDraw();

        if (_isActiveIdle()) {
            uint256 deadline = _pickDeadline();

            if (_bought.length < MIN_BUYERS_TO_SETTLE) {
                // One warp in eight strands the window on purpose. Rare, because a stranded
                // draw ends the live season unless dormancy picks it up.
                if (seed % 8 == 0) { vm.warp(deadline + 1 hours); return; }
                if (block.timestamp + 1 >= deadline) { ghost_skipWindowShut++; return; }
                vm.warp(block.timestamp + bound(seed, 1, deadline - block.timestamp - 1));
                return;
            }

            uint256 slot = _cooldownEnd();
            if (block.timestamp < slot) { vm.warp(slot); return; }
        }

        // Mid-draw: sometimes long enough to unlock the reset timeout.
        if (seed % 5 == 0) { vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1 hours); return; }
        vm.warp(block.timestamp + bound(seed, 1 hours, 6 hours));
    }

    // ── views ─────────────────────────────────────────────────────────────

    function playerCount() external view returns (uint256) { return players.length; }
    function buyersThisDraw() external view returns (uint256) { return _bought.length; }
}
