// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DeploymentFactory {
    function deploy(bytes memory initcode, bytes32 salt) external returns (BetPool) {
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initcode, 32), mload(initcode), salt)
        }
        require(deployed != address(0), "constructor failed");
        return BetPool(deployed);
    }
}

contract BetPoolSafetyTest is BetPoolTestBase {
    function _signedAttempt(uint8 side, uint256 amount, uint16 weight) internal {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        bytes32 nonce = bytes32(uint256(777));
        bytes memory sig = _sign(_ticketHash(ID, alice, side, amount, weight, expiry, nonce));
        vm.prank(alice);
        pool.bet(ID, side, amount, weight, expiry, nonce, sig);
    }

    function test_factoryDeploymentWithoutAnyExternalContractsOrPrivileges() public {
        vm.etch(IMD, "");
        vm.etch(SHIFT, "");
        vm.etch(SPLITTER, "");
        DeploymentFactory factory = new DeploymentFactory();
        bytes memory initcode = type(BetPool).creationCode;
        bytes32 salt = keccak256("local deployment rehearsal");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initcode)))))
        );
        BetPool fresh = factory.deploy(initcode, salt);
        assertEq(address(fresh), predicted);
        assertLe(initcode.length, 49_152);
        assertEq(fresh.owner(), OWNER);
        assertTrue(fresh.owner() != address(factory));
        assertTrue(address(fresh).code.length > 0);
        vm.prank(address(factory));
        vm.expectRevert(BetPool.OnlyOwner.selector);
        fresh.setSigner(alice);
    }

    function test_runtimeSizeAndNoForbiddenOpcodes() public view {
        bytes memory code = address(pool).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_onlyOwnerMayConfigureOrPause() public {
        vm.startPrank(alice);
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.setSigner(alice);
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.setLimits(IMD, 1, 2);
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.pause();
        vm.expectRevert(BetPool.OnlyOwner.selector);
        pool.unpause();
        vm.stopPrank();
    }

    function test_signerCannotBeSetToZero() public {
        vm.prank(OWNER);
        vm.expectRevert(BetPool.InvalidSigner.selector);
        pool.setSigner(address(0));
        assertEq(pool.signer(), vm.addr(TEST_SIGNER_KEY));
    }

    function test_limitsCanReachButNeverExceedEitherHardCap() public {
        vm.startPrank(OWNER);
        pool.setLimits(IMD, 1, 10_000 ether);
        pool.setLimits(SHIFT, 1, 500_000_000 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 1, 10_000 ether + 1);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(SHIFT, 1, 500_000_000 ether + 1);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 0, 500 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(SHIFT, 1_000 ether, 999 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 0, 0);
        pool.setLimits(IMD, 17, 17);
        vm.stopPrank();
        (uint256 min, uint256 max) = pool.limits(IMD);
        assertEq(min, 17);
        assertEq(max, 17);
    }

    function test_onlyTwoTokensAccepted() public {
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(_marketHash(ID, alice, close, GAME));
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(ID, alice, close, GAME, sig);
        vm.prank(OWNER);
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.setLimits(alice, 1, 2);
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(ID, address(0), close, GAME, "");
    }

    function test_IMDAmountsOutsideLimitsRejected() public {
        _badAmounts(IMD);
    }

    function test_SHIFTAmountsOutsideLimitsRejected() public {
        _badAmounts(SHIFT);
    }

    function _badAmounts(address token) internal {
        _create(ID, token);
        (uint256 min, uint256 max) = pool.limits(token);
        vm.expectRevert(BetPool.AmountOutsideLimits.selector);
        _signedAttempt(0, min - 1, 500);
        vm.expectRevert(BetPool.AmountOutsideLimits.selector);
        _signedAttempt(0, max + 1, 10_000);
        vm.expectRevert(BetPool.AmountOutsideLimits.selector);
        _signedAttempt(0, 0, 5_000);
        assertEq(pool.marketBalance(ID), 0);
    }

    function test_invalidSideAndWeightRejectedEvenIfSignerApproves() public {
        _create(ID, IMD);
        vm.expectRevert(BetPool.InvalidSide.selector);
        _signedAttempt(2, 1 ether, 500);
        vm.expectRevert(BetPool.InvalidSide.selector);
        _signedAttempt(255, 1 ether, 500);
        vm.expectRevert(BetPool.InvalidWeight.selector);
        _signedAttempt(0, 1 ether, 499);
        vm.expectRevert(BetPool.InvalidWeight.selector);
        _signedAttempt(0, 1 ether, 10_001);
        vm.expectRevert(BetPool.InvalidWeight.selector);
        _signedAttempt(0, 1 ether, 0);
    }

    function test_newLimitsApplyToPendingTicketsAndExistingMarketsOnlyProspectively() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 500 ether, 500);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        bytes32 nonce = bytes32("pending");
        bytes memory sig = _sign(_ticketHash(ID, alice, 0, 500 ether, 500, expiry, nonce));
        vm.prank(OWNER);
        pool.setLimits(IMD, 0.2 ether, 10 ether);
        vm.prank(alice);
        vm.expectRevert(BetPool.AmountOutsideLimits.selector);
        pool.bet(ID, 0, 500 ether, 500, expiry, nonce, sig);
        _place(ID, bob, 1, 10 ether, 10_000);
        _settle(ID, 0);
        assertEq(_claim(ID, alice), 509.5 ether);
    }

    function test_minimumCanBeOneWeiButZeroShareTicketCannotCreateUndefinedPayout() public {
        _create(ID, IMD);
        vm.prank(OWNER);
        pool.setLimits(IMD, 1, 100);
        _fund(IMD, alice, 100);
        vm.expectRevert(BetPool.ZeroShares.selector);
        _signedAttempt(0, 1, 500);
        assertFalse(pool.usedNonce(bytes32(uint256(777))));
        _signedAttempt(0, 1, 10_000);
        _place(ID, bob, 1, 19, 10_000);
        _settle(ID, 0);
        assertEq(imd.balanceOf(SPLITTER), 0);
        assertEq(_claim(ID, alice), 20);
        assertEq(pool.marketBalance(ID), 0);
    }

    function test_twentyWeiMinimumWorksAtSmallestWeight() public {
        _create(ID, IMD);
        vm.prank(OWNER);
        pool.setLimits(IMD, 20, 20);
        _place(ID, alice, 0, 20, 500);
        _place(ID, bob, 1, 20, 500);
        _settle(ID, 0);
        assertEq(_position(ID, alice).sharesA, 1);
        assertEq(imd.balanceOf(SPLITTER), 1);
        assertEq(_claim(ID, alice), 39);
    }

    function test_bettingExclusiveCloseBoundary() public {
        _create(ID, IMD);
        uint64 close = _marketState(ID).closesAt;
        vm.warp(close - 1);
        _place(ID, alice, 0, 1 ether, 500);
        vm.warp(close);
        vm.expectRevert(BetPool.BettingClosed.selector);
        _signedAttempt(0, 1 ether, 500);
        vm.warp(uint256(close) + 1);
        vm.expectRevert(BetPool.BettingClosed.selector);
        _signedAttempt(0, 1 ether, 500);
    }

    function test_unknownMarketsRejectAllMutationsAndViewsReturnZero() public {
        assertEq(pool.claimable(ID, alice), 0);
        assertEq(_position(ID, alice).amountA, 0);
        assertEq(_marketState(ID).token, address(0));
        vm.expectRevert(BetPool.UnknownMarket.selector);
        _signedAttempt(0, 1 ether, 500);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.settle(ID, 0, vm.getBlockTimestamp(), "");
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.expire(ID);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.claim(ID);
    }

    function test_noClaimsBeforeSettlementAndNoBetsOrDoubleSettleAfterwards() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        vm.prank(alice);
        vm.expectRevert(BetPool.MarketNotSettled.selector);
        pool.claim(ID);
        _settle(ID, 0);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        _signedAttempt(0, 1 ether, 500);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.settle(ID, 2, vm.getBlockTimestamp(), "");
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.expire(ID);
    }

    function test_settleAfterExpireRejected() public {
        _create(ID, IMD);
        uint256 deadline = vm.getBlockTimestamp() + 3 days;
        bytes memory sig = _sign(_outcomeHash(ID, 0, deadline));
        vm.warp(uint256(_marketState(ID).closesAt) + 24 hours);
        pool.expire(ID);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.settle(ID, 0, deadline, sig);
    }

    function test_settlementAfterRefundDeadlineStillWorksUntilSomeoneExpires() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 1 ether, 500);
        vm.warp(uint256(_marketState(ID).closesAt) + 24 hours);
        _settle(ID, 0);
        assertFalse(_marketState(ID).refundable);
        assertEq(_claim(ID, alice), 1.95 ether);
    }

    function test_invalidOutcomeEvenIfSignedRejected() public {
        _create(ID, IMD);
        bytes memory sig = _sign(_outcomeHash(ID, 3, vm.getBlockTimestamp()));
        vm.expectRevert(BetPool.InvalidOutcome.selector);
        pool.settle(ID, 3, vm.getBlockTimestamp(), sig);
    }

    function test_pauseBlocksOnlyNewMarketsAndBets() public {
        _create(ID, IMD);
        _create(ID2, SHIFT);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 2 ether, 10_000);
        _place(ID2, alice, 0, 1_000 ether, 500);
        vm.prank(OWNER);
        pool.pause();
        assertTrue(pool.paused());
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.createMarket(bytes32("new"), IMD, uint64(vm.getBlockTimestamp() + 1 hours), GAME, "");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _signedAttempt(0, 1 ether, 500);
        _settle(ID, 0);
        assertEq(_claim(ID, alice), 2.9 ether);
        vm.warp(uint256(_marketState(ID2).closesAt) + 24 hours);
        pool.expire(ID2);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ID2;
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(shift.balanceOf(alice), 1_000 ether);
        vm.prank(OWNER);
        pool.unpause();
        assertFalse(pool.paused());
        _create(bytes32("new"), IMD);
        _place(bytes32("new"), bob, 1, 2 ether, 500);
    }

    function test_duplicatePauseAndUnpauseRejectedAndConfigurationWorksWhilePaused() public {
        vm.startPrank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        pool.unpause();
        pool.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.pause();
        pool.setSigner(alice);
        pool.setLimits(IMD, 1 ether, 3 ether);
        pool.unpause();
        vm.stopPrank();
        assertEq(pool.signer(), alice);
    }

    function test_ownerHasNoCustodyRedirectionOrOwnershipTransferFunctions() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 2 ether, 500);
        bytes[] memory attempts = new bytes[](9);
        attempts[0] = abi.encodeWithSignature("withdraw(address,uint256)", IMD, 2 ether);
        attempts[1] = abi.encodeWithSignature("sweep(address,address,uint256)", IMD, OWNER, 2 ether);
        attempts[2] = abi.encodeWithSignature("rescueTokens(address,address,uint256)", IMD, OWNER, 2 ether);
        attempts[3] = abi.encodeWithSignature("setFeeRecipient(address)", OWNER);
        attempts[4] = abi.encodeWithSignature("setFee(uint256)", 10_000);
        attempts[5] = abi.encodeWithSignature("transferOwnership(address)", alice);
        attempts[6] = abi.encodeWithSignature("renounceOwnership()");
        attempts[7] = abi.encodeWithSignature("upgradeTo(address)", alice);
        attempts[8] = abi.encodeWithSignature(
            "execute(address,bytes)", IMD, abi.encodeWithSignature("transfer(address,uint256)", OWNER, 2 ether)
        );
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(pool).call(attempts[i]);
            assertFalse(ok);
        }
        assertEq(imd.balanceOf(address(pool)), 2 ether);
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(pool.owner(), OWNER);
        assertEq(pool.FEE_SPLITTER(), SPLITTER);
        assertEq(pool.FEE_BPS(), 500);
    }

    function test_transferFromFailureDoesNotConsumeNonceOrRecordBet() public {
        _create(ID, IMD);
        _fund(IMD, alice, 1 ether);
        imd.setModes(MockToken.Mode.ReturnFalse, MockToken.Mode.Normal);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _signedAttempt(0, 1 ether, 500);
        _assertNoBet();
        imd.setModes(MockToken.Mode.RevertTransfer, MockToken.Mode.Normal);
        vm.expectRevert(bytes("mock pull failure"));
        _signedAttempt(0, 1 ether, 500);
        _assertNoBet();
        imd.setModes(MockToken.Mode.Normal, MockToken.Mode.Normal);
        _signedAttempt(0, 1 ether, 500);
        assertTrue(pool.usedNonce(bytes32(uint256(777))));
    }

    function test_inexactTransfersRevertAndRollBackEverything() public {
        _create(ID, IMD);
        _fund(IMD, alice, 1 ether);
        MockToken.Mode[3] memory modes =
            [MockToken.Mode.ShortTransfer, MockToken.Mode.NoTransfer, MockToken.Mode.ExtraTransfer];
        for (uint256 i; i < modes.length; ++i) {
            imd.setModes(modes[i], MockToken.Mode.Normal);
            vm.expectRevert(BetPool.InexactTransfer.selector);
            _signedAttempt(0, 1 ether, 500);
            _assertNoBet();
            assertEq(imd.balanceOf(alice), 1 ether);
            assertEq(imd.allowance(alice, address(pool)), 1 ether);
        }
    }

    function _assertNoBet() internal view {
        assertEq(pool.marketBalance(ID), 0);
        assertEq(imd.balanceOf(address(pool)), 0);
        assertEq(_position(ID, alice).amountA, 0);
        assertEq(_marketState(ID).sharesA, 0);
        assertFalse(pool.usedNonce(bytes32(uint256(777))));
    }

    function test_insufficientAllowanceAndBalanceRollBack() public {
        _create(ID, IMD);
        imd.mint(alice, 1 ether);
        vm.expectRevert();
        _signedAttempt(0, 1 ether, 500);
        _assertNoBet();
        vm.prank(alice);
        imd.approve(address(pool), 2 ether);
        vm.expectRevert();
        _signedAttempt(0, 2 ether, 500);
        _assertNoBet();
    }

    function test_tokenWithoutCodeCannotAcceptBet() public {
        _create(ID, IMD);
        vm.etch(IMD, "");
        vm.expectRevert();
        _signedAttempt(0, 1 ether, 500);
        assertEq(pool.marketBalance(ID), 0);
        assertFalse(pool.usedNonce(bytes32(uint256(777))));
    }

    function test_safeERC20AcceptsNoReturnData() public {
        _create(ID, IMD);
        imd.setModes(MockToken.Mode.NoReturn, MockToken.Mode.NoReturn);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 1 ether, 500);
        _settle(ID, 0);
        assertEq(imd.balanceOf(SPLITTER), 0.05 ether);
        assertEq(_claim(ID, alice), 1.95 ether);
        assertEq(imd.balanceOf(alice), 1.95 ether);
    }

    function test_failedFeeTransferRollsBackSettlementAndCanExpireLater() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 1 ether, 500);
        imd.setModes(MockToken.Mode.Normal, MockToken.Mode.ReturnFalse);
        bytes memory sig = _sign(_outcomeHash(ID, 0, vm.getBlockTimestamp()));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        pool.settle(ID, 0, vm.getBlockTimestamp(), sig);
        assertFalse(_marketState(ID).settled);
        assertEq(pool.marketBalance(ID), 2 ether);
        assertEq(imd.balanceOf(SPLITTER), 0);
        vm.warp(uint256(_marketState(ID).closesAt) + 24 hours);
        pool.expire(ID);
        assertTrue(_marketState(ID).refundable);
        imd.setModes(MockToken.Mode.Normal, MockToken.Mode.Normal);
        assertEq(_claim(ID, alice), 1 ether);
        assertEq(_claim(ID, bob), 1 ether);
    }

    function test_failedClaimPreservesEntitlementAndDoesNotBlockOthers() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 2 ether, 500);
        _settle(ID, 2);
        imd.setModes(MockToken.Mode.Normal, MockToken.Mode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        pool.claim(ID);
        assertFalse(_position(ID, alice).claimed);
        assertEq(pool.claimable(ID, alice), 1 ether);
        assertEq(pool.marketBalance(ID), 3 ether);
        imd.setModes(MockToken.Mode.Normal, MockToken.Mode.Normal);
        assertEq(_claim(ID, bob), 2 ether);
        assertEq(_claim(ID, alice), 1 ether);
    }

    function test_reentrantBetCallbackIsBlocked() public {
        _create(ID, IMD);
        imd.setCallback(address(pool), abi.encodeCall(pool.claim, (ID)), true, false);
        _place(ID, alice, 0, 1 ether, 500);
        _assertGuardedCallback();
        assertEq(pool.marketBalance(ID), 1 ether);
    }

    function test_reentrantSettlementFeeCallbackIsBlocked() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 1 ether, 500);
        imd.setCallback(address(pool), abi.encodeCall(pool.claim, (ID)), false, true);
        _settle(ID, 0);
        _assertGuardedCallback();
        assertFalse(_position(ID, IMD).claimed);
        assertEq(pool.marketBalance(ID), 1.95 ether);
    }

    function test_reentrantClaimAndClaimManyCallbacksAreBlocked() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        _place(ID, bob, 1, 1 ether, 500);
        _settle(ID, 2);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ID;
        imd.setCallback(address(pool), abi.encodeCall(pool.claimMany, (ids)), false, true);
        _claim(ID, alice);
        _assertGuardedCallback();
        imd.setCallback(address(pool), abi.encodeCall(pool.expire, (ID)), false, true);
        vm.prank(bob);
        pool.claimMany(ids);
        _assertGuardedCallback();
        assertEq(pool.marketBalance(ID), 0);
    }

    function _assertGuardedCallback() internal view {
        assertFalse(imd.callbackSuccess());
        assertEq(bytes4(imd.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }
}
