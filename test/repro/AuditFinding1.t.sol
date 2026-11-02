// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {BellRinger} from "src/BellRinger.sol";
import {ReproBase} from "./ReproBase.sol";
import {IERC20T} from "../Base.sol";

/// Rings the open from inside its own PoolManager unlock and, optionally, buys coin in the same unlock right after.
contract InUnlockRinger is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    MarketHoursHook internal immutable hook;
    uint256 internal buyImd;
    int24 public tickAtSwap;
    uint256 public coinGot;

    constructor(IPoolManager m, MarketHoursHook h) {
        manager = m;
        hook = h;
    }

    function attack(uint256 buyImd_) external {
        buyImd = buyImd_;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        hook.ringOpen();
        if (buyImd > 0) {
            PoolKey memory k = hook.poolKey();
            (, tickAtSwap,,) = manager.getSlot0(PoolIdLibrary.toId(k));
            // the harness's coin sorts below IMD: IMD in is oneForZero
            BalanceDelta d =
                manager.swap(k, IPoolManager.SwapParams(false, -int256(buyImd), TickMath.MAX_SQRT_PRICE - 1), "");
            manager.sync(k.currency1);
            IERC20T(Currency.unwrap(k.currency1)).transfer(address(manager), uint256(uint128(-d.amount1())));
            manager.settle();
            coinGot = uint256(uint128(d.amount0()));
            manager.take(k.currency0, address(this), coinGot);
        }
        return "";
    }
}

