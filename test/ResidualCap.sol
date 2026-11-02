// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {IERC20T} from "./Base.sol";
import {GasOps} from "./GasOps.sol";

/// The residual's bucket cap and the gas floor's worst case, on the band's own dense pool (a position at every bucket,
/// L = 1e20, so every bucket the residual crosses is an initialised tick it has never crossed).
abstract contract ResidualCap is GasOps {
    using StateLibrary for IPoolManager;

    int24 internal constant CAP_TICKS = 7_200; // RESIDUAL_MAX_BUCKETS (120) x 60

    PoolDonateTest internal donor;

    function setUp() public virtual override {
        super.setUp();
        donor = new PoolDonateTest(manager);
        _fundImd(address(this), 1e24);
        IERC20T(imd).approve(address(donor), type(uint256).max);
    }

    /// A 1-wei donate each way while the seed is in range: both fee growths non-zero, as on a pool that has traded both
    /// ways, so each tick the residual crosses writes two fresh fee-growth words.
    function _donateBoth(Mkt memory m) internal {
        m.coin.approve(address(donor), type(uint256).max);
        donor.donate(m.key, 1, 1, "");
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(m.key.toId());
        require(g0 > 0 && g1 > 0, "harness: both fee growths non-zero");
    }

    /// The heavy order of _denseBand's book (the buyer up, the seller down): its id, the last placed.
    function _heavyId(Mkt memory m) internal view returns (uint256) {
        return m.hook.nextOrderId() - 1;
    }

    /// Claims `id` as `who` and returns (out, refund, the unfilled-order fee it was charged: 0 if none was emitted).
    function _claimLogged(Mkt memory m, address who, uint256 id) internal returns (uint256 out, uint256 refund, uint256 unfilledFee) {
        vm.recordLogs();
        vm.prank(who);
        m.hook.claim(id);
        Vm.Log[] memory ls = vm.getRecordedLogs();
        for (uint256 i; i < ls.length; ++i) {
            if (ls[i].emitter != address(m.hook) || ls[i].topics.length < 2 || uint256(ls[i].topics[1]) != id) continue;
            if (ls[i].topics[0] == MarketHoursHook.UnfilledFeeTaken.selector) (, unfilledFee) = abi.decode(ls[i].data, (bool, uint256));
            if (ls[i].topics[0] == MarketHoursHook.Claimed.selector) (out, refund) = abi.decode(ls[i].data, (uint256, uint256));
        }
    }

    // ═════ the cap binds, both ways ═════
    /// The band's dense pool, the book clearing at its edge (P* = +/-12,000, fee-inward ~11,880): the residual would cross
    /// ~198 buckets; the cap stops it 120 buckets from spot (0), at tick +/-7,200 to within a wei of sqrt price. Its 900-coin
    /// / 900-IMD residual is far more than those 120 buckets hold, so part of it is unfilled: that part comes back to the
    /// heavy order without the unfilled-order fee. The light order fills whole.
    function _capBinds(bool up) internal {
        Mkt memory m = _denseBand(up, up ? 0x3481 : 0x3482);
        uint256 heavy = _heavyId(m);
        m.hook.ringOpen();
        (int24 p, bool rung, bool buyHeavy,,, uint64 rf) = m.hook.bells(2 * D);
        assertTrue(rung, "rung");
        assertEq(buyHeavy, up, "the heavy side is the residual's");
        assertEq(p, up ? int24(12_000) : int24(-12_000), "P* at the band's edge, beyond the cap");
        int24 t = _tick(m);
        console2.log(up ? "(H-cap) up: tick after / residualFill" : "(H-cap) down: tick after / residualFill", vm.toString(t), uint256(rf));
        // the cap is sqrt(1.0001)^7,200 times spot's sqrt price (2^96 here) to within a wei, so the pool ends on tick 7,200
        // or the one below it; a cap one bucket off (119 or 121) ends 60 ticks away
        if (up) {
            assertTrue(t == CAP_TICKS || t == CAP_TICKS - 1, "the buy residual stopped at the cap, +7,200");
        } else {
            assertTrue(t == -CAP_TICKS || t == -CAP_TICKS - 1, "the sell residual stopped at the cap, -7,200");
        }
        assertGt(rf, 0, "the residual filled in part");
        assertLt(rf, 1e18, "the residual did not fill whole: the cap left part of it");
        (uint8 ru,) = m.hook.charges(2 * D);
        assertTrue(ru & 4 != 0, "the cap was the nearer limit, flagged (Charge.roundUp bit 2)");
        (uint256 out, uint256 refund, uint256 fee) = _claimLogged(m, makeAddr(up ? "buyer" : "seller"), heavy);
        console2.log("(H-cap) heavy order claim: out / refund / unfilled-order fee", out, refund, fee);
        assertGt(out, 0, "the heavy order got what the book and the residual filled");
        assertGt(refund, 0, "and the cap's remainder back");
        assertEq(fee, 0, "no unfilled-order fee on the cap's remainder");
        (,, uint256 lightFee) = _claimLogged(m, makeAddr(up ? "seller" : "buyer"), heavy - 1);
        assertEq(lightFee, 0, "the light order filled whole");
    }

    function test_H_capBindsUpRemainderFeeFree() public {
        _capBinds(true);
    }

    /// The waiver where no other rule spares the order. In _capBinds the heavy order sits at P* with a marginal fill above
    /// zero, so the marginal exception already spares it; here nothing does. A one-sided buy book clears at the
    /// reference with zero matches (test_U_reachedSideUnfilledPaysTheFee), so the order at P* has no book fill,
    /// is not rationed, and all of it is residual. An overnight exit (outside the session, so the reference stays at
    /// initialisation's 0) took spot ~200 buckets below it, so the cap is the nearer limit and leaves most of the order
    /// unfilled: that part comes back without the unfilled-order fee. Before the cap the same order paid it.
    function test_H_capRemainderFeeFreeWhereNoBookRuleSparesIt() public {
        Mkt memory m = _market(0x3485, type(MarketHoursHook).creationCode, 60, 1e20);
        _fundImd(address(this), 1_000e18);
        for (int24 b = 60; b < 12_000; b += 60) {
            lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b, b + 60, 1e20, 0), "");
        }
        for (int24 b = 0; b > -12_000; b -= 60) {
            lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b - 60, b, 1e20, 0), "");
        }
        _at(D, 1 hours);
        vm.prank(trader);
        m.hook.emergencyExit(82e18, 0);
        int24 spot = _tick(m);
        assertLt(spot, -11_000, "precondition: the exit took spot below -11,000");
        int24 ref = m.hook.referenceOf(2 * D);
        assertEq(ref, 0, "precondition: the reference is still initialisation's");
        address bu = _player(m, "buyer", 1_000e18, 0);
        uint256 id = _orderAs(m, bu, 2 * D, true, ref, 900e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p, bool rung, bool buyHeavy,, uint64 marg, uint64 rf) = m.hook.bells(2 * D);
        assertTrue(rung && buyHeavy && p == ref && marg == 0, "precondition: zero matches at the reference, no book fill");
        int24 t = _tick(m);
        console2.log("(H-waiver) spot before / tick after / residualFill", vm.toString(spot), vm.toString(t), uint256(rf));
        // spot's sqrt price times sqrt(1.0001)^7,200, to within a wei: 7,200 ticks on, or the one below
        assertTrue(t >= spot + CAP_TICKS - 1 && t <= spot + CAP_TICKS, "the residual stopped at the cap, spot + 7,200");
        assertGt(rf, 0, "the residual filled in part");
        assertLt(rf, 1e18, "the cap left part of it");
        (uint256 out, uint256 refund, uint256 fee) = _claimLogged(m, bu, id);
        console2.log("(H-waiver) claim: out / refund / unfilled-order fee", out, refund, fee);
        assertGt(out, 0, "the order got what the residual filled");
        assertGt(refund, 0, "and the cap's remainder back");
        assertEq(fee, 0, "no unfilled-order fee on the cap's remainder");
    }

    function test_H_capBindsDownRemainderFeeFree() public {
        _capBinds(false);
    }

    // ═════ a normal day is unchanged ═════
    /// The same dense pool, the book clearing 50 buckets from spot: P*'s fee-inward limit is nearer than the cap, so the
    /// cap must change nothing. Every figure of the ring and both claims is logged.
    function _normalDay(bool up) internal {
        Mkt memory m = _market(up ? 0x3483 : 0x3484, type(MarketHoursHook).creationCode, 60, 1e20);
        if (up) {
            for (int24 b = 60; b < 12_000; b += 60) {
                lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b, b + 60, 1e20, 0), "");
            }
        } else {
            _fundImd(address(this), 1_000e18);
            for (int24 b = 0; b > -12_000; b -= 60) {
                lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b - 60, b, 1e20, 0), "");
            }
        }
        address se = _player(m, "seller", 0, 1_000e18);
        address bu = _player(m, "buyer", 1_000e18, 0);
        _at(D, 1 hours);
        uint256 a;
        uint256 b2;
        if (up) {
            a = _orderAs(m, se, 2 * D, false, 0, 1e18);
            b2 = _orderAs(m, bu, 2 * D, true, 3_000, 900e18);
        } else {
            a = _orderAs(m, bu, 2 * D, true, 0, 1e18);
            b2 = _orderAs(m, se, 2 * D, false, -3_000, 900e18);
        }
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p, bool rung, bool buyHeavy, uint64 inner, uint64 marg, uint64 rf) = m.hook.bells(2 * D);
        (uint8 ru, uint64 rup) = m.hook.charges(2 * D);
        string memory tag = up ? "(H-normal) up" : "(H-normal) down";
        console2.log(tag, "pStar / tick after", vm.toString(p), vm.toString(_tick(m)));
        console2.log(tag, "rung / buyHeavy", rung, buyHeavy);
        console2.log(string.concat(tag, " innerFill / marginalFill / residualFill"), uint256(inner), uint256(marg), uint256(rf));
        console2.log(string.concat(tag, " roundUp / residualUp"), uint256(ru), uint256(rup));
        assertTrue(ru < 4, "the cap was not the nearer limit, so no cap flag");
        assertTrue(up ? _tick(m) < CAP_TICKS - 60 : _tick(m) > -CAP_TICKS + 60, "the residual stopped short of the cap");
        (uint256 o1, uint256 r1, uint256 f1) = _claimLogged(m, up ? se : bu, a);
        (uint256 o2, uint256 r2, uint256 f2) = _claimLogged(m, up ? bu : se, b2);
        console2.log(string.concat(tag, " light claim: out / refund / unfilled fee"), o1, r1, f1);
        console2.log(string.concat(tag, " heavy claim: out / refund / unfilled fee"), o2, r2, f2);
        console2.log(tag, "burnAccrued / coinBurnAccrued", m.hook.burnAccrued(), m.hook.coinBurnAccrued());
        console2.log(tag, "hook IMD / coin after the claims", IERC20T(imd).balanceOf(address(m.hook)), m.coin.balanceOf(address(m.hook)));
    }

    function test_H_normalDayUp() public {
        _normalDay(true);
    }

    function test_H_normalDayDown() public {
        _normalDay(false);
    }

    // ═════ the floor's worst case, cap-bounded ═════
    /// On the REAL hook (floor BELL_GAS_FLOOR): the worst clamp-bounded case rings at the floor, directly and through the
    /// ringer. The least gas that rings and fills is set by the floor's own check (plus what runs before it), not by the
    /// bell's work: within 100,000 above the floor; through the ringer, above the ringer's own minimum (the floor plus
    /// the opening chores' gas, which it checks at entry).
    function _ringsAtTheFloor(bool up, bool viaRinger) internal {
        Mkt memory m = _denseBand(up, (up ? 0x34a0 : 0x34a1) + (viaRinger ? 2 : 0));
        _donateBoth(m);
        BellRinger r = _ringer(m);
        uint256 floor = viaRinger ? r.bellGasFloor() + r.CHORE_GAS_OPEN() : m.hook.BELL_GAS_FLOOR();
        require(r.bellGasFloor() == m.hook.BELL_GAS_FLOOR(), "harness: the ringer is handed the hook's floor");
        uint256 snap = vm.snapshotState();
        uint256 lo = 1_000_000;
        uint256 hi = 60_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(snap);
            _coolAll(m);
            vm.cool(address(r));
            (bool ok,) = viaRinger
                ? address(r).call{gas: mid}(abi.encodeCall(BellRinger.ring, ()))
                : address(m.hook).call{gas: mid}(abi.encodeCall(MarketHoursHook.ringOpen, ()));
            (, bool rung,,,, uint64 rf) = m.hook.bells(2 * D);
            if (ok && rung && rf > 0) hi = mid;
            else lo = mid;
        }
        vm.revertToState(snap);
        _coolAll(m);
        vm.cool(address(r));
        (bool ok2,) = viaRinger
            ? address(r).call{gas: hi}(abi.encodeCall(BellRinger.ring, ()))
            : address(m.hook).call{gas: hi}(abi.encodeCall(MarketHoursHook.ringOpen, ()));
        (, bool rung2,,,, uint64 rf2) = m.hook.bells(2 * D);
        console2.log(viaRinger ? "(H-atfloor) ringer.ring()" : "(H-atfloor) ringOpen()", up ? "up" : "down");
        console2.log("   floor (ringer: + opening chores) / least call gas that rings and fills / over it", floor, hi, hi > floor ? hi - floor : 0);
        assertTrue(ok2 && rung2 && rf2 > 0, "at its least gas the worst case rings and fills");
        assertLt(hi, floor + 100_000, "the worst clamp-bounded ring needs no more than the floor");
    }

    function test_H_ringsAtTheFloorUp() public {
        _ringsAtTheFloor(true, false);
    }

    function test_H_ringsAtTheFloorDown() public {
        _ringsAtTheFloor(false, false);
    }

    function test_H_ringerRingsAtTheFloorUp() public {
        _ringsAtTheFloor(true, true);
    }

    function test_H_ringerRingsAtTheFloorDown() public {
        _ringsAtTheFloor(false, true);
    }
}
