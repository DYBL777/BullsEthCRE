// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SmartEarnBase} from "../base/SmartEarnBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @title  Governance timelocks
/// @notice A timelock is a mandatory wait between announcing a change and being allowed to
///         make it. Without one, the owner could swap the price feed or move the seed dial
///         and players would learn about it afterwards. With one, the intent is public
///         first, and the owner can still cancel during the window.
///
/// @dev    Every triple here is propose / wait / execute, plus cancel. What varies is the
///         DURATION and the BOUNDS, and the durations are deliberately not uniform:
///
///           TIMELOCK_DELAY        7 days   breath override, breath rails, FEED CHANGE
///           SEED_RATIO_TIMELOCK   7 days   seed release ratio  (separate constant!)
///           PRIZE_RATE_TIMELOCK  48 hours  prize rate, exhale floor
///           DORMANCY_TIMELOCK    24 hours  dormancy
///           OWNERSHIP_TRANSFER_EXPIRY 7 days  ownership (an EXPIRY, not a delay)
///
///         TIMELOCK_DELAY and SEED_RATIO_TIMELOCK are both 7 days today but are DIFFERENT
///         constants, so a future change to one must not silently be assumed of the other.
///         They are asserted against their own constant in each test below.
///
///         SCOPE. The breath override, breath rails, prize rate and exhale floor triples are
///         already covered in BreathEngine.t.sol; dormancy propose/activate/cancel in
///         Dormancy.t.sol; start-game propose/execute/cancel in Pregame.t.sol. This file
///         covers what none of those reach: the feed change, the seed release ratio, the
///         two-step ownership transfer, and the cross-cancellation sweep.
contract GovernanceTimelocksTest is SmartEarnBase {
    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant SEED_RATIO_TIMELOCK = 7 days;
    uint256 internal constant OWNERSHIP_TRANSFER_EXPIRY = 7 days;
    // Needed by the emergency-reset cross-cancel test. Declared here because the base
    // harness does not expose it and a bare reference would not compile.
    uint256 internal constant DRAW_STUCK_TIMEOUT = 48 hours;

    // ══════════════════════════════════════════════════════════════════════
    //  Feed change: propose / execute / cancel  (TIMELOCK_DELAY, 7 days)
    // ══════════════════════════════════════════════════════════════════════

    function test_FeedChange_RevertsForNonOwner() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(80001);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.proposeFeedChange(address(0xBEEF));
    }

    function test_FeedChange_RevertsOutsideActive() public {
        _bootstrapCommitted(10);
        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.proposeFeedChange(address(0xBEEF));
    }

    /// @notice The address guards. Every one of these would break settlement if it landed,
    ///         so each gets its own assertion rather than being lumped together.
    function test_FeedChange_RejectsTheZeroAddress() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.proposeFeedChange(address(0));
    }

    function test_FeedChange_RejectsUsdc() public {
        _bootstrapAndStart();
        // Read FIRST. vm.expectRevert applies to the next external call, and a getter in the
        // argument position IS that call, so it would consume the expectation.
        address usdcAddr = bulls.USDC();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.proposeFeedChange(usdcAddr);
    }

    function test_FeedChange_RejectsTheContractItself() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.proposeFeedChange(address(bulls));
    }

    /// @notice Proposing the CURRENT feed is a no-op that would still consume the timelock
    ///         slot, so it is rejected with its own distinct error.
    function test_FeedChange_RejectsTheCurrentFeed() public {
        _bootstrapAndStart();
        address current = bulls.ethFeed();
        vm.expectRevert(IBullsEthCRE.FeedUnchanged.selector);
        bulls.proposeFeedChange(current);
    }

    /// @notice The two immutable fallback feeds are rejected as a new PRIMARY. Promoting a
    ///         fallback would leave the fallback chain pointing at the same source, quietly
    ///         removing the redundancy it exists to provide.
    ///
    /// @dev    LOCAL REDEPLOY, and the reason is worth recording. An earlier version of this
    ///         test ran against the shared fixture and carried a vacuity guard requiring at
    ///         least one fallback to be configured. On execution THE GUARD FIRED: this
    ///         harness deploys with BOTH fallbacks at address(0), so neither rejection branch
    ///         was reachable and the test proved nothing.
    ///
    ///         The fallbacks are immutable constructor params, so there is no way to add them
    ///         to an existing deployment. The only honest fix is a fresh contract configured
    ///         WITH them, bootstrapped to ACTIVE because proposeFeedChange is ACTIVE-only.
    ///         vcSeed is 0 here, which disables SmartEarn entirely and lets both seed cap
    ///         params be 0 as well; none of that is relevant to the feed guard under test.
    function test_FeedChange_RejectsTheFallbackFeeds() public {
        MockAggregator reserveMock = new MockAggregator(8, ETH_PRICE);
        MockAggregator wethMock    = new MockAggregator(8, ETH_PRICE);

        bulls = new BullsEth(
            bulls.USDC(),
            address(ethFeed),          // reuse the fixture's primary mock
            address(reserveMock),
            address(wethMock),
            BASE_PREDICTION,
            bulls.SEQUENCER_FEED(),
            bulls.PROTOCOL_BENEFICIARY(),
            0,                         // vcSeed: SmartEarn disabled
            address(0),                // vcSeedReturnAddress: inert at vcSeed 0
            0,                         // maxSeedReleaseRatioBps: inert at vcSeed 0
            0                          // maxSeedPerDrawBps: inert at vcSeed 0
        );

        // Bootstrap to ACTIVE by hand rather than via the seeded helper, since seedPot()
        // reverts BelowMinimum on a vcSeed-0 deployment.
        _bootstrapCommitted(MIN_PLAYERS_TO_START);
        bulls.proposeStartGame();
        vm.warp(block.timestamp + START_GAME_NOTICE_PERIOD + 1);
        ethFeed.pushRound(ETH_PRICE);
        bulls.startGame();

        // Preconditions: both fallbacks are genuinely configured on THIS deployment, so the
        // two assertions below cannot pass vacuously the way the original did.
        assertEq(bulls.ethReserveFeed(), address(reserveMock), "reserve fallback is live");
        assertEq(bulls.wethFeed(), address(wethMock), "weth fallback is live");

        vm.expectRevert(IBullsEthCRE.FeedUnchanged.selector);
        bulls.proposeFeedChange(address(reserveMock));

        vm.expectRevert(IBullsEthCRE.FeedUnchanged.selector);
        bulls.proposeFeedChange(address(wethMock));
    }

    /// @notice A codeless address is still rejected, just NOT with the typed error. Named for
    ///         what it actually proves rather than what the code reads like.
    ///
    /// @dev    Calling decimals() on an address with no code fails the compiler's extcodesize
    ///         check, which reverts RAW with empty returndata before the call is made, so
    ///         Solidity's try/catch never sees it. A bare vm.expectRevert() with no selector
    ///         is the correct expectation. Operationally: an EMPTY revert on a rejected
    ///         proposal means "not a contract"; a typed FeedDecimalsMismatch means "a contract
    ///         reporting the wrong decimals". Two separate readings of this code have assumed
    ///         the typed error, so it is worth pinning both cases side by side.
    function test_FeedChange_RejectsACodelessAddressWithARawRevert() public {
        _bootstrapAndStart();
        vm.expectRevert();
        bulls.proposeFeedChange(address(0xDEAD));
    }

    /// @notice THE REAL DECIMALS GUARD. A feed reporting anything other than 8 decimals is
    ///         rejected, because every price path in the contract assumes 8 and a 6-decimal
    ///         feed would silently misprice every settlement by 100x.
    ///
    /// @dev    An earlier version of this test pointed at a CODELESS address and expected
    ///         FeedDecimalsMismatch, on the reasoning that decimals() would fail and the
    ///         try/catch would convert it. Execution disproved that: calling a function on
    ///         an address with no code fails the compiler's extcodesize check, which reverts
    ///         RAW with empty returndata BEFORE the call is made, and Solidity's try/catch
    ///         does not catch that. The revert is real but untyped.
    ///
    ///         So a codeless address IS rejected, just not with a named error. Worth knowing
    ///         when reading a failed proposal on-chain: an empty revert means "not a
    ///         contract", a typed FeedDecimalsMismatch means "a contract with wrong decimals".
    ///         This test now exercises the guard that actually produces the typed error.
    function test_FeedChange_RejectsWrongDecimals() public {
        _bootstrapAndStart();
        MockAggregator sixDecimalFeed = new MockAggregator(6, ETH_PRICE);
        vm.expectRevert(IBullsEthCRE.FeedDecimalsMismatch.selector);
        bulls.proposeFeedChange(address(sixDecimalFeed));
    }

    /// @notice Propose stores the pending change against TIMELOCK_DELAY, its own constant.
    function test_FeedChange_ProposeSetsPendingAndSevenDayTimelock() public {
        _bootstrapAndStart();
        MockAggregator newFeed = new MockAggregator(8, ETH_PRICE);

        bulls.proposeFeedChange(address(newFeed));

        (address pendingFeed, uint256 effectiveTime) = bulls.pendingEthFeedChange();
        assertEq(pendingFeed, address(newFeed), "pending feed recorded");
        assertEq(
            effectiveTime,
            block.timestamp + TIMELOCK_DELAY,
            "7 days, not the 48-hour prize-rate lock"
        );
        assertTrue(bulls.ethFeed() != address(newFeed), "and the live feed has NOT moved yet");
    }

    function test_FeedChange_RevertsWhenAlreadyPending() public {
        _bootstrapAndStart();
        MockAggregator feedA = new MockAggregator(8, ETH_PRICE);
        MockAggregator feedB = new MockAggregator(8, ETH_PRICE);

        bulls.proposeFeedChange(address(feedA));
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.proposeFeedChange(address(feedB));
    }

    function test_FeedChange_ExecuteRevertsBeforeTheTimelockElapses() public {
        _bootstrapAndStart();
        MockAggregator newFeed = new MockAggregator(8, ETH_PRICE);
        bulls.proposeFeedChange(address(newFeed));

        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.executeFeedChange();
    }

    function test_FeedChange_ExecuteRevertsWithNothingPending() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.executeFeedChange();
    }

    /// @notice THE HAPPY PATH, and it does more than swap an address. Executing also zeroes
    ///         lastValidPrice and autoDefaultCents, because both were derived from the OLD
    ///         feed and carrying them across would let a stale reading from a feed the
    ///         contract no longer trusts seed the next draw's fallback.
    function test_FeedChange_ExecuteSwapsTheFeedAndClearsDerivedState() public {
        _bootstrapAndStart();
        // TWO draws, not one. autoDefaultCents is populated at resolution from the PREVIOUS
        // draw's resolvedPrice, so after a single draw it is still 0 and the "cleared to 0"
        // assertion below would already have been true before the execute -- semi-vacuous.
        // A second draw gives it a real value, so both preconditions now earn their asserts.
        _runStandardDraw();
        _runStandardDraw();
        assertTrue(bulls.lastValidPrice() != 0, "precondition: a price is cached");
        assertTrue(bulls.autoDefaultCents() != 0, "precondition: an auto-default is cached");

        MockAggregator newFeed = new MockAggregator(8, ETH_PRICE);
        address oldFeed = bulls.ethFeed();
        bulls.proposeFeedChange(address(newFeed));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        bulls.executeFeedChange();

        assertEq(bulls.ethFeed(), address(newFeed), "live feed swapped");
        assertTrue(bulls.ethFeed() != oldFeed, "and it is genuinely a different address");
        assertEq(bulls.lastValidPrice(), 0, "cached price cleared: it came from the old feed");
        assertEq(bulls.autoDefaultCents(), 0, "auto-default cleared for the same reason");

        (address pendingAfter, uint256 timeAfter) = bulls.pendingEthFeedChange();
        assertEq(pendingAfter, address(0), "pending cleared");
        assertEq(timeAfter, 0, "timelock cleared");
    }

    /// @notice Decimals are re-validated AT EXECUTE, not just at propose. A feed can be
    ///         upgraded behind its address during the 7-day window, so re-checking is what
    ///         stops a feed that was 8 decimals at proposal time going live at 6.
    function test_FeedChange_ExecuteRevalidatesDecimals() public {
        _bootstrapAndStart();
        MockAggregator shifty = new MockAggregator(8, ETH_PRICE);
        bulls.proposeFeedChange(address(shifty));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Simulate the feed changing its reported decimals mid-window.
        vm.mockCall(
            address(shifty),
            abi.encodeWithSignature("decimals()"),
            abi.encode(uint8(6))
        );

        vm.expectRevert(IBullsEthCRE.FeedDecimalsMismatch.selector);
        bulls.executeFeedChange();
        vm.clearMockedCalls();
    }

    function test_FeedChange_CancelClearsAndAllowsReProposal() public {
        _bootstrapAndStart();
        MockAggregator newFeed = new MockAggregator(8, ETH_PRICE);
        bulls.proposeFeedChange(address(newFeed));
        bulls.cancelFeedChange();

        (address pendingFeed, uint256 effectiveTime) = bulls.pendingEthFeedChange();
        assertEq(pendingFeed, address(0), "cleared");
        assertEq(effectiveTime, 0, "timelock cleared");

        bulls.proposeFeedChange(address(newFeed));
        (address reProposed,) = bulls.pendingEthFeedChange();
        assertEq(reProposed, address(newFeed), "re-proposable after cancel");
    }

    function test_FeedChange_CancelRevertsWithNothingPending() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.cancelFeedChange();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Seed release ratio: propose / execute / cancel  (SEED_RATIO_TIMELOCK)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice This is the dial that governs how much investor seed can be released into
    ///         prizes across a season, so its bounds are the ones protecting the VC.
    function test_SeedRatio_ProposeSetsPendingAndSevenDayTimelock() public {
        _bootstrapAndStart();
        uint256 target = bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2;
        assertGt(target, 0, "precondition: this fixture has a non-zero ratio cap");

        bulls.proposeSeedReleaseRatio(target);

        assertEq(bulls.pendingSeedReleaseRatioBps(), target, "pending set");
        assertEq(
            bulls.seedReleaseRatioEffectiveTime(),
            block.timestamp + SEED_RATIO_TIMELOCK,
            "SEED_RATIO_TIMELOCK, its own constant, not TIMELOCK_DELAY by coincidence"
        );
    }

    function test_SeedRatio_RevertsForNonOwner() public {
        _bootstrapAndStart();
        address stranger = _newFundedPlayer(80002);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.proposeSeedReleaseRatio(100);
    }

    function test_SeedRatio_RevertsOutsideActive() public {
        _bootstrapCommitted(10);
        vm.expectRevert(IBullsEthCRE.WrongPhase.selector);
        bulls.proposeSeedReleaseRatio(100);
    }

    /// @notice THE BOUND THAT MATTERS. MAX_SEED_RELEASE_RATIO_BPS is an immutable set at
    ///         deploy, and the constructor's solvency proof depends on governance never
    ///         exceeding it: the VC's spent-seed return is only guaranteed fundable from
    ///         treasury while the ratio stays under that cap. Governance must not be able
    ///         to raise it past the figure the deployment was proven against.
    function test_SeedRatio_CannotExceedTheImmutableCap() public {
        _bootstrapAndStart();
        uint256 cap = bulls.MAX_SEED_RELEASE_RATIO_BPS();
        assertGt(cap, 0, "precondition: a seeded game must have a non-zero cap");

        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeSeedReleaseRatio(cap + 1);

        // And the cap itself is permitted, so the rejection above is the boundary and not
        // an off-by-one that also blocks the legal maximum.
        bulls.proposeSeedReleaseRatio(cap);
        assertEq(bulls.pendingSeedReleaseRatioBps(), cap, "the cap itself is allowed");
    }

    function test_SeedRatio_CannotExceedOneHundredPercent() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.ExceedsLimit.selector);
        bulls.proposeSeedReleaseRatio(10001);
    }

    function test_SeedRatio_RevertsWhenAlreadyPending() public {
        _bootstrapAndStart();
        uint256 target = bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2;
        bulls.proposeSeedReleaseRatio(target);
        vm.expectRevert(IBullsEthCRE.TimelockPending.selector);
        bulls.proposeSeedReleaseRatio(target - 1);
    }

    /// @notice Both propose and execute are gated on IDLE, not just ACTIVE. Changing the
    ///         seed dial mid-draw would move the release ceiling underneath a distribution
    ///         that has already been priced against the old one.
    function test_SeedRatio_RevertsMidDraw() public {
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned(); // now CUTOFF_SUBMISSION, not IDLE

        // Read FIRST. Third time this footgun has landed in this project, and this file
        // documents it twice already (test_FeedChange_RejectsUsdc, and the BreathEngine
        // wogTickets fix). vm.expectRevert attaches to the NEXT external call; a getter in
        // the argument position IS that call, so it consumes the expectation and the real
        // revert then arrives unwatched. Rule: contract reads go on their own line.
        uint256 halfCap = bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2;
        vm.expectRevert(IBullsEthCRE.DrawInProgress.selector);
        bulls.proposeSeedReleaseRatio(halfCap);
    }

    function test_SeedRatio_ExecuteRevertsBeforeTheTimelockElapses() public {
        _bootstrapAndStart();
        uint256 target = bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2;
        bulls.proposeSeedReleaseRatio(target);
        vm.warp(block.timestamp + SEED_RATIO_TIMELOCK - 1);
        vm.expectRevert(IBullsEthCRE.TooEarly.selector);
        bulls.executeSeedReleaseRatio();
    }

    function test_SeedRatio_ExecuteRevertsWithNothingPending() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.executeSeedReleaseRatio();
    }

    function test_SeedRatio_ExecuteAppliesTheNewRatio() public {
        _bootstrapAndStart();
        uint256 before = bulls.seedReleaseRatioBps();
        uint256 target = bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2;
        assertTrue(target != before, "precondition: the target is genuinely a change");

        bulls.proposeSeedReleaseRatio(target);
        vm.warp(block.timestamp + SEED_RATIO_TIMELOCK + 1);
        bulls.executeSeedReleaseRatio();

        assertEq(bulls.seedReleaseRatioBps(), target, "applied");
        assertEq(bulls.pendingSeedReleaseRatioBps(), 0, "pending cleared");
        assertEq(bulls.seedReleaseRatioEffectiveTime(), 0, "timelock cleared");
    }

    function test_SeedRatio_CancelClearsAndAllowsReProposal() public {
        _bootstrapAndStart();
        uint256 target = bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2;
        bulls.proposeSeedReleaseRatio(target);
        bulls.cancelSeedReleaseRatio();

        assertEq(bulls.pendingSeedReleaseRatioBps(), 0, "cleared");
        assertEq(bulls.seedReleaseRatioEffectiveTime(), 0, "timelock cleared");

        // Re-proposable, so cancel genuinely releases the slot rather than burning it.
        bulls.proposeSeedReleaseRatio(target);
        assertEq(bulls.pendingSeedReleaseRatioBps(), target, "re-proposable after cancel");
    }

    function test_SeedRatio_CancelRevertsWithNothingPending() public {
        _bootstrapAndStart();
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.cancelSeedReleaseRatio();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Ownership: two-step transfer with a 7-day EXPIRY
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Ownership here is not a timelock in the propose/wait/execute sense. It is
    ///         two-step with an EXPIRY: the current owner nominates, the nominee must accept
    ///         WITHIN the window, and the offer dies if they do not. That protects against
    ///         handing ownership to an address that turns out to be uncontrolled, because
    ///         an unclaimed offer lapses instead of sitting open forever.
    function test_Ownership_TransferSetsAnExpiryWindow() public {
        address newOwner = _newFundedPlayer(80010);
        bulls.transferOwnership(newOwner);

        assertEq(
            bulls.ownershipTransferExpiry(),
            block.timestamp + OWNERSHIP_TRANSFER_EXPIRY,
            "expiry set 7 days out"
        );
        assertEq(bulls.pendingOwner(), newOwner, "nominee recorded");
        assertEq(bulls.owner(), address(this), "but ownership has NOT moved yet");
    }

    function test_Ownership_TransferRejectsTheZeroAddress() public {
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.transferOwnership(address(0));
    }

    function test_Ownership_TransferRevertsForNonOwner() public {
        address stranger = _newFundedPlayer(80011);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.transferOwnership(stranger);
    }

    function test_Ownership_NomineeCanAcceptInsideTheWindow() public {
        address newOwner = _newFundedPlayer(80012);
        bulls.transferOwnership(newOwner);

        vm.warp(block.timestamp + OWNERSHIP_TRANSFER_EXPIRY - 1);
        vm.prank(newOwner);
        bulls.acceptOwnership();

        assertEq(bulls.owner(), newOwner, "ownership moved");
        assertEq(bulls.ownershipTransferExpiry(), 0, "expiry cleared on acceptance");
    }

    /// @notice THE EXPIRY ITSELF. Past the window the offer is dead, and the nominee cannot
    ///         resurrect it: only a fresh transferOwnership can.
    function test_Ownership_AcceptanceExpiresAfterSevenDays() public {
        address newOwner = _newFundedPlayer(80013);
        bulls.transferOwnership(newOwner);

        vm.warp(block.timestamp + OWNERSHIP_TRANSFER_EXPIRY + 1);
        vm.prank(newOwner);
        vm.expectRevert(IBullsEthCRE.OwnershipTransferExpired.selector);
        bulls.acceptOwnership();

        assertEq(bulls.owner(), address(this), "ownership stayed put");
    }

    function test_Ownership_AcceptRevertsWithNoOfferOutstanding() public {
        address stranger = _newFundedPlayer(80014);
        vm.prank(stranger);
        vm.expectRevert(IBullsEthCRE.NoTimelockPending.selector);
        bulls.acceptOwnership();
    }

    /// @notice Only the NOMINEE can accept. A stranger inside the window is refused by
    ///         OpenZeppelin's own Ownable2Step guard, which fires before this contract's
    ///         expiry logic is reached.
    function test_Ownership_AcceptRevertsForANonNominee() public {
        address newOwner = _newFundedPlayer(80015);
        address stranger = _newFundedPlayer(80016);
        bulls.transferOwnership(newOwner);

        vm.prank(stranger);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        bulls.acceptOwnership();

        assertEq(bulls.owner(), address(this), "ownership stayed put");
        assertEq(bulls.pendingOwner(), newOwner, "and the real nominee is still nominated");
    }

    /// @notice Nominating a second address REPLACES the first offer and RESETS the expiry.
    ///         So a change of mind does not leave two live offers, and the new nominee gets
    ///         a full window rather than the remainder of someone else's.
    function test_Ownership_ReNominationReplacesTheOfferAndResetsTheWindow() public {
        address firstPick  = _newFundedPlayer(80017);
        address secondPick = _newFundedPlayer(80018);

        bulls.transferOwnership(firstPick);
        uint256 firstExpiry = bulls.ownershipTransferExpiry();

        // Let part of the first window elapse, so a reset is distinguishable from a no-op.
        vm.warp(block.timestamp + 2 days);
        bulls.transferOwnership(secondPick);

        assertEq(bulls.pendingOwner(), secondPick, "the second nomination replaced the first");
        assertGt(bulls.ownershipTransferExpiry(), firstExpiry, "and the window was reset, not inherited");
        assertEq(
            bulls.ownershipTransferExpiry(),
            block.timestamp + OWNERSHIP_TRANSFER_EXPIRY,
            "a full fresh window from now"
        );

        // The displaced nominee can no longer accept.
        vm.prank(firstPick);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        bulls.acceptOwnership();
    }

    /// @notice Renouncing is disabled outright. An ownerless game cannot run its keeper
    ///         paths, cannot settle, and cannot wind down, so the ability to renounce is a
    ///         way to strand everyone's funds with a single transaction.
    function test_Ownership_RenounceIsDisabled() public {
        vm.expectRevert(IBullsEthCRE.RenounceOwnershipDisabled.selector);
        bulls.renounceOwnership();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Cross-cancellation: one action clears every other pending proposal
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Sets up as many independent pending proposals as one PREGAME-to-ACTIVE fixture
    ///      allows, so the sweep tests below have something real to clear.
    function _queueSeveralProposals() internal {
        uint256 lowerBreath = bulls.breathMultiplier() > 300 ? bulls.breathMultiplier() - 50 : 150;
        bulls.proposeBreathOverride(lowerBreath, bytes32("queued override"));
        bulls.proposeExhaleFloorRelease(15000);
        bulls.proposeSeedReleaseRatio(bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2);

        assertGt(bulls.pendingBreathOverride(), 0, "override queued");
        assertGt(bulls.pendingExhaleFloorReleaseTime(), 0, "exhale floor queued");
        assertGt(bulls.seedReleaseRatioEffectiveTime(), 0, "seed ratio queued");
    }

    /// @notice proposeDormancy sweeps EVERY pending governance proposal, including the seed
    ///         release ratio. The reasoning is that a game heading for shutdown should not
    ///         carry queued parameter changes that would execute into a wind-down, and a
    ///         proposal left pending into DORMANT is orphaned state nobody can action.
    function test_CrossCancel_ProposeDormancyClearsEveryPendingProposal() public {
        _bootstrapAndStart();
        _queueSeveralProposals();

        bulls.proposeDormancy();

        assertEq(bulls.pendingBreathOverride(), 0, "breath override cancelled");
        assertEq(bulls.pendingExhaleFloorReleaseTime(), 0, "exhale floor cancelled");
        assertEq(bulls.seedReleaseRatioEffectiveTime(), 0, "seed release ratio cancelled");
        assertGt(bulls.dormancyEffectiveTime(), 0, "and dormancy itself is now queued");
    }

    /// @notice THE DELIBERATE ASYMMETRY, and the reason this test exists separately.
    ///         emergencyResetDraw sweeps the same proposals EXCEPT the seed release ratio.
    ///         A reset resumes ACTIVE play, so a queued ratio change is still meaningful and
    ///         is left alone; a dormancy ends the season, so it is not. The contract states
    ///         this explicitly and it is the kind of intentional inconsistency a future
    ///         reader would otherwise "tidy up" into a bug.
    function test_CrossCancel_EmergencyResetSparesTheSeedRatioButClearsTheRest() public {
        _bootstrapAndStart();
        _queueSeveralProposals();

        // Get the draw stuck so a reset is legal: resolve, then never submit cutoffs.
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        _resolvePinned();
        vm.warp(block.timestamp + DRAW_STUCK_TIMEOUT + 1);

        bulls.emergencyResetDraw();

        assertEq(bulls.pendingBreathOverride(), 0, "breath override cancelled by the reset");
        assertEq(bulls.pendingExhaleFloorReleaseTime(), 0, "exhale floor cancelled by the reset");
        assertGt(
            bulls.seedReleaseRatioEffectiveTime(),
            0,
            "seed release ratio SURVIVES: a reset resumes ACTIVE, so the proposal is still live"
        );
    }

    /// @notice A cancelled proposal must be re-proposable afterwards. Otherwise the sweep
    ///         would permanently burn the slot and governance would be stuck.
    function test_CrossCancel_SweptProposalsCanBeQueuedAgain() public {
        _bootstrapAndStart();
        _queueSeveralProposals();
        bulls.proposeDormancy();
        bulls.cancelDormancy();

        // Everything the sweep cleared is proposable once more.
        bulls.proposeExhaleFloorRelease(15000);
        assertGt(bulls.pendingExhaleFloorReleaseTime(), 0, "exhale floor re-queued");

        bulls.proposeSeedReleaseRatio(bulls.MAX_SEED_RELEASE_RATIO_BPS() / 2);
        assertGt(bulls.seedReleaseRatioEffectiveTime(), 0, "seed ratio re-queued");
    }
}
