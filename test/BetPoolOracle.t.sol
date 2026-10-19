// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Scenarios checked against constants computed by hand (outside Solidity), not against a
///         re-implementation of the payout formula, plus boundary and failure paths at exact edges.
contract BetPoolOracleTest is BetPoolTestBase {
    // ---------------------------------------------------------------------------------------------
    // Hand-computed IMD market: limits 0.1..500, weights 500..10000, alice and bob on both sides.
    // A: alice 0.1 @10000, bob 500 @500, carol 123.456789012345678901 @7777, alice 0.1+1wei @9999
    // B: dave 77.777777777777777777 @9999, bob 500 @10000, alice 3.333333333333333333 @1234
    // ---------------------------------------------------------------------------------------------

    function _imdMarket() internal {
        _create(ID, IMD);
        _place(ID, alice, 0, 0.1 ether, 10_000);
        _place(ID, bob, 0, 500 ether, 500);
        _place(ID, carol, 0, 123_456789012345678901, 7_777);
        _place(ID, alice, 0, 0.1 ether + 1, 9_999);
        _place(ID, dave, 1, 77_777777777777777777, 9_999);
        _place(ID, bob, 1, 500 ether, 10_000);
        _place(ID, alice, 1, 3_333333333333333333, 1_234);
        BetPool.Market memory m = _marketState(ID);
        assertEq(m.totalA, 623_656789012345678902);
        assertEq(m.totalB, 581_111111111111111110);
        assertEq(m.sharesA, 121_212334814901234481);
        assertEq(m.sharesB, 578_181333333333333332);
        assertEq(imd.balanceOf(address(pool)), 623_656789012345678902 + 581_111111111111111110);
    }

    function test_oracleIMD_AWins() public {
        _imdMarket();
        _settle(ID, 0);
        assertEq(imd.balanceOf(SPLITTER), 29_055555555555555555, "fee = floor(5% of B)");
        assertEq(_claim(ID, alice), 1_110844516972235138);
        assertEq(_claim(ID, bob), 613_861257684413612910);
        assertEq(_claim(ID, carol), 560_740242366515386407);
        assertEq(_claim(ID, dave), 0, "loser gets nothing");
        assertEq(imd.balanceOf(dave), 0);
        assertEq(imd.balanceOf(address(pool)), 2, "two winners, two wei dust");
        assertEq(pool.marketBalance(ID), 2);
    }

    function test_oracleIMD_BWins() public {
        _imdMarket();
        _settle(ID, 1);
        assertEq(imd.balanceOf(SPLITTER), 31_182839450617283945, "fee = floor(5% of A)");
        assertEq(_claim(ID, dave), 157_470248635966934019);
        assertEq(_claim(ID, bob), 1012_359977228938898314);
        assertEq(_claim(ID, alice), 3_754834807933673733);
        assertEq(_claim(ID, carol), 0, "loser gets nothing");
        assertEq(imd.balanceOf(address(pool)), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Hand-computed SHIFT market at and between limits 1000..25,000,000; carol and alice on both sides.
    // ---------------------------------------------------------------------------------------------

    function _shiftMarket() internal {
        _create(ID2, SHIFT);
        _place(ID2, alice, 0, 1_000 ether, 10_000);
        _place(ID2, bob, 0, 25_000_000 ether, 500);
        _place(ID2, carol, 0, 1_234_567 ether + 987_654_321, 6_000);
        _place(ID2, dave, 1, 25_000_000 ether, 10_000);
        _place(ID2, carol, 1, 1_000 ether + 1, 501);
        _place(ID2, alice, 1, 7_777_777 ether + 7, 9_000);
        BetPool.Market memory m = _marketState(ID2);
        assertEq(m.totalA, 26_235_567_000000000987654321);
        assertEq(m.totalB, 32_778_777_000000000000000008);
        assertEq(m.sharesA, 1_991_740_200000000592592592);
        assertEq(m.sharesB, 32_000_049_400000000000000006);
    }

    function test_oracleSHIFT_AWins() public {
        _shiftMarket();
        _settle(ID2, 0);
        assertEq(shift.balanceOf(SPLITTER), 1_638_938_850000000000000000);
        assertEq(_claim(ID2, alice), 16_634_487946771366433794);
        assertEq(_claim(ID2, bob), 44_543_109_933464208042242577);
        assertEq(_claim(ID2, carol), 12_815_660_728589021578977957);
        assertEq(_claim(ID2, dave), 0);
        assertEq(shift.balanceOf(address(pool)), 1);
    }

    function test_oracleSHIFT_BWins() public {
        _shiftMarket();
        _settle(ID2, 1);
        assertEq(shift.balanceOf(SPLITTER), 1_311_778_350000000049382716);
        assertEq(_claim(ID2, dave), 44_471_679_823406773348818330);
        assertEq(_claim(ID2, carol), 1_039_021246366107173792);
        assertEq(_claim(ID2, alice), 13_229_846_805346861482279490);
        assertEq(_claim(ID2, bob), 0);
        assertEq(shift.balanceOf(address(pool)), 1);
    }

    function test_oracleBothMarketsVoidRefundExactly() public {
        _imdMarket();
        _shiftMarket();
        _settle(ID, 2);
        _settle(ID2, 2);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID;
        ids[1] = ID2;
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(alice), 0.1 ether + 0.1 ether + 1 + 3_333333333333333333);
        assertEq(shift.balanceOf(alice), 1_000 ether + 7_777_777 ether + 7);
        vm.prank(bob);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(bob), 1_000 ether);
        assertEq(shift.balanceOf(bob), 25_000_000 ether);
        vm.prank(carol);
        pool.claimMany(ids);
        vm.prank(dave);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(address(pool)), 0);
        assertEq(shift.balanceOf(address(pool)), 0);
        assertEq(imd.balanceOf(SPLITTER), 0);
        assertEq(shift.balanceOf(SPLITTER), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee: smallest losing sides, where 5% rounds to zero or one wei.
    // ---------------------------------------------------------------------------------------------

    function test_feeRoundsDownOnOddTinyLosingSide() public {
        vm.prank(OWNER);
        pool.setLimits(IMD, 20, 500 ether);
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 10_000);
        _place(ID, bob, 1, 39, 10_000); // 39 / 20 = 1
        _settle(ID, 0);
        assertEq(imd.balanceOf(SPLITTER), 1);
        assertEq(_claim(ID, alice), 1 ether + 38);
    }

    function test_feeZeroWhenLosingSideBelowTwentyWei() public {
        vm.prank(OWNER);
        pool.setLimits(IMD, 19, 500 ether);
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 10_000);
        _place(ID, bob, 1, 20, 10_000); // shares 20, fee 1
        _settle(ID, 0);
        assertEq(imd.balanceOf(SPLITTER), 1);
        _create(ID2, IMD);
        _place(ID2, alice, 0, 1 ether, 10_000);
        _place(ID2, bob, 1, 19, 10_000); // fee floor(19/20) = 0
        _settle(ID2, 0);
        assertEq(imd.balanceOf(SPLITTER), 1, "no transfer for a zero fee");
        assertEq(_claim(ID2, alice), 1 ether + 19);
    }

    // ---------------------------------------------------------------------------------------------
    // Exact boundaries and failures with otherwise valid signatures.
    // ---------------------------------------------------------------------------------------------

    function _signedTicket(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight, uint64 expiry)
        internal
        returns (bytes32 nonce, bytes memory sig)
    {
        nonce = bytes32(++nonceCounter);
        sig = _sign(_ticketHash(id, bettor, side, amount, weight, expiry, nonce));
    }

    function _tryBet(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight, bytes4 err) internal {
        (address token,,,,,,,,,) = pool.markets(id);
        if (token != address(0)) _fund(token, bettor, amount);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 60);
        (bytes32 nonce, bytes memory sig) = _signedTicket(id, bettor, side, amount, weight, expiry);
        vm.prank(bettor);
        vm.expectRevert(err);
        pool.bet(id, side, amount, weight, expiry, nonce, sig);
        assertFalse(pool.usedNonce(nonce));
    }

    function test_signedButOutOfRangeTicketsRefused() public {
        _create(ID, IMD);
        _create(ID2, SHIFT);
        _tryBet(ID, alice, 0, 0.1 ether - 1, 10_000, BetPool.AmountOutsideLimits.selector);
        _tryBet(ID, alice, 0, 500 ether + 1, 10_000, BetPool.AmountOutsideLimits.selector);
        _tryBet(ID, alice, 0, 0, 10_000, BetPool.AmountOutsideLimits.selector);
        _tryBet(ID2, alice, 1, 1_000 ether - 1, 10_000, BetPool.AmountOutsideLimits.selector);
        _tryBet(ID2, alice, 1, 25_000_000 ether + 1, 10_000, BetPool.AmountOutsideLimits.selector);
        _tryBet(ID, alice, 0, 1 ether, 499, BetPool.InvalidWeight.selector);
        _tryBet(ID, alice, 0, 1 ether, 10_001, BetPool.InvalidWeight.selector);
        _tryBet(ID, alice, 0, 1 ether, 0, BetPool.InvalidWeight.selector);
        _tryBet(ID, alice, 0, 1 ether, type(uint16).max, BetPool.InvalidWeight.selector);
        _tryBet(ID, alice, 2, 1 ether, 10_000, BetPool.InvalidSide.selector);
        _tryBet(ID, alice, 255, 1 ether, 10_000, BetPool.InvalidSide.selector);
        _tryBet(keccak256("unknown"), alice, 0, 1 ether, 10_000, BetPool.UnknownMarket.selector);
        // The boundaries themselves are accepted.
        _place(ID, alice, 0, 0.1 ether, 500);
        _place(ID, alice, 1, 500 ether, 10_000);
        _place(ID2, bob, 0, 1_000 ether, 500);
        _place(ID2, bob, 1, 25_000_000 ether, 10_000);
        assertEq(_position(ID, alice).sharesA, 0.005 ether);
        assertEq(_position(ID2, bob).sharesA, 50 ether);
    }

    function test_ticketForOneSideOrAmountCannotBeUsedForAnother() public {
        _create(ID, IMD);
        _fund(IMD, alice, 10 ether);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        (bytes32 nonce, bytes memory sig) = _signedTicket(ID, alice, 0, 1 ether, 9_000, expiry);
        vm.startPrank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 1, 1 ether, 9_000, expiry, nonce, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 0, 2 ether, 9_000, expiry, nonce, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 0, 1 ether, 10_000, expiry, nonce, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 0, 1 ether, 9_000, expiry - 1, nonce, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 0, 1 ether, 9_000, expiry, bytes32(uint256(nonce) + 1), sig);
        vm.stopPrank();
        // A relayer or front-runner cannot spend alice's ticket, even with their own funds.
        _fund(IMD, bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 0, 1 ether, 9_000, expiry, nonce, sig);
        // Alice's own ticket still works afterwards, exactly once.
        vm.startPrank(alice);
        pool.bet(ID, 0, 1 ether, 9_000, expiry, nonce, sig);
        vm.expectRevert(BetPool.NonceAlreadyUsed.selector);
        pool.bet(ID, 0, 1 ether, 9_000, expiry, nonce, sig);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(pool)), 1 ether);
        assertEq(imd.balanceOf(bob), 10 ether);
    }

    function test_ticketExpiryBoundaries() public {
        _create(ID, IMD);
        _fund(IMD, alice, 10 ether);
        uint64 now_ = uint64(vm.getBlockTimestamp());
        (bytes32 n1, bytes memory s1) = _signedTicket(ID, alice, 0, 1 ether, 9_000, now_ + 121);
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidTicketExpiry.selector);
        pool.bet(ID, 0, 1 ether, 9_000, now_ + 121, n1, s1);
        (bytes32 n2, bytes memory s2) = _signedTicket(ID, alice, 0, 1 ether, 9_000, now_ + 120);
        vm.warp(now_ + 121);
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidTicketExpiry.selector);
        pool.bet(ID, 0, 1 ether, 9_000, now_ + 120, n2, s2);
        vm.warp(now_ + 120);
        vm.prank(alice);
        pool.bet(ID, 0, 1 ether, 9_000, now_ + 120, n2, s2);
        // n1 was never consumed and is valid once it falls inside the window.
        vm.warp(now_ + 2);
        vm.prank(alice);
        pool.bet(ID, 0, 1 ether, 9_000, now_ + 121, n1, s1);
        assertEq(_position(ID, alice).amountA, 2 ether);
    }

    function test_betRefusedAtCloseAfterEarlySettlementAndAfterExpiry() public {
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        _createAt(ID, IMD, close);
        _createAt(ID2, IMD, close);
        _place(ID, alice, 0, 1 ether, 10_000);
        // Early settlement closes betting even before closesAt.
        _settle(ID2, 2);
        _tryBet(ID2, bob, 0, 1 ether, 10_000, BetPool.MarketAlreadySettled.selector);
        vm.warp(close - 1);
        _place(ID, bob, 1, 1 ether, 10_000);
        vm.warp(close);
        _tryBet(ID, carol, 1, 1 ether, 10_000, BetPool.BettingClosed.selector);
        vm.warp(close + 24 hours - 1);
        vm.expectRevert(BetPool.TooEarlyToExpire.selector);
        pool.expire(ID);
        vm.warp(close + 24 hours);
        pool.expire(ID);
        _tryBet(ID, carol, 1, 1 ether, 10_000, BetPool.MarketAlreadySettled.selector);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.expire(ID);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.expire(ID2);
        uint256 deadline = vm.getBlockTimestamp() + 1;
        bytes memory sig = _sign(_outcomeHash(ID, 0, deadline));
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.settle(ID, 0, deadline, sig);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.expire(keccak256("unknown"));
        assertEq(_claim(ID, alice), 1 ether);
        assertEq(_claim(ID, bob), 1 ether);
        assertEq(imd.balanceOf(SPLITTER), 0);
    }

    function test_settleWithSignatureForOtherMarketOrOutcomeRefused() public {
        _create(ID, IMD);
        _create(ID2, IMD);
        _place(ID, alice, 0, 1 ether, 10_000);
        _place(ID, bob, 1, 1 ether, 10_000);
        vm.warp(_marketState(ID).closesAt);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sigOther = _sign(_outcomeHash(ID2, 0, deadline));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 0, deadline, sigOther);
        bytes memory sigA = _sign(_outcomeHash(ID, 0, deadline));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 1, deadline, sigA);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 0, deadline + 1, sigA);
        bytes memory wrongKey = _signFor(_outcomeHash(ID, 1, deadline), address(pool), 1, OTHER_TEST_KEY);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 1, deadline, wrongKey);
        // Owner holds no settlement power without the signer.
        vm.prank(OWNER);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 1, deadline, wrongKey);
        assertFalse(_marketState(ID).settled);
        pool.settle(ID, 0, deadline, sigA);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.settle(ID, 0, deadline, sigA);
    }

    function test_createRefusesWrongFieldsAndUnsupportedToken() public {
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(_marketHash(ID, IMD, close, GAME));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID, SHIFT, close, GAME, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID, IMD, close + 1, GAME, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID2, IMD, close, GAME, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID, IMD, close, keccak256("Space Pinball"), sig);
        address fake = address(new MockToken());
        bytes memory fakeSig = _sign(_marketHash(ID, fake, close, GAME));
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(ID, fake, close, GAME, fakeSig);
        bytes memory zeroSig = _sign(_marketHash(ID, address(0), close, GAME));
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(ID, address(0), close, GAME, zeroSig);
        uint64 tooFar = uint64(vm.getBlockTimestamp() + 7 days + 1);
        bytes memory farSig = _sign(_marketHash(ID, IMD, tooFar, GAME));
        vm.expectRevert(BetPool.InvalidCloseTime.selector);
        pool.createMarket(ID, IMD, tooFar, GAME, farSig);
        pool.createMarket(ID, IMD, close, GAME, sig);
        vm.expectRevert(BetPool.MarketAlreadyExists.selector);
        pool.createMarket(ID, IMD, close, GAME, sig);
    }

    // ---------------------------------------------------------------------------------------------
    // Claims, owner powers and pause.
    // ---------------------------------------------------------------------------------------------

    function test_claimEdgeCases() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 2 ether, 10_000);
        _place(ID, bob, 1, 1 ether, 10_000);
        vm.prank(alice);
        vm.expectRevert(BetPool.MarketNotSettled.selector);
        pool.claim(ID);
        vm.prank(alice);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.claim(keccak256("unknown"));
        _settle(ID, 1);
        // Bob gets his stake back plus 95% of alice's 2 IMD.
        assertEq(pool.claimable(ID, bob), 1 ether + 1.9 ether);
        assertEq(pool.claimable(ID, alice), 0);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BetPool.Claimed(ID, alice, 0);
        assertEq(pool.claim(ID), 0);
        vm.prank(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claim(ID);
        bytes32[] memory none = new bytes32[](0);
        vm.prank(carol);
        pool.claimMany(none);
        assertEq(_claim(ID, bob), 2.9 ether);
        assertEq(pool.claimable(ID, bob), 0);
        bytes32[] memory again = new bytes32[](1);
        again[0] = ID;
        vm.prank(bob);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claimMany(again);
        assertEq(imd.balanceOf(address(pool)), 0);
        assertEq(imd.balanceOf(SPLITTER), 0.1 ether);
    }

    function test_ownerCannotTakeFundsThroughAnyRoute() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 100 ether, 10_000);
        _place(ID, bob, 1, 100 ether, 10_000);
        uint256 held = imd.balanceOf(address(pool));
        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.MarketNotSettled.selector);
        pool.claim(ID);
        pool.pause();
        pool.setLimits(IMD, 1 ether, 10_000 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 1 ether, 10_000 ether + 1);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 0, 1 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 2 ether, 1 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(SHIFT, 1 ether, 500_000_000 ether + 1);
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.setLimits(address(0xBEEF), 1, 1);
        vm.expectRevert(BetPool.InvalidSigner.selector);
        pool.setSigner(address(0));
        vm.stopPrank();
        assertEq(imd.balanceOf(address(pool)), held);
        assertEq(imd.balanceOf(OWNER), 0);
        // Non-owners cannot use admin functions either.
        vm.startPrank(alice);
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.unpause();
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.setSigner(alice);
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.setLimits(IMD, 1, 1);
        vm.stopPrank();
        // Existing positions are untouched by the new limits; settle and claim work while paused.
        _settle(ID, 0);
        assertEq(_claim(ID, OWNER), 0, "owner has no position");
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(_claim(ID, alice), 195 ether);
        assertEq(imd.balanceOf(SPLITTER), 5 ether);
    }

    function test_pauseBlocksCreateAndBetOnly() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 10_000);
        vm.prank(OWNER);
        pool.pause();
        _tryBet(ID, bob, 1, 1 ether, 10_000, Pausable.EnforcedPause.selector);
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(_marketHash(ID2, IMD, close, GAME));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.createMarket(ID2, IMD, close, GAME, sig);
        vm.prank(OWNER);
        pool.unpause();
        pool.createMarket(ID2, IMD, close, GAME, sig);
        _place(ID, bob, 1, 1 ether, 10_000);
        vm.prank(OWNER);
        pool.pause();
        _settle(ID, 1);
        vm.warp(close + 24 hours);
        pool.expire(ID2);
        assertEq(_claim(ID, bob), 1.95 ether);
        assertEq(_claim(ID2, bob), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Stateless fuzz: random keys never authorize; payout bounds for a single winner vs losers.
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_randomKeyNeverAuthorizes(uint256 keySeed, uint8 outcome) public {
        uint256 key = bound(keySeed, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(key != TEST_SIGNER_KEY);
        _create(ID, IMD);
        uint8 o = uint8(bound(outcome, 0, 2));
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory msig = _signFor(_marketHash(ID2, SHIFT, close, GAME), address(pool), 1, key);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID2, SHIFT, close, GAME, msig);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 60);
        bytes memory tsig =
            _signFor(_ticketHash(ID, alice, 0, 1 ether, 5_000, expiry, bytes32(0)), address(pool), 1, key);
        _fund(IMD, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(ID, 0, 1 ether, 5_000, expiry, bytes32(0), tsig);
        // Settlement is checked inside its window, so only the signature can be what refuses it.
        vm.warp(_marketState(ID).closesAt);
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory sig = _signFor(_outcomeHash(ID, o, deadline), address(pool), 1, key);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, o, deadline, sig);
        assertFalse(_marketState(ID).settled);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_winnerGetsPrincipalPlusAtMostNetLosingSide(
        uint256 win,
        uint256 lose1,
        uint256 lose2,
        uint16 w0,
        uint16 w1,
        bool shiftToken,
        bool bWins
    ) public {
        address token = shiftToken ? SHIFT : IMD;
        (uint256 min, uint256 max) = pool.limits(token);
        win = bound(win, min, max);
        lose1 = bound(lose1, min, max);
        lose2 = bound(lose2, min, max);
        uint16 ww = uint16(bound(w0, 500, 10_000));
        uint16 lw = uint16(bound(w1, 500, 10_000));
        uint8 winSide = bWins ? 1 : 0;
        uint8 loseSide = 1 - winSide;
        _create(ID, token);
        _place(ID, alice, winSide, win, ww);
        _place(ID, bob, loseSide, lose1, lw);
        _place(ID, carol, loseSide, lose2, 10_000 - lw + 500);
        _settle(ID, winSide);
        uint256 losing = lose1 + lose2;
        uint256 fee = losing / 20;
        assertEq(MockToken(token).balanceOf(SPLITTER), fee);
        // A sole winner takes the entire net losing side, whatever the weights.
        assertEq(_claim(ID, alice), win + losing - fee);
        assertEq(_claim(ID, bob), 0);
        assertEq(_claim(ID, carol), 0);
        assertEq(MockToken(token).balanceOf(address(pool)), 0);
    }
}
