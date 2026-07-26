// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockSequencer
/// @notice L2 sequencer uptime feed stand-in. The contract's _checkSequencer()
///         requires answer == 0 (sequencer up) and that at least
///         SEQUENCER_GRACE_PERIOD (1 hour) has passed since startedAt.
///         startedAt is fixed at 1, so as long as the test's block.timestamp is
///         comfortably above 1 hour (the base harness warps well past that), the
///         grace check always passes. Toggle s_answer to 1 to simulate downtime.
contract MockSequencer {
    int256 internal s_answer = 0; // 0 = up, 1 = down
    uint256 internal s_startedAt = 1;

    function setStatus(int256 answer, uint256 startedAt) external {
        s_answer = answer;
        s_startedAt = startedAt;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, s_answer, s_startedAt, s_startedAt, 1);
    }
}
