// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../../src/BetPool.sol";
import {MockToken} from "./MockToken.sol";

/// @dev Mixes honest calls with attacks (replayed and stolen tickets, forged outcomes, double claims,
///      claims by non-bettors, premature expiry, admin calls by strangers). Every attack must revert or
///      pay nothing, and leave balances untouched. Claims are checked against payout bounds rather than
///      the exact formula, so this model is independent of the one in BetPoolHandler.
contract BetPoolAttackHandler is Test {
    uint256 internal constant SIGNER_KEY = 0x751910;
    uint256 internal constant FORGER_KEY = 0xA77AC4;
    uint256 public constant ACTORS = 4;
    address internal constant SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;

    struct Ghost {
        bytes32 id;
        address token;
        uint64 close;
        uint256 a;
        uint256 b;
        uint256 fee;
        uint256 paid;
        bool settled;
        uint8 outcome;
        bool refundable;
        uint256[4] depA;
        uint256[4] depB;
        bool[4] claimed;
    }

    struct Ticket {
        bytes32 id;
        address bettor;
        uint8 side;
        uint256 amount;
        uint16 weight;
        uint64 expiry;
        bytes32 nonce;
        bytes sig;
    }

    BetPool public immutable pool;
    address public immutable owner;
    address public immutable attacker = address(0xBAD);
    address[4] public actors;
    Ghost[] internal ghosts;
    Ticket internal last;
    bool public hasLast;
    uint256 internal nonceCount = 1 << 128;
    mapping(address token => uint256) public fees;
    mapping(address token => uint256) public attacksRefused;
    uint256 public refusedAttacks;
    uint256 public honestClaims;

    constructor(BetPool pool_) {
        pool = pool_;
        owner = pool_.owner();
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = address(uint160(0x7000 + i));
        }
        _create(0, 2 hours);
        _create(1, 3 hours);
    }

    function count() external view returns (uint256) {
        return ghosts.length;
    }

    function ghost(uint256 i) external view returns (Ghost memory) {
        return ghosts[i];
    }

    // --------------------------------------------------------------------------------------------- honest

    function create(uint256 seed) external {
        if (ghosts.length >= 12) return;
        _create(seed, bound(seed, 1 hours, 7 days));
    }

    function _create(uint256 seed, uint256 duration) internal {
        address token = seed % 2 == 0 ? pool.IMD() : pool.SHIFT();
        bytes32 id = keccak256(abi.encode("attack market", ghosts.length));
        uint64 close = uint64(vm.getBlockTimestamp() + duration);
        bytes32 game = keccak256("Space Pinball");
        bytes32 h = keccak256(
            abi.encode(
                keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)"), id, token, close, game
            )
        );
        pool.createMarket(id, token, close, game, _sign(SIGNER_KEY, h));
        Ghost storage g = ghosts.push();
        g.id = id;
        g.token = token;
        g.close = close;
    }

    function place(uint256 mSeed, uint256 aSeed, uint256 amountSeed, uint16 weightSeed, bool sideB) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled || vm.getBlockTimestamp() >= g.close) return;
        uint256 ai = aSeed % ACTORS;
        (uint256 min, uint256 max) = pool.limits(g.token);
        uint256 amount = bound(amountSeed, min, max);
        Ticket memory t = _ticket(g.id, actors[ai], sideB ? 1 : 0, amount, uint16(bound(weightSeed, 500, 10_000)));
        MockToken(g.token).mint(t.bettor, amount);
        vm.startPrank(t.bettor);
        MockToken(g.token).approve(address(pool), amount);
        pool.bet(t.id, t.side, t.amount, t.weight, t.expiry, t.nonce, t.sig);
        vm.stopPrank();
        if (sideB) {
            g.b += amount;
            g.depB[ai] += amount;
        } else {
            g.a += amount;
            g.depA[ai] += amount;
        }
        last = t;
        hasLast = true;
    }

    function settle(uint256 mSeed, uint8 outcomeSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled) return;
        uint8 outcome = uint8(bound(outcomeSeed, 0, 2));
        uint256 deadline = vm.getBlockTimestamp() + 300;
        uint256 splitterBefore = MockToken(g.token).balanceOf(SPLITTER);
        pool.settle(g.id, outcome, deadline, _sign(SIGNER_KEY, _outcomeHash(g.id, outcome, deadline)));
        g.settled = true;
        g.outcome = outcome;
        g.refundable = outcome == 2 || g.a == 0 || g.b == 0;
        uint256 fee = MockToken(g.token).balanceOf(SPLITTER) - splitterBefore;
        // 5% of the losing side, rounded down; nothing on a refundable market.
        uint256 losing = outcome == 0 ? g.b : g.a;
        assertEq(fee, g.refundable ? 0 : losing / 20, "fee is not floor(5% of losing side)");
        assertLe(fee * 20, g.refundable ? 0 : losing);
        g.fee = fee;
        fees[g.token] += fee;
    }

    function expire(uint256 mSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled) return;
        if (vm.getBlockTimestamp() < uint256(g.close) + 24 hours) {
            try pool.expire(g.id) {
                assertTrue(false, "expired before closesAt + 24h");
            } catch {
                ++refusedAttacks;
            }
            return;
        }
        pool.expire(g.id);
        g.settled = true;
        g.outcome = 2;
        g.refundable = true;
    }

    function claim(uint256 mSeed, uint256 aSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        uint256 ai = aSeed % ACTORS;
        address actor = actors[ai];
        if (!g.settled || g.claimed[ai]) {
            uint256 before = MockToken(g.token).balanceOf(actor);
            vm.prank(actor);
            try pool.claim(g.id) {
                assertTrue(false, "claim before settlement or second claim succeeded");
            } catch {
                ++refusedAttacks;
            }
            assertEq(MockToken(g.token).balanceOf(actor), before);
            return;
        }
        uint256 balBefore = MockToken(g.token).balanceOf(actor);
        vm.prank(actor);
        uint256 paid = pool.claim(g.id);
        assertEq(MockToken(g.token).balanceOf(actor) - balBefore, paid, "returned amount differs from transfer");
        _checkPayout(g, ai, paid);
        g.claimed[ai] = true;
        g.paid += paid;
        ++honestClaims;
    }

    function _checkPayout(Ghost storage g, uint256 ai, uint256 paid) internal view {
        if (g.refundable) {
            assertEq(paid, g.depA[ai] + g.depB[ai], "refund is not exactly the stakes");
            return;
        }
        uint256 principal = g.outcome == 0 ? g.depA[ai] : g.depB[ai];
        uint256 losing = g.outcome == 0 ? g.b : g.a;
        if (principal == 0) {
            assertEq(paid, 0, "a wallet with no winning stake was paid");
            return;
        }
        assertGe(paid, principal, "winner lost principal");
        assertLe(paid, principal + losing - g.fee, "winner paid more than the net losing side");
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 8 hours));
    }

    // --------------------------------------------------------------------------------------------- attacks

    function replayLastTicket() external {
        if (!hasLast) return;
        Ticket memory t = last;
        address token = _tokenOf(t.id);
        MockToken(token).mint(t.bettor, t.amount);
        vm.startPrank(t.bettor);
        MockToken(token).approve(address(pool), t.amount);
        uint256 held = MockToken(token).balanceOf(address(pool));
        try pool.bet(t.id, t.side, t.amount, t.weight, t.expiry, t.nonce, t.sig) {
            assertTrue(false, "replayed ticket accepted");
        } catch {
            ++refusedAttacks;
        }
        MockToken(token).approve(address(pool), 0);
        vm.stopPrank();
        assertEq(MockToken(token).balanceOf(address(pool)), held);
        // Burn the unused mint so actor balances only reflect payouts.
        vm.prank(t.bettor);
        MockToken(token).transfer(address(0xdead), t.amount);
    }

    function stealTicket(uint256 mSeed, uint256 aSeed, uint256 amountSeed, uint16 weightSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        (uint256 min, uint256 max) = pool.limits(g.token);
        uint256 amount = bound(amountSeed, min, max);
        Ticket memory t = _ticket(g.id, actors[aSeed % ACTORS], 0, amount, uint16(bound(weightSeed, 500, 10_000)));
        _attackerBet(g, t, "ticket used by someone other than its bettor");
    }

    function forgedTicket(uint256 mSeed, uint256 amountSeed, uint16 weightSeed, bool sideB) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        (uint256 min, uint256 max) = pool.limits(g.token);
        uint256 amount = bound(amountSeed, min, max);
        uint16 weight = uint16(bound(weightSeed, 500, 10_000));
        uint64 expiry = uint64(vm.getBlockTimestamp() + 60);
        bytes32 nonce = bytes32(++nonceCount);
        bytes memory sig = _sign(FORGER_KEY, _ticketHash(g.id, attacker, sideB ? 1 : 0, amount, weight, expiry, nonce));
        _attackerBet(g, Ticket(g.id, attacker, sideB ? 1 : 0, amount, weight, expiry, nonce, sig), "forged ticket");
    }

    function _attackerBet(Ghost storage g, Ticket memory t, string memory why) internal {
        MockToken(g.token).mint(attacker, t.amount);
        vm.startPrank(attacker);
        MockToken(g.token).approve(address(pool), t.amount);
        try pool.bet(t.id, t.side, t.amount, t.weight, t.expiry, t.nonce, t.sig) {
            assertTrue(false, why);
        } catch {
            ++refusedAttacks;
        }
        MockToken(g.token).transfer(address(0xdead), t.amount);
        vm.stopPrank();
        assertFalse(pool.usedNonce(t.nonce), "refused ticket consumed its nonce");
    }

    function forgedSettle(uint256 mSeed, uint8 outcomeSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        uint8 outcome = uint8(bound(outcomeSeed, 0, 2));
        uint256 deadline = vm.getBlockTimestamp() + 300;
        bytes memory sig = _sign(FORGER_KEY, _outcomeHash(g.id, outcome, deadline));
        vm.prank(owner);
        try pool.settle(g.id, outcome, deadline, sig) {
            assertTrue(false, "outcome settled without the signer");
        } catch {
            ++refusedAttacks;
        }
    }

    function resettle(uint256 mSeed, uint8 outcomeSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (!g.settled) return;
        uint8 outcome = uint8(bound(outcomeSeed, 0, 2));
        uint256 deadline = vm.getBlockTimestamp() + 300;
        try pool.settle(g.id, outcome, deadline, _sign(SIGNER_KEY, _outcomeHash(g.id, outcome, deadline))) {
            assertTrue(false, "settled twice");
        } catch {
            ++refusedAttacks;
        }
        try pool.expire(g.id) {
            assertTrue(false, "expired a settled market");
        } catch {
            ++refusedAttacks;
        }
    }

    function strangerClaims(uint256 mSeed) external {
        Ghost storage g = ghosts[mSeed % ghosts.length];
        vm.prank(attacker);
        try pool.claim(g.id) returns (uint256 paid) {
            assertTrue(g.settled, "claim on unsettled market");
            assertEq(paid, 0, "stranger was paid");
        } catch {
            ++refusedAttacks;
        }
    }

    function strangerAdmin(uint256 seed) external {
        vm.startPrank(attacker);
        try pool.setSigner(attacker) {
            assertTrue(false, "stranger set signer");
        } catch {}
        try pool.setLimits(pool.IMD(), 1, bound(seed, 1, 10_000 ether)) {
            assertTrue(false, "stranger set limits");
        } catch {}
        try pool.pause() {
            assertTrue(false, "stranger paused");
        } catch {}
        vm.stopPrank();
        ++refusedAttacks;
    }

    // --------------------------------------------------------------------------------------------- helpers

    function _tokenOf(bytes32 id) internal view returns (address token) {
        (token,,,,,,,,,) = pool.markets(id);
    }

    function _ticket(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight)
        internal
        returns (Ticket memory t)
    {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        bytes32 nonce = bytes32(++nonceCount);
        t = Ticket(
            id,
            bettor,
            side,
            amount,
            weight,
            expiry,
            nonce,
            _sign(SIGNER_KEY, _ticketHash(id, bettor, side, amount, weight, expiry, nonce))
        );
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
        return keccak256(
            abi.encode(
                keccak256(
                    "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
                ),
                id,
                bettor,
                side,
                amount,
                weight,
                expiry,
                nonce
            )
        );
    }

    function _outcomeHash(bytes32 id, uint8 outcome, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)"), id, outcome, deadline)
        );
    }

    function _sign(uint256 key, bytes32 h) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftBets"),
                keccak256("1"),
                block.chainid,
                address(pool)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, h)));
        return abi.encodePacked(r, s, v);
    }
}
