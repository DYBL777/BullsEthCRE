// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  MockAggregatorWithBounds
/// @notice A Chainlink feed mock that DOES implement `minAnswer` and `maxAnswer`.
///
/// @dev    WHY THIS EXISTS. The contract carries circuit-breaker protection at three sites
///         (_readPinnedPrice, _readEthPrice, _readPriceFeed): a price sitting at or beyond
///         the aggregator's own clamp bounds is treated as INVALID and the ladder falls
///         through to the next feed. This is the LUNA-crash class of protection, where an
///         oracle keeps reporting its floor long after the real price has gone through it.
///
///         The existing MockAggregator does not implement those two functions, so every one
///         of those `try` blocks has only ever taken its `catch` path and the comparisons
///         themselves have NEVER EXECUTED in any test. Three guard sites, zero coverage, and
///         `minAnswer` is a ten-second grep for anyone reviewing this repo.
///
///         Rounds carry an EXPLICIT timestamp rather than using block.timestamp, because
///         _readPinnedPrice requires a round strictly before the scheduled slot in order to
///         prove firstness. Without a settable timestamp the firstness fallback fires first
///         and the clamp comparison is never reached, which would make a passing test
///         meaningless.
contract MockAggregatorWithBounds {
    uint8   private immutable _decimals;
    int192  private immutable _minAnswer;
    int192  private immutable _maxAnswer;

    struct Round { int256 answer; uint256 updatedAt; }
    mapping(uint80 => Round) private _rounds;
    uint80 private _latest;

    constructor(uint8 decimals_, int192 minAnswer_, int192 maxAnswer_) {
        _decimals  = decimals_;
        _minAnswer = minAnswer_;
        _maxAnswer = maxAnswer_;
    }

    function decimals() external view returns (uint8) { return _decimals; }
    function minAnswer() external view returns (int192) { return _minAnswer; }
    function maxAnswer() external view returns (int192) { return _maxAnswer; }
    function description() external pure returns (string memory) { return "bounded mock"; }
    function version() external pure returns (uint256) { return 1; }

    /// @dev Explicit timestamp: see the firstness note above.
    function pushRoundAt(int256 answer_, uint256 updatedAt_) external returns (uint80) {
        _latest++;
        _rounds[_latest] = Round(answer_, updatedAt_);
        return _latest;
    }

    function getRoundData(uint80 roundId_)
        external view returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = _rounds[roundId_];
        return (roundId_, r.answer, r.updatedAt, r.updatedAt, roundId_);
    }

    function latestRoundData()
        external view returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = _rounds[_latest];
        return (_latest, r.answer, r.updatedAt, r.updatedAt, _latest);
    }
}
