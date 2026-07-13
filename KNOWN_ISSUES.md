BullsEthCRE, Known Issues
Things still to do before this is deployment-ready. This is a forward-looking list of open
work, not a log of resolved findings. The per-version change history lives in the changelog.
Status of the code itself: compiles clean (solc 0.8.24, viaIR, 0 errors), logic hardened over
many internal audit rounds. The items below are what stands between this version and mainnet.
---
1. EIP-170 size split (deployment gate)
The contract's runtime bytecode is over the EIP-170 limit (24,576 bytes), so it cannot deploy as
a single contract. Logic needs to move into libraries to get under the limit. This is the primary
gate before any deployment. It does not affect the economics or the audited logic, it is a
packaging step.
2. Foundry test suite is written but not yet run
The runtime layer is not proven. The logic has been reasoned through, but the invariant and
edge-case tests need to actually execute to confirm behaviour under real state transitions
(dormancy waterfall sums, VC solvency near the ratio cap, the floor split, reset-then-dormancy
paths). Until they run, the runtime is unverified.
3. Full removal of the inert tier mechanism
The old fixed-tier VC bonus mechanism was superseded by the spent-return model and is now provably
dead (the constructor rejects tier params unconditionally). The dead code is still in the file. It
should be removed entirely. This also helps item 1, since removing it reduces bytecode.
4. Stale CRE-era NatSpec reconciliation
Some inline comments and NatSpec still describe the pre-CRE economics (the older treasury and
return-curve numbers) rather than the current CRE values. Most were swept across the version
history, but a final accuracy pass is worth doing so no comment contradicts the code it sits on.
---
These are the known open items. Anything not listed here is either resolved (see the changelog) or
outside the scope of this version.
