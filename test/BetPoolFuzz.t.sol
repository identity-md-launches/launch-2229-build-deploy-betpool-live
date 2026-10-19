// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, MockToken} from "./helpers/BetPoolTestBase.sol";

contract BetPoolFuzzTest is BetPoolTestBase {
    struct ExpectedPosition {
        address bettor;
        uint256 a;
        uint256 b;
        uint256 sa;
        uint256 sb;
    }

    function testFuzz_payoutsFollowWeightedSharesAndConserveBothTokens(
        uint128[8] memory amountSeeds,
        uint16[8] memory weightSeeds,
        bool isShift,
        uint8 outcomeSeed,
        bool oneSided,
        bool reverse
    ) public {
        address token = isShift ? SHIFT : IMD;
        uint8 outcome = uint8(bound(outcomeSeed, 0, 2));
        (uint256 min, uint256 max) = pool.limits(token);
        _create(ID, token);
        ExpectedPosition[8] memory positions;
        uint256 totalA;
        uint256 totalB;
        uint256 sharesA;
        uint256 sharesB;
        for (uint256 i; i < positions.length; ++i) {
            ExpectedPosition memory p;
            p.bettor = address(uint160(0x1000 + i));
            p.a = bound(amountSeeds[i], min, max);
            uint16 wa = uint16(bound(weightSeeds[i], 500, 10_000));
            p.sa = p.a * wa / 10_000;
            _place(ID, p.bettor, 0, p.a, wa);
            if (!oneSided) {
                p.b = bound(uint256(keccak256(abi.encode(amountSeeds[i], i))), min, max);
                uint16 wb = uint16(bound(uint256(weightSeeds[i]) * 13, 500, 10_000));
                p.sb = p.b * wb / 10_000;
                _place(ID, p.bettor, 1, p.b, wb);
            }
            totalA += p.a;
            totalB += p.b;
            sharesA += p.sa;
            sharesB += p.sb;
            positions[i] = p;
        }
        // Different weights on successive bets must be added, never averaged before rounding.
        _place(ID, positions[0].bettor, 0, min, 501);
        positions[0].a += min;
        positions[0].sa += min * 501 / 10_000;
        totalA += min;
        sharesA += min * 501 / 10_000;
        assertEq(_marketState(ID).totalA, totalA);
        assertEq(_marketState(ID).totalB, totalB);
        assertEq(_marketState(ID).sharesA, sharesA);
        assertEq(_marketState(ID).sharesB, sharesB);
        bool refundable = outcome == 2 || oneSided;
        uint256 losing = outcome == 0 ? totalB : totalA;
        uint256 fee = refundable ? 0 : losing * 5 / 100;
        _settle(ID, outcome);
        assertEq(MockToken(token).balanceOf(SPLITTER), fee);
        uint256 paid;
        for (uint256 n; n < positions.length; ++n) {
            uint256 i = reverse ? positions.length - n - 1 : n;
            ExpectedPosition memory p = positions[i];
            uint256 expected;
            if (refundable) {
                expected = p.a + p.b;
            } else {
                uint256 principal = outcome == 0 ? p.a : p.b;
                uint256 shares = outcome == 0 ? p.sa : p.sb;
                uint256 totalShares = outcome == 0 ? sharesA : sharesB;
                expected = principal + (losing - fee) * shares / totalShares;
            }
            assertEq(pool.claimable(ID, p.bettor), expected);
            uint256 balanceBefore = pool.marketBalance(ID);
            assertLe(expected, balanceBefore);
            assertEq(_claim(ID, p.bettor), expected);
            assertEq(MockToken(token).balanceOf(p.bettor), expected);
            assertEq(pool.marketBalance(ID), balanceBefore - expected);
            paid += expected;
        }
        uint256 dust = MockToken(token).balanceOf(address(pool));
        assertEq(paid + fee + dust, totalA + totalB);
        assertEq(pool.marketBalance(ID), dust);
        if (refundable) assertEq(dust, 0);
        else assertLt(dust, positions.length);
    }

    function testFuzz_limitsWithinHardCapsNeverOverflowShares(
        bool isShift,
        uint128 amountSeed,
        uint16 weightSeed,
        bool sideB
    ) public {
        address token = isShift ? SHIFT : IMD;
        uint256 cap = isShift ? 500_000_000 ether : 10_000 ether;
        vm.prank(OWNER);
        pool.setLimits(token, 20, cap);
        uint256 amount = bound(amountSeed, 20, cap);
        uint16 weight = uint16(bound(weightSeed, 500, 10_000));
        uint8 side = sideB ? 1 : 0;
        _create(ID, token);
        _place(ID, alice, side, amount, weight);
        _place(ID, bob, 1 - side, cap, 10_000);
        assertEq(sideB ? _position(ID, alice).sharesB : _position(ID, alice).sharesA, amount * weight / 10_000);
        _settle(ID, side);
        assertEq(_claim(ID, alice), amount + cap - cap * 5 / 100);
        assertEq(MockToken(token).balanceOf(address(pool)), 0);
    }
}
