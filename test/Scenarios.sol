// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {Base, IERC20T} from "./Base.sol";

/// The bell scenarios: gas on a full band, the three rings behind strict accounting and the residual price, the settle
/// window, the stale reference. Environment-agnostic.
abstract contract Scenarios is Base {
    // ── bell gas on a full band (the gas floor's basis) ──
    /// Overnight book 2D: `nSells` sell orders of 0.6 coin spread over the buckets below the reference and `nBuys` buy
    /// orders of 1.2 IMD spread over those above. Buys outweigh sells, so the bell also runs its residual swap. A book of
    /// 200+ orders a side fills buckets 1..200 (the full band); a smaller one starts 3 buckets out, because a P* less than
    /// ~126 ticks from spot leaves no room inside the fee-moved limit and the residual swap would not run.
    function _fillBook(MarketHoursHook hook, uint256 s, uint256 nSells, uint256 nBuys) internal {
        int24 ref = hook.referenceOf(s);
        vm.startPrank(trader);
        for (uint256 i; i < nSells; ++i) {
            hook.placeOrder(s, false, ref - _k(i, nSells) * 60, 0.6e18);
        }
        for (uint256 i; i < nBuys; ++i) {
            hook.placeOrder(s, true, ref + _k(i, nBuys) * 60, 1.2e18);
        }
        vm.stopPrank();
    }

    function _k(uint256 i, uint256 n) internal pure returns (int24) {
        return int24(int256(n >= 200 ? 1 + (i * 200) / n : 3 + (i * 198) / n));
    }

    function _bellGasOpen(uint256 nSells, uint256 nBuys) internal returns (uint256 used, Mkt memory m) {
        m = mkt;
        _at(D, 1 hours); // 01:00 of D: closeSettled(D-1) holds by time, book 2D is enterable
        _fillBook(m.hook, 2 * D, nSells, nBuys);
        _at(D, OPEN);
        _nextBlock();
        _coolAll(m);
        uint256 g = gasleft();
        m.hook.ringOpen();
        used = g - gasleft();
        (int24 p, bool rung,,,, uint64 rf) = m.hook.bells(2 * D);
        assertTrue(rung, "bell rang");
        assertGt(rf, 0, "the residual swap ran (a non-zero residual fill)");
        console2.log("  P* bucket", p);
    }

    function test_d_bellGasFullBandOpen() public {
        (uint256 used, Mkt memory m) = _bellGasOpen(200, 200);
        console2.log("(d) ringOpen gas, full BAND (200 sell + 200 buy orders, 1 per bucket), cold:", used);
        console2.log("(d) floor candidate = 2 x", used * 2);
        console2.log("(d) BELL_GAS_FLOOR / half of it", m.hook.BELL_GAS_FLOOR(), m.hook.BELL_GAS_FLOOR() / 2);
        assertLe(2 * used, m.hook.BELL_GAS_FLOOR(), "the full-band opening ring is at most half the floor");
    }

    function test_d_bellGasOrders2() public {
        (uint256 used,) = _bellGasOpen(1, 1);
        console2.log("(d, gas floor) ringOpen gas, 2 orders, cold:", used);
    }

    function test_d_bellGasOrders1000() public {
        (uint256 used,) = _bellGasOpen(500, 500);
        console2.log("(d, gas floor) ringOpen gas, 1,000 orders, cold:", used);
    }

    function test_d_bellGasFullBandClose() public {
        (, Mkt memory m) = _bellGasOpen(200, 200);
        _at(D, OPEN + 5 minutes);
        _fillBook(m.hook, 2 * D + 1, 200, 200);
        _at(D, CLOSE);
        _nextBlock();
        _coolAll(m);
        uint256 g = gasleft();
        m.hook.ringClose();
        uint256 used = g - gasleft();
        (, bool rung,,,, uint64 rf) = m.hook.bells(2 * D + 1);
        assertTrue(rung, "close rang");
        assertGt(rf, 0, "the closing residual swap ran");
        console2.log("(d) ringClose gas, full BAND (200 sell + 200 buy orders), cold:", used);
        console2.log("(d) close floor candidate = 2 x", used * 2);
    }

    // ── the hook's own residual swap inside unlock, limited at the P* edge moved inward by the LP fee ──
    struct Res {
        int24 p;
        bool buyHeavy;
        uint64 rf;
        uint256 spent;
        uint256 got;
        uint256 atP;
        uint256 surplus;
        int24 tickBefore;
        int24 tickAfter;
    }

    function _ringRead(Mkt memory m, uint256 s, bool open) internal returns (Res memory r) {
        uint256 i0 = IERC20T(imd).balanceOf(address(m.hook));
        uint256 c0 = m.coin.balanceOf(address(m.hook));
        uint256 b0 = m.hook.burnAccrued();
        r.tickBefore = _tick(m);
        if (open) m.hook.ringOpen();
        else m.hook.ringClose();
        r.tickAfter = _tick(m);
        uint256 i1 = IERC20T(imd).balanceOf(address(m.hook));
        uint256 c1 = m.coin.balanceOf(address(m.hook));
        bool rung;
        (r.p, rung, r.buyHeavy,,, r.rf) = m.hook.bells(s);
        assertTrue(rung, "rung");
        uint160 sp = TickMath.getSqrtPriceAtTick(r.p);
        if (r.buyHeavy) {
            (r.spent, r.got) = (i0 - i1, c1 - c0);
            r.atP = FullMath.mulDiv(FullMath.mulDiv(r.got, sp, 1 << 96), sp, 1 << 96);
        } else {
            (r.spent, r.got) = (c0 - c1, i1 - i0);
            r.atP = FullMath.mulDiv(FullMath.mulDiv(r.spent, sp, 1 << 96), sp, 1 << 96);
        }
        r.surplus = m.hook.burnAccrued() - b0;
    }

    function _assertI18(Res memory r, string memory label) internal {
        console2.log(label);
        console2.log("  P* bucket", int256(r.p));
        console2.log("  buyHeavy", r.buyHeavy);
        console2.log("  pool tick before the ring", int256(r.tickBefore));
        console2.log("  pool tick after the ring", int256(r.tickAfter));
        console2.log("  residualFill (1e18 = all)", uint256(r.rf));
        console2.log("  hook paid the pool, LP fee included / received (wei)", r.spent, r.got);
        console2.log("  residual leg at exactly P*, IMD (wei) / surplus -> burnAccrued (wei)", r.atP, r.surplus);
        if (r.buyHeavy) {
            assertLe(r.spent, r.atP, "residual price: buy residual paid more than price(P*) per coin, fee included (hook short)");
            assertEq(r.surplus, r.atP - r.spent, "residual price: surplus booked = P* value - paid");
        } else {
            assertGe(r.got, r.atP, "residual price: sell residual received less than price(P*) per coin, fee included (hook short)");
            assertEq(r.surplus, r.got - r.atP, "residual price: surplus booked = received - P* value");
        }
    }

    /// After a ring every order of it is claimed; then the IMD and coin accounting checks. With nothing unclaimed and nothing unharvested the hook's
    /// balance must equal what it accounts for (asserted always), and what it accounts for must cover every accrual:
    ///  - fee scale (`strict` false): |accounted - accruals| <= DUST_BOUND each way.
    ///  - strict (`strict` true): accounted >= accruals to the wei, "never short", and every claim succeeds. Claims are
    ///    tried, not required, so all three rings are logged; the failures and the largest shortfall are asserted once.
    uint256 internal constant DUST_BOUND = 1e6;
    uint256 internal strictShortImd;
    uint256 internal strictShortCoin;
    uint256 internal strictClaimReverts;

    function _owedImd(Mkt memory m) internal view returns (uint256) {
        return m.hook.burnAccrued() + m.hook.networkAccrued() + m.hook.feeWalletImdAccrued() + m.hook.swarmAccrued()
            + m.hook.bellPurseAccrued() + m.hook.dustImd() + m.hook.reserveImd();
    }

    function _owedCoin(Mkt memory m) internal view returns (uint256) {
        return m.hook.coinBurnAccrued() + m.hook.feeWalletCoinAccrued() + m.hook.dustCoin() + m.hook.reserveCoin();
    }

    function _claimAllAndI1(Mkt memory m, uint256[] memory ids, bool strict) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (!strict) {
                m.hook.claim(ids[i]);
                continue;
            }
            try m.hook.claim(ids[i]) {}
            catch (bytes memory e) {
                ++strictClaimReverts;
                console2.log("  CLAIM REVERTED, order id", ids[i]);
                console2.logBytes(e);
            }
        }
        uint256 owedImd = _owedImd(m);
        uint256 owedCoin = _owedCoin(m);
        uint256 accImd = m.hook.imdAccounted();
        uint256 accCoin = m.hook.coinAccounted();
        console2.log("  IMD accounting after the claims: IMD balance / accounted / accruals owed", IERC20T(imd).balanceOf(address(m.hook)), accImd, owedImd);
        console2.log("  coin accounting after the claims: coin balance / accounted / accruals owed", m.coin.balanceOf(address(m.hook)), accCoin, owedCoin);
        console2.log("  IMD accounting signed remainder IMD (accounted - accruals, wei)", int256(accImd) - int256(owedImd));
        console2.log("  coin accounting signed remainder coin (accounted - accruals, wei)", int256(accCoin) - int256(owedCoin));
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), accImd, "IMD accounting: IMD balance != accounted (unaccounted flow)");
        assertEq(m.coin.balanceOf(address(m.hook)), accCoin, "coin accounting: coin balance != accounted (unaccounted flow)");
        if (strict) {
            if (owedImd > accImd && owedImd - accImd > strictShortImd) strictShortImd = owedImd - accImd;
            if (owedCoin > accCoin && owedCoin - accCoin > strictShortCoin) strictShortCoin = owedCoin - accCoin;
            return;
        }
        if (owedImd > accImd) assertLe(owedImd - accImd, DUST_BOUND, "IMD accounting: IMD accruals exceed the IMD the hook holds beyond dust");
        else assertLe(accImd - owedImd, DUST_BOUND, "IMD accounting: IMD left over beyond dust");
        if (owedCoin > accCoin) assertLe(owedCoin - accCoin, DUST_BOUND, "coin accounting: coin accruals exceed the coin the hook holds beyond dust");
        else assertLe(accCoin - owedCoin, DUST_BOUND, "coin accounting: coin left over beyond dust");
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function test_e_I18_residualNeverShort() public {
        _ringsE(false, false, true);
    }

    function test_e_I1_feeScale() public {
        _ringsE(true, false, false);
    }

    /// strict IMD accounting and claim liveness on all three rings with the reserve at zero: never short to the wei, every claim
    /// succeeds.
    function test_e_I1_strictNeverShort() public {
        _ringsE(true, true, true);
        console2.log("(e) strict IMD accounting: claim reverts over the three rings", strictClaimReverts);
        console2.log("(e) strict IMD accounting: largest IMD / coin shortfall after a ring's claims (wei)", strictShortImd, strictShortCoin);
        assertEq(strictClaimReverts, 0, "strict accounting and claims: a claim reverted (the hook was short of what it owed)");
        assertEq(strictShortImd, 0, "strict IMD accounting: the hook was short of IMD after a ring's claims (wei)");
        assertEq(strictShortCoin, 0, "strict coin accounting: the hook was short of coin after a ring's claims (wei)");
    }

    function test_e_I1_seededStrictNeverShort() public {
        vm.prank(trader);
        mkt.hook.seedDust(1e15, 1e15);
        assertEq(mkt.hook.reserveImd(), 1e15, "reserve IMD booked");
        assertEq(mkt.hook.reserveCoin(), 1e15, "reserve coin booked");
        test_e_I1_strictNeverShort();
    }

    function test_e_I1_seedDustNotHarvestable() public {
        Mkt memory m = mkt;
        uint256 b0 = m.hook.burnAccrued();
        uint256 f0 = m.hook.feeWalletCoinAccrued();
        uint256 cb0 = m.hook.coinBurnAccrued();
        vm.prank(trader);
        m.hook.seedDust(1e15, 1e15);
        m.hook.harvest();
        assertEq(m.hook.burnAccrued(), b0, "harvest folded the IMD reserve into the burn");
        assertEq(m.hook.swarmAccrued(), 0, "harvest folded the IMD reserve into the swarm slice");
        assertEq(m.hook.bellPurseAccrued(), 0, "harvest folded the IMD reserve into the bell purse slice");
        assertEq(m.hook.feeWalletCoinAccrued(), f0, "harvest folded the coin reserve into the fee wallet");
        assertEq(m.hook.coinBurnAccrued(), cb0, "harvest folded the coin reserve into the coin burn");
        assertEq(m.hook.reserveImd(), 1e15, "reserve IMD untouched");
        assertEq(m.hook.reserveCoin(), 1e15, "reserve coin untouched");
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), m.hook.imdAccounted(), "IMD balance = accounted");
        assertEq(m.coin.balanceOf(address(m.hook)), m.hook.coinAccounted(), "coin balance = accounted");
    }

    /// Three rings on the shared seed (pool ticks [0, 12000), L = 1e23, spot at tick 0):
    ///   B1  open, P* = bucket 60, inside the fee of spot: the fee-moved limit is behind spot, so nothing fills;
    ///   B2  open, P* = bucket 300: the residual fills until the fee-moved limit binds, partly (buy-heavy, residual-heavy);
    ///   S   the close after B2, P* = bucket 0, sell-heavy: coin sold into the IMD B2 left in the pool.
    function _ringsE(bool claims, bool strict, bool withS) internal {
        Mkt memory m = mkt;
        uint256 snap = vm.snapshotState();

        // B1
        _at(D, 1 hours);
        uint256 s1 = _order(m, 2 * D, false, -60, 10e18);
        uint256 b1 = _order(m, 2 * D, true, 60, 980e18);
        _at(D, OPEN);
        _nextBlock();
        vm.prank(trader);
        try router.swap(
            m.key, IPoolManager.SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        ) {
            fail("router swap before the ring must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.AwaitingBell.selector), "refused for the wrong reason");
        }
        Res memory r = _ringRead(m, 2 * D, true);
        assertEq(r.p, 60, "B1 precondition: P* = bucket 60");
        assertTrue(r.buyHeavy, "B1 precondition: buy-heavy");
        _assertI18(r, "(e) B1 open, P* bucket 60 (within the fee of spot)");
        if (claims) _claimAllAndI1(m, _ids2(s1, b1), strict);
        // revertToState also rewinds this contract's own storage, so B1's strict counters are carried across it
        (uint256 kRev, uint256 kImd, uint256 kCoin) = (strictClaimReverts, strictShortImd, strictShortCoin);
        vm.revertToState(snap);
        (strictClaimReverts, strictShortImd, strictShortCoin) = (kRev, kImd, kCoin);

        // B2
        _at(D, 1 hours);
        s1 = _order(m, 2 * D, false, -60, 10e18);
        b1 = _order(m, 2 * D, true, 300, 980e18);
        _at(D, OPEN);
        _nextBlock();
        r = _ringRead(m, 2 * D, true);
        assertEq(r.p, 300, "B2 precondition: P* = bucket 300");
        assertTrue(r.buyHeavy, "B2 precondition: buy-heavy");
        assertGt(r.rf, 0, "B2 precondition: the residual filled (the residual price check is not vacuous)");
        assertLt(r.rf, 1e18, "B2 precondition: partly, so the limit and not the size stopped it");
        console2.log("(e) B2 limit binds: ticks inside P* at the stop", int256(r.p) - int256(r.tickAfter));
        _assertI18(r, "(e) B2 open, P* bucket 300");
        if (claims) _claimAllAndI1(m, _ids2(s1, b1), strict);
        if (!withS) return;

        // S
        _at(D, OPEN + 5 minutes);
        uint256 b2 = _order(m, 2 * D + 1, true, 0, 20e18);
        uint256 s2 = _order(m, 2 * D + 1, false, 0, 900e18);
        _at(D, CLOSE);
        _nextBlock();
        r = _ringRead(m, 2 * D + 1, false);
        assertEq(r.p, 0, "S precondition: P* = bucket 0");
        assertFalse(r.buyHeavy, "S precondition: sell-heavy");
        assertGt(r.rf, 0, "S precondition: the residual filled (the residual price check is not vacuous)");
        console2.log("(e) S limit binds: ticks inside P* at the stop", int256(r.tickAfter) - int256(r.p));
        _assertI18(r, "(e) S close, P* bucket 0, sell residual");
        if (claims) _claimAllAndI1(m, _ids2(b2, s2), strict);
    }

    // ── stale reference ──
    function test_I17_staleReference() public {
        Mkt memory m = mkt;
        int24 ref0 = m.hook.lastCleared();
        assertEq(ref0, 0, "reference before the first bell = the launch's initial tick bucket");
        _at(D, OPEN);
        (, uint16 c0) = _counters(m);
        assertEq(c0, 0, "no checkpoint before the first session");
        m.hook.ringOpen();
        assertEq(m.hook.lastCleared(), ref0, "open, zero matches, tickCount 0: lastCleared unchanged");
        int256 sum;
        for (uint256 i; i < 3; ++i) {
            _nextBlock();
            sum += _tick(m);
            _swap(m, true, 1_000e18);
        }
        (int48 s1, uint16 c1) = _counters(m);
        assertEq(c1, 3, "three blocks with swaps counted");
        assertEq(int256(s1), sum, "tickSum = sum of the three checkpoint ticks");
        int24 expectP = _nearest(sum / 3);
        assertTrue(expectP != ref0, "the session moved the mean off the reference (test precondition)");
        _at(D, CLOSE);
        m.hook.ringClose();
        assertEq(m.hook.lastCleared(), expectP, "close, zero matches: lastCleared = nearest bucket of tickSum/tickCount");
        (int48 s2, uint16 c2) = _counters(m);
        assertEq(c2, 0, "tickCount reset at the ring");
        assertEq(int256(s2), 0, "tickSum reset at the ring");
        _at(D, CLOSE + 1 hours);
        _nextBlock();
        vm.prank(trader);
        m.hook.emergencyExit(2_500e18, 0);
        assertTrue(_nearest(_tick(m)) != expectP, "the exit moved spot to another bucket (test precondition)");
        (, uint16 c3) = _counters(m);
        assertEq(c3, 0, "the exit swap was not counted");
        _at(D + 1, OPEN);
        m.hook.ringOpen();
        assertEq(m.hook.lastCleared(), expectP, "open after an exit-only night: lastCleared unchanged");
    }
}
