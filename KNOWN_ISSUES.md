# BullsEthCRE, Known Issues

Open work between this version and mainnet. Forward-looking, not a log of resolved
findings. Per-version history is in the changelog.

Current version: v1.17. Deployed bytecode 70,811 bytes for BullsEthCRE (down 14 on
v1.16), plus a 5,502-byte `CreReportGuard`. Foundry suite builds and runs clean: 432 tests
across 24 suites, exit 0, verified 13 Aug 2026.

Both Criticals are now closed. C-01 in v1.15, C-02 in v1.16.

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

Still open. `test_Draw_ScheduleIsAnchoredEvenWhenADrawSettlesLate` pins the current
behaviour, so the anchoring is proven rather than assumed, and a change to it will fail a
test.

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
unrecoverable. Measured residual: $2,760.58 against a $120,000 floor, about 2.3%.
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
Deployed bytecode is 70,811 against the 24,576 limit, 46,235 over. It was 39,710 over at
v1.11c. The fix arc added roughly 7,000 bytes net through v1.16; v1.17 gave 14 back by
deleting the CRE spot branch (M-01).

Note that C-02 was closed at zero cost to this figure, by putting the fix in a separate
contract. That is the pattern to reach for while the split is outstanding.

**Now measured, not estimated.** The previous version of this entry gave source-line
proportions and told the reader to run `forge build --sizes` and comment-out-and-diff before
planning. That was done on 12 Aug 2026, compiling with the project's own settings:

| Cluster removed | Bytes recovered |
|---|---|
| Dormancy (7 functions plus its state getters) | 11,742 |
| OG mechanism (12 functions plus its state getters) | 11,724 |

Two things follow, and the second corrects this entry as it previously stood.

Removing **both** flagship features still leaves the contract roughly 23KB over the limit.
So no combination of feature deletion reaches a deployable size. The deployable paths are
external libraries and satellite contracts, not trimming.

And the two clusters are within 18 bytes of each other. The earlier entry said the OG
mechanism was "larger still" than dormancy, reasoning from source line count. Compiled size
did not follow source size. Anyone planning the split should measure rather than count
lines, which is what the earlier entry advised and is now demonstrated.

Extraction and the split are the SAME WORK, with one condition: library functions must be
`external` or `public` to be deployed separately and reached by `delegatecall`. An
`internal` library is inlined at compile time and saves nothing. Dormancy is the cleaner lift
of the two; the OG mechanism is woven through buying, matching, dormancy sizing, the endgame
and the unwind, so it is the harder one regardless of its size.

Note `forge build --sizes` exits non-zero while any contract is over the limit. Do not use
it in a CI build step or the pipeline goes red before tests run. `forge test` is unaffected
and needs no `code_size_limit` setting.

**B2. Test coverage: 432 tests across 24 suites, zero contract bugs found.**
Superseded the previous entry, which recorded 379 tests across 19 suites and named prize
distribution as the largest remaining gap. That gap is now closed.

Worth stating plainly, because it is the actual result: across roughly a dozen external
audit rounds on the test suite itself, every finding has been in the tests, none in the
contract.

Covered: the breath engine (51), pregame registration and refunds (43), governance
timelocks (41), keeper and automation (41), dormancy (31), draw machinery (30), the CRE seam
and report guard (28), emergency reset and unwind (22), claims and endgame (22), treasury
withdrawal (15), the weekly OG lifecycle (15), SmartEarn dormancy (13), prize distribution
(11), reset refunds (11), invariant fuzzing (9), audit-finding regressions (9), feed guards
and the circuit breaker (8), breath solvency (7), the draw-30 bonus fund (7), seed and
solvency (7), the H-02 invariant (5), deploy (5), and one full-cycle integration.

Closed since the previous version of this entry: prize distribution mechanics, which was
named as the only remaining area where a bug means someone is paid the wrong amount; the
draw-30 bonus fund; the reset refund tails; the feed circuit breaker, whose min and max
answer comparisons had never executed against any test before a bounds-aware mock was
written for them.

