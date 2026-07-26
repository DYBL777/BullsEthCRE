// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BullsEthBase} from "./BullsEthBase.t.sol";
import {BullsEth} from "../src/BullsEthCRE.sol";
import {IBullsEthCRE} from "../src/IBullsEthCRE.sol";

/// @notice Pregame registration and commitment flow.
contract PregameTest is BullsEthBase {
    function test_Register() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();
        (bool registered,,,,,,,,,,,,,) = bulls.getPlayerInfo(p);
        assertTrue(registered);
    }

    function test_Register_RevertOnDouble() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.register();
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.AlreadyRegistered.selector);
        bulls.register();
    }

    function test_PayCommitment_RevertIfNotRegistered() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        vm.expectRevert(IBullsEthCRE.NotRegistered.selector);
        bulls.payCommitment(BASE_PREDICTION);
    }

    function test_PayCommitment_Accounting() public {
        uint256 potBefore = bulls.prizePot();
        uint256 treasuryBefore = bulls.treasuryBalance();

        address p = _newFundedPlayer(1);
        _commit(p, BASE_PREDICTION);

        assertEq(bulls.committedPlayerCount(), 1);
        // $10 ticket: 25% treasury ($2.50), 75% to the pot ($7.50).
        uint256 expectedTreasury = TICKET_PRICE * TREASURY_BPS / 10000;
        assertEq(bulls.treasuryBalance() - treasuryBefore, expectedTreasury);
        assertEq(bulls.prizePot() - potBefore, TICKET_PRICE - expectedTreasury);
    }

    function test_RegisterAsUpfrontOG() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 1);
        assertEq(bulls.upfrontOGCount(), 1);
    }

    function test_CancelUpfrontOG_DecrementsCount() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.registerAsOG(BASE_PREDICTION, BASE_PREDICTION + 1);
        assertEq(bulls.upfrontOGCount(), 1);

        vm.prank(p);
        bulls.cancelOGRegistration();
        assertEq(bulls.upfrontOGCount(), 0);
    }

    function test_RegisterAsWeeklyOG() public {
        address p = _newFundedPlayer(1);
        vm.prank(p);
        bulls.registerAsWeeklyOG(BASE_PREDICTION, BASE_PREDICTION + 1);
        assertEq(bulls.weeklyOGCount(), 1);
    }
}
