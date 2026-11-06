// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {BellRinger} from "src/BellRinger.sol";
import {IERC20T} from "../Base.sol";
import {ReproBase} from "../repro/ReproBase.sol";

// ── the audit's own harness for finding 1 (its attached proof, imports adjusted only) ──
contract Tkn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract RingerHook {
    function bells(uint256) external pure returns (int24, bool) { return (0, false); }
    function ringOpen() external {}
    function ringClose() external {}
    fallback() external payable {}
}

contract Mgr {
    bytes32 public slot;
    bytes32 public word;
    function set(bytes32 s, bytes32 w) external { slot = s; word = w; }
    function extsload(bytes32 s) external view returns (bytes32) { return s == slot ? word : bytes32(0); }
}

/// Audit 3, finding 1, ACCEPTED: no change to the reward's pricing. The ringer stores the raw spot its own transaction
/// read, so a ring made with the ETH/IMD pool moved the same way twice running is paid at the moved price on the
/// second, up to the 3 IMD cap. Moving the pool and moving it back costs the mover the pool's fee on both legs, and
/// nobody can trade between the two legs, so the residual is accepted and recorded. This is the audit's proof harness;
/// the test asserts the ACCEPTED behaviour and pins it (the moved close is paid the honest stored price; the next ring
/// at the moved spot pays the cap), so it PASSES here and would fail if the pricing changed. The two-rings test in
/// test/RingerPrice.sol stays as it is.
contract AuditThreeFinding1Test is Test {
    Tkn internal imd;
    RingerHook internal hook;
    Mgr internal mgr;
    BellRinger internal r;

    uint256 internal constant DAY = 20_400;
    uint256 internal constant OPEN = 43_200;
    uint256 internal constant CLOSE = 57_600;
    uint256 internal constant HONEST_X = 20; // sqrt price 20 x 2^96: 400 IMD per ETH
    uint256 internal constant MOVED_X = 1_000; // 1,000,000 IMD per ETH

    function setUp() public {
        imd = new Tkn();
        hook = new RingerHook();
        mgr = new Mgr();
        r = new BellRinger(address(hook), address(this), address(this), address(this), address(imd), address(mgr), 7, 0);
        imd.mint(address(r), 1_000e18);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        vm.warp(DAY * 1 days + OPEN);
        vm.roll(1);
    }

    function _price(uint256 x) internal {
        mgr.set(keccak256(abi.encode(r.ethImdPoolId(), bytes32(uint256(6)))), bytes32(x << 96));
    }

    function _ring() internal returns (uint256 paid) {
        vm.recordLogs();
        r.ring{gas: 3_000_000}();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.Rewarded.selector) {
                (paid,) = abi.decode(lg[i].data, (uint256, bool));
                return paid;
            }
        }
        fail();
    }

    function _open(uint256 d, uint256 x) internal returns (uint256) {
        vm.warp(d * 1 days + OPEN);
        vm.roll(block.number + 1);
        _price(x);
        return _ring();
    }

    function _close(uint256 d, uint256 x) internal returns (uint256) {
        vm.warp(d * 1 days + CLOSE);
        vm.roll(block.number + 1);
        _price(x);
        return _ring();
    }

    /// ACCEPTED: the audit's scenario with the accepted outcome asserted. The audit's version asserted n1 == n0.
    function test_A3F1_accepted_twoRingsPayTheMovedPriceOnTheSecond() public {
        uint256 snap = vm.snapshotState();

        // honest path: open 400, close 400, next open 400
        uint256 o0 = _open(DAY, HONEST_X);
        uint256 c0 = _close(DAY, HONEST_X);
        uint256 n0 = _open(DAY + 1, HONEST_X);
        assertGt(n0, 0, "precondition: the honest next open is paid");

        vm.revertToState(snap);

        // moved path: the close is rung at 1,000,000 IMD/ETH
        uint256 o1 = _open(DAY, HONEST_X);
        uint256 c1 = _close(DAY, MOVED_X);
        uint256 n1 = _open(DAY + 1, MOVED_X);

        emit log_named_uint("honest next open (wei IMD)", n0);
        emit log_named_uint("moved close (wei IMD)", c1);
        emit log_named_uint("moved next open (wei IMD)", n1);
        assertEq(o0, o1, "the open is the same");
        assertEq(c0, c1, "the moved close is paid the last ring's honest price");
        // the accepted residual: the moved close stored its own read, so the next ring at the moved spot pays the cap
        assertGt(n1, n0, "the second moved ring running is paid more than the honest ring");
        assertEq(n1, r.RING_REWARD_CAP(), "the second moved ring running pays the cap, 3 IMD");
    }
}