Still open, and tracked in `TESTING_BACKLOG.md`:

**View functions (~14).** 23 views exist; roughly 12 have no test. Views are what frontends
and keepers read, so a wrong view is a wrong decision downstream with nothing reverting.
`getRequiredCutoffDiffBounds` is the highest value of these, being keeper-facing. This is
now the largest remaining gap.

**Sweep tails (~6).** The `sweepFailedPregame` happy path including the VC seed return, both
180-day sweeps, and the `batchRefundPlayers` branch where a refund is capped at pot plus
treasury.

**Smaller branch gaps (~10).** Five revert branches never exercised (`InvalidPrediction`
bounds, `SeedNotDeposited`, `MaxPlayersReached`, `InsufficientGasForBatch`, and
`GameAlreadyClosed` at the season boundary); the partial-claim cap in
`claimCommitmentRefund`; the second reset-refund pool, which needs a two-reset fixture; the
empty-tier skip path; and the prize-rate multiplier's effect on what a winner actually
receives.

**Typed-expectation debt (11 one-line edits, no new tests).** Nine `vm.expectRevert()` calls
in the suite are untyped and would pass on any revert. All the underlying errors take no
arguments, so typing them is mechanical.

**B3. The fuzz tests exercise a mirror, not the contract.**
`_simGeomPot` and `_solveGeometricBps` are internal and cannot be called from a test, so the
H-06 fuzz tests run against a hand-transcribed copy. They prove the algorithm; the scenario
tests prove the contract wires it up; the claim is the pair.

`test_MirrorMatchesTheContractsRealSimGeomPot` pins the mirror by reconstructing
`checkSolvency()` from public state and asserting it agrees with the contract, so silent
drift now fails a test. That reduces the risk. It does not eliminate it.

**B4. Invariants: nine now enforced in CI, register still owed.**
The previous version of this entry said invariants lived in prose across the changelog with
nothing re-checking them, and cited v1.06 asserting the VC obligation could never exceed the
treasury funding it, falsified by v1.09 with nothing catching it for five versions.

That gap is now partly closed by executable means. Nine properties run under invariant
fuzzing on every CI run, 32 sequences of 400 calls each, 12,800 calls per property:

- contract USDC balance covers every allocated pool, mirroring the contract's own
  seventeen-term solvency identity
- seed released never exceeds the seed
- seed release stays inside the ratio ceiling
- qualified weekly OGs are a subset of active ones
- the treasury never exceeds holdings
- every draw number is either played or voided
- senior dormancy tiers are funded before junior ones
- the season never runs past its end
- distribution indices stay in bounds

The campaign asserts its own progress, so a run that completes no draws fails CI rather than
passing quietly. Executed paths include clean seasons, emergency resets that void a draw,
dormancy wind-downs with waterfall refunds, and cutoff sabotage with recovery.

Still owed: an `INVARIANTS.md` naming each invariant, where it is enforced, and what would
break it. Nine properties are checked; the document that lets a reader find the rest is not
written. The specific failure that motivated this entry, a prose invariant falsified by a
later version, is not fully solved by a test suite that only covers the nine.

---

## C. Contract behaviour notes

Cases where observable behaviour differs from what the code reads like. None is a bug and
none carries a code change. Recorded because in three of the four, more than one reader has
already been caught by the same thing.

**C1. `proposeFeedChange` rejects a codeless address with an EMPTY revert.**
The decimals check is wrapped in try/catch, which reads as though any address that cannot
answer `decimals()` is rejected with `FeedDecimalsMismatch`. For an address with no code the
call never happens: Solidity emits an `extcodesize` check first, and that reverts raw with
empty returndata before entering the try. So there are two distinct rejections and only one
is typed.

| Target | Revert |
|---|---|
| Address with no code | empty revert, no reason data |
| Contract whose `decimals()` returns != 8 | `FeedDecimalsMismatch` |
| Contract whose `decimals()` itself reverts | `FeedDecimalsMismatch` |

