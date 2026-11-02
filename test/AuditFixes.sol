// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {IERC20T} from "./Base.sol";
import {GasOps} from "./GasOps.sol";

/// Rings the open from inside its own PoolManager unlock.
contract ForeignUnlockRinger is IUnlockCallback {
    IPoolManager internal immutable manager;
    MarketHoursHook internal immutable hook;

    constructor(IPoolManager m, MarketHoursHook h) {
        manager = m;
        hook = h;
    }

    function ring() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        hook.ringOpen();
        return "";
    }
}

/// Calls the ringer's ring() from inside its own PoolManager unlock.
contract ForeignUnlockRingerCall is IUnlockCallback {
    IPoolManager internal immutable manager;
    BellRinger internal immutable ringer;

    constructor(IPoolManager m, BellRinger r) {
        manager = m;
        ringer = r;
    }

    function ring() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        ringer.ring();
        return "";
    }
}

/// The tests the audit's eleven fixes need beyond the audit's reproduction tests (test/repro), and a few figures.
abstract contract AuditFixes is GasOps {
    // ── Audit finding 1 (a): a ring inside somebody else's unlock is refused even when the bell has no residual ──
    function test_A1_ringInsideAForeignUnlockRefusedWithoutAResidual() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        (, uint256 matched,, uint256 residual) = m.hook.indicativePrice(2 * D);
        assertEq(matched + residual, 0, "precondition: an empty book, so the bell has no residual and never unlocks");
        ForeignUnlockRinger a = new ForeignUnlockRinger(manager, m.hook);
        (bool ok, bytes memory e) = address(a).call(abi.encodeCall(ForeignUnlockRinger.ring, ()));
        assertFalse(ok, "audit finding 1: a ring inside a foreign unlock is refused");
        assertTrue(_has(e, MarketHoursHook.PoolUnlocked.selector), "audit finding 1: refused as PoolUnlocked");
        (, bool rung,,,,) = m.hook.bells(2 * D);
        assertFalse(rung, "and the bell did not ring");
        // control: the same bell rung plainly rings
        m.hook.ringOpen();
        (, rung,,,,) = m.hook.bells(2 * D);
        assertTrue(rung, "control: a plain ring rings");
    }

    // ── Audit finding 2: the reference is held where its whole band is a valid price ──
    /// The harness pool has no liquidity below tick 0, so a dust sell in the session takes spot to the bottom of the tick
    /// range; the next block's first swap (a dust buy, back into the seed) checkpoints that price. The open after the
    /// night reads the last checkpoint's price (no swap since the close): the bottom of the range. Held to -875,220, the
    /// next book's band is a valid price and its bell rings; unheld, the band would leave the tick range and no bell
    /// could ring again.
    function test_A2_referenceHeldInsideTheTickRange() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
        _swap(m, false, 1e15);
        assertLt(_tick(m), -880_000, "precondition: the dust sell took spot to the bottom of the range");
        _nextBlock();
        _swap(m, true, 1e15);
        (, uint160 cpSp,,) = m.hook.checkpoint();
        assertLt(TickMath.getTickAtSqrtPrice(cpSp), -880_000, "precondition: the last checkpoint is at the bottom");
        _at(D, CLOSE);
        m.hook.ringClose();
        _at(D + 1, OPEN);
        m.hook.ringOpen();
        uint256 s = 2 * (D + 1) + 1; // day D + 1's closing book, opened by the bell just rung
        int24 ref = m.hook.referenceOf(s);
        console2.log("(A2) reference after a bottom-of-range checkpoint", int256(ref));
        assertEq(ref, -875_220, "audit finding 2: the reference is held where its whole band is a valid price");
        _order(m, s, true, ref, 1e18);
        _at(D + 1, CLOSE);
        m.hook.ringClose();
        (, bool rung,,,,) = m.hook.bells(s);
        assertTrue(rung, "audit finding 2: and the next bell still rings");
    }

    // ── Audit finding 3: the cap counts an order by its distance, and a cancel releases exactly what it counted ──
    function test_A3_countedByDistanceReleasedExactly() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        int24 ref = m.hook.referenceOf(2 * D);
        assertEq(ref, 0, "precondition: the reference is bucket 0, so a coin is worth one IMD there");
        uint256 far = _order(m, 2 * D, true, ref - 12_000, 1_000e18); // a tenth
        assertEq(m.hook.bookImdTotal(2 * D), 100e18, "audit finding 3: an order at the band's edge counts a tenth");
        uint256 mid = _order(m, 2 * D, false, ref + 6_000, 20e18); // (40,000 - 18,000) / 40,000 = 0.55
        assertEq(m.hook.bookImdTotal(2 * D), 111e18, "audit finding 3: half way out counts 55 %");
        uint256 near = _order(m, 2 * D, true, ref, 10e18); // in full
        assertEq(m.hook.bookImdTotal(2 * D), 121e18, "audit finding 3: at the reference it counts in full");
        vm.startPrank(trader);
        m.hook.cancelOrder(far);
        assertEq(m.hook.bookImdTotal(2 * D), 21e18, "audit finding 3: a cancel releases exactly what the order counted");
        m.hook.cancelOrder(mid);
        assertEq(m.hook.bookImdTotal(2 * D), 10e18, "audit finding 3: the sell's counted amount, stored, not re-valued");
        m.hook.cancelOrder(near);
        vm.stopPrank();
        assertEq(m.hook.bookImdTotal(2 * D), 0, "audit finding 3: every cancel together releases the whole total");
    }

    // ── Audit finding 10: chores once after a direct ring, and never a second payout ──
    function test_A10_choresOnceAfterADirectRingNeverTwice() public {
        Mkt memory m = mkt;
        BellRinger r = BellRinger(payable(m.hook.bellPurse()));
        manager.initialize(PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 200, IHooks(address(0))), uint160(20 << 96));
        _fundImd(address(this), 10e18);
        IERC20T(imd).approve(address(r), 10e18);
        r.topUp(10e18);
        _at(D, OPEN);
        vm.fee(1 gwei);
        vm.prank(makeAddr("direct"));
        m.hook.ringOpen();
        uint256 calls0 = claimFeesCalls;
        address bot = makeAddr("bot");
        vm.prank(bot, bot);
        r.ring{gas: 20_000_000}();
        uint256 paid = IERC20T(imd).balanceOf(bot);
        assertEq(claimFeesCalls, calls0 + 1, "audit finding 10: the chores ran once after a direct ring");
        assertGt(paid, 0, "audit finding 10: and the caller was paid for its own gas");
        uint256 purse1 = IERC20T(imd).balanceOf(address(r));
        address other = makeAddr("other");
        vm.prank(other, other);
        (bool ok, bytes memory e) = address(r).call{gas: 20_000_000}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok, "audit finding 10: a second ring of the same bell reverts");
        assertEq(bytes4(e), BellRinger.BellAlreadyRung.selector, "as BellAlreadyRung");
        assertEq(claimFeesCalls, calls0 + 1, "audit finding 10: no second round of chores");
        assertEq(IERC20T(imd).balanceOf(other), 0, "audit finding 10: no second payout");
        assertEq(IERC20T(imd).balanceOf(address(r)), purse1, "the purse kept the rest");
    }

    /// Audit finding 10's other half, with ample gas: with the residual capped, a ringer with enough gas left for its
    /// chores after a swallowed hook failure also gives the hook enough to ring (63/64 of the call), so an out-of-gas
    /// refusal cannot show a ringer that carries on; a refusal at any gas can. ring() from inside a foreign
    /// unlock: the hook refuses (PoolUnlocked), and the whole ring() reverts: no bell, no chores, no reward.
    function test_A10_ringerRevertsWhenTheHookRefusesInsideAnUnlock() public {
        Mkt memory m = mkt;
        BellRinger r = BellRinger(payable(m.hook.bellPurse()));
        _fundImd(address(this), 10e18);
        IERC20T(imd).approve(address(r), 10e18);
        r.topUp(10e18);
        _at(D, 1 hours);
        address se = _player(m, "seller", 0, 10e18);
        address bu = _player(m, "buyer", 1_000e18, 0);
        _orderAs(m, se, 2 * D, false, 0, 1e18);
        _orderAs(m, bu, 2 * D, true, 60, 100e18);
        _at(D, OPEN);
        ForeignUnlockRingerCall w = new ForeignUnlockRingerCall(manager, r);
        uint256 calls0 = claimFeesCalls;
        (bool ok, bytes memory e) = address(w).call{gas: 30_000_000}(abi.encodeCall(ForeignUnlockRingerCall.ring, ()));
        (, bool rung,,,,) = m.hook.bells(2 * D);
        assertFalse(ok, "audit finding 10: the hook's refusal reverts ring()");
        assertTrue(_has(e, MarketHoursHook.PoolUnlocked.selector), "precondition: the hook's refusal is PoolUnlocked");
        assertFalse(rung, "no bell");
        assertEq(claimFeesCalls, calls0, "no chores");
        assertEq(IERC20T(imd).balanceOf(address(w)), 0, "no reward");
        assertEq(r.purse(), 10e18, "the purse is whole");
        // control: the same ring() outside an unlock rings, runs the chores
        (ok,) = address(r).call{gas: 30_000_000}(abi.encodeCall(BellRinger.ring, ()));
        (, rung,,,,) = m.hook.bells(2 * D);
        assertTrue(ok && rung, "control: outside an unlock the ringer rings");
        assertGt(claimFeesCalls, calls0, "control: and runs the chores");
    }

    // ── figures ──
    /// Audit finding 3: what holding a book with orders that do not trade costs now, per bell, by week: the escrow that fills the
    /// counted cap at the band's edge (ten caps) and half way out (cap / 0.55), and 0.5 % of it, the unfilled fee.
    function test_A_measure_capHoldCostByWeek() public {
        uint256 d0 = mkt.hook.d0();
        for (uint256 w; w <= 8; ++w) {
            vm.warp((d0 + 7 * w) * 1 days + 1 hours);
            uint256 cap = mkt.hook.depositCap();
            uint256 edge = 10 * cap;
            uint256 half = cap * 40_000 / 22_000;
            console2.log("(A3) week / cap (IMD)", w, cap / 1e18);
            console2.log("    edge escrow / fee (IMD x 1e-3)", edge / 1e18, (edge * 50 / 10_000) / 1e15);
            console2.log("    half-band escrow / fee (IMD x 1e-3)", half / 1e18, (half * 50 / 10_000) / 1e15);
        }
    }

    /// Audit finding 2: after a dust self-match at the band's top in both of a day's bells, an honest pair near the pool's price the
    /// next day clears there, and the bell sends nothing to the coin burn.
    function test_A_measure_honestPairAtThePoolAfterTheDrift() public {
        Mkt memory m = mkt;
        address a = _player(m, "attacker", 100e18, 100e18);
        address hb = _player(m, "honest buyer", 1_000e18, 0);
        address hs = _player(m, "honest seller", 0, 100e18);
        _at(D, 1 hours);
        _orderAs(m, a, 2 * D, true, 12_000, 0.5e18);
        _orderAs(m, a, 2 * D, false, 12_000, 0.5e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        int24 top = m.hook.referenceOf(2 * D + 1) + 12_000;
        _orderAs(m, a, 2 * D + 1, true, top, 0.5e18);
        _orderAs(m, a, 2 * D + 1, false, top, 0.5e18);
        _at(D, CLOSE);
        m.hook.ringClose();
        (int24 pOpen,,,,,) = m.hook.bells(2 * D);
        (int24 pClose,,,,,) = m.hook.bells(2 * D + 1);
        console2.log("(A2) day D P* open", int256(pOpen));
        console2.log("(A2) day D P* close", int256(pClose));
        console2.log("(A2) reference for D+1", int256(m.hook.referenceOf(2 * (D + 1))));
        console2.log("(A2) pool tick", int256(_tick(m)));
        _at(D + 1, 1 hours);
        _orderAs(m, a, 2 * (D + 1), false, 12_000, 0.5e18); // the dust sell at the top again
        uint256 b = _orderAs(m, hb, 2 * (D + 1), true, 60, 100e18);
        _orderAs(m, hs, 2 * (D + 1), false, 0, 10e18);
        uint256 cb0 = m.hook.coinBurnAccrued();
        uint256 ib0 = m.hook.burnAccrued();
        _at(D + 1, OPEN);
        m.hook.ringOpen();
        (int24 p,, bool heavy,,, uint64 rf) = m.hook.bells(2 * (D + 1));
        uint256 c0 = m.coin.balanceOf(hb);
        vm.prank(hb);
        m.hook.claim(b);
        console2.log("(A2) D+1 P*", int256(p));
        console2.log("(A2) D+1 buyHeavy / residualFill", heavy, uint256(rf));
        console2.log("(A2) honest 100 IMD buy at bucket 60: coin out", m.coin.balanceOf(hb) - c0);
        console2.log("(A2) coin burn / IMD burn accrued by the bell (wei)", m.hook.coinBurnAccrued() - cb0, m.hook.burnAccrued() - ib0);
        assertEq(p, 60, "the honest pair cleared at bucket 60, next to the pool's price");
        assertEq(m.hook.coinBurnAccrued() - cb0, 0, "no coin went to the burn");
    }
}
