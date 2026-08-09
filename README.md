# BullsEthCRE

A 30-draw ETH/USD prediction game on Base Mainnet, settled in USDC, built on Chainlink (Data
Feeds, with a native CRE `onReport` delivery seam). Part of the DYBL suite.

This contract is a proof-of-concept / reference implementation. Its purpose is to demonstrate
the DYBL economic trust primitives (the breath solvency engine, the OG/endgame system, the VC
seed and spent-return model, and the dormancy waterfall) working together in a real game. The
reusable primitives are the underlying invention; this game is how they are shown in context.

## What it is

Players predict the ETH/USD price each draw over a 90-day, 30-draw season. Underneath the
game sits a set of economic trust mechanisms: a geometric "breath" solvency engine that keeps
the prize pool on a solvent trajectory, an OG tier and endgame system, a VC seed and
spent-return model, and a dormancy waterfall that refunds participants in strict seniority
order if the game winds down early. The design goal throughout is that the prize economics
stay solvent and predictable, and that nobody is left unable to recover what they are owed.

## The primitives

The game exists to demonstrate five reusable economic trust primitives. These are the
invention; the game is the context that exercises them under real money movement.

**Geometric breath solvency engine.** A binary-search solver that sets each draw's prize rate
so the pool stays on a solvent trajectory to the season's end obligations, projecting the pot
forward across the remaining draws under an EMA revenue estimate. It keeps a variable-payout
pool solvent over time without a fixed drawdown schedule. This is the one primitive whose
behaviour is emergent across the full season rather than readable in a single function, and
it took three audit rounds and 51 tests to pin properly.

**Eternal Seed.** A permanent compounding base: a fixed share of each prize pool is retained
and rolled forward rather than fully paid out, so the pool has a floor that grows draw on draw
instead of resetting to zero. The mechanism that makes a pool durable across seasons rather
than a one-shot distribution.

**OG tier and endgame system.** Committed-capital participants prepay a full-season stake and
receive a targeted return at close, with an anti-whale ratio cap bounding how much of the pool
they can hold. Aligns long-term backers with the pool without letting them dominate it.

**VC seed and spent-return model.** A third party seeds the prize pool; unspent seed returns
from the pot (defended inside the solvency floor), and spent seed is reconstituted from
treasury at close with a flat return plus a milestone bonus. The investor is made whole
whether the season completes or the game winds down early.

**Four-tier dormancy waterfall.** If the game winds down early, every participant class is
refunded in strict seniority order (VC seed, then OG pro-rata unplayed principal, then casual
and commitment refunds, then a per-head remainder), so no one is left unable to recover what
they are owed. An orderly wind-down with no loss out of sequence.

Each primitive was built because a fair game needed it, which is why they generalise beyond
the game, to prize-linked savings, insurance reserves, pension-style drawdown, and other
products where a variable-payout pool has to stay solvent and honour every participant in
order. Extracting these into a standalone primitive library is the direction this work is
heading; the game is the proof they hold together.

## Status

**Current version: v1.17.** Honest state of this version:

**Build and tests.** Compiles under solc 0.8.24 with viaIR. **379 Foundry tests across 19
suites, all passing**, run automatically by GitHub Actions on every push. Click the badge
above for the live run, so this is verifiable without taking anyone's word for it.

**Zero contract bugs found by the test suite.** Worth stating plainly because it is the actual
result of the work: across roughly a dozen external audit rounds on the tests themselves,
**every finding has been in the tests and none in the contract.** The failures were mine:
assertions that passed while measuring the wrong thing, fixtures whose own arithmetic defeated
them, expectations satisfied by any revert rather than the intended one. Each is recorded in
the test file that carried it, because a test that passes for the wrong reason is worse than
no test at all.

**Security findings.** Both Critical findings are closed. Settlement timing is now pinned to a
specific Chainlink round rather than read at whatever instant the caller chooses (C-01), and
CRE workflow authentication is handled by a separate `CreReportGuard` contract (C-02). Two
Mediums and five Lows are also closed. Per-version changelogs carry the full history; open
findings are in `KNOWN_ISSUES.md`, which also records four cases where observable behaviour
differs from what the code reads like, and the roughly 90 build warnings, judged rather than
ignored.

**What the suite covers.** Pregame registration and refunds, the breath solvency engine,
governance timelocks, keeper and CRE automation, the draw cycle, the dormancy waterfall,
emergency reset and unwind, claims and endgame, treasury withdrawal, the weekly OG lifecycle,
and audit-finding regressions.

**What it does not yet cover, and this matters more than the passing count.** Prize
distribution mechanics beyond winner counts: nothing yet asserts what a winner actually
*receives*, which is the last area where a bug means someone is paid the wrong amount. Tier
ordering, dust return, the empty-tier and zero-per-winner paths, batched distribution past the
per-transaction cap, and boundary ties on the inclusive cutoffs are all still open. Most view
functions are untested. Invariant fuzzing is deliberately last, because its handler must drive
calls in legal orders and the suite above is how that knowledge was acquired. The full list,
in priority order, is in `TESTING_BACKLOG.md`.

The breath engine has fuzz coverage of the solver algorithm plus scenario coverage of its
wiring, and the honesty limits of that pair are documented in the test file itself: the fuzz
runs against a hand-transcribed mirror, because the solver is internal and cannot be called
from a test.

**Deployment gate.** Over the EIP-170 runtime size limit: **70,811 bytes against 24,576**. The
size split, moving logic into libraries to get under the limit, is the outstanding gate. Note
that library extraction only reduces size if the extracted functions are `external` or
`public`; an `internal` library is inlined at compile time and saves nothing. Printed on every
CI run so it stays visible.

**Not deployed. No funds are at risk.**

## Repository

```
src/BullsEthCRE.sol      the game contract
src/IBullsEthCRE.sol     public interface: errors, events, documented signatures
src/CreReportGuard.sol   CRE workflow authentication shim (C-02)
test/                    Foundry suite
KNOWN_ISSUES.md          open findings, behaviour notes, and deployment gates
CHANGELOG.md             consolidated version history
```

## Running the tests

Dependencies are fetched automatically, so a clean clone needs no manual setup:

```
forge test
```

CI runs exactly this on every push. See `.github/workflows/tests.yml`.
