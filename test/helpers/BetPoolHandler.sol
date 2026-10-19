// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../../src/BetPool.sol";
import {MockToken} from "./MockToken.sol";

/// @dev Stateful reference model. Only successful calls change the model; unexpected reverts fail the invariant run.
contract BetPoolHandler is Test {
    uint256 public constant ACTORS = 6;
    uint256 public constant MAX_MARKETS = 24;

    struct Position {
        uint256 a;
        uint256 b;
        uint256 sa;
        uint256 sb;
        bool claimed;
    }

    struct Model {
        bytes32 id;
        address token;
        uint64 close;
        uint256 a;
        uint256 b;
        uint256 sa;
        uint256 sb;
        bool settled;
        uint8 outcome;
        bool refundable;
        uint256 fee;
        uint256 paid;
        Position[6] positions;
    }

    BetPool public immutable pool;
    address public immutable imd;
    address public immutable shift;
    address public immutable administrator;
    uint256 public signingKey;
    address[6] public actors;
    Model[] private models;
    mapping(address token => uint256) public totalDeposited;
    mapping(address token => uint256) public totalPaid;
    mapping(address token => uint256) public totalFees;
    mapping(address token => uint256) public donations;
    mapping(address token => mapping(address actor => uint256)) public actorPaid;
    uint256 public nonceCount;
    uint256 public successfulBets;
    uint256 public successfulClaims;
    uint256 public successfulSettlements;
    uint256 public successfulExpiries;

    constructor(BetPool pool_, uint256 testKey) {
        pool = pool_;
        signingKey = testKey;
        imd = pool_.IMD();
        shift = pool_.SHIFT();
        administrator = pool_.owner();
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = address(uint160(0x2000 + i));
        }
        for (uint256 i; i < 4; ++i) {
            _create(i % 2 == 0 ? imd : shift, 1 hours + i * 1 hours);
        }
    }

    function count() external view returns (uint256) {
        return models.length;
    }

    function snapshot(uint256 index) external view returns (Model memory) {
        return models[index];
    }

    function create(uint256 seed) external {
        if (pool.paused() || models.length == MAX_MARKETS) return;
        _create(seed % 2 == 0 ? imd : shift, bound(seed, 1 hours, 7 days));
    }

    function _create(address token, uint256 duration) private {
        bytes32 id = keccak256(abi.encode("invariant market", models.length));
        uint64 close = uint64(vm.getBlockTimestamp() + duration);
        bytes32 game = keccak256("Agent Arena");
        bytes32 hash = keccak256(
            abi.encode(
                keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)"), id, token, close, game
            )
        );
        pool.createMarket(id, token, close, game, _sign(hash));
        Model storage m = models.push();
        m.id = id;
        m.token = token;
        m.close = close;
    }

    function place(uint256 marketSeed, uint256 actorSeed, uint256 amountSeed, uint16 weightSeed, bool sideB) external {
        Model storage m = models[marketSeed % models.length];
        if (pool.paused() || m.settled || vm.getBlockTimestamp() >= m.close) return;
        uint256 actorIndex = actorSeed % ACTORS;
        address actor = actors[actorIndex];
        (uint256 min, uint256 max) = pool.limits(m.token);
        uint256 amount = bound(amountSeed, min, max);
        uint16 weight = uint16(bound(weightSeed, 500, 10_000));
        uint8 side = sideB ? 1 : 0;
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        bytes32 nonce = bytes32(++nonceCount);
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
                ),
                m.id,
                actor,
                side,
                amount,
                weight,
                expiry,
                nonce
            )
        );
        bytes memory sig = _sign(hash);
        MockToken(m.token).mint(actor, amount);
        vm.startPrank(actor);
        MockToken(m.token).approve(address(pool), amount);
        pool.bet(m.id, side, amount, weight, expiry, nonce, sig);
        vm.stopPrank();
        uint256 shares = amount * weight / 10_000;
        Position storage p = m.positions[actorIndex];
        if (sideB) {
            m.b += amount;
            m.sb += shares;
            p.b += amount;
            p.sb += shares;
        } else {
            m.a += amount;
            m.sa += shares;
            p.a += amount;
            p.sa += shares;
        }
        totalDeposited[m.token] += amount;
        ++successfulBets;
    }

    function settle(uint256 marketSeed, uint8 outcomeSeed) external {
        Model storage m = models[marketSeed % models.length];
        if (m.settled) return;
        uint8 outcome = uint8(bound(outcomeSeed, 0, 2));
        uint256 deadline = vm.getBlockTimestamp() + 120;
        bytes32 hash = keccak256(
            abi.encode(keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)"), m.id, outcome, deadline)
        );
        pool.settle(m.id, outcome, deadline, _sign(hash));
        m.settled = true;
        m.outcome = outcome;
        m.refundable = outcome == 2 || m.a == 0 || m.b == 0;
        if (!m.refundable) m.fee = (outcome == 0 ? m.b : m.a) * 5 / 100;
        totalFees[m.token] += m.fee;
        ++successfulSettlements;
    }

    function expire(uint256 marketSeed) external {
        Model storage m = models[marketSeed % models.length];
        if (m.settled) return;
        _expire(m);
    }

    function _expire(Model storage m) private {
        uint256 expiry = uint256(m.close) + 24 hours;
        if (vm.getBlockTimestamp() < expiry) vm.warp(expiry);
        pool.expire(m.id);
        m.settled = true;
        m.outcome = 2;
        m.refundable = true;
        ++successfulExpiries;
    }

    function claim(uint256 marketSeed, uint256 actorSeed) external {
        Model storage m = models[marketSeed % models.length];
        uint256 actorIndex = actorSeed % ACTORS;
        if (!m.settled || m.positions[actorIndex].claimed) return;
        _claim(m, actorIndex);
    }

    function _claim(Model storage m, uint256 actorIndex) private {
        uint256 expectedAmount = _expected(m, actorIndex);
        vm.prank(actors[actorIndex]);
        uint256 actual = pool.claim(m.id);
        assertEq(actual, expectedAmount, "claim disagrees with independent model");
        _recordClaim(m, actorIndex, expectedAmount);
    }

    function claimMany(uint256 firstSeed, uint256 secondSeed, uint256 actorSeed) external {
        uint256 a = firstSeed % models.length;
        uint256 b = secondSeed % models.length;
        uint256 actorIndex = actorSeed % ACTORS;
        Model storage first = models[a];
        Model storage second = models[b];
        if (
            a == b || !first.settled || !second.settled || first.positions[actorIndex].claimed
                || second.positions[actorIndex].claimed
        ) return;
        uint256 firstAmount = _expected(first, actorIndex);
        uint256 secondAmount = _expected(second, actorIndex);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = first.id;
        ids[1] = second.id;
        vm.prank(actors[actorIndex]);
        pool.claimMany(ids);
        _recordClaim(first, actorIndex, firstAmount);
        _recordClaim(second, actorIndex, secondAmount);
    }

    function _recordClaim(Model storage m, uint256 actorIndex, uint256 amount) private {
        m.positions[actorIndex].claimed = true;
        m.paid += amount;
        totalPaid[m.token] += amount;
        actorPaid[m.token][actors[actorIndex]] += amount;
        ++successfulClaims;
    }

    function expected(uint256 marketIndex, uint256 actorIndex) external view returns (uint256) {
        return _expected(models[marketIndex], actorIndex);
    }

    function _expected(Model storage m, uint256 actorIndex) private view returns (uint256) {
        Position storage p = m.positions[actorIndex];
        if (!m.settled || p.claimed) return 0;
        if (m.refundable) return p.a + p.b;
        uint256 principal = m.outcome == 0 ? p.a : p.b;
        uint256 shares = m.outcome == 0 ? p.sa : p.sb;
        uint256 winningShares = m.outcome == 0 ? m.sa : m.sb;
        uint256 losing = m.outcome == 0 ? m.b : m.a;
        return principal + shares * (losing - m.fee) / winningShares;
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 30 minutes));
    }

    function togglePause() external {
        bool paused = pool.paused();
        vm.prank(administrator);
        if (paused) pool.unpause();
        else pool.pause();
    }

    function adjustLimits(bool isShift, uint256 minSeed, uint256 maxSeed) external {
        address token = isShift ? shift : imd;
        uint256 cap = isShift ? 500_000_000 ether : 10_000 ether;
        uint256 min = bound(minSeed, 20, cap);
        uint256 max = bound(maxSeed, min, cap);
        vm.prank(administrator);
        pool.setLimits(token, min, max);
    }

    function rotateSigner(bool other) external {
        signingKey = other ? 0x123456 : 0x751910;
        vm.prank(administrator);
        pool.setSigner(vm.addr(signingKey));
    }

    function donate(bool isShift, uint128 seed) external {
        address token = isShift ? shift : imd;
        uint256 amount = bound(seed, 0, 100_000 ether);
        MockToken(token).mint(address(pool), amount);
        donations[token] += amount;
    }

    /// @dev Not targeted by the fuzzer. Drain every valid entitlement at the end to check liveness and rounding.
    function finish() external {
        for (uint256 i; i < models.length; ++i) {
            Model storage m = models[i];
            if (!m.settled) _expire(m);
            for (uint256 j; j < ACTORS; ++j) {
                if (!m.positions[j].claimed) _claim(m, j);
            }
        }
    }

    function _sign(bytes32 hash) private view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftBets"),
                keccak256("1"),
                block.chainid,
                address(pool)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, keccak256(abi.encodePacked("\x19\x01", domain, hash)));
        return abi.encodePacked(r, s, v);
    }
}