Not changed: the proposal is blocked either way, and an explicit `code.length` check buys a
nicer error at the cost of bytecode on a contract already 46k over EIP-170. Operationally:
an empty revert means "not a contract"; a typed error means "a contract reporting the wrong
decimals". Pinned by `test_FeedChange_RejectsACodelessAddressWithARawRevert` and
`test_FeedChange_RejectsWrongDecimals`, side by side.

**C2. The PREGAME guard in `withdrawTreasury` is unreachable.**
Two guards both revert `TreasuryLocked`, in this order:

```solidity
if (!gameSettled && currentDraw <= WITHDRAW_START_DRAW) revert TreasuryLocked();  // window
if (gamePhase == GamePhase.PREGAME) revert TreasuryLocked();                      // phase
```

`currentDraw` is 0 throughout PREGAME, first written at `startGame()` which also moves the
phase to ACTIVE. So the window gate always evaluates `0 <= 5` and fires first. Not removed:
both revert identically, so nothing is lost, and it is cheap defensive depth against a future
change introducing a PREGAME path with a non-zero `currentDraw`. No test written from outside
can distinguish the two; `test_Withdraw_BlockedBeforeTheGameStarts` is named for what it
actually proves.

**C3. The 18% total-OG cap is order-bypassable.**
`TOTAL_OG_CAP_BPS` is enforced by `_weeklyOGCapReached()`, called from exactly one place:
`registerAsWeeklyOG`. It is never re-checked. `registerAsOG` has no cap check at all, which
is deliberate since v1.57-P1.

Registration order therefore decides the outcome. Upfront first, then weekly: the headroom is
consumed and weekly registration reverts `OGCapReached`, and this direction IS documented, in
the NatSpec on `_weeklyOGCapReached`. Weekly first, then an upfront surge: the weekly
registrations pass while the upfront count is low, the surge is uncapped, and the earlier
weeklies are grandfathered. Worked example from a live fixture: 500 casuals commit, 10 weekly
OGs register (cap at that moment ~91), then 140 upfront register uncapped. Final state 650
committed, 150 OGs, a 23.1% ratio.

One arithmetic detail worth recording, because it caught a test fixture: each upfront
registration also increments `committedPlayerCount`, so registering upfront OGs enlarges the
very cap they are consuming. Exhausting the headroom needs more registrations than a static
reading of "18% of the committed count" suggests.

Not a vulnerability: `_computeTargetReturnBps` is continuous and already prices ratios to
100%, so a higher ratio simply lowers each OG's target return, and the solvency constraints
are elsewhere. Recorded because a reader would reasonably assume the cap binds both ways. If
it is ever meant to be hard, the fix is a re-check inside `registerAsOG`, a behavioural
change and a deliberate decision, not a tidy-up. Both directions pinned in
`WeeklyOgLifecycle.t.sol`.

**C4. Two of the three `qualifiedWeeklyOGCount` decrements cannot fire.**
`consecutiveWeeks` rises by at most one per distinct draw number (registration credits draw
1; `buyTickets` refuses a second buy in the same draw; `_continueUnwind` credits one voided
draw per reset). So `consecutiveWeeks <= currentDraw` always, and reaching the threshold of
30, equal to `TOTAL_DRAWS`, requires `currentDraw == 30`.

That makes two decrements unreachable. The one in `_processMatchesCore` needs a qualified OG
who did not buy the current draw, but qualification requires buying at draw 30. The one in
`_updateStreakTracking` needs a buy after a qualification, and `buyTickets` requires ACTIVE,
which ends at that same finalize.

The third, in `claimDormancyRefund`, IS reachable: qualify at draw 30, then the operator
winds down instead of resolving. Covered by
`test_Claim_WeeklyOG_DequalifiesAQualifiedClaimant`.

