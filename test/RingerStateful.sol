// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {ChoreBox, MockRingHook, MockManager, OK, REENTER} from "./RingerMocks.sol";

/// Random days against hostile chores: before every ring each of the seven chores is set, at random, to succeed, revert,
/// starve, revert with a 32 kB bomb, return a 32 kB bomb, or call back into the ringer; the price read is set to answer,
/// revert, answer short, starve, read zero or read absurd; the purse is fed, topped up and pushed from. The ghosts
/// record every IMD into and out of the ringer, every bell, and every ring that failed when it should have rung.
contract RingerHandler is Test {
    uint256 internal constant OPEN = 43200;
    uint256 internal constant CLOSE = 57600;
    uint256 internal constant DEADLINE = 72000;
    bytes4[7] internal SELS = [bytes4(0xe0d0eac4), 0x4641257d, 0xabb74d4b, 0x6b58a30f, 0xe67eccdd, 0x8df82800, 0x01e20f20];

    BellRinger public r;
    MockRingHook public hook;
    ChoreBox public factory;
    ChoreBox public game;
    ChoreBox public budget;
    MockManager public mgr;
    MockERC20 public imd;
    address[3] internal callers = [address(0xA1), address(0xA2), address(0xA3)];

    uint256 public purseIn;
    uint256 public purseOut;
    uint256 public rings;
    uint256 public ringsPaid;
    uint256 public choresSkipped;
    uint256 public ringFailedWhenDue; // must stay 0: a chore never fails a bell
    uint256 public secondRingsRefused;
    uint256 public shortGasRefused;
    uint256 public pushes;
    uint256 public daysSeen;
    uint256 internal lastDay;

    constructor(BellRinger r_, MockRingHook hook_, ChoreBox f, ChoreBox g, ChoreBox b, MockManager m, MockERC20 imd_) {
        (r, hook, factory, game, budget, mgr, imd) = (r_, hook_, f, g, b, m, imd_);
    }

    function _box(uint256 i) internal view returns (ChoreBox) {
        return i == 0 ? factory : i <= 4 ? ChoreBox(hook) : i == 5 ? game : budget;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
        vm.roll(block.number + 1);
        uint256 d = block.timestamp / 1 days;
        if (d != lastDay) {
            lastDay = d;
            ++daysSeen;
        }
    }

    /// to a bell's own second, so rings are frequent
    function toBell(bool open, uint256 dayAhead) external {
        uint256 d = block.timestamp / 1 days + bound(dayAhead, 0, 1);
        uint256 t = d * 1 days + (open ? OPEN : CLOSE);
        if (t <= block.timestamp) t += 1 days;
        vm.warp(t);
        vm.roll(block.number + 1);
        if (t / 1 days != lastDay) {
            lastDay = t / 1 days;
            ++daysSeen;
        }
    }

    function hostile(uint256 seed) external {
        for (uint256 i; i < 7; ++i) {
            uint8 m = uint8(uint256(keccak256(abi.encode(seed, i))) % 6);
            _box(i).setMode(SELS[i], m);
            if (m == REENTER) {
                uint256 which = uint256(keccak256(abi.encode(seed, i, "re"))) % 3;
                bytes memory data = which == 0 ? abi.encodeCall(BellRinger.ring, ()) : which == 1
                    ? abi.encodeCall(BellRinger.topUp, (1)) : abi.encodeCall(BellRinger.pushBurnRewarded, ());
                _box(i).setReenter(address(r), data);
            }
        }
    }

    function price(uint256 seed) external {
        bytes32 slot = keccak256(abi.encode(r.ethImdPoolId(), bytes32(uint256(6))));
        uint256 k = seed % 6;
        uint256 sp = k == 4 ? 0 : k == 5 ? type(uint160).max : bound(seed >> 8, 1 << 90, 1 << 110);
        mgr.set(slot, bytes32(sp), uint8(k < 4 ? k : 0));
    }

    function feed(uint256 a) external {
        hook.setPurseFeed(bound(a, 0, 5e18));
        imd.mint(address(hook), 5e18);
    }

    function topUp(uint256 a, uint8 who) external {
        a = bound(a, 0, 10e18);
        address c = callers[who % 3];
        imd.mint(c, a);
        vm.startPrank(c);
        imd.approve(address(r), a);
        r.topUp(a);
        vm.stopPrank();
        purseIn += a;
    }

    function ring(uint8 who, uint256 gasPrice) external {
        uint256 d = block.timestamp / 1 days;
        uint256 tod = block.timestamp % 1 days;
        bool open = tod >= OPEN && tod < CLOSE;
        bool due = open || (tod >= CLOSE && tod < DEADLINE);
        uint256 s = open ? 2 * d : 2 * d + 1;
        bool rungBefore = hook.rung(s);
        address c = callers[who % 3];
        uint256 held0 = imd.balanceOf(address(r));
        uint256 feed0 = hook.purseFeed();
        bool feedWorks = hook.mode(SELS[3]) == OK;
        // the fuzzer sets the base fee (0 to 2,000 gwei) and a tip on top of it; the reward follows the first
        uint256 bf = bound(gasPrice, 0, 2_000 gwei);
        vm.fee(bf);
        vm.txGasPrice(bf + gasPrice % 3 gwei);
        vm.recordLogs();
        vm.prank(c, c);
        (bool ok, bytes memory e) = address(r).call{gas: 9_500_000}(abi.encodeCall(BellRinger.ring, ()));
        Vm.Log[] memory lg = vm.getRecordedLogs();
        // back to zero at once: a gas price left set would be charged to the fuzzer's own sender after this call
        vm.txGasPrice(0);
        vm.fee(0);
        if (!due) {
            assertFalse(ok, "rang with no bell due");
            assertEq(bytes4(e), BellRinger.NoBellDue.selector);
            return;
        }
        if (rungBefore) {
            assertFalse(ok, "ringing: a second ring of a bell succeeded");
            assertEq(bytes4(e), MockRingHook.BellAlreadyRung.selector);
            assertEq(imd.balanceOf(address(r)), held0, "ringing: a refused ring paid");
            ++secondRingsRefused;
            return;
        }
        if (!ok) {
            ++ringFailedWhenDue;
            return;
        }
        assertTrue(hook.rung(s), "ringing: the bell rang");
        ++rings;
        uint256 paid;
        bool seen;
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter != address(r)) continue;
            if (lg[i].topics[0] == BellRinger.Rewarded.selector) {
                (paid,) = abi.decode(lg[i].data, (uint256, bool));
                assertEq(address(uint160(uint256(lg[i].topics[1]))), c, "ringer purse: paid to the caller");
                seen = true;
            } else if (lg[i].topics[0] == BellRinger.ChoreSkipped.selector) {
                ++choresSkipped;
            }
        }
        assertTrue(seen, "ringing: Rewarded on every ring");
        uint256 inflow = open && feedWorks ? feed0 : 0;
        assertLe(paid, r.RING_REWARD_CAP(), "ringer purse: over the cap");
        assertLe(paid, held0 + inflow, "ringer purse: over the purse");
        assertEq(imd.balanceOf(c) >= paid, true);
        purseIn += inflow;
        purseOut += paid;
        if (paid > 0) ++ringsPaid;
        // a second ringer in the same block: refused, paid nothing
        uint256 held1 = imd.balanceOf(address(r));
        address c2 = callers[(uint256(who) + 1) % 3];
        vm.prank(c2, c2);
        (bool ok2, bytes memory e2) = address(r).call{gas: 9_500_000}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok2, "ringing: a second ring in the block succeeded");
        assertEq(bytes4(e2), MockRingHook.BellAlreadyRung.selector);
        assertEq(imd.balanceOf(address(r)), held1, "ringing: the second ringer was paid");
        ++secondRingsRefused;
    }

    function ringShort(uint256 under) external {
        uint256 d = block.timestamp / 1 days;
        uint256 tod = block.timestamp % 1 days;
        bool open = tod >= OPEN && tod < CLOSE;
        if (!open && !(tod >= CLOSE && tod < DEADLINE)) return;
        uint256 s = open ? 2 * d : 2 * d + 1;
        bool rungBefore = hook.rung(s);
        uint256 need = r.bellGasFloor() + (open ? r.CHORE_GAS_OPEN() : r.CHORE_GAS_CLOSE());
        (bool ok, bytes memory e) = address(r).call{gas: need - bound(under, 1, 500_000)}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok, "ringing: a ring below floor + stipends went through");
        assertEq(bytes4(e), BellRinger.GasShort.selector, "ringing: refused for another reason");
        assertEq(hook.rung(s), rungBefore, "ringing: the bell rang anyway");
        ++shortGasRefused;
    }

    function push(uint256 a, uint256 value, bool refuse, uint256 gasPrice) external {
        a = bound(a, 0, 20e18);
        imd.mint(address(hook), a);
        hook.setBurnAccrued(a);
        hook.executor().set(0.0002 ether, 1e12, refuse);
        value = bound(value, 0, 0.01 ether);
        address c = callers[a % 3];
        vm.deal(c, value);
        uint256 held0 = imd.balanceOf(address(r));
        uint256 bf = bound(gasPrice, 0, 2_000 gwei);
        vm.fee(bf);
        vm.txGasPrice(bf + gasPrice % 3 gwei);
        vm.recordLogs();
        vm.prank(c, c);
        (bool ok,) = address(r).call{value: value}(abi.encodeCall(BellRinger.pushBurnRewarded, ()));
        Vm.Log[] memory lg = vm.getRecordedLogs();
        vm.txGasPrice(0);
        vm.fee(0);
        if (!ok) {
            assertLt(a, 5e18, "a push of a full accrual reverted");
            assertEq(c.balance, value, "a refused push returned the ETH");
            return;
        }
        uint256 paid;
        bool bridged;
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.PushRewarded.selector) {
                (paid, bridged) = abi.decode(lg[i].data, (uint256, bool));
            }
        }
        assertEq(bridged, !refuse && value >= 0.0002 ether, "bridged iff the executor took the fee");
        assertTrue(bridged || paid == 0, "ringer purse: a push paid without bridging");
        assertLe(paid, r.PUSH_REWARD_CAP(), "ringer purse: a push over its cap");
        assertEq(held0 - imd.balanceOf(address(r)), paid, "ringer purse: the purse moved by the reward only");
        purseOut += paid;
        ++pushes;
    }

    /// stray IMD sent straight to the ringer: the purse grows by it; anyone may do it, nothing can take it back out
    function stray(uint256 a) external {
        a = bound(a, 0, 1e18);
        imd.mint(address(r), a);
        purseIn += a;
    }
}

