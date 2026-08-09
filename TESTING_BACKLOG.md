# BullsEthCRE — testing backlog (v2, after full contract sweep)

Supersedes v1. Produced by enumerating every external/public function and view in
BullsEthCRE.sol v1.17 and checking each against the 18 suites.

**Current: 375 tests, 18 suites, zero contract bugs found to date.** Every finding across a
dozen audit rounds has been in the tests.

**Coverage of state-changing functions is good.** 74 external/public functions; all but a
handful have at least their guards tested. The gaps cluster in three places: **what winners
are actually paid**, **the sweep and refund tails**, and **view functions**, which have
almost no coverage at all.

Roughly **69 tests** to close everything, then fuzzing.

---

## Priority 1 — prize distribution mechanics (~13)

Unchanged from v1 and still the top item: the only area where a bug means someone is paid the
wrong amount. `DrawMachinery` covers winner COUNTS and value conservation. Nothing covers
what a winner RECEIVES.

- **Tier ordering (~3).** Nothing asserts T1 pays more than T2 pays more than T3. That is the
  headline structure (40% / 35.56% / remainder of distributable). Transpose the tier indices
  and no test fails.
- **Dust (~3).** `pool - (perWinner * winners.length)` returns to `prizePot`, `tierPools[i]`
  drops by the same. Use a prime winner count so the remainder is real.
- **The two skip paths (~3).** `perWinner == 0` and `winners.length == 0` both return the
  whole pool and emit `TierSkippedDust`. The empty-tier branch is documented as "should not
  occur", which is exactly the claim that earns a test.
- **Batched resumption (~2).** `MAX_DISTRIBUTE_PER_TX` is 200. Past that the loop resumes on
  `distTierIndex` / `distWinnerIndex`. Untested resumption is how half a tier gets paid twice.
- **Boundary ties (~2).** `diff <= t1CutoffDiff`, so entries landing EXACTLY on a cutoff all
  enter that tier. Stated in the contract, untested, and it is the mechanism that can push
  actual counts past `T1_COUNT_MAX_BPS` and bounce a draw. (The mass-identical-prediction case
  IS covered, in AuditFindings H-01. This is the narrower boundary case.)

---

## Priority 2 — view functions (~14) [NEW, and larger than expected]

**23 views exist. Roughly 12 have no test at all.** Views are what frontends and keepers read,
so a wrong view is a wrong decision by everything downstream, silently.

- **`getRequiredCutoffDiffBounds`** — keeper-facing, and carries the CRE v0.14 ceiling-division
  fix that stops keepers being guided into reverting submissions. Highest value of the group.
- **`getAutoDefault`** — feeds keeper auto-pick logic; returns the seed vs live flag.
- **`getOGCapInfo`** — registration-facing. Given the cap ordering quirk now pinned in
  WeeklyOgLifecycle, worth confirming what this reports under both orderings.
- **`getProjectedEndgamePerOG`** — what an OG sees as their expected return all season.
- **`getExhaleFloorHealth`** — the `gateActive` flag and `potHealthBps`.
- **`getSeedReleaseStatus`** — investor-facing.
- **`isResultStale`** — the draw-0 guard and the in-flight-phase early return are both
  documented as deliberate; neither is tested.
- **`getPreGameStats`** — `readyToStart` is documented as canPropose, NOT canExecuteStart. An
  easy thing to get wrong downstream.
- **`getCutoffState`**, **`isValidPrediction`**, **`getOGListIndex`**, **`getGameState`** —
  cheap.
- **`countStaleOGs(start, count)`** — the paginated overload. The unpaginated one is used;
  this one is not.

---

## Priority 3 — the draw-30 bonus fund (~5)

3% of every weekly pool siphoned across draws 1-29, consumed at draw 30, returned to the pot
if dormancy arrives first. Exercised incidentally, asserted nowhere.

- accumulation at `DRAW30_BONUS_BPS`
- consumption into the draw-30 pool
- `Draw30BonusReturned` on dormancy before draw 30
- reset rollback (`currentDrawBonusContribution` reversed, no double-accumulation on replay)
- the defensive zero at draw 30 stopping a reset double-deducting
- (`getDraw30BonusStatus` view folds in here)

---

## Priority 4 — sweeps and refund tails (~17)

All visible as absences in the CI log.

- **`claimCommitmentRefund` (~4).** The draw-1 reset path. EmergencyReset has three
  `ResetRefund` tests and none for the commitment pool.
- **`sweepResetRefundRemainder` (~4).** Both reset pools and the commitment pool, including
  the DORMANT/CLOSED branch that pays the beneficiary rather than returning to the pot.
