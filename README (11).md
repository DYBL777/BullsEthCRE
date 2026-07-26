[![tests](https://github.com/DYBL777/BullsEthCRE/actions/workflows/tests.yml/badge.svg)](https://github.com/DYBL777/BullsEthCRE/actions/workflows/tests.yml)

# BullsEthCRE

A 30-draw ETH/USD prediction game on Base Mainnet, settled in USDC, built on Chainlink
(Data Feeds, with a native CRE `onReport` delivery seam). Part of the DYBL suite.

> This contract is a proof-of-concept / reference implementation. Its purpose is to demonstrate the
> DYBL economic trust primitives (the breath solvency engine, the OG/endgame system, the VC
> seed and spent-return model, and the dormancy waterfall) working together in a real game. The
> reusable primitives are the underlying invention; this game is how they are shown in context.

## What it is

Players predict the ETH/USD price each draw over a 90-day, 30-draw season. Underneath the game
sits a set of economic trust mechanisms: a geometric "breath" solvency engine that keeps the prize
pool on a solvent trajectory, an OG tier and endgame system, a VC seed and spent-return model, and
a dormancy waterfall that refunds participants in strict seniority order if the game winds down
early. The design goal throughout is that the prize economics stay solvent and predictable, and
that nobody is left unable to recover what they are owed.

## The primitives

The game exists to demonstrate five reusable economic trust primitives. These are the invention;
the game is the context that exercises them under real money movement.

**Geometric breath solvency engine.** A binary-search solver that sets each draw's prize rate so
the pool stays on a solvent trajectory to the season's end obligations, projecting the pot forward
across the remaining draws under an EMA revenue estimate. It keeps a variable-payout pool solvent
over time without a fixed drawdown schedule. This is the one primitive whose behaviour is emergent
across the full season rather than readable in a single function, so it is the one that most needs
the runtime test layer to fully confirm.

**Eternal Seed.** A permanent compounding base: a fixed share of each prize pool is retained and
rolled forward rather than fully paid out, so the pool has a floor that grows draw on draw instead
of resetting to zero. The mechanism that makes a pool durable across seasons rather than a
one-shot distribution.

**OG tier and endgame system.** Committed-capital participants prepay a full-season stake and
receive a targeted return at close, with an anti-whale ratio cap bounding how much of the pool
they can hold. Aligns long-term backers with the pool without letting them dominate it.

**VC seed and spent-return model.** A third party seeds the prize pool; unspent seed returns from
the pot (defended inside the solvency floor), and spent seed is reconstituted from treasury at
close with a flat return plus a milestone bonus. The investor is made whole whether the season
completes or the game winds down early.

**Four-tier dormancy waterfall.** If the game winds down early, every participant class is refunded
in strict seniority order (VC seed, then OG pro-rata unplayed principal, then casual and commitment
refunds, then a per-head remainder), so no one is left unable to recover what they are owed. An
orderly wind-down with no loss out of sequence.

Each primitive was built because a fair game needed it, which is why they generalise beyond the
game, to prize-linked savings, insurance reserves, pension-style drawdown, and other products where
a variable-payout pool has to stay solvent and honour every participant in order. Extracting these
into a standalone primitive library is the direction this work is heading; the game is the proof
they hold together.

## Status

**Current version: v1.17.** Honest state of this version:

**Build and tests.** Compiles under solc 0.8.24 with viaIR. **59 Foundry tests, all passing**,
run automatically by GitHub Actions on every push. Click the badge above for the live run, so
this is verifiable without taking anyone's word for it.

**Security findings.** Both Critical findings are closed. Settlement timing is now pinned to a
specific Chainlink round rather than read at whatever instant the caller chooses (C-01), and CRE
workflow authentication is handled by a separate `CreReportGuard` contract (C-02). Two Mediums
and five Lows are also closed. Per-version changelogs carry the full history; open findings are
in `KNOWN_ISSUES.md`.

**Test coverage is regression-focused, not comprehensive.** This matters more than the passing
count. The suite proves the audit findings stay fixed, and 46 of the 59 tests exist for that
purpose. It does **not** yet cover the dormancy waterfall, emergency reset paths, governance
timelocks, or prize tier distribution beyond a single happy-path draw. The breath engine has
fuzz coverage of the solver algorithm plus scenario coverage of its wiring, and the honesty
limits of that pair are documented in the test file itself.

**Deployment gate.** Over the EIP-170 runtime size limit: 70,811 bytes against 24,576. The size
split, moving logic into libraries to get under the limit, is the outstanding gate. Printed on
every CI run so it stays visible.

**Not deployed. No funds are at risk.**

## Repository

```
src/BullsEthCRE.sol      the game contract
src/IBullsEthCRE.sol     public interface: errors, events, documented signatures
src/CreReportGuard.sol   CRE workflow authentication shim (C-02)
test/                    Foundry suite
KNOWN_ISSUES.md          open findings and deployment gates
CHANGELOG.md             consolidated version history
```

## Running the tests

Dependencies are fetched automatically, so a clean clone needs no manual setup:

```
forge test
```

CI runs exactly this on every push. See `.github/workflows/tests.yml`.