Not removed, and this is the point: they are dead only because
`WEEKLY_OG_QUALIFICATION_WEEKS` equals `TOTAL_DRAWS`. The NatSpec presents that as a design
choice. Set the threshold below the season length and both sites go live immediately.
Deleting them to satisfy a coverage report would remove the protection one constant change
before it is needed. A coverage tool will flag both branches as uncovered; that is the
expected result, not a gap in the suite.

---

## D. Compiler and lint warnings

The build emits roughly 90 warnings. None is a bug. Recorded because an auditor opening a log
with ninety warnings wants evidence they were read and judged.

**D1. `block-timestamp` lint class (~50 occurrences), accepted.**
Every window in this contract is measured in hours or days: the shortest is
`SEQUENCER_GRACE_PERIOD` at one hour, and the rest run 24 hours to 180 days. Second-scale
validator drift cannot meaningfully move any boundary, and no path confers an advantage from
being either side of one. Settlement price is pinned to a feed round rather than a call time
(C-01), and prize allocation depends on submitted cutoffs rather than timing. The one place
timing did matter was the settlement instant, closed at v1.15. Not suppressed inline: fifty
disable comments would add noise and invite the question of what was being hidden.

**D2. `unsafe-typecast` on `bytes32("...")` literals (~40 occurrences), accepted.**
Test files only. Every occurrence is a governance reason code. A string literal to `bytes32`
is not a numeric cast. The real hazard, worth knowing: a literal longer than 32 characters
WOULD silently truncate. The longest in the suite is 23 characters, so there is headroom, but
anyone adding a reason code should stay under 32.

