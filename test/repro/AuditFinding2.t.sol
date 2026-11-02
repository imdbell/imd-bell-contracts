// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {ReproBase} from "./ReproBase.sol";

/// Audit finding 2 (medium): dust self-matches walk the reference off the pool price. The audit report's proof runs on its own harness
/// (a pool with no liquidity); this is the same sequence on the repo harness (a seeded pool), plus its control.
contract AuditFinding2Test is ReproBase {
    function _drift(Mkt memory m, address a) internal {
        _at(D, 1 hours);
        _orderAs(m, a, 2 * D, true, 12_000, 0.5e18);
        _orderAs(m, a, 2 * D, false, 12_000, 0.5e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        // the close book's band is centred on the pool's own price now, so the attacker's second pair
        // goes to that band's top edge (24,000 is outside it and refused, BadBucket); its sell is valued at that
        // reference, so the smallest one is 0.5 coin (was 0.2, valued at the drifted reference)
        int24 top = m.hook.referenceOf(2 * D + 1) + 12_000;
        _orderAs(m, a, 2 * D + 1, true, top, 0.5e18);
        _orderAs(m, a, 2 * D + 1, false, top, 0.5e18);
        _at(D, CLOSE);
        m.hook.ringClose();
    }

    /// Audit finding 2 on the repo harness: after the attacker's two bells an order at the pool's price must still be placeable.
    function test_F2_orderAtPoolPricePlaceableAfterSelfMatches() public {
        Mkt memory m = mkt;
        address a = _player(m, "attacker", 100e18, 100e18);
        address h = _player(m, "honest", 1_000e18, 0);
        _drift(m, a);
        console2.log("lastCleared after two self-matched bells", int256(m.hook.lastCleared()));
        console2.log("pool tick", int256(_tick(m)));
        _at(D + 1, 1 hours);
        // the tick is read before the prank (the prank was spent on the _tick read, so the order came
        // from the test contract; on the audited code BadBucket reverted first and hid it)
        int24 poolTick = _tick(m);
        vm.prank(h);
        (bool ok, bytes memory e) =
            address(m.hook).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * (D + 1), true, poolTick, 100e18)));
        assertTrue(ok, string.concat("an order at the pool's price must be placeable: ", _why(ok, e)));
    }

    /// CONTROL: the same two bells with no orders leave the reference on the pool's price and the order goes in.
    function test_F2_control_noSelfMatchNoDrift() public {
        Mkt memory m = mkt;
        address h = _player(m, "honest", 1_000e18, 0);
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D, CLOSE);
        m.hook.ringClose();
        assertEq(m.hook.lastCleared(), 0, "reference unchanged");
        _at(D + 1, 1 hours);
        _orderAs(m, h, 2 * (D + 1), true, 0, 100e18);
    }

    /// FIGURES (sub-claim "honest buys inside the drifted band lose most of their value"): day D + 1, an honest
    /// 100 IMD buy at the band's floor (bucket 12000) against one dust sell there; the residual buys from the pool at
    /// about 1 IMD per coin, the buyer is paid at P* = price(12000), and the coin beyond that goes to the coin burn.
    function test_F2_measure_honestBuyInDriftedBand() public {
        Mkt memory m = mkt;
        address a = _player(m, "attacker", 100e18, 100e18);
        address h = _player(m, "honest", 1_000e18, 0);
        _drift(m, a);
        _at(D + 1, 1 hours);
        // 0.5 coin (was 0.05, valued at the drifted reference); at the pool-anchored reference 0 the
        // smallest sell at bucket 12,000 is 0.5 coin
        _orderAs(m, a, 2 * (D + 1), false, 12_000, 0.5e18);
        uint256 id = _orderAs(m, h, 2 * (D + 1), true, 12_000, 100e18);
        uint256 cb0 = m.hook.coinBurnAccrued();
        _at(D + 1, OPEN);
        m.hook.ringOpen();
        (int24 p,, bool heavy,,, uint64 rf) = m.hook.bells(2 * (D + 1));
        Out memory o = _claimOut(m, id, h, true);
        console2.log("pStar", int256(p));
        console2.log("buyHeavy / residualFill", heavy, rf);
        console2.log("pool tick after the bell", int256(_tick(m)));
        console2.log("honest 100 IMD buy: coin out / IMD refund", o.out, o.refund);
        console2.log("coin burn accrued by the bell", m.hook.coinBurnAccrued() - cb0);
    }
}
