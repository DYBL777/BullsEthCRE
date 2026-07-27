// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "../base/BullsEthBase.t.sol";
import {BullsEth} from "../../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../../src/IBullsEthCRE.sol";

/// @notice Deployment and genesis-state invariants.
contract DeployTest is BullsEthBase {
    function test_Deploy_Version() public view {
        // [v1.12] Version string is deliberately still v1.11b: changing it would alter bytecode
        // and destroy the comment-only identity proof. Update when a code change lands.
        assertEq(bulls.getContractVersion(), "BullsEthCRE_v1.17");
    }

    function test_Deploy_OwnerIsDeployer() public view {
        assertEq(bulls.owner(), address(this));
    }

    function test_Deploy_InitialPhases() public view {
        assertEq(uint256(bulls.gamePhase()), uint256(IBullsEthCRE.GamePhase.PREGAME));
        assertEq(uint256(bulls.drawPhase()), uint256(IBullsEthCRE.DrawPhase.IDLE));
        assertEq(bulls.currentDraw(), 0);
    }

    function test_Deploy_ForwardersUnset() public view {
        assertEq(bulls.creForwarder(), address(0));
        assertEq(bulls.automationForwarder(), address(0));
    }

    function test_Deploy_SolventAtGenesis() public view {
        (,, bool isSolvent) = bulls.getSolvencyStatus();
        assertTrue(isSolvent);
    }
}