**D3. Two `uint256(resolvedPrice)` casts need annotation. ACTION REQUIRED.**
`resolvedPrice` is `int256`, and casting a negative value to `uint256` wraps rather than
errors. Two sites: `_resolveWeekApply` (computing `autoDefaultCents`) and
`_matchAndCategorize` (computing every player's diff). Both are safe, since
`_resolveWeekApply` reverts on `resolvedPrice <= 0` before either is reachable, but the
safety lives in a different function. A reader arriving at `_matchAndCategorize` cold has no
local evidence the value is positive, which is exactly the gap the lint exists to close.
Comment-only fix:

```solidity
// casting to 'uint256' is safe because _resolveWeekApply reverts on resolvedPrice <= 0
// before this function is reachable, so the value is strictly positive here.
// forge-lint: disable-next-line(unsafe-typecast)
uint256 actual = uint256(resolvedPrice);
```

**D4. Cosmetic, no action.** `renounceOwnership` could be `view` but is an override of
OpenZeppelin's non-view signature. Two `_casualNet()` test helpers and one fuzz test could be
`pure`. One unused local at `AuditFindings.t.sol:118` (`keeperCountsForThisOG = 2`), logged in
the backlog rather than deleted: an unused variable in a test sometimes marks an assertion
that was intended and never written.

---

## E. Documentation and packaging

`submitCutoffDiffs` is absent from `IBullsEthCRE` entirely, while
`getRequiredCutoffDiffBounds` in the same file instructs keepers to call it.
`proposePrizeRateIncrease` and `getSolvencyStatus` ship with no NatSpec in the interface,
despite having full docblocks in the implementation. Same extractor bug as the orphaned error
and event blocks. Rebuild the extractor before regenerating the interface after the size
split, not after.

`Deploy.s.sol` carries the wrong Base sequencer address (`...6069`). Chainlink documents
`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`, which matches the contract NatSpec. The script
also still targets the ancestor contract with a five-argument constructor and needs rewriting
for the current eleven-argument one.

The v0.14 changelog entry points at `CHANGELOG-BullsEthCRE-history.md`, which is not in this
repo.

The `_checkAutoAdjust` comment on `potHealth` truncation carries two false claims: an "exactly
1.2x reads 11999" example (exact multiples do not truncate) and a "gates fire one notch early"
mechanism (`floor(R) >= T` iff `R >= T` for integer T, so gate outcomes are identical to the
true ratio). Both were corrected in the BreathEngine primitive and never back-ported here.
Comment-only, still owed.

---

## F. Disclosures owed, not code

**OG terms.** On a completed but underperforming season the OG return may be reduced to
protect investor principal. `EndgameShortfall` fires for this case. Decided 23 July 2026, not
yet written down for the people it affects.

**Standing predictions.** From v1.14 a player's number stands until they change it. This needs
saying plainly in the player-facing material, along with the consequence: a forgotten
prediction does not track the market.

**CRE deployment shape.** `creForwarder` must point at a deployed `CreReportGuard`, never at
the chain-level KeystoneForwarder. This is now stated in the interface NatSpec, but it is a
deployment instruction and belongs in the runbook too. Revoking CRE access now has two levers:
`bulls.setCreForwarder(0)` or `guard.setForwarder(0)`.

**Cold-start floor.** From v1.13 the T3 cold-start floor cannot fire in draw 1, because no
in-season treasury has been earned to back a seed release. If a genuine cold-start fund is
wanted it must be a separate, explicitly non-returnable tranche, excluded from the VC
obligation. That is a design item, not a fix.

**Closed since the previous version of this section.** The DORM-GATE precedence test is
written and passing (`test_Engine_DormGateTakesPrecedenceOverTheDraw1Clamp`), so the startGame
draw-1 breath clamp it was blocking can now be reconsidered on its merits. NS-03 in the
BreathEngine primitive is corrected in that library's v1.3: its header no longer claims
BullsEth clamps to `breathRailMin`, and porters are directed to check their own host rather
than assume either behaviour. Lettery777's clamp status remains unconfirmed and must be
checked against that source rather than asserted.

---

## G. Resolved since the previous version of this file

Listed because a previous version of this file claimed to be complete and was not.

**Since 9 Aug 2026.** Prize distribution mechanics covered (11 tests), closing what the
previous B2 named as the largest gap and the only remaining area where a bug means someone is
paid the wrong amount. The draw-30 bonus fund covered (7). Reset refunds covered (11). Feed
guards and the Chainlink circuit breaker covered (8), which required a bounds-aware mock and
executed the min and max answer comparisons for the first time. Seed and solvency covered (7).
Invariant fuzzing built and running, nine properties in CI. Suite 379 to 432 across 24 suites.
The dormancy and OG size clusters measured rather than estimated, correcting this file's own
earlier claim that the OG mechanism was the larger of the two.

**Earlier.** Settlement timing chosen by the caller, C-01 (v1.15). `onReport` workflow
authentication, C-02 (v1.16), closed by a separate `CreReportGuard` contract rather than by
editing the game, so it costs BullsEthCRE no bytecode and can be redeployed independently if
the CRE envelope changes. CRE resolve spot-fallback removed, M-01 (v1.17). Withdraw-reserve
buffer folded into the constructor solvency bound, M-02 (v1.17), ratio cap tightened 6666 to
6349 so the failure happens at deploy rather than mid-season. Three Lows (v1.17): solver
skipped on a seeded zero-OG season (L-01); bare assignment on `vcReturnOwed` in
`sweepDormancyRemainder` (L-02); last rail clamp in the solver (L-03). Documentation sweep
(v1.17): 104 orphaned NatSpec lines neutralised before they could attach to an enum (IC-01, a
live compile hazard); `withdrawTreasury` gate documentation (NS-01); stale DORM-FLOOR block
removed (NS-02); layout-baseline note (IC-02); IC-03 comment corrected. Inert fixed-tier VC
bonus mechanism removed (v1.11b). Six false documentation claims corrected, provably
bytecode-identical (v1.12). T3 cold-start floor bypassing the seed release ratio cap (v1.13).
Auto-default tie clusters bricking draws, cutoff circuit breaker added (v1.14). Breath rail
enforced as a solvency constraint (v1.14). VC seniority inverted between the two settlement
paths (v1.14).
