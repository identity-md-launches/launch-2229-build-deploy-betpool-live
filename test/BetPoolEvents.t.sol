// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool} from "./helpers/BetPoolTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BetPoolEventsTest is BetPoolTestBase {
    function test_marketBetSettlementAndClaimEvents() public {
        uint64 close = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(_marketHash(ID, IMD, close, GAME));
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.MarketCreated(ID, IMD, close, GAME);
        pool.createMarket(ID, IMD, close, GAME, sig);
        _fund(IMD, alice, 1 ether);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120);
        bytes32 nonce = bytes32("events");
        sig = _sign(_ticketHash(ID, alice, 0, 1 ether, 5_000, expiry, nonce));
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.BetPlaced(ID, alice, 0, 1 ether, 5_000, 0.5 ether);
        vm.prank(alice);
        pool.bet(ID, 0, 1 ether, 5_000, expiry, nonce, sig);
        _place(ID, bob, 1, 2 ether + 19, 500);
        sig = _sign(_outcomeHash(ID, 0, vm.getBlockTimestamp()));
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.Settled(ID, 0, 0.1 ether);
        pool.settle(ID, 0, vm.getBlockTimestamp(), sig);
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.Claimed(ID, alice, 2.9 ether + 19);
        _claim(ID, alice);
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.Claimed(ID, bob, 0);
        _claim(ID, bob);
    }

    function test_adminAndExpiryEvents() public {
        _create(ID, IMD);
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.SignerSet(alice);
        vm.prank(OWNER);
        pool.setSigner(alice);
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.LimitsSet(IMD, 1 ether, 10 ether);
        vm.prank(OWNER);
        pool.setLimits(IMD, 1 ether, 10 ether);
        vm.expectEmit(false, false, false, true, address(pool));
        emit Pausable.Paused(OWNER);
        vm.prank(OWNER);
        pool.pause();
        vm.expectEmit(false, false, false, true, address(pool));
        emit Pausable.Unpaused(OWNER);
        vm.prank(OWNER);
        pool.unpause();
        vm.warp(uint256(_marketState(ID).closesAt) + 24 hours);
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.Expired(ID);
        pool.expire(ID);
    }

    function test_refundableSettlementEmitsZeroFee() public {
        _create(ID, IMD);
        _place(ID, alice, 0, 1 ether, 500);
        bytes memory sig = _sign(_outcomeHash(ID, 1, vm.getBlockTimestamp()));
        vm.expectEmit(true, true, true, true, address(pool));
        emit BetPool.Settled(ID, 1, 0);
        pool.settle(ID, 1, vm.getBlockTimestamp(), sig);
    }
}
