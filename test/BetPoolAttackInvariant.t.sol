// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";
import {BetPoolAttackHandler} from "./helpers/BetPoolAttackHandler.sol";

/// @notice Random sequences of honest calls and attacks. The pool must always hold what it owes,
///         never pay out more than was staked, keep finished markets final, and pay strangers nothing.
contract BetPoolAttackInvariantTest is BetPoolTestBase {
    BetPoolAttackHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BetPoolAttackHandler(pool);
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.place.selector;
        selectors[2] = handler.place.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.expire.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.replayLastTicket.selector;
        selectors[8] = handler.stealTicket.selector;
        selectors[9] = handler.forgedTicket.selector;
        selectors[10] = handler.forgedSettle.selector;
        selectors[11] = handler.resettle.selector;
        selectors[12] = handler.strangerClaims.selector;
        selectors[13] = handler.strangerAdmin.selector;
        selectors[14] = handler.settleOutsideWindow.selector;
        selectors[15] = handler.betAfterClose.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_poolHoldsWhatItOwesAndNeverOverpays() public view {
        uint256 heldImd;
        uint256 heldShift;
        for (uint256 i; i < handler.count(); ++i) {
            BetPoolAttackHandler.Ghost memory g = handler.ghost(i);
            uint256 balance = pool.marketBalance(g.id);
            assertLe(g.paid + g.fee, g.a + g.b, "market paid out more than was staked");
            assertEq(balance, g.a + g.b - g.fee - g.paid, "market ledger drifted");
            uint256 owed;
            for (uint256 j; j < 4; ++j) {
                owed += pool.claimable(g.id, handler.actors(j));
            }
            assertLe(owed, balance, "outstanding claims exceed the market's funds");
            if (g.token == IMD) heldImd += balance;
            else heldShift += balance;
        }
        assertEq(imd.balanceOf(address(pool)), heldImd, "IMD held != owed");
        assertEq(shift.balanceOf(address(pool)), heldShift, "SHIFT held != owed");
        assertEq(imd.balanceOf(SPLITTER), handler.fees(IMD));
        assertEq(shift.balanceOf(SPLITTER), handler.fees(SHIFT));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_finishedMarketsStayFinalAndStrangersGetNothing() public view {
        for (uint256 i; i < handler.count(); ++i) {
            BetPoolAttackHandler.Ghost memory g = handler.ghost(i);
            BetPool.Market memory m = _marketState(g.id);
            assertEq(m.totalA, g.a);
            assertEq(m.totalB, g.b);
            assertEq(m.settled, g.settled);
            assertEq(m.outcome, g.outcome);
            assertEq(m.refundable, g.refundable);
            assertEq(pool.claimable(g.id, handler.attacker()), 0);
            for (uint256 j; j < 4; ++j) {
                assertEq(_position(g.id, handler.actors(j)).claimed, g.claimed[j]);
            }
        }
        assertEq(imd.balanceOf(handler.attacker()), 0);
        assertEq(shift.balanceOf(handler.attacker()), 0);
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(shift.balanceOf(OWNER), 0);
        assertEq(pool.signer(), vm.addr(TEST_SIGNER_KEY));
    }
}
