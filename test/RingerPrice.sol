// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {RingerUnit} from "./RingerUnit.sol";
import {setRingRate} from "./RingRate.sol";

/// The ring reward's price: the lower of the ETH/IMD spot now and the spot the last ring stored, so a ringer that moves
/// the pool inside its own transaction cannot raise its own reward; each ring stores its own read; a push prices the
/// same way and stores nothing; a failed read pays nothing and leaves the stored price; the first ring uses the spot.
/// Against the mock manager, whose price word each test sets. Every comparison is one bell rung twice from one state,
/// so the counted gas is the same and only the price differs.
abstract contract RingerPrice is RingerUnit {
    uint256 internal constant SP100 = 10 << 96; // 100 IMD per ETH
    uint256 internal constant SP1600 = 40 << 96; // 1,600 IMD per ETH

    function _ringAt(uint256 d, uint256 tod, uint256 sp) internal returns (uint256 paid) {
        day = d;
        _at(tod);
        _price(sp, 0);
        (paid,) = _ring();
    }

    /// the same bell from one state, rung at spot `a` and (after a revert) at spot `b`; the state left is b's ring
    function _twice(uint256 d, uint256 tod, uint256 a, uint256 b) internal returns (uint256 pa, uint256 pb) {
        uint256 snap = vm.snapshotState();
        pa = _ringAt(d, tod, a);
        vm.revertToState(snap);
        pb = _ringAt(d, tod, b);
    }

    function _pricedSetUp() internal {
        _fund(30e18);
        setRingRate(r, 1 gwei);
    }

    /// No ring before: the spot alone. Four times the price, four times the reward.
    function test_RP_firstRingUsesTheSpot() public {
        _pricedSetUp();
        (uint256 p400, uint256 p1600) = _twice(day, OPEN, SP400, SP1600);
        assertGt(p400, 0);
        assertApproxEqRel(p1600, 4 * p400, 0.001e18, "the first ring: the spot, whatever it is");
    }

    /// The open rings at 400; the close at a spot four times higher is paid exactly as the close at 400.
    function test_RP_spotAboveTheLastRingPaysTheLastRingsPrice() public {
        _pricedSetUp();
        _ringAt(day, OPEN, SP400);
        (uint256 close400, uint256 closeMoved) = _twice(day, CLOSE, SP400, SP1600);
        console2.log("(RP) close at 400 / close with the spot at 1,600, after an open at 400 (wei IMD)", close400, closeMoved);
        assertGt(close400, 0);
        assertEq(closeMoved, close400, "a raised spot does not raise the reward above the last ring's price");
    }

    /// The open rings at 400; the close at a spot four times lower is paid at the spot.
    function test_RP_spotBelowTheLastRingPaysTheSpot() public {
        _pricedSetUp();
        _ringAt(day, OPEN, SP400);
        (uint256 close400, uint256 close100) = _twice(day, CLOSE, SP400, SP100);
        assertApproxEqRel(close400, 4 * close100, 0.001e18, "a lower spot pays the lower price");
    }

    /// Each ring stores its own read: open at 400, close at 100; the next open at 400 is paid as the next open at 100.
    function test_RP_eachRingStoresItsOwnRead() public {
        _pricedSetUp();
        _ringAt(day, OPEN, SP400);
        _ringAt(day, CLOSE, SP100);
        (uint256 at400, uint256 at100) = _twice(day + 1, OPEN, SP400, SP100);
        assertGt(at100, 0);
        assertEq(at400, at100, "held to the last ring's lower read");
    }

    /// A failed read pays nothing and leaves the stored price: open at 400, close's read fails; the next open at 1,600
    /// is paid as the next open at 400.
    function test_RP_failedReadKeepsTheStoredPrice() public {
        _pricedSetUp();
        _ringAt(day, OPEN, SP400);
        _at(CLOSE);
        _price(SP400, 1); // the read reverts
        (uint256 failed,) = _ring();
        assertEq(failed, 0, "a failed read pays nothing");
        (uint256 at1600, uint256 at400) = _twice(day + 1, OPEN, SP1600, SP400);
        assertGt(at400, 0);
        assertEq(at1600, at400, "held to the price stored before the failed read");
    }

    /// A push prices the same way and stores nothing: the open at 400 stores 400; a push at a spot of 1,600 is paid as
    /// a push at 400; the close after that push, at 1,600, is paid as a close at 400.
    function test_RP_pushUsesTheLowerPriceAndStoresNothing() public {
        _pricedSetUp();
        _ringAt(day, OPEN, SP400);
        imd.mint(address(hook), 9_205_508_960_207_920_806);
        hook.setBurnAccrued(9_205_508_960_207_920_806);
        uint256 snap = vm.snapshotState();
        _price(SP1600, 0);
        (uint256 pushMoved, bool bridged,) = _push(0.001 ether);
        vm.revertToState(snap);
        _price(SP400, 0);
        (uint256 push400,,) = _push(0.001 ether);
        assertTrue(bridged, "precondition: the push bridged");
        assertGt(push400, 0);
        assertEq(pushMoved, push400, "a push at a raised spot is paid at the last ring's price");
        vm.revertToState(snap);
        _price(SP1600, 0);
        _push(0.001 ether);
        (uint256 close1600, uint256 close400) = _twice(day, CLOSE, SP1600, SP400);
        assertEq(close1600, close400, "the push stored nothing: the close is held to the open's price");
    }

    /// FIGURES: a ringer that moves the spot in two rings running. The first moved ring is paid at the stored
    /// price but stores its own moved read, so the second moved ring running is paid at the moved price.
    function test_RP_measure_twoMovedRingsRunning() public {
        _pricedSetUp();
        _ringAt(day, OPEN, SP400);
        (uint256 honestClose, uint256 movedClose) = _twice(day, CLOSE, SP400, SP1600);
        uint256 snap = vm.snapshotState();
        uint256 movedNext = _ringAt(day + 1, OPEN, SP1600); // after the moved close, which stored 1,600
        vm.revertToState(snap);
        uint256 honestNext = _ringAt(day + 1, OPEN, SP400);
        console2.log("(RP) close honest / moved (wei IMD)", honestClose, movedClose);
        console2.log("(RP) next open after the moved close: at 400 / moved again to 1,600 (wei IMD)", honestNext, movedNext);
        assertEq(movedClose, honestClose, "the first moved ring: the stored price");
        assertApproxEqRel(movedNext, 4 * honestNext, 0.001e18, "the second moved ring running: its own last read");
    }
}
