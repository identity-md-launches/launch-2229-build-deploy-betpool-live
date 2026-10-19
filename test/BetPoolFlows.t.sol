// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";

contract BetPoolFlowsTest is BetPoolTestBase {
    function test_constructorDefaultsAndUnconfiguredSigner() public {
        BetPool fresh = new BetPool();
        assertEq(fresh.owner(), OWNER);
        assertTrue(fresh.owner() != address(this));
        assertEq(fresh.signer(), address(0));
        assertFalse(fresh.paused());
        assertEq(fresh.IMD(), IMD);
        assertEq(fresh.SHIFT(), SHIFT);
        assertEq(fresh.FEE_SPLITTER(), SPLITTER);
        (uint256 min, uint256 max) = fresh.limits(IMD);
        assertEq(min, 0.1 ether);
        assertEq(max, 500 ether);
        (min, max) = fresh.limits(SHIFT);
        assertEq(min, 1_000 ether);
        assertEq(max, 25_000_000 ether);
        assertEq(fresh.IMD_HARD_CAP(), 10_000 ether);
        assertEq(fresh.SHIFT_HARD_CAP(), 500_000_000 ether);
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(BetPool.SignerNotConfigured.selector);
        fresh.createMarket(ID, IMD, close, GAME, "");
    }

    function test_fullWeightedFlowIMD_AWins() public {
        _fullFlow(IMD, 0);
    }

    function test_fullWeightedFlowIMD_BWins() public {
        _fullFlow(IMD, 1);
    }

    function test_fullWeightedFlowSHIFT_AWins() public {
        _fullFlow(SHIFT, 0);
    }

    function test_fullWeightedFlowSHIFT_BWins() public {
        _fullFlow(SHIFT, 1);
    }

    function _fullFlow(address token, uint8 outcome) internal {
        _create(ID, token);
        (uint256 min, uint256 max) = pool.limits(token);
        address[4] memory bettors = [alice, bob, carol, dave];
        uint256[4] memory amountsA = [min, max, min + 43, max - 19];
        uint256[4] memory amountsB = [max, min + 21, max - 7, min];
        uint16[4] memory weightsA = [uint16(500), 10_000, 2_345, 7_531];
        uint16[4] memory weightsB = [uint16(10_000), 500, 8_007, 1_101];
        for (uint256 i; i < bettors.length; ++i) {
            _place(ID, bettors[i], 0, amountsA[i], weightsA[i]);
            _place(ID, bettors[i], 1, amountsB[i], weightsB[i]);
        }
        // Repeat a bet on the same side: aggregation must precede payout rounding.
        _place(ID, alice, 0, min + 3, 9_999);
        BetPool.Market memory m = _marketState(ID);
        assertEq(m.token, token);
        assertEq(m.game, GAME);
        assertFalse(m.settled);
        assertEq(m.totalA, amountsA[0] + amountsA[1] + amountsA[2] + amountsA[3] + min + 3);
        assertEq(m.totalB, amountsB[0] + amountsB[1] + amountsB[2] + amountsB[3]);
        uint256 totalSharesA;
        uint256 totalSharesB;
        for (uint256 i; i < bettors.length; ++i) {
            totalSharesA += amountsA[i] * weightsA[i] / 10_000;
            totalSharesB += amountsB[i] * weightsB[i] / 10_000;
        }
        totalSharesA += (min + 3) * 9_999 / 10_000;
        assertEq(m.sharesA, totalSharesA);
        assertEq(m.sharesB, totalSharesB);
        assertEq(pool.claimable(ID, alice), 0);

        uint256 pot = m.totalA + m.totalB;
        uint256 losingTotal = outcome == 0 ? m.totalB : m.totalA;
        uint256 fee = losingTotal * 5 / 100;
        uint256 winningShares = outcome == 0 ? totalSharesA : totalSharesB;
        _settle(ID, outcome);
        assertEq(MockToken(token).balanceOf(SPLITTER), fee);
        assertEq(pool.marketBalance(ID), pot - fee);
        uint256 paid;
        for (uint256 i; i < bettors.length; ++i) {
            uint256 principal = outcome == 0 ? amountsA[i] : amountsB[i];
            uint256 shares = outcome == 0 ? amountsA[i] * weightsA[i] / 10_000 : amountsB[i] * weightsB[i] / 10_000;
            if (i == 0 && outcome == 0) {
                principal += min + 3;
                shares += (min + 3) * 9_999 / 10_000;
            }
            uint256 expected = principal + (losingTotal - fee) * shares / winningShares;
            assertEq(pool.claimable(ID, bettors[i]), expected);
            // Reverse claim order is covered by the fuzz suite.
            assertEq(_claim(ID, bettors[i]), expected);
            assertEq(MockToken(token).balanceOf(bettors[i]), expected);
            assertEq(pool.claimable(ID, bettors[i]), 0);
            assertTrue(_position(ID, bettors[i]).claimed);
            paid += expected;
        }
        uint256 dust = pot - fee - paid;
        assertLt(dust, bettors.length);
        assertEq(MockToken(token).balanceOf(address(pool)), dust);
        assertEq(pool.marketBalance(ID), dust);
    }

    function test_exactPayoutsAndFeeForSimpleWeights() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 100 ether, 10_000);
        _place(ID, bob, 0, 100 ether, 5_000);
        _place(ID, carol, 1, 300 ether, 8_000);
        _settle(ID, 0);
        assertEq(imd.balanceOf(SPLITTER), 15 ether);
        assertEq(_claim(ID, alice), 290 ether);
        assertEq(_claim(ID, bob), 195 ether);
        assertEq(_claim(ID, carol), 0);
        assertEq(imd.balanceOf(address(pool)), 0);
        assertEq(pool.marketBalance(ID), 0);
    }

    function test_oddLosingAmountRoundsFeeDownAndOnlyBonusCreatesDust() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 10_000);
        _place(ID, bob, 0, 1 ether, 10_000);
        uint256 losing = 1 ether + 19;
        _place(ID, carol, 1, losing, 500);
        _settle(ID, 0);
        uint256 fee = losing * 500 / 10_000;
        assertEq(imd.balanceOf(SPLITTER), 0.05 ether);
        uint256 each = 1 ether + (losing - fee) / 2;
        assertEq(_claim(ID, bob), each);
        assertEq(_claim(ID, alice), each);
        assertEq(imd.balanceOf(address(pool)), 1);
        assertEq(pool.marketBalance(ID), 1);
    }

    function test_voidRefundsBothSidesIMD() public {
        _voidRefund(IMD);
    }

    function test_voidRefundsBothSidesSHIFT() public {
        _voidRefund(SHIFT);
    }

    function _voidRefund(address token) internal {
        (uint256 min,) = pool.limits(token);
        _create(ID, token);
        _place(ID, alice, 0, min, 500);
        _place(ID, alice, 1, min + 17, 1_231);
        _place(ID, bob, 1, min + 99, 10_000);
        _settle(ID, 2);
        assertTrue(_marketState(ID).refundable);
        assertEq(_claim(ID, alice), min * 2 + 17);
        assertEq(_claim(ID, bob), min + 99);
        assertEq(MockToken(token).balanceOf(SPLITTER), 0);
        assertEq(MockToken(token).balanceOf(address(pool)), 0);
    }

    function test_oneSidedWinningSideRefunded() public {
        _oneSided(0);
    }

    function test_oneSidedLosingSideRefunded() public {
        _oneSided(1);
    }

    function test_oneSidedVoidRefunded() public {
        _oneSided(2);
    }

    function _oneSided(uint8 outcome) internal {
        _create(ID, IMD);
        _place(ID, alice, 0, 17 ether + 3, 500);
        _place(ID, bob, 0, 29 ether + 1, 9_999);
        _settle(ID, outcome);
        assertTrue(_marketState(ID).refundable);
        assertEq(_claim(ID, alice), 17 ether + 3);
        assertEq(_claim(ID, bob), 29 ether + 1);
        assertEq(imd.balanceOf(SPLITTER), 0);
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_oneSidedBRefundedEvenWhenAIsDeclaredWinner() public {
        _create(ID, SHIFT);
        _place(ID, alice, 1, 1_000 ether + 1, 500);
        _settle(ID, 0);
        assertEq(_claim(ID, alice), 1_000 ether + 1);
        assertEq(shift.balanceOf(SPLITTER), 0);
    }

    function test_emptyMarketCanSettleAllOutcomes() public {
        for (uint8 outcome; outcome < 3; ++outcome) {
            bytes32 id = bytes32(uint256(outcome));
            _create(id, IMD);
            _settle(id, outcome);
            assertTrue(_marketState(id).refundable);
            assertEq(_claim(id, alice), 0);
        }
    }

    function test_expiryAtBoundaryRefundsAndFinalizes() public {
        _create(ID, SHIFT);
        _place(ID, alice, 0, 1_000 ether + 7, 501);
        _place(ID, alice, 1, 3_000 ether + 1, 10_000);
        _place(ID, bob, 1, 9_000 ether, 5_003);
        uint256 expiry = uint256(_marketState(ID).closesAt) + 24 hours;
        vm.warp(expiry - 1);
        vm.expectRevert(BetPool.TooEarlyToExpire.selector);
        pool.expire(ID);
        vm.warp(expiry);
        vm.prank(dave);
        pool.expire(ID);
        BetPool.Market memory m = _marketState(ID);
        assertTrue(m.settled);
        assertTrue(m.refundable);
        assertEq(m.outcome, 2);
        assertEq(_claim(ID, alice), 4_000 ether + 8);
        assertEq(_claim(ID, bob), 9_000 ether);
        assertEq(shift.balanceOf(SPLITTER), 0);
        assertEq(shift.balanceOf(address(pool)), 0);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.expire(ID);
    }

    function test_expireEmptyMarket() public {
        _create(ID, IMD);
        vm.warp(uint256(_marketState(ID).closesAt) + 24 hours + 1);
        pool.expire(ID);
        assertEq(pool.claimable(ID, alice), 0);
        assertTrue(_marketState(ID).refundable);
    }

    function test_claimManyMixesTokensAndLosingClaims() public {
        _create(ID, IMD);
        _create(ID2, SHIFT);
        bytes32 third = keccak256("third");
        _create(third, IMD);
        _place(ID, alice, 0, 7 ether, 500);
        _place(ID2, alice, 1, 8_000 ether, 9_999);
        _place(third, alice, 1, 3 ether, 500);
        _place(third, bob, 0, 5 ether, 10_000);
        _settle(ID, 0);
        _settle(ID2, 2);
        _settle(third, 0);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = ID;
        ids[1] = ID2;
        ids[2] = third;
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(alice), 7 ether);
        assertEq(shift.balanceOf(alice), 8_000 ether);
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(_position(ids[i], alice).claimed);
        }
        pool.claimMany(new bytes32[](0));
    }

    function test_claimManyDuplicateRollsBackEntireBatch() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 2 ether, 500);
        _settle(ID, 2);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID;
        ids[1] = ID;
        vm.prank(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claimMany(ids);
        assertFalse(_position(ID, alice).claimed);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(pool.marketBalance(ID), 2 ether);
        assertEq(_claim(ID, alice), 2 ether);
    }

    function test_claimManyUnknownOrUnsettledRollsBack() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 2 ether, 500);
        _settle(ID, 2);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID;
        ids[1] = ID2;
        vm.prank(alice);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.claimMany(ids);
        _create(ID2, SHIFT);
        vm.prank(alice);
        vm.expectRevert(BetPool.MarketNotSettled.selector);
        pool.claimMany(ids);
        assertFalse(_position(ID, alice).claimed);
        assertEq(imd.balanceOf(alice), 0);
    }

    function test_losersAndNonBettorsReceiveNothingAndCannotClaimTwice() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 3 ether, 500);
        _place(ID, bob, 1, 7 ether, 10_000);
        _settle(ID, 0);
        assertEq(_claim(ID, bob), 0);
        assertEq(_claim(ID, carol), 0);
        assertEq(imd.balanceOf(bob), 0);
        vm.prank(bob);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claim(ID);
        uint256 paid = _claim(ID, alice);
        assertEq(paid, 9.65 ether);
        vm.prank(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claim(ID);
    }

    function test_marketPotsAreIndependentAndDonationsDoNotChangePayouts() public {
        _create(ID, IMD);
        _create(ID2, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 2 ether, 5_001);
        _place(ID2, carol, 0, 500 ether, 10_000);
        imd.mint(address(pool), 11 ether);
        _settle(ID, 0);
        assertEq(_claim(ID, alice), 2.9 ether);
        assertEq(pool.marketBalance(ID), 0);
        assertEq(pool.marketBalance(ID2), 500 ether);
        assertEq(imd.balanceOf(address(pool)), 511 ether);
        _settle(ID2, 2);
        assertEq(_claim(ID2, carol), 500 ether);
        assertEq(imd.balanceOf(address(pool)), 11 ether);
    }
}