/// Audit finding 1 (high): a bell rung from inside a foreign unlock drops its residual. The book is the audit report's: sell 1 coin at
/// bucket 0, buy 900 IMD at bucket 300, on the harness pool (coin-only seed over [0, 12000), L = 1e23, tick 0).
contract AuditFinding1Test is ReproBase {
    address internal buyer;
    address internal seller;
    uint256 internal sellId;
    uint256 internal buyId;

    function _book(Mkt memory m) internal {
        seller = _player(m, "seller", 0, 10e18);
        buyer = _player(m, "buyer", 1_000e18, 0);
        _at(D, 1 hours);
        sellId = _orderAs(m, seller, 2 * D, false, 0, 1e18);
        buyId = _orderAs(m, buyer, 2 * D, true, 300, 900e18);
        _at(D, OPEN);
    }

    /// CONTROL: a plain ringOpen() sends the residual through the pool and the buyer receives the coin.
    function test_F1_control_plainRingFillsResidual() public {
        Mkt memory m = mkt;
        _book(m);
        m.hook.ringOpen();
        (, bool rung, bool heavy,,,) = m.hook.bells(2 * D);
        assertTrue(rung && heavy, "precondition: the open rang buy-heavy");
        uint64 rf = _residualFill(m, 2 * D);
        (, uint64 up) = m.hook.charges(2 * D);
        Out memory o = _claimOut(m, buyId, buyer, true);
        console2.log("control residualFill / residualUp", rf, up);
        console2.log("control pool tick after the bell", _tick(m));
        console2.log("control buyer coin out / IMD refund", o.out, o.refund);
        console2.log("control buyer unfilled fee", o.unfilledFee);
        assertGt(rf, 0, "a plain ring fills the residual");
    }

    /// Audit finding 1 core: the ring from inside a foreign unlock must fill the residual, or be refused.
    function test_F1_ringInsideForeignUnlockFillsResidual() public {
        Mkt memory m = mkt;
        _book(m);
        InUnlockRinger a = new InUnlockRinger(manager, m.hook);
        try a.attack(0) {}
        catch {
            return; // refused: the correct behaviour
        }
        (, bool rung,,,,) = m.hook.bells(2 * D);
        (, uint64 up) = m.hook.charges(2 * D);
        uint64 rf = _residualFill(m, 2 * D);
        console2.log("nested residualFill / residualUp", rf, up);
        assertTrue(rung, "precondition: the nested ring rang the bell");
        assertGt(rf, 0, "a bell rung from inside a foreign unlock must still fill its residual");
    }

    /// Audit finding 1 consequence (2): the heavy-side buyer's remainder is refunded less the unfilled-order fee instead of filled.
    function test_F1_nestedRingBuyerPaysNoUnfilledFee() public {
        Mkt memory m = mkt;
        _book(m);
        InUnlockRinger a = new InUnlockRinger(manager, m.hook);
        try a.attack(0) {}
        catch {
            return;
        }
        Out memory o = _claimOut(m, buyId, buyer, true);
        console2.log("nested buyer coin out / IMD refund", o.out, o.refund);
        console2.log("nested buyer unfilled fee", o.unfilledFee);
        assertEq(o.unfilledFee, 0, "the buyer's remainder must go to the pool, not be charged the unfilled-order fee");
    }

    /// Audit finding 1 consequence (3): no swap may run between a bell and its residual. The attacker buys inside its own unlock.
    function test_F1_noSwapBeforeTheResidual() public {
        Mkt memory m = mkt;
        _book(m);
        uint256 snap = vm.snapshotState();
        m.hook.ringOpen();
        int24 afterResidual = _tick(m);
        vm.revertToState(snap);

        InUnlockRinger a = new InUnlockRinger(manager, m.hook);
        _fundImd(address(a), 100e18);
        try a.attack(100e18) {}
        catch {
            return;
        }
        console2.log("pool tick after a plain bell's residual", afterResidual);
        console2.log("tick the in-unlock attacker swapped at", a.tickAtSwap());
        console2.log("coin the attacker got for 100 IMD", a.coinGot());
        assertGe(a.tickAtSwap(), afterResidual, "the attacker traded at the pre-residual price");
    }

    /// Audit finding 1 out-of-gas variant: a pool initialised at every bucket of the band, a residual that crosses all of them, rung
    /// with the least gas the hook accepts. Correct: the residual still fills (the floor covers the worst case).
    function test_F1_gasFloorCoversResidualAtWorstTickDensity() public {
        Mkt memory m = _market(0x61, type(MarketHoursHook).creationCode, 60, 1e20);
        for (int24 b = 60; b < 12_000; b += 60) {
            lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b, b + 60, 1e20, 0), "");
        }
        seller = _player(m, "seller", 0, 10e18);
        buyer = _player(m, "buyer", 1_000e18, 0);
        _at(D, 1 hours);
        _orderAs(m, seller, 2 * D, false, 0, 1e18);
        _orderAs(m, buyer, 2 * D, true, 12_000, 900e18);
        _at(D, OPEN);

        // control at unlimited gas
        uint256 snap = vm.snapshotState();
        _coolAll(m);
        uint256 g0 = gasleft();
        m.hook.ringOpen();
        uint256 used = g0 - gasleft();
        (int24 p,,,,,) = m.hook.bells(2 * D);
        console2.log("unlimited gas: ring gas used", used);
        console2.log("unlimited gas: pStar", int256(p));
        console2.log("unlimited gas: tick after", int256(_tick(m)));
        console2.log("unlimited gas: residualFill", _residualFill(m, 2 * D));
        assertGt(_residualFill(m, 2 * D), 0, "control: with ample gas the residual fills");
        vm.revertToState(snap);

        // the least gas, in 1,000-gas steps, at which ringOpen() succeeds
        // the search starts at the hook's floor (was 7,000,000 to 7,300,000: below the raised floor
        // every ring is refused GasFloor)
        uint256 g = m.hook.BELL_GAS_FLOOR();
        bool ok;
        for (uint256 top = g + 300_000; g < top; g += 1_000) {
            _coolAll(m);
            (ok,) = address(m.hook).call{gas: g}(abi.encodeCall(MarketHoursHook.ringOpen, ()));
            if (ok) break;
        }
        assertTrue(ok, "harness: some gas within 300k of the floor rings the bell");
        console2.log("least gas that rings", g);
        console2.log("residualFill at that gas", _residualFill(m, 2 * D));
        assertGt(_residualFill(m, 2 * D), 0, "at the least gas the hook accepts, the residual must still fill");
    }

    /// Audit finding 1 consequence (1): the heavy-side buyer gets the coin a plain bell would have bought for it.
    function test_F1_nestedRingBuyerReceivesTheResidualCoin() public {
        Mkt memory m = mkt;
        _book(m);
        uint256 snap = vm.snapshotState();
        m.hook.ringOpen();
        Out memory c = _claimOut(m, buyId, buyer, true);
        vm.revertToState(snap);
        InUnlockRinger a = new InUnlockRinger(manager, m.hook);
        try a.attack(0) {}
        catch {
            return;
        }
        Out memory o = _claimOut(m, buyId, buyer, true);
        console2.log("plain bell: buyer coin out / IMD refund", c.out, c.refund);
        console2.log("nested bell: buyer coin out / IMD refund", o.out, o.refund);
        assertEq(o.out, c.out, "a bell rung from inside a foreign unlock must pay the buyer the coin a plain bell pays");
    }

    function _denseMarket() internal returns (Mkt memory m) {
        m = _market(0x61, type(MarketHoursHook).creationCode, 60, 1e20);
        for (int24 b = 60; b < 12_000; b += 60) {
            lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b, b + 60, 1e20, 0), "");
        }
        seller = _player(m, "seller", 0, 10e18);
        buyer = _player(m, "buyer", 1_000e18, 0);
        _at(D, 1 hours);
        _orderAs(m, seller, 2 * D, false, 0, 1e18);
        _orderAs(m, buyer, 2 * D, true, 12_000, 900e18);
        _at(D, OPEN);
    }

    /// FIGURES (passes): on the dense pool, the least gas at which a direct ringOpen() fills the residual.
    function test_F1_measure_gasNeededForResidualAtWorstTickDensity() public {
        Mkt memory m = _denseMarket();
        uint256 g = 7_000_000;
        for (; g < 12_000_000; g += 25_000) {
            uint256 snap = vm.snapshotState();
            _coolAll(m);
            (bool ok,) = address(m.hook).call{gas: g}(abi.encodeCall(MarketHoursHook.ringOpen, ()));
            bool filled = ok && _residualFill(m, 2 * D) > 0;
            vm.revertToState(snap);
            if (filled) break;
        }
        console2.log("least gas (25k steps) at which ringOpen() fills the residual", g);
        assertLt(g, 12_000_000, "harness: found within 12M");
    }

    /// Audit finding 1 out-of-gas variant through the ringer: BellRinger.ring() at the least gas it accepts must fill the residual.
    function test_F1_ringerAtItsLeastGasFillsResidual() public {
        Mkt memory m = _denseMarket();
        BellRinger r = _ringer(m);
        uint256 g = r.bellGasFloor() + r.CHORE_GAS_OPEN();
        bool ok;
        for (uint256 top = g + 400_000; g < top; g += 1_000) {
            _coolAll(m);
            vm.cool(address(r));
            vm.prank(trader, trader);
            (ok,) = address(r).call{gas: g}(abi.encodeCall(BellRinger.ring, ()));
            if (ok) break;
        }
        assertTrue(ok, "harness: the ringer rings within 400k of its floor");
        console2.log("least gas BellRinger.ring() accepts", g);
        console2.log("residualFill at that gas", _residualFill(m, 2 * D));
        assertGt(_residualFill(m, 2 * D), 0, "a ring at the ringer's own least accepted gas must fill the residual");
    }

    /// FIGURES: a ring() sent with an 8,000,000 gas limit; on the dense pool, does the residual fill?
    function test_F1_measure_ringerAtSiteGasLimit() public {
        Mkt memory m = _denseMarket();
        BellRinger r = _ringer(m);
        _coolAll(m);
        vm.cool(address(r));
        vm.prank(trader, trader);
        (bool ok,) = address(r).call{gas: 8_000_000}(abi.encodeCall(BellRinger.ring, ()));
        console2.log("ring() at 8,000,000 ok", ok);
        console2.log("residualFill", _residualFill(m, 2 * D));
        // 8,000,000 is now below the ringer's own minimum (floor + chores), so the ring is refused
        // before the bell (was: assertTrue(ok)); either way the residual is never dropped
        assertTrue(!ok || _residualFill(m, 2 * D) > 0, "the site's 8,000,000 never rings a bell with its residual dropped");
    }
}
