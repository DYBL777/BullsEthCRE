BullsEthCRE
A 30-draw ETH/USD prediction game on Base Mainnet, settled in USDC, built on Chainlink
(Data Feeds, with a native CRE `onReport` delivery seam). Part of the DYBL suite.
> This contract is a proof-of-concept / reference implementation. Its purpose is to demonstrate the
> DYBL economic trust primitives (the breath solvency engine, the OG/endgame system, the VC
> seed and spent-return model, and the dormancy waterfall) working together in a real game. The
> reusable primitives are the underlying invention; this game is how they are shown in context.
What it is
Players predict the ETH/USD price each draw over a 90-day, 30-draw season. Underneath the game
sits a set of economic trust mechanisms: a geometric "breath" solvency engine that keeps the prize
pool on a solvent trajectory, an OG tier and endgame system, a VC seed and spent-return model, and
a dormancy waterfall that refunds participants in strict seniority order if the game winds down
early. The design goal throughout is that the prize economics stay solvent and predictable, and
that nobody is left unable to recover what they are owed.
Status
Honest state of this version:
Over the EIP-170 runtime size limit (24,576 bytes). The size split, moving logic into libraries
to get under the limit, is the outstanding deployment gate. See `KNOWN_ISSUES.md`.
Foundry tests are written but not yet run. The runtime layer is not proven. See `KNOWN_ISSUES.md`.
Logic has been hardened over many internal audit rounds, design by design and step by step.
Documentation
`KNOWN_ISSUES.md`, the open list: what is known to still need doing before this is
deployment-ready (the size split, the unrun test suite, and other tracked follow-ups). Not a log
of resolved findings.
`CHANGELOG.md`, the change record for this version.
Build
```
solc 0.8.24 --via-ir --optimize
```
(OpenZeppelin 4.9.6 + Chainlink contracts as dependencies.)
License
Copyright (c) 2026 DYBL. All rights reserved. (Confirm your intended license before publishing.)
