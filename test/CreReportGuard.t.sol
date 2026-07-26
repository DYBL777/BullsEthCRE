// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "./BullsEthBase.t.sol";
import {BullsEth} from "../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../src/IBullsEthCRE.sol";
import {CreReportGuard} from "../src/CreReportGuard.sol";

/// @notice C-02. The guard that makes BullsEthCRE's `msg.sender == creForwarder` check
///         mean something, by putting a contract we control in that slot instead of the
///         chain's shared KeystoneForwarder.
///
///         Tests both modes: RECORD, which learns the real envelope without exposing the
///         game, and ENFORCE, which validates it.
contract CreReportGuardTest is BullsEthBase {
    CreReportGuard internal guard;

    address internal chainlinkForwarder;   // stands in for the shared KeystoneForwarder
    address internal stranger;             // someone else's workflow, same forwarder

    // A plausible envelope. The real layout is whatever RECORD mode observes; the point of
    // the offset-based rules is that this contract never needs to know what the fields are.
    bytes internal OUR_META;
    bytes internal THEIR_META;

    function setUp() public virtual override {
        super.setUp();

        chainlinkForwarder = makeAddr("keystoneForwarder");
        stranger = makeAddr("strangerWorkflow");

        guard = new CreReportGuard();
        guard.setForwarder(chainlinkForwarder);
        guard.setTarget(address(bulls));

        // The game now trusts the guard, not the shared forwarder.
        bulls.setCreForwarder(address(guard));

        // 32 bytes of workflow id, then a 20-byte owner address, then a per-run field.
        OUR_META = abi.encodePacked(
            bytes32(uint256(0xC0FFEE)),          // offset 0,  len 32: workflow id
            bytes20(uint160(0xA11CE)),           // offset 32, len 20: workflow owner
            bytes32(uint256(1))                  // offset 52, len 32: execution id, varies
        );
        THEIR_META = abi.encodePacked(
            bytes32(uint256(0xBADBAD)),
            bytes20(uint160(0xB0B)),
            bytes32(uint256(1))
        );
    }

    /// @dev A prune report is a safe no-op in PREGAME, so it exercises the full relay path
    ///      without needing a live game. Mirrors the existing CreSeam test.
    function _pruneReport() internal pure returns (bytes memory) {
        return abi.encode(uint8(4), abi.encode(uint256(0))); // ACTION_PRUNE
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Access control
    // ══════════════════════════════════════════════════════════════════════

    function test_OnlyTheForwarderCanCall() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CreReportGuard.NotForwarder.selector, stranger));
        guard.onReport(OUR_META, _pruneReport());
    }

    function test_ZeroingTheForwarderIsAKillSwitch() public {
        guard.setForwarder(address(0));
        vm.prank(chainlinkForwarder);
        vm.expectRevert(CreReportGuard.ForwarderNotSet.selector);
        guard.onReport(OUR_META, _pruneReport());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  RECORD mode: learn the envelope without exposing the game
    // ══════════════════════════════════════════════════════════════════════

    function test_RecordMode_StoresMetadataAndDoesNotForwardByDefault() public {
        assertEq(uint256(guard.mode()), uint256(CreReportGuard.Mode.RECORD), "RECORD is the default");
        assertFalse(guard.forwardWhileRecording(), "and it does not relay by default");

        vm.prank(chainlinkForwarder);
        guard.onReport(OUR_META, _pruneReport());

        assertEq(guard.lastMetadata(), OUR_META, "the real envelope is now readable on-chain");
        assertEq(guard.reportCount(), 1);

        // The game was never touched. This is what makes RECORD safe to run anywhere.
        assertEq(bulls.creForwarder(), address(guard), "wiring is live");
    }

    function test_RecordMode_RecordsEvenAStrangersEnvelope() public {
        // The whole point: in RECORD mode you find out what actually arrives, including
        // from workflows that are not yours.
        vm.prank(chainlinkForwarder);
        guard.onReport(THEIR_META, _pruneReport());
        assertEq(guard.lastMetadata(), THEIR_META);
    }

    function test_RecordMode_CanRelayWhenExplicitlyEnabled() public {
        guard.setForwardWhileRecording(true);
        vm.prank(chainlinkForwarder);
        guard.onReport(OUR_META, _pruneReport()); // reaches the game, no revert
        assertEq(guard.reportCount(), 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Configuring rules from what RECORD observed
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The workflow this is meant to support: read the blob, derive slice hashes from
    ///      it, add rules, dry-run them, then switch to ENFORCE.
    function _pinOurWorkflow() internal {
        bytes32 idHash    = guard.sliceHash(OUR_META, 0, 32);  // workflow id
        bytes32 ownerHash = guard.sliceHash(OUR_META, 32, 20); // workflow owner
        guard.addRule(0, 32, idHash, "workflowId");
        guard.addRule(32, 20, ownerHash, "workflowOwner");
    }

    function test_WouldPass_LetsYouCheckRulesBeforeCommitting() public {
        _pinOurWorkflow();

        (bool okOurs,) = guard.wouldPass(OUR_META);
        assertTrue(okOurs, "our envelope passes");

        (bool okTheirs, uint256 failing) = guard.wouldPass(THEIR_META);
        assertFalse(okTheirs, "a stranger's does not");
        assertEq(failing, 0, "and it tells you which rule caught it");
    }

    /// @dev The per-run field must NOT be pinned, or every execution after the first fails.
    ///      Recording it as its own test so nobody pins it by accident later.
    function test_PerRunFieldsMustNotBePinned() public {
        _pinOurWorkflow();

        bytes memory secondRun = abi.encodePacked(
            bytes32(uint256(0xC0FFEE)),
            bytes20(uint160(0xA11CE)),
            bytes32(uint256(2))        // execution id has moved on
        );
        (bool ok,) = guard.wouldPass(secondRun);
        assertTrue(ok, "identity fields pinned, per-run field left alone");

        // Whereas pinning the whole blob would break on run two.
        guard.setExpectedMetadataHash(keccak256(OUR_META));
        (bool okWhole,) = guard.wouldPass(secondRun);
        assertFalse(okWhole, "whole-blob pinning only works for a constant envelope");
    }

    function test_CannotSwitchToEnforceWithNothingToEnforce() public {
        vm.expectRevert(CreReportGuard.NoRulesConfigured.selector);
        guard.setMode(CreReportGuard.Mode.ENFORCE);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ENFORCE mode: this is C-02 closed
    // ══════════════════════════════════════════════════════════════════════

    function test_EnforceMode_OurWorkflowIsRelayed() public {
        _pinOurWorkflow();
        guard.setMode(CreReportGuard.Mode.ENFORCE);

        vm.prank(chainlinkForwarder);
        guard.onReport(OUR_META, _pruneReport());
        assertEq(guard.reportCount(), 1, "relayed");
    }

    /// @notice THE FINDING. Same forwarder, same report, different workflow. Before the
    ///         guard this reached submitCutoffDiffs, closeGame and resolveWeek.
    function test_EnforceMode_AStrangersWorkflowIsRejected() public {
        _pinOurWorkflow();
        guard.setMode(CreReportGuard.Mode.ENFORCE);

        // Compute expectations BEFORE the prank: vm.prank applies to the very next call,
        // and a view call here would swallow it.
        bytes32 theirs = guard.sliceHash(THEIR_META, 0, 32);
        bytes32 ours   = guard.sliceHash(OUR_META, 0, 32);

        vm.prank(chainlinkForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(CreReportGuard.RuleFailed.selector, 0, theirs, ours)
        );
        guard.onReport(THEIR_META, _pruneReport());
    }

    function test_EnforceMode_RejectsAShortEnvelope() public {
        _pinOurWorkflow();
        guard.setMode(CreReportGuard.Mode.ENFORCE);

        bytes memory truncated = abi.encodePacked(bytes16(0));
        vm.prank(chainlinkForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(CreReportGuard.RuleOutOfBounds.selector, 0, 32, 16)
        );
        guard.onReport(truncated, _pruneReport());
    }

    function test_EnforceMode_WholeBlobPinningAlsoWorks() public {
        guard.setExpectedMetadataHash(keccak256(OUR_META));
        guard.setMode(CreReportGuard.Mode.ENFORCE);

        vm.prank(chainlinkForwarder);
        guard.onReport(OUR_META, _pruneReport());

        vm.prank(chainlinkForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreReportGuard.MetadataHashMismatch.selector,
                keccak256(THEIR_META),
                keccak256(OUR_META)
            )
        );
        guard.onReport(THEIR_META, _pruneReport());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Integration: the game only ever hears from the guard
    // ══════════════════════════════════════════════════════════════════════

    function test_TheGameRejectsEveryoneExceptTheGuard() public {
        // The shared forwarder can no longer reach the game directly, which is the whole
        // arrangement: BullsEthCRE trusts one address, and that address is ours.
        vm.prank(chainlinkForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, chainlinkForwarder)
        );
        bulls.onReport(OUR_META, _pruneReport());

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IBullsEthCRE.OwnableUnauthorizedAccount.selector, stranger)
        );
        bulls.onReport(OUR_META, _pruneReport());
    }

    function test_OnlyOwnerCanConfigure() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        guard.setForwarder(stranger);
        vm.expectRevert();
        guard.setTarget(stranger);
        vm.expectRevert();
        guard.addRule(0, 32, bytes32(0), "x");
        vm.expectRevert();
        guard.setForwardWhileRecording(true);
        vm.stopPrank();
    }

    function test_RenounceOwnershipIsDisabled() public {
        vm.expectRevert(CreReportGuard.RenounceOwnershipDisabled.selector);
        guard.renounceOwnership();
    }
}
