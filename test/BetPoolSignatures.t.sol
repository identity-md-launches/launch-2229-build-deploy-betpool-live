// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool} from "./helpers/BetPoolTestBase.sol";

contract BetPoolSignaturesTest is BetPoolTestBase {
    struct Ticket {
        bytes32 id;
        address bettor;
        uint8 side;
        uint256 amount;
        uint16 weight;
        uint64 expiry;
        bytes32 nonce;
    }

    function setUp() public override {
        super.setUp();
        _create(ID, IMD);
        _fund(IMD, alice, 500 ether);
    }

    function _ticket() internal view returns (Ticket memory t) {
        t = Ticket(ID, alice, 0, 1 ether, 7_500, uint64(vm.getBlockTimestamp() + 120), bytes32("nonce"));
    }

    function _hash(Ticket memory t) internal pure returns (bytes32) {
        return _ticketHash(t.id, t.bettor, t.side, t.amount, t.weight, t.expiry, t.nonce);
    }

    function _submit(Ticket memory t, bytes memory sig) internal {
        vm.prank(t.bettor);
        pool.bet(t.id, t.side, t.amount, t.weight, t.expiry, t.nonce, sig);
    }

    function test_domainAndTypeHashesMatchExactSpecification() public view {
        assertEq(pool.DOMAIN_SEPARATOR(), _domain(address(pool), 1));
        assertEq(pool.MARKET_TYPEHASH(), MARKET_HASH);
        assertEq(pool.TICKET_TYPEHASH(), TICKET_HASH);
        assertEq(pool.OUTCOME_TYPEHASH(), OUTCOME_HASH);
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            pool.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "NightshiftBets");
        assertEq(version, "1");
        assertEq(chainId, 1);
        assertEq(verifyingContract, address(pool));
    }

    function testFuzz_ticketSignatureBindsEveryField(uint8 field) public {
        field = uint8(bound(field, 0, 6));
        Ticket memory t = _ticket();
        bytes memory sig = _sign(_hash(t));
        if (field == 0) {
            _create(ID2, IMD);
            t.id = ID2;
        }
        if (field == 1) t.bettor = bob;
        if (field == 2) t.side = 1;
        if (field == 3) t.amount += 1;
        if (field == 4) t.weight -= 1;
        if (field == 5) t.expiry -= 1;
        if (field == 6) t.nonce = bytes32("other nonce");
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, sig);
        assertEq(pool.marketBalance(ID), 0);
        assertFalse(pool.usedNonce(t.nonce));
    }

    function test_ticketWrongSigner() public {
        Ticket memory t = _ticket();
        bytes memory sig = _signFor(_hash(t), address(pool), block.chainid, OTHER_TEST_KEY);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, sig);
    }

    function test_ticketWrongContract() public {
        Ticket memory t = _ticket();
        bytes memory sig = _signFor(_hash(t), address(this), block.chainid, TEST_SIGNER_KEY);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, sig);
    }

    function test_ticketWrongChain() public {
        Ticket memory t = _ticket();
        bytes memory sig = _signFor(_hash(t), address(pool), 2, TEST_SIGNER_KEY);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, sig);
    }

    function test_domainChangesAfterChainIdChange() public {
        Ticket memory t = _ticket();
        bytes memory oldSig = _sign(_hash(t));
        vm.chainId(2);
        assertEq(pool.DOMAIN_SEPARATOR(), _domain(address(pool), 2));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, oldSig);
        _submit(t, _signFor(_hash(t), address(pool), 2, TEST_SIGNER_KEY));
        assertEq(_position(ID, alice).amountA, t.amount);
    }

    function test_ticketExpiryAtCurrentTimeAndMaximumAccepted() public {
        Ticket memory t = _ticket();
        _submit(t, _sign(_hash(t)));
        t.expiry = uint64(vm.getBlockTimestamp());
        t.nonce = bytes32("second nonce");
        _submit(t, _sign(_hash(t)));
        assertEq(_position(ID, alice).amountA, 2 ether);
    }

    function test_ticketExpiredRejectedEvenWithValidSignature() public {
        Ticket memory t = _ticket();
        t.expiry = uint64(vm.getBlockTimestamp() - 1);
        bytes memory sig = _sign(_hash(t));
        vm.expectRevert(BetPool.InvalidTicketExpiry.selector);
        _submit(t, sig);
    }

    function test_ticketTooFarExpiryRejectedEvenWithValidSignature() public {
        Ticket memory t = _ticket();
        t.expiry = uint64(vm.getBlockTimestamp() + 121);
        bytes memory sig = _sign(_hash(t));
        vm.expectRevert(BetPool.InvalidTicketExpiry.selector);
        _submit(t, sig);
    }

    function test_ticketNonceCannotBeReusedEvenWithDifferentSignedFields() public {
        Ticket memory t = _ticket();
        _submit(t, _sign(_hash(t)));
        assertTrue(pool.usedNonce(t.nonce));
        bytes memory sig = _sign(_hash(t));
        vm.expectRevert(BetPool.NonceAlreadyUsed.selector);
        _submit(t, sig);
        t.side = 1;
        t.amount += 1;
        sig = _sign(_hash(t));
        vm.expectRevert(BetPool.NonceAlreadyUsed.selector);
        _submit(t, sig);
    }

    function test_nonceIsGlobalAcrossMarketsWalletsAndSignerRotations() public {
        Ticket memory t = _ticket();
        _submit(t, _sign(_hash(t)));
        _create(ID2, IMD);
        t.id = ID2;
        t.bettor = bob;
        vm.prank(OWNER);
        pool.setSigner(vm.addr(OTHER_TEST_KEY));
        bytes memory sig = _signFor(_hash(t), address(pool), block.chainid, OTHER_TEST_KEY);
        vm.expectRevert(BetPool.NonceAlreadyUsed.selector);
        _submit(t, sig);
    }

    function testFuzz_malformedSignatureLengthsRejected(uint8 rawLength) public {
        uint256 length = bound(rawLength, 0, 100);
        if (length == 65) length = 66;
        Ticket memory t = _ticket();
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, new bytes(length));
    }

    function test_highSMalleatedSignatureRejected() public {
        Ticket memory t = _ticket();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(address(pool), 1), _hash(t)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_SIGNER_KEY, digest);
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleated = abi.encodePacked(r, bytes32(order - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, malleated);
        _submit(t, abi.encodePacked(r, s, v));
    }

    function test_badVAndZeroRecoveryRejected() public {
        Ticket memory t = _ticket();
        bytes memory sig = _sign(_hash(t));
        sig[64] = bytes1(uint8(0));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, sig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, new bytes(65));
    }

    function test_personalSignSignatureRejected() public {
        Ticket memory t = _ticket();
        bytes32 typedDigest = keccak256(abi.encodePacked("\x19\x01", _domain(address(pool), 1), _hash(t)));
        bytes32 personalDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", typedDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_SIGNER_KEY, personalDigest);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, abi.encodePacked(r, s, v));
    }

    function testFuzz_createSignatureBindsEveryField(uint8 field) public {
        field = uint8(bound(field, 0, 3));
        bytes32 id = ID2;
        address token = IMD;
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes32 game = GAME;
        bytes memory sig = _sign(_marketHash(id, token, close, game));
        if (field == 0) id = bytes32("another market");
        if (field == 1) token = SHIFT;
        if (field == 2) close += 1;
        if (field == 3) game = keccak256("Space Pinball");
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(id, token, close, game, sig);
    }

    function testFuzz_createRejectsWrongSignerContractChain(uint8 variant) public {
        variant = uint8(bound(variant, 0, 2));
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _signFor(
            _marketHash(ID2, IMD, close, GAME),
            variant == 0 ? address(this) : address(pool),
            variant == 1 ? 2 : 1,
            variant == 2 ? OTHER_TEST_KEY : TEST_SIGNER_KEY
        );
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID2, IMD, close, GAME, sig);
    }

    function test_createSignatureCannotBeReplayedOnNewDeployment() public {
        BetPool other = new BetPool();
        vm.prank(OWNER);
        other.setSigner(vm.addr(TEST_SIGNER_KEY));
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(_marketHash(ID2, IMD, close, GAME));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        other.createMarket(ID2, IMD, close, GAME, sig);
    }

    function test_creationAtSevenDaysAndPermissionlessSubmission() public {
        uint64 close = uint64(vm.getBlockTimestamp() + 7 days);
        bytes memory sig = _sign(_marketHash(ID2, SHIFT, close, GAME));
        vm.prank(dave);
        pool.createMarket(ID2, SHIFT, close, GAME, sig);
        assertEq(_marketState(ID2).closesAt, close);
    }

    function test_creationAtNowPastAndTooFarRejected() public {
        uint64[3] memory times = [
            uint64(vm.getBlockTimestamp()),
            uint64(vm.getBlockTimestamp() - 1),
            uint64(vm.getBlockTimestamp() + 7 days + 1)
        ];
        for (uint256 i; i < times.length; ++i) {
            bytes memory sig = _sign(_marketHash(ID2, IMD, times[i], GAME));
            vm.expectRevert(BetPool.InvalidCloseTime.selector);
            pool.createMarket(ID2, IMD, times[i], GAME, sig);
        }
    }

    function test_duplicateMarketIdCannotBeReusedAfterSettlement() public {
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(_marketHash(ID, IMD, close, GAME));
        vm.expectRevert(BetPool.MarketAlreadyExists.selector);
        pool.createMarket(ID, IMD, close, GAME, sig);
        _settle(ID, 2);
        vm.expectRevert(BetPool.MarketAlreadyExists.selector);
        pool.createMarket(ID, IMD, close, GAME, sig);
    }

    function testFuzz_outcomeSignatureBindsEveryField(uint8 field) public {
        field = uint8(bound(field, 0, 2));
        _create(ID2, IMD);
        bytes32 id = ID;
        uint8 outcome;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(_outcomeHash(id, outcome, deadline));
        if (field == 0) id = ID2;
        if (field == 1) outcome = 1;
        if (field == 2) deadline += 1;
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(id, outcome, deadline, sig);
    }

    function testFuzz_settleRejectsWrongSignerContractChain(uint8 variant) public {
        variant = uint8(bound(variant, 0, 2));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signFor(
            _outcomeHash(ID, 0, deadline),
            variant == 0 ? address(this) : address(pool),
            variant == 1 ? 2 : 1,
            variant == 2 ? OTHER_TEST_KEY : TEST_SIGNER_KEY
        );
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 0, deadline, sig);
    }

    function test_settlementDeadlineInclusiveAndPermissionless() public {
        uint256 deadline = vm.getBlockTimestamp();
        bytes memory sig = _sign(_outcomeHash(ID, 0, deadline));
        vm.prank(dave);
        pool.settle(ID, 0, deadline, sig);
        assertTrue(_marketState(ID).settled);
    }

    function test_expiredSettlementRejected() public {
        uint256 deadline = vm.getBlockTimestamp() - 1;
        bytes memory sig = _sign(_outcomeHash(ID, 0, deadline));
        vm.expectRevert(BetPool.OutcomeExpired.selector);
        pool.settle(ID, 0, deadline, sig);
    }

    function test_ownerCannotSettleWithoutSigner() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vm.prank(OWNER);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 0, deadline, "");
        assertFalse(_marketState(ID).settled);
    }

    function test_rotationRevokesAllOldSignatureTypesAndNewSignerWorks() public {
        Ticket memory t = _ticket();
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory ticketSig = _sign(_hash(t));
        bytes memory marketSig = _sign(_marketHash(ID2, IMD, close, GAME));
        bytes memory outcomeSig = _sign(_outcomeHash(ID, 0, deadline));
        vm.prank(OWNER);
        pool.setSigner(vm.addr(OTHER_TEST_KEY));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, ticketSig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(ID2, IMD, close, GAME, marketSig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(ID, 0, deadline, outcomeSig);
        _submit(t, _signFor(_hash(t), address(pool), 1, OTHER_TEST_KEY));
        pool.createMarket(
            ID2, IMD, close, GAME, _signFor(_marketHash(ID2, IMD, close, GAME), address(pool), 1, OTHER_TEST_KEY)
        );
        pool.settle(ID, 0, deadline, _signFor(_outcomeHash(ID, 0, deadline), address(pool), 1, OTHER_TEST_KEY));
        assertEq(pool.claimable(ID, alice), 1 ether);
    }
}
