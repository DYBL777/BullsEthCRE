# BullsEthCRE

[![tests](https://github.com/DYBL777/BullsEthCRE/actions/workflows/tests.yml/badge.svg)](https://github.com/DYBL777/BullsEthCRE/actions/workflows/tests.yml)

A 30-draw ETH/USD prediction game on Base Mainnet, settled in USDC, built on Chainlink (Data
Feeds, with a native CRE onReport delivery seam). Part of the DYBL suite.

This contract is a proof-of-concept and reference implementation. Its purpose is to
demonstrate the DYBL economic trust primitives (the breath solvency engine, the OG and
endgame system, the VC seed and spent-return model, and the dormancy waterfall) working
together in a real game. The reusable primitives are the underlying invention; this game is
how they are shown in context.

## Status: frozen, and now a verification anchor

This contract is no longer under active development. That is a deliberate decision rather
than an abandonment, and the reasoning matters more than the fact.

It is 70,811 bytes of deployed bytecode against a 24,576 byte limit. In August 2026 the two
largest features were removed and the results measured rather than estimated: dormancy is
worth 11,742 bytes, the OG mechanism 11,724. With both gone the contract is still roughly
23,000 bytes over. So no amount of feature trimming reaches a deployable size. A deployable
path does exist, through deployed libraries and satellite contracts, but it is a long refactor
with the whole test suite to redo.

Rather than spend the next stretch on that refactor, the work moved to extracting the
primitives into a standalone library, where they are small, individually auditable, and useful
outside this game. This contract's job now is to be the reference each extraction is verified
against. The first extraction, the breath solvency engine, was proven byte-for-byte identical
to the solver in here across thousands of differential fuzz runs. A heavily tested frozen
reference is exactly what that kind of proof needs.

Not deployed. No funds are at risk, and none will be.

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
behaviour is emergent across the full season rather than readable in a single function, and it
took three audit rounds and 51 tests to pin properly.

**Eternal Seed.** A season-locked compounding base: a fixed share of each prize pool is
retained and rolled forward rather than fully paid out, so the pool has a floor that grows
draw on draw instead of resetting to zero. Ring-fenced during the season, with defined exit
paths at settlement and at dormancy. The mechanism that makes a pool durable rather than a
one-shot distribution.

**OG tier and endgame system.** Committed-capital participants prepay a full-season stake and
receive a targeted return at close, with an anti-whale ratio cap bounding how much of the pool
they can hold. Aligns long-term backers with the pool without letting them dominate it.

**VC seed and spent-return model.** A third party seeds the prize pool; unspent seed returns
from the pot (defended inside the solvency floor), and spent seed is reconstituted from
treasury at close with a flat return plus a milestone bonus. The investor is made whole whether
the season completes or the game winds down early.

**Four-tier dormancy waterfall.** If the game winds down early, every participant class is
refunded in strict seniority order (VC seed, then OG pro-rata unplayed principal, then casual
and commitment refunds, then a per-head remainder), so no one is left unable to recover what
they are owed. An orderly wind-down with no loss out of sequence.

Each primitive was built because a fair game needed it, which is why they generalise beyond
the game, to prize-linked savings, insurance reserves, pension-style drawdown, and other
products where a variable-payout pool has to stay solvent and honour every participant in
order. Extracting these into a standalone primitive library is now the active work; this game
is the proof they hold together, and the reference each extraction is checked against.

## Status of this version

Current version: v1.17. Honest state:

**Build and tests.** Compiles under solc 0.8.24 with viaIR. 432 Foundry tests across 24
suites, all passing, run automatically by GitHub Actions on every push. Click the badge above
for the live run, so this is verifiable without taking anyone's word for it.

**Zero contract bugs found by the test suite.** Worth stating plainly because it is the actual
result of the work: across roughly a dozen external audit rounds on the tests themselves,
every finding has been in the tests and none in the contract. The failures were mine:
assertions that passed while measuring the wrong thing, fixtures whose own arithmetic defeated
them, expectations satisfied by any revert rather than the intended one. Each is recorded in
the test file that carried it, because a test that passes for the wrong reason is worse than no
test at all.

**Security findings.** Both Critical findings are closed. Settlement timing is now pinned to a
specific Chainlink round rather than read at whatever instant the caller chooses (C-01), and
CRE workflow authentication is handled by a separate CreReportGuard contract (C-02). Two
Mediums and five Lows are also closed. Three Highs remain open and are described in full in
KNOWN_ISSUES.md, which also records four cases where observable behaviour differs from what the
code reads like, and the roughly 90 build warnings, judged rather than ignored.

**What the suite covers.** Pregame registration and refunds, the breath solvency engine,
governance timelocks, keeper and CRE automation, the draw cycle, the dormancy waterfall,
emergency reset and unwind, claims and endgame, treasury withdrawal, the weekly OG lifecycle,
prize distribution mechanics, reset refunds, the draw-30 bonus fund, the Chainlink feed guards
including the circuit breaker, and audit-finding regressions.

**Invariant fuzzing.** Nine properties run on every CI push, 32 random call sequences of 400
calls each per property. They check that the contract's USDC balance covers every allocated
pool, that seed release stays inside both its absolute and its ratio ceiling, that qualified
weekly OGs remain a subset of active ones, that the treasury never exceeds holdings, that
every draw number is either played or voided, that senior dormancy tiers are funded before
junior ones, that the season never runs past its end, and that distribution indices stay in
bounds. The campaign asserts its own progress, so a run that completes no draws fails CI
rather than passing quietly. Observed inside single sequences: multiple clean draws, emergency
resets that void a draw, dormancy wind-downs with waterfall refunds, and deliberate cutoff
sabotage followed by recovery.

**What it still does not cover.** Most view functions are untested, and that is now the
largest gap: views are what frontends and keepers read, so a wrong view is a wrong decision
downstream with nothing reverting. Several sweep tails and a handful of revert branches are
also open. Nine assertions in the suite expect a revert without naming which one, so they
would pass on the wrong error. The full list, in priority order, is in TESTING_BACKLOG.md.

The breath engine has fuzz coverage of the solver algorithm plus scenario coverage of its
wiring, and the honesty limits of that pair are documented in the test file itself: the fuzz
runs against a hand-transcribed mirror, because the solver is internal and cannot be called
from a test. A separate test pins that mirror against the contract's real behaviour, so silent
drift fails a test. That reduces the risk without eliminating it.

**Deployment gate.** Over the EIP-170 runtime size limit: 70,811 bytes against 24,576. See the
frozen-status note above for what was measured and what follows from it. Note that library
extraction only reduces size if the extracted functions are external or public; an internal
library is inlined at compile time and saves nothing. Printed on every CI run so it stays
visible.

## Repository

```
src/BullsEthCRE.sol      the game contract
src/IBullsEthCRE.sol     public interface: errors, events, documented signatures
src/CreReportGuard.sol   CRE workflow authentication shim (C-02)
test/                    Foundry suite, including the invariant campaign
KNOWN_ISSUES.md          open findings, behaviour notes, and deployment gates
TESTING_BACKLOG.md       remaining test coverage, in priority order
CHANGELOG.md             consolidated version history
```

## Running the tests

Dependencies are fetched automatically, so a clean clone needs no manual setup:

```
forge test
```

CI runs exactly this on every push. See `.github/workflows/tests.yml`.

Note that `forge build --sizes` exits non-zero while any contract is over the limit, so it is
not used as a build step here. `forge test` is unaffected and needs no size setting.
