// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {MockAggregatorWithBounds} from "../mocks/MockAggregatorWithBounds.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

/// @title  Feed and launch guards
/// @notice The protections that sit between the outside world and a settlement: the oracle
///         circuit breaker, the L2 sequencer gate, the insolvent-launch check, and the
///         refusal to settle a draw nobody entered.
///
/// @dev    Written before invariant fuzzing. Three of the four are things the fuzz handler
///         will pass through on every single sequence without ever exercising, and the
///         fourth is a launch-time guard the fuzz will never reach at all.
///
///         THE CIRCUIT BREAKER IS THE ONE THAT MATTERS MOST HERE. The contract rejects a
///         price sitting at or beyond the aggregator's own clamp bounds, which is the
///         LUNA-crash case: an oracle that keeps reporting its floor long after the real
///         price has fallen through it. The protection is at three sites. None of the
///         comparisons had ever executed, because the existing mock does not implement
///         minAnswer or maxAnswer and every call took the catch path instead.
contract FeedGuardsTest is SmartEarnBase {
    using stdStorage for StdStorage;

    int192 internal constant CLAMP_MIN = 1_000_00000000;   // $1,000, 8dp
    int192 internal constant CLAMP_MAX = 100_000_00000000; // $100,000, 8dp

    /// @dev Swaps the live feed for a bounded one via the normal governance path, so the
    ///      contract is genuinely reading a feed that answers minAnswer/maxAnswer. Buying
    ///      happens FIRST because the 7-day timelock closes draw 1's 48-hour pick window.
    function _swapToBoundedFeed() internal returns (MockAggregatorWithBounds bounded, uint256 slot) {
        bounded = new MockAggregatorWithBounds(8, CLAMP_MIN, CLAMP_MAX);

        _buyAllPlayers(1);
        slot = bulls.lastDrawTimestamp() + DRAW_COOLDOWN;

        bulls.proposeFeedChange(address(bounded));
        vm.warp(block.timestamp + bulls.TIMELOCK_DELAY() + 1);
        bulls.executeFeedChange();

        // An earlier round BEFORE the slot, so _readPinnedPrice can prove firstness. Without
        // it the firstness fallback rejects on the time window instead and the clamp
        // comparison is never reached, which would make these tests pass for the wrong
        // reason entirely.
        bounded.pushRoundAt(int256(uint256(uint192(CLAMP_MIN))) * 2, slot - 1 hours);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The oracle circuit breaker
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A PRICE PINNED AT THE AGGREGATOR'S FLOOR IS NOT A PRICE. When an oracle's
    ///         circuit breaker trips, it stops reporting the market and starts reporting its
    ///         own bound. Settling a nearest-the-price game on that figure would hand the
    ///         prize to whoever guessed the clamp rather than whoever guessed the market.
    function test_CircuitBreaker_APriceAtTheFloorIsRejected() public {
        _bootstrapAndStart();
        (MockAggregatorWithBounds bounded, uint256 slot) = _swapToBoundedFeed();

        uint80 rid = bounded.pushRoundAt(int256(uint256(uint192(CLAMP_MIN))), slot + 1);

        vm.expectRevert(IBullsEthCRE.NotEnoughValidPrices.selector);
        bulls.resolveWeek(rid);
    }

    /// @notice And at the ceiling, which is the same protection from the other side.
    function test_CircuitBreaker_APriceAtTheCeilingIsRejected() public {
        _bootstrapAndStart();
        (MockAggregatorWithBounds bounded, uint256 slot) = _swapToBoundedFeed();

        uint80 rid = bounded.pushRoundAt(int256(uint256(uint192(CLAMP_MAX))), slot + 1);

        vm.expectRevert(IBullsEthCRE.NotEnoughValidPrices.selector);
        bulls.resolveWeek(rid);
    }

    /// @notice THE CONTROL, and the test above is worthless without it. A price one unit
    ///         inside the bound settles normally. If it did not, the two rejections above
    ///         would be satisfied by a feed swap that broke resolution outright, which is a
    ///         different bug with an identical symptom.
    function test_CircuitBreaker_APriceJustInsideTheBoundIsAccepted() public {
        _bootstrapAndStart();
        (MockAggregatorWithBounds bounded, uint256 slot) = _swapToBoundedFeed();

        uint80 rid = bounded.pushRoundAt(int256(uint256(uint192(CLAMP_MIN))) + 1, slot + 1);
        bulls.resolveWeek(rid);

        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION),
            "one unit inside the clamp is a real price and settles"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The sequencer gate
    // ══════════════════════════════════════════════════════════════════════

    /// @notice On an L2, a downed sequencer means the feed is stale by construction: no new
    ///         rounds are being published and no transactions are landing. Settling through
    ///         that would use a price from before the outage. Every resolution and every
    ///         start passes through this gate and it had never fired in any test.
    ///
    /// @dev    The sequencer feed is immutable, so it is mocked in place rather than
    ///         swapped. `answer != 0` is the down signal in Chainlink's uptime feed.
    function test_Sequencer_ResolutionRefusesWhileTheSequencerIsDown() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        vm.mockCall(
            bulls.SEQUENCER_FEED(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), uint256(1), block.timestamp - 2 hours, uint80(1))
        );

        uint80 rid = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.SequencerNotReady.selector);
        bulls.resolveWeek(rid);
    }

    /// @notice And it stays shut through the grace period AFTER the sequencer returns. A feed
    ///         that has just come back has not caught up yet, so the hour of quarantine is
    ///         the point rather than an inconvenience.
    function test_Sequencer_ResolutionRefusesInsideTheGracePeriod() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        // answer 0 means up, but startedAt is recent, so the grace period has not elapsed.
        vm.mockCall(
            bulls.SEQUENCER_FEED(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp - 1 minutes, block.timestamp, uint80(1))
        );

        uint80 rid = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.SequencerNotReady.selector);
        bulls.resolveWeek(rid);
    }

    /// @notice A sequencer feed that reverts outright is treated as down rather than ignored.
    ///         The catch arm, which is the one that matters if the uptime feed itself is the
    ///         thing that has failed.
    function test_Sequencer_ARevertingUptimeFeedIsTreatedAsDown() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();

        vm.mockCallRevert(
            bulls.SEQUENCER_FEED(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            "sequencer feed is down"
        );

        uint80 rid = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.SequencerNotReady.selector);
        bulls.resolveWeek(rid);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The insolvent-launch guard
    // ══════════════════════════════════════════════════════════════════════

    /// @notice THE GUARD THAT STOPS A BROKEN SEASON LAUNCHING AT ALL. Before the game starts,
    ///         the contract simulates the pot forward across all 30 draws at the MINIMUM
    ///         possible distribution rate. If it still cannot reach the end-of-season floor,
    ///         the season is unwinnable by construction and startGame reverts rather than
    ///         opening a game that cannot pay what it promises.
    ///
    ///         Also closes the long-standing gap on `checkSolvency`'s insolvent direction:
    ///         the same fixture answers both, because the view and the gate compute the same
    ///         figure from the same state. That equivalence is the point of the pairing, and
    ///         asserting both here is what proves the preview cannot disagree with the gate.
    ///
    /// @dev    STATE INJECTION, disclosed. The pot is written down and the matching USDC
    ///         moved out. BOTH are needed: `checkSolvency` reads `prizePot` directly so the
    ///         write alone answers the view, while `startGame` runs `_captureYield` first,
    ///         which would restore the pot from the real balance if the balance were left
    ///         intact. The injection only makes a gate FIRE.
    ///
    ///         Worth recording plainly: this branch is NOT reachable through any legal
    ///         pregame configuration. Every OG adds more to the pot than to the floor, and
    ///         the 500-player minimum guarantees revenue that outruns the decay. A guard
    ///         against a state the economics forbid can only be demonstrated by manufacturing
    ///         it, and the alternative is shipping a launch check nothing has ever executed.
    function test_Launch_AnInsolventDeploymentIsRefusedAndPreviewedAsSuch() public {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);

        // Strip the pot to a level the 30-draw projection cannot recover from.
        uint256 crippled = bulls.VC_SEED() / 50;
        stdstore.target(address(bulls)).sig("prizePot()").checked_write(crippled);

        address sink = _newFundedPlayer(76001);
        uint256 held = usdc.balanceOf(address(bulls));
        uint256 keep = crippled + bulls.treasuryBalance();
        vm.prank(address(bulls));
        usdc.transfer(sink, held - keep);

        // The PREVIEW agrees, which is the half that has never been tested.
        (bool solvent, uint256 deficit) = bulls.checkSolvency();
        assertFalse(solvent, "checkSolvency reports the deployment as insolvent");
        assertGt(deficit, 0, "and quantifies the per-draw revenue shortfall");

        // And the GATE enforces it, on the same numbers.
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.PotBelowTrajectory.selector);
        bulls.startGame();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  The empty-draw refusal
    // ══════════════════════════════════════════════════════════════════════

    /// @notice A DRAW NOBODY ENTERED CANNOT BE SETTLED. With no entries there is nothing to
    ///         match, and the cutoff bands divide by the entry count, so allowing it through
    ///         would carry a division by zero into the next phase. Refusing at the gate is
    ///         what keeps that arithmetic safe further down.
    ///
    /// @dev    Reached by finalising draw 1 normally, which clears `weeklyNonOGPlayers`, and
    ///         then letting draw 2's window pass with nobody buying. No OGs in this fixture,
    ///         so both halves of the condition are genuinely empty.
    function test_EmptyDraw_ResolutionRefusesWhenNobodyEntered() public {
        _bootstrapAndStart();
        _runStandardDraw(); // draw 1 completes, the buyer list is cleared

        assertEq(bulls.currentDraw(), 2, "precondition: at draw 2 with nobody in it");

        _warpToCooldownEnd();
        uint80 rid = ethFeed.pushRound(ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.NotEnoughPlayers.selector);
        bulls.resolveWeek(rid);
    }
}
