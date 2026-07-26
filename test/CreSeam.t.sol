// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "./BullsEthBase.t.sol";
import {BullsEth} from "../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../src/IBullsEthCRE.sol";

/// @notice CRE seam (Option B onReport dispatch) behaviour.
contract CreSeamTest is BullsEthBase {
    // Local copy of the event for expectEmit.
    event CreReportProcessed(uint8 indexed action, uint256 indexed draw);

    // Action codes (mirror the contract constants).
    uint8 constant SUBMIT_CUTOFFS = 1;
    uint8 constant ADVANCE = 2;
    uint8 constant AUTO_PICKS = 3;
    uint8 constant PRUNE = 4;
    uint8 constant CLOSE_GAME = 5;
    uint8 constant RESOLVE_WEEK = 6;

    address forwarder = makeAddr("keystoneForwarder");

    function test_SetCreForwarder_OnlyOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        // setCreForwarder uses OpenZeppelin 4.9's onlyOwner modifier, which reverts with a
        // string (not the contract's own OwnableUnauthorizedAccount, which the manual auth
        // checks like onReport use).
        vm.expectRevert("Ownable: caller is not the owner");
        bulls.setCreForwarder(forwarder);
    }

    function test_SetCreForwarder_Blocklist() public {
        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(address(bulls));

        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(address(usdc));

        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(beneficiary);

        vm.expectRevert(IBullsEthCRE.InvalidAddress.selector);
        bulls.setCreForwarder(address(sequencer));
    }

    function test_SetCreForwarder_Sets() public {
        bulls.setCreForwarder(forwarder);
        assertEq(bulls.creForwarder(), forwarder);
    }

    function test_OnReport_RevertWhenForwarderUnset() public {
        // creForwarder defaults to address(0): every delivery must revert.
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, anyone));
        bulls.onReport("", abi.encode(ADVANCE, bytes("")));
    }

    function test_OnReport_RevertWhenCallerNotForwarder() public {
        bulls.setCreForwarder(forwarder);
        address notForwarder = makeAddr("notForwarder");
        vm.prank(notForwarder);
        vm.expectRevert(abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, notForwarder));
        bulls.onReport("", abi.encode(ADVANCE, bytes("")));
    }

    function test_OnReport_UnknownActionReverts() public {
        bulls.setCreForwarder(forwarder);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(IBullsEthCRE.UnknownAction.selector, uint8(99)));
        bulls.onReport("", abi.encode(uint8(99), bytes("")));
    }

    function test_OnReport_AdvanceRevertsInPregame() public {
        bulls.setCreForwarder(forwarder);
        vm.prank(forwarder);
        vm.expectRevert(IBullsEthCRE.GameNotActive.selector);
        bulls.onReport("", abi.encode(ADVANCE, bytes("")));
    }

    function test_OnReport_PruneNoOpSucceedsInPregame() public {
        bulls.setCreForwarder(forwarder);
        // drawPhase is IDLE and ogList is empty in pregame, so prune is a clean no-op.
        vm.expectEmit(true, true, false, false, address(bulls));
        emit CreReportProcessed(PRUNE, 0);
        vm.prank(forwarder);
        bulls.onReport("", abi.encode(PRUNE, abi.encode(uint256(1))));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  M-01: a CRE resolve report MUST carry a roundId (no spot fallback)
    // ══════════════════════════════════════════════════════════════════════
    // Before v1.17, ACTION_RESOLVE_WEEK with a payload under 32 bytes fell through to a
    // spot read via _resolveWeekCore, with no RESOLVE_FALLBACK_DELAY. That reintroduced
    // the caller-picks-the-instant optionality C-01 removed, behind the forwarder. The
    // spot path now belongs only to the restricted, delayed no-arg resolveWeek().
    function test_M01_CreResolveWithEmptyPayloadReverts() public {
        bulls.setCreForwarder(forwarder);
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        ethFeed.pushRound(ETH_PRICE);

        uint8 RESOLVE = 6; // ACTION_RESOLVE_WEEK
        // Empty inner payload: under 32 bytes, so the pinned decode cannot run.
        vm.prank(forwarder);
        vm.expectRevert(IBullsEthCRE.NotEnoughValidPrices.selector);
        bulls.onReport("", abi.encode(RESOLVE, bytes("")));
    }

    function test_M01_CreResolveWithRoundIdSettles() public {
        bulls.setCreForwarder(forwarder);
        _bootstrapAndStart();
        _buyAllPlayers(1);
        _warpToCooldownEnd();
        uint80 rid = ethFeed.pushRound(ETH_PRICE);

        // A well-formed CRE resolve carries the roundId as its payload.
        vm.prank(forwarder);
        bulls.onReport("", abi.encode(uint8(6), abi.encode(rid)));

        assertEq(bulls.getResolvedPrice(), ETH_PRICE, "M-01: pinned CRE settlement works");
        assertEq(
            uint256(bulls.drawPhase()),
            uint256(IBullsEthCRE.DrawPhase.CUTOFF_SUBMISSION),
            "M-01: draw advanced via the pinned CRE path"
        );
    }
}