// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../../src/BetPool.sol";
import {MockToken} from "./MockToken.sol";

abstract contract BetPoolTestBase is Test {
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address internal constant SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    uint256 internal constant TEST_SIGNER_KEY = 0x751910;
    uint256 internal constant OTHER_TEST_KEY = 0x123456;
    bytes32 internal constant ID = keccak256("test match 1");
    bytes32 internal constant ID2 = keccak256("test match 2");
    bytes32 internal constant GAME = keccak256("NIGHT CHESS");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Deliberately independent of the implementation's hash constants.
    bytes32 internal constant MARKET_HASH =
        keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)");
    bytes32 internal constant TICKET_HASH = keccak256(
        "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
    );
    bytes32 internal constant OUTCOME_HASH = keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)");

    BetPool internal pool;
    MockToken internal imd;
    MockToken internal shift;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;
    uint256 internal nonceCounter;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(1);
        pool = new BetPool();
        vm.prank(OWNER);
        pool.setSigner(vm.addr(TEST_SIGNER_KEY));
        MockToken implementation = new MockToken();
        vm.etch(IMD, address(implementation).code);
        vm.etch(SHIFT, address(implementation).code);
        imd = MockToken(IMD);
        shift = MockToken(SHIFT);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
    }

    function _domain(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("NightshiftBets"), keccak256("1"), chainId, verifyingContract)
            );
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        return _signFor(structHash, address(pool), 1, TEST_SIGNER_KEY);
    }

    function _signFor(bytes32 structHash, address target, uint256 chainId, uint256 key)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(target, chainId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _marketHash(bytes32 id, address token, uint64 close, bytes32 game) internal pure returns (bytes32) {
        return keccak256(abi.encode(MARKET_HASH, id, token, close, game));
    }

    function _ticketHash(
        bytes32 id,
        address bettor,
        uint8 side,
        uint256 amount,
        uint16 weight,
        uint64 expiry,
        bytes32 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(TICKET_HASH, id, bettor, side, amount, weight, expiry, nonce));
    }

    function _outcomeHash(bytes32 id, uint8 outcome, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(OUTCOME_HASH, id, outcome, deadline));
    }

    function _create(bytes32 id, address token) internal {
        _createAt(id, token, uint64(vm.getBlockTimestamp() + 1 hours));
    }

    function _createAt(bytes32 id, address token, uint64 close) internal {
        pool.createMarket(id, token, close, GAME, _sign(_marketHash(id, token, close, GAME)));
    }

    function _fund(address token, address bettor, uint256 amount) internal {
        MockToken(token).mint(bettor, amount);
        vm.prank(bettor);
        MockToken(token).approve(address(pool), amount);
    }

    function _place(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight)
        internal
        returns (bytes32 nonce)
    {
        (address token,,,,,,,,,) = pool.markets(id);
        _fund(token, bettor, amount);
        nonce = bytes32(++nonceCounter);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        bytes memory sig = _sign(_ticketHash(id, bettor, side, amount, weight, expiry, nonce));
        vm.prank(bettor);
        pool.bet(id, side, amount, weight, expiry, nonce, sig);
    }

    /// @dev Decisive outcomes are only accepted once betting has closed, so this moves the clock to closesAt
    ///      when needed. Void is relayed at the current time. Tests of the timing rules call pool.settle directly.
    function _settle(bytes32 id, uint8 outcome) internal {
        uint64 close = _marketState(id).closesAt;
        if (outcome != 2 && vm.getBlockTimestamp() < close) vm.warp(close);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        pool.settle(id, outcome, deadline, _sign(_outcomeHash(id, outcome, deadline)));
    }

    function _claim(bytes32 id, address bettor) internal returns (uint256 amount) {
        vm.prank(bettor);
        return pool.claim(id);
    }

    function _marketState(bytes32 id) internal view returns (BetPool.Market memory m) {
        (m.token, m.closesAt, m.game, m.totalA, m.totalB, m.sharesA, m.sharesB, m.settled, m.outcome, m.refundable) =
            pool.markets(id);
    }

    function _position(bytes32 id, address bettor) internal view returns (BetPool.Bet memory b) {
        (b.amountA, b.amountB, b.sharesA, b.sharesB, b.claimed) = pool.betsOf(id, bettor);
    }
}
