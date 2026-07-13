// SPDX-License-Identifier: BUSL-1.1
// Change Date: 24 February 2030. On the Change Date, available under MIT.

pragma solidity 0.8.24;

/**
 * @title  BullsEthCRE v1.11a
 * @notice 30-draw ETH/USD prediction game. 72h draw cycle, 90-day season.
 *
 *         PRE-CRE-FORK HISTORY: the full provenance trail (NearestTheETH_Base_1Y v1.86
 *         fork through BullsEth v2.35) is in CHANGELOG-BullsEthCRE-history.md, moved out
 *         of this header for readability [v0.13 audit packaging rec]. Only the CRE arc
 *         (v0.1 onward) is retained below.
 *
 *         ─── CRE FORK CHANGELOG ──────────────────────────────────────────────
 *         BullsEthCRE v0.1 (base: BullsEth v2.35)
 *           SmartEarn (VCEarnout): seedPot(), claimVCReturn(), seed supplement,
 *           2-tier exclusive performance bonus. Flat 25% treasury (was 15%/10%).
 *           OG return curve rescaled 10-50% (was 30-90%). Dormancy: VC TIER 0
 *           above OGs. OG pool uses target-return (not full principal). Dormancy
 *           waterfall stores dormancyAvgTargetReturnBps.
 *
 *         BullsEthCRE v0.2
 *           HIGH-01: draw-30 surplus reserves VC seed before distributing (4 sites).
 *           LOW-01: seedPot() restricted to onlyOwner + PREGAME phase gate.
 *           LOW-02: NatSpec sweep (stale 15%/90% rates, checkSolvency 9000→5000).
 *
 *         BullsEthCRE v0.3
 *           MEDIUM-01: OG dormancy refund changed from target-return to pro-rata
 *           unplayed draws. New state var dormancyDrawsPlayed. dormancyTotalOGEntitlement
 *           now = upfrontOGPrincipal * 75% * drawsUnplayed / TOTAL_DRAWS.
 *           SYNC sweep: vcReturnOwed + dormancyVCPool added to 3 inline SolvencyAlerts.
 *           Version string fixed to v0.3. Remaining NatSpec pass.
 *
 *         BullsEthCRE v0.4
 *           SE-H-01 (HIGH): SeedNotDeposited guard in startGame().
 *           SE-M-01 (MEDIUM): vcBonusEscrow — bonus moves from treasury to escrow
 *           at tier crossing; constructor invariants added; withdrawTreasury floor
 *           protects next un-escrowed tier; closeGame/sweepDorm use escrow not
 *           _vcBonusAmount(). vcBonusEscrow added to all 5 solvency sites.
 *           DR-M-01 (MEDIUM): weekly OGs removed from OG dormancy pool; claim
 *           current-draw ticket net from casual pool only. New state var
 *           currentDrawWeeklyOGNetTicketTotal. dormancyTotalOGEntitlement now
 *           upfront OGs only.
 *
 *         BullsEthCRE v0.5
 *           DR-M-02 (MEDIUM): pregame weekly OG net folded into
 *           currentDrawWeeklyOGNetTicketTotal at startGame() — closes draw-1
 *           dormancy pool-sizing gap.
 *           DR-L-01 (LOW): per-head share added to weekly OG claimDormancyRefund branch.
 *           NS sweep: _vcBonusAmount caller list, ogCancelRefund var comment,
 *           withdrawTreasury rate list, cancelOGRegistration 15%/10% rate,
 *           DORMANCY INHERITED UNCHANGED header line.
 *         BullsEthCRE v0.6
 *           MEDIUM-01: sweepFailedPregame() now returns a deposited VC seed to
 *           VC_SEED_RETURN_ADDRESS atomically, BEFORE the protocol-beneficiary sweep.
 *           Without this, a seed deposited via seedPot() but never started was swept
 *           to PROTOCOL_BENEFICIARY — a misroute of investor principal. Mirror of the
 *           SE-H-01 guard. New event FailedPregameSeedReturned. seedReleased is 0 in
 *           PREGAME so the full VC_SEED is returned; capped at usdcBalance for safety.
 *           LOW-01: registerAsOG() now mirrors registerAsWeeklyOG()'s startGameProposedAt
 *           guard (reverts TimelockPending once a start is proposed). Stops a late upfront
 *           OG having their decline window silently truncated and made permanent at start,
 *           voiding the 75% cancellation right.
 *           INFO-01: stale treasury-rate documentation swept. Deprecated helpers
 *           _getDrawTreasuryBps / _getHistoricalTreasuryBps NatSpec (1500→2500),
 *           OG_TREASURY_BPS "coincidentally matches" claim corrected (now differs),
 *           LAUNCH_TREASURY_BPS_D1_2/D3_4 references, and inline buyTickets /
 *           claimCommitmentRefund 15%→25% comments. Code was correct; only docs lied.
 *           INFO-02: claimVCReturn() and dormancyVCPool documented — senior tier reserved
 *           at activateDormancy() but only payable after the 90-day DORMANCY_CLAIM_WINDOW.
 *           INFO-03: withdrawTreasury PREGAME guard moved above the bonus-protection block
 *           for one deterministic revert reason on a pregame withdrawal attempt.
 *           INFO-04: SYNC notes added to the _calculatePrizePools() draw-30 holdback and
 *           the closeGame() VC reservation, flagging them as a load-bearing pair.
 *         BullsEthCRE v0.7
 *           M-01 (MEDIUM): dormancy per-head denominator now sized on CLAIMABLE heads.
 *           Was upfrontOGCount + weeklyOGCount + weeklyNonOGPlayers.length. weeklyOGCount
 *           counted active weekly OGs who had not bought the current draw; they revert
 *           NothingToClaim before the per-head block, so they never claimed their slice,
 *           which diluted everyone and swept to the beneficiary. Added
 *           currentDrawWeeklyOGBuyerCount (incremented per weekly-OG buy, folded with the
 *           pregame weekly OG head count at startGame, cleared each draw and on reset) and
 *           used it in place of weeklyOGCount. Also restructured the upfront-OG claim so an
 *           upfront OG still receives their per-head share when the OG principal pool is
 *           empty (was reverting before the per-head block); reverts only if the combined
 *           refund is zero.
 *           L-01 (LOW): getContractVersion() returned "BullsEthCRE_v0.5". Now v0.7.
 *           L-02 (LOW): constructor NatSpec now documents all 8 VC/SmartEarn params,
 *           including the "0 disables" semantics for _vcSeed and the tier exclusivity rules.
 *           L-04 (LOW): _vcSeedReturnAddress now also rejects address(this), matching every
 *           other address input. A self-address would strand VC principal in claimVCReturn().
 *           NOTE: L-03 (one-draw requiredEndPot transient after emergency reset) left as a
 *           documented, self-healing transient. INFO-01..04 from the v0.6 cold read deferred.
 *           CRE migration of the Automation trigger/compute seams tracked as v0.8.
 *         BullsEthCRE v0.8
 *           CR-M-02 (MEDIUM): checkSolvency() floor now includes the unreleased VC seed
 *           (VC_SEED - seedReleased), making the pre-flight floor bit-identical to the
 *           requiredEndPot startGame() enforces. In PREGAME seedReleased == 0, so the full
 *           VC_SEED is added back. Closes a preview-vs-start floor disagreement.
 *           CR-L-01 (LOW): seedReleased over-rollback on emergency reset during partial
 *           DISTRIBUTING fixed by DEFERRAL. The seedReleased += supplement increment moved
 *           out of _calculatePrizePools() into _finalizeWeekCore() (guarded !isResetFinalize),
 *           placed before the currentDrawSeedSupplement clear and before the calibration/
 *           snapshot reads. A reset never reaches finalize, so the supplement is never counted
 *           as released and the rollback block in emergencyResetDraw() was DELETED entirely.
 *           Provably correct: seedReleased moves only when a draw finalizes cleanly. Confirmed
 *           no state-mutating reader of seedReleased sits between _calculatePrizePools() and _finalizeWeekCore()
 *           (distribution does not read it). SeedSupplementPaid still emits the accurate
 *           post-increment cumulative figure.
 *           NS-L-01 (NatSpec, LOW): requiredEndPot formula docs updated in two places to
 *           include the VC-seed term: OGObligationLocked event @dev and
 *           getProjectedEndgamePerOG() @return potHealth.
 *           NOTE: This is audit hardening. The Automation-to-CRE seam migration
 *           (checkUpkeep/performUpkeep trigger and submitCutoffDiffs() compute) is still
 *           ahead and is the time-sensitive work given the Automation sunset (v1.x Jun 30,
 *           v2.1 Jul 31 2026). It will be written against the current migration guide.
 *         BullsEthCRE v0.9
 *           B-L-01 (LOW, only code change): sweepFailedPregame() now reconciles
 *           treasuryBalance down to actual USDC holdings after the seed return. On the
 *           clean-close path, players reclaim their full commitment (including treasury
 *           slice) via claimSignupRefund() while treasuryBalance still records those slices;
 *           after the seed return the recorded balance could exceed holdings, making a later
 *           withdrawTreasury() revert in SafeERC20 (funds safe, owner claim unbacked). One
 *           line: if (treasuryBalance > usdcBalance) treasuryBalance = usdcBalance. No other
 *           behavioural change in the contract.
 *           B-I-01 / WORST-CASE #7: partial-DISTRIBUTING reset with an active seed supplement
 *           repays the VC the already-distributed slice at closeGame()/dormancy. Conservative
 *           (favours investor), matches pre-v0.8 economics. Documented, not code-changed.
 *           NS-L-01: withdrawTreasury() requiredEndPot formula completed (third location; the
 *           v0.8 sweep updated two). NS-L-02: _vcBonusAmount() caller list corrected
 *           (withdrawTreasury no longer calls it; only getVCBonusStatus does). NS-L-03:
 *           getSolvencyStatus() @return now lists dormancyVCPool, vcReturnOwed, vcBonusEscrow
 *           (always in the maths, omitted from the doc). NS-I-01: SeedSupplementPaid
 *           totalSeedReleased documented as provisional pre-finalize (CR-L-01). NS-I-02:
 *           emergencyResetDraw() @notice corrected (draw voided and number consumed, not
 *           replayed under the same number). NS-I-03: seedReleased declaration comment updated
 *           for the deferral. IC-L-01: currentDrawSeedSupplement declaration comment updated
 *           (consumer is _finalizeWeekCore, not the deleted rollback). IC-L-02: claimCommitmentRefund
 *           "NET (85%)" corrected to 75% at TREASURY_BPS 2500. IC-I-01: activateDormancy pro-rata
 *           example reworded in unambiguous drawsPlayed terms. IC-I-02: WORST-CASE #7 added.
 *         BullsEthCRE v0.10
 *           D-L-01 (LOW): proposeDormancy() now cancels a pending seed-release-ratio proposal
 *           (mirroring the feed-change cancel). executeSeedReleaseRatio() has no phase gate and
 *           seedReleaseRatioBps is read only in _calculatePrizePools() (ACTIVE only), so a proposal
 *           left pending into DORMANT/CLOSED was orphaned governance state (v1.77/v1.80 class).
 *           Zero fund impact. NOT cancelled in emergencyResetDraw (reset resumes ACTIVE).
 *           D-I-01 (design decision -- OPTION B chosen): a weekly OG restored by _continueUnwind()
 *           after a voided draw now has lastActiveWeek advanced to lastResetDraw. Previously
 *           consecutiveWeeks was preserved but lastActiveWeek was not, so the next buy tripped
 *           gap-detection in _updateStreakTracking() and wiped the streak to 1; with
 *           WEEKLY_OG_QUALIFICATION_WEEKS == TOTAL_DRAWS and one draw number consumed by the reset,
 *           endgame became unreachable while the OG kept paying for active status. One storage write
 *           (p.lastActiveWeek = lastResetDraw) makes the reset cost the player nothing toward
 *           qualification -- consistent with the "not player fault" restoration rationale.
 *           NS-L-01: proposeSeedReleaseRatio() @notice documents phase gates (ACTIVE + IDLE) and
 *           7-day effective timing (earliest supplement ~draw 3-4). NS-I-01: getVCBonusStatus() @dev
 *           clarifies currentBonus is nominal; vcBonusEscrow is the funded truth post SE-M-01.
 *           NS-I-02: WORST-CASE #5 runbook note added for the Option B streak preservation.
 *           NOTE: per audit packaging rec, these fixes are intended to fold into the
 *           Automation-to-CRE migration (the priority workstream; Automation v2.1 sunsets
 *           31 Jul 2026). Versioned as v0.10 here so the fixes are not left unversioned; the
 *           CRE migration lands as v1.0 of the fork on top of this.
 *         BullsEthCRE v0.11
 *           D4-M-01 (MEDIUM): completes D-I-01. v0.10 advanced lastActiveWeek (stopping the
 *           gap-detector streak wipe) but the restored OG never bought the voided draw, so
 *           consecutiveWeeks maxed at 29 vs WEEKLY_OG_QUALIFICATION_WEEKS (30) -- qualification
 *           still unreachable, while three v0.10 doc sites claimed it was preserved (docs promising
 *           a money-affecting behaviour the code did not deliver). Fix: p.consecutiveWeeks++ in the
 *           _continueUnwind() restore branch, before the qualifiedWeeklyOGCount check, crediting the
 *           voided draw the OG could not buy. Traced safe: 29->30 crossing counts a genuine new
 *           qualification (branch previously unreachable on restore); already-qualified OGs remain
 *           symmetric (decremented at loss, incremented here); multi-reset seasons credit distinct
 *           voided draws with no double-count. EarnedOGQualified intentionally NOT emitted on the
 *           restore crossing (count is source of truth; documented). Cosmetic: an already-qualified
 *           restored OG may read one above the season max in getPlayerInfo; all qualification logic
 *           uses >= so no functional effect. WORST-CASE #5 doc corrected to the true two-part fix.
 *           D4-I-01 (INFO): executeSeedReleaseRatio() gained ACTIVE + IDLE gates for uniformity with
 *           sibling execute functions. Prior mid-draw/any-phase execution was harmless (ratio read
 *           once per draw, next-draw effective) but was a review asymmetry. cancelSeedReleaseRatio()
 *           stays ungated by design.
 *           NS-L-01: @return tags added to getSeedReleaseStatus() (7 values) and getVCBonusStatus()
 *           (6 values), the last untagged multi-value views. maxReleasable documented as a CEILING
 *           that ignores the threshold gate and per-draw cap -- not a next-draw release prediction.
 *           NOTE: fold into the CRE migration per packaging rec; CRE lands as v1.0 of the fork.
 *         BullsEthCRE v0.12
 *           D5-L-01 (LOW, OPTION A chosen): emergency-reset draws no longer count as played in
 *           upfront OG dormancy pro-rata. Each reset consumes a draw number (currentDraw++ at
 *           reset-finalize) without a play, so raw (currentDraw - 1) over-stated draws played,
 *           shaving ~$15 net per OG per reset off the OG pool and shifting it down the waterfall.
 *           Fix: new state var resetDrawCount (storage-appended after dormancyDrawsPlayed,
 *           layout-safe), incremented once per completed reset in _finalizeWeekCore()'s
 *           isResetFinalize branch (verified once-per-reset: RESET_FINALIZING is set only after
 *           the final unwind batch, and _finalizeWeekCore flips to IDLE at end, so no re-entry).
 *           activateDormancy() subtracts it from drawsPlayed (floor 0, before the TOTAL_DRAWS cap).
 *           Gives upfront OGs the same "a reset costs the player nothing" treatment D4-M-01 gave
 *           weekly OGs. WORST-CASE #8 added.
 *           NS-L-01: MAX_TARGET_RETURN_BPS @dev stale "estReturnBps = 9000" corrected to 5000,
 *           matching the constant declaration (pre-CRE rescale leftover).
 *           DEFERRED (need exact hunks from the full audit report to place precisely): NS-I-01
 *           (OG cost phrasing), NS-I-02 (bonus-view supplement note), IC-I-01 (natural-close orphan
 *           note), and the solver-transient @dev. These are doc-only, zero bytecode; will fold into
 *           the CRE migration once the report's line-level hunks are available.
 *           NOTE: CRE migration remains the clock (Automation v2.1 sunsets 31 Jul 2026); CRE lands
 *           as v1.0 of the fork with these fixes folded in.
 *         BullsEthCRE v0.13 (documentation only -- ZERO bytecode change)
 *           Clears the four doc items v0.12 deferred, applied verbatim from the v0.12 cold-read
 *           report's exact hunks, plus one fresh informational note. v0.12 graded 0C/0H/0M/0L on
 *           code; D5-L-01 was verified provably exact (invariant currentDraw-1 == drawsPlayed +
 *           resetDrawCount, brute-forced over 100k sequences). No code finding remains.
 *           NS-I-01 (HUNK 1): OG_UPFRONT_COST comment clarified -- $600 is 1x a weekly OG's full
 *           30-draw season (30 x $20) and 2x a single-ticket casual season, not the ambiguous
 *           "2x total season cost".
 *           NS-I-02 (HUNK 2): getDraw30BonusStatus() perDrawEstimate @return notes it excludes any
 *           active seed supplement (the live siphon includes it), so on supplement draws the real
 *           contribution is higher. Monitoring only.
 *           IC-I-01 (HUNK 3): proposeDormancy() documents the natural-close orphan -- a pending
 *           seed-ratio proposal is NOT auto-cancelled on the ordinary draw-30 -> CLOSED path;
 *           post D4-I-01 it cannot execute after CLOSED (ACTIVE-gated), cancelSeedReleaseRatio()
 *           is the cleanup path, and this is parity with every other governance proposal.
 *           Solver transient (HUNK 4): _calculatePrizePools() documents that on a supplement draw
 *           requiredEndPot overstates the floor by ~one supplement for the single solver call
 *           (seedReleased deferred to finalize per CR-L-01). Direction is CONSERVATIVE and
 *           self-heals at finalize. No behavioural change.
 *           NS-I-A (fresh INFO): the resetDrawCount floor guard in activateDormancy() annotated as
 *           provably defensive-only (the invariant guarantees _drawsPlayed >= resetDrawCount).
 *         BullsEthCRE v1.11a
 *           B-L-01 (LOW): getRequiredCutoffDiffBounds() min values now use CEILING division to
 *           match submitCutoffDiffs()'s acceptance check (floor(count*10000/snapshot) >= MIN_BPS).
 *           The v1.54 floor-with-"if 0 then 1" patch fixed only the zero case; counts of 1 or 2
 *           could still be under-reported and rejected (e.g. snapshot=500, T1 MIN 50: floor 2 but
 *           2*10000/500=40 < 50; true min ceil(2.5)=3). t1/t2/t3 Min now (snapshot*MIN+9999)/10000.
 *           MAX side stays floor (conservative under-report by <=1, harmless), commented so it is
 *           not "fixed" the wrong way. Restores the documented Layer-3 keeper pre-validation.
 *           B-L-02 (LOW): claimVCReturn() is FULLY PERMISSIONLESS from settlement [updated at
 *           CRE v1.0]. Anyone may trigger the return the moment the game is settled; there is no
 *           owner gate and no time gate. Destination is immutable (VC_SEED_RETURN_ADDRESS) and the
 *           amount deterministic (vcReturnOwed), so no caller can misdirect or withhold it. This
 *           supersedes the earlier owner-any-time / anyone-after-180-day design; ENDGAME_SWEEP_WINDOW
 *           no longer gates this function (the constant remains for the endgame/prize sweeps).
 *           NS-I-01: sweepDormancyRemainder() @dev documents it is intentionally permissionless
 *           (fixed destinations, time-gated), pre-empting a missing-access-control flag.
 *           NS-I-02: getVCBonusStatus() gates the !enabled early return before computing
 *           _vcBonusAmount() (gate-first house style; avoids wasted view work).
 *           PACKAGING: pre-CRE-fork changelog (NearestTheETH v1.86 through BullsEth v2.35) moved to
 *           CHANGELOG-BullsEthCRE-history.md; header now carries only the CRE arc for readability
 *           [v0.13 audit rec]. Zero bytecode effect.
 *           This is the last economics-side pass. Next build is CRE v1.0: the Automation-to-CRE seam
 *           migration (checkUpkeep/performUpkeep/submitCutoffDiffs), the time-sensitive workstream
 *           (Automation v2.1 sunsets 31 Jul 2026), written against the current Chainlink guide.
 *         ─────────────────────────────────────────────────────────────────────
 *         CRE ARC (v1.0 - v1.04). Full per-version detail in CHANGELOG-BullsEthCRE-v1.x.md files.
 *         v1.0: CRE seam (Option B, native onReport dispatch). onReport(bytes,bytes) gated to
 *           creForwarder decodes (uint8 action, bytes payload) and routes to internal cores; 6
 *           actions (1 SUBMIT_CUTOFFS, 2 ADVANCE, 3 AUTO_PICKS, 4 PRUNE, 5 CLOSE_GAME, 6
 *           RESOLVE_WEEK). resolveWeek/submitCutoffDiffs/closeGame split into wrapper+core; five
 *           direct-call auth sites also accept creForwarder. claimVCReturn made FULLY PERMISSIONLESS
 *           [B-L-02] (immutable destination, deterministic amount; supersedes the v0.14 time gate).
 *           getRequiredCutoffDiffBounds MIN bounds use ceiling division [B-L-01].
 *         v1.01: SEED-CAP constructor guard -- a seeded game (VC_SEED>0) may not deploy with
 *           maxSeedPerDrawBps==0 (the only anti-dump bound). DORM-FLOOR: requiredEndPot became
 *           max(endgame, live dormancy obligation) to protect dormancy. [Both revised below.]
 *         v1.02: LOW-01 draw-1 breath clamp (initialBreath cannot push the pot below the floor
 *           before the solver takes over at draw 2). DORM-FLOOR-2: dropped the current-draw refund
 *           term from the floor (self-covering in IDLE), fixing an OG-heavy launch block.
 *         v1.03: CASUAL-GATE -- health-gated current-pot dormancy floor on distribution. [Revised
 *           at v1.04.]
 *         v1.03a: record-fixes -- claimVCReturn docs aligned to the permissionless code; version
 *           header/string reconciled; upfrontOGCount conservatism note. Seed-supplement + gate
 *           interaction proven and simulated floor-neutral.
 *         v1.04: FLOOR SPLIT [B-M-02]. requiredEndPot is now the ENDGAME target only (season-end,
 *           for the solver + startGame sim), matching checkSolvency() bit-for-bit [B-M-01 / CR-M-02
 *           preserved]. The live dormancy-now obligation moved to a separate view _dormancyNowFloor()
 *           used ONLY by the distribution gate. Folding a decaying today-floor into a season-end
 *           target had throttled early-season prizes in upfront-heavy tiers (sim: ~$95k / ~2.4x over
 *           draws 1-10 at 1000 UF-OG / 500 casual); the split moved that constraint out of the
 *           season-end target and freed the solver, materially improving early-draw prizes -- though
 *           the inherent draw-1 throttle remains (you cannot both pay large draw-1 prizes and
 *           guarantee full OG pro-rata on a draw-1 dormancy) -- while keeping the senior
 *           dormancy guarantee absolute per draw. DORM-GATE [B-L-01]: the casual-refund reservation
 *           and CASUAL_PROTECT_HEALTH_BPS health line were removed as protectively vacuous (the
 *           current-draw refund is self-covering in IDLE) and non-monotonic; the gate now caps
 *           against the senior dormancy-now floor unconditionally. Casuals are covered on every
 *           branch, including seeded games.
 *         v1.05a: swept stale floor call-site comments left by the v1.04 split (docs-only).
 *         v1.06-v1.07: VC SPENT-RETURN model. Seed spent on prizes is reconstituted to the VC from
 *           treasury with a flat 25% return, +25% bonus above a treasury threshold, paid on BOTH the
 *           completed-season (closeGame) and early-shutdown (sweepDormancyRemainder) paths. Unspent
 *           seed still returns from the pot. Constructor VC-SPENT-CAP bounds the release ratio so the
 *           obligation can never exceed the treasury that funds it; old fixed-tier bonus forbidden on
 *           seeded games (would double-pay).
 *         v1.08: RESERVE-FIX. withdrawTreasury reserves against seed RELEASABLE from accumulated
 *           treasury at the immutable MAX ratio (not seed already released), closing a drain-before-
 *           release insolvency found by fuzzing. WITHDRAW_START_DRAW window ("protocol eats last").
 *         v1.09-v1.10: T3-FLOOR. In a seeded game, draws 1..WITHDRAW_START_DRAW, if T3 would pay below
 *           TICKET_PRICE per winner, a little seed is released to lift the whole tier curve pro-rata so
 *           T3 hits TICKET_PRICE (see the three-point disclosure in CHANGELOG v1.10). Reserve tweak
 *           covers it; the release is DEFERRED to _finalizeWeekCore (v1.10) so an emergencyResetDraw is
 *           reset-safe (mirrors CR-L-01 for the supplement).
 *         PRE-MAINNET CRE VERIFICATION [NS-I-01, do not skip]: (1) confirm whether the live
 *           KeystoneForwarder for the target chain probes ERC165 before delivering; if it does, add
 *           supportsInterface (this seam omits it deliberately per current docs). (2) Optional
 *           hardening: pin the registered workflow owner/name from onReport metadata. (3) onReport
 *           ACTION_* codes are UNRELATED to performUpkeep's action bytes (onReport ACTION 1 =
 *           SUBMIT_CUTOFFS; performUpkeep 1 = advance) -- do not conflate in the offchain workflow.
 *         ─────────────────────────────────────────────────────────────────────
 *
 * @author DYBL Foundation
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
// Aave removed in v1.52. Pure USDC contract.
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface AggregatorMinMax {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

contract BullsEth is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Errors ───────────────────────────────────────────────────────────────
    error GameNotActive();
    error GameNotClosed();
    error DrawInProgress();
    error NotEnoughPlayers();
    error MaxPlayersReached();
    error OwnableUnauthorizedAccount(address account);
    error AlreadyRegistered();
    error NotRegistered();
    error AlreadyOG();
    error OGCapReached();
    error NotOG();
    error NotEligible();
    error PicksLocked();
    error AlreadyBoughtThisWeek();
    error InvalidPrediction();
    error InvalidAddress();
    error FeedUnchanged();
    error InsufficientBalance();
    error TreasuryLocked();
    error NothingToClaim();
    error InsufficientGasForBatch();
    error ResetRefundNotEligible();
    error ResetRefundExpired();
    error AlreadyClaimed();
    error WrongPhase();
    error TooEarly();
    error CooldownActive();
    error ExceedsLimit();
    error BelowMinimum();
    error CanOnlyDecrease();
    error NotStuck();
    error DrawNotProgressing();
    /// @dev [v1.57+] Declared but never used as revert. Retained for ABI compatibility.
    ///      Originally intended for malformed performData in performUpkeep().
    ///      Actual decode failure throws a generic EVM ABI error instead. See performUpkeep().
    error MalformedPerformData();
    error SolvencyCheckFailed();
    error TimelockPending();
    error NoTimelockPending();
    error GameAlreadyClosed();
    error SignupNotFailed();
    error PregameWindowExpired();
    error AlreadyRefunded();
    error MinimumTicketsRequired();
    error GameNotDormant();
    error AlreadyCommitted();
    error DormancyWindowExpired();
    error NotQualifiedForEndgame();
    error NotEnoughValidPrices();
    error SequencerNotReady();
    error PotBelowTrajectory();
    error BreathUnchanged();
    error RenounceOwnershipDisabled();
    error OwnershipTransferExpired();
    /// @dev [CRE v0.1 / SmartEarn] withdrawTreasury() revert when amount would leave treasury
    ///      below the currently triggered VC performance bonus obligation.
    error TreasuryBonusProtected(uint256 required, uint256 available);
    error SeedNotDeposited(); // [CRE v0.4 / SE-H-01] startGame() fired without VC seed deposited
    /// @dev [CRE v0.1] seedPot() revert if called more than once.
    error PotAlreadySeeded();
    error IntentQueueFull(); // [v1.57-P1] never fired -- intent queue removed
    error AlreadyInIntentQueue(); // [v1.57-P1] kept for ABI compat
    error NoIntentPending(); // [v1.57-P1] never fired -- intent queue removed
    error IntentWindowExpired(); // [v1.57-P1] never fired -- intent queue removed
    error IntentQueueNotEmpty(); // kept for ABI compat, no longer fired
    /// @dev [v1.57-P1] Reverts cancelOGRegistration() when 72h window has passed.
    error DeclineWindowExpired();
    /// @dev [v1.57-P1] Reverts cancelOGRegistration() when caller has no open window.
    error NotInDeclineWindow();
    error ActiveDeclineWindowOpen(); // [v1.57-P1] never fired -- retained for ABI compat
    error PregameOGNetNotSet(); // [v1.57] never fired -- guard removed
    error FeedDecimalsMismatch();
    error UnknownAction(uint8 action);
    // [v1.0] No InvalidTierConfiguration -- no TIER_BPS constants in this fork.
    /// @dev [v1.0] Submitted cutoff counts outside acceptable range.
    ///      t1Count: 0.5%-4% of snapshotTotalEntries.
    ///      t2Count: 4%-12% of snapshotTotalEntries.
    ///      t3Count: 10%-50% of snapshotTotalEntries.
    ///      [v2.18] Lower bound recalibrated from 16% to 10% (new cumulative T3 target 12-15%).
    ///      Upper bound unchanged at 50% (same 2-ticket casual snapshot bias applies).
    error CutoffOutOfRange();
    /// @dev [v1.0] t1CutoffDiff > t2CutoffDiff or t2CutoffDiff > t3CutoffDiff or t1Count > t3Count.
    error InvalidCutoffOrder();

    // ── Events ───────────────────────────────────────────────────────────────
    event StaleOGsPruned(uint256 pruned, uint256 remaining);
    event PlayerRegistered(address indexed player, uint256 totalPlayers);
    event CommitmentPaid(address indexed player, uint256 amount);
    event CommitmentDoublePaid(address indexed player, uint256 amount);
    event CommitmentDoubleUnused(address indexed player, uint256 amount);
    event CommitmentCreditExpired(address indexed player, uint256 creditAmount);
    event UpfrontOGRegistered(address indexed player, uint256 prediction, uint256 prediction2, uint256 ogCount);
    event WeeklyOGRegistered(address indexed player, uint256 prediction, uint256 prediction2, uint256 draw);
    event WeeklyOGStatusLost(address indexed player, uint256 atDraw);
    event TicketsBought(address indexed player, uint256 draw, uint256 ticketCount);
    event TierSkippedDust(uint256 indexed tier, uint256 amount);
    event PredictionSubmitted(address indexed player, uint256 prediction, uint256 draw);
    event Prediction2Submitted(address indexed player, uint256 prediction2, uint256 draw);
    /// @dev Emitted in three places post-v2.34: (1) OG matching in _processMatchesCore()
    ///      when OG prediction2 is stale/zero; (2) casual matching in _processMatchesCore()
    ///      for lastTicketCount>=2 players when prediction2 stale/zero (added v2.34 M-01);
    ///      (3) _applyAutoPredictions(). NOT OG-exclusive post v2.34 M-01. [v2.35 NS-I-03]
    ///      Subgraphs inferring OG status from this event must be updated.
    event AutoPrediction2Applied(address indexed player, uint256 indexed draw, uint256 prediction2);
    event GameStarted(uint256 timestamp, uint256 totalPlayers);
    event StartGameProposed(uint256 launchNotBefore);
    event StartGameProposalCancelled();
    event FeedSubstituted(address indexed oldFeed, address indexed newFeed);
    event SignupRefund(address indexed player, uint256 amount, uint256 fullAmount);
    event DrawResolved(uint256 indexed draw, int256 resolvedPrice);
    event AutoPredictionApplied(address indexed player, uint256 indexed draw, uint256 prediction);
    event AutomationForwarderSet(address indexed forwarder);
    /// @notice [CRE v1.0] Emitted when the CRE forwarder address is set or cleared.
    event CreForwarderSet(address indexed forwarder);
    /// @notice [CRE v1.0] Emitted after every successfully processed CRE report.
    event CreReportProcessed(uint8 indexed action, uint256 indexed draw);
    event SignupRefundSkipped(address indexed player);
    event MatchingComplete(uint256 indexed draw, uint256 totalWinners);
    /// @notice Emitted when post-match winner counts fall outside expected BPS bounds. [v1.2]
    ///         Winner arrays cleared; drawPhase reverts to CUTOFF_SUBMISSION for resubmission.
    ///         Tier pools preserved for the corrected pass. OG status losses from the failed
    ///         pass are NOT reversed. Fastest recovery: resubmit corrected cutoffs immediately.
    ///         The 48h emergencyResetDraw() path is fallback if keeper cannot self-correct.
    ///         Restoration via emergencyResetDraw(): _continueUnwind() restores OGs whose
    ///         statusLostAtDraw == lastResetDraw. Only that draw's losses are reversible.
    ///         See deployment runbook for full recovery procedure.
    event MatchCountMismatch(
        uint256 indexed draw,
        uint256 t1Actual,
        uint256 t12Actual,
        uint256 t123Actual,
        uint256 snapshot
    );
    event MatchingBatchProcessed(uint256 indexed draw, uint256 processed, uint256 total);
    event PrizeDistributed(address indexed winner, uint256 amount, uint256 tier);
    // [v1.0] JPMissRedistributed REMOVED -- T1 always has winners, no miss path.
    // [v1.0] TierNoWinners REMOVED -- percentage cutoffs are designed so entries exist in each tier.
    /// @notice Emitted when keeper submits cutoff diffs. [v1.0]
    ///         Keepers read all predictions from chain, sort off-chain, find
    ///         diff values at 1%, ~6%, and ~12-15% thresholds (draw-schedule dependent), submit here.
    ///         If not submitted within DRAW_STUCK_TIMEOUT, emergencyResetDraw() available.
    ///         Counts are cumulative: t1Count = T1 entries, t2Count = T1+T2, t3Count = all winners.
    event CutoffDiffsSubmitted(
        uint256 indexed draw,
        uint256 t1CutoffDiff,
        uint256 t2CutoffDiff,
        uint256 t3CutoffDiff,
        uint256 t1Count,
        uint256 t2Count,
        uint256 t3Count
    );
    /// @notice Seed/rollover returns to prizePot each draw. 10% of weeklyPool.
    ///         On draw 30 (surplus path): emits SeedReturned(30, 0) -- same as draw 52 in 1Y.
    event SeedReturned(uint256 indexed draw, uint256 amount);
    event WeekFinalized(uint256 indexed draw);
    event GameClosed(uint256 perOG, uint256 surplusToTreasury, uint256 qualifiedOGs);
    event YieldCaptured(uint256 yieldAmount);
    event AccountingDiscrepancy(uint256 trackedUnclaimed, uint256 claimAmount);
    /// @notice Emitted when a post-transfer balance check detects potential underfunding. [v1.51]
    ///         Non-fatal: emitted as an early warning, does not revert the calling function.
    ///         allocated: sum of all tracked on-chain obligations at time of check.
    ///         balance: actual USDC balance held by contract (no aUSDC in v1.52).
    ///         context: which function triggered the check (for monitoring/alerting).
    event SolvencyAlert(uint256 indexed allocated, uint256 balance, bytes32 context);
    /// @notice Emitted when the geometric solver detects structural insolvency:
    ///         even at breath=0 (no prizes, only revenue added) the floor cannot be reached.
    ///         Wire monitoring to this event and trigger proposeDormancy() review on receipt.
    event SolverDistressSignal(uint256 indexed draw, uint256 pot, uint256 floor, uint256 drawsLeft, uint256 projectedAtZero);
    /// @dev [v1.57-P1] Emitted when OG registration confirmed and 72h window opens.
    ///      windowExpiry: block.timestamp + OG_DECLINE_WINDOW. Call cancelOGRegistration()
    ///      before this timestamp for a 75% refund. [CRE v0.2 / LOW-02] was "90% refund" (old 10% treasury rate).
    event OGDeclineWindowOpened(address indexed player, uint256 windowExpiry);
    /// @dev [v1.57-P1] Emitted when OG cancels within 72h window.
    ///      netRefund = ogTransfer * 75%. Treasury slice (25%) is permanently retained.
    ///      [CRE v0.2 / LOW-02] was "90% / 10%" — rates updated to match UF_OG_TREASURY_BPS = 2500.
    event OGRegistrationCancelled(address indexed player, uint256 netRefund);
    event EndgameClaimed(address indexed og, uint256 amount);
    event TreasuryWithdrawal(uint256 amount, address recipient);
    event UnclaimedFundsSwept(bytes32 indexed reason, uint256 amount);
    event TreasuryAccrual(uint256 indexed draw, uint256 amount, uint256 rateBps);
    event PrizeRateReductionProposed(uint256 newMultiplier, uint256 effectiveTime, bytes32 reason);
    event PrizeRateReductionExecuted(uint256 oldMultiplier, uint256 newMultiplier, bytes32 reason);
    event PrizeRateReductionCancelled();
    event PrizeRateIncreaseProposed(uint256 newMultiplier, uint256 effectiveTime, bytes32 reason);
    event PrizeRateIncreaseExecuted(uint256 oldMultiplier, uint256 newMultiplier, bytes32 reason);
    event PrizeRateIncreaseCancelled();
    event FeedStaleFallback();
    event ReserveFeedUsed(address indexed feed, uint256 indexed draw);
    event FeedChangeProposed(address newFeed, uint256 effectiveTime);
    event FeedChangeExecuted(address oldFeed, address newFeed);
    event FeedChangeCancelled();
    event EmergencyReset(uint256 indexed draw, DrawPhase fromPhase, uint256 amountReturned);
    event EmergencyUnwindBatch(uint256 indexed draw, uint256 unwoundSoFar, uint256 total);
    event PredictionResetOnUnwind(address indexed player, uint256 indexed draw);
    event EmergencyUnwindComplete(uint256 indexed draw, uint256 total);
    event PrizeClaimed(address indexed player, uint256 amount);
    event DormancyActivated(uint256 timestamp);
    event DormancyClaimDeadline(uint256 deadline);
    event DormancyRefund(address indexed player, uint256 amount);
    event DormancyProposed(uint256 effectiveTime);
    event DormancyCancelled();
    event ResetRefundClaimed(address indexed player, uint256 indexed draw, uint256 amount);
    event ResetRefundPartial(address indexed player, uint256 indexed draw, uint256 paid, uint256 owed);
    event ResetRefundExpiredSwept(uint256 indexed draw, uint256 amount);
    event ResetRefundSkipped(uint256 indexed draw, uint256 unprotectedTicketTotal);
    event ResetRefundOverflow(uint256 indexed draw, uint256 amount);
    event CommitmentRefundActivated(uint256 indexed draw, uint256 poolAmount);
    event CommitmentRefundClaimed(address indexed player, uint256 amount);
    event CommitmentRefundPartial(address indexed player, uint256 paid, uint256 owed);
    event CommitmentRefundExpiredSwept(uint256 indexed draw, uint256 amount);
    event DormancyRemainderSwept(uint256 toProtocolBeneficiary);
    event FailedPregameSwept(uint256 toProtocolBeneficiary);
    /// @notice [CRE v0.6 / MEDIUM-01] Emitted when a deposited VC seed is returned to
    ///         VC_SEED_RETURN_ADDRESS during sweepFailedPregame() because the game never started.
    event FailedPregameSeedReturned(uint256 seedReturned);
    event StreakBroken(address indexed player, uint256 previousStreak);
    /// @notice Emitted when a weekly OG reaches WEEKLY_OG_QUALIFICATION_WEEKS consecutive draws.
    ///         [v1.3] Now emits exclusively from _updateStreakTracking (via buyTickets).
    ///         In v1.2 and earlier this could also emit from the mulligan path during MATCHING.
    ///         Monitoring infrastructure should be aware it originates only from buyTickets.
    event EarnedOGQualified(address indexed player, uint256 atDraw);
    /// @dev [v1.58-P3] Emitted once at startGame() when obligation is locked at draw 1.
    ///      obligation = maxOGs * OG_UPFRONT_COST (gross, ceiling at startGame).
    ///      requiredPot = obligation * targetReturnBps/10000 + DRAW30_PRIZE_RESERVE + (VC_SEED - seedReleased). [CRE v0.8 / NS-L-01]
    ///      qualifiedOGs = upfrontOGCount + earnedOGCount at the moment of startGame().
    event OGObligationLocked(uint256 obligation, uint256 requiredPot, uint256 qualifiedOGs);
    /// @dev [v1.58-P3] Emitted every draw when OG count or requiredEndPot changes.
    ///      Called from _snapshotOGObligation() after each _finalizeWeekCore().
    ///      Not emitted if both obligation and requiredEndPot are unchanged (early return).
    event OGObligationSnapshot(uint256 indexed draw, uint256 oldObligation, uint256 newObligation, uint256 oldRequiredPot, uint256 newRequiredPot, uint256 ogCount);
    event BreathMultiplierAdjusted(uint256 oldMultiplier, uint256 newMultiplier, bool isUp);
    event BreathOverrideProposed(uint256 indexed newMultiplier, uint256 effectiveTime, bytes32 reason);
    event BreathOverrideCancelled(uint256 cancelledMultiplier);
    event BreathOverrideExecuted(uint256 oldMultiplier, uint256 newMultiplier, bytes32 reason);
    event BreathRailsUpdated(uint256 newMin, uint256 newMax, uint256 atDraw);
    event BreathRailsProposed(uint256 newMin, uint256 newMax, uint256 effectiveTime, bytes32 reason);
    event BreathRailsProposalCancelled(uint256 cancelledMin, uint256 cancelledMax);
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGIntentForceDeclineFailed(address indexed player, uint256 amount); // [v1.57-P1] never emitted -- forceDeclineIntent removed
    event EndgameShortfall(uint256 perOGPaid, uint256 perOGPromised, uint256 shortfallTotal);
    event PlayerLapsed(address indexed player, uint256 atDraw);
    event PlayerUnlapsed(address indexed player, uint256 atDraw);
    /// @notice Emitted at startGame() after breath calibration. [v1.5]
    ///         ogBreathBps: OG-obligation-aware starting breath from _computeStartingBreathFromTarget(targetReturnBps).
    ///         t3FloorBps:  T3-prize-floor breath from _computeStartingBreath (draws on pregame data).
    ///         initialBreathBps: actual starting breath used = max(ogBreathBps, t3FloorBps).
    ///         estimatedEntriesDraw1: entry count estimate used in T3-floor formula.
    event BreathCalibrated(
        uint256 ogRatioBps,
        uint256 targetReturnBps,
        uint256 initialBreathBps,
        uint256 ogBreathBps,
        uint256 t3FloorBps,
        uint256 estimatedEntriesDraw1
    );
    /// @dev [v1.57-P2] Emitted at FINAL_CALIBRATION_DRAW (draw 28) when targetReturnBps
    ///      is recalibrated from actual late-game OG ratio and requiredEndPot updated.
    event FinalReturnCalibrated(uint256 indexed draw, uint256 oldTargetBps, uint256 newTargetBps, uint256 newRatioBps, uint256 newRequiredEndPot);
    /// @dev [v1.60] Emitted when a new exhale floor release threshold is proposed.
    event ExhaleFloorReleaseProposed(uint256 newBps, uint256 executeAfter);
    /// @dev [v1.60] Emitted when the exhale floor release threshold is updated.
    event ExhaleFloorReleaseUpdated(uint256 oldBps, uint256 newBps);
    /// @dev [v1.62] Emitted when a pending exhale floor release proposal is cancelled.
    event ExhaleFloorReleaseCancelled(uint256 cancelledBps);
    /// @dev [v1.63] Emitted when draw30BonusFund is returned to prizePot on dormancy activation.
    event Draw30BonusReturned(uint256 amount);
    /// @dev [v1.57-P2] Emitted at draw 7 when targetReturnBps is recalibrated.
    ///      [v1.61] computedBreath is the formula estimate from _computeStartingBreathFromTarget --
    ///      NOT the solver-applied value. The actual breathMultiplier after draw 7
    ///      is in the subsequent BreathMultiplierAdjusted event at draw 8.
    event BreathRecalibrated(uint256 oldTargetBps, uint256 newTargetBps, uint256 oldBreath, uint256 computedBreath, uint256 actualRatioBps);
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGIntentRegistered(address indexed player, uint256 queueIndex, uint256 amount); // [v1.57-P1] never emitted -- intent queue removed
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGIntentOffered(address indexed player, uint256 windowExpiry); // [v1.57-P1] never emitted
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGIntentDeclined(address indexed player, uint256 netRefund, uint256 grossAmount, uint256 depositKept); // [v1.57-P1] never emitted
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGIntentSwept(address indexed player); // [v1.57-P1] never emitted
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGIntentForcedDeclined(address indexed player, uint256 refund, uint256 grossAmount); // [v1.57-P1] never emitted
    event ForceDeclineRefundClaimed(address indexed player, uint256 amount);
    /// @dev [v1.57-P1] Never emitted in v1.57+. Retained for ABI compatibility only.
    event OGSlotsConfirmed(uint256 confirmed, uint256 pendingRemaining); // [v1.57-P1] never emitted -- confirmOGSlots removed
    event DefaultPredictionUpdated(uint256 oldPrediction, uint256 newPrediction);
    // ── [CRE v0.1 / SmartEarn] VC earnout events ───────────────────────────────
    event PotSeeded(uint256 amount, address indexed seeder);
    event VCBonusTierReached(uint256 indexed tier, uint256 threshold, uint256 bonusAmount, uint256 cumulativeTreasury);
    /// @dev [CRE v0.9 / NS-I-01] totalSeedReleased is PROVISIONAL. This event fires in
    ///      _calculatePrizePools() when the supplement is added to the weekly pool, but after
    ///      CR-L-01 the seedReleased state variable is not incremented until _finalizeWeekCore()
    ///      (guarded !isResetFinalize). The value emitted here is the projected post-finalize
    ///      cumulative (current seedReleased + this draw's supplement). If the draw is voided by
    ///      emergencyResetDraw() before finalize, the increment never lands and this figure is NOT
    ///      realised. Subgraphs should treat totalSeedReleased as confirmed only once the matching
    ///      draw reaches a non-reset finalize; reconcile against on-chain seedReleased if in doubt.
    event SeedSupplementPaid(uint256 indexed draw, uint256 supplement, uint256 totalSeedReleased);
    /// @notice [CRE v1.09] Emitted when the seeded cold-start floor releases seed to lift T3 to
    ///         TICKET_PRICE per winner (pro-rata across tiers). Early draws only, shortfall only.
    event SeedT3FloorTopup(uint256 indexed draw, uint256 topupRecorded, uint256 t3Winners);
    event SeedReleaseRatioProposed(uint256 indexed newRatio, uint256 effectiveTime);
    event SeedReleaseRatioExecuted(uint256 indexed oldRatio, uint256 indexed newRatio);
    event SeedReleaseRatioCancelled(uint256 indexed cancelledRatio);
    event VCReturnClaimed(uint256 amount);

    // ── Enums ────────────────────────────────────────────────────────────────
    enum GamePhase { PREGAME, ACTIVE, DORMANT, CLOSED }
    /// @dev Draw phase flow:
    ///      IDLE -> CUTOFF_SUBMISSION -> MATCHING -> DISTRIBUTING -> FINALIZING -> IDLE
    ///      resolveWeek() transitions IDLE -> CUTOFF_SUBMISSION.
    ///      submitCutoffDiffs() transitions CUTOFF_SUBMISSION -> MATCHING.
    ///      _processMatchesCore() transitions MATCHING -> DISTRIBUTING (or back to CUTOFF_SUBMISSION on mismatch).
    ///      _distributePrizesCore() transitions DISTRIBUTING -> FINALIZING.
    ///      _finalizeWeekCore() transitions FINALIZING -> IDLE (or RESET_FINALIZING -> IDLE).
    ///      UNWINDING: emergency reset OG-restoration pass before RESET_FINALIZING.
    enum DrawPhase { IDLE, CUTOFF_SUBMISSION, MATCHING, DISTRIBUTING, FINALIZING, RESET_FINALIZING, UNWINDING }
    enum OGIntentStatus { NONE, PENDING, OFFERED, DECLINED, SWEPT }

    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_DRAWS                    = 30;
    uint256 public constant INHALE_DRAWS                   = 20;
    uint256 public constant FINAL_CALIBRATION_DRAW         = 28;
    uint256 public constant ENDGAME_SWEEP_WINDOW           = 180 days;
    uint256 public constant TICKET_PRICE                   = 10_000_000;
    // [v1.54] L-04: EXHALE_TICKET_PRICE removed. Exhale pricing equals TICKET_PRICE in
    // the 30-draw Base fork (no premium). Dead branch removed from buyTickets().
    uint256 public constant OG_UPFRONT_COST                = 600_000_000; // $600 = a weekly OG's full 30-draw season (30 x $20). 1x a weekly OG season, 2x a single-ticket casual season ($300), 60x single ticket price.
    // [v1.57-P2] OG_TREASURY_BPS deprecated. Upfront OGs use UF_OG_TREASURY_BPS (2500).
    //              Weekly OGs use TREASURY_BPS (2500). This constant is now unreferenced.
    //              Retained for ABI compatibility. [CRE v0.1/v0.6 NS] Numeric value is 1500.
    //              The pre-CRE comment claimed this "coincidentally matches TREASURY_BPS" --
    //              that is no longer true. CRE v0.1 set TREASURY_BPS = 2500, so this deprecated
    //              constant (1500) now DIFFERS from both TREASURY_BPS (2500) and
    //              UF_OG_TREASURY_BPS (2500). Do not use this value for any live rate.
    uint256 public constant OG_TREASURY_BPS                = 1500;
    uint256 public constant MAX_PLAYERS                    = 55_000;
    uint256 public constant MAX_TICKETS_PER_WEEK           = 2;
    uint256 public constant MIN_TICKETS_WEEKLY_OG          = 2;
    uint256 public constant MIN_PLAYERS_TO_START           = 500;
    uint256 public constant UPFRONT_OG_CAP_BPS             = 1000;
    uint256 public constant TOTAL_OG_CAP_BPS               = 1800;
    // [v1.57-P1] OG_INTENT_HARD_CAP deprecated -- intent queue removed. Never referenced.
    // [v1.57-P1 deprecated]
    uint256 public constant OG_INTENT_HARD_CAP             = 10_000;
    // ── [v1.58-P3] Geometric breath engine constants ─────────────────────────
    /// @dev [v1.62] Fraction of each draw's weekly pool siphoned into draw30BonusFund.
    ///      Accumulated over draws 1-29, added to draw-30 surplus in _calculatePrizePools().
    ///      300 bps (3%) strongly targets draw-30 as the largest prize event (simulation-
    ///      validated across OG% 0-30% at typical participation levels).
    ///      Simulation-validated. Governance upgrade path: add proposeDrawBonus() if needed.
    uint256 public constant DRAW30_BONUS_BPS = 300;
    /// @dev [v1.58-P3] Solver planning floor for draw-30 T1/T2/T3 prizes.
    ///      The geometric solver ensures pot >= OG_obligation + this reserve at draw 30.
    ///      resolveWeek() distributes draw-30 prizes BEFORE closeGame() pays OGs.
    ///      This reserve is consumed by draw-30 prize distribution, leaving OG_obligation
    ///      for closeGame(). It is a planning constraint, not a runtime holdback.
    uint256 public constant DRAW30_PRIZE_RESERVE   = 5_000_000000; // $5,000 USDC (6 dec)
    /// @dev [v1.58-P3] Binary search iterations for _solveGeometricBps().
    ///      24 iterations gives BPS precision < 1 on any feasible breath range.
    uint256 public constant GEOM_SOLVER_ITERS      = 24;

    // [v1.57-P1] OG_INTENT_WINDOW deprecated -- intent queue removed. Superseded by OG_DECLINE_WINDOW.
    // [v1.57-P1 deprecated]
    uint256 public constant OG_INTENT_WINDOW               = 72 hours;
    uint256 public constant START_GAME_NOTICE_PERIOD       = 72 hours;
    // [v1.57-P1] OG_DECLINE_WINDOW_TAIL deprecated -- proposeStartGame tail check removed.
    uint256 public constant OG_DECLINE_WINDOW_TAIL         = 6 hours;
    uint256 public constant BREATH_CALIBRATION_DRAW        = 7;
    /// @dev [v1.58-P3] DEPRECATED CONSTANT. Obligation locked at startGame() (draw 1),
    ///      not draw 10. Do NOT use to schedule monitoring. Listen for OGObligationLocked.
    uint256 public constant OG_OBLIGATION_LOCK_DRAW        = 10;
    /// @dev [v1.3] Equal to TOTAL_DRAWS. Zero-miss requirement: a weekly OG must buy
    ///      tickets every single draw to qualify for endgame. Intentional -- no mulligan
    ///      in BullsEth. The qualification threshold is only reachable on the final draw.
    ///      Frontends showing OG qualification progress must communicate this clearly.
    uint256 public constant WEEKLY_OG_QUALIFICATION_WEEKS  = 30;
    // [v1.3] MULLIGAN_THRESHOLD removed. No mulligan in BullsEth 30-draw game.
    //          Miss one buy window = weekly OG status lost immediately.
    //          72-hour windows over 90 days make a missed window a genuine signal.
    uint256 public constant SIGNUP_DURATION                = 4 weeks;
    uint256 public constant MAX_PREGAME_DURATION           = 4 weeks;
    uint256 public constant FAILED_PREGAME_SWEEP_EXTENSION = 180 days;
    uint256 public constant PREDICTION_SCALE               = 1_000_000;
    uint256 public constant MAX_PREDICTION_CENTS           = 1_000_000_000_000_000;

    // [v1.0] 3-tier pool splits.
    // [v1.62] Applied to distributable = weeklyPool * 87% (90% seed - 3% DRAW30_BONUS_BPS).
    // T1 = 40% of distributable ~= 34.8% of weeklyPool.
    // T2 = 35.56% of distributable ~= 30.9% of weeklyPool.
    // T3 = remainder of distributable ~= 21.3% of weeklyPool.
    // Seed  = 10% of weeklyPool -- returns to prizePot via SeedReturned event.
    // Bonus =  3% of weeklyPool -- accumulates in draw30BonusFund (v1.62).
    // Winner percentages: T1=top 1%, T2=next 5%, T3=graduated (6% draws 1-2, 9% draw 5+).
    // Total winners per draw: ~12% draws 1-2, ~15% draw 5+ (plus tie buffer ~2%).
    uint256 public constant JP_BPS    = 4000;  // T1: 40% of distributable
    uint256 public constant P2_BPS    = 3556;  // T2: 35.56% of distributable
    // T3 = remainder: distributable - tierPools[0] - tierPools[1]
    uint256 public constant SEED_BPS  = 1000;  // 10% rollover to prizePot

    // [v1.1] Cutoff count verification bounds (BPS of snapshotTotalEntries).
    // Counts are CUMULATIVE: t1Count = T1 entries (~1%), t2Count = T1+T2 entries (~6%),
    // t3Count = T1+T2+T3 entries (~12% draws 1-2, ~15% draw 5+). Cumulative cutoff count.
    //
    // snapshotTotalEntries undercounts 2-ticket casual entries (each casual = 1 in snapshot,
    // but 2-ticket casuals generate 2 entries in _matchAndCategorize). This means the
    // computed Bps values will read HIGHER than actual percentage when casuals hold 2 tickets.
    // The MAX bounds (T1_COUNT_MAX_BPS, T2_COUNT_MAX_BPS, T3_COUNT_MAX_BPS) are therefore
    // the binding risk: a keeper with many 2-ticket casuals may see valid submissions
    // rejected by the ceiling. Bounds are set wide enough to absorb full 2-ticket adoption.
    // OG status losses during MATCHING further reduce actual entry count vs snapshot.
    uint256 public constant T1_COUNT_MIN_BPS  =   50; // 0.5% -- T1 only
    uint256 public constant T1_COUNT_MAX_BPS  =  400; // 4.0% -- T1 only
    uint256 public constant T2_COUNT_MIN_BPS  =  400; // 4%   -- T1+T2 cumulative (~6% target)
    uint256 public constant T2_COUNT_MAX_BPS  = 1200; // 12%  -- T1+T2 cumulative
    // [v2.18] T3_COUNT_MIN recalibrated for new T3 winner schedule.
    // Draw 1-2: T3=6%, cumulative~12%. Draw 5+: T3=9%, cumulative~15%.
    // MIN set 2pp below draw 1-2 floor (12%->10%). MAX unchanged at 5000 (same 2-ticket bias).
    uint256 public constant T3_COUNT_MIN_BPS  = 1000; // 10%  -- T1+T2+T3 cumulative (old:16%)
    // [v1.57-P2] MAX raised to 5000 to accommodate 2-ticket casual snapshot bias.
    // snapshotTotalEntries = ogList.length*2 + weeklyNonOGPlayers.length (1 slot per casual).
    // [v2.18] At 90% casual 2-ticket adoption the keeper's honest count reads ~27% of snapshot
    //         (cumulative T3 = 15% of actual entries, snapshot ~55% of actual).
    // 5000 (50%) gives ample headroom above worst-case real-world deployment.
    uint256 public constant T3_COUNT_MAX_BPS  = 5000; // 50%  -- T1+T2+T3 cumulative (old:19%, v1.57.r12:25%)

    // [v1.57-P2] T3_WINNER_BPS = 700 removed -- replaced by graduated schedule.
    //              [v2.18] T3_WINNER_BPS = 900 (9% draw 5+). See constants block below.
    /// @dev [v1.55] Stale OG count at which checkUpkeep signals action 3 (prune needed).
    ///      50 chosen as: well below MAX_MATCH_PER_TX (500), noticeable throughput degradation,
    ///      but not triggering on routine 1-5 draw cycle turnover. Adjust per deployment profile.
    uint256 public constant STALE_OG_PRUNE_THRESHOLD     = 50;
    /// @dev [v1.56] Max ogList entries to iterate in _countStaleOGsInternal per checkUpkeep call.
    ///      Prevents full-list traversal when stale OGs are at tail of a large list.
    ///      500 entries * ~2100 gas/SLOAD = ~1.05M gas worst case -- acceptable for a view call.
    uint256 public constant MAX_STALE_COUNT_ITERATIONS    = 500;
    /// @dev [v1.56] Prune batch size for Chainlink Automation action 3.
    ///      Smaller than MAX_LAPSE_BATCH (500) to fit within default Automation gas limits.
    ///      50 prunes * ~8 SSTOREs each = ~400k gas -- safe for 500k gas upkeep limit.
    ///      Increase for deployments with higher configured gas limits.
    uint256 public constant AUTOMATION_PRUNE_BATCH         = 50;

    // ── [CRE v1.0] onReport action codes ─────────────────────────────────────
    // Report encoding: abi.encode(uint8 action, bytes payload).
    uint8 public constant ACTION_SUBMIT_CUTOFFS = 1;
    uint8 public constant ACTION_ADVANCE        = 2;
    uint8 public constant ACTION_AUTO_PICKS     = 3;
    uint8 public constant ACTION_PRUNE          = 4;
    uint8 public constant ACTION_CLOSE_GAME     = 5;
    uint8 public constant ACTION_RESOLVE_WEEK   = 6;

    // ── [v1.57-P2] Economics constants ─────────────────────────────────────
    /// @dev [CRE v0.1] Upfront OGs pay 25% treasury (flat rate, matches TREASURY_BPS). Prior 10% rate removed.
    ///      [CRE v0.2 / LOW-02] NatSpec corrected from "10% discount vs 15% casual" to reflect current 25% flat.
    uint256 public constant UF_OG_TREASURY_BPS          = 2500;  // [CRE v0.1] flat 25% matching TREASURY_BPS
    /// @dev [DEPRECATED v2.15] Graduated treasury removed. Zero callers.
    ///      Retained for ABI compatibility. See TREASURY_BPS (2500) for the flat rate. [CRE v0.6 NS]
    uint256 public constant LAUNCH_TREASURY_BPS_D1_2    = 500;
    /// @dev [DEPRECATED v2.15] Graduated treasury removed. Zero callers.
    ///      Retained for ABI compatibility. See TREASURY_BPS (2500) for the flat rate. [CRE v0.6 NS]
    uint256 public constant LAUNCH_TREASURY_BPS_D3_4    = 1000;
    /// @dev [v2.18] T3 winner schedule: fewer winners early so each winner gets more.
    ///      6% draws 1-2, 7% draw 3, 8% draw 4, 9% draw 5+.
    ///      Cumulative (T1+T2+T3): ~12% draws 1-2, ~15% draw 5+.
    uint256 public constant T3_WINNER_BPS_D1_2           =  600;  // 6% of entries
    uint256 public constant T3_WINNER_BPS_D3             =  700;  // 7%
    uint256 public constant T3_WINNER_BPS_D4             =  800;  // 8%
    uint256 public constant T3_WINNER_BPS                =  900;  // 9%
    /// @dev [v1.57-P1] Voluntary 72-hour cancel window. Player calls cancelOGRegistration()
    ///      within this period for 75% refund (25% treasury slice kept). [CRE v0.2 / LOW-02] was "90%/10%".
    uint256 public constant OG_DECLINE_WINDOW            = 72 hours;

    uint256 public constant TREASURY_BPS           = 2500;  // [CRE v0.1] flat 25% for casuals and OGs
    /// @dev [v1.57-P2] BREATH_START: default breath ceiling used by _computeStartingBreathFromTarget
    ///      when targetReturnBps = 5000 (50% -- low OG concentration). [CRE v0.2 / LOW-02] was "9000 (90%)".
    ///      Actual starting breath = max(targetBps-derived, T3-floor from _computeStartingBreath).
    uint256 public constant BREATH_START            = 700;
    // ── Deprecated constants -- retained to avoid breaking subgraph ABI decoders ──────
    // None referenced in active code. Removal would change bytecode and break verified-
    // bytecode comparison tools. Each inline comment explains the original purpose.
    uint256 public constant BREATH_STEP_DOWN        = 100;  // [v1.58-P3] deprecated, ABI-compat only
    /// @dev [v1.60] Default pot-health threshold below which the exhale floor releases.
    ///      At 12000 bps (120% of requiredEndPot) the floor releases on genuine distress.
    ///      Adjustable by owner via proposeExhaleFloorRelease() within [8000, 20000].
    ///      8000 = conservative (floor holds until pot < 80% of required).
    ///      20000 = aggressive (floor releases when pot < 2x required -- almost always).
    uint256 public constant EXHALE_FLOOR_RELEASE_DEFAULT = 12000;
    uint256 public constant ABSOLUTE_BREATH_FLOOR   = 100;
    uint256 public constant ABSOLUTE_BREATH_CEILING = 2000;
    uint256 public constant BREATH_MIN              = 100;
    uint256 public constant BREATH_MAX              = 1500;
    uint256 public constant BREATH_FLOOR_BPS        = 1000;  // deprecated, ABI-compat only -- never referenced in v1.52+
    uint256 public constant BREATH_COOLDOWN_DRAWS   = 3;
    uint256 public constant OG_ABSOLUTE_FLOOR       = 500;
    uint256 public constant TARGET_RETURN_FLOOR_BPS = 1000;  // [CRE v0.1] informational only
    /// @dev [v2.27] Ceiling of _computeTargetReturnBps() curve. avgTargetReturnBps can never
    ///      exceed this value. Used for draw-30 holdback so surplus = DRAW30_PRIZE_RESERVE
    ///      as intended. Do not change without auditing _calculatePrizePools draw-30 path.
    ///      [D-2 RESOLVED v2.30] MAX_TARGET_RETURN_BPS is now the fallback (ogRatioDrawCount==0)
    ///      only. Primary holdback uses the 29-draw running average, matching closeGame() exactly.
    ///      ("Exactly" is only true as of v2.30: v2.29 had an off-by-one draw; v2.30 fixed it
    ///      via the _finalizeWeekCore draw-30 exclusion guard. See v2.30 changelog.)
    ///      In the 5-20% OG design target: estReturnBps caps at MAX_TARGET_RETURN_BPS = 5000.
    ///      [CRE v0.12 / NS-L-01: was stale "9000" from the pre-CRE rescale; the constant below is
    ///      5000, so the doc now matches its own declaration.] No behavioral change.
    ///      In high-OG declining seasons: holdback tightens to actual obligation, eliminating
    ///      the over-reserve-to-treasury path. Integer dust only (cents). No EndgameShortfall.
    uint256 public constant MAX_TARGET_RETURN_BPS    = 5000;  // [CRE v0.1] must match _computeTargetReturnBps() hard ceiling
    uint256 public constant DRAW_COOLDOWN           = 72 hours;
    uint256 public constant PICK_DEADLINE           = 48 hours;
    uint256 public constant DRAW_STUCK_TIMEOUT      = 48 hours;
    uint256 public constant FEED_STALENESS          = 25 hours;
    uint256 public constant SEQUENCER_GRACE_PERIOD  = 1 hours;
    uint256 public constant TIMELOCK_DELAY          = 7 days;
    uint256 public constant PRIZE_RATE_TIMELOCK     = 48 hours;
    uint256 public constant OWNERSHIP_TRANSFER_EXPIRY = 7 days;
    uint256 public constant DORMANCY_TIMELOCK       = 24 hours;
    uint256 public constant DORMANCY_CLAIM_WINDOW   = 90 days;
    uint256 public constant RESET_REFUND_WINDOW     = 30 days;
    uint256 public constant AUTO_PICK_BUFFER        = 1 hours;
    // [v1.58-P3] BREATH_BUFFER_BPS deprecated -- was used by old linear solver. Never referenced.
    uint256 public constant BREATH_BUFFER_BPS       = 500;  // [v1.58-P3] deprecated, ABI-compat only
    // [v1.58-P3] POST_LOCK_DRAWS deprecated -- was used by old linear solver. Never referenced.
    uint256 public constant POST_LOCK_DRAWS         = 20;    // [v1.58-P3] deprecated, ABI-compat only
    uint256 public constant BATCH_REFUND_MAX        = 100;
    uint256 public constant MAX_MATCH_PER_TX        = 500;
    uint256 public constant MAX_DISTRIBUTE_PER_TX   = 200;
    uint256 public constant MAX_UNWIND_PER_TX       = 300;
    uint256 public constant MAX_LAPSE_BATCH         = 500;
    uint256 public constant UNWIND_CONTINUATION_TIMEOUT = 7 days;
    uint256 public constant SOLVENCY_TOLERANCE      = 100_000;
    /// @dev [CRE v0.1 / SmartEarn] Cumulative season treasury must reach this before any seed supplement fires.
    uint256 public constant SEED_RELEASE_THRESHOLD   = 100_000_000_000; // $100k USDC 6-dec placeholder
    /// @dev [CRE v0.1 / SmartEarn] Timelock on seedReleaseRatioBps governance changes.
    uint256 public constant SEED_RATIO_TIMELOCK      = 7 days;

    // ── [CRE v1.06 / VC-SPENT-RETURN] Spent-seed return model ──────────────────
    // Deal: any VC seed spent on prizes (seedReleased) is reconstituted to the VC from treasury,
    // plus a flat return, plus a bonus if the season is big. Unspent seed returns from the pot as
    // before (it is defended in requiredEndPot). So VC gets: unspent seed (pot) + seedReleased +
    // 25% of seedReleased + (25% more if cumulative treasury >= the bonus threshold), all from
    // treasury for the spent portion. At full spend that is VC_SEED * 1.25, or * 1.5 with the bonus.
    uint256 public constant VC_SPENT_RETURN_BPS      = 2500;   // flat 25% return on spent seed
    uint256 public constant VC_SPENT_BONUS_BPS       = 2500;   // +25% of spent seed if big-season
    uint256 public constant VC_SPENT_BONUS_THRESHOLD = 2_000_000_000_000; // $2m cumulative treasury (6-dec placeholder)
    // Reserve buffer applied to the WITHDRAW LOCK only (treasury holds obligation*1.05 during the
    // season so a timing/rounding wobble never leaves the VC short). The VC is PAID the true
    // obligation (buffer * 0) at close; the buffer is protocol money that returns to treasury.
    uint256 public constant VC_RESERVE_BUFFER_BPS    = 500;    // 5%
    // [CRE v1.08 / WITHDRAW-WINDOW] "Protocol eats last." Treasury withdrawals are blocked until
    // AFTER this draw, so in game one the protocol does not pay itself before the game is on its
    // feet. This is a VALUE layer and a small extra margin; it is NOT the solvency mechanism (the
    // releasable reserve below is). Placeholder value; set per deployment.
    uint256 public constant WITHDRAW_START_DRAW      = 5;

    // ── Immutables ────────────────────────────────────────────────────────────
    address public immutable USDC;
    // Aave removed in v1.52. No aUSDC or AAVE_POOL immutables.
    address public immutable PROTOCOL_BENEFICIARY;
    uint256 public immutable DEPLOY_TIMESTAMP;
    address public immutable SEQUENCER_FEED;
    // ── [CRE v0.1 / SmartEarn] VC earnout immutables ───────────────────────────
    /// @notice Investor seed amount. Goes 100% to prizePot via seedPot(). 0 = feature disabled.
    uint256 public immutable VC_SEED;
    /// @notice VC wallet receiving (VC_SEED - seedReleased) at closeGame / sweepDormancyRemainder.
    address public immutable VC_SEED_RETURN_ADDRESS;
    /// @notice Tier 1 cumulative treasury threshold for performance bonus. 0 = disabled.
    uint256 public immutable VC_BONUS_TIER1_THRESHOLD;
    /// @notice Bonus paid when tier 1 hit. Tiers are EXCLUSIVE — highest applicable pays only.
    uint256 public immutable VC_BONUS_TIER1_AMOUNT;
    /// @notice Tier 2 threshold. Must be > VC_BONUS_TIER1_THRESHOLD.
    uint256 public immutable VC_BONUS_TIER2_THRESHOLD;
    /// @notice Bonus paid when tier 2 hit. Must be > VC_BONUS_TIER1_AMOUNT.
    uint256 public immutable VC_BONUS_TIER2_AMOUNT;
    /// @notice Hard cap on seedReleaseRatioBps governance (BPS; 0 = no cap). [Weather20 v2.42 pattern]
    uint256 public immutable MAX_SEED_RELEASE_RATIO_BPS;
    /// @notice Per-draw seed release cap as BPS of VC_SEED (0 = no cap).
    uint256 public immutable MAX_SEED_PER_DRAW_BPS;

    // ── State variables ───────────────────────────────────────────────────────
    address public ethFeed;
    address public ethReserveFeed;
    int256  public lastValidPrice;
    int256  public resolvedPrice;
    // [v1.0] tier1Band/tier2Band/tier3Band/tier4Band REMOVED.
    // Dynamic cutoff diffs replace fixed BPS bands. See t1CutoffDiff et al.
    address public wethFeed;
    uint256 public autoDefaultCents;
    uint256 public defaultPrediction;

    struct PendingFeedChange { address newFeed; uint256 effectiveTime; }
    PendingFeedChange public pendingEthFeedChange;

    GamePhase public gamePhase;
    address public automationForwarder;
    DrawPhase public drawPhase;
    uint256 public currentDraw;
    uint256 public lastDrawTimestamp;
    uint256 public scheduleAnchor;
    uint256 public phaseStartTimestamp;
    uint256 public totalRegisteredPlayers;
    uint256 public totalLifetimeBuyers;
    uint256 public signupDeadline;
    uint256 public startGameProposedAt;
    /// @dev [v1.57-P1] Deprecated. Was set by confirmOGSlots() which is removed.
    ///      Always 0. Retained for storage layout compatibility.
    uint256 public latestOfferTimestamp;

    uint256 public prizePot;
    uint256 public treasuryBalance;
    uint256 public totalUnclaimedPrizes;
    uint256 public totalTreasuryWithdrawn;
    // aaveExited removed in v1.52 -- always false (no Aave).
    bool public gameSettled;
    bool public prizesSweepComplete;
    uint256 public settlementTimestamp;

    uint256 public endgamePerOG;
    uint256 public endgameOwed;
    /// @dev [v1.57-P1] Per-player decline window expiry. Set at registerAsOG().
    ///      Zero after expiry or cancellation.
    mapping(address => uint256) public ogDeclineWindowExpiry;
    /// @dev [v1.57-P1] Exact net refund owed on cancellation.
    ///      = ogTransfer * (10000 - UF_OG_TREASURY_BPS) / 10000.
    ///      Stored at registerAsOG() to avoid mixed-rate calculation errors.
    ///      [CRE v0.2 / LOW-02] Both UF_OG_TREASURY_BPS and TREASURY_BPS are now 25% (2500).
    ///      The prior comment "(commitment credit is taxed at 15%, OG transfer at 10%)" is stale.
    mapping(address => uint256) private ogCancelRefund;
    /// @dev [v1.57-P2] OG return target set at startGame() from actual OG ratio.
    uint256 public targetReturnBps;
    uint256 public dormancyTimestamp;
    uint256 public dormancyEffectiveTime;
    uint256 public totalOGPrincipal;
    uint256 public totalOGPrincipalSnapshot;

    uint256 public dormancyOGPool;
    uint256 public dormancyOGPoolSnapshot;
    bool    public dormancyPrincipalFullCover;
    uint256 public dormancyCasualRefundPool;
    uint256 public dormancyCasualRefundPoolSnapshot;
    uint256 public dormancyCasualTicketTotal;
    bool    public dormancyCasualFullCover;
    uint256 public dormancyCommitmentPool;
    uint256 public dormancyCommitmentPoolSnapshot;
    uint256 public dormancyCommitmentNetTotal;
    bool    public dormancyCommitmentFullCover;
    uint256 public dormancyPerHeadPool;
    uint256 public dormancyPerHeadShare;
    /// @dev [CRE v0.7 / M-01] Sized as upfrontOGCount + currentDrawWeeklyOGBuyerCount
///      + weeklyNonOGPlayers.length at activateDormancy() time. Was previously
///      weeklyOGCount in the middle term, which counted active weekly OGs who had NOT
///      bought the current draw; those OGs cannot claim a per-head share (they revert
///      NothingToClaim before the per-head block), so the old denominator over-counted
///      and their slices leaked to the beneficiary. currentDrawWeeklyOGBuyerCount counts
///      only weekly OGs who bought this draw (or the pregame draw-1 entry), the exact set
///      that can reach the per-head block. weeklyNonOGPlayers contains only current-draw
///      buyers by construction. ogList.length may be higher if pruneStaleOGs() has not
///      run; that does not affect this counter or the per-head share calculation.
uint256 public dormancyParticipantCount;
    uint256 public currentDrawCasualNetTicketTotal;
    /// @notice [CRE v0.4 / DR-M-01] Active weekly OG net ticket spend for the current draw.
    ///         Used in activateDormancy() to fold weekly OG current-draw costs into the casual
    ///         refund pool. Cleared in _finalizeWeekCore() and emergencyResetDraw().
    uint256 public currentDrawWeeklyOGNetTicketTotal;
    /// @notice [CRE v0.7 / M-01] Head count of weekly OGs who bought the CURRENT draw.
    ///         Incremented once per weekly-OG buy (the AlreadyBoughtThisWeek guard ensures
    ///         one buy per draw per player). Used to size the dormancy per-head denominator
    ///         on CLAIMABLE heads only: a weekly OG who did not buy the current draw cannot
    ///         claim a per-head share (they revert NothingToClaim before the per-head block),
    ///         so counting all of weeklyOGCount over-sized the denominator and leaked the
    ///         non-buyers' slices to the beneficiary. Cleared alongside
    ///         currentDrawWeeklyOGNetTicketTotal in _finalizeWeekCore() and emergencyResetDraw().
    uint256 public currentDrawWeeklyOGBuyerCount;
    uint256 public ownershipTransferExpiry;
    uint256 public currentDrawTicketTotal;
    uint256 public currentDrawNetTicketTotal;
    uint256 private pregameWeeklyOGTicketTotal;

    uint256 public resetDrawRefundPool;
    uint256 public resetDrawRefundDraw;
    uint256 public resetDrawRefundDeadline;
    uint256 public resetDrawRefundPool2;
    uint256 public resetDrawRefundDraw2;
    uint256 public resetDrawRefundDeadline2;
    uint256 public commitmentRefundPool;
    uint256 public commitmentRefundDraw;
    uint256 public commitmentRefundDeadline;
    uint256 private pregameWeeklyOGNetTotal;

    uint256 public ogCapDenominator;
    uint256 public prizeRateMultiplier = 10000;
    uint256 public pendingMultiplier;
    uint256 public multiplierEffectiveTime;
    bytes32 public pendingMultiplierReason;
    bytes32 public lastMultiplierChangeReason;
    uint256 public ogEndgameObligation;
    uint256 public requiredEndPot;
    /// @dev [v1.58-P3] Prize pot value captured at startGame() when obligation is locked.
    ///      Read-only after startGame; used by off-chain analytics and event indexers.
    uint256 public potAtObligationLock;
    bool    public obligationLocked;

    uint256 public breathMultiplier = BREATH_START;
    uint256 public lastBreathAdjustDraw;
    uint256 public breathRailMin = BREATH_MIN;
    uint256 public breathRailMax = BREATH_MAX;
    /// @dev [v1.60] Live pot-health threshold for exhale floor release.
    ///      Floor releases when prizePot * 10000 / requiredEndPot < this value.
    ///      Default 12000 (120%). Governable within [8000, 20000] via timelock.
    uint256 public exhaleFloorReleaseBps = EXHALE_FLOOR_RELEASE_DEFAULT;
    uint256 public pendingExhaleFloorReleaseBps;  // [v1.60] pending governance value
    uint256 public pendingExhaleFloorReleaseTime; // [v1.60] timelock expiry (48h)
    /// @dev [v1.68] Bonus siphoned from the current draw's weeklyPool into draw30BonusFund.
    ///      Tracked so emergencyResetDraw() can reverse the contribution if the draw fails.
    ///      Cleared at end of _finalizeWeekCore() alongside currentDrawSeedReturn.
    uint256 public currentDrawBonusContribution;
    uint256 public pendingBreathRailMin;
    uint256 public pendingBreathRailMax;
    uint256 public breathRailsEffectiveTime;
    uint256 public pendingBreathOverride;
    uint256 public breathOverrideEffectiveTime;
    bytes32 public pendingBreathOverrideReason;
    bytes32 public lastBreathOverrideReason;
    uint256 public breathOverrideLockUntilDraw;
    // [v1.57-P2] targetReturnBps moved to P2 state vars block above.
    /// @dev [v1.58-P3] EMA-smoothed casual net ticket revenue per draw.
    ///      Seeded at startGame() using committedDoubleCount for accurate 2-ticket estimate.
    ///      Updated each draw in _checkAutoAdjust: 3:1 weighted blend with actual revenue.
    ///      Always updated (even zero-revenue draws decay estimate toward 0).
    uint256 public avgNetRevenuePerDraw;
    /// @dev [v1.62] Accumulated draw-30 bonus fund. Siphoned from each draw's
    ///      weekly pool at DRAW30_BONUS_BPS rate. Consumed in _calculatePrizePools()
    ///      on draw 30 (called from resolveWeek()). Returned to prizePot on dormancy
    ///      activation if draw 30 is never reached.
    ///      Only increments on non-reset draws. Reset on new game (gameSettled cleared).
    uint256 public draw30BonusFund;
    /// @dev [v1.59] Sum of ogRatioBps captured after each draw. Divided by
    ///      ogRatioDrawCount in closeGame() to compute the season-average OG ratio.
    ///      Ensures the final OG return reflects the economics players experienced
    ///      across all non-reset draws of the season EXCEPT draw 30 (draw 30 excluded
    ///      by v2.30 SSoT guard in _finalizeWeekCore: `currentDraw < TOTAL_DRAWS`).
    uint256 public ogRatioBpsAccumulator;
    /// @dev [v1.59] Count of draws accumulated into ogRatioBpsAccumulator.
    ///      [v2.30] Draw 30 excluded by the SSoT guard in _finalizeWeekCore().
    ///      Equals 29 in normal operation (no resets, draw 30 excluded).
    ///      Reduced further only by emergency reset draws (each reset-finalize
    ///      skips the accumulator increment via the !isResetFinalize guard).
    uint256 public ogRatioDrawCount;
    // [v1.58-P3] breathSeedAccumulator and breathSeedDrawCount deprecated.
    //             Revenue estimation now uses EMA in _checkAutoAdjust. Never written.
    uint256 public breathSeedAccumulator;
    uint256 public breathSeedDrawCount;

    // ── NTE30 matching state ──────────────────────────────────────────────────
    /// @dev [v1.2] Computed in resolveWeek(): ogList.length*2 + weeklyNonOGPlayers.length.
    ///      DIRECTIONAL BIAS -- two opposing effects:
    ///      (1) UNDERCOUNTS when casuals hold 2 tickets: each casual = 1 in snapshot but
    ///          generates 2 entries. Makes computed BPS read HIGHER than actual percentages.
    ///          MAX bounds (T1/T2/T3_COUNT_MAX_BPS) are the binding risk in this direction.
    ///      (2) OVERCOUNTS when OGs miss their buy and lose status during MATCHING: their
    ///          2 slots counted in snapshot but generate 0 entries. Makes computed BPS read
    ///          LOWER than actual percentages. MIN bounds are the binding risk in this direction.
    ///      (3) OVERCOUNTS (minor) when a status-lost OG re-buys as casual before pruning:
    ///          counted twice in ogList (2 slots) + once in weeklyNonOGPlayers (1 slot) = 3x
    ///          in snapshot but generates only 1-2 actual entries. Same overcount direction
    ///          as (2) -- MAX bounds absorb. Resolved at next pruneStaleOGs() call.
    ///      Verification bounds are set wide enough to absorb both effects simultaneously.
    ///      Reset to 0 in _finalizeWeekCore and emergencyResetDraw.
    uint256 public snapshotTotalEntries;

    /// @dev [v1.0] Set by submitCutoffDiffs() in CUTOFF_SUBMISSION phase.
    ///      t1CutoffDiff: entries with diff <= this win T1 (1% Club jackpot).
    ///      t2CutoffDiff: entries with diff <= this win T1 or T2.
    ///      t3CutoffDiff: entries with diff <= this win T1, T2, or T3 (~12-15% total, draw-schedule dependent).
    ///      All reset to 0 in _finalizeWeekCore and emergencyResetDraw.
    uint256 public t1CutoffDiff;
    uint256 public t2CutoffDiff;
    uint256 public t3CutoffDiff;

    struct PlayerData {
        bool registered;
        bool commitmentPaid;
        bool isUpfrontOG;
        bool commitmentDouble;
        bool isWeeklyOG;
        bool weeklyOGStatusLost;
        bool isLapsed;
        uint256 statusLostAtDraw;
        bool endgameClaimed;
        bool dormancyRefunded;
        uint256 prediction;
        uint256 prediction2;
        uint256 predictionDraw;
        uint256 prediction2Draw;
        uint256 lastBoughtDraw;
        uint256 lastActiveWeek;
        uint256 firstPlayedDraw;
        uint256 consecutiveWeeks;
        uint256 totalPaid;
        uint256 lastTicketCount;
        uint256 lastTicketCost;
        uint256 pregameOGNetContributed;
        uint256 resetRefundClaimedAtDraw;
        uint256 resetRefundClaimedAtDraw2;
        uint256 lastResetBoughtDraw1;
        uint256 lastResetTicketCost1;
        uint256 lastResetBoughtDraw2;
        uint256 lastResetTicketCost2;
        uint256 unclaimedPrizes;
        uint256 totalPrizesWon;
    }

    mapping(address => PlayerData) public players;

    uint256 public committedPlayerCount;
    uint256 public committedDoubleCount;
    uint256 public commitmentPaidCount;
    uint256 public neverPlayedCommitmentCount;
    uint256 public lapsedPlayerCount;

    address[] public ogList;
    mapping(address => uint256) private ogListIndex;
    address[] public weeklyNonOGPlayers;
    uint256 public upfrontOGCount;
    uint256 public weeklyOGCount;
    uint256 public earnedOGCount;
    uint256 public qualifiedWeeklyOGCount;

    // ── Deprecated OG intent queue state (v1.57-P1 removal) ─────────────────────
    // Never written in v1.57+. Retained for storage layout compatibility only.
    // Subgraphs must not index OGIntentRegistered/OGIntentOffered events -- never emitted.
    address[] public ogIntentQueue;
    uint256 public ogIntentQueueHead;
    uint256 public pendingIntentCount;
    mapping(address => OGIntentStatus) public ogIntentStatus;
    mapping(address => uint256) public ogIntentAmount;
    mapping(address => uint256) public ogIntentWindowExpiry;
    mapping(address => uint256) private ogIntentCreditAmount;
    mapping(address => uint256) public forceDeclineRefundOwed;
    uint256 public totalForceDeclineRefundOwed;

    uint256 public lastResolvedDraw;

    // [v1.0] tierPools[3] not [4] -- 3 tiers only. T4 removed.
    // SIDE EFFECT NOTE: getSolvencyStatus() loops i<3 not i<4.
    uint256[3] public tierPools;
    uint256 public currentDrawSeedReturn;
    uint256 public matchOGIndex;
    uint256 public matchNonOGIndex;
    bool    public ogMatchingDone;
    uint256 public lastResetDraw;
    uint256 public emergencyUnwindIndex;
    uint256 public emergencyUnwindTotal;
    address[] public jpWinners;
    address[] public p2Winners;
    address[] public p3Winners;
    // [v1.0] p4Winners REMOVED. Only 3 prize tiers.
    uint256 public distTierIndex;
    uint256 public distWinnerIndex;
    uint256 public currentTierPerWinner;


    // ── [CRE v0.1 / SmartEarn] VC earnout state ────────────────────────────────
    bool    public potSeeded;
    uint256 public cumulativeSeasonTreasury;   // cumulative treasury accrued this season
    uint256 public seedReleased;               // cumulative VC seed breathed into prizes. [CRE v0.9 / NS-I-03]
                                               // Incremented in _finalizeWeekCore() (deferred by CR-L-01),
                                               // NOT in _calculatePrizePools(). Only advances when a draw
                                               // finalizes cleanly (skipped on reset-finalize).
    uint256 public seedReleaseRatioBps;        // governance: fraction of ct releasable
    uint256 public pendingSeedReleaseRatioBps;
    uint256 public seedReleaseRatioEffectiveTime;
    uint256 public vcReturnOwed;               // set at closeGame / sweepDormancyRemainder
    /// @notice [CRE v0.4 / SE-M-01] Pre-funded VC bonus. Moved from treasuryBalance to here
    ///         the moment a tier threshold is crossed in buyTickets(). Owner cannot withdraw
    ///         escrowed funds. Transferred to vcReturnOwed at closeGame / sweepDormancyRemainder.
    uint256 public vcBonusEscrow;
    uint256 public currentDrawSeedSupplement;  // [CRE v0.9 / IC-L-01] this draw's seed supplement.
                                               // Set in _calculatePrizePools(); CONSUMED in
                                               // _finalizeWeekCore() where it is added to seedReleased
                                               // (CR-L-01 deferral). Cleared each draw at finalize and on
                                               // reset. The old emergencyResetDraw() rollback consumer was
                                               // deleted in v0.8 -- a reset simply never counts it as released.
    uint256 public currentDrawT3FloorTopup;    // [CRE v1.10 / T3-FLOOR-DEFER] this draw's T3-floor
                                               // seed top-up. Set in _processMatchesCore(); CONSUMED in
                                               // _finalizeWeekCore() where it is added to seedReleased under
                                               // !isResetFinalize. Cleared each draw at finalize and on reset.
                                               // Deferred (not eager) so an emergencyResetDraw() in
                                               // DISTRIBUTING -- which returns tierPools to prizePot -- simply
                                               // never counts it as released, mirroring CR-L-01. An eager
                                               // increment desynced seedReleased from the un-spent pot.
    // Dormancy VC pool (cleared to vcReturnOwed at sweepDormancyRemainder)
    // [CRE v0.6 / INFO-02] Reserved at activateDormancy() but NOT claimable until
    // sweepDormancyRemainder(), which requires block.timestamp >= dormancyTimestamp +
    // DORMANCY_CLAIM_WINDOW (90 days). On an emergency shutdown the VC's senior tier is
    // carved out immediately here, yet principal return waits the full claim window. The
    // delay is by design (players claim first within the window); the VC should expect it.
    uint256 public dormancyVCPool;
    uint256 public dormancyVCPoolSnapshot;
    bool    public dormancyVCFullCover;
    uint256 public dormancyAvgTargetReturnBps; // informational only in v0.3 -- no longer used for OG pool sizing
    uint256 public dormancyTotalOGEntitlement; // [CRE v0.3] totalOGPrincipal * netRate * drawsUnplayed / TOTAL_DRAWS
    uint256 public dormancyDrawsPlayed;         // [CRE v0.3] draws completed before dormancy activation (currentDraw - 1)
    /// @notice [CRE v0.12 / D5-L-01] Count of draws voided by emergency resets this season.
    ///         Each reset consumes a draw number (currentDraw++ at reset-finalize) with no play,
    ///         so activateDormancy() subtracts this from raw drawsPlayed to keep OG pro-rata honest.
    ///         Incremented once per completed reset in _finalizeWeekCore()'s isResetFinalize branch.
    ///         Storage-appended after dormancyDrawsPlayed (layout-safe; no reordering of prior slots).
    uint256 public resetDrawCount;

    /// @notice [CRE v1.0] Address authorised to deliver CRE reports via onReport().
    ///         Set to the Chainlink KeystoneForwarder for the target chain, NOT a
    ///         keeper EOA. address(0) DISABLES CRE delivery (safe default at deploy).
    ///         Storage-appended after resetDrawCount (layout-safe, no slot shift).
    address public creForwarder;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploys BullsEth (pure USDC, no Aave dependency).
    /// @param _usdc                  USDC token address. Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    /// @param _ethFeed               Chainlink ETH/USD feed (8 decimals). Base: 0x71041dddad3595F9CEd3dCCFBe3D1F4b0a16Bb70
    /// @param _defaultPrediction     Default prediction in USD cents for draw-1 auto-default.
    /// @param _sequencerFeed         L2 sequencer uptime feed. Base: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
    /// @param _protocolBeneficiary   Immutable recipient for all post-game unclaimed sweeps.
    /// @param _vcSeed                SmartEarn VC seed in USDC (6 decimals). 0 DISABLES the entire
    ///                              SmartEarn/VC mechanism: no seed deposit, no bonus tiers, no VC
    ///                              return path. When 0, all subsequent SmartEarn params are inert.
    /// @param _vcSeedReturnAddress  Immutable wallet receiving (VC_SEED - seedReleased) at closeGame(),
    ///                              sweepDormancyRemainder(), or sweepFailedPregame(). Required non-zero
    ///                              when _vcSeed > 0. Must not be USDC or address(this) [L-04]. Set a
    ///                              multisig: no on-chain recovery or expiry exists if the key is lost.
    /// @param _vcBonusTier1Threshold Cumulative season treasury (USDC) at which tier-1 SmartEarn bonus
    ///                              unlocks. 0 (with tier-1 amount 0) disables tier 1. If active, must be
    ///                              >= _vcBonusTier1Amount so earned treasury covers the escrow [SE-M-01].
    /// @param _vcBonusTier1Amount   Tier-1 bonus (USDC) paid to the VC on crossing the tier-1 threshold.
    ///                              If active, must be > 0 and (when _vcSeed > 0) <= _vcSeed.
    /// @param _vcBonusTier2Threshold Cumulative season treasury at which tier-2 unlocks. Tier 2 requires
    ///                              tier 1 active. Must be strictly greater than _vcBonusTier1Threshold,
    ///                              and the incremental threshold must cover the incremental bonus delta
    ///                              [SE-M-01]. Tiers are exclusive: only the highest crossed tier pays.
    /// @param _vcBonusTier2Amount   Tier-2 bonus (USDC). Must exceed _vcBonusTier1Amount and (when
    ///                              _vcSeed > 0) be <= _vcSeed.
    /// @param _maxSeedReleaseRatioBps Per-season cap on cumulative seed release as BPS of VC_SEED
    ///                              (0 = no cap). Must be <= 10000.
    /// @param _maxSeedPerDrawBps    Per-draw cap on seed release as BPS of VC_SEED (0 = no cap).
    ///                              Must be <= 10000.
    constructor(
        address _usdc, address _ethFeed,
        uint256 _defaultPrediction, address _sequencerFeed, address _protocolBeneficiary,
        uint256 _vcSeed, address _vcSeedReturnAddress,
        uint256 _vcBonusTier1Threshold, uint256 _vcBonusTier1Amount,
        uint256 _vcBonusTier2Threshold, uint256 _vcBonusTier2Amount,
        uint256 _maxSeedReleaseRatioBps, uint256 _maxSeedPerDrawBps
    ) Ownable2Step() {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_ethFeed == address(0)) revert InvalidAddress();
        _validatePrediction(_defaultPrediction); // [v2.02] B-2.01-02: full validation (0 and upper bound)
        if (_protocolBeneficiary == address(0)) revert InvalidAddress();
        if (_protocolBeneficiary == _usdc) revert InvalidAddress();
        if (_protocolBeneficiary == address(this)) revert InvalidAddress();
        if (_sequencerFeed == address(0)) revert InvalidAddress();
        try AggregatorV3Interface(_ethFeed).decimals() returns (uint8 dec) {
            if (dec != 8) revert FeedDecimalsMismatch();
        } catch { revert FeedDecimalsMismatch(); }
        // [v1.0] InvalidTierConfiguration guard REMOVED -- no TIER_BPS constants.
        PROTOCOL_BENEFICIARY = _protocolBeneficiary;
        ethFeed = _ethFeed;
        defaultPrediction = _defaultPrediction;
        USDC = _usdc;
        SEQUENCER_FEED = _sequencerFeed;
        DEPLOY_TIMESTAMP = block.timestamp;
        gamePhase = GamePhase.PREGAME;
        drawPhase = DrawPhase.IDLE;
        signupDeadline = block.timestamp + SIGNUP_DURATION;

        // [CRE v0.1 / SmartEarn] VC earnout validation and immutable assignment.
        // VC_SEED == 0 disables the entire SmartEarn mechanism.
        if (_vcSeed > 0) {
            if (_vcSeedReturnAddress == address(0)) revert InvalidAddress();
            if (_vcSeedReturnAddress == _usdc)      revert InvalidAddress();
            // [CRE v0.7 / L-04] Reject address(this). Every other address input in this
            // contract rejects the contract itself; this asymmetry was the gap. A return
            // address of the contract would make claimVCReturn() send VC principal back
            // into the contract, stranding it with no recovery path.
            if (_vcSeedReturnAddress == address(this)) revert InvalidAddress();
        }
        bool _tier1Active = (_vcBonusTier1Threshold > 0 || _vcBonusTier1Amount > 0);
        bool _tier2Active = (_vcBonusTier2Threshold > 0 || _vcBonusTier2Amount > 0);
        if (_tier1Active) {
            if (_vcBonusTier1Threshold == 0) revert BelowMinimum();
            if (_vcBonusTier1Amount    == 0) revert BelowMinimum();
            if (_vcSeed > 0 && _vcBonusTier1Amount > _vcSeed) revert ExceedsLimit();
            // [CRE v0.4 / SE-M-01] Threshold must be >= bonus. If treasury hasn't been drained,
            // hitting the threshold means enough treasury was earned to cover the escrow.
            if (_vcBonusTier1Threshold < _vcBonusTier1Amount) revert BelowMinimum();
        }
        if (_tier2Active) {
            if (!_tier1Active)                                       revert BelowMinimum();
            if (_vcBonusTier2Threshold <= _vcBonusTier1Threshold)   revert BelowMinimum();
            if (_vcBonusTier2Amount    <= _vcBonusTier1Amount)      revert BelowMinimum();
            if (_vcSeed > 0 && _vcBonusTier2Amount > _vcSeed)      revert ExceedsLimit();
            // [CRE v0.4 / SE-M-01] Incremental threshold must cover incremental bonus delta.
            // Closes the cross-tier gap: treasury earned between tier1 and tier2 must be
            // enough to fund the additional escrow.
            if ((_vcBonusTier2Threshold - _vcBonusTier1Threshold) < (_vcBonusTier2Amount - _vcBonusTier1Amount))
                revert BelowMinimum();
        }
        if (_maxSeedReleaseRatioBps > 10000) revert ExceedsLimit();
        if (_maxSeedPerDrawBps > 10000)      revert ExceedsLimit();
        // [CRE v1.11a / PG-01 fix] FAIL-CLOSED. The old fixed-tier bonus is superseded by the
        // spent-seed return model and is dead in every valid config: forbidden when seeded (it
        // would double-pay the VC), and when unseeded it could fire vcBonusEscrow to an
        // unvalidated VC_SEED_RETURN_ADDRESS (possibly address(0)). So tier params are now
        // rejected UNCONDITIONALLY. Full removal of the tier mechanism (params + crossing logic
        // at line ~2157 + vcBonusEscrow references) is a tracked follow-up (KNOWN_ISSUES).
        if (_tier1Active || _tier2Active) revert ExceedsLimit();
        // [CRE v1.01 / SEED-CAP] A seeded game MUST set a per-draw release cap. BullsEth's
        // inline seed release has no ceiling ratchet, so maxSeedPerDrawBps is the only
        // bound on per-draw release velocity. Deploying a seeded game with cap 0 would
        // let a high governance ratio dump the seed in a few draws. Mirrors the SeedRelease
        // primitive's opt-in discipline: the dangerous config must be impossible, not just
        // discouraged. (VC_SEED == 0 disables SmartEarn entirely, so the cap is moot there.)
        if (_vcSeed > 0 && _maxSeedPerDrawBps == 0) revert ExceedsLimit();
        // [CRE v1.06 / VC-SPENT-CAP] Solvency bound for the spent-seed return model. The VC is
        // owed seedReleased * (1 + 25% + 25% bonus) = seedReleased * 1.5 max from treasury. Since
        // seedReleased <= cumulativeSeasonTreasury * seedReleaseRatioBps / 10000, the obligation
        // stays <= treasury iff maxRatio * (10000 + return + bonus) <= 10000^2. A 0 ratio cap means
        // unbounded release, which would let the obligation exceed treasury. So a seeded game must
        // set a release-ratio cap low enough that the return is always fundable (with return=bonus=
        // 25% this caps the ratio at 6666 = 66.66%). Without this, the game could owe the VC more
        // treasury than the season ever earns.
        if (_vcSeed > 0) {
            if (_maxSeedReleaseRatioBps == 0) revert ExceedsLimit();
            if (_maxSeedReleaseRatioBps * (10000 + VC_SPENT_RETURN_BPS + VC_SPENT_BONUS_BPS) > 10000 * 10000) revert ExceedsLimit();
        }
        VC_SEED                    = _vcSeed;
        VC_SEED_RETURN_ADDRESS     = _vcSeedReturnAddress;
        VC_BONUS_TIER1_THRESHOLD   = _vcBonusTier1Threshold;
        VC_BONUS_TIER1_AMOUNT      = _vcBonusTier1Amount;
        VC_BONUS_TIER2_THRESHOLD   = _vcBonusTier2Threshold;
        VC_BONUS_TIER2_AMOUNT      = _vcBonusTier2Amount;
        MAX_SEED_RELEASE_RATIO_BPS = _maxSeedReleaseRatioBps;
        MAX_SEED_PER_DRAW_BPS      = _maxSeedPerDrawBps;
    }

    function renounceOwnership() public override onlyOwner { revert RenounceOwnershipDisabled(); }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        ownershipTransferExpiry = block.timestamp + OWNERSHIP_TRANSFER_EXPIRY;
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override {
        if (ownershipTransferExpiry == 0) revert NoTimelockPending();
        if (block.timestamp > ownershipTransferExpiry) revert OwnershipTransferExpired();
        ownershipTransferExpiry = 0;
        super.acceptOwnership();
    }

    // ── [CRE v0.1 / SmartEarn] VC seed ──────────────────────────────────────────

    /// @notice Seeds the prize pot with exactly VC_SEED USDC. Callable once during PREGAME only.
    ///         VC capital goes 100% to prizePot — no treasury slice on seed.
    ///         The seed supplement activates only after SEED_RELEASE_THRESHOLD of cumulative
    ///         season treasury is earned AND seedReleaseRatioBps > 0.
    ///         [CRE v0.2 / LOW-01] Restricted to onlyOwner (was permissionless). A stranger calling
    ///         this would pull VC_SEED from their own wallet and route it to VC_SEED_RETURN_ADDRESS
    ///         at close — not theft, but an accidental donation. Phase gate added: PREGAME only.
    ///         A post-game call would seed a closed/dormant contract with no distribution path.
    function seedPot() external onlyOwner nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        if (VC_SEED == 0) revert BelowMinimum();
        if (potSeeded) revert PotAlreadySeeded();
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), VC_SEED);
        potSeeded  = true;
        prizePot  += VC_SEED;
        emit PotSeeded(VC_SEED, msg.sender);
    }

    // ── Registration ──────────────────────────────────────────────────────────

    /// @notice Registers the caller as a player. Required before any other action.
    function register() external nonReentrant {
        if (gamePhase != GamePhase.PREGAME && gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (players[msg.sender].registered) revert AlreadyRegistered();
        if (gamePhase == GamePhase.ACTIVE) {
            // Active casual count = lifetime buyers minus lapsed (lapsed hold no slot).
            // OG slots counted directly. Combined cap = MAX_PLAYERS.
            if ((totalLifetimeBuyers > lapsedPlayerCount ? totalLifetimeBuyers - lapsedPlayerCount : 0)
                + upfrontOGCount + weeklyOGCount >= MAX_PLAYERS) revert MaxPlayersReached();
        }
        players[msg.sender].registered = true;
        totalRegisteredPlayers++;
        emit PlayerRegistered(msg.sender, totalRegisteredPlayers);
    }

    /// @notice Pays the pregame ticket commitment and locks in a prediction. PREGAME only.
    /// @param prediction  ETH/USD price prediction in USD cents.
    function payCommitment(uint256 prediction) external nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        if (block.timestamp >= signupDeadline) revert PregameWindowExpired();
        PlayerData storage p = players[msg.sender];
        if (!p.registered) revert NotRegistered();
        if (p.isUpfrontOG || p.isWeeklyOG) revert AlreadyOG();
        if (p.commitmentPaid) revert AlreadyCommitted();
        // [v1.57-P1] AlreadyInIntentQueue guard removed -- intent queue eliminated.
        if (committedPlayerCount >= MAX_PLAYERS) revert MaxPlayersReached();
        _validatePrediction(prediction);
        uint256 cost = TICKET_PRICE;
        uint256 treasurySlice = cost * TREASURY_BPS / 10000;
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), cost);
        treasuryBalance += treasurySlice; prizePot += cost - treasurySlice;
        p.totalPaid += cost; p.commitmentPaid = true;
        commitmentPaidCount++; neverPlayedCommitmentCount++;
        p.prediction = prediction; p.predictionDraw = 1;
        committedPlayerCount++;
        emit TreasuryAccrual(0, treasurySlice, TREASURY_BPS);
        emit CommitmentPaid(msg.sender, cost);
    }

    /// @notice Pregame double-ticket commitment. Pays 2x TICKET_PRICE upfront.
    ///         WARNING [v1.54]: If the player buys only 1 ticket on draw 1, the second credit
    ///         is NOT refunded -- it is forfeited to the prize pool. CommitmentDoubleUnused fires
    ///         on draw 2 when the expired credit is detected. Players uncertain about buying 2 tickets
    ///         on draw 1 should use payCommitment() (single) instead. This is by design: the double
    ///         commitment signals intent to play 2 tickets from day one.
    /// @param prediction   First ETH/USD prediction (USD cents).
    /// @param prediction2  Second ETH/USD prediction (USD cents).
    function payCommitmentDouble(uint256 prediction, uint256 prediction2) external nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        if (block.timestamp >= signupDeadline) revert PregameWindowExpired();
        PlayerData storage p = players[msg.sender];
        if (!p.registered) revert NotRegistered();
        if (p.isUpfrontOG || p.isWeeklyOG) revert AlreadyOG();
        if (p.commitmentPaid) revert AlreadyCommitted();
        // [v1.57-P1] AlreadyInIntentQueue guard removed -- intent queue eliminated.
        if (committedPlayerCount >= MAX_PLAYERS) revert MaxPlayersReached();
        _validatePrediction(prediction); _validatePrediction(prediction2);
        uint256 cost = TICKET_PRICE * 2;
        uint256 treasurySlice = cost * TREASURY_BPS / 10000;
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), cost);
        treasuryBalance += treasurySlice; prizePot += cost - treasurySlice;
        p.totalPaid += cost; p.commitmentPaid = true;
        commitmentPaidCount++; neverPlayedCommitmentCount++;
        p.commitmentDouble = true;
        p.prediction = prediction; p.predictionDraw = 1;
        p.prediction2 = prediction2; p.prediction2Draw = 1;
        committedPlayerCount++; committedDoubleCount++;
        emit TreasuryAccrual(0, treasurySlice, TREASURY_BPS);
        emit CommitmentDoublePaid(msg.sender, cost);
    }

    /// @notice Registers caller as an Upfront OG. Pays OG_UPFRONT_COST immediately.
    ///         OG status is GRANTED IMMEDIATELY -- no queue, no owner confirmation needed.
    ///         If a pregame commitment credit was applied, that credit is forfeited on
    ///         cancellation -- only the OG transfer net of 25% is returned.
    ///         A 72-hour voluntary decline window opens. Call cancelOGRegistration() within
    ///         72 hours for a 75% refund (25% treasury slice non-refundable as commitment).
    ///         [CRE v0.2 / LOW-02] was "90% refund (10% treasury slice)". Rates updated for flat 25%.
    ///         After 72 hours the registration is permanent.
    /// @dev [v1.57-P1] Intent queue removed entirely. No PENDING status. No confirmOGSlots().
    ///      No ratio cap on OG registration. Any number of OGs can register.
    ///      Game can start with 100% OGs if that is what happens -- economics handle it.
    /// @param prediction   ETH/USD price in USD cents. Primary prediction for all draws.
    /// @param prediction2  Secondary prediction (second match entry). May equal prediction.
    function registerAsOG(uint256 prediction, uint256 prediction2) external nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        // [CRE v0.6 / LOW-01] Block new upfront OG registration once a start is proposed.
        // Mirrors registerAsWeeklyOG. Without this, an upfront OG registering inside the
        // notice window has their decline window silently truncated to less than the full
        // OG_DECLINE_WINDOW and then made permanent at startGame() -- voiding the 75%
        // cancellation right with no warning. Blocking late registration is the honest fix.
        if (startGameProposedAt != 0) revert TimelockPending();
        PlayerData storage p = players[msg.sender];
        if (p.isUpfrontOG || p.isWeeklyOG) revert AlreadyOG();
        if (p.dormancyRefunded) revert AlreadyRefunded();
        _validatePrediction(prediction);
        _validatePrediction(prediction2);
        if (block.timestamp >= signupDeadline) revert PregameWindowExpired();
        if (committedPlayerCount >= MAX_PLAYERS) revert MaxPlayersReached();

        if (!p.registered) {
            p.registered = true;
            totalRegisteredPlayers++;
            emit PlayerRegistered(msg.sender, totalRegisteredPlayers);
        }

        // [v1.57-P2] UF OGs pay treasury at UF_OG_TREASURY_BPS. [CRE v0.1/v0.2] now 25% flat (was 10%).
        bool usingOGCredit  = p.commitmentPaid;
        uint256 ogCredit    = usingOGCredit ? (p.commitmentDouble ? TICKET_PRICE * 2 : TICKET_PRICE) : 0;
        uint256 ogTransfer  = OG_UPFRONT_COST - ogCredit;
        uint256 treasurySlice = ogTransfer * UF_OG_TREASURY_BPS / 10000;

        if (ogTransfer > 0) {
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), ogTransfer);
        }

        if (usingOGCredit) {
            if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false;
            if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
        }

        treasuryBalance += treasurySlice;
        prizePot        += ogTransfer - treasurySlice;
        p.totalPaid     += ogTransfer;
        p.prediction     = prediction;
        p.prediction2    = prediction2;
        p.predictionDraw = 1;
        p.prediction2Draw = 1;
        // [Phase 4] drawsPlayed and totalPoints added in Phase 4 (points system).

        // [v1.57-P1] Grant OG status immediately
        ogListIndex[msg.sender] = ogList.length;
        ogList.push(msg.sender);
        p.isUpfrontOG   = true;
        upfrontOGCount++;
        // [v1.98] F1 fix: use OG_UPFRONT_COST not ogTransfer so totalOGPrincipal
        // matches p.totalPaid for credit-using OGs. p.totalPaid = commitment + transfer
        // = OG_UPFRONT_COST regardless of credit usage. Dormancy waterfall reads p.totalPaid
        // per claimer -- the pool must be sized to match.
        totalOGPrincipal += OG_UPFRONT_COST;

        if (!usingOGCredit) committedPlayerCount++;

        // [v1.57-P1] Open 72-hour voluntary decline window
        uint256 windowExpiry = block.timestamp + OG_DECLINE_WINDOW;
        ogDeclineWindowExpiry[msg.sender] = windowExpiry;
        // Store exact refundable amount: net OG transfer only (commitment credit forfeited).
        ogCancelRefund[msg.sender] = ogTransfer * (10000 - UF_OG_TREASURY_BPS) / 10000;

        emit TreasuryAccrual(0, treasurySlice, UF_OG_TREASURY_BPS);
        emit UpfrontOGRegistered(msg.sender, prediction, prediction2, upfrontOGCount);
        emit OGDeclineWindowOpened(msg.sender, windowExpiry);
    }

    /// @notice Cancels an OG registration within the 72-hour decline window.
    ///         Returns 75% of the OG transfer (ogTransfer * 75%).
    ///         The 25% treasury slice is non-refundable -- it was the commitment signal.
    ///         [CRE v0.2 / LOW-02] was "90% / 10%" — updated for flat 25% treasury.
    ///         If a commitment credit was applied at registration, the credit is forfeited.
    ///         This is voluntary consumer protection. The window is player-controlled.
    ///         Re-registration: cancelling does NOT set dormancyRefunded. The player may
    ///         call registerAsOG() again (paying another 25% treasury slice each time).
    ///         Each attempt costs the same treasury signal. This is intentional.
    /// @dev [v1.57-P1] Replaces claimOGIntentRefund(). No queue state to unwind.
    ///      Uses stored ogCancelRefund mapping to avoid mixed-rate calculation errors
    ///      (commitment paid 25% treasury; OG transfer paid 25% UF treasury).
    ///      [CRE v0.5 / NS] Corrected from "15%/10%" — both rates are now 25% in CRE v0.1+.
    function cancelOGRegistration() external nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        uint256 expiry = ogDeclineWindowExpiry[msg.sender];
        if (expiry == 0) revert NotInDeclineWindow();
        if (block.timestamp > expiry) revert DeclineWindowExpired();

        PlayerData storage p = players[msg.sender];
        if (!p.isUpfrontOG) revert NotInDeclineWindow();

        _captureYield();

        // [v1.57-P1] Use stored net refund -- avoids mixed-rate error when
        // [CRE v0.2 / LOW-02] Both rates now 25% (UF_OG_TREASURY_BPS = TREASURY_BPS = 2500).
        // ogCancelRefund = ogTransfer × 75%. Commitment credit is forfeited on cancel.
        uint256 netRefund = ogCancelRefund[msg.sender];
        if (netRefund == 0) revert NothingToClaim(); // safety: should never be 0

        // [v1.98] F1 fix: totalOGPrincipal was incremented by OG_UPFRONT_COST at
        // registration. Decrement using the same constant -- no derivation needed.

        // Remove OG status
        p.isUpfrontOG   = false;
        p.totalPaid     = 0;
        p.prediction    = 0; p.prediction2 = 0;
        p.predictionDraw = 0; p.prediction2Draw = 0;
        ogDeclineWindowExpiry[msg.sender] = 0;
        ogCancelRefund[msg.sender] = 0;

        if (upfrontOGCount > 0) upfrontOGCount--;
        // [v1.98] F1 fix: reverse full OG_UPFRONT_COST (mirrors registerAsOG fix).
        if (totalOGPrincipal >= OG_UPFRONT_COST) totalOGPrincipal -= OG_UPFRONT_COST;
        else totalOGPrincipal = 0;
        if (committedPlayerCount > 0) committedPlayerCount--;

        // Remove from ogList
        uint256 ogLen = ogList.length;
        if (ogLen > 0 && ogListIndex[msg.sender] < ogLen
            && ogList[ogListIndex[msg.sender]] == msg.sender) {
            uint256 idx  = ogListIndex[msg.sender];
            uint256 last = ogLen - 1;
            if (idx != last) {
                address lastAddr = ogList[last];
                ogList[idx] = lastAddr;
                ogListIndex[lastAddr] = idx;
            }
            ogList.pop();
            delete ogListIndex[msg.sender];
        }

        // Return net to player (treasury slice stays -- it was the commitment signal)
        if (prizePot >= netRefund) {
            prizePot -= netRefund;
        } else {
            uint256 deficit = netRefund - prizePot;
            prizePot = 0;
            // Drain treasury toward deficit. If treasuryBalance < deficit, drain fully
            // to zero. Residual covered by actual USDC balance -- SafeERC20 reverts on
            // _withdrawAndTransfer if insufficient. Avoids phantom treasury balance.
            if (treasuryBalance >= deficit) {
                treasuryBalance -= deficit;
            } else {
                treasuryBalance = 0;
            }
        }

        // [v1.57-P1] Clear deprecated intent queue state (always zero in new design,
        // but cleared for consistency with _cleanupOGOnRefund).
        if (ogIntentStatus[msg.sender] != OGIntentStatus.NONE) {
            ogIntentStatus[msg.sender] = OGIntentStatus.DECLINED;
            ogIntentAmount[msg.sender] = 0;
        }

        _withdrawAndTransfer(msg.sender, netRefund);
        emit OGRegistrationCancelled(msg.sender, netRefund);
    }

    // [v1.57-P1] confirmOGSlots removed -- intent queue eliminated.


    // [v1.57-P1] claimOGIntentRefund removed -- intent queue eliminated.


    // [v1.57-P1] sweepExpiredDeclines removed -- intent queue eliminated.


    // [v1.57-P1] forceDeclineIntent removed -- intent queue eliminated.



    /// @notice Claims any outstanding force-decline refund owed to the caller.
    /// @dev [v1.57-P1] forceDeclineIntent() was removed with the intent queue.
    ///      forceDeclineRefundOwed[] is never written in the new design.
    ///      This function always reverts NothingToClaim() for any new deployment.
    ///      Retained for ABI compatibility with tooling built against earlier versions.
    function claimForceDeclineRefund() external nonReentrant {
        uint256 owed = forceDeclineRefundOwed[msg.sender];
        if (owed == 0) revert NothingToClaim();
        forceDeclineRefundOwed[msg.sender] = 0;
        if (totalForceDeclineRefundOwed >= owed) totalForceDeclineRefundOwed -= owed; else totalForceDeclineRefundOwed = 0;
        _withdrawAndTransfer(msg.sender, owed);
        emit ForceDeclineRefundClaimed(msg.sender, owed);
    }

    /// @notice Registers caller as a Weekly OG. Pays 2x TICKET_PRICE. PREGAME only.
    ///         Weekly OGs must buy tickets every draw to maintain status.
    ///         Missing a draw loses status -- no mulligan in BullsEth.
    ///         Note: weekly OG registration has NO 72-hour decline window.
    ///         Unlike registerAsOG(), this registration is immediate and permanent.
    ///         Weekly OG slots may be fully consumed by upfront OG uptake if
    ///         upfrontOGCount exceeds TOTAL_OG_CAP_BPS% of committed players.
    /// @dev [v1.57-P1] startGameProposedAt guard now throws TimelockPending (was ActiveDeclineWindowOpen).
    ///      Weekly OG ratio cap (_weeklyOGCapReached) still enforced. Upfront OG cap removed.
    /// @param prediction   First ETH/USD prediction for the current draw (USD cents).
    /// @param prediction2  Second ETH/USD prediction for the current draw (USD cents).
    function registerAsWeeklyOG(uint256 prediction, uint256 prediction2) external nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (startGameProposedAt != 0) revert TimelockPending(); // [v1.57-P1] was ActiveDeclineWindowOpen -- semantically wrong
        if (block.timestamp >= signupDeadline) revert PregameWindowExpired();
        PlayerData storage p = players[msg.sender];
        if (p.isUpfrontOG || p.isWeeklyOG) revert AlreadyOG();
        if (p.dormancyRefunded) revert AlreadyRefunded();
        // [v1.57-P1] AlreadyInIntentQueue guard removed -- intent queue eliminated.
        if (_weeklyOGCapReached()) revert OGCapReached();
        if (committedPlayerCount >= MAX_PLAYERS) revert MaxPlayersReached();
        if (!p.registered) { p.registered = true; totalRegisteredPlayers++; emit PlayerRegistered(msg.sender, totalRegisteredPlayers); }
        _validatePrediction(prediction); _validatePrediction(prediction2);
        uint256 cost = TICKET_PRICE * MIN_TICKETS_WEEKLY_OG;
        bool usingPreCommitment = p.commitmentPaid;
        uint256 creditAmount = usingPreCommitment ? (p.commitmentDouble ? TICKET_PRICE * 2 : TICKET_PRICE) : 0;
        uint256 transferCost = cost - creditAmount;
        if (transferCost > 0) {
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), transferCost);
        }
        if (transferCost > 0) {
            uint256 tSlice = transferCost * TREASURY_BPS / 10000;
            treasuryBalance += tSlice; prizePot += transferCost - tSlice;
            emit TreasuryAccrual(0, tSlice, TREASURY_BPS);
        }
        // [v1.54] M-01 AUDIT NOTE: p.totalPaid correctly tracks GROSS contribution.
        // If usingPreCommitment: p.totalPaid already holds TICKET_PRICE ($10) from payCommitment().
        // transferCost adds the remaining $10, giving cumulative p.totalPaid = $20 = totalOGPrincipal increment.
        // If not usingPreCommitment: transferCost = cost = $20, p.totalPaid += $20 = totalOGPrincipal += $20.
        // In all cases: p.totalPaid (cumulative) == cost == amount added to totalOGPrincipal. Invariant holds.
        p.isWeeklyOG = true; p.totalPaid += transferCost;
        p.lastTicketCount = MIN_TICKETS_WEEKLY_OG; p.lastTicketCost = cost;
        p.prediction = prediction; p.prediction2 = prediction2;
        if (usingPreCommitment && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
        p.predictionDraw = 1; p.prediction2Draw = 1; p.lastBoughtDraw = 1;
        p.consecutiveWeeks = 1; p.lastActiveWeek = 1; p.firstPlayedDraw = 1;
        if (usingPreCommitment) {
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false;
            if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
        } else { committedPlayerCount++; }
        // [v2.05/v2.06] include commitment credit net so EMA seed is accurate.
        // Previously excluded commitment net understated pregameWeeklyOGNetTotal for
        // credit-using WOGs, causing slightly conservative avgNetRevenuePerDraw seed.
        // creditAmount already computed above: TICKET_PRICE*2 if double, TICKET_PRICE if single.
        uint256 commitNet = usingPreCommitment ? creditAmount * (10000 - TREASURY_BPS) / 10000 : 0;
        uint256 pregameOGNet = transferCost * (10000 - TREASURY_BPS) / 10000 + commitNet;
        p.pregameOGNetContributed = pregameOGNet;
        pregameWeeklyOGTicketTotal += cost;
        pregameWeeklyOGNetTotal += pregameOGNet;
        totalOGPrincipal += cost;
        ogListIndex[msg.sender] = ogList.length;
        ogList.push(msg.sender);
        weeklyOGCount++; earnedOGCount++;
        emit WeeklyOGRegistered(msg.sender, prediction, prediction2, 1);
    }


    /// @notice Sets the reserve ETH/USD price feed used as primary fallback. Owner only.
    /// @param _reserveFeed  New reserve feed address. address(0) clears the fallback.
    function setReserveFeed(address _reserveFeed) external onlyOwner {
        // FeedSubstituted reused for admin feed management -- semantically distinct from startGame() usage.
        if (_reserveFeed == address(0)) { address old = ethReserveFeed; ethReserveFeed = address(0); emit FeedSubstituted(old, address(0)); return; }
        if (_reserveFeed == USDC || _reserveFeed == address(this)) revert InvalidAddress();
        if (_reserveFeed == SEQUENCER_FEED && SEQUENCER_FEED != address(0)) revert InvalidAddress();
        if (_reserveFeed == ethFeed) revert FeedUnchanged();
        if (_reserveFeed == wethFeed) revert FeedUnchanged();
        try AggregatorV3Interface(_reserveFeed).decimals() returns (uint8 dec) { if (dec != 8) revert FeedDecimalsMismatch(); } catch { revert FeedDecimalsMismatch(); }
        address oldReserve = ethReserveFeed;
        ethReserveFeed = _reserveFeed;
        emit FeedSubstituted(oldReserve, _reserveFeed);
    }

    /// @notice Sets the WETH/USD price feed used as secondary fallback. Owner only.
    /// @param _wethFeed  New WETH feed address. address(0) clears the fallback.
    function setWethFeed(address _wethFeed) external onlyOwner {
        // FeedSubstituted reused for admin feed management -- semantically distinct from startGame() usage.
        if (_wethFeed == address(0)) { address old = wethFeed; wethFeed = address(0); emit FeedSubstituted(old, address(0)); return; }
        if (_wethFeed == USDC || _wethFeed == address(this)) revert InvalidAddress();
        if (_wethFeed == SEQUENCER_FEED && SEQUENCER_FEED != address(0)) revert InvalidAddress();
        if (_wethFeed == ethFeed) revert FeedUnchanged();
        if (_wethFeed == ethReserveFeed) revert FeedUnchanged();
        try AggregatorV3Interface(_wethFeed).decimals() returns (uint8 dec) { if (dec != 8) revert FeedDecimalsMismatch(); } catch { revert FeedDecimalsMismatch(); }
        address oldWeth = wethFeed;
        wethFeed = _wethFeed;
        emit FeedSubstituted(oldWeth, _wethFeed);
    }

    /// @notice Sets the global auto-default prediction value. Owner only.
    /// @param _prediction  Default prediction in USD cents. Used when autoDefaultCents == 0.
    function setDefaultPrediction(uint256 _prediction) external onlyOwner {
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (gamePhase != GamePhase.PREGAME && gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        _validatePrediction(_prediction);
        uint256 old = defaultPrediction;
        defaultPrediction = _prediction;
        emit DefaultPredictionUpdated(old, _prediction);
    }

    /// @notice Proposes game start with START_GAME_NOTICE_PERIOD (72h) notice.
    ///         Requires MIN_PLAYERS_TO_START (500) committed players.
    /// @dev [v1.57-P1] pendingIntentCount check removed -- intent queue eliminated.
    function proposeStartGame() external onlyOwner {
        if (gamePhase != GamePhase.PREGAME) revert GameNotActive();
        if (committedPlayerCount < MIN_PLAYERS_TO_START) revert NotEnoughPlayers();
        // [v1.57-P1] No pendingIntentCount check -- intent queue removed.
        //            Any OG in decline window at startGame becomes permanent.
        if (startGameProposedAt != 0) revert TimelockPending();
        // [v1.57-P1] latestOfferTimestamp check removed -- confirmOGSlots gone,
        //            latestOfferTimestamp is always 0. ActiveDeclineWindowOpen retired.
        if (block.timestamp >= signupDeadline + MAX_PREGAME_DURATION) revert PregameWindowExpired();
        startGameProposedAt = block.timestamp;
        emit StartGameProposed(block.timestamp + START_GAME_NOTICE_PERIOD);
    }

    /// @notice Cancels a pending startGame() proposal. Owner only.
    function cancelStartGameProposal() external onlyOwner {
        if (startGameProposedAt == 0) revert NoTimelockPending();
        startGameProposedAt = 0;
        emit StartGameProposalCancelled();
    }

    /// @notice Starts the game, sets draw 1, calibrates breath from OG ratio.
    /// @dev [v1.57-P2] STEP 1 computes targetReturnBps from actual OG ratio (50% at <=20% OG,
    ///      linear to 10% at 100% OG). [CRE v0.2 / LOW-02] corrected from "90%/30%". STEP 2 derives ogBreath from targetReturnBps.
    ///      STEP 3 takes max(ogBreath, t3FloorBreath) as starting breathMultiplier.
    /// @dev [v1.58-P3] Locks OG obligation immediately. Runs geometric solvency check.
    ///      Reverts with PotBelowTrajectory if the game cannot honour obligations at breathRailMin.
    ///      [v1.62] _simGeomPot does not model the draw30BonusFund injection at draw 30.
    ///      In reality the draw-30 pot = simulated_pot + draw30BonusFund accumulated,
    ///      so the solvency check underestimates the final pot. Conservative (pessimistic).
    function startGame() external onlyOwner nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert GameNotActive();
        // [CRE v0.4 / SE-H-01] Require seed deposited before game starts when VC_SEED is set.
        // Without this guard, requiredEndPot includes VC_SEED as a defended floor even if the
        // USDC was never deposited. At closeGame(), vcReturnOwed would be sourced from player
        // funds. One line closes a genuine misallocation path.
        if (VC_SEED > 0 && !potSeeded) revert SeedNotDeposited();
        if (block.timestamp >= signupDeadline + MAX_PREGAME_DURATION) revert PregameWindowExpired();
        if (committedPlayerCount < MIN_PLAYERS_TO_START) revert NotEnoughPlayers();
        if (startGameProposedAt == 0) revert NoTimelockPending();
        if (block.timestamp < startGameProposedAt + START_GAME_NOTICE_PERIOD) revert TooEarly();
        // [v1.57-P1] No pendingIntentCount check. Intent queue removed.
        _checkSequencer(); _captureYield();
        int256 price = _readEthPrice();
        if (price == 0 && ethReserveFeed != address(0)) {
            int256 rPrice = _readPriceFeed(ethReserveFeed);
            if (rPrice > 0) {
                bool decimalOk;
                try AggregatorV3Interface(ethReserveFeed).decimals() returns (uint8 dec) { decimalOk = (dec == 8); } catch { decimalOk = false; }
                if (decimalOk) { emit FeedSubstituted(ethFeed, ethReserveFeed); ethFeed = ethReserveFeed; price = rPrice; }
            }
        }
        if (price == 0) revert NotEnoughValidPrices();
        lastValidPrice = price;
        gamePhase = GamePhase.ACTIVE; currentDraw = 1; lastDrawTimestamp = block.timestamp;
        scheduleAnchor = block.timestamp; ogCapDenominator = committedPlayerCount;
        startGameProposedAt = 0;
        uint256 ogRatioBps = committedPlayerCount > 0
            ? (upfrontOGCount + earnedOGCount) * 10000 / committedPlayerCount : 0;

        // [v1.57-P2] STEP 1: Compute targetReturnBps from actual OG ratio.
        // Canonical curve in _computeTargetReturnBps() -- do not inline edits here.
        targetReturnBps = _computeTargetReturnBps(ogRatioBps);

        // [v1.57-P2] STEP 2: Now ogBreath uses the correct targetReturnBps.
        uint256 ogBreath = _computeStartingBreathFromTarget(targetReturnBps);

        // [v1.5] STEP 3: T3-floor breath. Final breath = max(ogBreath, t3FloorBreath).
        (uint256 t3FloorBreath, uint256 estEntries) = _computeStartingBreath();
        uint256 initialBreath = t3FloorBreath > ogBreath ? t3FloorBreath : ogBreath;
        breathMultiplier = initialBreath;
        emit BreathCalibrated(ogRatioBps, targetReturnBps, initialBreath,
            ogBreath, t3FloorBreath, estEntries);

        // [v1.58-P3] Lock OG obligation at draw 1. upfrontOGCount is the ceiling --
        // no new upfront OGs can join after startGame, so this is the maximum possible
        // obligation. [CRE v1.11a / PG-04] This is the INITIAL lock; _snapshotOGObligation
        // re-snapshots it per draw. It can rise as weekly OGs earn status (earnedOGCount) and
        // fall as OGs lose status. No draw-10 lock needed.
        {
            uint256 maxOGs = upfrontOGCount + earnedOGCount;
            ogEndgameObligation = maxOGs * OG_UPFRONT_COST;
            // requiredEndPot = OG obligation at targetReturnBps + draw-30 prize planning floor + unreleased VC seed.
            // [CRE v0.2 / HIGH-01] VC seed added so the geometric solver defends it throughout the season.
            // Without this term, the solver does not know to protect the seed and the draw-30 holdback fix alone
            // is insufficient: the solver may allow the pot to fall below VC_SEED before draw 30.
            // [CRE v1.04 / FLOOR-SPLIT] requiredEndPot is the ENDGAME target only (season-end)
            // for the solver + this sim. The live dormancy-now floor is separate (_dormancyNowFloor,
            // used by the per-draw gate). See _requiredEndPotFloor. [Was max(endgame,dormancy) pre-v1.04.]
            requiredEndPot = _requiredEndPotFloor(ogEndgameObligation);
            potAtObligationLock = prizePot;
            obligationLocked = true;
            // [CRE v1.02 / LOW-01] Floor-check the draw-1 breath. The calibrated initialBreath
            // set above is never otherwise checked against requiredEndPot, so an aggressive draw-1
            // distribution could push prizePot below the floor before the solver takes over at
            // draw 2. Cap draw-1 breath so the post-distribution pot (net of the SEED_BPS rollover,
            // which returns to prizePot at finalize) stays at or above requiredEndPot, but never
            // below breathRailMin. Uses requiredEndPot (now the season-end ENDGAME floor post v1.04
            // split); the live per-draw dormancy protection is handled separately by the DORM-GATE.
            // NOTE [review pt5]: post-split this clamp is largely vestigial. The DORM-GATE in
            // _calculatePrizePools caps draw-1 distribution against the stricter LIVE dormancy-now
            // floor and binds first, so this endgame-floor clamp rarely does anything. Kept as a
            // belt-and-braces backstop (harmless, cheap); a later tidy could remove it once the
            // gate's precedence is covered by a test.
            // Ample-headroom games are unaffected --
            // the cap sits above the calibrated breath and does not bind.
            if (prizePot > requiredEndPot) {
                uint256 _maxDraw1Breath = (prizePot - requiredEndPot) * 1e8 / (prizePot * (10000 - SEED_BPS));
                if (breathMultiplier > _maxDraw1Breath) {
                    breathMultiplier = _maxDraw1Breath > breathRailMin ? _maxDraw1Breath : breathRailMin;
                }
            } else {
                breathMultiplier = breathRailMin;
            }
            // Seed geometric revenue estimate using committedDoubleCount for 2-ticket casuals.
            // More accurate than assuming all casuals buy 1 ticket: double-commitment
            // players are known at startGame and they generate 2x revenue per draw.
            uint256 casualCount = committedPlayerCount > maxOGs ? committedPlayerCount - maxOGs : 0;
            uint256 doubleCount = committedDoubleCount < casualCount ? committedDoubleCount : casualCount;
            uint256 singleCount = casualCount - doubleCount;
            // Uses flat TREASURY_BPS=25% for all draws [CRE v0.6 NS] -- seed is accurate.
            avgNetRevenuePerDraw = (singleCount + doubleCount * 2) * TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
            // [v1.58-P3] Geometric solvency check: even at minimum breath (breathRailMin)
            // for all 30 draws, the pot must still reach requiredEndPot.
            // This is the true insolvent-deployment guard. A linear check (pot + rev*30)
            // is insufficient -- it ignores pot decay from prize distributions.
            // Reverts and rolls back all startGame state if the game is insolvent.
            // (State writes above are reverted by the EVM on revert -- nothing is committed.)
            if (_simGeomPot(prizePot, breathRailMin, TOTAL_DRAWS, avgNetRevenuePerDraw) < requiredEndPot) {
                revert PotBelowTrajectory();
            }
            emit OGObligationLocked(ogEndgameObligation, requiredEndPot, maxOGs);
        }

        if (pregameWeeklyOGTicketTotal > 0) {
            currentDrawTicketTotal += pregameWeeklyOGTicketTotal;
            currentDrawNetTicketTotal += pregameWeeklyOGNetTotal;
            // [CRE v0.5 / DR-M-02] Also fold into the weekly-OG dormancy sizing counter.
            // Without this, an early dormancy during draw 1 sizes the casual pool without
            // pregame weekly OGs, but they still claim from it — draining the pool for casuals.
            // pregameWeeklyOGNetTotal is already correct (tracked in registerAsWeeklyOG,
            // decremented in _cleanupOGOnRefund on cancellation before startGame).
            currentDrawWeeklyOGNetTicketTotal += pregameWeeklyOGNetTotal;
            // [CRE v0.7 / M-01] Fold the pregame weekly OG HEAD COUNT into the buyer count so
            // a draw-1 dormancy sizes the per-head denominator on these claimable heads. At
            // startGame weeklyOGCount equals the pregame weekly OG count exactly (no in-season
            // status losses have occurred yet; cancellations before startGame already
            // decremented it). Each is a claimable draw-1 buyer (lastBoughtDraw == 1).
            currentDrawWeeklyOGBuyerCount += weeklyOGCount;
        }
        emit GameStarted(block.timestamp, totalRegisteredPlayers);
    }

    /// @notice Claims registration refund if the game never started. PREGAME only.
    ///         If contract balance is insufficient for a full refund (rare: requires
    ///         large OG cancellations to drain treasury in pregame), refunds are
    ///         first-come-first-served. The SignupRefund event captures actual vs owed.
    function claimSignupRefund() external nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert SignupNotFailed();
        if (block.timestamp < signupDeadline) revert TooEarly();
        _captureYield();
        bool signupFailed = committedPlayerCount < MIN_PLAYERS_TO_START;
        bool pregameExpired = block.timestamp >= signupDeadline + MAX_PREGAME_DURATION;
        if (!signupFailed && !pregameExpired) revert SignupNotFailed();
        PlayerData storage p = players[msg.sender];
        if (p.totalPaid == 0) revert NothingToClaim();
        if (p.dormancyRefunded) revert AlreadyRefunded();
        uint256 fullAmount = p.totalPaid; uint256 refund = fullAmount;
        uint256 maxDeductible = prizePot + treasuryBalance;
        if (refund > maxDeductible) refund = maxDeductible;
        if (refund == 0) revert NothingToClaim();
        p.dormancyRefunded = true; p.totalPaid = 0;
        if (p.isUpfrontOG || p.isWeeklyOG) { _cleanupOGOnRefund(msg.sender, p); }
        else if (p.commitmentPaid) {
            if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false; if (committedPlayerCount > 0) committedPlayerCount--;
            if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
            p.prediction = 0; p.predictionDraw = 0; p.prediction2 = 0; p.prediction2Draw = 0;
        } else if (ogIntentStatus[msg.sender] == OGIntentStatus.PENDING) {
            // [v1.57-P1] pendingIntentCount deprecated -- intent queue removed.
            ogIntentStatus[msg.sender] = OGIntentStatus.DECLINED; ogIntentAmount[msg.sender] = 0;
            if (committedPlayerCount > 0) committedPlayerCount--;
        }
        // [CRE v1.11a / PG-02] Dead SWEPT block removed (ogIntentStatus never written in v1.57+;
        // it carried a latent double-decrement trap). Intent queue fully retired.
        if (refund <= prizePot) { prizePot -= refund; } else {
            uint256 fromTreasury = refund - prizePot; prizePot = 0;
            if (treasuryBalance >= fromTreasury) { treasuryBalance -= fromTreasury; } else { treasuryBalance = 0; }
        }
        _withdrawAndTransfer(msg.sender, refund);
        emit SignupRefund(msg.sender, refund, fullAmount);
    }

    function _cleanupOGOnRefund(address addr, PlayerData storage p) internal {
        if (p.isUpfrontOG) {
            // NOTE: When called from claimSignupRefund/batchRefundPlayers, p.totalPaid is
            // already 0 (zeroed before this call). upfrontActual = 0, totalOGPrincipal
            // unchanged. Pre-existing behaviour -- harmless in failed-pregame context as
            // no ACTIVE-phase function reads totalOGPrincipal after sweepFailedPregame().
            // [v1.57-P1] ogIntentCreditAmount deprecated -- always 0 in new design.
            uint256 upfrontActual = p.totalPaid;
            if (totalOGPrincipal >= upfrontActual) totalOGPrincipal -= upfrontActual; else totalOGPrincipal = 0;
            p.isUpfrontOG = false; p.prediction = 0; p.prediction2 = 0; p.predictionDraw = 0; p.prediction2Draw = 0;
            if (upfrontOGCount > 0) upfrontOGCount--;
        } else if (p.isWeeklyOG) {
            uint256 weeklyOGCost = TICKET_PRICE * MIN_TICKETS_WEEKLY_OG;
            if (totalOGPrincipal >= weeklyOGCost) totalOGPrincipal -= weeklyOGCost; else totalOGPrincipal = 0;
            p.isWeeklyOG = false; p.prediction = 0; p.prediction2 = 0; p.predictionDraw = 0; p.prediction2Draw = 0; p.lastBoughtDraw = 0;
            p.consecutiveWeeks = 0; p.lastActiveWeek = 0; p.firstPlayedDraw = 0;
            if (weeklyOGCount > 0) weeklyOGCount--;
            if (earnedOGCount > 0) earnedOGCount--;
            uint256 netToSubtract = p.pregameOGNetContributed; p.pregameOGNetContributed = 0;
            if (pregameWeeklyOGTicketTotal >= weeklyOGCost) pregameWeeklyOGTicketTotal -= weeklyOGCost; else pregameWeeklyOGTicketTotal = 0;
            if (pregameWeeklyOGNetTotal >= netToSubtract) pregameWeeklyOGNetTotal -= netToSubtract; else pregameWeeklyOGNetTotal = 0;
        }
        if (p.commitmentPaid) {
            if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false;
            if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
        }
        // [v1.57-P1] Clear decline window and cancel refund amount on failed-pregame refund.
        if (ogDeclineWindowExpiry[addr] != 0) ogDeclineWindowExpiry[addr] = 0;
        if (ogCancelRefund[addr] != 0) ogCancelRefund[addr] = 0;
        // Legacy intent queue cleanup (deprecated state -- safe no-ops)
        if (ogIntentStatus[addr] == OGIntentStatus.OFFERED) {
            ogIntentStatus[addr] = OGIntentStatus.DECLINED; ogIntentAmount[addr] = 0;
            ogIntentWindowExpiry[addr] = 0;
        }
        // [CRE v1.11a / PG-02] Dead SWEPT else-if removed (unreachable, intent queue retired).
        uint256 ogLen = ogList.length;
        if (ogLen > 0 && ogListIndex[addr] < ogLen && ogList[ogListIndex[addr]] == addr) {
            uint256 idx = ogListIndex[addr]; address last = ogList[ogLen - 1];
            ogList[idx] = last; ogListIndex[last] = idx; ogList.pop(); delete ogListIndex[addr];
        }
        if (committedPlayerCount > 0) committedPlayerCount--;
    }

    /// @notice Removes stale weekly OGs from ogList. Callable by owner, automationForwarder, or
    ///         creForwarder [CRE v1.0], and reachable via onReport (ACTION_PRUNE = 4).
    /// @dev [v1.54] M-02 FIX: accessible to automationForwarder as well as owner.
    ///      Stale OGs each consume one slot of the MAX_MATCH_PER_TX budget per batch
    ///      without producing match results -- reducing effective throughput per call.
    ///      Keepers must call this regularly (every draw cycle) to prevent throughput degradation.
    ///      Risk: if stale OG count approaches MAX_MATCH_PER_TX (500), draws stall.
    /// @param maxPrune  Maximum number of stale OGs to remove in this call. Must be <= MAX_LAPSE_BATCH (500).
    function pruneStaleOGs(uint256 maxPrune) public {
    // [v2.34 C-01] public not external: performUpkeep() calls this internally (JUMP).
    // external would be a compile error. IMPORTANT: do NOT add nonReentrant to this
    // function. performUpkeep() holds the reentrancy guard when it calls in (action 3);
    // the internal JUMP shares guard state, so nonReentrant here would revert every
    // automation action 3 call. The function makes no external calls so nonReentrant
    // is unnecessary. [v2.35 I-1]
        if (msg.sender != owner() && msg.sender != automationForwarder && msg.sender != creForwarder) revert OwnableUnauthorizedAccount(msg.sender); // [CRE v1.0] auth site 5/5
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (maxPrune > MAX_LAPSE_BATCH) revert ExceedsLimit();
        uint256 pruned = 0; uint256 i = 0;
        while (i < ogList.length && pruned < maxPrune) {
            address addr = ogList[i]; PlayerData storage p = players[addr];
            if (p.isWeeklyOG && p.weeklyOGStatusLost) {
                uint256 last = ogList.length - 1; address tail = ogList[last];
                ogList[i] = tail; ogListIndex[tail] = i; ogList.pop(); delete ogListIndex[addr];
                p.isWeeklyOG = false; p.prediction = 0; p.prediction2 = 0;
                p.predictionDraw = 0; p.prediction2Draw = 0; // [v2.08] consistency across all cleanup paths
                p.weeklyOGStatusLost = false; p.statusLostAtDraw = 0;
                pruned++;
            } else { i++; }
        }
        emit StaleOGsPruned(pruned, ogList.length);
    }


    // ── Ticket buying ─────────────────────────────────────────────────────────

    /// @notice Buys 1 or 2 tickets for the current draw. ACTIVE phase only.
    /// @dev [v2.15] Treasury rate is flat TREASURY_BPS on all draws. [CRE v0.1] TREASURY_BPS = 2500 (25%).
    ///      Commitment credit applied at the same flat rate -- no rate asymmetry.
    /// @param ticketCount  Number of tickets to buy (1 or 2). Weekly OGs must buy 2.
    function buyTickets(uint256 ticketCount) external nonReentrant {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp > lastDrawTimestamp + PICK_DEADLINE) revert PicksLocked();
        PlayerData storage p = players[msg.sender];
        if (!p.registered) revert NotRegistered();
        if (p.isUpfrontOG) revert AlreadyOG();
        if (p.lastBoughtDraw == currentDraw) revert AlreadyBoughtThisWeek();
        if (ticketCount == 0 || ticketCount > MAX_TICKETS_PER_WEEK) revert ExceedsLimit();
        if (p.isWeeklyOG && !p.weeklyOGStatusLost && ticketCount < MIN_TICKETS_WEEKLY_OG) revert MinimumTicketsRequired();
        uint256 cost;
        bool isActiveWeeklyOG = p.isWeeklyOG && !p.weeklyOGStatusLost;
        cost = TICKET_PRICE * ticketCount; // [v1.54] L-04: exhale pricing removed (equal to TICKET_PRICE in 30-draw Base fork)
        if (p.commitmentPaid && currentDraw > 1 && commitmentRefundPool == 0) {
            bool wasDouble = p.commitmentDouble;
            if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false; if (committedPlayerCount > 0) committedPlayerCount--;
            if (wasDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
            emit CommitmentCreditExpired(msg.sender, wasDouble ? TICKET_PRICE * 2 : TICKET_PRICE);
        }
        if (currentDraw > 1 && p.commitmentDouble && !p.commitmentPaid) {
            p.commitmentDouble = false;
            if (committedDoubleCount > 0) committedDoubleCount--;
            emit CommitmentDoubleUnused(msg.sender, TICKET_PRICE);
        }
        bool usingCommitment = p.commitmentPaid && currentDraw == 1;
        bool commitmentCreditHandled = false; // [v1.91] renamed from usingDoubleCredit -- true for both single and double credit paths
        uint256 creditAmount = usingCommitment ? (p.commitmentDouble && ticketCount == 2 ? TICKET_PRICE * 2 : TICKET_PRICE) : 0;
        uint256 transferAmount = cost > creditAmount ? cost - creditAmount : 0;
        if (transferAmount > 0) {
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), transferAmount);
        }
        if (usingCommitment) {
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            // [v1.2 M-01] Decrement here, before p.commitmentPaid = false.
            // The post-transfer check at isFirstBuy (below) tests p.commitmentPaid which
            // is already false by then -- so this is the only path that fires for commitment
            // players buying draw-1 tickets. Fixes neverPlayedCommitmentCount never
            // decrementing via buyTickets, which inflated dormancyCommitmentPool sizing.
            if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            p.commitmentPaid = false;
            if (committedPlayerCount > 0) committedPlayerCount--;
            if (p.commitmentDouble && ticketCount == 2) {
                p.commitmentDouble = false;
                if (committedDoubleCount > 0) committedDoubleCount--;
                // [v2.15] Flat rate: pregame commitment (25%) and draw tickets (25%) match exactly [CRE v0.6 NS].
                // No rate asymmetry -- reset pool sizing is precise.
                uint256 pregameNet2x = TICKET_PRICE * 2 * (10000 - TREASURY_BPS) / 10000;
                currentDrawTicketTotal += TICKET_PRICE * 2;
                currentDrawNetTicketTotal += pregameNet2x;
                currentDrawCasualNetTicketTotal += pregameNet2x;
                commitmentCreditHandled = true; // prevents bottom else-if from double-adding
            } else {
                // [v1.86] Single credit. credit net -> netTicketTotal. Full cost net ->
                // casualNetTicketTotal so 2-ticket single-credit buyers get the correct
                // dormancy pool share (credit portion + transfer portion both included).
                // [v2.15] Flat rate: TREASURY_BPS (25%) on both pregame and active draws [CRE v0.6 NS].
                // [v2.35 I-03] NOTE: p.commitmentDouble and committedDoubleCount are NOT
                // cleared here. Cleanup is deferred to the CommitmentDoubleUnused block on
                // the player's next buy (draw 2+). If dormancy activates before draw 2,
                // activateDormancy()'s safeDoubleCount_ can overcount singles as doubles,
                // over-reserving dormancyCommitmentPool (~$17 vs ~$8.50 per affected player).
                // Over-reserve direction only -- surplus swept by sweepDormancyRemainder().
                uint256 creditNet = TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
                uint256 fullCostNet = cost * (10000 - TREASURY_BPS) / 10000;
                currentDrawTicketTotal += TICKET_PRICE;
                currentDrawNetTicketTotal += creditNet;      // credit portion only (transfer block adds its share)
                currentDrawCasualNetTicketTotal += fullCostNet; // full net matches dormancy claim
                commitmentCreditHandled = true; // guards bottom else-if from double-adding
            }
        }
        if (transferAmount > 0) {
            uint256 tSlice = transferAmount * TREASURY_BPS / 10000;
            treasuryBalance += tSlice; prizePot += transferAmount - tSlice; p.totalPaid += transferAmount;
            emit TreasuryAccrual(currentDraw, tSlice, TREASURY_BPS);
            // [CRE v0.1 / SmartEarn] Track season treasury and emit live tier-crossing events.
            // [CRE v0.4 / SE-M-01] At crossing: move bonus from treasuryBalance to vcBonusEscrow immediately.
            // Escrow is a separate allocation — owner cannot withdraw it via withdrawTreasury().
            // Tier 2 moves only the delta above tier 1 (exclusive tiers, highest wins).
            uint256 _prevCT = cumulativeSeasonTreasury;
            cumulativeSeasonTreasury += tSlice;
            if (VC_BONUS_TIER1_THRESHOLD > 0
                    && _prevCT < VC_BONUS_TIER1_THRESHOLD
                    && cumulativeSeasonTreasury >= VC_BONUS_TIER1_THRESHOLD) {
                uint256 _t1Escrow = VC_BONUS_TIER1_AMOUNT <= treasuryBalance ? VC_BONUS_TIER1_AMOUNT : treasuryBalance;
                if (_t1Escrow > 0) { treasuryBalance -= _t1Escrow; vcBonusEscrow += _t1Escrow; }
                emit VCBonusTierReached(1, VC_BONUS_TIER1_THRESHOLD, VC_BONUS_TIER1_AMOUNT, cumulativeSeasonTreasury);
            }
            if (VC_BONUS_TIER2_THRESHOLD > 0
                    && _prevCT < VC_BONUS_TIER2_THRESHOLD
                    && cumulativeSeasonTreasury >= VC_BONUS_TIER2_THRESHOLD) {
                // Delta: tier2 total minus what tier1 already escrowed.
                uint256 _t2Delta = VC_BONUS_TIER2_AMOUNT > vcBonusEscrow ? VC_BONUS_TIER2_AMOUNT - vcBonusEscrow : 0;
                uint256 _t2Escrow = _t2Delta <= treasuryBalance ? _t2Delta : treasuryBalance;
                if (_t2Escrow > 0) { treasuryBalance -= _t2Escrow; vcBonusEscrow += _t2Escrow; }
                emit VCBonusTierReached(2, VC_BONUS_TIER2_THRESHOLD, VC_BONUS_TIER2_AMOUNT, cumulativeSeasonTreasury);
            }
            currentDrawTicketTotal += transferAmount;
            currentDrawNetTicketTotal += transferAmount - tSlice;
        }
        bool isFirstBuy = (p.lastBoughtDraw == 0);
        if (isFirstBuy && p.commitmentPaid && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
        bool isStatusLostOGFirstCasualBuy = p.isWeeklyOG && p.weeklyOGStatusLost && p.statusLostAtDraw > 0 && p.lastBoughtDraw < p.statusLostAtDraw;
        if (resetDrawRefundDraw != 0 && p.lastBoughtDraw == resetDrawRefundDraw && p.resetRefundClaimedAtDraw != resetDrawRefundDraw) {
            p.lastResetBoughtDraw1 = p.lastBoughtDraw; p.lastResetTicketCost1 = p.lastTicketCost;
        } else if (resetDrawRefundDraw2 != 0 && p.lastBoughtDraw == resetDrawRefundDraw2 && p.resetRefundClaimedAtDraw2 != resetDrawRefundDraw2) {
            p.lastResetBoughtDraw2 = p.lastBoughtDraw; p.lastResetTicketCost2 = p.lastTicketCost;
        }
        p.lastBoughtDraw = currentDraw; p.lastTicketCount = ticketCount; p.lastTicketCost = cost;
        if (!p.isWeeklyOG || p.weeklyOGStatusLost) {
            if (p.isLapsed) {
                uint256 ogSlotsTakenL = upfrontOGCount + weeklyOGCount;
                uint256 buyerCapL = MAX_PLAYERS > ogSlotsTakenL ? MAX_PLAYERS - ogSlotsTakenL : 0;
                uint256 activeBuyersL = totalLifetimeBuyers > lapsedPlayerCount ? totalLifetimeBuyers - lapsedPlayerCount : 0;
                if (activeBuyersL >= buyerCapL) revert MaxPlayersReached();
                p.isLapsed = false; if (lapsedPlayerCount > 0) lapsedPlayerCount--;
                emit PlayerUnlapsed(msg.sender, currentDraw);
            }
            if (isFirstBuy || isStatusLostOGFirstCasualBuy) {
                uint256 ogSlotsTaken = upfrontOGCount + weeklyOGCount;
                uint256 buyerCap = MAX_PLAYERS > ogSlotsTaken ? MAX_PLAYERS - ogSlotsTaken : 0;
                uint256 activeBuyers = totalLifetimeBuyers > lapsedPlayerCount ? totalLifetimeBuyers - lapsedPlayerCount : 0;
                if (activeBuyers >= buyerCap) revert MaxPlayersReached();
                totalLifetimeBuyers++;
            }
            weeklyNonOGPlayers.push(msg.sender);
        }
        if (isActiveWeeklyOG) {
            totalOGPrincipal += cost;
            // [CRE v0.4 / DR-M-01] Track weekly OG current-draw net for dormancy casual pool sizing.
            // At dormancy, weekly OGs claim from the casual pool (current draw only).
            currentDrawWeeklyOGNetTicketTotal += cost * (10000 - TREASURY_BPS) / 10000;
            // [CRE v0.7 / M-01] Count this weekly OG as a current-draw buyer (claimable head).
            // The AlreadyBoughtThisWeek guard ensures one increment per draw per player.
            currentDrawWeeklyOGBuyerCount++;
        }
        // commitmentCreditHandled=true when any commitment credit was processed above (single or double).
        // Guards against re-adding the full casual net -- already tallied correctly in the credit block.
        else if (!commitmentCreditHandled) { currentDrawCasualNetTicketTotal += cost * (10000 - TREASURY_BPS) / 10000; }
        _updateStreakTracking(msg.sender);
        emit TicketsBought(msg.sender, currentDraw, ticketCount);
    }

    /// @notice Submits or updates the first prediction for the current draw.
    /// @param prediction  ETH/USD price prediction in USD cents.
    function submitPrediction(uint256 prediction) external {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp > lastDrawTimestamp + PICK_DEADLINE) revert PicksLocked();
        PlayerData storage p = players[msg.sender];
        bool isOG = p.isUpfrontOG || (p.isWeeklyOG && !p.weeklyOGStatusLost);
        bool hasBoughtThisDraw = p.lastBoughtDraw == currentDraw;
        if (!isOG && !hasBoughtThisDraw) revert NotEligible();
        _validatePrediction(prediction);
        p.prediction = prediction; p.predictionDraw = currentDraw;
        emit PredictionSubmitted(msg.sender, prediction, currentDraw);
    }

    /// @notice Submits or updates the second prediction for the current draw
///         (OGs and players who bought 2 tickets this draw). [v2.35 NS-L-02]
///         After v2.34 M-01, 2-ticket casuals who do not call this function receive
///         an auto-default second entry at matching time. Frontends should surface
///         this function to all lastTicketCount>=2 players, not OGs only.
    /// @param prediction2  Second ETH/USD price prediction in USD cents.
    function submitPrediction2(uint256 prediction2) external {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp > lastDrawTimestamp + PICK_DEADLINE) revert PicksLocked();
        PlayerData storage p = players[msg.sender];
        bool isOG = p.isUpfrontOG || (p.isWeeklyOG && !p.weeklyOGStatusLost);
        bool bought2ThisDraw = p.lastBoughtDraw == currentDraw && p.lastTicketCount >= 2;
        if (!isOG && !bought2ThisDraw) revert NotEligible();
        _validatePrediction(prediction2);
        p.prediction2 = prediction2; p.prediction2Draw = currentDraw;
        emit Prediction2Submitted(msg.sender, prediction2, currentDraw);
    }

    // ── Draw resolution & cutoff submission ───────────────────────────────────

    /// @notice Resolves ETH price and transitions to CUTOFF_SUBMISSION.
    /// @dev    [v1.0] FLOW CHANGE: transitions to CUTOFF_SUBMISSION not MATCHING.
    ///         Keeper must call submitCutoffDiffs() before processMatches() can run.
    ///         snapshotTotalEntries captured here for verification.
    ///         tier1-4Band computation removed. Dynamic cutoffs replace fixed bands.
    function resolveWeek() external nonReentrant {
        _resolveWeekCore();
    }

    /// @dev [CRE v1.0] Verbatim v0.14 resolveWeek() body. Called by the external
    ///      wrapper (permissionless, nonReentrant) and by onReport (nonReentrant).
    function _resolveWeekCore() internal {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp < lastDrawTimestamp + DRAW_COOLDOWN) revert CooldownActive();
        if (currentDraw > TOTAL_DRAWS) revert GameAlreadyClosed();
        uint256 totalOGs = upfrontOGCount + weeklyOGCount;
        if (weeklyNonOGPlayers.length == 0 && totalOGs == 0) revert NotEnoughPlayers();
        _checkSequencer();
        _captureYieldAndCheck();
        int256 currentPrice = _readEthPrice();
        if (currentPrice > 0) { lastValidPrice = currentPrice; }
        else {
            if (ethReserveFeed != address(0)) {
                int256 rPrice = _readPriceFeed(ethReserveFeed);
                if (rPrice > 0) { currentPrice = rPrice; lastValidPrice = rPrice; emit ReserveFeedUsed(ethReserveFeed, currentDraw); }
            }
            if (currentPrice == 0 && wethFeed != address(0)) {
                int256 wPrice = _readPriceFeed(wethFeed);
                if (wPrice > 0) { currentPrice = wPrice; lastValidPrice = wPrice; emit ReserveFeedUsed(wethFeed, currentDraw); }
            }
            if (currentPrice == 0 && lastValidPrice > 0) { emit FeedStaleFallback(); currentPrice = lastValidPrice; }
            if (currentPrice == 0) revert NotEnoughValidPrices();
        }
        // [v1.77] autoDefaultCents uses the PREVIOUS draw's resolvedPrice (one-draw lag).
        // Intentional: the last resolved price is the best on-chain reference at draw start.
        if (resolvedPrice > 0) {
            uint256 snap = uint256(resolvedPrice) / PREDICTION_SCALE;
            if (snap > 0 && snap <= MAX_PREDICTION_CENTS) autoDefaultCents = snap;
        }
        resolvedPrice = currentPrice;
        lastResolvedDraw = currentDraw;
        if (resolvedPrice <= 0) revert NotEnoughValidPrices();
        // [v1.0] No tier band computation -- dynamic cutoffs submitted in CUTOFF_SUBMISSION phase.
        _calculatePrizePools();
        // [v1.58-P3] _lockOGObligation call removed -- obligation locked at startGame().
        //            OG_OBLIGATION_LOCK_DRAW retained as a deprecated constant for ABI compat.
        // [v1.1] Snapshot approximate entry count for cutoff range verification.
        // ogList.length*2 (OGs always 2 entries) + weeklyNonOGPlayers.length (casuals 1+).
        // NOTE: undercounts actual entries when casuals hold 2 tickets -- each casual = 1
        // in snapshot but generates 2 entries in _matchAndCategorize. This makes computed
        // BPS read HIGHER than actual percentages. MAX bounds are the binding risk.
        // Wide bounds absorb full 2-ticket adoption and OG status-loss variance.
        snapshotTotalEntries = ogList.length * 2 + weeklyNonOGPlayers.length;
        // [v1.0] Transition to CUTOFF_SUBMISSION, not MATCHING.
        drawPhase = DrawPhase.CUTOFF_SUBMISSION; phaseStartTimestamp = block.timestamp;
        matchOGIndex = 0; matchNonOGIndex = 0; ogMatchingDone = false; currentTierPerWinner = 0;
        t1CutoffDiff = 0; t2CutoffDiff = 0; t3CutoffDiff = 0;
        // [v1.0] Assembly clears: p4Winners.slot REMOVED (p4Winners does not exist).
        assembly { sstore(jpWinners.slot, 0) sstore(p2Winners.slot, 0) sstore(p3Winners.slot, 0) }
        emit DrawResolved(currentDraw, currentPrice);
    }

    /// @notice Keeper submits cutoff diff values defining prize tier boundaries.
    /// @dev    [v1.1] Called in CUTOFF_SUBMISSION phase by owner, automationForwarder, or
    ///         creForwarder [CRE v1.0], and reachable via onReport (ACTION_SUBMIT_CUTOFFS = 1).
    ///         Keeper reads all on-chain predictions, computes diffs against resolvedPrice,
    ///         sorts, finds diff values at 1%, ~6%, and ~12-15% thresholds (draw-schedule dependent) with tie handling.
    ///
    ///         CUTOFF SEMANTICS:
    ///           t1CutoffDiff: diff <= this = T1 (1% Club) winners.
    ///           t2CutoffDiff: diff <= this but > t1CutoffDiff = T2 winners.
    ///           t3CutoffDiff: diff <= this but > t2CutoffDiff = T3 winners.
    ///           Ties at boundary: all entries at exactly boundary diff included.
    ///
    ///         COUNT SEMANTICS (cumulative):
    ///           _t1Count: entries with diff <= t1CutoffDiff (~1% of entries).
    ///           _t2Count: entries with diff <= t2CutoffDiff (~6%, T1+T2 combined).
    ///           _t3Count: entries with diff <= t3CutoffDiff (~12-15% cumulative, draw-schedule dependent).
    ///           All three verified against snapshotTotalEntries within BPS bounds.
    ///           t1Count <= t2Count <= t3Count required (counts are cumulative).
    ///
    ///         STUCK GAME: if not submitted within DRAW_STUCK_TIMEOUT (48h),
    ///         emergencyResetDraw() available to owner.
    ///
    /// @param _t1CutoffDiff  Diff threshold for T1 (1% Club) top boundary.
    /// @param _t2CutoffDiff  Diff threshold for T2 top boundary (T1+T2 combined ~6%).
    /// @param _t3CutoffDiff  Diff threshold for T3 top boundary (all winners ~12-15%, draw-schedule dependent).
    /// @param _t1Count       Cumulative entries with diff <= _t1CutoffDiff.
    /// @param _t2Count       Cumulative entries with diff <= _t2CutoffDiff (includes T1).
    /// @param _t3Count       Cumulative entries with diff <= _t3CutoffDiff (includes T1+T2).
    function submitCutoffDiffs(
        uint256 _t1CutoffDiff,
        uint256 _t2CutoffDiff,
        uint256 _t3CutoffDiff,
        uint256 _t1Count,
        uint256 _t2Count,
        uint256 _t3Count
    ) external nonReentrant {
        if (msg.sender != owner() && msg.sender != automationForwarder && msg.sender != creForwarder)
            revert OwnableUnauthorizedAccount(msg.sender); // [CRE v1.0] auth site 1/5
        _submitCutoffDiffsCore(_t1CutoffDiff, _t2CutoffDiff, _t3CutoffDiff, _t1Count, _t2Count, _t3Count);
    }

    /// @dev [CRE v1.0] Verbatim v0.14 submitCutoffDiffs() body minus the auth line.
    function _submitCutoffDiffsCore(
        uint256 _t1CutoffDiff,
        uint256 _t2CutoffDiff,
        uint256 _t3CutoffDiff,
        uint256 _t1Count,
        uint256 _t2Count,
        uint256 _t3Count
    ) internal {
        if (drawPhase != DrawPhase.CUTOFF_SUBMISSION) revert WrongPhase();
        // Ordering: diffs narrowest to widest, counts non-decreasing (cumulative).
        if (_t1CutoffDiff > _t2CutoffDiff || _t2CutoffDiff > _t3CutoffDiff) revert InvalidCutoffOrder();
        if (_t1Count > _t2Count || _t2Count > _t3Count) revert InvalidCutoffOrder();
        // [v1.78] Belt-and-suspenders: revert if no entries -- range checks would divide by zero.
        if (snapshotTotalEntries == 0) revert NotEnoughPlayers();
        // Range verification against snapshotTotalEntries.
        {
            uint256 t1Bps = _t1Count * 10000 / snapshotTotalEntries;
            uint256 t2Bps = _t2Count * 10000 / snapshotTotalEntries;
            uint256 t3Bps = _t3Count * 10000 / snapshotTotalEntries;
            if (t1Bps < T1_COUNT_MIN_BPS || t1Bps > T1_COUNT_MAX_BPS) revert CutoffOutOfRange();
            if (t2Bps < T2_COUNT_MIN_BPS || t2Bps > T2_COUNT_MAX_BPS) revert CutoffOutOfRange();
            if (t3Bps < T3_COUNT_MIN_BPS || t3Bps > T3_COUNT_MAX_BPS) revert CutoffOutOfRange();
        }
        t1CutoffDiff = _t1CutoffDiff;
        t2CutoffDiff = _t2CutoffDiff;
        t3CutoffDiff = _t3CutoffDiff;
        drawPhase = DrawPhase.MATCHING; phaseStartTimestamp = block.timestamp;
        emit CutoffDiffsSubmitted(currentDraw, _t1CutoffDiff, _t2CutoffDiff, _t3CutoffDiff, _t1Count, _t2Count, _t3Count);
    }

    /// @notice Runs the prize matching pass for the current draw. Callable by keeper or owner.
    function processMatches() external nonReentrant {
        if (drawPhase != DrawPhase.MATCHING) revert WrongPhase();
        _processMatchesCore();
    }

    function _processMatchesCore() internal {
        uint256 processed;
        uint256 autoDefault = _autoDefaultPrediction();
        if (!ogMatchingDone) {
            uint256 ogTotal = ogList.length;
            while (matchOGIndex < ogTotal && processed < MAX_MATCH_PER_TX) {
                address addr = ogList[matchOGIndex]; PlayerData storage p = players[addr];
                if (p.isWeeklyOG && !p.weeklyOGStatusLost) {
                    if (p.lastBoughtDraw != currentDraw) {
                        // [v1.3] No mulligan. Miss = status lost immediately.
                        // 72-hour windows over 90 days: a missed window is a
                        // genuine signal of disengagement, not bad luck.
                        // Also removes mulligan double-penalty on mismatch recovery.
                        // p.totalPaid = cumulative principal across all draws (incremented by cost each draw).
                        if (totalOGPrincipal >= p.totalPaid) totalOGPrincipal -= p.totalPaid; else totalOGPrincipal = 0;
                        p.weeklyOGStatusLost = true; p.statusLostAtDraw = currentDraw;
                        p.prediction = 0; p.prediction2 = 0; p.predictionDraw = 0; p.prediction2Draw = 0;
                        if (weeklyOGCount > 0) weeklyOGCount--;
                        if (earnedOGCount > 0) earnedOGCount--;
                        if (p.consecutiveWeeks >= WEEKLY_OG_QUALIFICATION_WEEKS && qualifiedWeeklyOGCount > 0) { qualifiedWeeklyOGCount--; }
                        emit WeeklyOGStatusLost(addr, currentDraw);
                        matchOGIndex++; processed++; continue;
                    }
                }
                bool isActive = p.isUpfrontOG || (p.isWeeklyOG && !p.weeklyOGStatusLost);
                if (isActive) {
                    bool predictionFresh = (p.predictionDraw == currentDraw);
                    uint256 effectivePrediction;
                    if (predictionFresh && p.prediction != 0) { effectivePrediction = p.prediction; }
                    else { effectivePrediction = autoDefault; p.prediction = autoDefault; p.predictionDraw = currentDraw; emit AutoPredictionApplied(addr, currentDraw, autoDefault); }
                    _matchAndCategorize(addr, effectivePrediction);
                    bool prediction2Fresh = (p.prediction2Draw == currentDraw);
                    uint256 effectivePrediction2;
                    if (prediction2Fresh && p.prediction2 != 0) { effectivePrediction2 = p.prediction2; }
                    else { effectivePrediction2 = autoDefault; p.prediction2 = autoDefault; p.prediction2Draw = currentDraw; emit AutoPrediction2Applied(addr, currentDraw, autoDefault); }
                    _matchAndCategorize(addr, effectivePrediction2);
                }
                matchOGIndex++; processed++;
            }
            if (matchOGIndex >= ogTotal) ogMatchingDone = true;
        }
        if (ogMatchingDone) {
            uint256 nonOGTotal = weeklyNonOGPlayers.length;
            while (matchNonOGIndex < nonOGTotal && processed < MAX_MATCH_PER_TX) {
                address addr = weeklyNonOGPlayers[matchNonOGIndex]; PlayerData storage p = players[addr];
                uint256 casualPrediction;
                if (p.predictionDraw == currentDraw && p.prediction != 0) { casualPrediction = p.prediction; }
                else { casualPrediction = autoDefault; p.prediction = autoDefault; p.predictionDraw = currentDraw; emit AutoPredictionApplied(addr, currentDraw, autoDefault); }
                _matchAndCategorize(addr, casualPrediction);
                if (p.lastTicketCount >= 2) {
                    // [v2.34 M-01] Always give 2-ticket casuals a second entry.
                    // Auto-default if prediction2 not submitted (mirrors OG path).
                    uint256 effective2;
                    if (p.prediction2Draw == currentDraw && p.prediction2 != 0) {
                        effective2 = p.prediction2;
                    } else {
                        effective2 = autoDefault;
                        p.prediction2 = autoDefault;
                        p.prediction2Draw = currentDraw;
                        emit AutoPrediction2Applied(addr, currentDraw, effective2);
                    }
                    _matchAndCategorize(addr, effective2);
                }
                matchNonOGIndex++; processed++;
            }
            if (matchNonOGIndex >= nonOGTotal) {
                // [v1.2 H-01] Post-match count reconciliation.
                // Verify actual winner array sizes against the same BPS bounds used in
                // submitCutoffDiffs(). Catches keeper submitting honest counts but
                // dishonest diffs (e.g. t1CutoffDiff set to capture 10% not 1%).
                // Counts are cumulative: t1Actual = T1 only, t12Actual = T1+T2, t123Actual = all.
                // If mismatch: clear winner arrays and revert to CUTOFF_SUBMISSION.
                //   tierPools are PRESERVED for the corrected resubmission pass.
                //   Returning them to prizePot would leave zero funds to pay prizes.
                // NOTE: OG status changes (status-lost) from this match pass
                // are not reversed here. emergencyResetDraw() available if required.
                if (snapshotTotalEntries > 0) {
                    uint256 t1Actual   = jpWinners.length;
                    uint256 t12Actual  = jpWinners.length + p2Winners.length;
                    uint256 t123Actual = jpWinners.length + p2Winners.length + p3Winners.length;
                    uint256 a1Bps  = t1Actual   * 10000 / snapshotTotalEntries;
                    uint256 a12Bps = t12Actual  * 10000 / snapshotTotalEntries;
                    uint256 a123Bps= t123Actual * 10000 / snapshotTotalEntries;
                    bool mismatch = (a1Bps  < T1_COUNT_MIN_BPS || a1Bps  > T1_COUNT_MAX_BPS)
                                 || (a12Bps < T2_COUNT_MIN_BPS || a12Bps > T2_COUNT_MAX_BPS)
                                 || (a123Bps< T3_COUNT_MIN_BPS || a123Bps> T3_COUNT_MAX_BPS);
                    if (mismatch) {
                        emit MatchCountMismatch(currentDraw, t1Actual, t12Actual, t123Actual, snapshotTotalEntries);
                        // Reset cutoffs and winner state. tierPools and currentDrawSeedReturn
                        // are left intact -- they were correctly calculated in resolveWeek()
                        // and remain allocated for the next matching pass with corrected cutoffs.
                        // Returning them to prizePot would cause the corrected distribution pass
                        // to pay zero prizes.
                        assembly { sstore(jpWinners.slot, 0) sstore(p2Winners.slot, 0) sstore(p3Winners.slot, 0) }
                        t1CutoffDiff = 0; t2CutoffDiff = 0; t3CutoffDiff = 0;
                        matchOGIndex = 0; matchNonOGIndex = 0; ogMatchingDone = false;
                        distTierIndex = 0; distWinnerIndex = 0; currentTierPerWinner = 0;
                        drawPhase = DrawPhase.CUTOFF_SUBMISSION; phaseStartTimestamp = block.timestamp;
                        return;
                    }
                }
                // [CRE v1.09 / T3-FLOOR] Seeded cold-start floor. In the early draws (within the
                // no-withdraw window), if T3 would pay below TICKET_PRICE per winner, release a
                // little unspent VC seed to lift the WHOLE tier curve pro-rata so T3 lands at
                // exactly TICKET_PRICE (T1 and T2 rise in the same proportion, curve shape kept).
                // Fires only: seeded (VC_SEED>0), early (currentDraw <= WITHDRAW_START_DRAW), and
                // on a genuine shortfall (healthy games release nothing). Bounded by unspent seed,
                // the per-draw cap, and prizePot. The seed release is DEFERRED (v1.10): the top-up
                // records it in currentDrawT3FloorTopup here, and _finalizeWeekCore folds it into
                // seedReleased under !isResetFinalize. Deferral is what makes it reset-safe --
                // an emergencyResetDraw in DISTRIBUTING returns tierPools to prizePot, so the seed
                // is un-spent, and finalize then never counts it (mirrors CR-L-01 for the
                // supplement). No reader of seedReleased sits between here and finalize anyway (the
                // DORM-GATE already ran in _calculatePrizePools() and withdrawals are window-blocked
                // in these draws).
                // Solvency: any released seed is covered by the v1.09 reserve (which
                // watches max(releasable-estimate, actual seedReleased)) once the window opens;
                // proven 0 insolvencies across 50k fuzz. See CHANGELOG v1.09.
                if (VC_SEED > 0 && currentDraw <= WITHDRAW_START_DRAW && p3Winners.length > 0) {
                    uint256 _t3Need = p3Winners.length * TICKET_PRICE;
                    if (tierPools[2] < _t3Need) {
                        uint256 _extra = (_t3Need - tierPools[2]) * 10000 / (10000 - JP_BPS - P2_BPS);
                        // [SA-9.2 fix] Subtract THIS draw's pending supplement too: it is in
                        // currentDrawSeedSupplement and not yet folded into seedReleased (that
                        // happens at finalize), so counting only seedReleased would let the
                        // supplement and this top-up jointly release more than VC_SEED.
                        uint256 _releasedSoFar = seedReleased + currentDrawSeedSupplement;
                        uint256 _unspent = VC_SEED > _releasedSoFar ? VC_SEED - _releasedSoFar : 0;
                        uint256 _cap = VC_SEED * MAX_SEED_PER_DRAW_BPS / 10000;
                        if (_extra > _unspent) _extra = _unspent;
                        if (_extra > _cap)     _extra = _cap;
                        if (_extra > prizePot) _extra = prizePot;
                        if (_extra > 0) {
                            prizePot     -= _extra;
                            currentDrawT3FloorTopup = _extra;   // [v1.10] DEFERRED to finalize
                            uint256 _add0 = _extra * JP_BPS / 10000;
                            uint256 _add1 = _extra * P2_BPS / 10000;
                            tierPools[0] += _add0;
                            tierPools[1] += _add1;
                            tierPools[2] += _extra - _add0 - _add1;
                            emit SeedT3FloorTopup(currentDraw, _extra, p3Winners.length);
                        }
                    }
                }
                drawPhase = DrawPhase.DISTRIBUTING; phaseStartTimestamp = block.timestamp;
                distTierIndex = 0; distWinnerIndex = 0;
                uint256 totalWinners = jpWinners.length + p2Winners.length + p3Winners.length;
                emit MatchingComplete(currentDraw, totalWinners); return;
            }
        }
        emit MatchingBatchProcessed(currentDraw, matchOGIndex + matchNonOGIndex, ogList.length + weeklyNonOGPlayers.length);
    }

    // ── Chainlink Automation ──────────────────────────────────────────────────

    /// @dev [v1.54] L-02 FIX: address(0) permitted to DISABLE automation forwarder.
    ///      Use during key compromise recovery -- disables performUpkeep/submitCutoffDiffs
    ///      from the compromised key until a replacement is set. Manual keeper calls still work.
    ///      INCIDENT RUNBOOK [CRE v1.0 / seam L-01]: as of the CRE seam there are TWO delivery
    ///      paths. Revoking keeper access on a compromise now requires zeroing BOTH:
    ///      setAutomationForwarder(address(0)) AND setCreForwarder(address(0)). Zeroing only one
    ///      leaves the other live. After both are zeroed the owner submits cutoffs directly.
    /// @param forwarder  New automation forwarder address. address(0) disables automation.
    function setAutomationForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(this)) revert InvalidAddress();
        if (forwarder == USDC) revert InvalidAddress();                // [v1.55] L-NEW-02
        if (forwarder == PROTOCOL_BENEFICIARY) revert InvalidAddress();  // [v1.55] L-NEW-02
        if (forwarder == SEQUENCER_FEED) revert InvalidAddress();        // [v1.56] all known immutables blocked
        // forwarder == address(0) intentionally allowed -- disables automation.
        automationForwarder = forwarder;
        emit AutomationForwarderSet(forwarder);
    }

    /// @notice Sets the CRE delivery address. Owner only. address(0) disables CRE.
    /// @dev Mirrors setAutomationForwarder's blocklist. Set to the KeystoneForwarder
    ///      (native onReport) or a deployed AutomationReceiver (translation route).
    /// @param forwarder  New CRE delivery address. address(0) disables.
    function setCreForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(this))        revert InvalidAddress();
        if (forwarder == USDC)                 revert InvalidAddress();
        if (forwarder == PROTOCOL_BENEFICIARY) revert InvalidAddress();
        if (forwarder == SEQUENCER_FEED)       revert InvalidAddress();
        // forwarder == address(0) intentionally allowed -- disables CRE.
        creForwarder = forwarder;
        emit CreForwarderSet(forwarder);
    }

    function _applyAutoPredictions(address[] memory players_) internal {
        uint256 autoDefault = _autoDefaultPrediction();
        for (uint256 i = 0; i < players_.length; i++) {
            address addr = players_[i];
            PlayerData storage p = players[addr];
            if (p.lastBoughtDraw != currentDraw) continue;
            if (p.predictionDraw == currentDraw && p.prediction != 0) continue;
            p.prediction = autoDefault; p.predictionDraw = currentDraw;
            emit AutoPredictionApplied(addr, currentDraw, autoDefault);
            if (p.lastTicketCount >= 2 && !(p.prediction2Draw == currentDraw && p.prediction2 != 0)) {
                p.prediction2 = autoDefault; p.prediction2Draw = currentDraw;
                emit AutoPrediction2Applied(addr, currentDraw, autoDefault);
            }
        }
    }

    /// @notice Applies auto-default predictions to a batch of players for the current draw.
    /// @param players_  Array of player addresses to apply auto-default to.
    function applyAutoPicksForDraw(address[] calldata players_) external nonReentrant {
        if (msg.sender != owner() && msg.sender != automationForwarder && msg.sender != creForwarder)
            revert OwnableUnauthorizedAccount(msg.sender); // [CRE v1.0] auth site 3/5
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (players_.length > 500) revert ExceedsLimit();
        _applyAutoPredictions(players_);
    }

    /// @notice Chainlink Automation compatibility. Returns upkeepNeeded and encoded action.
    ///         Action 1: advance draw phase (MATCHING/DISTRIBUTING/FINALIZING/UNWINDING).
    ///         Action 2: apply auto-picks before PICK_DEADLINE.
    ///         Action 3: prune stale OGs (fires when stale count >= STALE_OG_PRUNE_THRESHOLD). [v1.55]
    ///         CUTOFF_SUBMISSION is never returned as upkeepNeeded -- keeper submits diffs directly.
    /// @dev ACTION-2 NOTE: action 2 is a TIMING SIGNAL. Automation passes back abi.encode(uint8(2))
    ///      (32 bytes, no player list). performUpkeep handles this gracefully as a no-op.
    ///      To force-apply auto-picks for specific players, call applyAutoPicksForDraw() directly.
    /// @dev [v1.1] CUTOFF_SUBMISSION phase: returns (false, "") not (true, action1).
    ///      Chainlink Automation cannot advance CUTOFF_SUBMISSION -- calling performUpkeep
    ///      reverts DrawNotProgressing, which would burn LINK on every retry for 48h.
    ///      Keeper detects drawPhase == CUTOFF_SUBMISSION from on-chain state,
    ///      computes cutoff diffs off-chain, calls submitCutoffDiffs() directly.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        if (gamePhase != GamePhase.ACTIVE) return (false, "");
        // [v1.1] L-01 fix: return false for CUTOFF_SUBMISSION -- automation cannot advance this phase.
        if (drawPhase == DrawPhase.CUTOFF_SUBMISSION) return (false, "");
        if (drawPhase != DrawPhase.IDLE) { return (true, abi.encode(uint8(1))); }
        if (block.timestamp >= lastDrawTimestamp + PICK_DEADLINE - AUTO_PICK_BUFFER &&
            block.timestamp <= lastDrawTimestamp + PICK_DEADLINE) {
            return (true, abi.encode(uint8(2)));
        }
        // [v1.55] I-NEW-01: surface stale OG prune need to automation.
        // Stale OGs consume MAX_MATCH_PER_TX slots without contributing to matching.
        // If count exceeds threshold, signal action 3 so automation can trigger pruneStaleOGs().
        if (_countStaleOGsInternal() >= STALE_OG_PRUNE_THRESHOLD) {
            return (true, abi.encode(uint8(3)));
        }
        return (false, "");
    }

    /// @notice Chainlink Automation entry point. Executes the scheduled upkeep action.
    /// @param performData  ABI-encoded uint8 action code from checkUpkeep.
    function performUpkeep(bytes calldata performData) external nonReentrant {
        if (msg.sender != owner() && msg.sender != automationForwarder && msg.sender != creForwarder)
            revert OwnableUnauthorizedAccount(msg.sender); // [CRE v1.0] auth site 4/5
        uint8 action = abi.decode(performData, (uint8));
        if (action != 1 && action != 2 && action != 3) revert UnknownAction(action);
        if (action == 1) {
            if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
            // [v1.0] CUTOFF_SUBMISSION: cannot auto-advance. Keeper must call submitCutoffDiffs().
            if (drawPhase == DrawPhase.CUTOFF_SUBMISSION) revert DrawNotProgressing();
            if (drawPhase == DrawPhase.MATCHING) { _processMatchesCore(); }
            else if (drawPhase == DrawPhase.DISTRIBUTING) { _distributePrizesCore(); }
            else if (drawPhase == DrawPhase.FINALIZING || drawPhase == DrawPhase.RESET_FINALIZING) { _finalizeWeekCore(); }
            else if (drawPhase == DrawPhase.UNWINDING) { _continueUnwind(); }
            else { revert DrawNotProgressing(); }
        } else if (action == 2) {
            // [v1.88] Action 2 is a timing signal. Chainlink Automation passes back
            // abi.encode(uint8(2)) (32 bytes). If performData carries a player list
            // (>=96 bytes), decode and apply it. Otherwise no-op -- the fallback in
            // _processMatchesCore handles unpicked players at matching time.
            // Note: MalformedPerformData error is declared but not used here -- a
            // malformed payload throws a generic ABI decode failure at the EVM level.
            // The error is retained for ABI compatibility only. See error declaration.
            address[] memory players_;
            if (performData.length >= 96) {
                (, players_) = abi.decode(performData, (uint8, address[]));
            }
            if (players_.length > 500) revert ExceedsLimit();
            if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
            if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
            _applyAutoPredictions(players_);
        } else {
            // action == 3: [v1.55] automated prune of stale OGs
            if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
            if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
            pruneStaleOGs(AUTOMATION_PRUNE_BATCH); // [v1.56] smaller batch -- fits within default Automation gas limit
        }
    }

    // ── [CRE v1.0] CRE report delivery ───────────────────────────────────────

    /// @notice Chainlink CRE delivery entry point. Called by the KeystoneForwarder
    ///         after DON signature verification. Routes to INTERNAL cores.
    /// @dev holds nonReentrant; routed targets must not also hold it. pruneStaleOGs
    ///      is public with an auth guard that ACCEPTS creForwarder; the internal call preserves
    ///      msg.sender == creForwarder, which its auth accepts. metadata is unread
    ///      in v1.0 (forwarder gate is the trust root). Unknown action -> UnknownAction.
    /// @param report  abi.encode(uint8 action, bytes payload).
    function onReport(bytes calldata /* metadata */, bytes calldata report) external nonReentrant {
        if (creForwarder == address(0) || msg.sender != creForwarder)
            revert OwnableUnauthorizedAccount(msg.sender);
        (uint8 action, bytes memory payload) = abi.decode(report, (uint8, bytes));
        if (action == ACTION_RESOLVE_WEEK) {
            _resolveWeekCore();
        } else if (action == ACTION_SUBMIT_CUTOFFS) {
            (uint256 d1, uint256 d2, uint256 d3, uint256 c1, uint256 c2, uint256 c3)
                = abi.decode(payload, (uint256, uint256, uint256, uint256, uint256, uint256));
            _submitCutoffDiffsCore(d1, d2, d3, c1, c2, c3);
        } else if (action == ACTION_ADVANCE) {
            if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
            if (drawPhase == DrawPhase.CUTOFF_SUBMISSION) revert DrawNotProgressing();
            if (drawPhase == DrawPhase.MATCHING) { _processMatchesCore(); }
            else if (drawPhase == DrawPhase.DISTRIBUTING) { _distributePrizesCore(); }
            else if (drawPhase == DrawPhase.FINALIZING || drawPhase == DrawPhase.RESET_FINALIZING) { _finalizeWeekCore(); }
            else if (drawPhase == DrawPhase.UNWINDING) { _continueUnwind(); }
            else { revert DrawNotProgressing(); }
        } else if (action == ACTION_AUTO_PICKS) {
            address[] memory players_ = abi.decode(payload, (address[]));
            if (players_.length > 500) revert ExceedsLimit();
            if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
            if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
            _applyAutoPredictions(players_);
        } else if (action == ACTION_PRUNE) {
            uint256 maxPrune = abi.decode(payload, (uint256));
            pruneStaleOGs(maxPrune);
        } else if (action == ACTION_CLOSE_GAME) {
            _closeGameCore();
        } else {
            revert UnknownAction(action);
        }
        emit CreReportProcessed(action, currentDraw);
    }

    // ── Proximity matching ────────────────────────────────────────────────────

    /// @dev [v1.0] CHANGED FROM 1Y GAME. Uses submitted cutoff diffs, not fixed BPS bands.
    ///      T1 (1% Club): diff <= t1CutoffDiff.
    ///      T2:           t1CutoffDiff < diff <= t2CutoffDiff.
    ///      T3:           t2CutoffDiff < diff <= t3CutoffDiff.
    ///      Outside t3CutoffDiff: no prize (outside top ~12-15% depending on draw schedule).
    ///      submitCutoffDiffs() gate (CUTOFF_SUBMISSION phase) ensures cutoffs always set before this runs.
    function _matchAndCategorize(address player, uint256 prediction) internal {
        uint256 predScaled = prediction * PREDICTION_SCALE;
        uint256 actual = uint256(resolvedPrice);
        uint256 diff = predScaled >= actual ? predScaled - actual : actual - predScaled;
        if      (diff <= t1CutoffDiff) jpWinners.push(player);
        else if (diff <= t2CutoffDiff) p2Winners.push(player);
        else if (diff <= t3CutoffDiff) p3Winners.push(player);
        // t3CutoffDiff captures draw-schedule-dependent winner% (see _getT3WinnerBps()):
        // 6% draws 1-2, 7% draw 3, 8% draw 4, 9% draw 5+. Keeper sets per submitCutoffDiffs().
        // Entries outside t3CutoffDiff receive no prize.
    }

    // ── Prize distribution ────────────────────────────────────────────────────

    /// @notice Runs the prize distribution pass for the current draw. Callable by anyone.
    function distributePrizes() external nonReentrant {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.DISTRIBUTING) revert WrongPhase();
        _distributePrizesCore();
    }

    /// @dev [v1.0] CHANGED: loops distTierIndex < 3 (not 4). T4 removed.
    ///      No JPMissRedistributed -- T1 is expected to have winners by keeper design.
    ///      Empty winner array is a safety edge case only (zero entries draw).
    function _distributePrizesCore() internal {
        uint256 credited;
        while (distTierIndex < 3 && credited < MAX_DISTRIBUTE_PER_TX) {
            address[] storage winners = _getWinnersForTier(distTierIndex);
            uint256 pool = tierPools[distTierIndex];
            if (winners.length == 0) {
                // Safety path: should not occur with percentage-based cutoffs.
                // If empty (e.g. zero-entry draw), return pool to prizePot.
                prizePot += pool;
                emit TierSkippedDust(distTierIndex, pool);
                tierPools[distTierIndex] = 0; distTierIndex++; distWinnerIndex = 0; continue;
            }
            uint256 perWinner = pool / winners.length;
            if (perWinner == 0) { currentTierPerWinner = 0; prizePot += pool; emit TierSkippedDust(distTierIndex, pool); tierPools[distTierIndex] = 0; distTierIndex++; distWinnerIndex = 0; continue; }
            if (distWinnerIndex == 0) {
                uint256 dust = pool - (perWinner * winners.length);
                if (dust > 0) { prizePot += dust; tierPools[distTierIndex] -= dust; }
                currentTierPerWinner = perWinner;
            }
            while (distWinnerIndex < winners.length && credited < MAX_DISTRIBUTE_PER_TX) {
                address winner = winners[distWinnerIndex]; PlayerData storage p = players[winner];
                p.unclaimedPrizes += perWinner; p.totalPrizesWon += perWinner; totalUnclaimedPrizes += perWinner;
                emit PrizeDistributed(winner, perWinner, distTierIndex);
                distWinnerIndex++; credited++;
            }
            if (distWinnerIndex >= winners.length) { tierPools[distTierIndex] = 0; distTierIndex++; distWinnerIndex = 0; }
        }
        if (distTierIndex >= 3) {
            prizePot += currentDrawSeedReturn;
            emit SeedReturned(currentDraw, currentDrawSeedReturn);
            currentDrawSeedReturn = 0;
            drawPhase = DrawPhase.FINALIZING; phaseStartTimestamp = block.timestamp;
        }
    }

    /// @notice Finalises the current draw. Advances to the next draw or closes the game.
    function finalizeWeek() external nonReentrant {
        bool isResetFinalize = (drawPhase == DrawPhase.RESET_FINALIZING);
        if (!isResetFinalize && drawPhase != DrawPhase.FINALIZING) revert WrongPhase();
        _finalizeWeekCore();
    }

    function _finalizeWeekCore() internal {
        bool isResetFinalize = (drawPhase == DrawPhase.RESET_FINALIZING);
        // [CRE v0.8 / CR-L-01] Deferred seed-release accounting. The supplement was added
        // to weeklyPool in _calculatePrizePools() but NOT counted as released until here,
        // where the draw is known-good. On a reset (isResetFinalize) this is skipped and the
        // supplement is never counted, so no rollback is needed anywhere. Placed before the
        // currentDrawSeedSupplement clear below and before _finalReturnCalibration() /
        // _snapshotOGObligation(), which read seedReleased to recompute requiredEndPot --
        // they must see the post-increment value for this draw.
        if (!isResetFinalize && currentDrawSeedSupplement > 0) {
            seedReleased += currentDrawSeedSupplement;
        }
        // [CRE v1.10 / T3-FLOOR-DEFER] Same deferral for the T3-floor top-up. On a reset
        // (isResetFinalize) the top-up's tierPools were returned to prizePot, so it is never
        // counted -- keeping seedReleased in sync with the actually-spent seed.
        if (!isResetFinalize && currentDrawT3FloorTopup > 0) {
            seedReleased += currentDrawT3FloorTopup;
        }
        assembly { sstore(weeklyNonOGPlayers.slot, 0) }
        // Reset-finalize: re-anchor schedule so lastDrawTimestamp = block.timestamp.
        // Algebraically: (block.timestamp - draw*cooldown) + draw*cooldown = block.timestamp.
        // Purpose: next draw's DRAW_COOLDOWN starts from reset-finalize time, not from
        // the original draw slot. Prevents immediate re-resolution on the prior timestamp.
        if (isResetFinalize) {
            scheduleAnchor = block.timestamp - currentDraw * DRAW_COOLDOWN;
            // [CRE v0.12 / D5-L-01] Count this voided draw. _finalizeWeekCore() runs with
            // RESET_FINALIZING exactly once per reset (only after the final unwind batch sets
            // the phase), so this increments once per completed reset, not per unwind batch.
            resetDrawCount++;
        }
        lastDrawTimestamp = scheduleAnchor + currentDraw * DRAW_COOLDOWN;
        // [v1.58-P3] breathSeedAccumulator block removed -- avgNetRevenuePerDraw updated by EMA
        //            in _checkAutoAdjust each draw. Obligation locked at draw 1 not draw 10.
        currentDrawTicketTotal = 0; currentDrawNetTicketTotal = 0; currentDrawCasualNetTicketTotal = 0;
        currentDrawWeeklyOGNetTicketTotal = 0; // [CRE v0.4 / DR-M-01] cleared each draw
        currentDrawWeeklyOGBuyerCount = 0;      // [CRE v0.7 / M-01] cleared each draw, paired
        currentDrawBonusContribution = 0; // [v1.68] end-of-draw clear -- see emergencyResetDraw for reset-replay protection
        currentDrawSeedSupplement = 0; // [CRE v0.1] cleared each draw
        currentDrawT3FloorTopup = 0;   // [CRE v1.10] cleared each draw (paired deferral)
        // [v1.0] Reset cutoff state and snapshot after each draw completes.
        t1CutoffDiff = 0; t2CutoffDiff = 0; t3CutoffDiff = 0; snapshotTotalEntries = 0;
        // [v1.58-P3] obligationLocked always true from draw 1. Guard simplified.
        if (currentDraw == BREATH_CALIBRATION_DRAW) { _calibrateBreathTarget(); }
        // [v1.58-P3] obligationLocked always true from draw 1 -- guard is retained
        //            for defensive clarity only. Reset-finalize correctly skipped.
        if (obligationLocked && !isResetFinalize && currentDraw == FINAL_CALIBRATION_DRAW) { _finalReturnCalibration(); }
        // [v1.58-P3] Snapshot every draw -- obligation locked from draw 1.
        if (!isResetFinalize) { _snapshotOGObligation(); }
        // [v1.59] Accumulate OG ratio for season-average return calculation.
        // Skipped on reset-finalize draws (same guard as _snapshotOGObligation).
        // Reset draws must not inflate ogRatioDrawCount or double-count replayed draws.
        // [v1.59] ogCapDenominator is stable (set once at startGame(), never changed).
        // committedPlayerCount decrements to 0 as commitment credits are consumed
        // in buyTickets() -- typically reaching 0 by end of draw 1, which would
        // cause the accumulator to capture only one draw and make the feature a no-op.
        // [v2.30] currentDraw < TOTAL_DRAWS guard: excludes draw 30's ratio from the
        // accumulator so ogRatioDrawCount=29 at closeGame() time, matching the 29-draw
        // figure used by the draw-30 holdback in _calculatePrizePools(). True SSoT.
        // Note: currentDraw++ runs AFTER this accumulator block in _finalizeWeekCore,
        // so during draw 30's finalize currentDraw==30==TOTAL_DRAWS -- guard is false.
        if (!isResetFinalize && ogCapDenominator > 0 && currentDraw < TOTAL_DRAWS) {
            uint256 drawOGRatio = (upfrontOGCount + earnedOGCount) * 10000 / ogCapDenominator;
            ogRatioBpsAccumulator += drawOGRatio;
            ogRatioDrawCount++;
        }
        if (currentDraw >= TOTAL_DRAWS) { gamePhase = GamePhase.CLOSED; }
        emit WeekFinalized(currentDraw);
        currentDraw++; drawPhase = DrawPhase.IDLE;
    }

    /// @notice Permissionless draw step progression.
    /// @dev    [v1.0] CUTOFF_SUBMISSION cannot auto-advance (requires keeper computation).
    ///         Returns DrawNotProgressing for that phase.
    function completeDrawStep() external nonReentrant {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase == DrawPhase.CUTOFF_SUBMISSION) revert DrawNotProgressing();
        if (drawPhase == DrawPhase.MATCHING) { _processMatchesCore(); }
        else if (drawPhase == DrawPhase.DISTRIBUTING) { _distributePrizesCore(); }
        else if (drawPhase == DrawPhase.FINALIZING || drawPhase == DrawPhase.RESET_FINALIZING) { _finalizeWeekCore(); }
        else if (drawPhase == DrawPhase.UNWINDING) { _continueUnwind(); }
        else { revert DrawNotProgressing(); }
    }


    // ── Game close, dormancy, refunds ─────────────────────────────────────────
    // NOTE [v1.57-P2]: closeGame() was changed. maxPerOG now uses targetReturnBps.

    /// @notice Settles the game. Distributes endgame pot to qualified OGs.
    ///         perOGPromised = OG_UPFRONT_COST * avgTargetReturnBps / 10000
    ///         where avgTargetReturnBps is derived from the season-average OG ratio.
    ///         Callable by owner, automationForwarder, or creForwarder [CRE v1.0], and reachable
    ///         via onReport (ACTION_CLOSE_GAME = 5).
    /// @dev [v1.57-P2] OG endgame cap is targetReturnBps% of cost, not full cost.
    ///      Surplus above the cap goes to treasury. Shortfall emits EndgameShortfall.
    /// @dev [v1.59] perOGPromised uses season-average OG ratio across non-reset draws.
    ///      Prevents a late-game ratio spike from retroactively cutting OG returns.
    ///      Reset-finalize draws excluded. Draw 30 also excluded from accumulator
    ///      (v2.30 SSoT guard) -- only draws 1-29 are counted. See the ogRatioDrawCount dev-note.
    ///      NOTE: P3 solvency check targets pot adequacy for draw-1 targetReturnBps only.
    ///      If the OG ratio drops mid-season (fewer OGs stay), avgTargetReturnBps rises
    ///      above the draw-1 value (lower ratio = higher return per P2 curve).
    ///      Extra casual revenue from the ratio drop typically funds the difference,
    ///      but this is not guaranteed by mathematical proof. See deployment documentation.
    ///      Falls back to live ratio if accumulator is zero (should never occur).
    function closeGame() external nonReentrant {
        if (msg.sender != owner() && msg.sender != automationForwarder && msg.sender != creForwarder)
            revert OwnableUnauthorizedAccount(msg.sender); // [CRE v1.0] auth site 2/5 -- M-01 fix
        _closeGameCore();
    }

    /// @dev [CRE v1.0] Verbatim v0.14 closeGame() body minus the auth line.
    ///      Callers: closeGame() wrapper and onReport() ACTION_CLOSE_GAME.
    function _closeGameCore() internal {
        if (gamePhase != GamePhase.CLOSED) revert GameNotClosed();
        if (gameSettled) revert GameAlreadyClosed();
        _captureYield();
        uint256 qualifiedOGs = _countQualifiedOGs();
        uint256 surplusToTreasury; // [v2.05] track actual surplus for GameClosed event
        // [v1.59] Use season-average OG ratio to compute perOGPromised.
        // [v2.30] True single-source-of-truth: ogRatioBpsAccumulator / ogRatioDrawCount here
        // is the same 29-draw figure used for the draw-30 holdback in _calculatePrizePools().
        // ogRatioDrawCount=29 at closeGame() because _finalizeWeekCore() excludes draw 30
        // from the accumulator (currentDraw < TOTAL_DRAWS guard added in v2.30). This is
        // the correct mechanism -- NOT _checkAutoAdjust() which does not update this count.
        // OG ratio is monotonically non-increasing (frozen denominator, falling OG count).
        // Retroactive ratio spike cannot occur -- denominator frozen at startGame().
        // Reset-finalize draws excluded from accumulator (double-counting prevention).
        uint256 avgRatioBps = (ogRatioDrawCount > 0)
            ? ogRatioBpsAccumulator / ogRatioDrawCount
            : (ogCapDenominator > 0
                ? (upfrontOGCount + earnedOGCount) * 10000 / ogCapDenominator
                : 0); // fallback: should never fire -- accumulator starts draw 1
        uint256 avgTargetReturnBps = _computeTargetReturnBps(avgRatioBps);
        uint256 perOGPromised = OG_UPFRONT_COST * avgTargetReturnBps / 10000;
        if (qualifiedOGs > 0) {
            // [v1.57-P2] maxPerOG = targetReturnBps% of OG_UPFRONT_COST.
            // Never pay back more than the targeted return. Surplus to treasury.
            uint256 rawPerOG = prizePot / qualifiedOGs;
            uint256 maxPerOG = perOGPromised; // targetReturnBps% of cost, not full cost
            uint256 dust;
            if (rawPerOG > maxPerOG) {
                endgamePerOG = maxPerOG;
                dust = prizePot - endgamePerOG * qualifiedOGs;
            } else {
                endgamePerOG = rawPerOG;
                if (rawPerOG < perOGPromised) { emit EndgameShortfall(rawPerOG, perOGPromised, (perOGPromised - rawPerOG) * qualifiedOGs); }
                dust = prizePot - endgamePerOG * qualifiedOGs;
            }
            if (dust > 0) { treasuryBalance += dust; surplusToTreasury = dust; }
        } else {
            // qualifiedOGs == 0: no endgame payouts. Entire pot routes to treasury.
            // This is correct -- S08/S09 scenario (all OGs lost status or no OGs).
            // Not a vulnerability. ogEndgameObligation shortfall is emitted for transparency.
            if (ogEndgameObligation > 0) { emit EndgameShortfall(0, perOGPromised, ogEndgameObligation * avgTargetReturnBps / 10000); }
            surplusToTreasury = prizePot;
            treasuryBalance += prizePot;
        }
        endgameOwed = qualifiedOGs > 0 ? endgamePerOG * qualifiedOGs : 0;
        prizePot = 0; gameSettled = true; settlementTimestamp = block.timestamp;

        // [CRE v0.1 / SmartEarn] VC principal return: surplus first, treasury backstop.
        // [CRE v0.6 / INFO-04 / SYNC] LOAD-BEARING PAIR with _calculatePrizePools() draw-30 holdback.
        // The draw-30 holdback keeps _vcUnreleased in prizePot so surplusToTreasury here is large
        // enough to source the VC return. If the holdback formula in _calculatePrizePools() changes
        // without updating this reservation, the VC return silently underfunds. Review both together.
        if (VC_SEED > 0) {
            uint256 _unreleasedSeed = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
            if (_unreleasedSeed > 0) {
                uint256 _fromSurplus = _unreleasedSeed <= surplusToTreasury ? _unreleasedSeed : surplusToTreasury;
                if (_fromSurplus > 0) { treasuryBalance -= _fromSurplus; vcReturnOwed += _fromSurplus; }
                uint256 _shortfall   = _unreleasedSeed - _fromSurplus;
                uint256 _fromTreasury = _shortfall <= treasuryBalance ? _shortfall : treasuryBalance;
                if (_fromTreasury > 0) { treasuryBalance -= _fromTreasury; vcReturnOwed += _fromTreasury; }
            }
            // [CRE v0.4 / SE-M-01] Escrow already moved from treasury at tier crossing.
            // Transfer directly to vcReturnOwed. No treasury deduction needed here.
            // SE-I-04 note: the _fromSurplus/_fromTreasury split above is cosmetic —
            // surplusToTreasury was folded into treasuryBalance before this block,
            // so both branches decrement treasuryBalance. Kept for audit trail continuity.
            if (vcBonusEscrow > 0) { vcReturnOwed += vcBonusEscrow; vcBonusEscrow = 0; }
            // [CRE v1.06 / VC-SPENT-RETURN] Pay the spent-seed obligation (reconstituted principal
            // + 25% return + big-season bonus) from treasury. This is the TRUE amount (no buffer);
            // the withdraw lock's 5% buffer was protocol money and stays in treasury. The
            // constructor VC-SPENT-CAP guard guarantees treasury covers this, but bound to
            // treasuryBalance defensively so close can never revert on an arithmetic underflow.
            uint256 _spentOblig = _vcTreasuryObligation();
            if (_spentOblig > 0) {
                uint256 _fromTre2 = _spentOblig <= treasuryBalance ? _spentOblig : treasuryBalance;
                treasuryBalance -= _fromTre2;
                vcReturnOwed    += _fromTre2;
            }
        }

        emit GameClosed(endgamePerOG, surplusToTreasury, qualifiedOGs);
    }

    // ── [CRE v0.1 / SmartEarn] VC return and seed governance ──────────────────

    /// @notice Claims VC principal return + SmartEarn bonus after settlement. Routes to
    ///         VC_SEED_RETURN_ADDRESS (immutable). FULLY PERMISSIONLESS [CRE v1.0 / B-L-02]:
    ///         anyone may call the moment the game is settled. No owner gate and no time gate.
    ///         (Supersedes the v0.14 owner-any-time / anyone-after-180-day design; the old
    ///         ENDGAME_SWEEP_WINDOW gate no longer applies to this function.)
    ///         vcReturnOwed is set by closeGame() or sweepDormancyRemainder().
    /// @dev    [CRE v1.0 / B-L-02] The destination is immutable and the amount deterministic, so
    ///         any auth added a liveness dependency (owner key loss would permanently strand
    ///         vcReturnOwed — no sweep includes it) without any security benefit (funds can ONLY
    ///         ever go to VC_SEED_RETURN_ADDRESS). Making it fully permissionless from settlement
    ///         means nobody — including the operator — can withhold the investor's principal, and
    ///         it removes the 180-day wait that the earlier fallback imposed. Same anti-lock
    ///         rationale as the permissionless sweeps.
    /// @dev    [CRE v0.6 / INFO-02] On the dormancy (emergency shutdown) path, vcReturnOwed
    ///         is not set until sweepDormancyRemainder(), which requires the full 90-day
    ///         DORMANCY_CLAIM_WINDOW to elapse. The dormancyVCPool senior tier is reserved at
    ///         activateDormancy() but is not payable here until that window closes. The VC
    ///         should expect a minimum 90-day wait for principal on an early shutdown.
    function claimVCReturn() external nonReentrant {
        // [CRE v1.0 / B-L-02] Fully permissionless. Destination immutable, amount
        // deterministic, so no auth or time-gate is needed (supersedes v0.14's
        // owner-or-180-day gate). Anyone may trigger the VC return after settlement.
        if (!gameSettled) revert GameNotClosed();
        if (VC_SEED == 0) revert BelowMinimum();
        uint256 _amount = vcReturnOwed;
        if (_amount == 0) revert NothingToClaim();
        vcReturnOwed = 0;
        IERC20(USDC).safeTransfer(VC_SEED_RETURN_ADDRESS, _amount);
        emit VCReturnClaimed(_amount);
    }

    /// @notice Proposes a new seedReleaseRatioBps. Executes after SEED_RATIO_TIMELOCK (7 days).
    ///         0 = pause all seed release. MAX_SEED_RELEASE_RATIO_BPS is the hard cap at deploy.
    /// @dev    [CRE v0.10 / NS-L-01] PHASE GATES: callable only in ACTIVE + IDLE (not PREGAME,
    ///         DORMANT, or CLOSED, and not mid-draw). EFFECTIVE TIMING: the 7-day timelock means a
    ///         ratio proposed at season start cannot take effect until roughly draw 3-4 (draw cadence
    ///         dependent), so the earliest seed supplement a governance change enables is that draw,
    ///         not draw 1. Material to SmartEarn/VC term sheets: the VC cannot rely on a ratio change
    ///         landing sooner than the timelock permits. A pending proposal is auto-cancelled by
    ///         proposeDormancy() [D-L-01].
    function proposeSeedReleaseRatio(uint256 newRatio) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE)   revert DrawInProgress();
        if (newRatio > 10000)              revert ExceedsLimit();
        if (MAX_SEED_RELEASE_RATIO_BPS > 0 && newRatio > MAX_SEED_RELEASE_RATIO_BPS) revert ExceedsLimit();
        if (seedReleaseRatioEffectiveTime != 0) revert TimelockPending();
        pendingSeedReleaseRatioBps    = newRatio;
        seedReleaseRatioEffectiveTime = block.timestamp + SEED_RATIO_TIMELOCK;
        emit SeedReleaseRatioProposed(newRatio, seedReleaseRatioEffectiveTime);
    }

    /// @notice Executes a pending seedReleaseRatioBps change after the timelock.
    /// @dev    [CRE v0.11 / D4-I-01] ACTIVE + IDLE gates added for uniformity with sibling execute
    ///         functions. Execution outside ACTIVE was harmless (seedReleaseRatioBps is read once
    ///         per draw in _calculatePrizePools(), effective next draw), but the asymmetry was a
    ///         review flag. cancelSeedReleaseRatio() intentionally stays ungated (cancel must work
    ///         in any phase, e.g. after proposeDormancy() has moved the game toward DORMANT).
    function executeSeedReleaseRatio() external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE)   revert DrawInProgress();
        if (seedReleaseRatioEffectiveTime == 0)              revert NoTimelockPending();
        if (block.timestamp < seedReleaseRatioEffectiveTime) revert TooEarly();
        uint256 _old              = seedReleaseRatioBps;
        seedReleaseRatioBps       = pendingSeedReleaseRatioBps;
        pendingSeedReleaseRatioBps    = 0;
        seedReleaseRatioEffectiveTime = 0;
        emit SeedReleaseRatioExecuted(_old, seedReleaseRatioBps);
    }

    /// @notice Cancels a pending seedReleaseRatioBps proposal.
    function cancelSeedReleaseRatio() external onlyOwner {
        if (seedReleaseRatioEffectiveTime == 0) revert NoTimelockPending();
        emit SeedReleaseRatioCancelled(pendingSeedReleaseRatioBps);
        pendingSeedReleaseRatioBps    = 0;
        seedReleaseRatioEffectiveTime = 0;
    }

    /// @notice Claims the OG endgame payout after closeGame(). Capped at the targeted
    ///         return; may be reduced on shortfall (EndgameShortfall event). [v2.27]
    ///         "Guaranteed" language removed -- v1.63 swept this but this @notice survived.
    function claimEndgame() external nonReentrant {
        if (dormancyTimestamp > 0) revert NothingToClaim();
        PlayerData storage p = players[msg.sender];
        if (!gameSettled) revert GameNotClosed();
        if (!_isQualifiedForEndgame(p)) revert NotQualifiedForEndgame();
        if (p.endgameClaimed) revert AlreadyClaimed();
        if (endgamePerOG == 0) revert NothingToClaim();
        if (endgameOwed < endgamePerOG) revert NothingToClaim();
        p.endgameClaimed = true; endgameOwed -= endgamePerOG;
        _withdrawAndTransfer(msg.sender, endgamePerOG);
        // [v1.51] Lightweight post-transfer solvency check.
        // Non-reverting: emits SolvencyAlert if balance dips below allocated totals.
        // Catches unexpected balance changes early before they compound across OG claims.
        // [v1.52] ~800 gas (single USDC balanceOf call + comparison). No aUSDC read needed.
        {
            uint256 _balance = IERC20(USDC).balanceOf(address(this)); // [v1.52] USDC only
            // SYNC: subset of getSolvencyStatus -- draw30BonusFund/tierPools/prizePot zero in CLOSED.
            // Reset/commit pools may be non-zero if reset fired before draw 30.
            // [CRE v0.3 / SYNC] vcReturnOwed and dormancyVCPool added — nonzero in CLOSED if SmartEarn active.
            // [CRE v0.4] vcBonusEscrow added.
            uint256 _allocated = endgameOwed + totalUnclaimedPrizes + treasuryBalance
                + vcReturnOwed + dormancyVCPool + vcBonusEscrow
                + resetDrawRefundPool + resetDrawRefundPool2
                + commitmentRefundPool + totalForceDeclineRefundOwed;
            if (_balance + SOLVENCY_TOLERANCE < _allocated) {
                emit SolvencyAlert(_allocated, _balance, "claimEndgame");
            }
        }
        emit EndgameClaimed(msg.sender, endgamePerOG);
    }

    /// @notice Sweeps unclaimed endgame payouts to the protocol beneficiary after claim window. Owner only.
    /// @dev    Callable once block.timestamp >= settlementTimestamp + ENDGAME_SWEEP_WINDOW
    ///         (180 days). settlementTimestamp is set by closeGame(), sweepDormancyRemainder(),
    ///         or sweepFailedPregame() -- whichever first transitions game to CLOSED.
    ///         After this call swept endgame amounts are unrecoverable by individual OGs.
    function sweepUnclaimedEndgame() external onlyOwner nonReentrant {
        if (!gameSettled) revert GameNotClosed();
        if (block.timestamp < settlementTimestamp + ENDGAME_SWEEP_WINDOW) revert TooEarly();
        if (endgameOwed == 0) revert NothingToClaim();
        uint256 amount = endgameOwed; endgameOwed = 0;
        IERC20(USDC).safeTransfer(PROTOCOL_BENEFICIARY, amount);
        emit UnclaimedFundsSwept("unclaimedEndgame", amount);
    }

    /// @notice Sweeps unclaimed draw prizes to the protocol beneficiary after claim window. Owner only.
    /// @dev    Callable once block.timestamp >= settlementTimestamp + ENDGAME_SWEEP_WINDOW
    ///         (180 days). settlementTimestamp is set by closeGame(), sweepDormancyRemainder(),
    ///         or sweepFailedPregame() -- whichever first transitions game to CLOSED.
    ///         Sets prizesSweepComplete=true permanently. After this call individual
    ///         p.unclaimedPrizes balances remain non-zero on-chain but are unclaimable.
    ///         See also: claimPrize() @dev warning.
    function sweepUnclaimedPrizes() external onlyOwner nonReentrant {
        if (!gameSettled) revert GameNotClosed();
        if (block.timestamp < settlementTimestamp + ENDGAME_SWEEP_WINDOW) revert TooEarly();
        if (totalUnclaimedPrizes == 0) revert NothingToClaim();
        uint256 amount = totalUnclaimedPrizes; totalUnclaimedPrizes = 0;
        prizesSweepComplete = true;
        IERC20(USDC).safeTransfer(PROTOCOL_BENEFICIARY, amount);
        emit UnclaimedFundsSwept("unclaimedPrizes", amount);
    }

    /// @notice Proposes emergency dormancy activation with 24h timelock (DORMANCY_TIMELOCK). Owner only.
    function proposeDormancy() external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (dormancyEffectiveTime != 0) revert TimelockPending();
        if (pendingBreathOverride != 0) { uint256 cancelled = pendingBreathOverride; pendingBreathOverride = 0; pendingBreathOverrideReason = bytes32(0); breathOverrideEffectiveTime = 0; emit BreathOverrideCancelled(cancelled); }
        if (breathRailsEffectiveTime != 0) { uint256 cMin = pendingBreathRailMin; uint256 cMax = pendingBreathRailMax; pendingBreathRailMin = 0; pendingBreathRailMax = 0; breathRailsEffectiveTime = 0; emit BreathRailsProposalCancelled(cMin, cMax); }
        if (pendingMultiplier != 0) { bool isReduction = pendingMultiplier < prizeRateMultiplier; pendingMultiplier = 0; pendingMultiplierReason = bytes32(0); multiplierEffectiveTime = 0; if (isReduction) emit PrizeRateReductionCancelled(); else emit PrizeRateIncreaseCancelled(); }
        // [v1.62] Cancel pending exhale floor release on dormancy proposal.
        if (pendingExhaleFloorReleaseTime != 0) { uint256 c = pendingExhaleFloorReleaseBps; pendingExhaleFloorReleaseBps = 0; pendingExhaleFloorReleaseTime = 0; emit ExhaleFloorReleaseCancelled(c); }
        // [v1.80] Cancel pending feed change -- executeFeedChange() requires ACTIVE so it
        // can never execute after dormancy. Cancel here to avoid orphaned subgraph state.
        if (pendingEthFeedChange.effectiveTime != 0) { delete pendingEthFeedChange; emit FeedChangeCancelled(); }
        // [CRE v0.10 / D-L-01] Cancel pending seed-release-ratio proposal. executeSeedReleaseRatio()
        // has no phase gate and seedReleaseRatioBps is only read in _calculatePrizePools() (ACTIVE
        // only), so a proposal left pending into DORMANT/CLOSED is orphaned governance state (same
        // class as the v1.77/v1.80 findings). Zero fund impact, but cancel it here to keep governance
        // state clean. NOT cancelled in emergencyResetDraw(): a reset resumes ACTIVE, so a pending
        // ratio proposal stays meaningful there.
        // NATURAL-CLOSE CASE [CRE v0.13]: on the ordinary draw-30 -> CLOSED transition (not
        // dormancy), a pending seed-ratio proposal is NOT auto-cancelled here. Post D4-I-01,
        // executeSeedReleaseRatio() requires ACTIVE, so it can never execute after CLOSED;
        // cancelSeedReleaseRatio() is intentionally ungated and remains the cleanup path.
        // Zero fund impact, and this is parity behaviour with every other governance proposal
        // (breath override, rails, multiplier, feed change all share the same natural-close
        // orphan). Documented so a future reviewer does not re-open it as a gap.
        if (seedReleaseRatioEffectiveTime != 0) { uint256 c = pendingSeedReleaseRatioBps; pendingSeedReleaseRatioBps = 0; seedReleaseRatioEffectiveTime = 0; emit SeedReleaseRatioCancelled(c); }
        dormancyEffectiveTime = block.timestamp + DORMANCY_TIMELOCK;
        emit DormancyProposed(dormancyEffectiveTime);
    }

    /// @notice Cancels a pending dormancy proposal. Owner only.
    function cancelDormancy() external onlyOwner {
        if (dormancyEffectiveTime == 0) revert NoTimelockPending();
        dormancyEffectiveTime = 0; emit DormancyCancelled();
    }

    /// @notice Executes dormancy after the 24h timelock (DORMANCY_TIMELOCK). Distributes all funds. Owner only.
    function activateDormancy() external onlyOwner nonReentrant {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (dormancyEffectiveTime == 0) revert NoTimelockPending();
        if (block.timestamp < dormancyEffectiveTime) revert TooEarly();
        if (block.timestamp <= lastDrawTimestamp + PICK_DEADLINE) revert PicksLocked();
        gamePhase = GamePhase.DORMANT; dormancyTimestamp = block.timestamp; dormancyEffectiveTime = 0;
        // [v1.62] Return accumulated bonus fund to prizePot before dormancy waterfall.
        // draw30BonusFund was siphoned from prize distributions and is not in prizePot.
        // Must be returned here or it becomes stranded (game never reaches draw 30).
        if (draw30BonusFund > 0) { uint256 bonusReturned = draw30BonusFund; prizePot += bonusReturned; draw30BonusFund = 0; emit Draw30BonusReturned(bonusReturned); }
        _captureYield();
        totalOGPrincipalSnapshot = totalOGPrincipal;

        // [CRE v0.1] Compute dormancy avg OG ratio -- retained for informational monitoring only.
        // [CRE v0.3] dormancyAvgTargetReturnBps is no longer used for OG pool sizing.
        {
            uint256 _dormAvgRatioBps = (ogRatioDrawCount > 0)
                ? ogRatioBpsAccumulator / ogRatioDrawCount
                : (ogCapDenominator > 0 ? (upfrontOGCount + earnedOGCount) * 10000 / ogCapDenominator : 0);
            dormancyAvgTargetReturnBps = _computeTargetReturnBps(_dormAvgRatioBps);
        }

        // [CRE v0.3 / MEDIUM-01] Pro-rata OG dormancy refund.
        // Snapshot draws completed before dormancy. drawsPlayed = currentDraw - 1 because
        // dormancy fires in IDLE phase (currentDraw is the next open draw, not yet played).
        // drawsUnplayed = draws OGs paid for but did not get to play.
        // Treasury slice (UF_OG_TREASURY_BPS = 25%) is non-refundable — it was the commitment signal.
        // Each OG's entitlement = p.totalPaid * (10000 - UF_OG_TREASURY_BPS) / 10000
        //                        * drawsUnplayed / TOTAL_DRAWS.
        // [CRE v0.9 / IC-I-01] Example in drawsPlayed terms (TOTAL_DRAWS = 30), unambiguous:
        //   drawsPlayed = 5  -> drawsUnplayed = 25 -> refund = ~83% of net principal.
        //   drawsPlayed = 25 -> drawsUnplayed = 5  -> refund = ~17% of net principal.
        //   drawsPlayed = 30 -> drawsUnplayed = 0  -> refund = 0 (endgame path handles a full season).
        // Recall drawsPlayed = currentDraw - 1 (dormancy fires in IDLE before the open draw plays).
        // This is fair to OGs on operator-triggered early shutdown and honest to disclose.
        // Same formula applies to weekly OGs (both treasury rates are 25% in CRE v0.1+).
        // [CRE v0.12 / D5-L-01] Subtract resetDrawCount. Each emergency reset consumes a draw
        // number (currentDraw++ at reset-finalize) WITHOUT anyone playing that draw, so raw
        // (currentDraw - 1) over-states draws actually played by one per prior reset. Counting a
        // voided draw as played contradicts this block's own rationale ("draws OGs paid for but
        // did not get to play") and would shave ~$15 net per upfront OG per reset off their pool,
        // shifting it down the waterfall. Netting it out gives upfront OGs the same "a reset costs
        // the player nothing" treatment that D4-M-01 gave weekly OGs. Floor at 0 (defensive; resets
        // cannot exceed draws occurred), then the existing TOTAL_DRAWS cap still applies.
        {
            uint256 _drawsPlayed = currentDraw > 1 ? currentDraw - 1 : 0;
            // [CRE v0.13 / NS-I-A] The ternary floor is DEFENSIVE-ONLY and never binds: the
            // invariant (currentDraw - 1) == drawsPlayed + resetDrawCount holds at every point in
            // ACTIVE (each reset increments both resetDrawCount and currentDraw; each play
            // increments only currentDraw), so _drawsPlayed >= resetDrawCount always. Annotated
            // in the same house style as other never-binding guards (e.g. the ": 1000" dead
            // branch in _computeTargetReturnBps, the draw-0 guard in isResultStale).
            _drawsPlayed = _drawsPlayed > resetDrawCount ? _drawsPlayed - resetDrawCount : 0;
            if (_drawsPlayed > TOTAL_DRAWS) _drawsPlayed = TOTAL_DRAWS;
            dormancyDrawsPlayed = _drawsPlayed;
            uint256 _drawsUnplayed = TOTAL_DRAWS - _drawsPlayed;
            // [CRE v0.4 / DR-M-01] Upfront OGs only. Weekly OGs claim from casual pool instead.
            // upfrontOGCount * OG_UPFRONT_COST = correct aggregate (F1 fix: p.totalPaid == OG_UPFRONT_COST).
            uint256 _netRateBps = 10000 - UF_OG_TREASURY_BPS; // 7500 bps = 75%
            uint256 _upfrontOGNetPrincipal = upfrontOGCount * OG_UPFRONT_COST * _netRateBps / 10000;
            uint256 _ogTargetTotal2 = _drawsUnplayed > 0
                ? _upfrontOGNetPrincipal * _drawsUnplayed / TOTAL_DRAWS
                : 0;
            dormancyTotalOGEntitlement = _ogTargetTotal2;
        }

        // [CRE v0.1 / SmartEarn] TIER 0 (above OGs): VC unreleased seed.
        // vcReturnOwed is populated at sweepDormancyRemainder() — not claimable until then.
        if (VC_SEED > 0) {
            uint256 _vcShortfall = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
            if (_vcShortfall == 0 || prizePot == 0) {
                dormancyVCPool = 0; dormancyVCPoolSnapshot = 0; dormancyVCFullCover = (_vcShortfall == 0);
            } else if (prizePot >= _vcShortfall) {
                dormancyVCPool = _vcShortfall; dormancyVCPoolSnapshot = _vcShortfall; dormancyVCFullCover = true;
                prizePot -= _vcShortfall;
            } else {
                dormancyVCPool = prizePot; dormancyVCPoolSnapshot = prizePot; dormancyVCFullCover = false;
                prizePot = 0;
            }
        }

        // [CRE v0.3] TIER 1 (OGs): pro-rata unplayed-draws entitlement — upfront OGs only.
        // [CRE v0.4 / DR-M-01] Weekly OGs removed from OG pool. They claim from casual pool
        // (current draw only) in claimDormancyRefund(). upfrontOGCount * OG_UPFRONT_COST is
        // the correct aggregate because the F1 fix ensures p.totalPaid == OG_UPFRONT_COST
        // for every upfront OG regardless of commitment credit usage.
        // dormancyTotalOGEntitlement was computed above from upfront-only principal.
        uint256 _ogTargetTotal = dormancyTotalOGEntitlement;
        if (_ogTargetTotal == 0 || upfrontOGCount == 0) {
            dormancyOGPool = 0; dormancyOGPoolSnapshot = 0; dormancyPrincipalFullCover = true;
        } else if (prizePot >= _ogTargetTotal) {
            dormancyOGPool = _ogTargetTotal; dormancyOGPoolSnapshot = _ogTargetTotal; dormancyPrincipalFullCover = true; prizePot -= _ogTargetTotal;
        } else {
            dormancyOGPool = prizePot; dormancyOGPoolSnapshot = prizePot; dormancyPrincipalFullCover = false; prizePot = 0;
        }
        // [CRE v0.4 / DR-M-01] Casual pool includes weekly OG current-draw net ticket spend.
        // Weekly OGs who bought this draw claim from here at dormancy, same formula as casuals.
        dormancyCasualTicketTotal = currentDrawCasualNetTicketTotal + currentDrawWeeklyOGNetTicketTotal;
        if (!dormancyPrincipalFullCover || dormancyCasualTicketTotal == 0) {
            dormancyCasualRefundPool = 0; dormancyCasualRefundPoolSnapshot = 0; dormancyCasualFullCover = false;
        } else if (prizePot >= dormancyCasualTicketTotal) {
            dormancyCasualRefundPool = dormancyCasualTicketTotal; dormancyCasualRefundPoolSnapshot = dormancyCasualTicketTotal; dormancyCasualFullCover = true; prizePot -= dormancyCasualTicketTotal;
        } else {
            dormancyCasualRefundPool = prizePot; dormancyCasualRefundPoolSnapshot = prizePot; dormancyCasualFullCover = false; prizePot = 0;
        }
        {
            uint256 safeDoubleCount_ = committedDoubleCount < neverPlayedCommitmentCount ? committedDoubleCount : neverPlayedCommitmentCount;
            uint256 singleComCount_ = neverPlayedCommitmentCount > safeDoubleCount_ ? neverPlayedCommitmentCount - safeDoubleCount_ : 0;
            uint256 commitNetOwed = singleComCount_ * TICKET_PRICE * (10000 - TREASURY_BPS) / 10000 + safeDoubleCount_ * TICKET_PRICE * 2 * (10000 - TREASURY_BPS) / 10000;
            dormancyCommitmentNetTotal = commitNetOwed;
            if (!dormancyPrincipalFullCover || commitNetOwed == 0) {
                dormancyCommitmentPool = 0; dormancyCommitmentPoolSnapshot = 0; dormancyCommitmentFullCover = false;
            } else if (prizePot >= commitNetOwed) {
                dormancyCommitmentPool = commitNetOwed; dormancyCommitmentPoolSnapshot = commitNetOwed; dormancyCommitmentFullCover = true; prizePot -= commitNetOwed;
            } else {
                dormancyCommitmentPool = prizePot; dormancyCommitmentPoolSnapshot = prizePot; dormancyCommitmentFullCover = false; prizePot = 0;
            }
        }
        // [CRE v0.7 / M-01] Size the per-head denominator on CLAIMABLE heads only.
        // Was: upfrontOGCount + weeklyOGCount + weeklyNonOGPlayers.length. weeklyOGCount
        // counted active weekly OGs who had NOT bought the current draw; those OGs revert
        // NothingToClaim before the per-head block, so they never claimed their slice. It
        // diluted everyone and swept to the beneficiary. currentDrawWeeklyOGBuyerCount counts
        // only weekly OGs who bought this draw (or the pregame draw-1 entry), which is exactly
        // the set able to reach the per-head block. weeklyNonOGPlayers are all current-draw
        // buyers by construction (only current-draw buyers are pushed). upfront OGs always claim.
        dormancyParticipantCount = upfrontOGCount + currentDrawWeeklyOGBuyerCount + weeklyNonOGPlayers.length;
        dormancyPerHeadPool = prizePot;
        if (dormancyParticipantCount > 0 && dormancyPerHeadPool > 0) { dormancyPerHeadShare = dormancyPerHeadPool / dormancyParticipantCount; } else { dormancyPerHeadShare = 0; }
        prizePot = 0;
        emit DormancyActivated(block.timestamp);
        emit DormancyClaimDeadline(block.timestamp + DORMANCY_CLAIM_WINDOW);
    }

    /// @notice Claims dormancy refund for the caller. DORMANT phase only.
    /// @dev [v2.15] Casual ticket refund uses flat TREASURY_BPS on all draws. [CRE v0.1] 25%.
    ///      Commitment-only path also uses flat TREASURY_BPS -- commitment was paid pre-game.
    ///      Status-lost weekly OGs who did not re-enter as casuals this draw are not
    ///      eligible for any dormancy pool. Their OG principal was redistributed to
    ///      the prize pot at the draw they lost status. This is intentional -- the
    ///      commitment mechanic does not protect players who chose to stop participating.
    ///      IMPORTANT: Casuals who did not buy tickets in the CURRENT draw at dormancy
    ///      activation are also NOT eligible for refund -- even if they bought in prior
    ///      draws. Only current-draw buyers appear in weeklyNonOGPlayers. Prior-draw
    ///      contributions remain in the pot. This is intentional design.
    /// @dev [v2.05] p.commitmentPaid is NOT cleared during the casual path while a live
    ///      commitmentRefundPool exists (cleared only when pool == 0 or deadline expired).
    ///      Preserves the player's claimCommitmentRefund() entitlement on an overlapping
    ///      dormancy claim. Without this gate the commitment deposit would be stranded.
    function claimDormancyRefund() external nonReentrant {
        if (gamePhase == GamePhase.CLOSED) { if (dormancyTimestamp > 0) revert DormancyWindowExpired(); revert GameNotDormant(); }
        if (gamePhase != GamePhase.DORMANT) revert GameNotDormant();
        PlayerData storage p = players[msg.sender];
        if (p.dormancyRefunded) revert AlreadyRefunded();
        uint256 refund;
        if (p.isUpfrontOG) {
            // [CRE v0.7 / M-01] Do NOT revert up front on an empty OG principal pool.
            // An upfront OG is still a claimable per-head participant. Compute principal
            // (which is 0 when the OG pool is empty), add the per-head share, and revert
            // only if the COMBINED refund is zero. Previously the dormancyOGPool == 0 revert
            // fired before the per-head block, confiscating the per-head slice in the rare
            // case the OG principal pool was fully exhausted by senior tiers.
            // [CRE v0.3 / MEDIUM-01] Pro-rata unplayed-draws entitlement.
            // netPaid = gross * 75% (25% treasury non-refundable).
            // Entitlement = netPaid * drawsUnplayed / TOTAL_DRAWS.
            uint256 _drawsUnplayed = TOTAL_DRAWS > dormancyDrawsPlayed ? TOTAL_DRAWS - dormancyDrawsPlayed : 0;
            uint256 _netPaid = p.totalPaid * (10000 - UF_OG_TREASURY_BPS) / 10000;
            uint256 _entitlement = (_drawsUnplayed > 0 && dormancyTotalOGEntitlement > 0)
                ? _netPaid * _drawsUnplayed / TOTAL_DRAWS
                : 0;
            uint256 principal;
            if (dormancyOGPool == 0 || dormancyTotalOGEntitlement == 0) {
                principal = 0;
            } else if (dormancyPrincipalFullCover) {
                principal = _entitlement;
            } else {
                principal = _entitlement * dormancyOGPoolSnapshot / dormancyTotalOGEntitlement;
            }
            if (principal > dormancyOGPool) principal = dormancyOGPool;
            if (principal > 0) { dormancyOGPool -= principal; }
            refund = principal;
            if (dormancyPerHeadShare > 0 && dormancyPerHeadPool > 0) { uint256 perHead = dormancyPerHeadShare > dormancyPerHeadPool ? dormancyPerHeadPool : dormancyPerHeadShare; dormancyPerHeadPool -= perHead; refund += perHead; }
            // Revert only if nothing at all is owed (no principal and no per-head slice).
            if (refund == 0) revert NothingToClaim();
            if (upfrontOGCount > 0) upfrontOGCount--;
            p.isUpfrontOG = false; p.prediction = 0; p.prediction2 = 0; p.predictionDraw = 0; p.prediction2Draw = 0;
            uint256 ogLenP1 = ogList.length;
            if (ogLenP1 > 0 && ogListIndex[msg.sender] < ogLenP1 && ogList[ogListIndex[msg.sender]] == msg.sender) {
                uint256 idxP1 = ogListIndex[msg.sender]; uint256 lastP1 = ogLenP1 - 1;
                if (idxP1 != lastP1) { address lastAddrP1 = ogList[lastP1]; ogList[idxP1] = lastAddrP1; ogListIndex[lastAddrP1] = idxP1; }
                ogList.pop(); delete ogListIndex[msg.sender];
            }
        } else if (p.isWeeklyOG && !p.weeklyOGStatusLost) {
            // [CRE v0.4 / DR-M-01] Weekly OGs claim from the casual pool for the current draw only.
            // They pay per draw so have no prepaid future principal to return. The pro-rata formula
            // (v0.3) was wrong: it refunded accumulated historical spend on draws already consumed.
            // Now: current draw net ticket cost only. Nothing for prior weeks (already played and settled).
            // If the weekly OG did not buy this draw, they get nothing — no current claim exists.
            if (p.lastBoughtDraw == currentDraw && p.lastTicketCost > 0 && dormancyCasualRefundPool > 0) {
                uint256 _wogNetCost = p.lastTicketCost * (10000 - TREASURY_BPS) / 10000;
                if (_wogNetCost > 0) {
                    uint256 _wogRefund;
                    if (dormancyCasualFullCover) { _wogRefund = _wogNetCost; }
                    else { if (dormancyCasualTicketTotal == 0) revert NothingToClaim(); _wogRefund = dormancyCasualRefundPoolSnapshot * _wogNetCost / dormancyCasualTicketTotal; }
                    if (_wogRefund > dormancyCasualRefundPool) _wogRefund = dormancyCasualRefundPool;
                    dormancyCasualRefundPool -= _wogRefund; refund = _wogRefund;
                }
            }
            if (refund == 0 && (p.lastBoughtDraw != currentDraw || p.lastTicketCost == 0)) revert NothingToClaim();
            // [CRE v0.5 / DR-L-01] Per-head share for weekly OGs — was missing in v0.4.
            // [CRE v0.7 / M-01] dormancyParticipantCount counts current-draw weekly-OG buyers
            // (currentDrawWeeklyOGBuyerCount), the exact set that reaches this block. A weekly OG
            // who did not buy the current draw reverts above and is not in the denominator, so
            // no slice is sized for a head that cannot claim. Buyers are sized in and claim here.
            if (dormancyPerHeadShare > 0 && dormancyPerHeadPool > 0) { uint256 perHead = dormancyPerHeadShare > dormancyPerHeadPool ? dormancyPerHeadPool : dormancyPerHeadShare; dormancyPerHeadPool -= perHead; refund += perHead; }
            // Cleanup: remove from OG structures regardless of refund amount.
            if (weeklyOGCount > 0) weeklyOGCount--;
            if (earnedOGCount > 0) earnedOGCount--;
            if (p.consecutiveWeeks >= WEEKLY_OG_QUALIFICATION_WEEKS && qualifiedWeeklyOGCount > 0) qualifiedWeeklyOGCount--;
            p.isWeeklyOG = false; p.prediction = 0; p.prediction2 = 0; p.predictionDraw = 0; p.prediction2Draw = 0;
            uint256 ogLenD2 = ogList.length;
            if (ogLenD2 > 0 && ogListIndex[msg.sender] < ogLenD2 && ogList[ogListIndex[msg.sender]] == msg.sender) {
                uint256 idxD2 = ogListIndex[msg.sender]; uint256 lastD2 = ogLenD2 - 1;
                if (idxD2 != lastD2) { address lastAddrD2 = ogList[lastD2]; ogList[idxD2] = lastAddrD2; ogListIndex[lastAddrD2] = idxD2; }
                ogList.pop(); delete ogListIndex[msg.sender];
            }
        } else if (p.lastBoughtDraw == currentDraw && p.lastTicketCost > 0) {
            if (lastResetDraw == currentDraw && dormancyCasualTicketTotal == 0) revert NothingToClaim();
            // [v2.15] Flat treasury: all draws use TREASURY_BPS (25%) [CRE v0.6 NS].
            uint256 playerNetCost = p.lastTicketCost * (10000 - TREASURY_BPS) / 10000;
            if (playerNetCost > 0 && dormancyCasualRefundPool > 0) {
                uint256 casualRefund;
                if (dormancyCasualFullCover) { casualRefund = playerNetCost; }
                else { if (dormancyCasualTicketTotal == 0) revert NothingToClaim(); casualRefund = dormancyCasualRefundPoolSnapshot * playerNetCost / dormancyCasualTicketTotal; }
                if (casualRefund > dormancyCasualRefundPool) casualRefund = dormancyCasualRefundPool;
                dormancyCasualRefundPool -= casualRefund; refund = casualRefund;
            }
            if (dormancyPerHeadShare > 0 && dormancyPerHeadPool > 0) { uint256 perHead = dormancyPerHeadShare > dormancyPerHeadPool ? dormancyPerHeadPool : dormancyPerHeadShare; dormancyPerHeadPool -= perHead; refund += perHead; }
        } else if (p.commitmentPaid && p.lastBoughtDraw == 0) {
            if (dormancyCommitmentPool == 0) revert NothingToClaim();
            // [v2.15] Flat treasury: pregame commitment paid at TREASURY_BPS (25%) pre-game [CRE v0.6 NS].
            // All active-draw purchases also use TREASURY_BPS. Single flat rate on all paths.
            uint256 netPerTicket = TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
            uint256 net = p.commitmentDouble ? netPerTicket * 2 : netPerTicket;
            uint256 commitRefund;
            if (dormancyCommitmentFullCover) { commitRefund = net; }
            else { if (dormancyCommitmentNetTotal == 0) revert NothingToClaim(); commitRefund = dormancyCommitmentPoolSnapshot * net / dormancyCommitmentNetTotal; }
            if (commitRefund > dormancyCommitmentPool) commitRefund = dormancyCommitmentPool;
            if (commitRefund == 0) revert NothingToClaim();
            dormancyCommitmentPool -= commitRefund;
            if (neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false; // [v2.22] p.totalPaid zeroed at trailing cleanup below; double-write removed.
            if (committedPlayerCount > 0) committedPlayerCount--;
            if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
            refund = commitRefund;
        } else { revert NothingToClaim(); }
        // [v1.70] Unconditional weekly OG cleanup. Fires after any refund path including
        // status-lost OGs who claimed via casual path. weeklyOGCount was already
        // decremented in _processMatchesCore() at status loss -- no double-decrement here.
        if (p.isWeeklyOG) {
            p.isWeeklyOG = false; p.weeklyOGStatusLost = false;
            p.prediction = 0; p.prediction2 = 0; p.predictionDraw = 0; p.prediction2Draw = 0;
            uint256 ogLenC = ogList.length;
            if (ogLenC > 0 && ogListIndex[msg.sender] < ogLenC && ogList[ogListIndex[msg.sender]] == msg.sender) {
                uint256 idxC = ogListIndex[msg.sender]; uint256 lastC = ogLenC - 1;
                if (idxC != lastC) { address lastAddrC = ogList[lastC]; ogList[idxC] = lastAddrC; ogListIndex[lastAddrC] = idxC; }
                ogList.pop(); delete ogListIndex[msg.sender];
            }
        }
        if (refund == 0) revert NothingToClaim();
        // [v2.05] Gate prevents destroying commitment refund entitlement.
        // A casual-path player who had a draw-1 emergency reset may still have an active
        // commitmentRefundPool. Clearing commitmentPaid unconditionally would deny their
        // ability to call claimCommitmentRefund(). Only clear once the pool is gone or expired.
        // [v2.11] activateDormancy() already ran -- pool sizing used min(committedDoubleCount,
        // neverPlayedCommitmentCount) so committedDoubleCount drift here has zero fund impact.
        // Still cleared for counter consistency across all cleanup paths.
        if (p.commitmentPaid && (commitmentRefundPool == 0 || block.timestamp > commitmentRefundDeadline)) {
            // neverPlayedCommitmentCount: guard (lastBoughtDraw == 0) is always false here --
            // casual-path callers have lastBoughtDraw == currentDraw != 0. Pre-existing
            // dead-code line retained for safety; no counter drift.
            if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
            if (commitmentPaidCount > 0) commitmentPaidCount--;
            p.commitmentPaid = false; if (committedPlayerCount > 0) committedPlayerCount--;
            if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
        }
        // Belt-and-suspenders: casual path preserves commitmentPaid while pool is active.
        p.totalPaid = 0; p.dormancyRefunded = true;
        if (refund > 0) _withdrawAndTransfer(msg.sender, refund);
        // [v1.98] F4 / [v1.99] B-1.98-01 compile fix: inline allocation check.
        // getSolvencyStatus() is external and cannot be called internally.
        // Checks remaining dormancy pools + treasury vs actual USDC balance.
        { uint256 _bal = IERC20(USDC).balanceOf(address(this));
          uint256 _alloc = dormancyOGPool + dormancyCasualRefundPool
              + dormancyCommitmentPool + dormancyPerHeadPool
              + dormancyVCPool + vcReturnOwed + vcBonusEscrow              // [CRE v0.3/v0.4 / SYNC]
              + treasuryBalance + endgameOwed + totalUnclaimedPrizes
              + resetDrawRefundPool + resetDrawRefundPool2
              + commitmentRefundPool + totalForceDeclineRefundOwed;
          // SYNC: subset of getSolvencyStatus -- prizePot/tierPools/seedReturn/draw30BonusFund are 0 in DORMANT.
          if (_bal + SOLVENCY_TOLERANCE < _alloc)
              emit SolvencyAlert(_alloc, _bal, "claimDormancyRefund"); }
        emit DormancyRefund(msg.sender, refund);
    }

    /// @notice Sweeps expired unclaimed dormancy pool allocations to PROTOCOL_BENEFICIARY.
    /// @dev [CRE v0.14 / NS-I-01] INTENTIONALLY PERMISSIONLESS (no onlyOwner), unlike the other
    ///      owner-gated sweeps. Everything it moves goes to fixed destinations (PROTOCOL_BENEFICIARY
    ///      and vcReturnOwed to the immutable VC address), and it is time-gated by the dormancy claim
    ///      window, so anyone triggering it cannot redirect funds. Permissionless by design to avoid
    ///      an owner-key-loss lock, matching sweepResetRefundRemainder()'s anti-lock rationale. A cold
    ///      reviewer may flag the missing access control until they trace the destinations; this is it.
    /// @dev Sweeps dormancy-specific pools only (OG pool, casual pool, commitment pool,
    ///      per-head pool, prizePot remainder). The following are intentionally excluded
    ///      and remain accessible via their own functions:
    ///      - treasuryBalance: withdrawTreasury() (after gameSettled)
    ///      - totalUnclaimedPrizes: claimPrize() / sweepUnclaimedPrizes()
    ///      - resetDrawRefundPool(s): claimResetRefund() / sweepResetRefundRemainder()
    ///      - commitmentRefundPool: claimCommitmentRefund() / sweepResetRefundRemainder()
    ///      - draw30BonusFund: returned to prizePot at activateDormancy() before this fires.
    function sweepDormancyRemainder() external nonReentrant {
        if (gamePhase != GamePhase.DORMANT) revert GameNotDormant();
        if (gameSettled) revert GameAlreadyClosed();
        if (block.timestamp < dormancyTimestamp + DORMANCY_CLAIM_WINDOW) revert TooEarly();
        _captureYield();
        gamePhase = GamePhase.CLOSED; settlementTimestamp = block.timestamp; gameSettled = true;

        // [CRE v0.1 / SmartEarn] VC return: dormancyVCPool + treasury backstop + SmartEarn bonus.
        if (VC_SEED > 0) {
            uint256 _vcShortfallTotal = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
            if (dormancyVCPool > 0 || !dormancyVCFullCover) {
                uint256 _poolGap     = _vcShortfallTotal > dormancyVCPool ? _vcShortfallTotal - dormancyVCPool : 0;
                uint256 _fromTreasury = _poolGap <= treasuryBalance ? _poolGap : treasuryBalance;
                if (_fromTreasury > 0) treasuryBalance -= _fromTreasury;
                vcReturnOwed   = dormancyVCPool + _fromTreasury;
                dormancyVCPool = 0; dormancyVCPoolSnapshot = 0; dormancyVCFullCover = false;
            }
            // [CRE v0.4 / SE-M-01] Escrow already moved from treasury at tier crossing.
            if (vcBonusEscrow > 0) { vcReturnOwed += vcBonusEscrow; vcBonusEscrow = 0; }
            // [CRE v1.07 / VC-SPENT-RETURN] Pay the spent-seed obligation (reconstituted principal
            // + 25% return + big-season bonus) on EARLY SHUTDOWN too, not just a completed season.
            // The withdraw lock reserved this in treasury throughout the season, so the money is
            // present at a dormancy. So the VC's return no longer depends on the game completing,
            // only on how much of their seed was actually spent. True amount (no buffer, that was
            // protocol money); bounded to treasuryBalance defensively so this can never underflow.
            // Mirrors the closeGame() spent-return exactly; the two paths are mutually exclusive
            // (closeGame requires a non-DORMANT phase, this requires DORMANT, both gate on
            // gameSettled), so the obligation is paid on exactly one path.
            uint256 _spentObligD = _vcTreasuryObligation();
            if (_spentObligD > 0) {
                uint256 _fromTreD = _spentObligD <= treasuryBalance ? _spentObligD : treasuryBalance;
                treasuryBalance -= _fromTreD;
                vcReturnOwed    += _fromTreD;
            }
        }

        uint256 remaining = dormancyOGPool + dormancyCasualRefundPool + dormancyCommitmentPool + dormancyPerHeadPool + prizePot;
        dormancyOGPool = 0; dormancyOGPoolSnapshot = 0;
        dormancyCasualRefundPool = 0; dormancyCasualRefundPoolSnapshot = 0;
        dormancyCommitmentPool = 0; dormancyCommitmentPoolSnapshot = 0; dormancyCommitmentNetTotal = 0; dormancyCommitmentFullCover = false;
        dormancyPerHeadPool = 0; dormancyPerHeadShare = 0; prizePot = 0;
        dormancyParticipantCount = 0; dormancyCasualTicketTotal = 0;
        dormancyPrincipalFullCover = false; dormancyCasualFullCover = false;
        totalOGPrincipal = 0; totalOGPrincipalSnapshot = 0;
        if (remaining > 0) { IERC20(USDC).safeTransfer(PROTOCOL_BENEFICIARY, remaining); }
        emit DormancyRemainderSwept(remaining);
    }

    /// @notice Refunds a batch of players during a failed pregame. PREGAME only. Owner only.
    /// @param playerList  Array of player addresses to refund.
    function batchRefundPlayers(address[] calldata playerList) external onlyOwner nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        if (block.timestamp < signupDeadline) revert TooEarly();
        bool signupFailed = committedPlayerCount < MIN_PLAYERS_TO_START;
        bool pregameExpired = block.timestamp >= signupDeadline + MAX_PREGAME_DURATION;
        if (!signupFailed && !pregameExpired) revert SignupNotFailed();
        if (playerList.length > BATCH_REFUND_MAX) revert ExceedsLimit();
        _captureYield();
        uint256 len = playerList.length;
        for (uint256 i = 0; i < len; i++) {
            address addr = playerList[i];
            PlayerData storage p = players[addr];
            if (p.dormancyRefunded) continue;
            if (p.totalPaid == 0) continue;
            uint256 fullAmount = p.totalPaid; uint256 refund = fullAmount;
            uint256 maxDeductible = prizePot + treasuryBalance;
            if (refund > maxDeductible) refund = maxDeductible;
            if (refund == 0) continue;
            p.dormancyRefunded = true; p.totalPaid = 0;
            if (p.isUpfrontOG || p.isWeeklyOG) { _cleanupOGOnRefund(addr, p); }
            else if (p.commitmentPaid) {
                if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
                if (commitmentPaidCount > 0) commitmentPaidCount--;
                p.commitmentPaid = false; if (committedPlayerCount > 0) committedPlayerCount--;
                if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
                p.prediction = 0; p.predictionDraw = 0; p.prediction2 = 0; p.prediction2Draw = 0;
            } else if (ogIntentStatus[addr] == OGIntentStatus.PENDING) {
                // [v1.57-P1] pendingIntentCount deprecated -- intent queue removed.
                ogIntentStatus[addr] = OGIntentStatus.DECLINED; ogIntentAmount[addr] = 0;
                if (committedPlayerCount > 0) committedPlayerCount--;
            }
            // [CRE v1.11a / PG-02] Dead SWEPT block removed (unreachable double-decrement trap).
            if (refund <= prizePot) { prizePot -= refund; } else {
                uint256 fromTreasury = refund - prizePot; prizePot = 0;
                if (treasuryBalance >= fromTreasury) { treasuryBalance -= fromTreasury; } else { treasuryBalance = 0; }
            }
            _withdrawAndTransfer(addr, refund);
            emit SignupRefund(addr, refund, fullAmount);
        }
    }

    /// @notice Sweeps residual pregame contract balance to PROTOCOL_BENEFICIARY if the
    ///         game never reached ACTIVE state. Owner only. PREGAME phase only.
    ///         Individual player refunds are handled first by batchRefundPlayers() and
    ///         claimSignupRefund(). This function closes the accounting and sweeps any
    ///         remaining balance (treasuryBalance excepted) to PROTOCOL_BENEFICIARY.
    ///         treasuryBalance remains withdrawable via withdrawTreasury() after
    ///         gameSettled = true. Via time-gate path, unclaimed funds go to
    ///         PROTOCOL_BENEFICIARY -- NOT returned to individual players.
    /// @dev    [CRE v0.6 / MEDIUM-01] If a VC seed was deposited (potSeeded) but the game
    ///         never started, the seed is returned to VC_SEED_RETURN_ADDRESS here, atomically,
    ///         BEFORE the protocol-beneficiary sweep. Without this the deposited seed would be
    ///         swept to PROTOCOL_BENEFICIARY -- a misroute of investor principal. seedReleased
    ///         is always 0 in PREGAME (the supplement only fires in ACTIVE), so the full VC_SEED
    ///         is the correct return amount. This is the mirror of the SE-H-01 guard: that stops
    ///         the game defending a seed never deposited; this returns a seed that WAS deposited
    ///         when the game never starts. The seed is subtracted from the residual first so the
    ///         two transfers cannot draw on the same balance.
    function sweepFailedPregame() external onlyOwner nonReentrant {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase();
        // Time-gate path: full extension window elapsed -- residuals sweep to PROTOCOL_BENEFICIARY
        // regardless of how many players are still unrefunded. "Time has run out."
        bool timeGateOpen = block.timestamp >= signupDeadline + MAX_PREGAME_DURATION + FAILED_PREGAME_SWEEP_EXTENSION;
        // Clean-close path: all committed players individually refunded and signup window passed.
        bool allRefunded = committedPlayerCount == 0 && block.timestamp >= signupDeadline;
        if (!timeGateOpen && !allRefunded) revert TooEarly();
        _captureYield();
        gamePhase = GamePhase.CLOSED; gameSettled = true; settlementTimestamp = block.timestamp;
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));

        // [CRE v0.6 / MEDIUM-01] Return the deposited VC seed first. seedReleased == 0 in PREGAME,
        // so the full VC_SEED is owed back. Cap at usdcBalance for safety (cannot exceed holdings).
        uint256 seedReturn = 0;
        if (potSeeded && VC_SEED > 0) {
            seedReturn = VC_SEED <= usdcBalance ? VC_SEED : usdcBalance;
            if (seedReturn > 0) {
                usdcBalance -= seedReturn; // remove from residual before the beneficiary sweep
                IERC20(USDC).safeTransfer(VC_SEED_RETURN_ADDRESS, seedReturn);
                emit FailedPregameSeedReturned(seedReturn);
            }
        }

        // [CRE v0.9 / B-L-01] Reconcile treasuryBalance to actual holdings. On the clean-close
        // path, players reclaim their full commitment via claimSignupRefund() INCLUDING the
        // treasury slice, but treasuryBalance (the accounting variable) still records those
        // slices. After the seed return, recorded treasuryBalance can exceed the USDC actually
        // left in the contract. Left unreconciled, a later withdrawTreasury() would attempt to
        // move more than the contract holds and revert inside SafeERC20 -- stranding the owner's
        // claim (funds are safe; the claim is just unbacked). usdcBalance here is exactly the
        // post-seed-return on-chain holding, so capping treasuryBalance at it is the correct
        // settlement reconcile. The only legitimate cause of the gap is refunded slices; this
        // does not mask any other discrepancy because no other path diverges balance from
        // holdings at this settlement point.
        if (treasuryBalance > usdcBalance) treasuryBalance = usdcBalance;

        // [v1.57-P1] totalForceDeclineRefundOwed always 0 (intent queue removed). Retained for storage compat.
        uint256 toProtocolBeneficiary = usdcBalance > treasuryBalance + totalForceDeclineRefundOwed ? usdcBalance - treasuryBalance - totalForceDeclineRefundOwed : 0;
        prizePot = 0;
        if (toProtocolBeneficiary > 0) { IERC20(USDC).safeTransfer(PROTOCOL_BENEFICIARY, toProtocolBeneficiary); }
        emit FailedPregameSwept(toProtocolBeneficiary);
    }

    /// @notice Claims reset refund for the caller. Post-emergencyResetDraw only.
    /// @dev [v2.15] Flat treasury: both pools use TREASURY_BPS (25%) regardless of draw [CRE v0.6 NS].
    ///      Callers eligible for both pools must call twice -- returns after pool1.
    function claimResetRefund() external nonReentrant {
        PlayerData storage p = players[msg.sender];
        if (p.isUpfrontOG) revert ResetRefundNotEligible();
        bool pool1Active = resetDrawRefundDraw != 0 && block.timestamp <= resetDrawRefundDeadline;
        bool pool2Active = resetDrawRefundDraw2 != 0 && block.timestamp <= resetDrawRefundDeadline2;
        bool eligiblePool1 = pool1Active && ((p.lastBoughtDraw == resetDrawRefundDraw) || (p.lastResetBoughtDraw1 == resetDrawRefundDraw)) && p.resetRefundClaimedAtDraw != resetDrawRefundDraw;
        bool eligiblePool2 = pool2Active && ((p.lastBoughtDraw == resetDrawRefundDraw2) || (p.lastResetBoughtDraw2 == resetDrawRefundDraw2)) && p.resetRefundClaimedAtDraw2 != resetDrawRefundDraw2;
        if (!eligiblePool1 && !eligiblePool2) revert ResetRefundNotEligible();
        if (eligiblePool1) {
            uint256 costForCalc = (p.lastResetBoughtDraw1 == resetDrawRefundDraw) ? p.lastResetTicketCost1 : p.lastTicketCost;
            uint256 netCost = costForCalc * (10000 - TREASURY_BPS) / 10000;
            if (netCost == 0) revert ResetRefundNotEligible();
            uint256 claim = netCost <= resetDrawRefundPool ? netCost : resetDrawRefundPool;
            if (claim > 0) {
                p.resetRefundClaimedAtDraw = resetDrawRefundDraw; p.lastResetBoughtDraw1 = 0; p.lastResetTicketCost1 = 0;
                resetDrawRefundPool -= claim;
                if (p.isWeeklyOG) {
                    // [v2.27] B-1 FIX: grossEquiv computed before totalPaid decrement.
                    // totalPaid was previously decremented by NET (claim); now GROSS (grossEquiv)
                    // for symmetry with totalOGPrincipal and buyTickets (both use gross basis).
                    uint256 grossEquiv = claim * 10000 / (10000 - TREASURY_BPS);
                    if (p.totalPaid >= grossEquiv) p.totalPaid -= grossEquiv; else p.totalPaid = 0;
                    // [v1.3] totalOGPrincipal tracks gross (consistent with buyTickets += gross).
                    // [v2.15] flat TREASURY_BPS on all refund paths.
                    if (!p.weeklyOGStatusLost) { if (totalOGPrincipal >= grossEquiv) totalOGPrincipal -= grossEquiv; else totalOGPrincipal = 0; }
                }
                _withdrawAndTransfer(msg.sender, claim);
                emit ResetRefundClaimed(msg.sender, resetDrawRefundDraw, claim);
                if (claim < netCost) emit ResetRefundPartial(msg.sender, resetDrawRefundDraw, claim, netCost);
                return;
            }
            if (!eligiblePool2) revert NothingToClaim();
        }
        if (eligiblePool2) {
            uint256 costForCalc = (p.lastResetBoughtDraw2 == resetDrawRefundDraw2) ? p.lastResetTicketCost2 : p.lastTicketCost;
            uint256 netCost = costForCalc * (10000 - TREASURY_BPS) / 10000;
            if (netCost == 0) revert ResetRefundNotEligible();
            uint256 claim = netCost <= resetDrawRefundPool2 ? netCost : resetDrawRefundPool2;
            if (claim == 0) revert NothingToClaim();
            p.resetRefundClaimedAtDraw2 = resetDrawRefundDraw2; p.lastResetBoughtDraw2 = 0; p.lastResetTicketCost2 = 0;
            resetDrawRefundPool2 -= claim;
            // [v1.69] This isWeeklyOG block also fires for status-lost OGs who claimed
            // via the casual path above. weeklyOGCount was already decremented in
            // _processMatchesCore() on the draw they lost status -- no double-decrement here.
            if (p.isWeeklyOG) {
                // [v2.27] B-1 FIX: grossEquiv2 computed before totalPaid decrement (pool2 path).
                uint256 grossEquiv2 = claim * 10000 / (10000 - TREASURY_BPS);
                if (p.totalPaid >= grossEquiv2) p.totalPaid -= grossEquiv2; else p.totalPaid = 0;
                // [v1.3] Gross tracking -- flat TREASURY_BPS on all draws.
                if (!p.weeklyOGStatusLost) { if (totalOGPrincipal >= grossEquiv2) totalOGPrincipal -= grossEquiv2; else totalOGPrincipal = 0; }
            }
            _withdrawAndTransfer(msg.sender, claim);
            emit ResetRefundClaimed(msg.sender, resetDrawRefundDraw2, claim);
            if (claim < netCost) emit ResetRefundPartial(msg.sender, resetDrawRefundDraw2, claim, netCost);
        }
    }

    /// @notice Claims refund of pregame commitment if OG registration was cancelled.
    function claimCommitmentRefund() external nonReentrant {
        if (commitmentRefundPool == 0) revert NothingToClaim();
        if (commitmentRefundDeadline > 0 && block.timestamp > commitmentRefundDeadline) revert ResetRefundExpired();
        PlayerData storage p = players[msg.sender];
        if (!p.commitmentPaid) revert ResetRefundNotEligible();
        // [v1.57-P2] Commitment was paid pre-game at TREASURY_BPS (25%) [CRE v0.6 NS]. No graduated rate.
        uint256 claimAmount = p.commitmentDouble ? TICKET_PRICE * 2 * (10000 - TREASURY_BPS) / 10000 : TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
        uint256 claim = claimAmount <= commitmentRefundPool ? claimAmount : commitmentRefundPool;
        if (claim == 0) revert NothingToClaim();
        if (p.lastBoughtDraw == 0 && neverPlayedCommitmentCount > 0) neverPlayedCommitmentCount--;
        if (commitmentPaidCount > 0) commitmentPaidCount--;
        p.commitmentPaid = false;
        if (committedPlayerCount > 0) committedPlayerCount--;
        if (p.commitmentDouble) { p.commitmentDouble = false; if (committedDoubleCount > 0) committedDoubleCount--; }
        // [v2.34 L-02] Decrement totalPaid by GROSS (matching v2.27 B-1 convention).
        // claim is NET (75% of commitment at TREASURY_BPS 2500). [CRE v0.9 / IC-L-02: was
        // stale "85%" from the 15% treasury era.] totalPaid tracks GROSS. Use grossEquiv with floor.
        uint256 commitGrossEquiv = claim * 10000 / (10000 - TREASURY_BPS);
        if (p.totalPaid >= commitGrossEquiv) p.totalPaid -= commitGrossEquiv; else p.totalPaid = 0;
        commitmentRefundPool -= claim;
        _withdrawAndTransfer(msg.sender, claim);
        emit CommitmentRefundClaimed(msg.sender, claim);
        if (claim < claimAmount) emit CommitmentRefundPartial(msg.sender, claim, claimAmount);
    }

    /// @notice Sweeps expired reset refund pools and expired commitment refund pool
    ///         back to prizePot (ACTIVE) or protocol beneficiary (CLOSED/DORMANT).
    ///         Sweeps: resetDrawRefundPool (pool 1), resetDrawRefundPool2 (pool 2),
    ///         and commitmentRefundPool. Each swept independently on expiry.
    ///         Permissionless -- any caller may trigger once the window expires.
    /// @dev Intentionally permissionless -- any caller may trigger the sweep once the window expires.
    ///      Economic outcome is identical regardless of caller. Permissionless design avoids
    ///      permanent lock if owner becomes unavailable before the 30-day window expires.
    function sweepResetRefundRemainder() external nonReentrant {
        bool tp1 = resetDrawRefundDraw != 0 && block.timestamp > resetDrawRefundDeadline;
        bool tp2 = resetDrawRefundDraw2 != 0 && block.timestamp > resetDrawRefundDeadline2;
        bool tpc = commitmentRefundPool > 0 && commitmentRefundDeadline > 0 && block.timestamp > commitmentRefundDeadline;
        if (!tp1 && !tp2 && !tpc) revert NothingToClaim();
        if (tp1) {
            uint256 remainder = resetDrawRefundPool; uint256 closedDraw = resetDrawRefundDraw;
            resetDrawRefundPool = 0; resetDrawRefundDraw = 0; resetDrawRefundDeadline = 0;
            if (remainder > 0) { if (gamePhase == GamePhase.DORMANT || gamePhase == GamePhase.CLOSED) { _withdrawAndTransfer(PROTOCOL_BENEFICIARY, remainder); } else { prizePot += remainder; } }
            emit ResetRefundExpiredSwept(closedDraw, remainder);
        }
        if (tp2) {
            uint256 remainder2 = resetDrawRefundPool2; uint256 closedDraw2 = resetDrawRefundDraw2;
            resetDrawRefundPool2 = 0; resetDrawRefundDraw2 = 0; resetDrawRefundDeadline2 = 0;
            if (remainder2 > 0) { if (gamePhase == GamePhase.DORMANT || gamePhase == GamePhase.CLOSED) { _withdrawAndTransfer(PROTOCOL_BENEFICIARY, remainder2); } else { prizePot += remainder2; } }
            emit ResetRefundExpiredSwept(closedDraw2, remainder2);
        }
        if (tpc) {
            uint256 commitRemainder = commitmentRefundPool; uint256 savedCommitDraw = commitmentRefundDraw;
            commitmentRefundPool = 0; commitmentRefundDraw = 0; commitmentRefundDeadline = 0;
            if (commitRemainder > 0) { if (gamePhase == GamePhase.DORMANT || gamePhase == GamePhase.CLOSED) { _withdrawAndTransfer(PROTOCOL_BENEFICIARY, commitRemainder); } else { prizePot += commitRemainder; } }
            emit CommitmentRefundExpiredSwept(savedCommitDraw, commitRemainder);
        }
    }

    /// @notice Marks a player as lapsed (missed buy and not an active OG). Owner only.
    /// @param player  Address of the player to mark as lapsed.
    function markLapsed(address player) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        PlayerData storage p = players[player];
        if (p.lastBoughtDraw == 0) revert NothingToClaim();
        if (p.isUpfrontOG) revert AlreadyOG();
        if (p.isWeeklyOG && !p.weeklyOGStatusLost) revert AlreadyOG();
        if (p.isLapsed) revert NothingToClaim();
        if (p.lastBoughtDraw >= currentDraw) revert NothingToClaim();
        p.isLapsed = true; lapsedPlayerCount++;
        emit PlayerLapsed(player, currentDraw);
    }

    /// @notice Marks a batch of players as lapsed in a single owner call. ACTIVE phase only.
    /// @dev Reimplements markLapsed() logic inline for gas efficiency.
    ///      Phase and drawPhase checks fire once before the loop, not per-address.
    /// @param playerList  Addresses to mark as lapsed.
    function batchMarkLapsed(address[] calldata playerList) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (playerList.length > MAX_LAPSE_BATCH) revert ExceedsLimit();
        uint256 len = playerList.length;
        for (uint256 i = 0; i < len; i++) {
            PlayerData storage p = players[playerList[i]];
            if (p.lastBoughtDraw == 0) continue;
            if (p.isUpfrontOG) continue;
            if (p.isWeeklyOG && !p.weeklyOGStatusLost) continue;
            if (p.isLapsed) continue;
            if (p.lastBoughtDraw >= currentDraw) continue;
            p.isLapsed = true; lapsedPlayerCount++;
            emit PlayerLapsed(playerList[i], currentDraw);
        }
    }

    /// @notice Claims accumulated draw prizes owed to the caller.
    /// @dev    WARNING: if sweepUnclaimedPrizes() has been called, prizesSweepComplete
    ///         is permanently true and this function reverts NothingToClaim() for ALL
    ///         callers. Individual p.unclaimedPrizes balances remain non-zero on-chain
    ///         but are permanently unclaimable. Frontends must check prizesSweepComplete
    ///         before displaying or allowing claim of any unclaimedPrizes balance.
    function claimPrize() external nonReentrant {
        if (prizesSweepComplete) revert NothingToClaim();
        PlayerData storage p = players[msg.sender];
        uint256 amount = p.unclaimedPrizes;
        if (amount == 0) revert NothingToClaim();
        p.unclaimedPrizes = 0;
        if (totalUnclaimedPrizes >= amount) { totalUnclaimedPrizes -= amount; }
        else { emit AccountingDiscrepancy(totalUnclaimedPrizes, amount); totalUnclaimedPrizes = 0; }
        _withdrawAndTransfer(msg.sender, amount);
        // [v2.03] B-2.02-02: full getSolvencyStatus set -- claimPrize is callable in ACTIVE,
        // DORMANT, and CLOSED. In ACTIVE: prizePot, tierPools, draw30BonusFund are non-zero.
        // SYNC: mirrors getSolvencyStatus pool list.
        { uint256 _b = IERC20(USDC).balanceOf(address(this));
          uint256 _tierTotal;
          for (uint256 i = 0; i < 3; i++) _tierTotal += tierPools[i];
          uint256 _a = prizePot + totalUnclaimedPrizes + treasuryBalance + endgameOwed
              + dormancyOGPool + dormancyCasualRefundPool + dormancyCommitmentPool
              + dormancyPerHeadPool + dormancyVCPool + vcReturnOwed + vcBonusEscrow  // [CRE v0.3/v0.4 / SYNC]
              + _tierTotal + currentDrawSeedReturn
              + resetDrawRefundPool + resetDrawRefundPool2 + commitmentRefundPool
              + totalForceDeclineRefundOwed + draw30BonusFund;
          if (_b + SOLVENCY_TOLERANCE < _a) emit SolvencyAlert(_a, _b, "claimPrize"); }
        emit PrizeClaimed(msg.sender, amount);
    }

    /// @notice Withdraws accumulated treasury balance to a recipient address. Owner only.
    /// @dev [v1.0] Treasury accrues from multiple sources. [CRE v0.1] All rates are now flat 25% (2500 BPS).
    ///      Prior comment listed 15% active-draw, 15% pregame, 15% weekly OG, 10% upfront OG, 10% cancellation.
    ///      All are now TREASURY_BPS (2500) or UF_OG_TREASURY_BPS (2500) — same value. Stale rates removed.
    ///      [CRE v0.5 / NS] Updated.
    ///      Amount must not exceed treasuryBalance. recipient cannot be zero address.
    ///      [v2.06] TreasuryLocked reverts when (!gameSettled && prizePot < requiredEndPot).
    ///      requiredEndPot is the geometric solver OG floor:
    ///      ogEndgameObligation * targetReturnBps / 10000 + DRAW30_PRIZE_RESERVE + (VC_SEED - seedReleased). [CRE v0.9 / NS-L-01]
    ///      Treasury unlocks when pot recovers above requiredEndPot, or when gameSettled = true
    ///      (set by closeGame(), sweepDormancyRemainder(), or sweepFailedPregame()).
    ///      [v2.34 L-01] Also reverts unconditionally during PREGAME -- requiredEndPot is 0
    ///      before startGame() so the pot<floor gate cannot fire; PREGAME gate protects
    ///      claimSignupRefund() and cancelOGRegistration() treasury backstops. [v2.35 NS-L-01]
    /// @notice [CRE v1.06 / VC-SPENT-RETURN] Treasury owed to the VC for SPENT seed, at close.
    /// @dev Returns 0 when no seed has been released (nothing spent) or VC disabled. Otherwise:
    ///      seedReleased (reconstitute the spent principal, since released seed went to players)
    ///      + VC_SPENT_RETURN_BPS of seedReleased (flat 25% return)
    ///      + VC_SPENT_BONUS_BPS of seedReleased if cumulativeSeasonTreasury >= VC_SPENT_BONUS_THRESHOLD.
    ///      This is the TRUE amount paid at close. The withdraw lock reserves this * (1 + buffer);
    ///      the buffer is never paid to the VC. UNSPENT seed is returned separately from the pot.
    ///      Solvency: bounded by MAX_SEED_RELEASE_RATIO_BPS so this never exceeds treasury earned
    ///      (see the constructor VC-SPENT-CAP guard). Grows only as seed is spent, in step with the
    ///      treasury that funds it.
    /// @dev  NOTE [review pt4]: the bonus threshold reads cumulativeSeasonTreasury, which counts only
    ///      ACTIVE-DRAW ticket treasury slices, not the pregame/OG treasury slices. A heavily
    ///      OG-funded season can therefore earn a large treasury yet stay under the bonus threshold.
    ///      This is intentional (the bonus rewards in-play season size), not a bug; widen the counter
    ///      only if the term sheet intends OG funding to count toward the bonus.
    function _vcTreasuryObligation() internal view returns (uint256) {
        if (VC_SEED == 0 || seedReleased == 0) return 0;
        uint256 _ret   = seedReleased * VC_SPENT_RETURN_BPS / 10000;
        uint256 _bonus = cumulativeSeasonTreasury >= VC_SPENT_BONUS_THRESHOLD
            ? seedReleased * VC_SPENT_BONUS_BPS / 10000 : 0;
        return seedReleased + _ret + _bonus;
    }

    /// @notice Withdraws accrued treasury to a recipient. Owner only. Gated by VC + OG protections.
    function withdrawTreasury(uint256 amount, address recipient) external onlyOwner nonReentrant {
        if (amount == 0 || amount > treasuryBalance) revert InsufficientBalance();
        if (recipient == address(0)) revert InvalidAddress();
        // [CRE v1.08 / WITHDRAW-WINDOW] Protocol eats last: no treasury withdrawal until after
        // WITHDRAW_START_DRAW while the game is live. A value layer and a little extra margin, not
        // the solvency mechanism (the releasable reserve below is). Skipped once settled so the
        // protocol can take its share at close.
        if (!gameSettled && currentDraw <= WITHDRAW_START_DRAW) revert TreasuryLocked();
        // [CRE v0.6 / INFO-03] PREGAME guard moved to the top. Previously it sat below the
        // bonus-protection block, so a pregame withdrawal could revert TreasuryBonusProtected
        // (bonus path) instead of TreasuryLocked for the same underlying condition. One
        // deterministic revert reason for a pregame withdrawal attempt now.
        // [v2.34 L-01] Block pregame treasury withdrawal. During PREGAME, requiredEndPot is 0
        // (not yet set by startGame()), so the pot<floor gate never fires. Two refund backstops
        // (claimSignupRefund, cancelOGRegistration) rely on treasuryBalance during PREGAME.
        if (gamePhase == GamePhase.PREGAME) revert TreasuryLocked();
        // [CRE v0.4 / SE-M-01] Protect the next tier's bonus that is not yet escrowed.
        // Once a tier crosses, the bonus is in vcBonusEscrow (not in treasuryBalance), so no
        // protection needed for already-crossed tiers. This guards the NEXT tier's obligation.
        // SE-L-01 note: cumulativeSeasonTreasury counts only active-draw ticket revenue (not
        // pregame slices), so it may be slightly lower than the denominator used by the VC
        // to evaluate tier proximity. Document in deployment terms.
        if (!gameSettled) {
            uint256 _nextBonus = 0;
            if (VC_BONUS_TIER1_THRESHOLD > 0 && cumulativeSeasonTreasury < VC_BONUS_TIER1_THRESHOLD) {
                _nextBonus = VC_BONUS_TIER1_AMOUNT; // tier 1 not yet crossed — protect its full amount
            } else if (VC_BONUS_TIER2_THRESHOLD > 0 && cumulativeSeasonTreasury < VC_BONUS_TIER2_THRESHOLD) {
                _nextBonus = VC_BONUS_TIER2_AMOUNT > VC_BONUS_TIER1_AMOUNT
                    ? VC_BONUS_TIER2_AMOUNT - VC_BONUS_TIER1_AMOUNT : 0; // protect the delta only
            }
            if (_nextBonus > 0) {
                uint256 _remaining = treasuryBalance - amount;
                if (_remaining < _nextBonus) revert TreasuryBonusProtected(_nextBonus, _remaining);
            }
            // [CRE v1.06 / VC-SPENT-RETURN] Reserve the spent-seed obligation (principal
            // reconstitution + 25% return + big-season bonus) plus the 5% lock buffer. Treasury
            // may not be drained below this while the game runs, so the VC's spent seed and its
            // return are always there at close. The buffer is lock-only: the VC is paid the true
            // obligation at settlement (see closeGame), and the buffer returns to treasury.
            // [SA-5 fix] Reserve assumes the bonus is ALWAYS live (worst case, x1.5), not the
            // conditional current obligation. Otherwise a draw-down to the pre-bonus reserve
            // followed by cumulativeSeasonTreasury crossing VC_SPENT_BONUS_THRESHOLD would leave
            // treasury briefly below the bonus-inclusive need. The MAX_SEED_RELEASE_RATIO_BPS cap
            // was sized for this x1.5 case, so reserving it always is consistent and solvent.
            // [CRE v1.08 / RESERVE-FIX] Reserve against the seed RELEASABLE from accumulated
            // treasury at the MAX ratio, NOT seed already released. The old reserve watched
            // seedReleased, which is 0 before the release threshold is crossed (or before a
            // governance ratio rise), so an owner could drain treasury early; then a threshold
            // crossing dumped seed and created a VC obligation against an emptied treasury.
            // Fuzzing proved this insolvent (treasury up to ~$80k short). Sizing the reserve on
            // cumulativeSeasonTreasury * MAX_SEED_RELEASE_RATIO_BPS (the most that could ever be
            // released from what has been earned) closes it, and using the immutable MAX (not the
            // current governance ratio) makes it safe against drain-at-low-ratio-then-raise.
            // Re-fuzzed 60k cases with governance varying the ratio: zero insolvencies.
            if (VC_SEED > 0) {
                uint256 _releasable = cumulativeSeasonTreasury * MAX_SEED_RELEASE_RATIO_BPS / 10000;
                if (_releasable > VC_SEED) _releasable = VC_SEED;
                // [CRE v1.09 / RESERVE-TWEAK] Also cover seed ALREADY released beyond the ratio
                // estimate. The T3-floor top-up can release a little seed in the early draws
                // before cumulativeSeasonTreasury has grown, so the ratio-estimate alone would
                // under-reserve it. Watching the greater of the estimate and the actual released
                // amount covers every release path. Proven 0 insolvencies with the top-up in fuzz.
                if (seedReleased > _releasable) _releasable = seedReleased;
                uint256 _vcReserveMax = _releasable
                    * (10000 + VC_SPENT_RETURN_BPS + VC_SPENT_BONUS_BPS) / 10000
                    * (10000 + VC_RESERVE_BUFFER_BPS) / 10000;
                if (_vcReserveMax > 0) {
                    uint256 _remain2 = treasuryBalance - amount;
                    if (_remain2 < _vcReserveMax) revert TreasuryBonusProtected(_vcReserveMax, _remain2);
                }
            }
        }
        // TreasuryLocked: treasury is sealed while prizePot < requiredEndPot and game
        // is not settled. Protects OG principal -- treasury cannot be drained ahead of the
        // pot covering what OGs paid in. Unlocks automatically when pot recovers or on settlement.
        // [v2.05] Use requiredEndPot (geometric solver floor) not totalOGPrincipal.
        // totalOGPrincipal grows +$20/draw per active WOG -- by draw 15 it far exceeds
        // the actual solvency target, locking legitimate treasury access unnecessarily.
        if (!gameSettled && prizePot < requiredEndPot) revert TreasuryLocked();
        treasuryBalance -= amount; totalTreasuryWithdrawn += amount;
        _withdrawAndTransfer(recipient, amount);
        emit TreasuryWithdrawal(amount, recipient);
    }


    // ── Governance (inherited unchanged) ──────────────────────────────────────

    /// @notice Proposes a prize rate reduction with 48h timelock. Owner only.
    /// @param newMultiplier  New prize rate multiplier BPS (< current). Min 5000 (50% of normal).
    /// @param reason         Bytes32 reason code emitted in event for monitoring.
    function proposePrizeRateReduction(uint256 newMultiplier, bytes32 reason) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (newMultiplier >= prizeRateMultiplier) revert CanOnlyDecrease();
        if (newMultiplier < 5000) revert BelowMinimum();
        if (pendingMultiplier != 0) revert TimelockPending();
        pendingMultiplier = newMultiplier; pendingMultiplierReason = reason; multiplierEffectiveTime = block.timestamp + PRIZE_RATE_TIMELOCK;
        emit PrizeRateReductionProposed(newMultiplier, multiplierEffectiveTime, reason);
    }
    /// @notice Executes a pending prize rate reduction after the timelock. Owner only.
    function executePrizeRateReduction() external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (pendingMultiplier == 0) revert NoTimelockPending();
        if (pendingMultiplier >= prizeRateMultiplier) revert WrongPhase();
        if (block.timestamp < multiplierEffectiveTime) revert TooEarly();
        uint256 old = prizeRateMultiplier; prizeRateMultiplier = pendingMultiplier; lastMultiplierChangeReason = pendingMultiplierReason;
        pendingMultiplier = 0; pendingMultiplierReason = 0; multiplierEffectiveTime = 0;
        emit PrizeRateReductionExecuted(old, prizeRateMultiplier, lastMultiplierChangeReason);
    }
    /// @notice Cancels a pending prize rate reduction proposal. Owner only.
    function cancelPrizeRateReduction() external onlyOwner {
        if (pendingMultiplier == 0) revert NoTimelockPending();
        if (pendingMultiplier >= prizeRateMultiplier) revert WrongPhase();
        pendingMultiplier = 0; pendingMultiplierReason = 0; multiplierEffectiveTime = 0;
        emit PrizeRateReductionCancelled();
    }
    /// @notice Cancels a pending prize rate increase proposal. Owner only.
    function cancelPrizeRateIncrease() external onlyOwner {
        if (pendingMultiplier == 0) revert NoTimelockPending();
        if (pendingMultiplier <= prizeRateMultiplier) revert WrongPhase();
        pendingMultiplier = 0; pendingMultiplierReason = 0; multiplierEffectiveTime = 0;
        emit PrizeRateIncreaseCancelled();
    }
    /// @notice Proposes a prize rate increase with 48h timelock. Owner only.
    /// @param newMultiplier  New prize rate multiplier BPS (> current). Max 10000.
    /// @param reason         Bytes32 reason code emitted in event for monitoring.
    // [v1.90] obligationLocked guard is always satisfied post-startGame (set true at
    // startGame(), never cleared). Guard retained for defensive clarity. See cover letter.
    function proposePrizeRateIncrease(uint256 newMultiplier, bytes32 reason) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (!obligationLocked) revert WrongPhase();
        if (newMultiplier <= prizeRateMultiplier) revert WrongPhase();
        if (newMultiplier > 10000) revert ExceedsLimit();
        if (pendingMultiplier != 0) revert TimelockPending();
        pendingMultiplier = newMultiplier; pendingMultiplierReason = reason; multiplierEffectiveTime = block.timestamp + PRIZE_RATE_TIMELOCK;
        emit PrizeRateIncreaseProposed(newMultiplier, multiplierEffectiveTime, reason);
    }
    /// @notice Executes a pending prize rate increase after the timelock. Owner only.
    function executePrizeRateIncrease() external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (pendingMultiplier == 0) revert NoTimelockPending();
        if (pendingMultiplier <= prizeRateMultiplier) revert WrongPhase();
        if (block.timestamp < multiplierEffectiveTime) revert TooEarly();
        uint256 old = prizeRateMultiplier; prizeRateMultiplier = pendingMultiplier; lastMultiplierChangeReason = pendingMultiplierReason;
        pendingMultiplier = 0; pendingMultiplierReason = 0; multiplierEffectiveTime = 0;
        emit PrizeRateIncreaseExecuted(old, prizeRateMultiplier, lastMultiplierChangeReason);
    }
    /// @notice Proposes an override of the breath multiplier with 7-day timelock. Owner only.
    /// @dev [v2.01] UP-direction proposals revert PotBelowTrajectory when pot health
    ///      (prizePot * 10000 / requiredEndPot) < 8000 (below 80%). Same gate fires
    ///      at executeBreathOverride. See also: exhaleFloorReleaseBps threshold (120%)
    ///      which governs auto-adjust floor releases -- two independent pot-health
    ///      thresholds operate simultaneously.
    /// @param newMultiplier  New breathMultiplier BPS. Must be within [breathRailMin, breathRailMax].
    /// @param reason         Bytes32 reason code emitted in event for monitoring.
    function proposeBreathOverride(uint256 newMultiplier, bytes32 reason) external onlyOwner nonReentrant {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        _captureYield();
        if (newMultiplier < breathRailMin || newMultiplier > breathRailMax) revert ExceedsLimit();
        if (newMultiplier == breathMultiplier) revert BreathUnchanged();
        if (pendingBreathOverride != 0) revert TimelockPending();
        if (newMultiplier > breathMultiplier) { if (obligationLocked && requiredEndPot > 0 && prizePot * 10000 / requiredEndPot < 8000) revert PotBelowTrajectory(); }
        pendingBreathOverride = newMultiplier; pendingBreathOverrideReason = reason; breathOverrideEffectiveTime = block.timestamp + TIMELOCK_DELAY;
        emit BreathOverrideProposed(newMultiplier, breathOverrideEffectiveTime, reason);
    }
    /// @notice Executes a pending breath override after the timelock. Owner only.
    /// @dev UP-direction overrides re-check pot health < 80% at execution time
    ///      (same PotBelowTrajectory guard as proposeBreathOverride). If pot health
    ///      dropped below 80% between proposal and execution, the execute reverts.
    function executeBreathOverride() external onlyOwner nonReentrant {
        if (pendingBreathOverride == 0) revert NoTimelockPending();
        if (block.timestamp < breathOverrideEffectiveTime) revert TooEarly();
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        _captureYield();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        uint256 oldMultiplier = breathMultiplier; uint256 newMultiplier = pendingBreathOverride;
        if (newMultiplier < breathRailMin || newMultiplier > breathRailMax) revert ExceedsLimit();
        if (newMultiplier > oldMultiplier) { if (obligationLocked && requiredEndPot > 0 && prizePot * 10000 / requiredEndPot < 8000) revert PotBelowTrajectory(); }
        breathMultiplier = newMultiplier; lastBreathAdjustDraw = currentDraw;
        lastBreathOverrideReason = pendingBreathOverrideReason;
        pendingBreathOverride = 0; pendingBreathOverrideReason = bytes32(0); breathOverrideEffectiveTime = 0;
        breathOverrideLockUntilDraw = currentDraw + BREATH_COOLDOWN_DRAWS;
        emit BreathMultiplierAdjusted(oldMultiplier, newMultiplier, newMultiplier > oldMultiplier);
        emit BreathOverrideExecuted(oldMultiplier, newMultiplier, lastBreathOverrideReason);
    }
    /// @notice Cancels a pending breath override proposal. Owner only.
    function cancelBreathOverride() external onlyOwner {
        if (pendingBreathOverride == 0) revert NoTimelockPending();
        uint256 cancelled = pendingBreathOverride; pendingBreathOverride = 0; pendingBreathOverrideReason = bytes32(0); breathOverrideEffectiveTime = 0;
        emit BreathOverrideCancelled(cancelled);
    }
    /// @notice Proposes new breath rail bounds. Owner only. 7-day timelock.
    /// @dev newMin must be >= ABSOLUTE_BREATH_FLOOR (100 bps). newMax must be <= ABSOLUTE_BREATH_CEILING (2000 bps).
    ///      [v1.61] Setting a low breathRailMax can reduce draw-1 T3 prizes.
    ///      _computeStartingBreath() calibrates initial breath to target T3 near TICKET_PRICE.
    ///      If breathRailMax < t3FloorBreath (output of _computeStartingBreath,
    ///      see step 3 of startGame()) the calibration target cannot be met.
    ///      At default breathRailMax=1500 the target is achievable at normal parameters.
    /// @param newMin   New minimum breath BPS. Must be >= ABSOLUTE_BREATH_FLOOR (100).
    /// @param newMax   New maximum breath BPS. Must be <= ABSOLUTE_BREATH_CEILING (2000)
    ///                 and strictly > newMin.
    ///                 Equal rails (newMax == newMin) are NOT permitted here -- they would
    ///                 bypass the geometric solver and are rejected with ExceedsLimit().
    ///                 Use proposeBreathOverride() for fixed-rate mode instead.
    /// @param reason   Bytes32 reason code emitted in BreathRailsProposed. Not stored on-chain.
    function proposeBreathRails(uint256 newMin, uint256 newMax, bytes32 reason) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (newMin < ABSOLUTE_BREATH_FLOOR) revert BelowMinimum();
        if (newMax > ABSOLUTE_BREATH_CEILING) revert ExceedsLimit();
        // Strict inequality: equal rails force breathMultiplier to a single fixed point,
        // bypassing the geometric solver for the rest of the season. For an intentional
        // emergency fixed-rate mode, use proposeBreathOverride() instead.
        if (newMax <= newMin) revert ExceedsLimit();
        if (newMin == breathRailMin && newMax == breathRailMax) revert BreathUnchanged();
        if (breathRailsEffectiveTime != 0) revert TimelockPending();
        pendingBreathRailMin = newMin; pendingBreathRailMax = newMax; breathRailsEffectiveTime = block.timestamp + TIMELOCK_DELAY;
        emit BreathRailsProposed(newMin, newMax, breathRailsEffectiveTime, reason);
    }
    /// @notice Cancels a pending breath rails proposal. Owner only.
    function cancelBreathRails() external onlyOwner {
        if (breathRailsEffectiveTime == 0) revert NoTimelockPending();
        uint256 cMin = pendingBreathRailMin; uint256 cMax = pendingBreathRailMax;
        pendingBreathRailMin = 0; pendingBreathRailMax = 0; breathRailsEffectiveTime = 0;
        emit BreathRailsProposalCancelled(cMin, cMax);
    }
    /// @notice Executes pending breath rail bounds after the timelock. Owner only.
    function executeBreathRails() external onlyOwner {
        if (breathRailsEffectiveTime == 0) revert NoTimelockPending();
        if (block.timestamp < breathRailsEffectiveTime) revert TooEarly();
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        uint256 newMin = pendingBreathRailMin; uint256 newMax = pendingBreathRailMax;
        pendingBreathRailMin = 0; pendingBreathRailMax = 0; breathRailsEffectiveTime = 0;
        if (breathMultiplier < newMin) { emit BreathMultiplierAdjusted(breathMultiplier, newMin, true); breathMultiplier = newMin; lastBreathAdjustDraw = currentDraw; }
        else if (breathMultiplier > newMax) { emit BreathMultiplierAdjusted(breathMultiplier, newMax, false); breathMultiplier = newMax; lastBreathAdjustDraw = currentDraw; }
        breathRailMin = newMin; breathRailMax = newMax;
        emit BreathRailsUpdated(newMin, newMax, currentDraw);
        if (pendingBreathOverride != 0 && (pendingBreathOverride < newMin || pendingBreathOverride > newMax || pendingBreathOverride == breathMultiplier)) {
            uint256 cancelled = pendingBreathOverride; pendingBreathOverride = 0; pendingBreathOverrideReason = bytes32(0); breathOverrideEffectiveTime = 0;
            emit BreathOverrideCancelled(cancelled);
        }
    }
    /// @notice Proposes a primary price feed change with 7-day timelock. Owner only.
    /// @param newFeed  Address of the new primary ETH/USD Chainlink feed (8 decimals required).
    function proposeFeedChange(address newFeed) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (newFeed == address(0) || newFeed == USDC || newFeed == address(this)) revert InvalidAddress();
        if (newFeed == SEQUENCER_FEED && SEQUENCER_FEED != address(0)) revert InvalidAddress();
        if (newFeed == ethFeed) revert FeedUnchanged();
        if (newFeed == ethReserveFeed) revert FeedUnchanged();
        if (newFeed == wethFeed) revert FeedUnchanged();
        if (pendingEthFeedChange.effectiveTime != 0) revert TimelockPending();
        try AggregatorV3Interface(newFeed).decimals() returns (uint8 dec) { if (dec != 8) revert FeedDecimalsMismatch(); } catch { revert FeedDecimalsMismatch(); }
        pendingEthFeedChange = PendingFeedChange(newFeed, block.timestamp + TIMELOCK_DELAY);
        emit FeedChangeProposed(newFeed, block.timestamp + TIMELOCK_DELAY);
    }
    /// @notice Executes a pending feed change after the 7-day timelock. Owner only.
    function executeFeedChange() external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (pendingEthFeedChange.effectiveTime == 0) revert NoTimelockPending();
        if (block.timestamp < pendingEthFeedChange.effectiveTime) revert TooEarly();
        address oldFeed = ethFeed;
        // [CRE v1.11a / GOV-02] Re-validate decimals at execute for parity with the breath paths.
        try AggregatorV3Interface(pendingEthFeedChange.newFeed).decimals() returns (uint8 dec) { if (dec != 8) revert FeedDecimalsMismatch(); } catch { revert FeedDecimalsMismatch(); }
        ethFeed = pendingEthFeedChange.newFeed;
        lastValidPrice = 0; autoDefaultCents = 0;
        emit FeedChangeExecuted(oldFeed, ethFeed);
        delete pendingEthFeedChange;
    }
    /// @notice Cancels a pending feed change proposal. Owner only.
    function cancelFeedChange() external onlyOwner {
        if (pendingEthFeedChange.effectiveTime == 0) revert NoTimelockPending();
        emit FeedChangeCancelled();
        delete pendingEthFeedChange;
    }

    // ── Emergency reset ───────────────────────────────────────────────────────

    /// @dev [v1.0] CUTOFF_SUBMISSION handled: if stuck past DRAW_STUCK_TIMEOUT,
    ///      owner can call emergencyResetDraw() to reset. Same timeout applies.
    ///      Cutoff state (t1/t2/t3CutoffDiff, snapshotTotalEntries) cleared on reset.
    ///      tierPools loop uses i<3 (not i<4). p4Winners.slot clear REMOVED.
    /// @notice Initiates an emergency draw reset. VOIDS the current draw: rolls back its
    ///         distribution/accounting and unwinds OG status changes. [CRE v0.9 / NS-I-02]
    ///         The draw number is CONSUMED, not re-run under the same number -- at
    ///         reset-finalize the schedule re-anchors and currentDraw advances. "Replay"
    ///         elsewhere refers to the next draw proceeding, not a repeat of the voided one.
    ///         Owner only EXCEPT during UNWINDING phase: after UNWIND_CONTINUATION_TIMEOUT
    ///         (7 days) any address may call to continue the unwind. This permissionless
    ///         continuation prevents permanent lock if owner is unavailable mid-unwind.
    function emergencyResetDraw() external nonReentrant {
        if (drawPhase == DrawPhase.UNWINDING) {
            if (msg.sender != owner()) { if (block.timestamp < phaseStartTimestamp + UNWIND_CONTINUATION_TIMEOUT) revert TooEarly(); }
            _continueUnwind(); return;
        }
        if (msg.sender != owner()) revert OwnableUnauthorizedAccount(msg.sender);
        if (gamePhase != GamePhase.ACTIVE) revert GameNotActive();
        if (drawPhase == DrawPhase.IDLE) revert NotStuck();
        if (drawPhase == DrawPhase.FINALIZING || drawPhase == DrawPhase.RESET_FINALIZING) revert WrongPhase();
        if (block.timestamp < phaseStartTimestamp + DRAW_STUCK_TIMEOUT) revert TooEarly();
        uint256 amountReturned;
        // [v1.0] 3 tier pools only (i<3).
        for (uint256 i = 0; i < 3; i++) {
            if (tierPools[i] > 0) {
                uint256 alreadyPaid = (i == distTierIndex) ? distWinnerIndex * currentTierPerWinner : 0;
                uint256 remaining = tierPools[i] > alreadyPaid ? tierPools[i] - alreadyPaid : 0;
                amountReturned += remaining; prizePot += remaining; tierPools[i] = 0;
            }
        }
        currentTierPerWinner = 0;
        if (currentDrawSeedReturn > 0) { amountReturned += currentDrawSeedReturn; prizePot += currentDrawSeedReturn; currentDrawSeedReturn = 0; }
        // [CRE v0.8 / CR-L-01] Seed rollback block REMOVED. seedReleased is no longer
        // incremented in _calculatePrizePools(); it is deferred to _finalizeWeekCore()
        // (skipped on reset-finalize). A reset therefore never counted this draw's supplement
        // as released, so there is nothing to roll back. The prior full-rollback here
        // over-corrected when a reset fired mid-DISTRIBUTING after partial credit, desyncing
        // seedReleased. currentDrawSeedSupplement is still cleared in the reset cleanup below.
        // [v1.68] Roll back bonus contribution from failed draw -- prevents double-accumulation on replay.
        // [v1.69] currentDrawBonusContribution is cleared in the reset cleanup below
        // and again by _finalizeWeekCore at end of unwind. Both are intentional:
        // the cleanup section fires immediately; _finalizeWeekCore is the backstop.
        if (currentDrawBonusContribution > 0) {
            if (draw30BonusFund >= currentDrawBonusContribution) draw30BonusFund -= currentDrawBonusContribution;
            else draw30BonusFund = 0;
            prizePot += currentDrawBonusContribution;
            amountReturned += currentDrawBonusContribution;
        }
        emergencyUnwindTotal = ogList.length; emergencyUnwindIndex = 0; lastResetDraw = currentDraw;
        resolvedPrice = 0;
        // [v1.0] Clear cutoff state on emergency reset.
        t1CutoffDiff = 0; t2CutoffDiff = 0; t3CutoffDiff = 0; snapshotTotalEntries = 0;
        if (pendingBreathOverride != 0) { uint256 cancelled = pendingBreathOverride; pendingBreathOverride = 0; pendingBreathOverrideReason = bytes32(0); breathOverrideEffectiveTime = 0; emit BreathOverrideCancelled(cancelled); }
        if (breathRailsEffectiveTime != 0) { uint256 cMin = pendingBreathRailMin; uint256 cMax = pendingBreathRailMax; pendingBreathRailMin = 0; pendingBreathRailMax = 0; breathRailsEffectiveTime = 0; emit BreathRailsProposalCancelled(cMin, cMax); }
        if (dormancyEffectiveTime != 0) { dormancyEffectiveTime = 0; emit DormancyCancelled(); }
        if (pendingMultiplier != 0) { bool isReduction = pendingMultiplier < prizeRateMultiplier; pendingMultiplier = 0; pendingMultiplierReason = bytes32(0); multiplierEffectiveTime = 0; if (isReduction) emit PrizeRateReductionCancelled(); else emit PrizeRateIncreaseCancelled(); }
        // [v1.77] Cancel pending exhale floor release and feed change on emergency reset.
        if (pendingExhaleFloorReleaseTime != 0) { uint256 c = pendingExhaleFloorReleaseBps; pendingExhaleFloorReleaseBps = 0; pendingExhaleFloorReleaseTime = 0; emit ExhaleFloorReleaseCancelled(c); }
        if (pendingEthFeedChange.effectiveTime != 0) { delete pendingEthFeedChange; emit FeedChangeCancelled(); }
        matchOGIndex = 0; matchNonOGIndex = 0; ogMatchingDone = false; distTierIndex = 0; distWinnerIndex = 0;
        if (currentDraw == 1 && committedPlayerCount > 0 && commitmentRefundPool == 0) {
            // safeDouble_: min() guards against committedDoubleCount > commitmentPaidCount
            // drift (counter divergence via edge-case paths). Prevents underflow in
            // singleCount_ subtraction (commitmentPaidCount - safeDouble_ >= 0 guaranteed).
            uint256 safeDouble_ = committedDoubleCount < commitmentPaidCount ? committedDoubleCount : commitmentPaidCount;
            uint256 singleCount_ = commitmentPaidCount > safeDouble_ ? commitmentPaidCount - safeDouble_ : 0;
            uint256 poolAmount = singleCount_ * TICKET_PRICE * (10000 - TREASURY_BPS) / 10000 + safeDouble_ * TICKET_PRICE * 2 * (10000 - TREASURY_BPS) / 10000;
            if (poolAmount > prizePot) poolAmount = prizePot;
            commitmentRefundPool = poolAmount; commitmentRefundDraw = 1; commitmentRefundDeadline = block.timestamp + RESET_REFUND_WINDOW;
            prizePot -= poolAmount; emit CommitmentRefundActivated(1, poolAmount);
        }
        if (currentDrawNetTicketTotal > 0) {
            uint256 poolAmount = currentDrawNetTicketTotal;
            if (poolAmount > prizePot) poolAmount = prizePot;
            if (resetDrawRefundDraw == 0) { resetDrawRefundPool = poolAmount; resetDrawRefundDraw = currentDraw; resetDrawRefundDeadline = block.timestamp + RESET_REFUND_WINDOW; prizePot -= poolAmount; }
            else if (resetDrawRefundDraw2 == 0) { resetDrawRefundPool2 = poolAmount; resetDrawRefundDraw2 = currentDraw; resetDrawRefundDeadline2 = block.timestamp + RESET_REFUND_WINDOW; prizePot -= poolAmount; emit ResetRefundOverflow(currentDraw, poolAmount); }
            else { emit ResetRefundSkipped(currentDraw, currentDrawNetTicketTotal); }
        }
        currentDrawTicketTotal = 0; currentDrawNetTicketTotal = 0; currentDrawCasualNetTicketTotal = 0;
        currentDrawWeeklyOGNetTicketTotal = 0; // [CRE v0.4 / DR-M-01] cleared on reset
        currentDrawWeeklyOGBuyerCount = 0;      // [CRE v0.7 / M-01] cleared on reset, paired
        currentDrawBonusContribution = 0; // [v1.68] rollback: prevent double-accumulation on reset replay
        currentDrawSeedSupplement = 0; // [CRE v0.8 / CR-L-01] cleared on reset so the deferred
                                       // finalize increment (skipped on reset-finalize) never sees
                                       // a stale value. No seedReleased rollback needed (see above).
        currentDrawT3FloorTopup = 0;   // [CRE v1.10] same: cleared on reset, never counted as released.
        // [v1.58-P3] breathSeedAccumulator reset removed (accumulator deprecated).
        _captureYield();
        // [v1.0] p4Winners.slot clear REMOVED -- p4Winners does not exist in this fork.
        assembly { sstore(jpWinners.slot, 0) sstore(p2Winners.slot, 0) sstore(p3Winners.slot, 0) sstore(weeklyNonOGPlayers.slot, 0) }
        DrawPhase fromPhase = drawPhase; phaseStartTimestamp = block.timestamp;
        emit EmergencyReset(currentDraw, fromPhase, amountReturned);
        if (emergencyUnwindTotal == 0) { drawPhase = DrawPhase.RESET_FINALIZING; emit EmergencyUnwindComplete(currentDraw, 0); }
        else { drawPhase = DrawPhase.UNWINDING; _continueUnwind(); }
    }

    /// @dev Gas-bounded restoration loop. Restores weekly OGs whose statusLostAtDraw == lastResetDraw.
    ///      Processes up to MAX_UNWIND_PER_TX entries per call. Permissionless after UNWIND_CONTINUATION_TIMEOUT.
    ///      OG principal restoration is symmetric: += p.totalPaid here, -= p.totalPaid in replayed
    ///      _processMatchesCore if they miss again. Net zero across reset+replay cycle.
    ///      Casual/commitment player protection is handled by resetDrawRefundPool and
    ///      commitmentRefundPool set in emergencyResetDraw() prior to this loop.
    ///      Streak: consecutiveWeeks preserved here (not written by this function).
    ///      _updateStreakTracking gap-detection fires on next buyTickets() -- if the
    ///      player misses a subsequent draw, streak resets to 1 regardless of whether
    ///      they have reached WEEKLY_OG_QUALIFICATION_WEEKS.
    function _continueUnwind() internal {
        if (gasleft() < 150_000) revert InsufficientGasForBatch();
        uint256 start = emergencyUnwindIndex;
        uint256 end = start + MAX_UNWIND_PER_TX;
        if (end > emergencyUnwindTotal) end = emergencyUnwindTotal;
        for (uint256 i = start; i < end; i++) {
            if (gasleft() < 50_000) { end = i; break; }
            address addr = ogList[i]; PlayerData storage p = players[addr];
            if (p.isWeeklyOG && p.weeklyOGStatusLost && p.statusLostAtDraw == lastResetDraw) { // [v1.54] L-05: explicit isWeeklyOG guard
                totalOGPrincipal += p.totalPaid;
                p.weeklyOGStatusLost = false; p.statusLostAtDraw = 0;
                emit PredictionResetOnUnwind(addr, lastResetDraw);
                weeklyOGCount++; earnedOGCount++;
                // Streak preserved (consecutiveWeeks not modified) -- status loss on
                // emergency reset is not player fault. Re-increment qualifiedWeeklyOGCount
                // for already-qualified OGs: _processMatchesCore() decremented it at status
                // loss, so this restores it symmetrically.
                // [CRE v0.11 / D4-M-01] Credit the voided draw into the streak. lastActiveWeek
                // alone (v0.10 Option B) stops the gap-detector wiping the streak, but the OG never
                // BOUGHT the voided draw and consecutiveWeeks only increments at buy time, so their
                // max reachable streak was 29 vs WEEKLY_OG_QUALIFICATION_WEEKS (30) -- still
                // unreachable. The miss was not player fault (operator voided the draw), so we count
                // it here as if bought. This increment MUST precede the qualifiedWeeklyOGCount check
                // below so a 29->30 crossing on restore is counted. Cap is natural: consecutiveWeeks
                // cannot exceed draws played+credited, and each reset credits exactly one distinct
                // voided draw (no double-credit across multi-reset seasons).
                // CONSEQUENCE (documented, intentional): EarnedOGQualified is NOT emitted on a
                // restore-path 29->30 crossing (it emits only from _updateStreakTracking on a buy).
                // qualifiedWeeklyOGCount is the source of truth and is incremented correctly below;
                // subgraphs must derive qualification from the count, not solely from the event.
                p.lastActiveWeek = lastResetDraw;
                p.consecutiveWeeks++;
                if (p.consecutiveWeeks >= WEEKLY_OG_QUALIFICATION_WEEKS) { qualifiedWeeklyOGCount++; }
                if (p.isLapsed) { p.isLapsed = false; if (lapsedPlayerCount > 0) lapsedPlayerCount--; emit PlayerUnlapsed(addr, lastResetDraw); }
            }
            // [v1.3] No mulligan unwind needed -- mulligan removed from BullsEth.
        }
        emergencyUnwindIndex = end;
        if (emergencyUnwindIndex >= emergencyUnwindTotal) { drawPhase = DrawPhase.RESET_FINALIZING; emit EmergencyUnwindComplete(lastResetDraw, emergencyUnwindTotal); }
        else { emit EmergencyUnwindBatch(lastResetDraw, emergencyUnwindIndex, emergencyUnwindTotal); }
    }

    // ── View functions ─────────────────────────────────────────────────────────

    /// @notice Returns full player state (14 values). See @dev for ABI change note.
    /// @dev [v1.3] ABI CHANGE from v1.2: mulliganUsedVal (bool) removed from return tuple.
    ///      Returns 14 values (was 15). Subgraphs and frontends must update their decoder.
    /// @return registered         True if register() was called.
    /// @return upfrontOG          True if active upfront OG.
    /// @return weeklyOG           True if active weekly OG.
    /// @return statusLost         True if weekly OG status was lost this season.
    /// @return prediction         Primary price prediction (USD cents) for current predictionDraw.
    /// @return prediction2        Secondary price prediction (USD cents).
    /// @return predictionDraw     Draw number for which primary prediction was last set.
    /// @return prediction2Draw    Draw number for which secondary prediction was last set.
    /// @return streak             Consecutive-week buy streak count.
    /// @return unclaimed          Unclaimed prize balance (USDC 6-dec).
    /// @return totalWon           Cumulative prizes won lifetime (USDC 6-dec).
    /// @return boughtThisWeek     True if tickets bought in currentDraw.
    /// @return totalPaid          Cumulative USDC paid to the contract (6-dec).
    /// @return qualifiedForEndgame True if currently eligible for claimEndgame().
    function getPlayerInfo(address addr) external view returns (
        bool registered, bool upfrontOG, bool weeklyOG, bool statusLost,
        uint256 prediction, uint256 prediction2, uint256 predictionDraw, uint256 prediction2Draw,
        uint256 streak, uint256 unclaimed, uint256 totalWon,
        bool boughtThisWeek, uint256 totalPaid, bool qualifiedForEndgame
    ) {
        PlayerData storage p = players[addr];
        return (
            p.registered, p.isUpfrontOG, p.isWeeklyOG, p.weeklyOGStatusLost,
            p.prediction, p.prediction2, p.predictionDraw, p.prediction2Draw,
            p.consecutiveWeeks, p.unclaimedPrizes, p.totalPrizesWon,
            p.lastBoughtDraw == currentDraw, p.totalPaid,
            _isQualifiedForEndgame(p) && dormancyTimestamp == 0 && !p.endgameClaimed
        );
    }

    /// @notice Returns true if the current draw resolution result has gone stale.
    /// @return  True if resolution is overdue (IDLE, lastResolvedDraw stale).
    ///          False during any non-IDLE phase regardless of resolvedPrice --
    ///          monitoring tools should check drawPhase independently.
    ///          Also returns true when currentDraw == 0 (PREGAME, no draws started yet).
    function isResultStale() external view returns (bool) {
        // draw-0 guard: prevents uint256 underflow on `currentDraw - 1` in the
        // general check below. NOT dead code -- PREGAME always has currentDraw==0.
        // Unlike the removed draw-1 guard, this is not superseded by the general check.
        if (currentDraw == 0) return true;
        // [v2.22] B-2.21-01: draw-1 early return removed (dead code). The general
        // check below covers it: at draw 1 with lastResolvedDraw==0,
        // (0!=0)||(resolvedPrice==0) = resolvedPrice==0 = true.
        // [v2.03] B-2.01-03 APPLIED: return false during in-flight draw phases.
        // Previously: lastResolvedDraw==currentDraw during MATCHING/DISTRIBUTING/
        // FINALIZING caused false-stale signals across the draw processing window.
        if (drawPhase != DrawPhase.IDLE) return false;
        return (lastResolvedDraw != currentDraw - 1) || (resolvedPrice == 0);
    }

    /// @notice Returns a comprehensive snapshot of current game state.
    /// @return gPhase       Current GamePhase enum value.
    /// @return dPhase       Current DrawPhase enum value.
    /// @return draw         Current draw number (0 = pre-game, 1-30 active).
    /// @return pot          Current prizePot (USDC 6-dec).
    /// @return treasury     Current treasuryBalance (USDC 6-dec).
    /// @return unclaimed    Total unclaimed draw prizes outstanding (USDC 6-dec).
    /// @return playerCount  Total registered player count.
    /// @return upfrontOGs   Current upfront OG count.
    /// @return weeklyOGs    Current weekly OG count.
    /// @return breathMult   Current breathMultiplier (BPS).
    /// @return obligLocked  True if OG obligation is locked (always true after startGame).
    /// @return ogObligation Locked OG endgame obligation (USDC 6-dec).
    /// @return lastResolved Last draw number for which price was resolved.
    function getGameState() external view returns (
        GamePhase gPhase, DrawPhase dPhase, uint256 draw, uint256 pot,
        uint256 treasury, uint256 unclaimed, uint256 playerCount,
        uint256 upfrontOGs, uint256 weeklyOGs, uint256 breathMult,
        bool obligLocked, uint256 ogObligation, uint256 lastResolved
    ) {
        return (gamePhase, drawPhase, currentDraw, prizePot, treasuryBalance, totalUnclaimedPrizes,
            totalRegisteredPlayers, upfrontOGCount, weeklyOGCount, breathMultiplier, obligationLocked,
            ogEndgameObligation, lastResolvedDraw);
    }

    /// @notice Returns a full USDC accounting snapshot for off-chain monitoring.
    /// @dev Sums all allocated pools against the actual contract USDC balance.
    ///      isSolvent = totalValue + SOLVENCY_TOLERANCE >= totalAllocated.
    ///      SOLVENCY_TOLERANCE (100_000 = $0.10 USDC) absorbs rounding dust.
    ///      Includes draw30BonusFund in totalAllocated to prevent false surplus.
    /// @return totalValue      Actual USDC balance held by the contract.
    /// @return totalAllocated  Sum of all tracked allocations (prizePot + treasury +
    ///                         unclaimed prizes + dormancy pools + tier pools + seed +
    ///                         reset refund pools + endgameOwed + draw30BonusFund +
    ///                         dormancyVCPool + vcReturnOwed + vcBonusEscrow). [CRE v0.9 / NS-L-03:
    ///                         the three VC/SmartEarn pools were always in the maths but omitted
    ///                         from this list.]
    /// @return isSolvent       True if totalValue + SOLVENCY_TOLERANCE >= totalAllocated.
    ///                         SOLVENCY_TOLERANCE (100_000 = $0.10) absorbs USDC rounding
    ///                         dust. isSolvent=false indicates a genuine shortfall.
    // SYNC: pool list must stay in sync with _computeBalanceAndAllocated() internal function.
    function getSolvencyStatus() external view returns (uint256 totalValue, uint256 totalAllocated, bool isSolvent) {
        // [CRE v1.11a / SYNC-01] Delegates to the canonical _computeBalanceAndAllocated() so the
        // full pool list has ONE definition. Removes the duplicated sum that could silently drift
        // from the authoritative check on a future pool addition. Behaviour identical (same pools).
        (uint256 actualBalance, uint256 nonPotAllocated) = _computeBalanceAndAllocated();
        totalValue = actualBalance;
        totalAllocated = prizePot + nonPotAllocated;
        isSolvent = totalValue + SOLVENCY_TOLERANCE >= totalAllocated;
    }

    /// @notice Returns current breath-based prize rate in BPS.
    ///         Returns 0 when currentDraw >= TOTAL_DRAWS (draw 30). [v1.55 I-NEW-02]
    /// @return  BPS prize rate (breathMultiplier * prizeRateMultiplier / 10000).
    ///          Returns 0 at draw 30+ (surplus path used instead -- see notice above).
    ///          At draw 0 (pregame): returns the initial breathMultiplier (informational).
    ///         IMPORTANT: 0 on draw 30 does NOT mean zero payout. Draw 30 uses a special
    ///         surplus path in _calculatePrizePools() that ignores this rate and distributes
    ///         the pot above the running-average targeted holdback (29-draw OG ratio estimate). Draw 30 is typically the highest-payout
    ///         draw of the season. Frontends should display "Final Draw -- Surplus Distribution"
    ///         rather than "0% prize rate" when currentDraw >= TOTAL_DRAWS.
    function getCurrentPrizeRate() public view returns (uint256) {
        if (currentDraw >= TOTAL_DRAWS) return 0;
        return breathMultiplier * prizeRateMultiplier / 10000;
    }

    /// @notice Returns projected OG endgame payout per qualified OG.
    /// @dev Pre-settlement: estimates pot / qualifiedOGs capped at OG_UPFRONT_COST * targetReturnBps / 10000.
    ///      This matches the closeGame() perOGPromised ceiling (live ratio, not season average).
    ///      [v1.59] closeGame() uses season-average ratio; actual payout may be higher.
    ///      [v1.63] Cap corrected from OG_UPFRONT_COST to OG_UPFRONT_COST * targetReturnBps/10000.
    /// @return currentPerOG  Projected payout per OG, capped at OG_UPFRONT_COST * targetReturnBps/10000.
    /// @return obligation    Total OG endgame obligation at targetReturnBps.
    /// @return potHealth     Pot as BPS of requiredEndPot (10000 = at solvency floor). [v1.68] Uncapped --
    ///                       values above 10000 = above-floor health (e.g. 20000 = 2x requiredEndPot).
    ///                       [v2.27] Denominator is requiredEndPot (obligation * targetReturnBps/10000
    ///                       + DRAW30_PRIZE_RESERVE + unreleased VC seed), not gross obligation. [CRE v0.8 / NS-L-01]
    ///                       Monitoring tools should calibrate alerts against requiredEndPot, not the gross figure.
    function getProjectedEndgamePerOG() external view returns (uint256 currentPerOG, uint256 obligation, uint256 potHealth) {
        // [v1.58-P3] obligationLocked is always true from startGame() -- this branch never executes.
        if (!obligationLocked) return (0, 0, 0);
        if (dormancyTimestamp > 0) return (0, 0, 0);
        if (gameSettled) return (endgamePerOG, ogEndgameObligation * targetReturnBps / 10000, 10000);
        uint256 ogCount = _countQualifiedOGs();
        currentPerOG = ogCount > 0 ? prizePot / ogCount : 0;
        // [v1.63] Cap matches closeGame() which uses avgTargetReturnBps not OG_UPFRONT_COST.
        // Use live targetReturnBps as ceiling (conservative pre-settlement estimate).
        uint256 maxPerOG = OG_UPFRONT_COST * targetReturnBps / 10000;
        if (currentPerOG > maxPerOG) currentPerOG = maxPerOG;
        obligation = ogEndgameObligation * targetReturnBps / 10000;
        potHealth = requiredEndPot > 0 ? prizePot * 10000 / requiredEndPot : 10000;
        // [v1.68] potHealth cap removed -- values above 10000 indicate above-target pot health.
        // A pot at 200% of required correctly returns potHealth=20000. Frontend should interpret
        // values above 10000 as "above target" not clamp to 100%.
    }

    /// @notice Returns OG registration counts and capacity figures.
    /// @dev [v1.57-P1] upfrontMax is informational only -- the upfront OG ratio cap was
    ///      removed from registerAsOG() in v1.57-P1. Any number of upfront OGs can register.
    ///      weeklyMax / availableWeeklySlots are still enforced by _weeklyOGCapReached().
    /// @return upfrontCurrent      upfrontOGCount -- registered upfront OGs.
    /// @return upfrontMax          Computed upfront cap (formula: committedPlayerCount * UPFRONT_OG_CAP_BPS / 10000).
    ///                             INFORMATIONAL ONLY. Cap removed in v1.57-P1. Any number of upfront
    ///                             OGs can register regardless of this value.
    /// @return weeklyCurrent       weeklyOGCount -- active weekly OGs.
    /// @return weeklyMax           Computed weekly OG slot maximum (enforced).
    /// @return totalMax            Computed total OG cap (upfront + weekly).
    /// @return availableWeeklySlots  weeklyMax - weeklyCurrent (remaining weekly slots).
    function getOGCapInfo() external view returns (uint256 upfrontCurrent, uint256 upfrontMax, uint256 weeklyCurrent, uint256 weeklyMax, uint256 totalMax, uint256 availableWeeklySlots) {
        uint256 denominator = gamePhase == GamePhase.PREGAME ? committedPlayerCount : ogCapDenominator;
        uint256 uMax = denominator * UPFRONT_OG_CAP_BPS / 10000;
        if (uMax < OG_ABSOLUTE_FLOOR) uMax = OG_ABSOLUTE_FLOOR;
        uint256 tMax = denominator * TOTAL_OG_CAP_BPS / 10000;
        uint256 wMax = tMax > upfrontOGCount ? tMax - upfrontOGCount : 0;
        uint256 available = wMax > weeklyOGCount ? wMax - weeklyOGCount : 0;
        return (upfrontOGCount, uMax, weeklyOGCount, wMax, tMax, available);
    }

    /// @notice Returns pregame state for frontend display.
    /// @dev [v1.57-P1] intentQueueClear always returns true -- intent queue removed.
    ///      Retained in return signature for ABI compatibility with existing tooling.
    ///      [v1.69] intentQueueClear is permanently true in all v1.57+ deployments.
    ///      Any downstream consumer of this field should treat it as a deprecated constant.
    /// @return committed          committedPlayerCount -- total pregame commitments.
    /// @return upfrontOGs         upfrontOGCount.
    /// @return weeklyOGs          weeklyOGCount.
    /// @return neededToStart      MIN_PLAYERS_TO_START.
    /// @return readyToStart       True when proposeStartGame() can be called: player threshold
    ///                             met, PREGAME phase, no pending proposal, AND
    ///                             block.timestamp < signupDeadline + MAX_PREGAME_DURATION.
    ///                             Does NOT mean startGame() can execute -- that also requires
    ///                             the 72h notice period to have elapsed.
    /// @return intentQueueClear   Always true. Deprecated ABI-compat field from v1.57-P1.
    /// @return proposalTimestamp  startGameProposedAt (0 if no proposal pending).
    function getPreGameStats() external view returns (
        uint256 committed, uint256 upfrontOGs, uint256 weeklyOGs, uint256 neededToStart,
        bool readyToStart, bool intentQueueClear, uint256 proposalTimestamp
    ) {
        // [v1.69] readyToStart = canPropose (conditions met to call proposeStartGame).
        // Not the same as canExecuteStart -- startGame() additionally requires
        // startGameProposedAt != 0 and the 72h notice period to have elapsed.
        bool _readyToStart = committedPlayerCount >= MIN_PLAYERS_TO_START
            && gamePhase == GamePhase.PREGAME
            && block.timestamp < signupDeadline + MAX_PREGAME_DURATION
            && startGameProposedAt == 0;
        return (
            committedPlayerCount, upfrontOGCount, weeklyOGCount, MIN_PLAYERS_TO_START,
            _readyToStart,
            // [v1.57-P1] intentQueueClear permanently true -- intent queue removed in v1.57-P1.
            true,
            startGameProposedAt
        );
    }

    /// @notice Returns dormancy pool balances and claim window status.
    /// @return ogPoolRemaining       Remaining OG principal pool (USDC 6-dec).
    /// @return principalFullCover    True if OG principal is fully covered by pot.
    /// @return casualPoolRemaining   Remaining casual refund pool (USDC 6-dec).
    /// @return casualFullCover       True if casual refund pool is fully covered.
    /// @return casualTicketTotal     Total casual ticket contributions at dormancy.
    /// @return commitmentPoolRemaining Remaining commitment refund pool (USDC 6-dec).
    /// @return commitmentFullCover   True if commitment pool is fully covered.
    /// @return perHeadPoolRemaining  Remaining per-head surplus pool (USDC 6-dec).
    /// @return perHeadShare          Per-participant share amount (USDC 6-dec).
    /// @return participantCount      Number of participants eligible for per-head share.
    /// @return sweepWindowOpens      Timestamp when unclaimed funds can be swept (0 if not dormant).
    function getDormancyInfo() external view returns (
        uint256 ogPoolRemaining, bool principalFullCover,
        uint256 casualPoolRemaining, bool casualFullCover, uint256 casualTicketTotal,
        uint256 commitmentPoolRemaining, bool commitmentFullCover,
        uint256 perHeadPoolRemaining, uint256 perHeadShare, uint256 participantCount,
        uint256 sweepWindowOpens
    ) {
        return (dormancyOGPool, dormancyPrincipalFullCover, dormancyCasualRefundPool, dormancyCasualFullCover, dormancyCasualTicketTotal,
            dormancyCommitmentPool, dormancyCommitmentFullCover,
            dormancyPerHeadPool, dormancyPerHeadShare, dormancyParticipantCount,
            dormancyTimestamp > 0 ? dormancyTimestamp + DORMANCY_CLAIM_WINDOW : 0);
    }

    /// @notice Returns current cutoff diff state for monitoring and keeper verification. [v1.0]
    /// @return _t1        t1CutoffDiff (top 1% boundary diff value).
    /// @return _t2        t2CutoffDiff (top ~6% cumulative boundary diff value).
    /// @return _t3        t3CutoffDiff (top ~12-15% boundary diff value).
    /// @return _snapshot  snapshotTotalEntries used as BPS denominator.
    function getCutoffState() external view returns (uint256 _t1, uint256 _t2, uint256 _t3, uint256 _snapshot) {
        return (t1CutoffDiff, t2CutoffDiff, t3CutoffDiff, snapshotTotalEntries);
    }

    /// @notice Returns the count bounds that submitCutoffDiffs() will verify against. [v1.51]
    ///         Keepers SHOULD call this before submitting cutoff diffs to pre-validate
    ///         their computed counts. If submitted counts fall outside these bounds,
    ///         submitCutoffDiffs() will revert CutoffOutOfRange.
    ///
    ///         KEEPER WORKFLOW:
    ///           1. Wait for drawPhase == CUTOFF_SUBMISSION.
    ///           2. Read all predictions from chain events.
    ///           3. Compute diffs = |prediction * PREDICTION_SCALE - resolvedPrice| for each entry.
    ///           4. Sort entries by diff ascending.
    ///           5. Find diff values at 1%, ~6%, and ~12-15% cumulative thresholds (draw-schedule
    ///              dependent; include tie clusters). T3_COUNT_MIN_BPS=1000 means target >= 10%.
    ///           6. Call getRequiredCutoffDiffBounds() to verify your counts are in range.
    ///           7. If counts in range, call submitCutoffDiffs().
    ///
    ///      ENTRY ENUMERATION RULES (v2.35 I-04 / NS-I-01 -- load-bearing post-M-01):
    ///        The entry count you compute in step 3-4 MUST match _processMatchesCore()
    ///        exactly or your honest diff counts will trip MatchCountMismatch.
    ///        Rules as of v2.34:
    ///          - OGs (isUpfrontOG OR isWeeklyOG && !weeklyOGStatusLost): 2 entries each.
    ///            prediction1 auto-filled from autoDefaultPrediction if stale or zero.
    ///            prediction2 always auto-filled regardless (OG always has 2 entries).
    ///          - Casuals (weeklyNonOGPlayers): 1 entry for lastTicketCount == 1.
    ///            prediction1 auto-filled from autoDefaultPrediction if stale or zero.
    ///          - Casuals (weeklyNonOGPlayers): 2 entries for lastTicketCount >= 2.
    ///            prediction1 auto-filled. prediction2 auto-filled if stale or zero.
    ///            [Changed at v2.34 M-01: previously prediction2 was dropped if not
    ///            explicitly submitted. Update off-chain keeper spec to match.]
    ///        autoDefaultPrediction = lastResolvedPrice if <= DRAW_COOLDOWN old;
    ///        else defaultPrediction. Same value used for all fills in one draw.
    ///
    /// @return inCutoffSubmission  True if currently awaiting keeper submission.
    /// @return snapshot            snapshotTotalEntries -- denominator for all BPS checks.
    /// @return t1Min               Minimum acceptable T1 count (0.5% of snapshot).
    /// @return t1Max               Maximum acceptable T1 count (4% of snapshot).
    /// @return t2Min               Minimum acceptable T2 cumulative count (4% of snapshot).
    /// @return t2Max               Maximum acceptable T2 cumulative count (12% of snapshot). [v2.18: was 6%]
    /// @return t3Min               Minimum acceptable T3 cumulative count (10% of snapshot). [v2.18: was 16%]
    /// @return t3Max               Maximum acceptable T3 cumulative count (50% of snapshot).
    ///      NOTE: At draws 1-2 (T3_WINNER_BPS_D1_2=600) theoretical cumulative is ~12%.
    ///      The 10% minimum gives a 2% margin -- the tightest point in the season.
    ///      OG status losses during MATCHING reduce actual entries vs snapshot (overcounting)
    ///      which can push BPS lower. Verified safe at 20% OG + 10% attrition.
    ///      [v2.19] Margin structurally identical to old design: 12%-10% MIN = 2pp
    ///      (old: 18%-16% = 2pp). Re-confirm under new schedule before production.
    ///                             Upper bound is wide due to 2-ticket casual snapshot bias.
    ///                             Actual T3% of real entries is 12-15% depending on draw.
    /// @return priceForDiffs       resolvedPrice -- compute diffs against this value.
    /// @dev    DENOMINATOR NOTE: all bounds are computed against snapshotTotalEntries,
    ///         which uses the same 2-ticket casual undercount bias as submitCutoffDiffs().
    ///         (Each casual = 1 in snapshot regardless of ticket count; 2-ticket casuals
    ///         generate 2 entries. This makes BPS values read higher than actual percentages.)
    ///         Keepers do NOT need to adjust for this -- the bounds returned here exactly
    ///         match what submitCutoffDiffs() will accept. The bias is consistent end-to-end.
    function getRequiredCutoffDiffBounds() external view returns (
        bool   inCutoffSubmission,
        uint256 snapshot,
        uint256 t1Min, uint256 t1Max,
        uint256 t2Min, uint256 t2Max,
        uint256 t3Min, uint256 t3Max,
        int256  priceForDiffs
    ) {
        inCutoffSubmission = (drawPhase == DrawPhase.CUTOFF_SUBMISSION);
        snapshot            = snapshotTotalEntries;
        if (snapshot > 0) {
            // [CRE v0.14 / B-L-01] Min bounds use CEILING division to match the acceptance check.
            // submitCutoffDiffs() accepts count when floor(count * 10000 / snapshot) >= MIN_BPS.
            // The smallest count satisfying that is ceil(snapshot * MIN_BPS / 10000), NOT the floor.
            // The v1.54 L-03 floor-with-"if 0 then 1" patch fixed only the zero case; counts of 1 or 2
            // could still be under-reported and rejected (e.g. snapshot=500, T1 MIN 50: floor gives 2,
            // but 2*10000/500 = 40 < 50; true min is ceil(2.5) = 3). Ceiling division fixes all cases
            // and subsumes the zero patch (ceil of any positive is >= 1).
            t1Min = (snapshot * T1_COUNT_MIN_BPS + 9999) / 10000;
            t2Min = (snapshot * T2_COUNT_MIN_BPS + 9999) / 10000;
            t3Min = (snapshot * T3_COUNT_MIN_BPS + 9999) / 10000;
            // MAX bounds stay FLOOR: acceptance is floor(count*10000/snapshot) <= MAX_BPS, so the
            // largest acceptable count is floor(snapshot * MAX_BPS / 10000). Floor here can under-report
            // the max by at most 1, which is CONSERVATIVE (a keeper guided by it stays safely in range)
            // and therefore harmless. Do not "fix" the MAX side to ceiling; that would over-report and
            // guide a keeper into a reverting submission.
            t1Max = snapshot * T1_COUNT_MAX_BPS / 10000;
            t2Max = snapshot * T2_COUNT_MAX_BPS / 10000;
            t3Max = snapshot * T3_COUNT_MAX_BPS / 10000;
        }
        priceForDiffs = resolvedPrice;
    }

    /// @notice Returns the most recently resolved ETH/USD price (Chainlink 8-dec).
    ///         Returns 0 between draws and during draw 1 before the first resolution.
    function getResolvedPrice() external view returns (int256) { return resolvedPrice; }

    /// @notice Returns winner counts for each tier in the current draw.
    /// @dev [v1.0] 3 tiers only (T1/T2/T3). p4 REMOVED -- ABI change from 1Y game.
    ///      Subgraphs must update from 4-return to 3-return signature.
    /// @dev During IDLE phase these reflect the most recently completed draw.
    ///      Arrays are cleared at the start of resolveWeek() for the next draw,
    ///      not at finalizeWeek(). Counts are accurate during MATCHING → FINALIZING only.
    /// @return t1  T1 (1% Club) winner count.
    /// @return t2  T2 winner count.
    /// @return t3  T3 winner count.
    function getWinnerCounts() external view returns (uint256 t1, uint256 t2, uint256 t3) {
        return (jpWinners.length, p2Winners.length, p3Winners.length);
    }

    /// @notice Returns true if prediction is within [1, MAX_PREDICTION_CENTS].
    /// @param prediction  Value to validate.
    /// @return valid   True if prediction falls within [1, MAX_PREDICTION_CENTS].
    /// @return reason  Human-readable rejection reason if invalid; empty string if valid.
    function isValidPrediction(uint256 prediction) external pure returns (bool valid, string memory reason) {
        if (prediction == 0) return (false, "Prediction must be greater than zero");
        if (prediction > MAX_PREDICTION_CENTS) return (false, "Prediction exceeds maximum ($10 trillion USD / 1 quadrillion cents)");
        return (true, "");
    }

    /// @notice Returns 0-based ogList index for addr.
    /// @dev    Returns 0 for both the first list entry AND addresses not in the list
    ///         (storage default). AMBIGUOUS on its own. Always confirm membership via
    ///         p.isUpfrontOG || p.isWeeklyOG before using this index for list operations.
    /// @param addr  Address to look up.
    function getOGListIndex(address addr) external view returns (uint256) { return ogListIndex[addr]; }

    /// @notice Returns the contract version string.
    /// @return  Version string identifying this deployment.
    function getContractVersion() external pure returns (string memory) {
        return "BullsEthCRE_v1.11a";
    }

    /// @notice Returns current draw-30 bonus fund balance and expected contribution per draw.
    /// @dev [v1.62] For off-chain monitoring and frontend display.
    ///      perDrawEstimate returns 0 at draw 30 because getCurrentPrizeRate() returns 0
    ///      on the final draw. accumulated reflects the full season siphon at that point.
    /// @return accumulated  Total bonus siphoned so far.
    /// @return perDrawEstimate  Estimated bonus per draw at current breathMultiplier
    ///                          and prizeRateMultiplier (via getCurrentPrizeRate()).
    ///                          Returns 0 at draw 30+ (getCurrentPrizeRate() returns 0).
    ///                          [CRE v0.13] Excludes any active seed supplement. The bonus
    ///                          siphon in _calculatePrizePools() is taken from weeklyPool
    ///                          INCLUDING the supplement, so on supplement-active draws the
    ///                          real per-draw bonus contribution is proportionally higher than
    ///                          this estimate. Monitoring only; no economic effect.
    function getDraw30BonusStatus() external view returns (
        uint256 accumulated, uint256 perDrawEstimate
    ) {
        accumulated = draw30BonusFund;
        uint256 rate = getCurrentPrizeRate();
        uint256 weeklyEst = prizePot * rate / 10000;
        perDrawEstimate = weeklyEst * DRAW30_BONUS_BPS / 10000;
    }

    /// @notice Returns current pot health relative to requiredEndPot.
    ///         Used by operators and front-ends to monitor exhale floor gate status.
    /// @dev [v1.60] potHealthBps = prizePot * 10000 / requiredEndPot.
    ///      Gate fires when potHealthBps < exhaleFloorReleaseBps (default 12000).
    ///      Integer division truncates -- e.g. exact 1.2x gives potHealthBps=11999,
    ///      so gateActive returns true ~0.01% before the nominal threshold. Consequence:
    ///      exhale floor may release fractionally early. Negligible in practice.
    ///      gateActive is true only during exhale phase (currentDraw > INHALE_DRAWS).
    /// @return potHealthBps  Current pot as BPS of requiredEndPot (10000 = 100%).
    ///                       Returns 10000 as a sentinel when requiredEndPot == 0
    ///                       (no OG obligation locked -- game has no OGs or obligation
    ///                       not yet set). Sentinel indicates no floor exists, not full
    ///                       health. gateActive will be false in this state.
    /// @return gateActive    True if the gate could currently release the exhale floor.
    /// @return threshold     Current exhaleFloorReleaseBps setting.
    function getExhaleFloorHealth() external view returns (
        uint256 potHealthBps, bool gateActive, uint256 threshold
    ) {
        threshold = exhaleFloorReleaseBps;
        potHealthBps = (requiredEndPot > 0)
            ? prizePot * 10000 / requiredEndPot
            : 10000;
        gateActive = currentDraw > INHALE_DRAWS && potHealthBps < threshold;
    }

    /// @notice Pre-flight solvency check. Call before startGame() to verify the
    ///         game can be started without reverting PotBelowTrajectory.
    /// @dev [v1.58-P3] Runs the same geometric simulation as startGame().
    ///      Returns (true, 0) if solvent. Returns (false, deficit) if not,
    ///      where deficit is how much extra revenue per draw is needed.
    ///      Uses current breathRailMin, prizePot, and committed player counts.
    ///      PREGAME only -- call during signup window to diagnose before startGame.
    ///      [v1.59] Uses live OG ratio for the floor estimate (conservative).
    ///      Actual perOGPromised at closeGame() uses the season average and may
    ///      be higher if the ratio was elevated early but drops mid-season.
    /// @return solvent  True if the geometric simulation confirms solvency at breathRailMin.
    /// @return deficit  Approximate per-draw revenue shortfall if not solvent (lower-bound estimate).
    function checkSolvency() external view returns (bool solvent, uint256 deficit) {
        if (gamePhase != GamePhase.PREGAME) revert WrongPhase(); // PREGAME only
        uint256 maxOGs = upfrontOGCount + earnedOGCount;
        uint256 obligation = maxOGs * OG_UPFRONT_COST;
        uint256 curTargetBps = committedPlayerCount > 0
            ? _computeTargetReturnBps((maxOGs * 10000) / committedPlayerCount) : MAX_TARGET_RETURN_BPS; // [CRE v1.11a / PG-03] named constant (== _computeTargetReturnBps(0)) not magic 5000
        // [CRE v0.8 / CR-M-02] Include unreleased VC seed so this pre-flight floor is
        // bit-identical to the requiredEndPot that startGame() enforces. In PREGAME
        // seedReleased == 0, so this adds back the full VC_SEED the check was dropping.
        // Without it, a deployment could pass this preview but fail (or misprice) at start.
        uint256 _vcUnreleasedCS = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
        uint256 floor = obligation * curTargetBps / 10000 + DRAW30_PRIZE_RESERVE + _vcUnreleasedCS;
        uint256 casualCount = committedPlayerCount > maxOGs ? committedPlayerCount - maxOGs : 0;
        uint256 dblCount = committedDoubleCount < casualCount ? committedDoubleCount : casualCount;
        uint256 rev = (casualCount - dblCount + dblCount * 2) * TICKET_PRICE * (10000 - TREASURY_BPS) / 10000;
        uint256 endPot = _simGeomPot(prizePot, breathRailMin, TOTAL_DRAWS, rev);
        if (endPot >= floor) return (true, 0);
        // Approximate deficit: extra per-draw revenue that would close the gap.
        // Geometric decay means true deficit is slightly higher than this linear estimate.
        // Treat as a lower-bound indicator, not a precise figure.
        uint256 gap = floor - endPot;
        deficit = gap / TOTAL_DRAWS + 1;
        return (false, deficit);
    }

    /// @notice Returns the current auto-default prediction value and whether it is the seed fallback.
    /// @dev cents is autoDefaultCents (last resolved price in cent units) when > 0.
    ///      isSeed = true when autoDefaultCents == 0, meaning defaultPrediction is used instead.
    ///      Frontends must handle both cases differently -- isSeed = true means no prior resolution.
    /// @return cents     Auto-default prediction in USD cents. When isSeed=true this is
    ///                   the owner-set defaultPrediction (always non-zero by constructor);
    ///                   when isSeed=false this is autoDefaultCents from the previous draw.
    /// @return isSeed    True when falling back to the owner-set defaultPrediction.
    function getAutoDefault() external view returns (uint256 cents, bool isSeed) {
        if (autoDefaultCents > 0) return (autoDefaultCents, false);
        return (defaultPrediction, true);
    }

    /// @dev [v1.55] Internal version of countStaleOGs for use in checkUpkeep view.
    ///      Caps iteration at STALE_OG_PRUNE_THRESHOLD+1 (early exit on threshold confirmation).
    ///      [v1.56] Independent iteration cap: exits after MAX_STALE_COUNT_ITERATIONS
    ///      regardless of stale count. Prevents full ogList traversal on every checkUpkeep
    ///      call when stale OGs are concentrated at the tail of a large list.
    ///      Condition matches pruneStaleOGs exactly: p.isWeeklyOG && p.weeklyOGStatusLost.
    function _countStaleOGsInternal() internal view returns (uint256 staleCount) {
        uint256 len = ogList.length;
        uint256 staleCap = STALE_OG_PRUNE_THRESHOLD + 1;
        uint256 iterCap  = MAX_STALE_COUNT_ITERATIONS;
        for (uint256 i = 0; i < len && staleCount < staleCap && i < iterCap; i++) {
            PlayerData storage p = players[ogList[i]];
            if (p.isWeeklyOG && p.weeklyOGStatusLost) staleCount++;
        }
    }

    /// @notice Counts all stale weekly OGs in the full ogList. Unbounded -- use paginated overload for large lists.
    /// @return staleCount  Number of weekly OGs with weeklyOGStatusLost == true.
    function countStaleOGs() external view returns (uint256 staleCount) {
        for (uint256 i = 0; i < ogList.length; i++) {
            // Invariant: weeklyOGStatusLost only set on isWeeklyOG==true entries.
            if (players[ogList[i]].isWeeklyOG && players[ogList[i]].weeklyOGStatusLost) staleCount++;
        }
    }

    /// @notice Counts stale weekly OGs in a paginated range. For keeper gas estimation.
    ///         A weekly OG is stale when weeklyOGStatusLost is true and not yet pruned.
    /// @param start  Index into ogList to start from (0-based).
    /// @param count  Maximum number of entries to check from start.
    /// @return staleCount  Number of stale weekly OGs found in the range.
    function countStaleOGs(uint256 start, uint256 count) external view returns (uint256 staleCount) {
        uint256 len = ogList.length;
        if (start >= len) return 0;
        uint256 end = start + count;
        if (end > len) end = len;
        for (uint256 i = start; i < end; i++) {
            // Invariant: weeklyOGStatusLost only set on isWeeklyOG==true entries.
            if (players[ogList[i]].isWeeklyOG && players[ogList[i]].weeklyOGStatusLost) staleCount++;
        }
    }

    // ── Internal: breath calibration (inherited unchanged) ────────────────────

    /// @notice Computes starting breath rate targeting T3 prizes near TICKET_PRICE at draw 1. [v1.5]
    /// @dev    Called once at startGame(). Uses pregame state to estimate draw-1 entries and pot.
    ///
    ///         FORMULA DERIVATION:
    ///           T3 per winner = prizePot * (breath_bps/10000)
    ///                           * (10000-SEED_BPS)/10000
    ///                           * (10000-JP_BPS-P2_BPS)/10000
    ///                           / (estimatedEntries * _getT3WinnerBps()/10000)
    ///
    ///           Setting T3 per winner = TICKET_PRICE and solving for breath_bps:
    ///
    ///           breath_bps = TICKET_PRICE * estimatedEntries * _getT3WinnerBps() * 100_000_000
    ///                        / (prizePot * (10000-SEED_BPS-DRAW30_BONUS_BPS) * (10000-JP_BPS-P2_BPS))
    ///           [v1.62] Denominator includes DRAW30_BONUS_BPS: distributable = 87% not 90%.
    ///
    ///           All values in USDC 6-decimal units. TICKET_PRICE and prizePot share units
    ///           so they cancel dimensionally. The 100_000_000 factor = 10000^2 accounts for
    ///           the two /10000 fractions in DIST_FRAC.
    ///           Overflow safe: max numerator ~6.6*10^22 (10^7 * 110000 * 600 * 10^8)
    ///           << uint256 max ~1.16*10^77. Exponent unchanged from v2.13 correction.
    ///
    ///         ENTRY ESTIMATION:
    ///           OGs: (upfrontOGCount + weeklyOGCount) * 2 entries.
    ///           Single-commitment casuals: (committedPlayerCount - n_og - committedDoubleCount) * 1.
    ///           Double-commitment casuals: committedDoubleCount * 2.
    ///           committedDoubleCount is the best available proxy for 2-ticket casuals at launch.
    ///           Slight under-estimate: casuals may upgrade to 2 tickets in draws 2+ but
    ///           draw 1 is when the T3 calibration target matters most.
    ///
    ///         THE RAIL:
    ///           Capped at breathRailMax (default 15%). The 15% rail has two jobs:
    ///           (1) Security governor against admin/attack draining the pot.
    ///           (2) Exhale ceiling -- prevents breath rising past 15% in draws 21-30.
    ///           Using the rail fully at draw 1 for T3 floor calibration is the intended use.
    ///           Only scenario exceeding 15%: <3% OG with all casuals buying 2 tickets.
    ///           [v2.18] With T3=6% (fewer winners per pool), per-winner prize rises
    ///           vs old 10% design. Draw-1 $9.45 worst-case figure superseded.
    ///           This is a calibration approximation, not a hard guarantee.
    ///
    ///         TRADE-OFF:
    ///           Higher starting breath = better T3 prize on draw 1 but smaller draw-30 surplus.
    ///           [v2.18] Simulation values superseded -- new T3=6-9% schedule gives fewer
    ///           winners per pool so per-winner prize is higher at equivalent breath.
    ///           Breath calibration formula self-adjusts via _getT3WinnerBps() at runtime.
    ///           Design choice: a player who wins near TICKET_PRICE on day one returns for day two.
    ///           The ~$175 difference in draw-30 T3 surplus is the deliberate cost of retention.
    ///           [v2.18: superseded -- simulation values updated; figure not recalculated.]
    ///
    /// @return breathBps         Breath BPS targeting T3 near TICKET_PRICE at estimated draw-1
    ///                           parameters. Clamped to [breathRailMin, breathRailMax].
    ///                           A calibration estimate -- actual prize depends on runtime state.
    /// @return estimatedEntries  Estimated draw-1 entry count (used in BreathCalibrated event).
    function _computeStartingBreath() internal view returns (uint256 breathBps, uint256 estimatedEntries) {
        uint256 nOG     = upfrontOGCount + weeklyOGCount;
        uint256 nCasual = committedPlayerCount > nOG ? committedPlayerCount - nOG : 0;
        uint256 nDouble = committedDoubleCount < nCasual ? committedDoubleCount : nCasual;
        uint256 nSingle = nCasual - nDouble;
        estimatedEntries = nOG * 2 + nSingle + nDouble * 2;

        // [v1.51] Defence-in-depth guard. MIN_PLAYERS_TO_START (500) is already enforced
        // before startGame() can fire, so estimatedEntries < 500 should never occur.
        // Guard retained against future refactoring or extreme pregame scenarios.
        if (estimatedEntries < MIN_PLAYERS_TO_START || prizePot == 0) {
            return (breathRailMin, estimatedEntries);
        }

        // [v1.57-P2] Calibration target: T3/winner near TICKET_PRICE at estimated draw-1 parameters.
        // [v1.62] denominator uses (10000-SEED_BPS-DRAW30_BONUS_BPS) = 8700 (87% distributable).
        // Called from startGame() when currentDraw=1 -- _getT3WinnerBps() returns
        // T3_WINNER_BPS_D1_2 (600). Calibration intentionally targets draw-1 conditions:
        // tightest winner pool (6%, lowest in the graduated schedule). Correct for calibration.
        // 100_000_000 = 10000^2 (accounts for two /10000 factors in the fraction chain).
        uint256 numerator   = TICKET_PRICE * estimatedEntries * _getT3WinnerBps() * 100_000_000;
        // [v1.62] DRAW30_BONUS_BPS siphon reduces distributable from 90% to 87% of weeklyPool.
        uint256 denominator = prizePot * (10000 - SEED_BPS - DRAW30_BONUS_BPS) * (10000 - JP_BPS - P2_BPS);
        breathBps = denominator > 0 ? numerator / denominator : breathRailMin;

        if (breathBps < breathRailMin) breathBps = breathRailMin;
        if (breathBps > breathRailMax) breathBps = breathRailMax;
    }

    /// @dev [v1.57-P2] Canonical P2 return curve. Single source of truth for all three
    ///      calibration sites (startGame, _calibrateBreathTarget, _finalReturnCalibration).
    ///      [CRE v0.1] Curve rescaled: 50% at <=20% OG, linear to 10% at 100% OG. Hard floor 10%.
    ///      [CRE v0.2 / LOW-02] NatSpec corrected from old values (90%/30%, [3000,9000]).
    ///      Any future slope or floor change is made here only.
    /// @param ratioBps  OG ratio in BPS (upfrontOGCount+earnedOGCount)*10000/committed.
    /// @return ret      targetReturnBps in BPS. Range [1000, 5000].
    function _computeTargetReturnBps(uint256 ratioBps) internal pure returns (uint256 ret) {
        // [CRE v0.1] OG return curve: 50% at <=20% OG ratio, linear to 10% at 100% OG.
        // At <=20%: 5000 bps (50% of $600 = $300 back). At 100%: 1000 bps ($60 back).
        // All values are placeholder for CRE demo -- adjustable pre-mainnet.
        if (ratioBps <= 2000) return 5000;
        uint256 reduction = (ratioBps - 2000) * 4000 / 8000;
        return reduction < 5000 ? 5000 - reduction : 1000;
    }

    // ── [v2.15] Deprecated treasury helpers ─────────────────────────────────

    // [CRE v1.11a / DL-01] _getDrawTreasuryBps() removed (deprecated v2.15, zero callers).

    // [CRE v1.11a / DL-01] _getHistoricalTreasuryBps() removed (deprecated v2.15, zero callers).

    /// @dev [v2.18] T3 winner percentage for current draw.
    ///      Fewer winners early = each winner gets more despite smaller pool.
    ///      Draw 1-2: 6%. Draw 3: 7%. Draw 4: 8%. Draw 5+: 9%.
    /// @return  T3 winner BPS for the current draw: 600 (1-2), 700 (3), 800 (4), 900 (5+).
    function _getT3WinnerBps() internal view returns (uint256) {
        if (currentDraw <= 2) return T3_WINNER_BPS_D1_2;
        if (currentDraw == 3) return T3_WINNER_BPS_D3;
        if (currentDraw == 4) return T3_WINNER_BPS_D4;
        return T3_WINNER_BPS; // draw 5+: 9%
    }

    /// @dev [v1.57-P2] Linear interpolation from targetReturnBps to an initial breathMultiplier.
    ///      [CRE v0.1] Anchors updated for new return range [1000, 5000]:
    ///               165 bps at tReturnBps=1000 (10% return, 100% OG load);
    ///               700 bps at tReturnBps=5000 (50% return, low OG load).
    ///      [CRE v0.2 / LOW-02] NatSpec corrected from old anchors (3000/9000 = 30%/90%).
    ///      Linear interpolation between anchors. All paths clamped to [breathRailMin, breathRailMax].
    ///      [v1.90] Rail clamp unified -- early returns previously bypassed the clamp.
    ///      Now all three branches clamp unconditionally.
    ///      Called at startGame() (step 2 of 3-step breath calibration), by
    ///      _calibrateBreathTarget() for the BreathRecalibrated event at draw 7, and
    ///      by _finalReturnCalibration() at draw 28.
    // 165 is not a named constant -- calibration-only value. Change all literals together.
    function _computeStartingBreathFromTarget(uint256 tReturnBps)
        internal view returns (uint256 bps)
    {
        // [CRE v0.1] Anchors adjusted for new return range [1000, 5000].
        // 165 bps at 1000 return (10%, 100% OG). BREATH_START (700) at 5000 return (50%, low OG).
        if (tReturnBps <= 1000)       bps = 165;
        else if (tReturnBps >= 5000)  bps = BREATH_START;
        else bps = 165 + (tReturnBps - 1000) * (BREATH_START - 165) / (5000 - 1000);
        if (bps < breathRailMin) bps = breathRailMin;
        if (bps > breathRailMax) bps = breathRailMax;
    }

    // [v1.57-P2] _computeTargetAndBreath removed -- P2 curve replaces it inline.


    /// @dev [v1.57-P2] Called at FINAL_CALIBRATION_DRAW (draw 28). Final recalibration
    ///      of targetReturnBps from late-game OG ratio. Updates requiredEndPot.
    ///      [v1.58-P3] Uses /10000 exact. _lockOGObligation is now a deprecated no-op;
    ///      the "/9000 unlike _lockOGObligation" note from v1.57 no longer applies.
    function _finalReturnCalibration() internal {
        uint256 maxOGs = upfrontOGCount + earnedOGCount;
        uint256 newRatioBps = ogCapDenominator > 0 ? maxOGs * 10000 / ogCapDenominator : 0;
        uint256 oldTargetBps = targetReturnBps;
        // [v1.57-P2] Canonical curve -- do not edit here; edit _computeTargetReturnBps().
        targetReturnBps = _computeTargetReturnBps(newRatioBps);
        // [v1.58-P3] Must include DRAW30_PRIZE_RESERVE to preserve draw-30 prize floor.
        //            Without it, solver floor drops by 5k at draw 28 and prizes at risk.
        // [CRE v1.04 / FLOOR-SPLIT] requiredEndPot is the ENDGAME target only (season-end) for the
        // solver. The live dormancy-now floor is separate (_dormancyNowFloor). [Was max() pre-v1.04.]
        if (ogEndgameObligation > 0) { requiredEndPot = _requiredEndPotFloor(ogEndgameObligation); }
        emit FinalReturnCalibrated(currentDraw, oldTargetBps, targetReturnBps, newRatioBps, requiredEndPot);
    }

    /// @dev [v1.57-P2] Called at BREATH_CALIBRATION_DRAW (draw 7). Recalibrates
    ///      targetReturnBps from the actual mid-game OG ratio using the P2 curve.
    ///      requiredEndPot is subsequently updated by _snapshotOGObligation(), which
    ///      runs in the same _finalizeWeekCore() call immediately after this function.
    ///      [v1.61] breathMultiplier is NOT written here. The geometric solver in
    ///      _checkAutoAdjust() applies the corrected breath at draw 8.
    function _calibrateBreathTarget() internal {
        uint256 maxOGs = upfrontOGCount + earnedOGCount;
        uint256 actualRatioBps = ogCapDenominator > 0 ? maxOGs * 10000 / ogCapDenominator : 0;
        uint256 oldTargetBps = targetReturnBps;
        uint256 recalBreath;
        // [v1.57-P2] Canonical curve -- do not edit here; edit _computeTargetReturnBps().
        targetReturnBps = _computeTargetReturnBps(actualRatioBps);
        // [v1.68] recalBreath computed solely for BreathRecalibrated event (computedBreath field).
        // Solver applies the actual value at draw 8 via _checkAutoAdjust().
        recalBreath = _computeStartingBreathFromTarget(targetReturnBps);
        uint256 oldBreath = breathMultiplier;
        // [v1.61] breathMultiplier write removed. targetReturnBps updated here;
        // requiredEndPot is updated by _snapshotOGObligation() immediately after.
        // _checkAutoAdjust() at draw 8 applies the correct solver-derived breath.
        // This eliminates the draw-7 breath bump artifact in low-revenue scenarios.
        emit BreathRecalibrated(oldTargetBps, targetReturnBps, oldBreath, recalBreath, actualRatioBps); // computedBreath = recalBreath (formula estimate, not solver value)
    }

    /// @dev [v1.58-P3] Deprecated no-op. OG obligation was previously locked at
    ///      OG_OBLIGATION_LOCK_DRAW (draw 10) with a /9000 buffer. Superseded by
    ///      startGame() locking at draw 1 with exact /10000 and DRAW30_PRIZE_RESERVE.
    ///      Retained for audit trail continuity: draw-10 locking was explicitly replaced
    ///      by startGame() P3. Safe to remove after Cyfrin audit acceptance and
    ///      before mainnet deployment. No callers. No side effects.
    function _lockOGObligation() internal {
        // [v1.58-P3] No-op. Obligation is locked at startGame(). See startGame() P3 block.
    }

    /// @dev [v1.58-P3] Called every draw from draw 1 (not just after draw 10).
    ///      Always uses /10000 exact. snapDivider (/9000 inhale buffer) removed in P3.
    ///      DRAW30_PRIZE_RESERVE added to floor so solver targets meaningful prizes at draw 30.
    ///      At draw 7: runs AFTER _calibrateBreathTarget, so uses updated targetReturnBps.
    ///      At draw 7: _calibrateBreathTarget updates targetReturnBps but NOT requiredEndPot.
    ///      Snapshot detects the delta in newRequired and emits OGObligationSnapshot.
    ///      At draw 28: _finalReturnCalibration updates BOTH targetReturnBps AND requiredEndPot
    ///      before the snapshot runs. Snapshot finds no delta and returns early.
    ///      FinalReturnCalibrated event covers the draw-28 change.
    ///      OGObligationSnapshot fires at draw 28 only if OG count also changed.
    /// @notice [CRE v1.01 / DORM-FLOOR] Single source of truth for the solver floor.
    ///         Returns max(endgame obligation, live dormancy obligation) so the
    ///         geometric solver can never draw prizePot below what a dormancy-now
    ///         would owe the senior tiers (VC, then upfront OGs) plus the current
    ///         draw's ticket buyers. Makes the early-dormancy senior-tier shortfall
    ///         structurally unreachable. VC is senior to OGs (unchanged ordering);
    ///         this floor guarantees enough for both so the seniority never bites.
    /// @param  _obligation  ogEndgameObligation to price this call against (callers
    ///                      pass either the stored value or a freshly computed one).
    /// @dev    Dormancy obligation mirrors activateDormancy()'s TIER 0 + TIER 1 +
    ///         current-draw casual pool, computed on live state:
    ///           TIER 0  unreleased VC seed              = VC_SEED - seedReleased
    ///           TIER 1  upfront OG pro-rata unplayed    = upfrontOG net principal
    ///                                                     * drawsUnplayed / TOTAL_DRAWS
    ///           casual  current-draw net ticket refund  = currentDrawCasualNetTicketTotal
    ///                                                     + currentDrawWeeklyOGNetTicketTotal
    ///         drawsUnplayed uses the SAME convention as activateDormancy:
    ///         drawsPlayed = currentDraw - 1 (dormancy fires in IDLE), netted of
    ///         resetDrawCount [D5-L-01], so a voided reset draw is not counted.
    ///         Commitment + per-head tiers are intentionally NOT reserved — they are
    ///         junior and gated on full senior cover; the floor protects seniors only.
    /// @notice [CRE v1.04 / FLOOR-SPLIT] The SOLVER / startGame end-of-season target.
    /// @dev Returns the ENDGAME floor only: what the pot must hold at draw 30 to pay the OG
    ///      endgame return, the draw-30 prize reserve, and any unreleased VC seed. This is a
    ///      season-END target and is the correct thing for _solveGeometricBps / _simGeomPot and
    ///      the startGame solvency gate to aim at. It matches checkSolvency() bit-for-bit
    ///      (same obligation, same targetReturnBps, same reserve, same VC term), which is what
    ///      keeps the pre-flight preview and the enforced gate in agreement [B-M-01 / CR-M-02].
    ///      The live dormancy obligation is NOT folded in here: it is a CURRENT-pot floor that
    ///      decays each played draw, and folding a today-floor into a season-end target made the
    ///      solver hold breath down all season for a constraint that has vanished by the time it
    ///      is measured [B-M-02]. Live dormancy protection is delivered per-draw by the
    ///      distribution gate against _dormancyNowFloor(); see _calculatePrizePools().
    function _requiredEndPotFloor(uint256 _obligation) internal view returns (uint256) {
        uint256 _vcUnreleased = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
        return _obligation * targetReturnBps / 10000 + DRAW30_PRIZE_RESERVE + _vcUnreleased;
    }

    /// @notice [CRE v1.04 / FLOOR-SPLIT] The LIVE senior dormancy-now floor (a CURRENT-pot floor).
    /// @dev [CRE v1.05] DELIBERATELY SEPARATE from _requiredEndPotFloor(): these are two different
    ///      quantities and must not be merged back into one. _requiredEndPotFloor() is a SEASON-END
    ///      target (what the pot must hold at draw 30) for the solver and startGame sim; this is a
    ///      CURRENT-pot floor (what a dormancy owes RIGHT NOW) for the per-draw distribution gate.
    ///      They were split at v1.04 [B-M-02] precisely because folding this decaying today-floor
    ///      into the season-end target throttled early-season prizes. See _requiredEndPotFloor's
    ///      FLOOR-SPLIT note for the other half of this pointer.
    /// @dev Returns what a dormancy RIGHT NOW would owe the senior tiers: unreleased VC seed plus
    ///      upfront-OG net principal (75% of gross) pro-rated by unplayed draws. Mirrors
    ///      activateDormancy()'s TIER 0 + TIER 1 exactly (same net rate, same drawsUnplayed
    ///      convention netted of resetDrawCount). Decays by ~1/30 of OG net principal per played
    ///      draw. Used ONLY by the distribution gate in _calculatePrizePools(): the gate caps each
    ///      draw so the carried pot stays at or above this, making the senior guarantee absolute
    ///      against the live pot. The current-draw casual + weekly-OG refund is intentionally NOT
    ///      included: dormancy fires only in IDLE, where each buy adds its own net to the pot at the
    ///      same instant it adds to the refund owed, so carried >= this floor implies
    ///      pot(IDLE) >= this floor + refund-owed, always. Casuals are self-covered on every branch.
    function _dormancyNowFloor() internal view returns (uint256) {
        uint256 _vcUnreleased = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
        uint256 _drawsPlayed = currentDraw > 1 ? currentDraw - 1 : 0;
        _drawsPlayed = _drawsPlayed > resetDrawCount ? _drawsPlayed - resetDrawCount : 0;
        if (_drawsPlayed > TOTAL_DRAWS) _drawsPlayed = TOTAL_DRAWS;
        uint256 _drawsUnplayed = TOTAL_DRAWS - _drawsPlayed;
        // upfrontOGCount is the count as of the last snapshot; it only falls between snapshots
        // (OGs lose status, never gain), so this over-reserves rather than under-reserves. Safe.
        uint256 _ogNetPrincipal = upfrontOGCount * OG_UPFRONT_COST * (10000 - UF_OG_TREASURY_BPS) / 10000;
        uint256 _ogProRata = _drawsUnplayed > 0 ? _ogNetPrincipal * _drawsUnplayed / TOTAL_DRAWS : 0;
        return _vcUnreleased + _ogProRata;
    }

    function _snapshotOGObligation() internal {
        uint256 currentOGs = upfrontOGCount + earnedOGCount;
        uint256 newObligation = currentOGs * OG_UPFRONT_COST;
        // [v1.58-P3] /10000 exact. /9000 buffer removed -- geometric solver provides
        //            the protective floor directly. DRAW30_PRIZE_RESERVE added to planning floor.
        // [CRE v0.2 / HIGH-01] VC unreleased seed added to floor so solver tracks it every draw.
        // [CRE v1.04 / FLOOR-SPLIT] requiredEndPot is the ENDGAME target only (season-end) for the
        // solver. The live dormancy-now floor is separate (_dormancyNowFloor). [Was max() pre-v1.04.]
        // Priced against newObligation (this draw's recomputed OG obligation), not the stored one.
        uint256 newRequired = _requiredEndPotFloor(newObligation);
        if (newObligation == ogEndgameObligation && newRequired == requiredEndPot) return;
        uint256 oldObligation = ogEndgameObligation; uint256 oldRequired = requiredEndPot;
        ogEndgameObligation = newObligation; requiredEndPot = newRequired;
        emit OGObligationSnapshot(currentDraw, oldObligation, newObligation, oldRequired, requiredEndPot, currentOGs);
    }

    // ── [v1.58-P3] Geometric breath solver ───────────────────────────────────

    /// @dev [v1.58-P3] Binary search for the maximum breathBps such that the pot
    ///      projected over `drawsLeft` draws (with `revPerDraw` net revenue each)
    ///      remains >= `floor` at the end of the season. At draw d: targets
    ///      pot >= floor after (TOTAL_DRAWS - d) more draws given estimated revenue. Covers both OG
    ///      endgame obligation AND DRAW30_PRIZE_RESERVE at game close.
    ///      24 iterations: precision < 1 BPS on [0, breathRailMax].
    ///      Gas: 24 * drawsLeft iterations max (24 * 29 = 696 at draw 1 -- safe).
    ///      drawsLeft max is 29 (draw 1 completed; draw 0 never calls the solver).
    /// @param pot         Current prizePot (USDC 6-dec).
    /// @param drawsLeft   Draws still to be played after the current completed draw.
    ///                    Caller passes (TOTAL_DRAWS - currentDraw). At draw 1 completed: 29.
    /// @param floor       Minimum pot required at draw 30 (requiredEndPot).
    /// @param revPerDraw  Estimated net casual ticket revenue per draw.
    /// @return breathBps  Maximum safe breath rate, clamped to [breathRailMin, breathRailMax].
    function _solveGeometricBps(
        uint256 pot,
        uint256 drawsLeft,
        uint256 floor,
        uint256 revPerDraw
    ) internal returns (uint256 breathBps) {
        // [v2.06] view removed -- function emits SolverDistressSignal on insolvent path.
        // Cannot be called from view/pure contexts. Only caller: _checkAutoAdjust() (internal).
        if (drawsLeft == 0 || pot == 0) return breathRailMin;
        // Insolvent scenario: pot + all future revenue cannot reach the required floor
        // even with zero distribution. No breath value can satisfy the floor.
        // Return breathRailMin as the least-damaging option -- startGame() solvency
        // check should have caught this before deployment.
        // Linear upper bound: at breathBps=0 no prizes are distributed, pot grows by
        // exactly revPerDraw per draw -- equivalent to _simGeomPot(pot, 0, drawsLeft, revPerDraw).
        // Overflow safe: drawsLeft <= 29, revPerDraw is EMA-bounded by actual ticket revenue.
        uint256 projEnd = pot + revPerDraw * drawsLeft;
        // [v2.05] Emit distress signal for operator monitoring on insolvent path.
        if (projEnd <= floor) {
            emit SolverDistressSignal(currentDraw, pot, floor, drawsLeft, projEnd);
            return breathRailMin;
        }
        uint256 lo = 0;
        uint256 hi = breathRailMax;
        for (uint256 i = 0; i < GEOM_SOLVER_ITERS; i++) {
            uint256 mid = (lo + hi + 1) / 2; // ceiling to avoid infinite loop at lo+1==hi
            if (_simGeomPot(pot, mid, drawsLeft, revPerDraw) >= floor) {
                lo = mid; // mid is safe -- try higher
            } else {
                hi = mid - 1; // mid overshoots -- try lower
            }
        }
        if (lo < breathRailMin) return breathRailMin;
        if (lo > breathRailMax) return breathRailMax;
        return lo;
    }

    /// @dev [v1.58-P3] Simulate pot evolution over `n` draws.
    ///      Each draw: pot loses breathBps% * (1 - SEED_BPS/10000) (seed is returned).
    ///      Then pot gains revPerDraw (estimated casual net revenue).
    ///      Pure: no state reads. Used exclusively by _solveGeometricBps.
    ///      [v1.62] Does not model draw30BonusFund accumulation or draw-30 injection.
    ///      The bonus siphon (3%) comes from weeklyPool and is therefore embedded in
    ///      the `lost` term -- no separate deduction needed. Pot decay is correct.
    ///      The draw-30 bonus injection is absent -- simulation underestimates draw-30
    ///      pot by draw30BonusFund. Conservative direction.
    /// @param pot         Starting pot value (USDC 6-dec).
    /// @param breathBps   Breath rate to simulate (BPS).
    /// @param n           Number of draws to simulate.
    /// @param revPerDraw  Revenue added each simulated draw.
    /// @return            Pot value after n draws.
    function _simGeomPot(
        uint256 pot,
        uint256 breathBps,
        uint256 n,
        uint256 revPerDraw
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < n; i++) {
            // Net fraction leaving pot = breathBps% of (1 - SEED_BPS/10000).
            // SEED_BPS portion is returned to pot each draw so does not compound out.
            uint256 lost = pot * breathBps * (10000 - SEED_BPS) / 100_000_000;
            pot = pot > lost ? pot - lost : 0;
            pot += revPerDraw;
        }
        return pot;
    }

    // ── Exhale floor governance ────────────────────────────────────────────────

    /// @notice Proposes a new exhale floor release threshold. Owner only. 48h timelock.
    /// @dev [v1.60] newBps must be in [8000, 20000]. Values outside this range revert.
    ///      8000 (80%): floor holds until deep distress -- prioritises prize experience.
    ///      20000 (200%): floor releases proactively -- prioritises solvency.
    ///      Default 12000 (120%) is the recommended balanced setting.
    /// @param newBps  New threshold in BPS. Must be in [8000, 20000].
    function proposeExhaleFloorRelease(uint256 newBps) external onlyOwner {
        if (gamePhase != GamePhase.ACTIVE) revert WrongPhase();
        if (newBps < 8000) revert BelowMinimum();
        if (newBps > 20000) revert ExceedsLimit();
        if (pendingExhaleFloorReleaseTime != 0) revert TimelockPending();
        pendingExhaleFloorReleaseBps = newBps;
        pendingExhaleFloorReleaseTime = block.timestamp + PRIZE_RATE_TIMELOCK; // 48h
        emit ExhaleFloorReleaseProposed(newBps, pendingExhaleFloorReleaseTime);
    }

    /// @notice Executes a pending exhale floor release proposal after timelock.
    /// @dev [v1.60] Reverts TooEarly() if called before the 48h timelock expires.
    ///      Reverts NoTimelockPending() if no proposal is pending.
    function executeExhaleFloorRelease() external onlyOwner {
        if (pendingExhaleFloorReleaseTime == 0) revert NoTimelockPending();
        if (block.timestamp < pendingExhaleFloorReleaseTime) revert TooEarly();
        uint256 oldBps = exhaleFloorReleaseBps;
        exhaleFloorReleaseBps = pendingExhaleFloorReleaseBps;
        pendingExhaleFloorReleaseBps = 0;
        pendingExhaleFloorReleaseTime = 0;
        emit ExhaleFloorReleaseUpdated(oldBps, exhaleFloorReleaseBps);
    }

    /// @notice Cancels a pending exhale floor release proposal.
    function cancelExhaleFloorRelease() external onlyOwner {
        if (pendingExhaleFloorReleaseTime == 0) revert NoTimelockPending();
        uint256 cancelled = pendingExhaleFloorReleaseBps;
        pendingExhaleFloorReleaseBps = 0;
        pendingExhaleFloorReleaseTime = 0;
        emit ExhaleFloorReleaseCancelled(cancelled);
    }

    /// @dev [v1.58-P3] Called each draw to recompute breathMultiplier via geometric solver.
    ///      EMA decays toward 0 on zero-revenue draws -- if casuals stop buying, the
    ///      revenue estimate tightens and solver becomes more conservative. Safe.
    function _checkAutoAdjust() internal {
        // [v1.58-P3] Pre-lock branch removed -- obligationLocked is always true from draw 1.
        if (ogEndgameObligation == 0) return;
        // [v2.01] B-2.00-02: EMA updates unconditionally -- breath override cooldown
        // must not stall revenue tracking. Solver decisions still skip during lock.
        // [v1.58-P3] EMA revenue update: always blend, even zero-revenue draws.
        // Zero-revenue draws decay the estimate toward 0, preventing stale-high
        // estimates from allowing excess breath when ticket sales fall.
        // Note: currentDrawNetTicketTotal includes weekly OG ticket revenue (reliable floor --
        // OGs must buy or lose status) plus variable casual revenue. Seed at startGame() was
        // casual-only (committedDoubleCount used to distinguish single/double ticket buyers),
        // so EMA underestimates actual revenue in early high-OG draws.
        // Solver applies slightly lower breath than necessary -- conservative from a solvency standpoint.
        // In OG-heavy seasons, OG ticket revenue inflates the EMA above pure casual
        // revenue. This is safe: OGs must buy or lose status (guaranteed floor).
        // If OGs lose status mid-season, EMA decays toward actual casual revenue
        // within ~2-3 draws (3:1 blend). Delta closes as EMA converges.
        // 3 parts historical, 1 part current draw.
        // Fast decay: ~2-3 draws to halve if revenue drops to zero
        // (factor 0.75 per draw: ln(0.5)/ln(0.75) ≈ 2.4 draws).
        // Conservative: lower estimate -> lower solver breath -> protects solvency.
        avgNetRevenuePerDraw = (avgNetRevenuePerDraw * 3 + currentDrawNetTicketTotal) / 4;
        // [v2.01] Solver skips during breath override cooldown (EMA still updates above).
        // C-2.00-02: exhaleFloorReleaseBps (120%) and this 80% gate are independent.
        if (breathOverrideLockUntilDraw > 0 && currentDraw <= breathOverrideLockUntilDraw) return;
        uint256 remainingDraws = currentDraw < TOTAL_DRAWS ? TOTAL_DRAWS - currentDraw : 0;
        if (remainingDraws == 0) return;
        // [v1.58-P3] Geometric solver: find max breath rate that leaves
        //            pot >= requiredEndPot (OG obligation + DRAW30_PRIZE_RESERVE) after all
        //            remaining draws, given estimated revenue per draw.
        uint256 optimalBreathBps = _solveGeometricBps(
            prizePot,
            remainingDraws,
            requiredEndPot,
            avgNetRevenuePerDraw
        );
        // [v1.60] Pot-health-gated exhale floor.
        // Normal operation (pot healthy): floor holds -- preserves prize escalation experience.
        // Distress (pot below exhaleFloorReleaseBps of requiredEndPot): floor releases
        //   immediately, no timelock. Solver output accepted to protect solvency.
        // Immediate release is intentional -- a timelock here would allow further draws
        // at full breath before protection activates, compounding the shortfall.
        if (currentDraw > INHALE_DRAWS && optimalBreathBps < breathMultiplier) {
            // Integer division truncates: exact 1.2x gives 11999 not 12000.
            // Gate fires ~0.01% earlier than stated threshold. Negligible in practice.
            bool potHealthy = requiredEndPot == 0 ||
                prizePot * 10000 / requiredEndPot >= exhaleFloorReleaseBps;
            if (potHealthy) {
                optimalBreathBps = breathMultiplier; // floor holds -- healthy pot
            }
            // else: solver output accepted -- floor released, solvency wins
        }
        if (optimalBreathBps != breathMultiplier) {
            emit BreathMultiplierAdjusted(breathMultiplier, optimalBreathBps, optimalBreathBps > breathMultiplier);
            breathMultiplier = optimalBreathBps; lastBreathAdjustDraw = currentDraw;
        }
    }

    /// @dev SYNC: pool list must stay in sync with getSolvencyStatus() external view,
    ///      this function (_computeBalanceAndAllocated), AND the inline SolvencyAlert
    ///      allocations in claimEndgame(), claimDormancyRefund(), and claimPrize().
    ///      Adding/removing a pool requires updates at all five locations:
    ///      getSolvencyStatus(), _computeBalanceAndAllocated() (here), claimEndgame(),
    ///      claimDormancyRefund(), and claimPrize() inline SolvencyAlert checks.
    ///      Returns actual USDC balance and sum of all non-prizePot allocations.
    ///      Called by _captureYield() and _captureYieldAndCheck() for surplus/deficit computation.
    ///      [v1.0] Tier loop uses i < 3. A 4th tier in any fork requires updating this function.
    ///      [v1.62] draw30BonusFund included to prevent _captureYield treating it as free surplus.
    ///      [v1.52] USDC-only: single balanceOf call (~800 gas). No aUSDC.
    function _computeBalanceAndAllocated() internal view returns (uint256 actualBalance, uint256 nonPotAllocated) {
        actualBalance = IERC20(USDC).balanceOf(address(this)); // [v1.52] USDC only, no aUSDC
        uint256 tierPoolsTotal;
        for (uint256 i = 0; i < 3; i++) tierPoolsTotal += tierPools[i]; // [v1.0] 3 tiers
        nonPotAllocated = treasuryBalance + totalUnclaimedPrizes + endgameOwed
            + dormancyOGPool + dormancyCasualRefundPool + dormancyCommitmentPool + dormancyPerHeadPool
            + tierPoolsTotal + currentDrawSeedReturn
            + resetDrawRefundPool + resetDrawRefundPool2 + commitmentRefundPool + totalForceDeclineRefundOwed
            + draw30BonusFund
            + dormancyVCPool + vcReturnOwed + vcBonusEscrow; // [CRE v0.1] SmartEarn; [CRE v0.4] escrow added
    }

    /// @dev [v1.52] Operational profile change from Aave variant.
    ///      In the Aave variant, YieldCaptured fired regularly as Aave interest accrued.
    ///      In v1.52 (no Aave), YieldCaptured fires ONLY if USDC is sent directly to the
    ///      contract (accidental transfer, manual top-up, etc.). The function is correct as
    ///      a safety net -- any surplus above tracked allocations is added to prizePot.
    ///      Event name YieldCaptured is retained for ABI stability (renaming would break
    ///      subgraphs). Note: semantics shifted from "yield" to "unexpected inflow".
    function _captureYield() internal {
        (uint256 actualBalance, uint256 nonPotAllocated) = _computeBalanceAndAllocated();
        if (actualBalance > nonPotAllocated) {
            uint256 realPot = actualBalance - nonPotAllocated;
            if (realPot > prizePot) { uint256 yieldCaptured = realPot - prizePot; prizePot = realPot; emit YieldCaptured(yieldCaptured); }
        }
    }

    function _captureYieldAndCheck() internal {
        (uint256 actualBalance, uint256 nonPotAllocated) = _computeBalanceAndAllocated();
        if (actualBalance > nonPotAllocated) {
            uint256 realPot = actualBalance - nonPotAllocated;
            if (realPot > prizePot) { uint256 yieldCaptured = realPot - prizePot; prizePot = realPot; emit YieldCaptured(yieldCaptured); }
        }
        uint256 totalAllocated = prizePot + nonPotAllocated;
        if (actualBalance + SOLVENCY_TOLERANCE < totalAllocated) revert SolvencyCheckFailed();
    }

    /// @dev [v1.0] CHANGED: 3-tier pool sizes with updated BPS.
    ///      [v1.62] distributable = 87% of weeklyPool (10% seed + 3% bonus siphon).
    ///      T1: JP_BPS/10000 of distributable = 40% ~= 34.8% of weeklyPool.
    ///      T2: P2_BPS/10000 of distributable = 35.56% ~= 30.9% of weeklyPool.
    ///      T3: remainder of distributable ~= 21.3% of weeklyPool.
    ///      Seed: SEED_BPS/10000 of weeklyPool = 10% rollover to prizePot.
    ///      No JPMissRedistributed -- T1 always has winners.
    ///      Draw 30 (TOTAL_DRAWS) uses full surplus path, same as draw 52 in 1Y game.
    function _calculatePrizePools() internal {
        uint256 weeklyPool; uint256 distributable;
        if (currentDraw == TOTAL_DRAWS) {
            // Draw 30: surplus above estimated OG holdback plus the season-long bonus fund.
            // [v1.62] draw30BonusFund was siphoned from draws 1-29 to make D30 the season peak.
            // [v2.27] D-1 FIX: holdback changed from gross ($600/OG) to curve ceiling ($540/OG).
            // [v2.29] D-2 FIX: holdback uses 29-draw running-average estimate.
            // [v2.30] TRUE SSoT: ogRatioDrawCount=29 at both holdback time (here) and at
            // closeGame() time because _finalizeWeekCore() excludes draw 30 from the
            // accumulator (currentDraw < TOTAL_DRAWS guard). Both paths read identical
            // 29-draw state by design. Surplus = integer dust only (cents).
            // OG ratio is monotonically non-increasing (frozen denominator, falling count).
            // MAX_TARGET_RETURN_BPS fallback: guard unreachable at draw 30 (count=29
            // guaranteed since accumulator starts at draw 1 finalization).
            uint256 estReturnBps = ogRatioDrawCount > 0
                ? _computeTargetReturnBps(ogRatioBpsAccumulator / ogRatioDrawCount)
                : MAX_TARGET_RETURN_BPS;
            // [CRE v0.2 / HIGH-01] Reserve unreleased VC seed before computing surplus.
            // Without this, the full pot (including VC seed) distributes to draw-30 winners.
            // closeGame() then tries to pay the VC from treasury — which has no reservation.
            // Pattern mirrored from Weather20_1Y v2.44 draw-52 surplus path.
            // [CRE v0.6 / INFO-04 / SYNC] LOAD-BEARING PAIR with closeGame(). This holdback keeps
            // _vcUnreleased in prizePot past draw-30 distribution so it survives into closeGame(),
            // where vcReturnOwed is sourced from the resulting surplus + treasury. If this holdback
            // formula changes, the closeGame() VC reservation MUST be reviewed in lockstep or the
            // VC return silently underfunds. See matching SYNC note in closeGame().
            uint256 _vcUnreleased = VC_SEED > seedReleased ? VC_SEED - seedReleased : 0;
            uint256 holdback = (obligationLocked ? ogEndgameObligation * estReturnBps / 10000 : 0) + _vcUnreleased;
            uint256 surplus = prizePot > holdback ? prizePot - holdback : 0;
            weeklyPool = surplus + draw30BonusFund;
            currentDrawSeedReturn = 0;
            prizePot -= surplus;
            // draw30BonusFund was siphoned from prior draws' weeklyPool. The USDC flowed
            // through prizePot via the weekly siphon, but draw30BonusFund was never credited
            // to prizePot's accounting variable -- so no prizePot deduction is needed here.
            // Adding to weeklyPool above completes consumption.
            // NOTE: draw30BonusFund is already net of treasury. The weekly siphon
            // operated on post-treasury prize pool funds (treasury deducted at ticket
            // sale time). No additional TREASURY_BPS deduction applies to the bonus
            // portion at draw 30.
            draw30BonusFund = 0;
            // [v1.69] Defensive zero. currentDrawBonusContribution was already cleared
            // in draw 29's _finalizeWeekCore; draw30BonusFund was consumed above (=0).
            // Belt-and-suspenders: ensures emergencyResetDraw() cannot double-deduct
            // from an already-zeroed draw30BonusFund if reset fires during draw-30
            // MATCHING or DISTRIBUTING phase.
            // Even without this guard, the underflow branch in emergencyResetDraw() would
            // catch it safely (draw30BonusFund = 0 when fund < contribution).
            currentDrawBonusContribution = 0;
            distributable = weeklyPool;
        } else {
            uint256 rate = getCurrentPrizeRate();
            weeklyPool = prizePot * rate / 10000;

            // [CRE v1.04 / DORM-GATE] Health-line and refund reservation removed [B-L-01].
            // Cap this draw's base distribution so the carried pot (net of the SEED_BPS rollover
            // that returns at finalize) stays at or above the senior dormancy-now floor. This
            // makes the senior guarantee (VC + upfront-OG net principal) absolute against the LIVE
            // pot, not just the forward projection. The current-draw casual + weekly-OG refund is
            // NOT reserved: it is self-covering (dormancy fires only in IDLE, where carried >=
            // seniorFloor implies pot(IDLE) >= seniorFloor + refund-owed on every branch), so the
            // old refund/_fullFloor/health-line machinery was protectively vacuous and introduced
            // a non-monotonic kink at the line. Removing it loses zero protection and makes casual
            // funding of early-season prizes exactly true. Only the base pool is capped here; any
            // VC seed supplement below is floor-neutral (releasing seed lowers this floor's VC term
            // by the same amount, and 10% rolls back), proven and simulated safe at v1.03a.
            //
            // [CRE v1.05 / DORM-GATE transient, B-L-01 note] Precise statement of the guarantee:
            // this cap holds the carried pot at or above _dormancyNowFloor() as computed for THIS
            // draw. On a draw where the seed supplement fires below, _seedSupp is added to
            // weeklyPool AFTER this cap, so intra-draw the carried pot can sit up to
            // _seedSupp * (1 - SEED_BPS/10000) BELOW this draw's floor. That dip is offset at the
            // NEXT finalize, when seedReleased += _seedSupp lowers _dormancyNowFloor()'s own VC
            // term by exactly _seedSupp (same conservative, self-healing transient as the v0.13
            // solver-transient note, same direction). It is never observed by a claim: dormancy
            // can only activate in IDLE (drawPhase gate), never mid-draw. So the senior floor holds
            // AT FINALIZE, not intra-draw, on supplement draws; fund impact is none. The cap is
            // deliberately left against _dormancyNowFloor() alone rather than netting the pending
            // supplement, to keep the two floors [FLOOR-SPLIT] cleanly decoupled.
            {
                uint256 _target = _dormancyNowFloor();
                uint256 _maxWeekly = prizePot > _target
                    ? (prizePot - _target) * 10000 / (10000 - SEED_BPS)
                    : 0;
                if (weeklyPool > _maxWeekly) { weeklyPool = _maxWeekly; }
            }

            // [CRE v0.1 / SmartEarn] Seed supplement: additive prize boost from VC_SEED.
            // Fires when cumulative season treasury >= SEED_RELEASE_THRESHOLD and ratio > 0.
            // seedSupp is already in prizePot (VC seeded it); this releases it to weekly prizes.
            if (VC_SEED > 0 && cumulativeSeasonTreasury >= SEED_RELEASE_THRESHOLD && seedReleaseRatioBps > 0) {
                uint256 _maxRel = cumulativeSeasonTreasury * seedReleaseRatioBps / 10000;
                if (_maxRel > VC_SEED) _maxRel = VC_SEED;
                uint256 _newlyRel = _maxRel > seedReleased ? _maxRel - seedReleased : 0;
                if (MAX_SEED_PER_DRAW_BPS > 0 && _newlyRel > 0) {
                    uint256 _perDrawCap = VC_SEED * MAX_SEED_PER_DRAW_BPS / 10000;
                    if (_newlyRel > _perDrawCap) _newlyRel = _perDrawCap;
                }
                if (_newlyRel > 0) {
                    uint256 _seedSupp = _newlyRel * rate / 10000;
                    if (_seedSupp > _newlyRel) _seedSupp = _newlyRel;
                    uint256 _potLeft = prizePot > weeklyPool ? prizePot - weeklyPool : 0;
                    if (_seedSupp > _potLeft) _seedSupp = _potLeft;
                    if (_seedSupp > 0) {
                        weeklyPool              += _seedSupp;
                        // [CRE v0.8 / CR-L-01] seedReleased increment DEFERRED to
                        // _finalizeWeekCore() (guarded !isResetFinalize). Counting the
                        // supplement as released here (before the draw is known-good) meant an
                        // emergency reset mid-DISTRIBUTING rolled back the full supplement even
                        // when part had been distributed, desyncing seedReleased and over-stating
                        // vcReturnOwed at closeGame(). Deferring means seedReleased only moves when
                        // a draw finalizes cleanly; a reset never reaches finalize, so no rollback
                        // is needed. currentDrawSeedSupplement carries the value to the increment.
                        currentDrawSeedSupplement = _seedSupp;
                        emit SeedSupplementPaid(currentDraw, _seedSupp, seedReleased + _seedSupp);
                    }
                }
            }

            prizePot -= weeklyPool;
            // Solver reads prizePot post-weeklyPool-deduction (remaining pot after
            // this draw's distributions). Correct: solver plans remaining draws from
            // the reduced base, not the pre-distribution pot.
            // SUPPLEMENT TRANSIENT [CRE v0.13]: on a draw where a seed supplement fired above,
            // seedReleased is NOT yet incremented (deferred to _finalizeWeekCore per CR-L-01),
            // so requiredEndPot (the solver floor, = obligation*rate + reserve + (VC_SEED -
            // seedReleased)) still counts this draw's supplement as unreleased even though the
            // pot has already given it up to weeklyPool. For this single solver call the floor
            // is overstated by ~one supplement while the pot is already lower. Direction is
            // CONSERVATIVE (breath is set slightly lower than strictly necessary). It self-heals
            // at finalize when seedReleased increments and _snapshotOGObligation() recomputes
            // requiredEndPot downward. No behavioural change warranted.
            _checkAutoAdjust();
            currentDrawSeedReturn = weeklyPool * SEED_BPS / 10000; // 10% rollover
            // [v1.62] Siphon draw-30 bonus before distributing to players.
            // Both seed (10%) and bonus (3%) taken from weeklyPool.
            // distributable = weeklyPool * (1 - SEED_BPS/10000 - DRAW30_BONUS_BPS/10000) = 87%.
            // Taken from weeklyPool base -- no compounding between seed and bonus.
            // _calculatePrizePools() is only called from resolveWeek(), never
            // from reset-finalize paths. Reset draws do not contribute to the bonus.
            uint256 bonusContribution = weeklyPool * DRAW30_BONUS_BPS / 10000;
            draw30BonusFund += bonusContribution;
            currentDrawBonusContribution = bonusContribution; // [v1.68] track for reset rollback
            distributable = weeklyPool - currentDrawSeedReturn - bonusContribution;
        }
        // [v1.0] 3-tier pool allocation.
        tierPools[0] = distributable * JP_BPS / 10000;  // T1: 40% of distributable
        tierPools[1] = distributable * P2_BPS / 10000;  // T2: 35.56% of distributable
        tierPools[2] = distributable - tierPools[0] - tierPools[1];
        // T3: remainder ~21.3% of weeklyPool (24.4% of distributable).
        // Winner count is draw-schedule-dependent (see _getT3WinnerBps(); cutoff submitted by keeper).
    }

    /// @dev Updates streak tracking for addr after a confirmed buyTickets call.
    ///      Increments consecutiveWeeks when draw == lastActive + 1 (consecutive buy).
    ///      Resets streak to 1 when draw > lastActive + 1 (gap detected).
    ///      Fires EarnedOGQualified when consecutiveWeeks reaches WEEKLY_OG_QUALIFICATION_WEEKS.
    ///      qualifiedWeeklyOGCount decremented on streak reset for consistency.
    ///      Only called from buyTickets -- EarnedOGQualified always originates from a buy.
    function _updateStreakTracking(address addr) internal {
        PlayerData storage p = players[addr];
        uint256 lastActive = p.lastActiveWeek;
        uint256 current = currentDraw;
        if (lastActive == 0) { p.consecutiveWeeks = 1; p.lastActiveWeek = current; p.firstPlayedDraw = current; return; }
        if (lastActive == current) return;
        if (current == lastActive + 1) {
            uint256 prevWeeks = p.consecutiveWeeks; p.consecutiveWeeks++; p.lastActiveWeek = current;
            if (p.isWeeklyOG && !p.weeklyOGStatusLost && prevWeeks < WEEKLY_OG_QUALIFICATION_WEEKS && p.consecutiveWeeks >= WEEKLY_OG_QUALIFICATION_WEEKS) { qualifiedWeeklyOGCount++; emit EarnedOGQualified(addr, current); }
            return;
        }
        uint256 prevStreak = p.consecutiveWeeks;
        if (p.isWeeklyOG && !p.weeklyOGStatusLost && prevStreak >= WEEKLY_OG_QUALIFICATION_WEEKS && qualifiedWeeklyOGCount > 0) { qualifiedWeeklyOGCount--; }
        p.consecutiveWeeks = 1; p.lastActiveWeek = current;
        if (p.isWeeklyOG && !p.weeklyOGStatusLost) { emit StreakBroken(addr, prevStreak); }
    }

    // [CRE v1.11a / DL-01] _upfrontOGCapReached() removed (deprecated, zero callers).

    /// @dev Returns true when weeklyOGCount reaches the available weekly OG slots.
    ///      [v1.57-P1] IMPORTANT: upfrontOGCount is now uncapped, so it can exceed
    ///      maxTotal (TOTAL_OG_CAP_BPS % of committed). When it does, maxEarned = 0
    ///      and registerAsWeeklyOG() reverts OGCapReached(). Operators should be
    ///      aware that heavy upfront OG uptake (>18% of committed) eliminates weekly
    ///      OG slots entirely. This is a logical consequence of removing the upfront cap.
    function _weeklyOGCapReached() internal view returns (bool) {
        uint256 denominator = gamePhase == GamePhase.PREGAME ? committedPlayerCount : ogCapDenominator;
        if (denominator == 0) return false;
        uint256 maxTotal = denominator * TOTAL_OG_CAP_BPS / 10000;
        if (maxTotal == 0) maxTotal = 1;
        uint256 maxEarned = maxTotal > upfrontOGCount ? maxTotal - upfrontOGCount : 0;
        return weeklyOGCount >= maxEarned;
    }

    function _isQualifiedForEndgame(PlayerData storage p) internal view returns (bool) {
        if (p.isUpfrontOG) return true;
        if (p.isWeeklyOG && !p.weeklyOGStatusLost && p.consecutiveWeeks >= WEEKLY_OG_QUALIFICATION_WEEKS) return true;
        return false;
    }

    function _countQualifiedOGs() internal view returns (uint256) { return upfrontOGCount + qualifiedWeeklyOGCount; }

    function _validatePrediction(uint256 prediction) internal pure {
        if (prediction == 0) revert InvalidPrediction();
        if (prediction > MAX_PREDICTION_CENTS) revert InvalidPrediction();
    }

    function _autoDefaultPrediction() internal view returns (uint256) {
        if (autoDefaultCents > 0) return autoDefaultCents;
        return defaultPrediction;
    }

    function _getWinnersForTier(uint256 tier) internal view returns (address[] storage) {
        if (tier == 0) return jpWinners;
        if (tier == 1) return p2Winners;
        return p3Winners; // [v1.0] tier index 2 = T3 prize pool (p3Winners). T4 pool removed in v1.0.
    }

    function _checkSequencer() internal view {
        if (SEQUENCER_FEED == address(0)) return;
        AggregatorV3Interface seqFeed = AggregatorV3Interface(SEQUENCER_FEED);
        try seqFeed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (answer != 0) revert SequencerNotReady();
            if (startedAt == 0 || startedAt > block.timestamp || block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) revert SequencerNotReady();
        } catch { revert SequencerNotReady(); }
    }

    function _readEthPrice() internal view returns (int256) {
        AggregatorV3Interface feed = AggregatorV3Interface(ethFeed);
        try feed.latestRoundData() returns (uint80 roundId, int256 price, uint256, uint256 updatedAt, uint80 answeredInRound) {
            if (updatedAt > block.timestamp) return 0;
            if (block.timestamp - updatedAt > FEED_STALENESS) return 0;
            if (answeredInRound < roundId) return 0;
            if (price <= 0) return 0;
            try AggregatorMinMax(ethFeed).minAnswer() returns (int192 minAns) { if (price <= int256(minAns)) return 0; } catch {}
            try AggregatorMinMax(ethFeed).maxAnswer() returns (int192 maxAns) { if (maxAns > 0 && price >= int256(maxAns)) return 0; } catch {}
            return price;
        } catch { return 0; }
    }

    function _readPriceFeed(address feedAddr) internal view returns (int256) {
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddr);
        try feed.latestRoundData() returns (uint80 roundId, int256 price, uint256, uint256 updatedAt, uint80 answeredInRound) {
            if (updatedAt > block.timestamp) return 0;
            if (block.timestamp - updatedAt > FEED_STALENESS) return 0;
            if (answeredInRound < roundId) return 0;
            if (price <= 0) return 0;
            try AggregatorMinMax(feedAddr).minAnswer() returns (int192 minAns) { if (price <= int256(minAns)) return 0; } catch {}
            try AggregatorMinMax(feedAddr).maxAnswer() returns (int192 maxAns) { if (maxAns > 0 && price >= int256(maxAns)) return 0; } catch {}
            return price;
        } catch { return 0; }
    }

    // ── [CRE v0.1 / SmartEarn] Internal + view helpers ──────────────────────────

    /// @dev Returns the VC performance bonus currently owed based on cumulativeSeasonTreasury.
    ///      Tiers are EXCLUSIVE: highest applicable pays only. Returns 0 if none hit.
    ///      [CRE v0.4] No longer called by closeGame() or sweepDormancyRemainder() — escrow handles
    ///      payment there. [CRE v0.9 / NS-L-02] withdrawTreasury() no longer calls this either; its
    ///      bonus-protection floor reads vcBonusEscrow and the tier thresholds directly. The ONLY
    ///      remaining caller is getVCBonusStatus() (view).
    function _vcBonusAmount() internal view returns (uint256) {
        if (VC_BONUS_TIER2_THRESHOLD > 0 && cumulativeSeasonTreasury >= VC_BONUS_TIER2_THRESHOLD)
            return VC_BONUS_TIER2_AMOUNT;
        if (VC_BONUS_TIER1_THRESHOLD > 0 && cumulativeSeasonTreasury >= VC_BONUS_TIER1_THRESHOLD)
            return VC_BONUS_TIER1_AMOUNT;
        return 0;
    }

    /// @notice Returns current seed release state for off-chain monitoring.
    /// @dev    [CRE v0.11 / NS-L-01] Return tags added (was untagged multi-value view).
    /// @return ratioBps             Current active seedReleaseRatioBps (governance-set).
    /// @return maxReleasable        CEILING only: cumulativeSeasonTreasury * ratioBps / 10000,
    ///                              capped at VC_SEED. This IGNORES the SEED_RELEASE_THRESHOLD gate
    ///                              and the per-draw MAX_SEED_PER_DRAW_BPS cap, so it is an upper
    ///                              bound, NOT a next-draw release prediction. Actual per-draw
    ///                              release is computed in _calculatePrizePools() and is typically
    ///                              lower. Do not use this to forecast the next supplement.
    /// @return released             Cumulative seed released to date (seedReleased).
    /// @return remaining            VC_SEED - seedReleased (0 if fully released).
    /// @return thresholdMet         True if cumulativeSeasonTreasury >= SEED_RELEASE_THRESHOLD
    ///                              (the gate maxReleasable ignores).
    /// @return pendingRatio         Pending governance ratio (0 if none pending).
    /// @return pendingEffectiveTime Timelock expiry for the pending ratio (0 if none).
    function getSeedReleaseStatus() external view returns (
        uint256 ratioBps,
        uint256 maxReleasable,
        uint256 released,
        uint256 remaining,
        bool    thresholdMet,
        uint256 pendingRatio,
        uint256 pendingEffectiveTime
    ) {
        uint256 _max = (VC_SEED > 0 && seedReleaseRatioBps > 0)
            ? cumulativeSeasonTreasury * seedReleaseRatioBps / 10000 : 0;
        if (_max > VC_SEED) _max = VC_SEED;
        return (
            seedReleaseRatioBps, _max, seedReleased,
            VC_SEED > seedReleased ? VC_SEED - seedReleased : 0,
            cumulativeSeasonTreasury >= SEED_RELEASE_THRESHOLD,
            pendingSeedReleaseRatioBps,
            seedReleaseRatioEffectiveTime
        );
    }

    /// @notice Returns SmartEarn bonus status for monitoring.
    /// @dev    [CRE v0.10 / NS-I-01] currentBonus is the NOMINAL tier figure (what the current
    ///         cumulativeSeasonTreasury tier implies). It is NOT the funded/committed amount. Post
    ///         SE-M-01, the funded truth is vcBonusEscrow: bonus is moved treasury->escrow at the
    ///         tier crossing inside buyTickets(), and that escrowed value is what the VC is actually
    ///         paid. Monitoring integrators tracking what the VC will receive should read vcBonusEscrow
    ///         (via getSolvencyStatus or direct), not currentBonus here.
    /// @dev    [CRE v0.11 / NS-L-01] Return tags added (was untagged multi-value view).
    /// @return enabled         True if tier 1 is configured (VC_BONUS_TIER1_THRESHOLD > 0).
    /// @return currentBonus    NOMINAL bonus for the current tier (see @dev; NOT the funded escrow).
    /// @return nextTier        Next uncrossed tier index (1 or 2); 0 if all tiers crossed or disabled.
    /// @return nextThreshold   cumulativeSeasonTreasury needed to reach nextTier; 0 if none.
    /// @return nextBonusAmount Nominal bonus at nextTier; 0 if none.
    /// @return treasuryToNext  Remaining cumulativeSeasonTreasury to nextTier; 0 if none.
    function getVCBonusStatus() external view returns (
        bool    enabled,
        uint256 currentBonus,
        uint256 nextTier,
        uint256 nextThreshold,
        uint256 nextBonusAmount,
        uint256 treasuryToNext
    ) {
        enabled = (VC_BONUS_TIER1_THRESHOLD > 0);
        // [CRE v0.14 / NS-I-02] Gate first: return before computing _vcBonusAmount() when disabled,
        // matching the gate-first house style elsewhere. Avoids wasted work in the disabled-config view.
        if (!enabled) return (false, 0, 0, 0, 0, 0);
        currentBonus = _vcBonusAmount();
        if (VC_BONUS_TIER1_THRESHOLD > 0 && cumulativeSeasonTreasury < VC_BONUS_TIER1_THRESHOLD) {
            return (true, currentBonus, 1, VC_BONUS_TIER1_THRESHOLD, VC_BONUS_TIER1_AMOUNT,
                VC_BONUS_TIER1_THRESHOLD - cumulativeSeasonTreasury);
        }
        if (VC_BONUS_TIER2_THRESHOLD > 0 && cumulativeSeasonTreasury < VC_BONUS_TIER2_THRESHOLD) {
            return (true, currentBonus, 2, VC_BONUS_TIER2_THRESHOLD, VC_BONUS_TIER2_AMOUNT,
                VC_BONUS_TIER2_THRESHOLD - cumulativeSeasonTreasury);
        }
        return (true, currentBonus, 0, 0, 0, 0);
    }

    /// @dev [v1.52] Simplified -- direct USDC transfer only. No Aave withdrawal path.
    function _withdrawAndTransfer(address recipient, uint256 amount) internal {
        IERC20(USDC).safeTransfer(recipient, amount);
    }

    // ── Aave governance (inherited unchanged) ─────────────────────────────────

    // [v1.52] Aave governance functions removed:
    // _fullExitAave(), proposeAaveExit(), executeAaveExit(),
    // cancelAaveExit(), activateAaveEmergency() -- all removed.
}
