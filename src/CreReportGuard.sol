// SPDX-License-Identifier: BUSL-1.1
// Change Date: 24 February 2030. On the Change Date, available under MIT.

pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IReportReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/**
 * @title  CreReportGuard
 * @notice A small dedicated receiver that sits between the Chainlink CRE forwarder and
 *         BullsEthCRE, and answers the one question BullsEthCRE cannot: did this report
 *         come from OUR workflow?
 *
 * @dev    THE PROBLEM THIS SOLVES (audit finding C-02).
 *         BullsEthCRE.onReport() checks `msg.sender == creForwarder` and discards the
 *         `metadata` argument. That check is only meaningful if `creForwarder` is an
 *         address only we can cause to call. The chain-level KeystoneForwarder is NOT
 *         that: it is a shared singleton, and any party can register a workflow that
 *         targets an arbitrary receiver. Pointing `creForwarder` straight at it means
 *         a stranger's workflow can reach submitCutoffDiffs, closeGame and resolveWeek.
 *
 *         THE FIX. Deploy this contract, point BullsEthCRE's `creForwarder` at it, and
 *         point this contract's `target` at BullsEthCRE. The forwarder now talks to us,
 *         we verify the workflow, and only then do we call the game. BullsEthCRE's
 *         existing check becomes true by construction: `creForwarder` is now an address
 *         only our verified workflow can cause to call.
 *
 *         WHY A SEPARATE CONTRACT RATHER THAN EDITING THE GAME.
 *         1. BullsEthCRE is already ~46,000 bytes over the EIP-170 limit. This adds none.
 *         2. If Chainlink changes the report envelope, redeploy 200 lines, not 70,000.
 *         3. This can be tested on its own in seconds.
 *
 *         WHY IT DOES NOT NEED THE SPEC UP FRONT.
 *         The exact layout of `metadata` has changed between Keystone revisions, and a
 *         decoder written against the wrong layout is worse than none because it looks
 *         like protection. So this contract starts in RECORD mode: it stores and emits
 *         the raw bytes it actually receives. Run your workflow once on a testnet, read
 *         the real bytes back, configure rules against them, then switch to ENFORCE.
 *         Verification by observation rather than by documentation.
 *
 *         Rules are offset-based rather than field-based, so this contract never needs to
 *         know what the fields MEAN. It asserts that the bytes at a given position hash to
 *         a given value. That works for any envelope layout, present or future.
 */
