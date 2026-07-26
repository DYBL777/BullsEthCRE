// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockAggregator
/// @notice Chainlink AggregatorV3Interface stand-in with REAL ROUND HISTORY.
/// @dev    [v1.15] Rewritten for C-01. The previous version returned the current price and
///         block.timestamp for ANY roundId, which made it impossible to test round pinning:
///         every round looked identical and every round looked like it was the right one.
///         Rounds are now stored with the timestamp they were pushed at, so getRoundData
///         answers historically and the contract's firstness check can actually be exercised.
///
///         8 decimals, matching the constructor's feed check. Intentionally does NOT
///         implement minAnswer/maxAnswer, so the contract's try/catch bounds checks are
///         skipped, which is the safe default in _readEthPrice and _readPinnedPrice.
contract MockAggregator {
    uint8 public immutable decimals;
    string public description = "MOCK / USD";
    uint256 public version = 4;

    struct Round { int256 answer; uint256 updatedAt; }
    mapping(uint80 => Round) internal rounds;
    uint80 internal s_latest;

    constructor(uint8 _decimals, int256 _initialPrice) {
        decimals = _decimals;
        s_latest = 1;
        rounds[1] = Round(_initialPrice, block.timestamp);
    }

    /// @notice Record a new round at the CURRENT block timestamp. Returns its id.
    function pushRound(int256 _price) public returns (uint80) {
        s_latest += 1;
        rounds[s_latest] = Round(_price, block.timestamp);
        return s_latest;
    }

    /// @notice Back-compatible alias used by older tests.
    function setPrice(int256 _price) external { pushRound(_price); }

    function latestRound() external view returns (uint80) { return s_latest; }
    function latestAnswer() external view returns (int256) { return rounds[s_latest].answer; }

    function latestRoundData()
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory r = rounds[s_latest];
        return (s_latest, r.answer, r.updatedAt, r.updatedAt, s_latest);
    }

    /// @dev Unknown rounds return zeros, which the contract treats as invalid.
    function getRoundData(uint80 _roundId)
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory r = rounds[_roundId];
        return (_roundId, r.answer, r.updatedAt, r.updatedAt, _roundId);
    }
}