- **`sweepFailedPregame` happy path (~3).** Only the two revert tests exist. The VC seed
  return (CRE v0.6 MEDIUM-01) and the treasury reconciliation (B-L-01) are both untested.
- **`sweepUnclaimedPrizes` / `sweepUnclaimedEndgame` after the 180-day window (~3).** Only the
  "reverts before" side is covered.
- **`batchRefundPlayers` partial coverage (~3).** Three tests exist; the branch where a refund
  is capped at `prizePot + treasuryBalance` is not one of them.

---

## Priority 5 — newly found smaller gaps (~12) [NEW]

- **`seedPot` (~4).** Only the `onlyOwner` revert is tested. Untested: `PotAlreadySeeded` on a
  second call, `BelowMinimum` when `VC_SEED == 0`, the `potSeeded` flag, and the `prizePot`
  increment. The seeding happens inside `_bootstrapAndStart` so it demonstrably works, but
  nothing asserts it.
- **`cancelPrizeRateIncrease` (~2).** `cancelPrizeRateReduction` is tested; the increase
  variant is not. Separate functions with mirrored guards
  (`pendingMultiplier <= prizeRateMultiplier` vs `>=`).
- **`applyAutoPicksForDraw` happy path (~2).** Keeper covers every guard. Nothing proves it
  actually applies a prediction.
- **`startGame` feed substitution (~1).** If the primary feed returns 0 and the reserve is
  live, `startGame` repoints `ethFeed` and emits `FeedSubstituted`. Pregame tests the
  stale-feed REVERT but not the successful substitution.
- **`claimForceDeclineRefund` (~1).** Deprecated with the intent queue;
  `forceDeclineRefundOwed` is always 0, so it always reverts `NothingToClaim`. One test pins
  it inert, worth having precisely because it looks live.
- **`_captureYield` / `YieldCaptured` (~2).** Send USDC directly to the contract and the
  surplus is absorbed into `prizePot`. Untested donation path.

---

## Priority 6 — small owed items (~8)

Carried forward.

- `setDefaultPrediction` bounds and phase gates
- `checkSolvency` insolvent direction (only solvent is covered)
- fallback-feed rejection on a deployment that configures fallbacks (see GovernanceTimelocks,
  where the vacuity guard fired and the test was removed)
- `getCurrentPrizeRate` composition
- `BreathRailReleased` event emission
- solver resumption after the override lock expires
- DORM-GATE precedence over the draw-1 breath clamp (the IC-03 note says the clamp stays until
  this test exists)
- `SolvencyAlert` emission from the three inline checks (claimEndgame, claimDormancyRefund,
  claimPrize)

---

## Priority 7 — invariant fuzzing (LAST, deliberately)

Random legal call sequences, properties checked after every call. Goes last because the
handler must drive calls in legal orders, and the tests above are how that knowledge was
acquired.

- contract USDC balance covers every allocated pool (the SYNC list, five places)
- `seedReleased <= VC_SEED`
- `seedReleased <= cumulativeSeasonTreasury * MAX_SEED_RELEASE_RATIO_BPS / 10000`
- `qualifiedWeeklyOGCount <= weeklyOGCount`
- `drawsPlayed + resetDrawCount == currentDraw - 1` (stated as an invariant in the
  activateDormancy NatSpec, never actually asserted)
- pot plus tier pools conserved across a draw
- treasury locked whenever `prizePot < requiredEndPot` and not settled
- `upfrontOGCount + weeklyOGCount` never exceeds `ogList.length`

**The handler is the work.** Unconstrained, ~95% of generated calls bounce off `WrongPhase`
and the fuzzer tests the guards rather than the logic.

---

## What is genuinely well covered

Recorded so the list above is not mistaken for the whole picture:

pregame registration and refunds (43), the breath engine (51), governance timelocks (41),
keeper and automation (41), draw machinery (30), dormancy (30), emergency reset and unwind
(22), claims and endgame (22), the CRE seam and report guard (25), SmartEarn dormancy and the
H-02 invariant (18), the weekly OG lifecycle (15), deploy (5), and one full-cycle integration.

---

## Housekeeping (not tests)

- **`test/unit/BreathEngine.t (4).sol`** still carries the download-rename artefact. Rename
  before Cyfrin sees the repo.
- **Unused variable** at `AuditFindings.t.sol:118` (`keeperCountsForThisOG = 2`). Open it
  rather than delete it: an unused variable in a test sometimes marks an assertion that was
  intended and never written.
- **Two `uint256(resolvedPrice)` casts** need lint annotations. See KNOWN_ISSUES addendum 2.
