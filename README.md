[README (8).md](https://github.com/user-attachments/files/29982832/README.8.md)
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

Honest state of this version:

- Over the EIP-170 runtime size limit (24,576 bytes). The size split, moving logic into libraries
  to get under the limit, is the outstanding deployment gate. See `KNOWN_ISSUES.md`.
- Foundry tests are written but not yet run. The runtime layer is not proven. See `KNOWN_ISSUES.md`.
- Logic has been hardened over many internal audit rounds, design by design and step by step.

## Documentation

- `KNOWN_ISSUES.md`, the open list: what is known to still need doing before this is
  deployment-ready (the size split, the unrun test suite, and other tracked follow-ups). Not a log
  of resolved findings.
- `CHANGELOG.md`, the change record for this version.

## Build

```
solc 0.8.24 --via-ir --optimize
```
(OpenZeppelin 4.9.6 + Chainlink contracts as dependencies.)

## License

Copyright (c) 2026 DYBL. All rights reserved. (Confirm your intended license before publishing.)