contract CreReportGuard is Ownable2Step {
    // ── Errors ───────────────────────────────────────────────────────────────
    error NotForwarder(address caller);
    error TargetNotSet();
    error ForwarderNotSet();
    error InvalidAddress();
    error MetadataTooShort(uint256 got, uint256 required);
    error MetadataHashMismatch(bytes32 got, bytes32 expected);
    error RuleFailed(uint256 ruleIndex, bytes32 got, bytes32 expected);
    error RuleOutOfBounds(uint256 ruleIndex, uint256 end, uint256 metadataLength);
    error NoRulesConfigured();
    error RecordingDoesNotForward();
    error RenounceOwnershipDisabled();

    // ── Types ────────────────────────────────────────────────────────────────

    /// @notice RECORD learns the envelope. ENFORCE validates it.
    enum Mode { RECORD, ENFORCE }

    /// @notice "the bytes at [offset, offset+length) must hash to `expected`".
    /// @dev    Offset-based on purpose. This contract does not need to know whether the
    ///         slice is a workflow owner, a workflow name or a DON id. You learn the
    ///         positions from RECORD mode and pin whichever ones identify your workflow.
    struct MetaRule {
        uint16  offset;
        uint16  length;
        bytes32 expected; // keccak256 of the expected slice
        string  label;    // human note, e.g. "workflowOwner"
    }

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice The Chainlink CRE forwarder permitted to call onReport(). address(0)
    ///         disables this contract entirely, mirroring the game's kill switch.
    address public forwarder;

    /// @notice The contract reports are relayed to, normally BullsEthCRE.
    address public target;

    Mode public mode; // defaults to RECORD

    /// @notice Whether RECORD mode also relays. Defaults to FALSE, which is the safe
    ///         setting: while learning the envelope, nothing reaches the game. Set true
    ///         only on a testnet, where you want the full path exercised end to end.
    bool public forwardWhileRecording;

    /// @notice Optional whole-envelope pin. Zero disables it. Only useful if metadata is
    ///         byte-identical across executions; if it carries a per-run field such as an
    ///         execution id, use rules instead.
    bytes32 public expectedMetadataHash;

    /// @notice Optional minimum length. Zero disables.
    uint16 public minMetadataLength;

    MetaRule[] private _rules;

    /// @notice Most recent metadata seen, for on-chain inspection after a RECORD run.
    bytes public lastMetadata;
    uint256 public reportCount;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice The point of RECORD mode. Read this log to learn the real envelope.
    event MetadataRecorded(uint256 indexed index, bytes32 indexed metadataHash, uint256 length, bytes metadata);
    event ReportRelayed(uint256 indexed index, address indexed to, uint256 reportLength);
    event ReportNotRelayed(uint256 indexed index, string reason);
    event ForwarderSet(address indexed forwarder);
    event TargetSet(address indexed target);
    event ModeSet(Mode mode);
    event ForwardWhileRecordingSet(bool enabled);
    event ExpectedMetadataHashSet(bytes32 expectedHash);
    event MinMetadataLengthSet(uint16 minLength);
    event RuleAdded(uint256 indexed index, uint16 offset, uint16 length, bytes32 expected, string label);
    event RulesCleared(uint256 count);

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @dev Matches BullsEthCRE's hardened ownership: renouncing is permanently disabled,
    ///      so this contract can never become unconfigurable.
    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function setForwarder(address _forwarder) external onlyOwner {
        if (_forwarder == address(this)) revert InvalidAddress();
        // address(0) intentionally allowed: it disables relaying, the kill switch.
        forwarder = _forwarder;
        emit ForwarderSet(_forwarder);
    }

    function setTarget(address _target) external onlyOwner {
        if (_target == address(this)) revert InvalidAddress();
        target = _target;
        emit TargetSet(_target);
    }

    /// @dev Guards against the obvious footgun: switching to ENFORCE with nothing to
    ///      enforce would look like protection and be none, which is the exact failure
    ///      this contract exists to prevent.
    function setMode(Mode _mode) external onlyOwner {
        if (_mode == Mode.ENFORCE && _rules.length == 0 && expectedMetadataHash == bytes32(0)) {
            revert NoRulesConfigured();
        }
        mode = _mode;
        emit ModeSet(_mode);
    }

    function setForwardWhileRecording(bool enabled) external onlyOwner {
        forwardWhileRecording = enabled;
        emit ForwardWhileRecordingSet(enabled);
    }

    function setExpectedMetadataHash(bytes32 h) external onlyOwner {
        expectedMetadataHash = h;
        emit ExpectedMetadataHashSet(h);
    }

    function setMinMetadataLength(uint16 n) external onlyOwner {
        minMetadataLength = n;
        emit MinMetadataLengthSet(n);
    }

    /// @param offset   Byte position in metadata where the identifying slice starts.
    /// @param length   Slice length in bytes.
    /// @param expected keccak256 of the slice you observed in RECORD mode.
    /// @param label    Human note so a future reader knows what this pins.
    function addRule(uint16 offset, uint16 length, bytes32 expected, string calldata label)
        external onlyOwner
    {
        _rules.push(MetaRule({offset: offset, length: length, expected: expected, label: label}));
        emit RuleAdded(_rules.length - 1, offset, length, expected, label);
    }

    function clearRules() external onlyOwner {
        uint256 n = _rules.length;
        delete _rules;
        emit RulesCleared(n);
    }

    function ruleCount() external view returns (uint256) { return _rules.length; }

    function getRule(uint256 i)
        external view
        returns (uint16 offset, uint16 length, bytes32 expected, string memory label)
    {
        MetaRule storage r = _rules[i];
        return (r.offset, r.length, r.expected, r.label);
    }

    // ── The hot path ─────────────────────────────────────────────────────────

    /// @notice Called by the CRE forwarder. Verifies the envelope, then relays.
    /// @dev    No reentrancy guard here on purpose: this contract holds no funds and no
    ///         state a reentrant call could corrupt beyond an incremented counter. The
    ///         target (BullsEthCRE.onReport) carries its own nonReentrant.
    function onReport(bytes calldata metadata, bytes calldata report) external {
        if (forwarder == address(0)) revert ForwarderNotSet();
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);

        uint256 index = reportCount;
        reportCount = index + 1;

        if (mode == Mode.RECORD) {
            lastMetadata = metadata;
            emit MetadataRecorded(index, keccak256(metadata), metadata.length, metadata);
            if (!forwardWhileRecording) {
                emit ReportNotRelayed(index, "RECORD mode, forwarding disabled");
                return;
            }
        } else {
            _verify(metadata);
        }

        if (target == address(0)) revert TargetNotSet();
        emit ReportRelayed(index, target, report.length);
        IReportReceiver(target).onReport(metadata, report);
    }

    /// @dev Reverts with the specific reason so a failure is diagnosable rather than a
    ///      bare revert. Cheap: this path only runs on a real report.
    function _verify(bytes calldata metadata) internal view {
        if (minMetadataLength != 0 && metadata.length < minMetadataLength) {
            revert MetadataTooShort(metadata.length, minMetadataLength);
        }
        if (expectedMetadataHash != bytes32(0)) {
            bytes32 h = keccak256(metadata);
            if (h != expectedMetadataHash) revert MetadataHashMismatch(h, expectedMetadataHash);
        }
        uint256 n = _rules.length;
        for (uint256 i = 0; i < n; i++) {
            MetaRule storage r = _rules[i];
            uint256 end = uint256(r.offset) + uint256(r.length);
            if (end > metadata.length) revert RuleOutOfBounds(i, end, metadata.length);
            bytes32 got = keccak256(metadata[r.offset:end]);
            if (got != r.expected) revert RuleFailed(i, got, r.expected);
        }
    }

    // ── Configuration helpers ────────────────────────────────────────────────

    /// @notice Dry-run the current configuration against a metadata blob WITHOUT sending
    ///         a transaction. Use this after RECORD mode to confirm your rules pass on the
    ///         real envelope before switching to ENFORCE. Getting that wrong locks the
    ///         game's CRE path until you notice, so check first.
    /// @return ok            True if the blob would be accepted.
    /// @return failingRule   Index of the first failing rule, or type(uint256).max if the
    ///                       failure was the length check or the whole-blob hash.
    function wouldPass(bytes calldata metadata) external view returns (bool ok, uint256 failingRule) {
        if (minMetadataLength != 0 && metadata.length < minMetadataLength) {
            return (false, type(uint256).max);
        }
        if (expectedMetadataHash != bytes32(0) && keccak256(metadata) != expectedMetadataHash) {
            return (false, type(uint256).max);
        }
        uint256 n = _rules.length;
        for (uint256 i = 0; i < n; i++) {
            MetaRule storage r = _rules[i];
            uint256 end = uint256(r.offset) + uint256(r.length);
            if (end > metadata.length) return (false, i);
            if (keccak256(metadata[r.offset:end]) != r.expected) return (false, i);
        }
        return (true, 0);
    }

    /// @notice Convenience for building a rule from an observed blob: returns the hash of
    ///         the slice at [offset, offset+length). Read a blob from the MetadataRecorded
    ///         log, call this, and pass the result to addRule.
    function sliceHash(bytes calldata metadata, uint16 offset, uint16 length)
        external pure returns (bytes32)
    {
        uint256 end = uint256(offset) + uint256(length);
        require(end <= metadata.length, "slice out of bounds");
        return keccak256(metadata[offset:end]);
    }
}
