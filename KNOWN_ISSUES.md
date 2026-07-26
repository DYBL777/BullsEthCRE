# BullsEthCRE, Known Issues

Open work between this version and mainnet. Forward-looking, not a log of resolved
findings. Per-version history is in the changelog.

**Current version: v1.17.** Deployed bytecode 70,811 bytes for BullsEthCRE (down 14 on
v1.16), plus a 5,502-byte `CreReportGuard`. Foundry suite builds and runs clean: **59 tests
passing, exit 0**, verified 26 Jul 2026.

**Both Criticals are now closed.** C-01 in v1.15, C-02 in v1.16.

This file is intended to be complete. If something is not here and not in the changelog as
resolved, treat that as a gap in this document rather than as evidence no such issue exists.

---

## A. Open security findings

**A1. Schedule re-anchor (High).**
There is an unenforced invariant that a draw must finalize within `PICK_DEADLINE` of its
scheduled slot. If it does not, the next draw's buy window is closed when it opens, no
tickets can be bought, and every weekly OG loses status because there is no mulligan. The
reset path re-anchors and self-heals; the normal finalize path does not.
Fix direction: derive the pick deadline from finalize time, or re-anchor on every finalize.

**A2. Keeper enumeration spec, code half (High).**
The v1.12 documentation fix corrected the spec. The code is untouched. A weekly OG who
missed the buy still reads as active at submission time and produces zero entries during
matching, and `snapshotTotalEntries` counts them either way.
Demonstrated by `test_H05_SnapshotIdenticalWhetherOrNotTheOgBought`: the snapshot is 502 in
both cases while the true entry set differs by two.

**A3. EMA revenue lag leaves a residual shortfall (High).**
The v1.14 rail release stops the pot bleeding but does not fully hold `requiredEndPot` in a
hard collapse. `avgNetRevenuePerDraw` is a 3:1 moving average and lags by roughly four
draws, so the solver spends headroom on revenue that never arrives. With no revenue that is
unrecoverable. Measured residual: **$2,760.58 against a $120,000 floor, about 2.3%.**
`test_H07_EmaLagLeavesAResidualShortfall` asserts the residual exists and bounds it inside
3%, so a regression that widens it is caught.
Not yet fixed because the fix is an economics decision. Planning on
`min(EMA, last-draw actual)` reacts in one draw instead of four but slams breath down after
a single quiet draw in normal operation.

**A4. Medium and Low findings.** The widest blast radius: the solvency view reporting false
insolvency during multi-transaction distribution; the draw-30 holdback routing
non-qualifying OG reserve to treasury rather than to the finale; weekly OG slots squattable
in pregame and unrecoverable because registration is pregame-only; the cutoff submitter's
discretion over the jackpot boundary within an eightfold band. See the audit documents.

---

## B. Deployment and verification gates

**B1. EIP-170 size split, and it is getting worse.**
Deployed bytecode is **70,811** against the 24,576 limit, **46,235 over**. It was 39,710
over at v1.11c. The fix arc added ~7,000 bytes net through v1.16; v1.17 gave 14 back by
deleting the CRE spot branch (M-01).

Note that C-02 was closed at **zero** cost to this figure, by putting the fix in a separate
contract. That is the pattern to reach for while the split is outstanding.

Every further fix widens this job. That is now an argument for doing the library split
sooner rather than continuing to accumulate, and it should be a deliberate decision rather
than something discovered later.

Note `forge build --sizes` exits non-zero while any contract is over the limit. Do not use
it in a CI build step or the pipeline goes red before tests run. `forge test` is unaffected
and needs no `code_size_limit` setting.

**B2. Test coverage is a start, not coverage.**
The suite builds and runs: 59 tests across deployment, pregame, the draw cycle, the CRE
seam and guard, the SmartEarn layer, and the audit findings. Nothing yet covers the dormancy
waterfall, emergency reset paths, or the governance timelocks, which between them hold most
of the money logic. `TEST_GAPS_v1.11a.md` remains the roadmap and its priorities still
stand.

**B3. The fuzz tests exercise a mirror, not the contract.**
`_simGeomPot` and `_solveGeometricBps` are internal and cannot be called from a test, so the
H-06 fuzz tests run against a hand-transcribed copy. They prove the algorithm; the scenario
tests prove the contract wires it up; the claim is the pair.
`test_MirrorMatchesTheContractsRealSimGeomPot` pins the mirror by reconstructing
`checkSolvency()` from public state and asserting it agrees with the contract, so silent
drift now fails a test. That reduces the risk. It does not eliminate it.

