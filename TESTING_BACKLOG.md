# BullsEthCRE, testing backlog

What is not yet covered, in priority order. Current suite: 432 tests across 24 suites, all
passing. Zero contract bugs found to date; every finding across roughly a dozen audit rounds
has been in the tests.

Rough remaining total: 30 to 35 tests, plus 11 one-line edits that add no tests.

---

## 1. View functions (~14). The largest remaining gap.

23 views exist and roughly 12 have no test at all. Views are what frontends and keepers read,
so a wrong view is a wrong decision downstream with nothing reverting to stop it. Nothing else
on this list has that property.

- `getRequiredCutoffDiffBounds` is the highest value of the group, being keeper-facing, and it
  carries the CRE v0.14 ceiling-division fix that stops keepers being guided into submissions
  that revert.
- `getAutoDefault` feeds keeper auto-pick logic.
- `getOGCapInfo`, worth testing under both registration orderings given the cap ordering quirk
  recorded in KNOWN_ISSUES C3.
- `getProjectedEndgamePerOG`, what an OG sees as their expected return all season.
- `getExhaleFloorHealth`, the gate flag and the health reading.
- `getSeedReleaseStatus`, investor-facing.
- `isResultStale`, whose draw-0 guard and in-flight early return are both deliberate and
  neither is tested.
- `getPreGameStats`, where `readyToStart` means canPropose and not canExecuteStart, which is
  an easy thing to get wrong downstream.
- `getCutoffState`, `isValidPrediction`, `getOGListIndex`, `getGameState`, `getDormancyInfo`,
  all cheap.
- `countStaleOGs(start, count)`, the paginated overload. The unpaginated one is used; this one
  is not.

## 2. Sweep and refund tails (~6)

- `sweepFailedPregame` happy path, including the VC seed return and the treasury
  reconciliation. Only the two revert cases exist.
- `sweepUnclaimedPrizes` and `sweepUnclaimedEndgame` after the 180-day window. Only the
  "reverts before" side is covered.
- `batchRefundPlayers` where a refund is capped at prize pot plus treasury balance.

## 3. Untested revert branches (5)

Each of these errors exists in the contract and is named by no test.

- `InvalidPrediction`, the zero and above-maximum bounds.
- `SeedNotDeposited`, `startGame` with a seed configured and `seedPot` never called.
- `MaxPlayersReached`, the registration cap.
- `InsufficientGasForBatch`, the batch loops refusing to start an iteration under 150k gas.
- `GameAlreadyClosed` at the resolve-side season boundary, where `currentDraw` exceeds
  `TOTAL_DRAWS`. Distinct from the `gameSettled` sites, which are covered.

## 4. Behavioural gaps (~6)

- **Prize-rate multiplier effect on payouts.** The governance around `prizeRateMultiplier` is
  fully tested. Nothing asserts that a reduced multiplier reduces what a winner is actually
  paid, so the multiplier could be a no-op in distribution and every existing test would still
  pass.
- **Resolution-time fallback ladder consumption.** `startGame`'s feed substitution is covered.
  The resolve-side ladder is not: `ReserveFeedUsed`, `FeedStaleFallback`, and a resolution
  actually settling on `autoDefaultCents`. This is the part that pays players.
- **Partial-claim cap in `claimCommitmentRefund`**, with its `CommitmentRefundPartial` event.
- **`resetDrawRefundPool2`**, the second-reset overflow slot. Needs a two-reset fixture, which
  nobody has built.
- **Empty-tier skip**, the `winners.length == 0` path. Documented in the contract as "should
  not occur", which is exactly the claim that earns a test. May be unreachable through honest
  cutoffs given the band minimums, in which case the outcome is a KNOWN_ISSUES unreachability
  note rather than a test.
- **Streak de-qualification decrement.** See KNOWN_ISSUES C4: two of the three
  `qualifiedWeeklyOGCount` decrements are unreachable while the qualification threshold equals
  the season length. Already analysed and recorded there; listed here so the analysis is not
  mistaken for a coverage gap.

## 5. Typed expectation debt (11 one-line edits, no new tests)

Nine `vm.expectRevert()` calls in the suite name no error, so each would pass on any revert
rather than the intended one. Sites: Pregame 296, 304, 456, 497, 514; AuditFindings 350; and
CreReportGuard's `test_OnlyOwnerCanConfigure`, which stacks four bare expectations under a
single `startPrank`. All the underlying errors take no arguments, so typing them is
mechanical.

One further bare expectation is deliberate and should stay: the codeless-address test in
GovernanceTimelocks, where the raw empty revert is the behaviour being pinned (KNOWN_ISSUES
C1).

## 6. Operator telemetry events (2)

The suite asserts state rather than events, which is a defensible style and not worth
reversing wholesale. Two exceptions are worth making, because they are events an operator's
monitoring would alert on and no state assertion substitutes:

- `SolverDistressSignal`, on the proven insolvency fixture.
- `CutoffAttemptsExhausted`, at exhaustion.

## 7. Constructor completeness (~2)

The deploy suite is five tests against a constructor with considerably more validation than
that: the per-address `InvalidAddress` set, the feed decimals check, and the M-02 seed-cap
ceiling of 6349, which deserves the both-sides boundary treatment the governance suite gave
the governance-side cap (6350 reverts, 6349 deploys).

---

## Closed since the previous version of this file

Listed because the previous version named several of these as the top priorities.

**Prize distribution mechanics (11 tests).** Was the largest gap and the only remaining area
where a bug meant someone was paid the wrong amount. Now covers tier ordering, equal payment
within a tier, dust return with exact conservation, both skip paths, batched resumption past
the 200-per-transaction cap with the parked indices asserted exactly, and boundary ties at
both cutoffs.

**Invariant fuzzing (9 properties).** Was listed as deliberately last. Now running on every CI
push, 32 sequences of 400 calls per property. Covers clean seasons, emergency resets that void
a draw, dormancy wind-downs with waterfall refunds, and cutoff sabotage with recovery. The
campaign asserts its own progress, so a run that completes no draws fails CI rather than
passing quietly.

**The draw-30 bonus fund (7 tests).** Accumulation at the stated rate, consumption into the
final draw, the dormancy return, and the reset rollback.

**Reset refunds (11 tests).** `claimCommitmentRefund` and `sweepResetRefundRemainder`,
including the destination flip that sends the remainder back to the pot while the game is
active but to the beneficiary once it is dormant or closed.

**Feed guards and the circuit breaker (8 tests).** Required a bounds-aware mock, and executed
the Chainlink min and max answer comparisons for the first time in the project's history. Also
covers all three sequencer arms and the insolvent-launch refusal.

**Seed and solvency (7 tests).** The `seedPot` cluster, plus `SolvencyCheckFailed` proven able
to fire and its healthy-path control, which were the prerequisites for trusting the balance
invariant under fuzzing.
