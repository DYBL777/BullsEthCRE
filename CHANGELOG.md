[CHANGELOG_BullsEthCRE_v1.11b (1).md](https://github.com/user-attachments/files/30005585/CHANGELOG_BullsEthCRE_v1.11b.1.md)
# CHANGELOG: BullsEthCRE v1.11b

Base: v1.11a. Completes the tier-mechanism removal that v1.11a's PG-01 fail-close only
neutralised, and makes the two fallback price feeds immutable (per Robbie's size-limit
suggestion). Two independent changes, one version, one compile. Both LOW risk, no live behaviour
path changed. Built and compiled in this workspace, self-audited.

Status: compiles clean (solc 0.8.24, viaIR, optimizer runs 200, 0 errors, 1 benign warning
"state mutability can be restricted to view", unchanged in count from v1.11a).

Byte figures (measured here, both metrics stated to avoid the creation-vs-runtime ambiguity that
earlier changelogs carried, see the note at the end):
- v1.11a: runtime/deployed 71,649, creation 73,630
- v1.11b: runtime/deployed 64,286, creation 66,433
- Saving: 7,363 runtime, 7,197 creation
- EIP-170 applies to the RUNTIME figure: 64,286 vs 24,576, still OVER by 39,710. The library
  size split remains the deployment gate; this is real progress toward it, not a solution to it.

---

## Part A: remove the dead fixed-tier VC bonus mechanism

The old fixed-tier performance bonus was superseded by the spent-seed return model and made
unreachable by v1.11a's PG-01 (constructor rejected all tier params unconditionally). v1.11a left
the mechanism in place and tracked full removal as a follow-up (its VC-01 note). This is that
follow-up. Pure dead-code deletion, no behaviour change on any reachable path.

Removed: the four VC_BONUS_TIER1/2_THRESHOLD/AMOUNT immutables and their constructor params; the
vcBonusEscrow state variable; the VCBonusTierReached event; the two tier-crossing blocks in
buyTickets (and the now-orphaned _prevCT local); the vcBonusEscrow transfer in closeGame and in
sweepDormancyRemainder; the _nextBonus protection block in withdrawTreasury; the getVCBonusStatus
view; the _vcBonusAmount helper; and the associated NatSpec and constructor param docs.

Kept deliberately (these rhyme with the removed names but are LIVE and load-bearing): the entire
spent-seed return model (VC_SPENT_RETURN_BPS, VC_SPENT_BONUS_BPS, VC_SPENT_BONUS_THRESHOLD,
_vcTreasuryObligation, and the withdrawTreasury releasable reserve); the TreasuryBonusProtected
error (still thrown by that reserve); and cumulativeSeasonTreasury tracking (feeds
SEED_RELEASE_THRESHOLD and the spent-return).

Code changes: 4 immutables + 4 params removed; 1 state var removed; 1 event removed; 2 buyTickets
blocks + 1 local removed; 2 escrow-transfer lines removed; 1 withdrawTreasury block removed; 2
views removed; 4 solvency-sum sites cleared of the vcBonusEscrow term (the SYNC set stays
consistent; every sum was numerically unchanged since the term was always 0).
NatSpec: 4 constructor @param docs removed, immutable and view docs removed.

ABI impact: removes the vcBonusEscrow() getter and the getVCBonusStatus() view; removes 4
constructor params.

## Part B: make the fallback feeds immutable

ethReserveFeed and wethFeed become immutable, set once in the constructor (two new params), with
the validation moved out of the deleted setters into the constructor (decimals == 8, not USDC /
self / sequencer, no feed-equals-feed collision; address(0) permitted = fallback disabled). The
primary feed ethFeed stays mutable and the full proposeFeedChange / executeFeedChange /
cancelFeedChange timelock path is untouched, so the primary ETH/USD feed can still follow a
Chainlink aggregator re-address, and the startGame primary-fail repoint (ethFeed = ethReserveFeed)
still compiles because ethFeed is still mutable. The FeedSubstituted event is kept (still emitted
by that repoint).

Code changes: 2 state vars to immutable; setReserveFeed and setWethFeed deleted; constructor gains
2 params and a validation-and-assignment block. NatSpec: 2 constructor @param docs added.

ABI impact: removes the setReserveFeed and setWethFeed functions; adds 2 constructor params.

## Constructor signature (both parts)

Net param change is minus two: four tier params removed, two feed params added. New order:
(_usdc, _ethFeed, _ethReserveFeed, _wethFeed, _defaultPrediction, _sequencerFeed,
_protocolBeneficiary, _vcSeed, _vcSeedReturnAddress, _maxSeedReleaseRatioBps, _maxSeedPerDrawBps).
The Foundry deploy scripts and tests must be updated to this signature before the suite builds.

---

## Self-audit performed

- Part A: grep confirms zero executable references remain to VC_BONUS_TIER*, vcBonusEscrow,
  VCBonusTierReached, getVCBonusStatus, or _vcBonusAmount. TreasuryBonusProtected retained and
  still referenced by the spent-return reserve. Spent-return model untouched.
- Part B: confirmed ethFeed retains its write sites (constructor, startGame repoint,
  executeFeedChange), so leaving it mutable keeps all three compiling. ethReserveFeed and wethFeed
  have no write sites other than the deleted setters, so immutable + constructor-set is
  self-contained. All remaining references to them are reads (startGame, resolveWeek,
  proposeFeedChange), valid against immutables.
- Compiles clean (0 errors). Byte figures measured, both metrics reported.
- NOT verified: behavioural correctness. The Foundry suite was not run (it needs the new
  constructor signature first). "Compiles" is not "tested."

## Change-routing summary (for the separate coding thread)

- Logic/state changes: Part A removals across constructor, buyTickets, closeGame,
  sweepDormancyRemainder, withdrawTreasury, and the 4 solvency sums; Part B state-to-immutable,
  setter deletion, constructor validation block.
- ABI changes: removed getter (vcBonusEscrow), removed view (getVCBonusStatus), removed setters
  (setReserveFeed, setWethFeed), constructor signature (net minus two params).
- NatSpec/comment only: the removed/added @param docs and the [v1.11b] inline notes.

## Open before Cyfrin

1. Update the Foundry deploy/tests to the new constructor signature, then run the suite (the real
   behavioural check this change still needs).
2. EIP-170 size split (64,286 runtime vs 24,576) remains the deployment gate.
3. Full tier-mechanism removal is now DONE (this version); the v1.11a VC-01 follow-up is closed.

## Note on byte labelling (reconciliation)

Earlier per-version changelogs (v1.07 through v1.11a) reported a "runtime bytecode" figure that was
actually the CREATION (init) bytecode. For v1.11a that figure was 73,630, which is the creation
bytecode; the true runtime/deployed bytecode (the one EIP-170's 24,576 limit governs) is 71,649.
This file states both metrics explicitly so the distinction is unambiguous going forward. This does
not change any past conclusion (the contract was and is far over the limit either way); it only
corrects which number to quote against EIP-170.

---

## NatSpec fixes folded in (post-build review, zero bytecode change)

An external review plus a Claude cross-check found five doc-only issues; all fixed in this same
v1.11b file, deployed bytecode unchanged at 64,286 (proof they are comment-only):

1. Constructor @param docs for _maxSeedReleaseRatioBps and _maxSeedPerDrawBps said "(0 = no cap)"
   without the seeded-game caveat. For a seeded game (VC_SEED > 0), 0 is a guaranteed constructor
   revert (SEED-CAP / VC-SPENT-CAP guards), not a safe default. Docs now state the caveat.
   (Reviewer finding.)
2. Same "0 = no cap" issue in the two immutable @notice docs (MAX_SEED_RELEASE_RATIO_BPS,
   MAX_SEED_PER_DRAW_BPS), not just the @param lines. Fixed. (Cross-check found; reviewer flagged
   only the @param lines.)
3. _vcSeed @param still listed "no bonus tiers" among what VC_SEED==0 disables; that mechanism no
   longer exists. Removed. (Cross-check.)
4. getSolvencyStatus @return still listed vcBonusEscrow in the allocation sum; removed with the
   fixed-tier bonus. Corrected to the two remaining VC pools. (Cross-check.)
5. Header changelog block mis-titled "BullsEthCRE v1.11a" actually contained v0.14 content ("next
   build is CRE v1.0"). Relabeled to v0.14 with a note. The real v1.11a/v1.11b changes live in the
   per-version CHANGELOG files by design. (Reviewer finding; previously flagged.) NOTE: this is a
   minimal relabel; the full header trim (move the whole CRE arc out to the CHANGELOG files, leave a
   pointer) remains the larger planned cleanup.
