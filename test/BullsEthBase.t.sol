// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BullsEth} from "../src/BullsEthCRE.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockSequencer} from "./mocks/MockSequencer.sol";

/// @title BullsEthBase
/// @notice Shared deployment and game-driving helpers for the BullsEth suite.
/// @dev    Deploys with VC_SEED = 0, which disables the SmartEarn / VC layer so the
///         core game flow is testable without seeding. A separate suite should cover
///         the VC-enabled path (constructor with a non-zero seed + seedPot()).
///
///         The test contract itself is the deployer, so it is owner(). Owner-only
///         calls are therefore made directly from the test; player calls use vm.prank.
///
///         NOTE: this harness could not be executed inside the environment it was
///         written in (the Foundry binary host was blocked). The numbers in the draw
///         cycle were hand-traced. An engineer should run `forge test` first and treat
///         any failure as a fixture-tuning task, not a contract bug, until proven otherwise.
abstract contract BullsEthBase is Test {
    BullsEth internal bulls;
    MockERC20 internal usdc;
    MockAggregator internal ethFeed;
    MockSequencer internal sequencer;

    address internal beneficiary;

    // Mirror of the contract constants used by the harness.
    uint256 internal constant TICKET_PRICE = 10_000_000; // $10, 6 decimals
    uint256 internal constant OG_UPFRONT_COST = 600_000_000; // $600
    uint256 internal constant MIN_PLAYERS_TO_START = 500;
    uint256 internal constant DRAW_COOLDOWN = 72 hours;
    uint256 internal constant PICK_DEADLINE = 48 hours;
    uint256 internal constant START_GAME_NOTICE_PERIOD = 72 hours;
    uint256 internal constant TREASURY_BPS = 2500;

    // Feed price: $3000 at 8 decimals. A prediction of 300000 (cents) maps to this exactly:
    // predScaled = prediction * 1e6 = 300000 * 1e6 = 3e11 = 3000e8 = resolvedPrice.
    int256 internal constant ETH_PRICE = 3000e8;
    uint256 internal constant BASE_PREDICTION = 300_000; // cents == $3000

    address[] internal players; // populated by _bootstrapCommitted

    function setUp() public virtual {
        // Warp to a realistic timestamp so the sequencer grace period is satisfied
        // (sequencer startedAt = 1) and signup windows are sane.
        vm.warp(1_700_000_000);

        beneficiary = makeAddr("beneficiary");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        ethFeed = new MockAggregator(8, ETH_PRICE);
        sequencer = new MockSequencer();

        bulls = new BullsEth(
            address(usdc),
            address(ethFeed),
            address(0), // _ethReserveFeed  [v1.11b] immutable, address(0) disables this fallback
            address(0), // _wethFeed        [v1.11b] immutable, address(0) disables this fallback
            BASE_PREDICTION, // _defaultPrediction
            address(sequencer),
            beneficiary,
            0, // _vcSeed (disables SmartEarn)
            address(0), // _vcSeedReturnAddress (allowed when seed == 0)
            0, // _maxSeedReleaseRatioBps (0 permitted only because _vcSeed == 0)
            0  // _maxSeedPerDrawBps       (0 permitted only because _vcSeed == 0)
        );

        vm.label(address(bulls), "BullsEth");
        vm.label(address(usdc), "USDC");
    }

    // ─────────────────────────── player helpers ───────────────────────────

    function _newFundedPlayer(uint256 salt) internal returns (address p) {
        p = vm.addr(uint256(keccak256(abi.encode("player", salt))));
        usdc.mint(p, 10_000_000_000); // $10k, ample
        vm.prank(p);
        usdc.approve(address(bulls), type(uint256).max);
    }

    function _commit(address p, uint256 prediction) internal {
        vm.prank(p);
        bulls.register();
        vm.prank(p);
        bulls.payCommitment(prediction);
    }

    /// @notice Creates `n` committed casual players with spread predictions
    ///         (BASE_PREDICTION + i), so a later draw has a real diff distribution.
    function _bootstrapCommitted(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            address p = _newFundedPlayer(i);
            _commit(p, BASE_PREDICTION + i);
            players.push(p);
        }
    }

    // ─────────────────────────── game lifecycle ───────────────────────────

    /// @notice Bootstraps MIN_PLAYERS_TO_START committed players and starts the game.
    ///         After this returns, gamePhase == ACTIVE and currentDraw == 1.
    function _bootstrapAndStart() internal {
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame(); // owner
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        // [v1.15] The mock now reports real round timestamps, so the feed goes stale across
        // a 72h warp exactly as a real one would between heartbeats. Publish a round first,
        // which is what a live feed does on its heartbeat.
        ethFeed.pushRound(ethFeed.latestAnswer());
        bulls.startGame(); // owner
    }

    /// @notice Every bootstrapped player buys one ticket for the current draw,
    ///         using their pregame commitment credit in draw 1.
    function _buyAllPlayers(uint256 ticketCount) internal {
        for (uint256 i = 0; i < players.length; i++) {
            vm.prank(players[i]);
            bulls.buyTickets(ticketCount);
        }
    }

    function _warpToCooldownEnd() internal {
        vm.warp(bulls.lastDrawTimestamp() + DRAW_COOLDOWN);
    }

    /// @dev [v1.15 / C-01] Normal settlement. Publishes a feed round at the scheduled slot
    ///      and settles against it. Mirrors what an off-chain caller does: find the first
    ///      round at or after the slot, then submit that id.
    function _resolvePinned() internal returns (uint80 rid) {
        rid = ethFeed.pushRound(ethFeed.latestAnswer());
        bulls.resolveWeek(rid);
    }

    /// @dev As above but settling on a specific price.
    function _resolvePinnedAt(int256 price) internal returns (uint80 rid) {
        rid = ethFeed.pushRound(price);
        bulls.resolveWeek(rid);
    }
}
