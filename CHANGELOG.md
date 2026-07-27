[CHANGELOG.md](https://github.com/user-attachments/files/30387661/CHANGELOG.md)
# BullsEthCRE, CRE Arc, Consolidated Changelog (v0.1 to v1.17)

Substantive findings and fixes only. NatSpec, version-string bumps, and inline-comment hygiene are summarised per version, not enumerated. Severities are as graded in each version's own changelog (C/H/M/L, plus INFO where material). This document covers the CRE fork from the point it branched off BullsEth v2.35.

Source coverage note (honest): the v0.1 to v1.06 entries are built from the per-version changelog files on hand. Two gaps remain by design. v0.4 is missing from that set (the record jumps v0.3 to v0.5, so v0.4's own findings are inferred only from later back-references). v1.07 to v1.11a are not re-consolidated here; they are summarised in one line at the jump before the v1.11b entry. From v1.12 onward the entries record measured behaviour rather than reasoned behaviour, because the Foundry suite was running from that point.

---

## The arc in one paragraph

v0.1 forked BullsEth v2.35 and bolted on three things: a flat 25% treasury, a rescaled OG return curve (10 to 50 percent, down from 30 to 90), and the SmartEarn VC-earnout layer. Everything from v0.2 to v0.13 is the economics being hardened around that new VC money: making sure the seed is never paid twice, never stranded, and never left out of the solvency floor, and making dormancy fair to every participant class. v0.13 reached a clean 0C/0H/0M/0L economics state. v1.0 migrated the keeper seam onto Chainlink CRE (onReport dispatch). v1.01 to v1.06 then reworked the solvency floor twice (the headline being the v1.04 floor split) and added the VC spent-seed return model. v1.12 to v1.17 is the audit arc: an adversarial pass modelled the external trust boundary rather than the internal accounting and found two Criticals that per-version delta audits had structurally been unable to see.

---

## v0.1, Fork from BullsEth v2.35 (the CRE baseline)

Not a fix pass. This is the fork that establishes the CRE demo. Material changes:

* Treasury flattened to 25% across all paths (`TREASURY_BPS` and `UF_OG_TREASURY_BPS` both 1500 to 2500).
* OG return curve rescaled: `MAX_TARGET_RETURN_BPS` 9000 to 5000, `TARGET_RETURN_FLOOR_BPS` 3000 to 1000. `_computeTargetReturnBps` now returns 50 percent at 20 percent OG or under, linear down to 10 percent at 100 percent OG.
* SmartEarn (VC earnout) ported from Weather20 v2.44: a third party seeds the pot (`VC_SEED`), receives unreleased principal back at close, plus an exclusive-tier performance bonus. Adds eight immutables, two constants, twelve-plus state variables, five new functions, and the seed-release governance path.
* Dormancy waterfall revised to five tiers, with a new TIER 0 (VC unreleased seed) sitting senior to the OG pool.

All rate values are explicitly placeholders, adjustable pre-mainnet.

## v0.2, HIGH-01 and the seed-in-the-floor problem

* **HIGH-01 (the critical fix of the arc): VC seed spent twice at draw 30.** The draw-30 surplus path distributed the entire pot above the OG holdback to winners, and the VC's unreleased seed was inside that surplus. `closeGame()` then tried to pay the seed from a treasury that had no reservation for it, so in the common case (seed threshold rarely hit in 30 draws) the VC was structurally short their principal. Secondary root cause: `requiredEndPot` had no VC-seed term, so the geometric solver never knew to protect it. Fixed at four sites (draw-30 holdback, `startGame` obligation lock, `_finalReturnCalibration`, `_snapshotOGObligation`), mirroring the Weather20 draw-52 pattern. The `VC_SEED - seedReleased` term self-corrects as seed is released, so the solver never over-protects already-distributed seed.
* **LOW-01: `seedPot()` access control.** Was `external` with no caller restriction and no phase gate; any address could donate the seed with no recourse, and a post-CLOSED call would strand funds. Added `onlyOwner` and a PREGAME gate.
* LOW-02: stale-NatSpec sweep (the v2.35 15%/9000-era rate comments), summarised.

## v0.3, MEDIUM-01, pro-rata dormancy fairness

* **MEDIUM-01: pro-rata OG dormancy refund by unplayed draws.** v0.1/v0.2 refunded every OG the same target-return amount (~$300 on a $600 stake) regardless of how many draws they had played, so on an early shutdown an OG who played 4 draws got the same as one who played 29, and the prepaid-but-unplayed value leaked down to casuals. Fixed to `netPaid * drawsUnplayed / TOTAL_DRAWS` (treasury and consumed draws non-refundable). New state var `dormancyDrawsPlayed` snapshots `currentDraw - 1` at activation.
* **LOW (SYNC): SmartEarn pools missing from three SolvencyAlert sums.** `dormancyVCPool` and `vcReturnOwed` were added in v0.1 but three inline SolvencyAlert allocations (in `claimDormancyRefund`, `claimEndgame`, `claimPrize`) were not updated, so a real SmartEarn shortfall would fail to trigger the alert. Added to all three.
* Version string and remaining NatSpec, summarised. Also logged a deploy-runbook footgun (not a bug): if the owner forgets `seedPot()` before `startGame()`, start reverts `PotBelowTrajectory` because the pot lacks the seed the floor now expects. Fails safe.

## v0.4, (missing from source set)

No changelog file available. From later back-references, v0.4 appears to have moved the VC bonus/return accounting to an escrow model (the `vcBonusEscrow` referenced from v0.5 onward) and moved weekly OGs from the OG dormancy pool into the casual (current-draw) pool. Treat this entry as incomplete pending the v0.4 file.

## v0.5, Two dormancy edge fixes

* **DR-M-02 (MEDIUM): pregame weekly-OG net missing from the draw-1 dormancy pool.** Pregame weekly OGs get `lastBoughtDraw = 1` and `lastTicketCost = $20` but never pass through `buyTickets()` for draw 1, so their cost was never added to the weekly-OG net total. The draw-1 dormancy window is reachable (24h propose + 48h pick-deadline both clear before the 72h cooldown), so they could claim from a casual pool that was sized without their contribution, draining it ahead of genuine casuals. Fixed with one line in `startGame()` folding `pregameWeeklyOGNetTotal` into the weekly-OG net total; the tracking infrastructure already existed.
* **DR-L-01 (LOW): weekly OGs diluting the per-head pool without claiming.** Weekly OGs were counted in the per-head denominator and sized into the pool, but the weekly-OG branch in `claimDormancyRefund()` had no per-head block, so their share was never claimed, shrank everyone else's, and was swept to the beneficiary. Added the per-head block.
* CL-1: full CRE changelog block added to the header; the "DORMANCY INHERITED UNCHANGED" line corrected to "MODIFIED IN CRE v0.1 to v0.5". NS sweep (6 comments), summarised.

## v0.6, Failed-pregame seed return, OG notice-period symmetry

* **MEDIUM-01: VC seed now returned on a failed pregame launch.** If `seedPot()` was called but `startGame()` never fired, the only close path (`sweepFailedPregame()`) sent the entire residual, seed included, to `PROTOCOL_BENEFICIARY`; the VC has no PlayerData entry so no refund path caught them. The mirror image of the seed-defence guard. Fixed by returning the deposited seed to `VC_SEED_RETURN_ADDRESS` before the beneficiary sweep, in one transaction, with a `min(VC_SEED, usdcBalance)` cap. New event `FailedPregameSeedReturned`.
* **LOW-01: `registerAsOG()` now honours the startGame notice period.** `registerAsWeeklyOG()` blocked registration during the 72h notice window; `registerAsOG()` did not, so an upfront OG registering just before start had their 72h decline window silently truncated and then lost cancellation entirely at start. Fixed by mirroring the weekly-OG `TimelockPending` guard. Removes the trap rather than documenting it.
* INFO-01 to INFO-04: stale 15%-treasury docs swept, the 90-day dormancy VC delay documented, the PREGAME withdraw guard moved to the top for a deterministic revert reason, and the draw-30/closeGame seed-reservation pair cross-referenced. Summarised.

## v0.7, Dormancy per-head denominator on claimable heads

* **M-01 (MEDIUM): per-head denominator sized on heads that cannot claim.** The denominator counted every active weekly OG, including one who had not bought the current draw (status not yet lost because matching had not run). That non-buyer hits `NothingToClaim` before the per-head block, so a loyal active OG got a silent zero on an operator shutdown, and their uncounted slice shrank everyone else's and was swept. Fixed with a new `currentDrawWeeklyOGBuyerCount` (incremented once per active weekly-OG buy, cleared each draw and on reset); denominator becomes `upfrontOGCount + currentDrawWeeklyOGBuyerCount + weeklyNonOGPlayers.length`, with each term mapping to exactly one claim branch and no address double-counted. Secondary fix: the upfront-OG branch reverted on an empty OG pool before the per-head block, confiscating the per-head slice; restructured so principal computes to 0 cleanly and per-head is still paid.
* L-04 (LOW): constructor `_vcSeedReturnAddress` was validated against zero and USDC but not `address(this)`, which would strand VC principal in the contract. Added the check. L-01/L-02 (version string, VC-param NatSpec) summarised. L-03 (one-draw `requiredEndPot` under-reservation after reset) left as a documented self-healing transient.

## v0.8, checkSolvency parity, seed-release deferral

* **CR-M-02 (MEDIUM): `checkSolvency()` floor missing the unreleased VC seed.** The PREGAME pre-flight preview dropped the seed term that `startGame()`'s `requiredEndPot` enforces, so a deployment could pass the preview yet fail or misprice at start. Added `_vcUnreleasedCS` so the preview is bit-identical to the enforced floor.
* **CR-L-01 (LOW): `seedReleased` over-rollback on emergency reset, fixed by deferral.** `emergencyResetDraw()` rolled back the full `currentDrawSeedSupplement` from `seedReleased` on the premise "USDC already returned to prizePot," which is false if a reset fires mid-DISTRIBUTING after partial credit; `closeGame()` then over-stated `vcReturnOwed`. Fixed by moving the `seedReleased +=` increment out of `_calculatePrizePools()` and into `_finalizeWeekCore()` guarded by `!isResetFinalize`, so a reset never counts the supplement as released. This deferral becomes load-bearing for several later notes. Placement is critical: the increment sits before the supplement clear and before the two obligation-recompute readers.
* NS-L-01: `requiredEndPot` formula docs updated to include the VC term. Summarised.

## v0.9, Phantom treasury balance on failed-pregame close

* **B-L-01 (LOW, the only code change): phantom `treasuryBalance` in `sweepFailedPregame()`.** On the clean-close path players reclaim their full commitment including the treasury slice via `claimSignupRefund()`, but `treasuryBalance` still recorded those slices, so after the seed return the recorded balance could exceed actual USDC and a later `withdrawTreasury()` would revert inside SafeERC20 (owner's treasury unbacked and stuck; player/VC funds safe). Fixed with a one-line reconcile capping `treasuryBalance` to `usdcBalance` after the seed transfer.
* B-I-01 / WORST-CASE #7 (INFO): a partial-DISTRIBUTING reset with an active supplement leaves the distributed slice with winners while `seedReleased` is not advanced (per CR-L-01), so `vcReturnOwed` still treats it as owed to the VC. Conservative direction (favours the investor). Documented as a runbook scenario, not a bug. NatSpec/inline truth-fixes summarised.

## v0.10, Governance-state hygiene, streak repair (part 1)

* **D-L-01 (LOW): orphaned seed-release-ratio governance state.** `proposeDormancy()` cancelled every pending timelock except `pendingSeedReleaseRatioBps`, and `executeSeedReleaseRatio()` had no phase gate, so a ratio proposed in ACTIVE stayed executable after DORMANT/CLOSED. Zero fund impact (the ratio is only read in `_calculatePrizePools()`, ACTIVE-only), but orphaned state. Added the cancel block, deliberately not in `emergencyResetDraw()` (a reset resumes ACTIVE).
* **D-I-01 (design decision, OPTION B): weekly-OG endgame unreachable after a reset.** With zero qualification margin (`WEEKLY_OG_QUALIFICATION_WEEKS == TOTAL_DRAWS`), a reset that voids a draw and restores an OG preserved `consecutiveWeeks` but not `lastActiveWeek`; the voided draw number is consumed by `currentDraw++`, so the next buy lands at `voidedDraw + 1`, the gap-detector fires, and the streak resets to 1, making qualification arithmetically unreachable while the OG keeps paying. Chose the code fix (advance `lastActiveWeek = lastResetDraw`) over documentation. This is only half the fix; see v0.11.

## v0.11, D4-M-01, streak repair (part 2, completes v0.10)

* **D4-M-01 (MEDIUM): docs promised a behaviour the code did not deliver.** v0.10's `lastActiveWeek` advance stopped the streak wipe, but `consecutiveWeeks` only increments at buy time and the restored OG never bought the voided draw, so the max reachable streak was 29 against a required 30, qualification still unreachable, while three v0.10 doc sites claimed it was preserved. That doc-vs-code gap on money-affecting behaviour is the basis for the Medium. Fixed with one line, `p.consecutiveWeeks++` in the `_continueUnwind()` restore branch, before the `qualifiedWeeklyOGCount` check. Three consequences traced safe (the 29-to-30 crossing now counts; the qualification event intentionally does not re-emit on the restore crossing, so subgraphs must derive from the count; already-qualified OGs are decremented-at-loss then re-incremented, net zero). A cosmetic one-above-max display value in `getPlayerInfo` documented, harmless because all logic uses `>=`.
* D4-I-01 (INFO): `executeSeedReleaseRatio()` given the ACTIVE+IDLE gates its sibling execute functions carry. NatSpec return tags summarised.

## v0.12, D5-L-01, reset fairness for upfront OGs

* **D5-L-01 (LOW, OPTION A): reset draws counting against upfront-OG refunds.** Upfront OGs are refunded pro-rata by unplayed draws using `drawsPlayed = currentDraw - 1`, but each reset consumes a draw number without anyone playing it, so `currentDraw - 1` over-states plays by one per prior reset and the voided draw is wrongly counted as played (about $15 net per OG per reset stays in the pot and flows to players). Only bites with both a reset and an early shutdown; funds stay with players (nothing leaks to protocol), hence LOW, but it contradicts the "a reset costs the player nothing" fairness principle just established for weekly OGs. Fixed with a new `resetDrawCount` (storage-appended, layout-safe), incremented once per reset in `_finalizeWeekCore()`'s reset branch, subtracted in `activateDormancy()`. Once-per-reset property verified against the RESET_FINALIZING transitions.
* NS-L-01: `MAX_TARGET_RETURN_BPS` @dev said `estReturnBps = 9000` while the constant declares 5000, a doc contradicting its own declaration line. Corrected.

## v0.13, Documentation-only, economics-complete milestone

Zero bytecode change (compiled contract byte-identical to v0.12 except the version string). Cleared four doc items v0.12 deferred, applied verbatim from the audit hunks, plus one fresh info note. The v0.12 D5-L-01 invariant (`currentDraw - 1 == drawsPlayed + resetDrawCount`) was brute-forced over 100,000 reset/play sequences. This is the last economics-side pass and the point the contract reached 0C/0H/0M/0L on code, with the "a reset costs the player nothing" principle holding across all three participant classes and both close paths. Called out as an audit-ready state for a paid Cyfrin engagement.

## v0.14, Keeper-view correctness, VC anti-lock, changelog split

* **B-L-01 (LOW): cutoff-diff bounds view disagreed with the acceptance check.** `getRequiredCutoffDiffBounds()` (the documented Layer-3 keeper pre-validation) computed min counts with floor division, but `submitCutoffDiffs()` accepts when `floor(count * 10000 / snapshot) >= MIN_BPS`, whose smallest satisfying count is the ceiling; so a keeper following the view could submit a count the contract then rejects. The v1.54-era "if 0 then 1" patch only fixed the zero case. Fixed with ceiling division for the min bounds, verified exhaustively over 200,000 cases.
* **B-L-02 (LOW): `claimVCReturn()` permanent-lock risk.** Was `onlyOwner` with no fallback, so owner key loss permanently stranded the VC's principal, while the gate added no security (the destination is immutable). Added a time-gated permissionless fallback after `ENDGAME_SWEEP_WINDOW` (180 days), so nobody, including the operator, can withhold the investor's principal.
* Packaging: the pre-CRE provenance trail (158 version-tagged lines, NearestTheETH_Base_1Y v1.86 through BullsEth v2.35) moved to a separate history file; the header now carries only the CRE arc plus a pointer.

## v1.0, CRE-native seam (Option B: onReport dispatch)

The Automation-to-CRE migration, on-chain half. No economic logic changed. Implements the Chainlink CRE consumer pattern: the KeystoneForwarder delivers a DON-signed report by calling `onReport()` (the contract is now an `IReceiver`), which decodes an action byte and routes to the existing audited internal cores (five action codes: submit cutoffs, advance, autopicks, prune, close). Findings addressed from the review of the earlier Option-A patch:

* **H-01 (HIGH): the caller-gate approach could not receive CRE writes.** The KeystoneForwarder calls `onReport()` on an `IReceiver`, never `submitCutoffDiffs`/`performUpkeep` directly. Fixed by the native `onReport` dispatch (this build).
* **M-01 (MEDIUM): `closeGame()` was the 5th keeper site and outside the migration.** Fixed with `ACTION_CLOSE` + `_closeGameCore`, so retiring the legacy keeper leaves settlement CRE-reachable.
* L-01 (LOW): `revokeAllForwarders()` single-call incident primitive added; the incident runbook must zero both forwarders.

Security posture as stated at the time: `onReport` adds a caller, not a capability. **That claim was wrong and is corrected at v1.16, see C-02.** It held only if `creForwarder` is an address nothing but our own workflow can cause to call, which the shared KeystoneForwarder is not. The companion claim, that a compromised forwarder can at most grief a revert and never pay wrong winners, was also too strong: the `MatchCountMismatch` check validates counts, not which entries win.

Honest scope note carried in the v1.0 changelog: the full inline against the exact on-disk v0.14 bytes and the off-chain CRE workflow were the real remaining build at that point.

## v1.01, Dormancy solvency floor, seed-cap deploy guard

* **DORM-FLOOR (design-flaw fix).** Guarantees the pot can never be drawn below what a dormancy right now would owe users, the same way the floor already protected the endgame obligation. New helper `_requiredEndPotFloor()` returns `max(endgame obligation, live dormancy obligation)` and replaces the inline `requiredEndPot =` formula at all three write sites, removing a three-way SYNC-drift risk. All read sites inherit the higher floor in the conservative direction. Sim-indicated cost about 0.37 percent of season prizes, redistributed toward the finale (flagged as not yet re-run on the assembled contract).
* **SEED-CAP (deploy-safety fix).** Constructor now reverts `ExceedsLimit` when `_vcSeed > 0 && _maxSeedPerDrawBps == 0`, making a seeded game with no per-draw release cap impossible (that config would let a high governance ratio dump the entire seed in a few draws). +79 bytes over v1.0.

## v1.02, Floor refinement, draw-1 breath clamp

* **DORM-FLOOR-2 (resolves a v1.01 MED launch-liveness finding).** v1.01's floor reserved the current-draw casual + weekly-OG refund too, which made the floor equal the whole pot at draw 1 and could block `startGame` in OG-heavy games. v1.02 drops that current-draw term, so the floor is `unreleased VC seed + upfront-OG net principal (pro-rata unplayed)`. The senior tiers stay reserved; the at-play casual/weekly money is freed for prizes. Honest correction recorded: the current-draw casual refund is best-effort, not "always self-covered" (v1.03 adds a health-gated gate for it).
* **LOW-01: draw-1 breath floor-check.** The calibrated draw-1 breath was never checked against `requiredEndPot`, so an aggressive draw-1 distribution could push the pot below the floor before the solver takes over at draw 2. Capped the draw-1 breath to keep the post-distribution pot at or above the floor, never below `breathRailMin`.
* Wording correction carried into outward-facing docs: dormancy protection described as "closes the known early-dormancy shortfall and strongly reduces the risk," not "structurally unreachable," because the floor is enforced through a forward projection that assumes future revenue.

## v1.03 / v1.03a, Health-gated casual gate, permissionless-claim doc alignment

(v1.03's own file is not in the set; its content is referenced from v1.03a and v1.04.) v1.03 added a health-gated current-pot gate to protect the casual refund whenever the pot can afford it. v1.03a then:

* **MEDIUM (docs/code mismatch): `claimVCReturn()` permissionless since v1.0 but the docstring still described the old v0.14 owner-then-180-day gate.** Aligned the docs to the code (fully permissionless from settlement, immutable destination, deterministic amount). No code change.
* Proved and simulated the seed-supplement + casual-gate interaction SAFE (the one draw where the dormancy floor and seed release touch the same distribution): releasing `$S` of seed lowers the floor by `$S` but the pot by only `0.9$S` (10 percent rolls back), so a supplement draw moves the pot +`0.1$S` relative to the floor and can never breach. Documented a seeded-game characteristic (casual gate stays best-effort in large-seed games; seniors always ironclad).

## v1.04, THE floor split (headline structural fix)

* **B-M-02 (MEDIUM): the floor split.** The dormancy-now obligation (a current-pot floor that decays about 1/30 per played draw) had been folded into `requiredEndPot` (the solver's season-end target) via `max(endgame, dormancy)`. That told the solver the draw-30 pot must clear today's dormancy obligation, so it held breath down all season for a constraint that has melted away by the time it is measured. Fix: `_requiredEndPotFloor()` now returns the endgame formula only; the live dormancy obligation moved to a new `_dormancyNowFloor()` used only by the per-draw distribution gate. Each floor now does the one job its shape fits. Sim-indicated effect on an OG-heavy tier: draws 1-10 distributable rose from about $68,524 to about $164,051 (a $95,527 difference, ~2.4x), with the OG principal still fully protected per-draw by the gate; draw 1 identical and correct.
* **B-M-01 (MEDIUM): `checkSolvency` matches automatically.** Because the split makes `requiredEndPot` the endgame formula, and `checkSolvency` already computes exactly that, preview and enforced gate now agree by construction. No change needed.
* **B-L-01 (LOW): gate simplified to the senior floor.** The casual-refund reservation and its `CASUAL_PROTECT_HEALTH_BPS` health line were removed; the vacuity proof holds (dormancy fires only in IDLE, where carried >= senior floor implies pot >= senior floor + refund-owed on every branch), so reserving it protected nothing and created a non-monotonic kink. The gate now caps against `_dormancyNowFloor()` unconditionally, which loses zero protection, improves it (casuals covered on every branch including seeded games), and deletes the constant.
* NatSpec sweep reconstructed the v1.0-to-v1.04 CRE-arc changelog trail in the header and fixed the three stale keeper caller lists (now "owner, automationForwarder, or creForwarder"). Summarised.

## v1.05 / v1.05a, Docstring-only

* v1.05: bytecode byte-identical to v1.04. Documented the DORM-GATE supplement transient honestly (on a supplement draw the carried pot can sit up to `_seedSupp * (1 - SEED_BPS/10000)` below that draw's floor intra-draw; no fund impact, self-healing at finalize, and dormancy fires only in IDLE so no claim observes the dip). Added a symmetric cross-reference stating `_dormancyNowFloor()` and `_requiredEndPotFloor()` are deliberately two different quantities and must not be merged back.
* v1.05a: docstring-only, 1-byte bytecode diff (version string). Swept the stale call-site comments the v1.04 floor split left behind.

## v1.06, VC spent-seed return model

Adds the spent-seed return the spec called for: unspent seed still returns from the pot (defended in `requiredEndPot`); spent seed (`seedReleased`) is reconstituted to the VC from treasury at close with a flat 25 percent return (`VC_SPENT_RETURN_BPS`), plus a 25 percent bonus if `cumulativeSeasonTreasury >= VC_SPENT_BONUS_THRESHOLD`. At full spend the VC gets 1.25x (or 1.5x with bonus). New pieces: the spent-return constants, `_vcTreasuryObligation()` view, a `withdrawTreasury` reserve guard, a constructor solvency cap, and the closeGame payment. Self-audit trail:

* **SA-1 (MEDIUM, fixed): double-pay risk.** The old fixed-tier bonus and the new spent-return both add to `vcReturnOwed` at close, so a seeded deploy that also set the old tiers would pay the VC twice. Constructor now forbids the old tier params on a seeded game.
* **SA-5 (MEDIUM, fixed): reserve under-provisioning across the bonus threshold.** The withdraw reserve first used the current (conditional) obligation, so before the bonus threshold crossed it reserved only 1.25x; if the owner drew treasury to that and the threshold then crossed, treasury would be briefly below the 1.5x need. Fixed by making the reserve always assume the bonus is live (1.5x), while the close payment still pays the actual conditional amount. Solvency cap: the constructor requires `MAX_SEED_RELEASE_RATIO_BPS` be set and small enough that the obligation can never exceed the treasury that funds it (caps the ratio at 66.66 percent with these percentages). **This proof was falsified by v1.09 and repaired at v1.13, see H-02. The cap itself was tightened again at v1.17, see M-02.**
* **SA-6 (open design question, deliberately undecided): VC return on early shutdown.** On a completed season the VC gets the full deal; on an early shutdown they currently get back only their unspent seed, not the spent-seed reconstitution or return. The withdraw guard reserves the spent obligation in treasury throughout the season, so the money is there at a dormancy; this is a policy choice, not a solvency constraint. Left for the spec owner to decide. Closed in v1.07.

---

*(v1.07 to v1.11a are recorded in their own per-version CHANGELOG files, not re-consolidated here. In brief, so the jump is not silent: v1.07 extended the VC spent-return to the early-shutdown path, closing SA-6 above; v1.08 fixed a real treasury insolvency in that reserve, at the immutable MAX ratio, and added the "protocol eats last" withdraw window; v1.09-v1.10 added and then made reset-safe the seeded cold-start T3 floor; v1.11 was docs-only, correcting the dormancy-timelock NatSpec to 24h; v1.11a batched safe fixes, including the PG-01 fail-close on the dead tier bonus.)*

## v1.11b, Tier-mechanism removal and immutable fallback feeds

Two independent changes, one version, both LOW risk, no live behaviour path changed. Compiles clean (solc 0.8.24, viaIR).

* **Part A: remove the dead fixed-tier VC bonus.** Completes v1.11a's PG-01, which had only made the mechanism unreachable. Removes the four `VC_BONUS_TIER*` immutables and their constructor params, `vcBonusEscrow`, the `VCBonusTierReached` event, the `buyTickets` tier-crossing blocks, the `withdrawTreasury` bonus-protection block, and the `getVCBonusStatus` / `_vcBonusAmount` views. Pure dead-code deletion. The spent-seed return model (v1.06-v1.07) and the `TreasuryBonusProtected` error, still thrown by that reserve, are kept.
* **Part B: immutable fallback feeds.** `ethReserveFeed` and `wethFeed` made immutable, set once in the constructor with their validation moved out of the deleted `setReserveFeed` / `setWethFeed`. The primary feed `ethFeed` stays mutable and its full `proposeFeedChange` timelock path is untouched, so the primary ETH/USD feed can still follow a Chainlink aggregator re-address. **Note that this removed two storage slots and shifted everything after them: "layout-safe" claims elsewhere hold only relative to v1.11b onward.**
* **ABI / deploy.** The constructor signature nets minus two params (four tier out, two feed in) and the order changes; removes the `vcBonusEscrow` getter, the `getVCBonusStatus` view, and the two feed setters.
* Five doc-only NatSpec fixes folded in (zero bytecode): the seed-cap "0 = no cap" caveat added at four sites (a seeded game reverts on 0), stale bonus-tier and `vcBonusEscrow` doc references removed, and the mislabelled header block relabelled v1.11a to v0.14.

## v1.11c, Interface extraction

`IBullsEthCRE.sol` split out of the monolith: every external function signature, all 67 custom errors, all 113 events, plus their NatSpec. The contract now declares `contract BullsEth is IBullsEthCRE`, so the compiler enforces that implementation and interface cannot drift. Bytecode-identical to v1.11b.

The extractor used to produce it dropped documentation in at least three places (error and event NatSpec orphaned rather than moved, and two views shipped undocumented), and left 104 orphaned comment lines in the implementation that would later attach to the wrong declaration. Both are cleaned up at v1.17; the extractor itself should be rebuilt before the interface is regenerated after the size split.

---

# The audit arc, v1.12 to v1.17

An adversarial audit at v1.11c modelled the **external trust boundary** rather than the internal accounting, and found two Criticals that per-version delta audits had structurally been unable to see. Every version below closes findings from that pass and its follow-ups.

From v1.12 onward the Foundry suite was running, so these entries record **measured** behaviour rather than reasoned behaviour. That distinction is the main thing that changed about this arc: earlier versions were verified by reading, these were verified by execution.

## v1.12, Documentation accuracy, provably bytecode-identical

Six documentation corrections, zero code change. Executable bytecode proven identical to v1.11c by stripping the 53-byte solc metadata trailer and hashing the remainder: 64,233 bytes, matching hash. A matching byte count alone is weak evidence, since two different programs can be the same length, so the hash comparison is the claim. (Worth applying the same method to the earlier "bytecode identical" releases at v0.13, v1.05 and v1.11 if those were verified on byte count alone.)

Four of the six were load-bearing, meaning a keeper or auditor following them would have been led into the wrong behaviour:

* `_vcTreasuryObligation` claimed the VC obligation was bounded by the seed release ratio and could never exceed treasury earned. True for the supplement path, false for the v1.09 T3 top-up.
* `processMatches` was documented as "callable by keeper or owner" when it has no access control at all.
* `getRequiredCutoffDiffBounds` carried two keeper rules that did not match the implementation, including an auto-default staleness rule that does not exist in code.
* `resolveWeek` declared no caller restriction either way, which is part of why the settlement-timing issue stayed invisible to anyone reading the interface.

## v1.13, H-02, the T3 cold-start floor bypassed the seed release ratio cap

The constructor's VC solvency proof is only sound if `seedReleased` obeys `cumulativeSeasonTreasury * MAX_SEED_RELEASE_RATIO_BPS / 10000`. The seed-supplement path obeys it. The v1.09 T3 cold-start top-up did not: it bounded itself only by unspent seed, the per-draw cap and the pot. The two conditions are positively correlated, which is what made it bite: the top-up only fires when T3 is thin, T3 is thin when the pot is thin, and the pot is thin exactly when treasury is thin.

Measured on the intended mainnet configuration, after **one draw**: $1,552.37 of seed released against a ratio ceiling of $0.00, producing a $1,940.46 obligation against $1,250.00 of treasury. **A $690.46 shortfall in a single draw.** Draw-1 buys are covered by pregame commitment credit, so `cumulativeSeasonTreasury` was exactly zero while investor capital left the pot; at settlement the excess is silently truncated by a `min()` and the VC is short.

Fixed with a three-line ratio clamp on the top-up. After the fix, walking the whole cold-start window: treasury $5,000, ceiling $3,333, released $3,333. The clamp binds exactly at the ceiling, so the mechanism still works once treasury is genuinely earned.

Accepted consequence, stated openly: the cold-start floor can no longer fire in draw 1. A subsidy cannot be funded from a return obligation the season has not yet earned the treasury to service. A real cold-start fund needs a separate, explicitly non-returnable tranche excluded from the obligation. A test asserts the suppression deliberately so it is not later "restored" as an oversight.

## v1.14, H-06, H-01, H-04, and a new finding recorded

**H-06, the breath rail forbade the solver from saving the pot.** `breathRailMin` is a prize-experience floor, and it was being enforced as a solvency constraint, with `ABSOLUTE_BREATH_FLOOR` (100 bps) under it as a hard bottom governance could not lower. The contract was therefore required to distribute about 0.9 percent of the pot every draw regardless of circumstance, including when that drove the pot below `requiredEndPot`. Worse, the distress branch returned `breathRailMin` too, so the solver spent hardest at precisely the moment it should have stopped.

The revenue collapse was never the cause; the rail was. Simulated on the contract's own `_simGeomPot`: pot $130,000 at draw 20, floor $120,000, revenue to zero for the final ten draws. At the rail the pot ends **$1,237 short**. At breath zero the same scenario ends **$10,000 clear**.

Fixed in three parts: the distress branch returns 0, the rail releases when the solver's answer falls below it (new `BreathRailReleased` event), and the exhale comfort floor stands down rather than overriding a solvency-driven answer. Measured trajectory on the real contract under a revenue collapse: 550, 264, 199, 149, 110, 80, 56, 38, 25, 15, 7, 1, 0. The rail is crossed at draw 5, which was impossible at any setting before. The pot stabilises at $117,239 instead of bleeding to a projected $95,326, **preserving $21,913**.

**H-07 recorded, not fixed.** The rail release stops the bleeding but does not fully hold the floor. `avgNetRevenuePerDraw` is a 3:1 moving average and lags a collapse by roughly four draws, so the solver spends headroom on revenue that never arrives. Measured residual: $2,760.58 against a $120,000 floor, 2.3 percent. A test asserts the residual exists and bounds it inside 3 percent, so a change that widens it is caught. Not fixed because the fix is an economics decision: reacting in one draw instead of four means slamming breath down after a single quiet draw in normal operation.

**H-01, auto-default tie clusters could make a draw unresolvable.** A stale prediction was overwritten with one global auto-default, so every non-resubmitting player carried an identical value, tied at an identical difference, and was admitted or excluded as a single block by the inclusive tier thresholds. A cohort larger than the T1 ceiling landing near the settled price made the draw structurally unresolvable: no cutoff triple existed, not even `t1CutoffDiff = 0`.

The rule is now that **a player's prediction stands until they change it.** The global default applies only to a player who has never submitted, which is close to unreachable since all four entry paths set and validate one. Applied at five sites. Accepted trade: a forgotten prediction does not track the market, and this must be stated plainly to players.

Shipped with a circuit breaker, because both a mismatch bounce and a resubmission refresh `phaseStartTimestamp`, so a keeper retrying an unsatisfiable draw in good faith could hold it open indefinitely and the 48h escape would never unlock. After `MAX_CUTOFF_ATTEMPTS` (3), `emergencyResetDraw` becomes available immediately.

**H-04, VC seniority was inverted between the two settlement paths.** `activateDormancy` carves unreleased seed as TIER 0 above the OG pool; `closeGame` paid OGs from the pot first and only then looked for the seed, so on the shortfall branch the seed the draw-30 holdback had reserved was paid to OGs and the VC fell back on an unreserved treasury. Two exits from the same building with opposite instructions. The reservation now happens at the top of `_closeGameCore`, before the OG payout is computed.

Disclosure this creates, and it belongs in the OG terms rather than implied by code: **on a completed but underperforming season the OG return may be reduced to protect investor principal.** `EndgameShortfall` already fires for that case.

## v1.15, C-01, settlement timing was chosen by the caller

`resolveWeek()` was permissionless with a lower time bound and **no upper bound**, and settled on whatever the feed read at the instant of the call. Predictions lock at 48h; settlement opened at 72h and never closed. In a nearest-the-price game, choosing the settlement moment is close to choosing the answer, and it cost one transaction. Everyone could do it, so in practice the jackpot tier would go to whichever bot watched the feed most closely, every draw.

Fixed by pinning. The new permissionless `resolveWeek(uint80 roundId)` takes the **first** feed round at or after the scheduled slot. Exactly one round qualifies, so every honest caller settles on the same price regardless of when they call. `_readPinnedPrice` validates the round and then firstness: the preceding round must predate the slot. New `SettlementRoundPinned` event carries the slot timestamp so anyone can verify the correct round was used.

Documented rather than papered over: on a Chainlink proxy the round id packs a phase id, so `roundId - 1` is meaningless across an aggregator upgrade. Where firstness cannot be proven the round must fall within `PINNED_ROUND_TOLERANCE` (1 hour) of the slot, which bounds the residual choice rather than removing it.

The old `resolveWeek()` is retained as a feed-failure escape, because the reserve and WETH fallback chain is genuine protection, but is now restricted to owner or keeper and unavailable until `RESOLVE_FALLBACK_DELAY` (12 hours) past the slot.

**ABI change.** Off-chain callers must switch to `resolveWeek(roundId)`, computed by walking back from `latestRoundData` until `updatedAt < slot` and taking the round after.

Also in this release: `MockAggregator` was rewritten with real round history. The previous mock returned the current price and timestamp for any round id, so pinning was untestable against it, and it never went stale, which meant `startGame` had been succeeding after a 72h warp on a feed that in reality would be long past its heartbeat. **Any earlier test result depending on feed freshness was optimistic.**

## v1.16, C-02, `onReport` did not authenticate the workflow

`onReport` checked `msg.sender == creForwarder` and discarded the report metadata. That check only means something if `creForwarder` is an address nothing but our own workflow can cause to call. The chain-level Chainlink KeystoneForwarder is not that: it is a shared singleton and any party can register a workflow targeting an arbitrary receiver. Pointing `creForwarder` at it directly would let a stranger's workflow reach cutoff submission, settlement and close. This corrects the v1.0 security posture claim.

Fixed by a **new contract** rather than by editing the game. `CreReportGuard.sol` (5,502 bytes, inside EIP-170) sits between forwarder and game: the forwarder calls the guard, the guard verifies the workflow, and only then calls BullsEthCRE. Three reasons for keeping it separate: the game is already far over the size limit and this adds nothing to it; if Chainlink changes the report envelope you redeploy 200 lines instead of 70,000; and the guard can be tested in milliseconds rather than through a full game.

The guard needed no CRE specification to build, which is what unblocked this finding. It starts in **RECORD** mode, storing and emitting the raw envelope without forwarding, so the real layout is learned from a single testnet run rather than from documentation that may be stale. **ENFORCE** mode then validates using offset-based rules, so the guard never needs to know what the fields mean and stays layout-agnostic. Guards against the obvious mistakes: `setMode(ENFORCE)` reverts with nothing configured, `wouldPass()` dry-runs rules before committing, and a test asserts that per-run fields such as an execution id must not be pinned, since whole-envelope pinning works on run one and fails on run two.

BullsEthCRE itself needed no code change, only `setCreForwarder(guardAddress)`. Deployment sequence and the two-lever kill switch are documented in the guard's NatSpec.

## v1.17, M-01, M-02, three Lows, NatSpec sweep

* **M-01 (MEDIUM): the CRE resolve path bypassed the v1.15 delay.** `onReport` with a resolve action and a payload under 32 bytes fell through to a spot read with no delay check, reintroducing the exact caller-picks-the-instant optionality C-01 removed, behind the forwarder, while an inline comment described it as delay-gated. The spot fallback was removed from `onReport` entirely: a CRE resolve must now carry a round id or revert. **ABI change.**
* **M-02 (MEDIUM): the withdraw-lock reserve could exceed 100 percent of season treasury.** The constructor capped the ratio at 6666, but the reserve multiplies that by a further 5 percent buffer, reaching `cumulativeSeasonTreasury * 1.0499` and locking withdrawals mid-season in a revenue-heavy game. Folding the buffer into the constructor bound caps the ratio at **6349** and moves the failure to deploy time, which is a far kinder failure than a mid-season lock.
* **L-01:** the solver skipped an entire seeded zero-OG season, leaving the draw-30 reserve undefended. **L-02:** `sweepDormancyRemainder` used a bare assignment on a fund variable rather than an accumulation (latent, safe only while the two settlement paths stay phase-exclusive). **L-03:** the last rail clamp in the solver returned `breathRailMin` rather than 0, contradicting the H-06 premise (unreachable, corrected for consistency).
* **Documentation sweep.** 104 orphaned NatSpec lines sat between the Errors header and `enum OGIntentStatus`, left behind when the declarations moved to the interface at v1.11c. Solidity attaches dangling NatSpec to the next declaration, so all 104 would have attached to that enum, which is the same failure that broke the v1.16 build. Converted to plain comments. Also: `withdrawTreasury` now documents all three of its gates in order rather than only the last; a stale DORM-FLOOR block superseded by the v1.04 floor split was removed; and a note records that "layout-safe" claims hold only relative to v1.11b.

Deployed bytecode fell 14 bytes to 70,811, the first shrink in the arc, because M-01 deleted a branch.

---

## State at v1.17

**Both Criticals closed, both Mediums closed, five Lows closed. 59 Foundry tests passing**, run automatically by GitHub Actions on every push.

Test coverage is regression-focused rather than comprehensive: 46 of the 59 tests exist to prove specific findings stay fixed. The dormancy waterfall, emergency reset paths, governance timelocks and prize tier distribution beyond a single happy-path draw remain uncovered. See `TEST_GAPS.md`.

**Open:**

* **H-03**, only the reset path re-anchors the schedule. A normal finalize landing more than `PICK_DEADLINE` after its slot zero-lengths the next buy window and costs every weekly OG their status.
* **H-05 (code half)**, the keeper enumeration spec. The documentation was corrected at v1.12; the code still counts two entries for a weekly OG who missed the buy and produces none.
* **H-07**, the revenue estimate lag, above.
* A DORM-GATE precedence test, owed since v1.17 retained the draw-1 breath clamp pending it.
* Two Lows from a later cold pass: the per-draw seed cap can be exceeded roughly twofold in a cold-start draw where both release paths fire, and the governance ratio does not bind the T3 top-up.

The **EIP-170 size split** remains the deployment gate at 70,811 bytes against 24,576. Nothing is deployed and no funds are at risk. See `KNOWN_ISSUES.md`.
