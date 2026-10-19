// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";
import {BetPoolHandler} from "./helpers/BetPoolHandler.sol";

contract BetPoolInvariantTest is BetPoolTestBase {
    BetPoolHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BetPoolHandler(pool, TEST_SIGNER_KEY);
        // Every campaign starts with meaningful liabilities in both tokens, on both sides.
        for (uint256 i; i < 4; ++i) {
            uint256 stake = i % 2 == 0 ? 10 ether : 1_000_000 ether;
            handler.place(i, 0, stake, 10_000, false);
            handler.place(i, 1, stake, 5_000, false);
            handler.place(i, 2, stake, 4_000, true);
            handler.place(i, 0, stake, 500, true);
        }
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.place.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.expire.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.claimMany.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.togglePause.selector;
        selectors[8] = handler.adjustLimits.selector;
        selectors[9] = handler.rotateSigner.selector;
        selectors[10] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_marketStateAndEveryClaimMatchIndependentModel() public view {
        uint256 count = handler.count();
        for (uint256 i; i < count; ++i) {
            BetPoolHandler.Model memory expected = handler.snapshot(i);
            BetPool.Market memory actual = _marketState(expected.id);
            assertEq(actual.token, expected.token);
            assertEq(actual.closesAt, expected.close);
            assertEq(actual.totalA, expected.a);
            assertEq(actual.totalB, expected.b);
            assertEq(actual.sharesA, expected.sa);
            assertEq(actual.sharesB, expected.sb);
            assertEq(actual.settled, expected.settled);
            assertEq(actual.outcome, expected.outcome);
            assertEq(actual.refundable, expected.refundable);
            uint256 owed;
            for (uint256 j; j < 6; ++j) {
                address actor = handler.actors(j);
                BetPool.Bet memory position = _position(expected.id, actor);
                BetPoolHandler.Position memory p = expected.positions[j];
                assertEq(position.amountA, p.a);
                assertEq(position.amountB, p.b);
                assertEq(position.sharesA, p.sa);
                assertEq(position.sharesB, p.sb);
                assertEq(position.claimed, p.claimed);
                uint256 claim = handler.expected(i, j);
                assertEq(pool.claimable(expected.id, actor), claim);
                owed += claim;
            }
            uint256 remaining = expected.a + expected.b - expected.fee - expected.paid;
            assertEq(pool.marketBalance(expected.id), remaining);
            assertLe(owed, remaining, "market owes more than its pot");
            assertLe(expected.paid + expected.fee, expected.a + expected.b, "market paid more than deposits");
        }
    }

    function invariant_actualBalancesCoverAllMarketsAndConserveEveryWei() public view {
        address[2] memory tokens = [IMD, SHIFT];
        for (uint256 t; t < tokens.length; ++t) {
            address token = tokens[t];
            uint256 pots;
            for (uint256 i; i < handler.count(); ++i) {
                BetPoolHandler.Model memory m = handler.snapshot(i);
                if (m.token == token) pots += pool.marketBalance(m.id);
            }
            uint256 balance = MockToken(token).balanceOf(address(pool));
            assertEq(balance, pots + handler.donations(token));
            assertEq(
                balance + handler.totalPaid(token) + handler.totalFees(token),
                handler.totalDeposited(token) + handler.donations(token)
            );
            assertEq(MockToken(token).balanceOf(SPLITTER), handler.totalFees(token));
            for (uint256 a; a < 6; ++a) {
                address actor = handler.actors(a);
                assertEq(MockToken(token).balanceOf(actor), handler.actorPaid(token, actor));
            }
        }
    }

    function invariant_authorityAndNoncesRemainCorrect() public view {
        assertEq(pool.owner(), OWNER);
        assertEq(pool.signer(), vm.addr(handler.signingKey()));
        assertEq(pool.FEE_SPLITTER(), SPLITTER);
        assertEq(pool.FEE_BPS(), 500);
        assertEq(pool.IMD(), IMD);
        assertEq(pool.SHIFT(), SHIFT);
        for (uint256 i = 1; i <= handler.nonceCount(); ++i) {
            assertTrue(pool.usedNonce(bytes32(i)));
        }
        assertFalse(pool.usedNonce(bytes32(handler.nonceCount() + 1)));
    }

    function afterInvariant() public {
        handler.finish();
        invariant_marketStateAndEveryClaimMatchIndependentModel();
        invariant_actualBalancesCoverAllMarketsAndConserveEveryWei();
        for (uint256 i; i < handler.count(); ++i) {
            BetPoolHandler.Model memory m = handler.snapshot(i);
            if (m.refundable) {
                assertEq(pool.marketBalance(m.id), 0, "refunds left funds behind");
            } else {
                uint256 winners;
                for (uint256 j; j < 6; ++j) {
                    if ((m.outcome == 0 ? m.positions[j].a : m.positions[j].b) != 0) ++winners;
                }
                assertLt(pool.marketBalance(m.id), winners, "excessive rounding dust");
            }
        }
    }
}