/// Calls BellRinger.ring() from inside its own PoolManager unlock (where a swap could sit before and after it).
contract RingInsideUnlock is IUnlockCallback {
    IPoolManager internal immutable manager;
    address internal ringer;

    constructor(IPoolManager m) {
        manager = m;
    }

    function go(address r) external {
        ringer = r;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        BellRinger(payable(ringer)).ring{gas: 13_000_000}();
        return "";
    }
}

/// Audit 3, finding 1, extra (kept as the record of the accepted residual): once the bell has been rung straight at
/// the hook, ring() skips the hook, so the hook's PoolUnlocked guard never runs and ring() pays from inside a
/// PoolManager unlock. A swap before and after it in that unlock settles only the net, so the move needs no capital of
/// its own, only the fee. Both tests PASS on every build; they pin that path.
contract AuditThreeFinding1InsideUnlockTest is ReproBase {
    /// the ETH/IMD pool at the ringer's key in the offline PoolManager, at 100 IMD per ETH (no liquidity needed for
    /// the price read), a purse, and a 1 gwei base fee; returns the ringer
    function _ringerWithPrice() internal returns (BellRinger r) {
        r = _ringer(mkt);
        manager.initialize(PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 200, IHooks(address(0))), uint160(10 << 96));
        _fundImd(address(r), 100e18);
        vm.fee(1 gwei);
    }

    function _paidIn(Vm.Log[] memory lg, address r) internal pure returns (bool found, uint256 paid) {
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == r && lg[i].topics[0] == BellRinger.Rewarded.selector) {
                (paid,) = abi.decode(lg[i].data, (uint256, bool));
                found = true;
            }
        }
    }

    /// FIGURES: the bell rung straight at the hook first, then ring() from INSIDE an unlock: the ringer skips the hook
    /// (already rung), so the hook's PoolUnlocked guard never runs; chores run (harvest refuses inside an unlock and is
    /// skipped) and the reward is paid at the spot read inside the unlock.
    function test_A3F1x_measure_ringerPaysInsideAnUnlockAfterADirectRing() public {
        BellRinger r = _ringerWithPrice();
        RingInsideUnlock u = new RingInsideUnlock(manager);
        _at(D, OPEN);
        mkt.hook.ringOpen(); // anyone, outside any unlock
        vm.recordLogs();
        vm.prank(address(0xA77), address(0xA77));
        (bool ok, bytes memory e) = address(u).call(abi.encodeCall(RingInsideUnlock.go, (address(r))));
        (bool found, uint256 paid) = _paidIn(vm.getRecordedLogs(), address(r));
        console2.log(string.concat("ring() inside an unlock after a direct ring: ", _why(ok, e)));
        console2.log("Rewarded emitted / paid (wei IMD)", found ? 1 : 0, paid);
        console2.log("paid to the unlocker contract", IERC20T(imd).balanceOf(address(u)));
        assertTrue(ok && found && paid > 0, "ring() paid inside an unlock");
    }

    /// CONTROL: with the bell NOT yet rung, ring() from inside an unlock reaches the hook, which refuses (PoolUnlocked).
    function test_A3F1x_control_ringerInsideAnUnlockRefusedWhenItMustRing() public {
        BellRinger r = _ringerWithPrice();
        RingInsideUnlock u = new RingInsideUnlock(manager);
        _at(D, OPEN);
        (bool ok, bytes memory e) = address(u).call(abi.encodeCall(RingInsideUnlock.go, (address(r))));
        console2.log(string.concat("ring() inside an unlock, bell not rung: ", _why(ok, e)));
        assertFalse(ok);
        assertTrue(_has(e, MarketHoursHook.PoolUnlocked.selector), "refused by the hook's PoolUnlocked");
    }
}
