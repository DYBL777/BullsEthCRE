[CHANGELOG-BullsEthCRE.md](https://github.com/user-attachments/files/30006002/CHANGELOG-BullsEthCRE.md)
# BullsEthCRE, CRE Arc, Consolidated Changelog (v0.1 to v1.06)

Substantive findings and fixes only. NatSpec, version-string bumps, and inline-comment hygiene are summarised per version, not enumerated. Severities are as graded in each version's own changelog (C/H/M/L, plus INFO where material). This document covers the CRE fork from the point it branched off BullsEth v2.35.

Source coverage note (honest): this consolidation is built from the changelog files on hand, which run v0.1 to v1.06, plus the current head v1.11b added at the end. Two gaps remain by design. v0.4 is missing from the set (the record jumps v0.3 to v0.5, so v0.4's own findings are inferred only from later back-references). v1.07 to v1.11a are not re-consolidated here; they live in their own per-version CHANGELOG files and are summarised in one line at the jump before the v1.11b entry.

\---

## The arc in one paragraph

v0.1 forked BullsEth v2.35 and bolted on three things: a flat 25% treasury, a rescaled OG return curve (10 to 50 percent, down from 30 to 90), and the SmartEarn VC-earnout layer. Everything from v0.2 to v0.13 is the economics being hardened around that new VC money: making sure the seed is never paid twice, never stranded, and never left out of the solvency floor, and making dormancy fair to every participant class. v0.13 reached a clean 0C/0H/0M/0L economics state. v1.0 migrated the keeper seam onto Chainlink CRE (onReport dispatch). v1.01 to v1.06 then reworked the solvency floor twice (the headline being the v1.04 floor split) and added the VC spent-seed return model.

\---

## v0.1, Fork from BullsEth v2.35 (the CRE baseline)

Not a fix pass. This is the fork that establishes the CRE demo. Material changes:

* Treasury flattened to 25% across all paths (`TREASURY\_BPS` and `UF\_OG\_TREASURY\_BPS` both 1500 to 2500).
* OG return curve rescaled: `MAX\_TARGET\_RETURN\_BPS` 9000 to 5000, `TARGET\_RETURN\_FLOOR\_BPS` 3000 to 1000. `\_computeTargetReturnBps` now returns 50 percent at 20 percent OG or under, linear down to 10 percent at 100 percent OG.
* SmartEarn (VC earnout) ported from Weather20 v2.44: a third party seeds the pot (`VC\_SEED`), receives unreleased principal back at close, plus an exclusive-tier performance bonus. Adds eight immutables, two constants, twelve-plus state variables, five new functions, and the seed-release governance path.
* Dormancy waterfall revised to five tiers, with a new TIER 0 (VC unreleased seed) sitting senior to the OG pool.

All rate values are explicitly placeholders, adjustable pre-mainnet.

## v0.2, HIGH-01 and the seed-in-the-floor problem

* **HIGH-01 (the critical fix of the arc): VC seed spent twice at draw 30.** The draw-30 surplus path distributed the entire pot above the OG holdback to winners, and the VC's unreleased seed was inside that surplus. `closeGame()` then tried to pay the seed from a treasury that had no reservation for it, so in the common case (seed threshold rarely hit in 30 draws) the VC was structurally short their principal. Secondary root cause: `requiredEndPot` had no VC-seed term, so the geometric solver never knew to protect it. Fixed at four sites (draw-30 holdback, `startGame` obligation lock, `\_finalReturnCalibration`, `\_snapshotOGObligation`), mirroring the Weather20 draw-52 pattern. The `VC\_SEED - seedReleased` term self-corrects as seed is released, so the solver never over-protects already-distributed seed.
* **LOW-01: `seedPot()` access control.** Was `external` with no caller restriction and no phase gate; any address could donate the seed with no recourse, and a post-CLOSED call would strand funds. Added `onlyOwner` and a PREGAME gate.
* LOW-02: stale-NatSpec sweep (the v2.35 15%/9000-era rate comments), summarised.

## v0.3, MEDIUM-01, pro-rata dormancy fairness

* **MEDIUM-01: pro-rata OG dormancy refund by unplayed draws.** v0.1/v0.2 refunded every OG the same target-return amount (\~$300 on a $600 stake) regardless of how many draws they had played, so on an early shutdown an OG who played 4 draws got the same as one who played 29, and the prepaid-but-unplayed value leaked down to casuals. Fixed to `netPaid \* drawsUnplayed / TOTAL\_DRAWS` (treasury and consumed draws non-refundable). New state var `dormancyDrawsPlayed` snapshots `currentDraw - 1` at activation.
* **LOW (SYNC): SmartEarn pools missing from three SolvencyAlert sums.** `dormancyVCPool` and `vcReturnOwed` were added in v0.1 but three inline SolvencyAlert allocations (in `claimDormancyRefund`, `claimEndgame`, `claimPrize`) were not updated, so a real SmartEarn shortfall would fail to trigger the alert. Added to all three.
* Version string and remaining NatSpec, summarised. Also logged a deploy-runbook footgun (not a bug): if the owner forgets `seedPot()` before `startGame()`, start reverts `PotBelowTrajectory` because the pot lacks the seed the floor now expects. Fails safe.

## v0.4, (missing from source set)

No changelog file available. From later back-references, v0.4 appears to have moved the VC bonus/return accounting to an escrow model (the `vcBonusEscrow` referenced from v0.5 onward) and moved weekly OGs from the OG dormancy pool into the casual (current-draw) pool. Treat this entry as incomplete pending the v0.4 file.

## v0.5, Two dormancy edge fixes

* **DR-M-02 (MEDIUM): pregame weekly-OG net missing from the draw-1 dormancy pool.** Pregame weekly OGs get `lastBoughtDraw = 1` and `lastTicketCost = $20` but never pass through `buyTickets()` for draw 1, so their cost was never added to the weekly-OG net total. The draw-1 dormancy window is reachable (24h propose + 48h pick-deadline both clear before the 72h cooldown), so they could claim from a casual pool that was sized without their contribution, draining it ahead of genuine casuals. Fixed with one line in `startGame()` folding `pregameWeeklyOGNetTotal` into the weekly-OG net total; the tracking infrastructure already existed.
* **DR-L-01 (LOW): weekly OGs diluting the per-head pool without claiming.** Weekly OGs were counted in the per-head denominator and sized into the pool, but the weekly-OG branch in `claimDormancyRefund()` had no per-head block, so their share was never claimed, shrank everyone else's, and was swept to the beneficiary. Added the per-head block.
* CL-1: full CRE changelog block added to the header; the "DORMANCY INHERITED UNCHANGED" line corrected to "MODIFIED IN CRE v0.1 to v0.5". NS sweep (6 comments), summarised.

## v0.6, Failed-pregame seed return, OG notice-period symmetry

* **MEDIUM-01: VC seed now returned on a failed pregame launch.** If `seedPot()` was called but `startGame()` never fired, the only close path (`sweepFailedPregame()`) sent the entire residual, seed included, to `PROTOCOL\_BENEFICIARY`; the VC has no PlayerData entry so no refund path caught them. The mirror image of the seed-defence guard. Fixed by returning the deposited seed to `VC\_SEED\_RETURN\_ADDRESS` before the beneficiary sweep, in one transaction, with a `min(VC\_SEED, usdcBalance)` cap. New event `FailedPregameSeedReturned`.
* **LOW-01: `registerAsOG()` now honours the startGame notice period.** `registerAsWeeklyOG()` blocked registration during the 72h notice window; `registerAsOG()` did not, so an upfront OG registering just before start had their 72h decline window silently truncated and then lost cancellation entirely at start. Fixed by mirroring the weekly-OG `TimelockPending` guard. Removes the trap rather than documenting it.
* INFO-01 to INFO-04: stale 15%-treasury docs swept, the 90-day dormancy VC delay documented, the PREGAME withdraw guard moved to the top for a deterministic revert reason, and the draw-30/closeGame seed-reservation pair cross-referenced. Summarised.

## v0.7, Dormancy per-head denominator on claimable heads

* **M-01 (MEDIUM): per-head denominator sized on heads that cannot claim.** The denominator counted every active weekly OG, including one who had not bought the current draw (status not yet lost because matching had not run). That non-buyer hits `NothingToClaim` before the per-head block, so a loyal active OG got a silent zero on an operator shutdown, and their uncounted slice shrank everyone else's and was swept. Fixed with a new `currentDrawWeeklyOGBuyerCount` (incremented once per active weekly-OG buy, cleared each draw and on reset); denominator becomes `upfrontOGCount + currentDrawWeeklyOGBuyerCount + weeklyNonOGPlayers.length`, with each term mapping to exactly one claim branch and no address double-counted. Secondary fix: the upfront-OG branch reverted on an empty OG pool before the per-head block, confiscating the per-head slice; restructured so principal computes to 0 cleanly and per-head is still paid.
* L-04 (LOW): constructor `\_vcSeedReturnAddress` was validated against zero and USDC but not `address(this)`, which would strand VC principal in the contract. Added the check. L-01/L-02 (version string, VC-param NatSpec) summarised. L-03 (one-draw `requiredEndPot` under-reservation after reset) left as a documented self-healing transient.

## v0.8, checkSolvency parity, seed-release deferral

* **CR-M-02 (MEDIUM): `checkSolvency()` floor missing the unreleased VC seed.** The PREGAME pre-flight preview dropped the seed term that `startGame()`'s `requiredEndPot` enforces, so a deployment could pass the preview yet fail or misprice at start. Added `\_vcUnreleasedCS` so the preview is bit-identical to the enforced floor.
* **CR-L-01 (LOW): `seedReleased` over-rollback on emergency reset, fixed by deferral.** `emergencyResetDraw()` rolled back the full `currentDrawSeedSupplement` from `seedReleased` on the premise "USDC already returned to prizePot," which is false if a reset fires mid-DISTRIBUTING after partial credit; `closeGame()` then over-stated `vcReturnOwed`. Fixed by moving the `seedReleased +=` increment out of `\_calculatePrizePools()` and into `\_finalizeWeekCore()` guarded by `!isResetFinalize`, so a reset never counts the supplement as released. This deferral becomes load-bearing for several later notes. Placement is critical: the increment sits before the supplement clear and before the two obligation-recompute readers.
* NS-L-01: `requiredEndPot` formula docs updated to include the VC term. Summarised.

## v0.9, Phantom treasury balance on failed-pregame close

* **B-L-01 (LOW, the only code change): phantom `treasuryBalance` in `sweepFailedPregame()`.** On the clean-close path players reclaim their full commitment including the treasury slice via `claimSignupRefund()`, but `treasuryBalance` still recorded those slices, so after the seed return the recorded balance could exceed actual USDC and a later `withdrawTreasury()` would revert inside SafeERC20 (owner's treasury unbacked and stuck; player/VC funds safe). Fixed with a one-line reconcile capping `treasuryBalance` to `usdcBalance` after the seed transfer.
* B-I-01 / WORST-CASE #7 (INFO): a partial-DISTRIBUTING reset with an active supplement leaves the distributed slice with winners while `seedReleased` is not advanced (per CR-L-01), so `vcReturnOwed` still treats it as owed to the VC. Conservative direction (favours the investor). Documented as a runbook scenario, not a bug. NatSpec/inline truth-fixes summarised.

## v0.10, Governance-state hygiene, streak repair (part 1)

* **D-L-01 (LOW): orphaned seed-release-ratio governance state.** `proposeDormancy()` cancelled every pending timelock except `pendingSeedReleaseRatioBps`, and `executeSeedReleaseRatio()` had no phase gate, so a ratio proposed in ACTIVE stayed executable after DORMANT/CLOSED. Zero fund impact (the ratio is only read in `\_calculatePrizePools()`, ACTIVE-only), but orphaned state. Added the cancel block, deliberately not in `emergencyResetDraw()` (a reset resumes ACTIVE).
* **D-I-01 (design decision, OPTION B): weekly-OG endgame unreachable after a reset.** With zero qualification margin (`WEEKLY\_OG\_QUALIFICATION\_WEEKS == TOTAL\_DRAWS`), a reset that voids a draw and restores an OG preserved `consecutiveWeeks` but not `lastActiveWeek`; the voided draw number is consumed by `currentDraw++`, so the next buy lands at `voidedDraw + 1`, the gap-detector fires, and the streak resets to 1, making qualification arithmetically unreachable while the OG keeps paying. Chose the code fix (advance `lastActiveWeek = lastResetDraw`) over documentation. This is only half the fix; see v0.11.

## v0.11, D4-M-01, streak repair (part 2, completes v0.10)

* **D4-M-01 (MEDIUM): docs promised a behaviour the code did not deliver.** v0.10's `lastActiveWeek` advance stopped the streak wipe, but `consecutiveWeeks` only increments at buy time and the restored OG never bought the voided draw, so the max reachable streak was 29 against a required 30, qualification still unreachable, while three v0.10 doc sites claimed it was preserved. That doc-vs-code gap on money-affecting behaviour is the basis for the Medium. Fixed with one line, `p.consecutiveWeeks++` in the `\_continueUnwind()` restore branch, before the `qualifiedWeeklyOGCount` check. Three consequences traced safe (the 29-to-30 crossing now counts; the qualification event intentionally does not re-emit on the restore crossing, so subgraphs must derive from the count; already-qualified OGs are decremented-at-loss then re-incremented, net zero). A cosmetic one-above-max display value in `getPlayerInfo` documented, harmless because all logic uses `>=`.
* D4-I-01 (INFO): `executeSeedReleaseRatio()` given the ACTIVE+IDLE gates its sibling execute functions carry. NatSpec return tags summarised.

## v0.12, D5-L-01, reset fairness for upfront OGs

* **D5-L-01 (LOW, OPTION A): reset draws counting against upfront-OG refunds.** Upfront OGs are refunded pro-rata by unplayed draws using `drawsPlayed = currentDraw - 1`, but each reset consumes a draw number without anyone playing it, so `currentDraw - 1` over-states plays by one per prior reset and the voided draw is wrongly counted as played (about $15 net per OG per reset stays in the pot and flows to players). Only bites with both a reset and an early shutdown; funds stay with players (nothing leaks to protocol), hence LOW, but it contradicts the "a reset costs the player nothing" fairness principle just established for weekly OGs. Fixed with a new `resetDrawCount` (storage-appended, layout-safe), incremented once per reset in `\_finalizeWeekCore()`'s reset branch, subtracted in `activateDormancy()`. Once-per-reset property verified against the RESET\_FINALIZING transitions.
* NS-L-01: `MAX\_TARGET\_RETURN\_BPS` @dev said `estReturnBps = 9000` while the constant declares 5000, a doc contradicting its own declaration line. Corrected.

## v0.13, Documentation-only, economics-complete milestone

Zero bytecode change (compiled contract byte-identical to v0.12 except the version string). Cleared four doc items v0.12 deferred, applied verbatim from the audit hunks, plus one fresh info note. The v0.12 D5-L-01 invariant (`currentDraw - 1 == drawsPlayed + resetDrawCount`) was brute-forced over 100,000 reset/play sequences. This is the last economics-side pass and the point the contract reached 0C/0H/0M/0L on code, with the "a reset costs the player nothing" principle holding across all three participant classes and both close paths. Called out as an audit-ready state for a paid Cyfrin engagement.

## v0.14, Keeper-view correctness, VC anti-lock, changelog split

* **B-L-01 (LOW): cutoff-diff bounds view disagreed with the acceptance check.** `getRequiredCutoffDiffBounds()` (the documented Layer-3 keeper pre-validation) computed min counts with floor division, but `submitCutoffDiffs()` accepts when `floor(count \* 10000 / snapshot) >= MIN\_BPS`, whose smallest satisfying count is the ceiling; so a keeper following the view could submit a count the contract then rejects. The v1.54-era "if 0 then 1" patch only fixed the zero case. Fixed with ceiling division for the min bounds, verified exhaustively over 200,000 cases.
* **B-L-02 (LOW): `claimVCReturn()` permanent-lock risk.** Was `onlyOwner` with no fallback, so owner key loss permanently stranded the VC's principal, while the gate added no security (the destination is immutable). Added a time-gated permissionless fallback after `ENDGAME\_SWEEP\_WINDOW` (180 days), so nobody, including the operator, can withhold the investor's principal.
* Packaging: the pre-CRE provenance trail (158 version-tagged lines, NearestTheETH\_Base\_1Y v1.86 through BullsEth v2.35) moved to `CHANGELOG-BullsEthCRE-history.md`; the header now carries only the CRE arc plus a pointer. NS info items summarised.

## v1.0, CRE-native seam (Option B: onReport dispatch)

The Automation-to-CRE migration, on-chain half. No economic logic changed. Implements the Chainlink CRE consumer pattern: the KeystoneForwarder delivers a DON-signed report by calling `onReport()` (the contract is now an `IReceiver`), which decodes an action byte and routes to the existing audited internal cores (five action codes: submit cutoffs, advance, autopicks, prune, close). Findings addressed from the review of the earlier Option-A patch:

* **H-01 (HIGH): the caller-gate approach could not receive CRE writes.** The KeystoneForwarder calls `onReport()` on an `IReceiver`, never `submitCutoffDiffs`/`performUpkeep` directly. Fixed by the native `onReport` dispatch (this build).
* **M-01 (MEDIUM): `closeGame()` was the 5th keeper site and outside the migration.** Fixed with `ACTION\_CLOSE` + `\_closeGameCore`, so retiring the legacy keeper leaves settlement CRE-reachable.
* L-01 (LOW): `revokeAllForwarders()` single-call incident primitive added; the incident runbook must zero both forwarders.

Security posture: `onReport` adds a caller, not a capability. Phase advance was already permissionless; the cutoff `MatchCountMismatch` honesty check is unchanged, so a compromised forwarder can at most grief a revert, never pay wrong winners. `\_closeGameCore` moves no funds (payouts stay deferred to claim functions). An alternate v1.0 Option A (minimal caller-gate, no decode entry point) was written and rejected in favour of B for suite-wide symmetry.

Honest scope note carried in the v1.0 changelog: the full inline against the exact on-disk v0.14 bytes and the off-chain CRE workflow were the real remaining build at that point.

## v1.01, Dormancy solvency floor, seed-cap deploy guard

* **DORM-FLOOR (design-flaw fix).** Guarantees the pot can never be drawn below what a dormancy right now would owe users, the same way the floor already protected the endgame obligation. New helper `\_requiredEndPotFloor()` returns `max(endgame obligation, live dormancy obligation)` and replaces the inline `requiredEndPot =` formula at all three write sites, removing a three-way SYNC-drift risk. All read sites inherit the higher floor in the conservative direction. Sim-indicated cost about 0.37 percent of season prizes, redistributed toward the finale (flagged as not yet re-run on the assembled contract).
* **SEED-CAP (deploy-safety fix).** Constructor now reverts `ExceedsLimit` when `\_vcSeed > 0 \&\& \_maxSeedPerDrawBps == 0`, making a seeded game with no per-draw release cap impossible (that config would let a high governance ratio dump the entire seed in a few draws). +79 bytes over v1.0.

## v1.02, Floor refinement, draw-1 breath clamp

* **DORM-FLOOR-2 (resolves a v1.01 MED launch-liveness finding).** v1.01's floor reserved the current-draw casual + weekly-OG refund too, which made the floor equal the whole pot at draw 1 and could block `startGame` in OG-heavy games. v1.02 drops that current-draw term, so the floor is `unreleased VC seed + upfront-OG net principal (pro-rata unplayed)`. The senior tiers stay reserved; the at-play casual/weekly money is freed for prizes. Honest correction recorded: the current-draw casual refund is best-effort, not "always self-covered" (v1.03 adds a health-gated gate for it).
* **LOW-01: draw-1 breath floor-check.** The calibrated draw-1 breath was never checked against `requiredEndPot`, so an aggressive draw-1 distribution could push the pot below the floor before the solver takes over at draw 2. Capped the draw-1 breath to keep the post-distribution pot at or above the floor, never below `breathRailMin`.
* Wording correction carried into outward-facing docs: dormancy protection described as "closes the known early-dormancy shortfall and strongly reduces the risk," not "structurally unreachable," because the floor is enforced through a forward projection that assumes future revenue.

## v1.03 / v1.03a, Health-gated casual gate, permissionless-claim doc alignment

(v1.03's own file is not in the set; its content is referenced from v1.03a and v1.04.) v1.03 added a health-gated current-pot gate to protect the casual refund whenever the pot can afford it. v1.03a then:

* **MEDIUM (docs/code mismatch): `claimVCReturn()` permissionless since v1.0 but the docstring still described the old v0.14 owner-then-180-day gate.** Aligned the docs to the code (fully permissionless from settlement, immutable destination, deterministic amount). No code change.
* Proved and simulated the seed-supplement + casual-gate interaction SAFE (the one draw where the dormancy floor and seed release touch the same distribution): releasing `$S` of seed lowers the floor by `$S` but the pot by only `0.9$S` (10 percent rolls back), so a supplement draw moves the pot +`0.1$S` relative to the floor and can never breach. Documented a seeded-game characteristic (casual gate stays best-effort in large-seed games; seniors always ironclad).

## v1.04, THE floor split (headline structural fix)

* **B-M-02 (MEDIUM): the floor split.** The dormancy-now obligation (a current-pot floor that decays about 1/30 per played draw) had been folded into `requiredEndPot` (the solver's season-end target) via `max(endgame, dormancy)`. That told the solver the draw-30 pot must clear today's dormancy obligation, so it held breath down all season for a constraint that has melted away by the time it is measured. Fix: `\_requiredEndPotFloor()` now returns the endgame formula only; the live dormancy obligation moved to a new `\_dormancyNowFloor()` used only by the per-draw distribution gate. Each floor now does the one job its shape fits. Sim-indicated effect on an OG-heavy tier: draws 1-10 distributable rose from about $68,524 to about $164,051 (a $95,527 difference, \~2.4x), with the OG principal still fully protected per-draw by the gate; draw 1 identical and correct.
* **B-M-01 (MEDIUM): `checkSolvency` matches automatically.** Because the split makes `requiredEndPot` the endgame formula, and `checkSolvency` already computes exactly that, preview and enforced gate now agree by construction. No change needed.
* **B-L-01 (LOW): gate simplified to the senior floor.** The casual-refund reservation and its `CASUAL\_PROTECT\_HEALTH\_BPS` health line were removed; the vacuity proof holds (dormancy fires only in IDLE, where carried >= senior floor implies pot >= senior floor + refund-owed on every branch), so reserving it protected nothing and created a non-monotonic kink. The gate now caps against `\_dormancyNowFloor()` unconditionally, which loses zero protection, improves it (casuals covered on every branch including seeded games), and deletes the constant.
* NatSpec sweep reconstructed the v1.0-to-v1.04 CRE-arc changelog trail in the header and fixed the three stale keeper caller lists (now "owner, automationForwarder, or creForwarder"). Summarised.

## v1.05 / v1.05a, Docstring-only

* v1.05: bytecode byte-identical to v1.04. Documented the DORM-GATE supplement transient honestly (on a supplement draw the carried pot can sit up to `\_seedSupp \* (1 - SEED\_BPS/10000)` below that draw's floor intra-draw; no fund impact, self-healing at finalize, and dormancy fires only in IDLE so no claim observes the dip). Added a symmetric cross-reference stating `\_dormancyNowFloor()` and `\_requiredEndPotFloor()` are deliberately two different quantities and must not be merged back.
* v1.05a: docstring-only, 1-byte bytecode diff (version string). Swept the stale call-site comments the v1.04 floor split left behind.

## v1.06, VC spent-seed return model

Adds the spent-seed return the spec called for: unspent seed still returns from the pot (defended in `requiredEndPot`); spent seed (`seedReleased`) is reconstituted to the VC from treasury at close with a flat 25 percent return (`VC\_SPENT\_RETURN\_BPS`), plus a 25 percent bonus if `cumulativeSeasonTreasury >= VC\_SPENT\_BONUS\_THRESHOLD`. At full spend the VC gets 1.25x (or 1.5x with bonus). New pieces: the spent-return constants, `\_vcTreasuryObligation()` view, a `withdrawTreasury` reserve guard, a constructor solvency cap, and the closeGame payment. Self-audit trail:

* **SA-1 (MEDIUM, fixed): double-pay risk.** The old fixed-tier bonus and the new spent-return both add to `vcReturnOwed` at close, so a seeded deploy that also set the old tiers would pay the VC twice. Constructor now forbids the old tier params on a seeded game.
* **SA-5 (MEDIUM, fixed): reserve under-provisioning across the bonus threshold.** The withdraw reserve first used the current (conditional) obligation, so before the bonus threshold crossed it reserved only 1.25x; if the owner drew treasury to that and the threshold then crossed, treasury would be briefly below the 1.5x need. Fixed by making the reserve always assume the bonus is live (1.5x), while the close payment still pays the actual conditional amount. Solvency cap: the constructor requires `MAX\_SEED\_RELEASE\_RATIO\_BPS` be set and small enough that the obligation can never exceed the treasury that funds it (caps the ratio at 66.66 percent with these percentages).
* **SA-6 (open design question, deliberately undecided): VC return on early shutdown.** On a completed season the VC gets the full deal; on an early shutdown they currently get back only their unspent seed, not the spent-seed reconstitution or return. The withdraw guard reserves the spent obligation in treasury throughout the season, so the money is there at a dormancy; this is a policy choice, not a solvency constraint. Left for the spec owner to decide.

\---

*(v1.07 to v1.11a are recorded in their own per-version CHANGELOG files, not re-consolidated here. In brief, so the jump is not silent: v1.07 extended the VC spent-return to the early-shutdown path, closing SA-6 above; v1.08 fixed a real treasury insolvency in that reserve, at the immutable MAX ratio, and added the "protocol eats last" withdraw window; v1.09-v1.10 added and then made reset-safe the seeded cold-start T3 floor; v1.11 was docs-only, correcting the dormancy-timelock NatSpec to 24h; v1.11a batched safe fixes, including the PG-01 fail-close on the dead tier bonus.)*

## v1.11b, Tier-mechanism removal and immutable fallback feeds

Two independent changes, one version, both LOW risk, no live behaviour path changed. Compiles clean (solc 0.8.24, viaIR). Runtime bytecode 71,649 to 64,286 (minus 7,363); the EIP-170 size split is still the gate.

* **Part A: remove the dead fixed-tier VC bonus.** Completes v1.11a's PG-01, which had only made the mechanism unreachable. Removes the four `VC\_BONUS\_TIER\*` immutables and their constructor params, `vcBonusEscrow`, the `VCBonusTierReached` event, the `buyTickets` tier-crossing blocks, the `withdrawTreasury` bonus-protection block, and the `getVCBonusStatus` / `\_vcBonusAmount` views. Pure dead-code deletion. The spent-seed return model (v1.06-v1.07) and the `TreasuryBonusProtected` error, still thrown by that reserve, are kept.
* **Part B: immutable fallback feeds.** `ethReserveFeed` and `wethFeed` made immutable, set once in the constructor with their validation moved out of the deleted `setReserveFeed` / `setWethFeed`. The primary feed `ethFeed` stays mutable and its full `proposeFeedChange` timelock path is untouched, so the primary ETH/USD feed can still follow a Chainlink aggregator re-address.
* **ABI / deploy.** The constructor signature nets minus two params (four tier out, two feed in) and the order changes; removes the `vcBonusEscrow` getter, the `getVCBonusStatus` view, and the two feed setters. The Foundry deploy scripts and tests must be updated to the new signature before the suite builds.
* **Five doc-only NatSpec fixes folded in** (zero bytecode): the seed-cap "0 = no cap" caveat added at four sites (a seeded game reverts on 0), stale bonus-tier and `vcBonusEscrow` doc references removed, and the mislabelled header block relabelled v1.11a to v0.14 (its content is the pre-CRE v0.14 pass). Not yet behaviourally tested; the Foundry suite needs the new signature first.

\---

## Open threads (as of v1.11b)

Refreshed from the v1.06 tail. Closed since: **SA-6** was decided in v1.07 (the VC is made whole on early shutdown too); the **fixed-tier bonus** was fully removed in v1.11b.

* **EIP-170 size split** remains the deployment gate. Runtime (deployed) bytecode is 64,286 against the 24,576 limit; v1.11b's removals help but do not close it. (Earlier "runtime" figures such as 73,630 were the creation bytecode; EIP-170 governs the deployed figure.)
* **Foundry sims / tests not yet run** on the assembled contract; the prize-size and floor-cost figures across v1.01 onward are sim-indicated, not proven on-chain, and the suite needs the v1.11b constructor signature before it builds.
* **Full cold-read audit** of the assembled contract still owed.