**B4. No invariant register.**
Invariants live in prose across the changelog with nothing re-checking them when a later
version lands. v1.06 asserted the VC obligation could never exceed the treasury funding it;
v1.09 falsified it and nothing caught it for five versions. An `INVARIANTS.md` naming each
invariant, where it is enforced, and what would break it, is a prerequisite rather than a
nice-to-have.

---

## C. Documentation and packaging

- `submitCutoffDiffs` is absent from `IBullsEthCRE` entirely, while
  `getRequiredCutoffDiffBounds` in the same file instructs keepers to call it.
- `proposePrizeRateIncrease` and `getSolvencyStatus` ship with no NatSpec in the interface,
  despite having full docblocks in the implementation. Same extractor bug as the orphaned
  error and event blocks. Rebuild the extractor before regenerating the interface after the
  size split, not after.
- `Deploy.s.sol` carries the wrong Base sequencer address (`...6069`). Chainlink documents
  `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`, which matches the contract NatSpec. The
  script also still targets the ancestor contract with a five-argument constructor and needs
  rewriting for the current eleven-argument one.
- The v0.14 changelog entry points at `CHANGELOG-BullsEthCRE-history.md`, which is not in
  this repo.

---

## D. Disclosures owed, not code

- **OG terms.** On a completed but underperforming season the OG return may be reduced to
  protect investor principal. `EndgameShortfall` fires for this case. Decided 23 July 2026,
  not yet written down for the people it affects.
- **Standing predictions.** From v1.14 a player's number stands until they change it. This
  needs saying plainly in the player-facing material, along with the consequence: a
  forgotten prediction does not track the market.
- **CRE deployment shape.** `creForwarder` must point at a deployed `CreReportGuard`, never
  at the chain-level KeystoneForwarder. This is now stated in the interface NatSpec, but it
  is a deployment instruction and belongs in the runbook too. Revoking CRE access now has
  two levers: `bulls.setCreForwarder(0)` or `guard.setForwarder(0)`.
- **DORM-GATE precedence test (owed, v1.17 / IC-03).** The startGame draw-1 breath clamp is
  retained but annotated as awaiting a test that proves DORM-GATE takes precedence. Until that
  test exists the clamp stays. Write it before removing the clamp.
- **NS-03, BreathEngine primitive (framework repo).** Its header note wrongly says BullsEth
  clamps to breathRailMin; false for v1.14+. Correct it there. Lettery777's clamp status is
  unconfirmed and must be checked against that source, not asserted. See
  NS-03_BreathEngine_instruction.md.
- **Cold-start floor.** From v1.13 the T3 cold-start floor cannot fire in draw 1, because no
  in-season treasury has been earned to back a seed release. If a genuine cold-start fund is
  wanted it must be a separate, explicitly non-returnable tranche, excluded from the VC
  obligation. That is a design item, not a fix.

---

## E. Resolved since the previous version of this file

Listed because the previous version claimed to be complete and was not.

- Settlement timing chosen by the caller, C-01 (v1.15). Settlement is now pinned to the
  first feed round at or after the scheduled slot, so the price is a function of the draw
  rather than of when the caller fires. `resolveWeek()` retained as an owner-only,
  12-hour-delayed feed-failure escape.
- `onReport` workflow authentication, C-02 (v1.16). Closed by a separate `CreReportGuard`
  contract rather than by editing the game, so it costs BullsEthCRE no bytecode and can be
  redeployed independently if the CRE envelope changes.
- CRE resolve spot-fallback removed, M-01 (v1.17). A CRE resolve report must carry a roundId;
  the delay-gated spot path survives only on the restricted no-arg resolveWeek().
- Withdraw-reserve buffer folded into the constructor solvency bound, M-02 (v1.17). Ratio cap
  tightened 6666 to 6349; the failure now happens at deploy, not mid-season.
- Three Lows (v1.17): solver skipped on a seeded zero-OG season (L-01); bare assignment on
  vcReturnOwed in sweepDormancyRemainder (L-02); last rail clamp in the solver (L-03).
- Documentation sweep (v1.17): 104 orphaned NatSpec lines neutralised before they could attach
  to an enum (IC-01, a live compile hazard); withdrawTreasury gate documentation (NS-01); stale
  DORM-FLOOR block removed (NS-02); layout-baseline note (IC-02); IC-03 comment corrected.
- Inert fixed-tier VC bonus mechanism removed (v1.11b).
- Six false documentation claims corrected, provably bytecode-identical (v1.12).
- T3 cold-start floor bypassing the seed release ratio cap (v1.13).
- Auto-default tie clusters bricking draws; cutoff circuit breaker added (v1.14).
- Breath rail enforced as a solvency constraint (v1.14).
- VC seniority inverted between the two settlement paths (v1.14).