abstract contract RingerStateful is Test {
    RingerHandler internal h;

    function setUp() public virtual {
        vm.warp(20_400 days + 2 hours);
        MockERC20 imd = new MockERC20("Stand-in", "STAND", 18);
        MockRingHook hook = new MockRingHook(imd);
        ChoreBox f = new ChoreBox();
        ChoreBox g = new ChoreBox();
        ChoreBox b = new ChoreBox();
        MockManager m = new MockManager();
        BellRinger r = new BellRinger(address(hook), address(f), address(g), address(b), address(imd), address(m), 770003, 7_000_000);
        h = new RingerHandler(r, hook, f, g, b, m, imd);
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](15);
        sels[0] = RingerHandler.warp.selector;
        sels[1] = RingerHandler.toBell.selector;
        sels[2] = RingerHandler.toBell.selector;
        sels[3] = RingerHandler.hostile.selector;
        sels[4] = RingerHandler.hostile.selector;
        sels[5] = RingerHandler.price.selector;
        sels[6] = RingerHandler.feed.selector;
        sels[7] = RingerHandler.topUp.selector;
        sels[8] = RingerHandler.ring.selector;
        sels[9] = RingerHandler.ring.selector;
        sels[10] = RingerHandler.ring.selector;
        sels[11] = RingerHandler.ringShort.selector;
        sels[12] = RingerHandler.push.selector;
        sels[13] = RingerHandler.stray.selector;
        sels[14] = RingerHandler.feed.selector;
        targetSelector(FuzzSelector(address(h), sels));
    }

    /// The ringer holds exactly what reached it less what it paid; never ETH
    function invariant_I28_purse() public view {
        assertEq(h.imd().balanceOf(address(h.r())), h.purseIn() - h.purseOut(), "ringer purse: purse != in - out");
        assertEq(address(h.r()).balance, 0, "ringer purse: the ringer holds ETH");
    }

    /// No bell that was due and unrung failed to ring, whatever the chores did
    function invariant_I29_aChoreNeverFailsTheBell() public view {
        assertEq(h.ringFailedWhenDue(), 0, "ringing: a due bell failed to ring");
    }

    /// a run that never rang, or never saw a chore fail, would pass these invariants vacuously
    function afterInvariant() public view {
        console2.log("(ringer stateful) days / rings / paid rings / chores skipped", h.daysSeen(), h.rings(), h.ringsPaid());
        console2.log("   ", h.choresSkipped());
        console2.log("   second rings refused / short-gas rings refused / pushes", h.secondRingsRefused(), h.shortGasRefused(), h.pushes());
        assertGt(h.rings(), 0, "vacuous: no ring in the run");
        assertGt(h.choresSkipped(), 0, "vacuous: no chore failed in the run");
    }
}
