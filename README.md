# BullsEthCRE Foundry suite, ported to v1.12

Self-contained. Dependencies are vendored in `lib/`, so no network access is needed.

## Run

    forge test

If forge cannot fetch solc, download it once and point at it:

    curl -L -o solc-0.8.24 https://github.com/ethereum/solidity/releases/download/v0.8.24/solc-static-linux
    chmod +x solc-0.8.24
    forge test --use ./solc-0.8.24 --offline

## Contents

    src/BullsEthCRE.sol      v1.12 implementation (comment-only vs v1.11c)
    src/IBullsEthCRE.sol     v1.12 interface
    test/BullsEthBase.t.sol  shared harness: mocks, funded players, lifecycle helpers
    test/Deploy.t.sol        deployment and genesis solvency
    test/Pregame.t.sol       registration, commitment, OG paths
    test/DrawCycle.t.sol     full happy-path draw
    test/CreSeam.t.sol       onReport dispatch and forwarder access control
    test/AuditFindings.t.sol NEW: executable demonstrations of C-01, H-01, H-05

## Note on AuditFindings.t.sol

These tests PASS while the findings are present. They assert the broken behaviour.
When a fix lands the test will fail, and must then be rewritten to assert the
corrected behaviour. That inversion is deliberate.
