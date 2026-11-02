// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {Base} from "./Base.sol";

/// The gas of the book's calls and of a bell in fixed scenarios, every account cooled first. Figures only; no
/// assertion beyond the harness's own.
abstract contract GasOps is Base {
    function _g(Mkt memory m, address who, bytes memory call) internal returns (uint256 used) {
        _coolAll(m);
        vm.prank(who);
        uint256 g0 = gasleft();
        (bool ok,) = address(m.hook).call(call);
        used = g0 - gasleft();
        require(ok, "harness: the timed call failed");
    }

    function test_G_measure_bookAndBellGas() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 placeFirst = _g(m, trader, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, true, 60, 100e18)));
        uint256 placeSame = _g(m, trader, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, true, 60, 50e18)));
        uint256 placeSell = _g(m, trader, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, false, -60, 60e18)));
        uint256 placeFar = _g(m, trader, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, false, 12_000, 20e18)));
        uint256 cancelBuy = _g(m, trader, abi.encodeCall(MarketHoursHook.cancelOrder, (1)));
        _at(D, OPEN);
        _coolAll(m);
        uint256 g0 = gasleft();
        m.hook.ringOpen();
        uint256 ring = g0 - gasleft();
        uint256 claimBuy = _g(m, trader, abi.encodeCall(MarketHoursHook.claim, (0)));
        uint256 claimSell = _g(m, trader, abi.encodeCall(MarketHoursHook.claim, (2)));
        uint256 claimFar = _g(m, trader, abi.encodeCall(MarketHoursHook.claim, (3)));
        console2.log("(G) placeOrder: first in a bucket / same bucket", placeFirst, placeSame);
        console2.log("(G) placeOrder: a sell / a sell at the band's edge", placeSell, placeFar);
        console2.log("(G) cancelOrder (a buy)", cancelBuy);
        console2.log("(G) ringOpen, cold, a four-order book", ring);
        console2.log("(G) claim: filled buy / filled sell", claimBuy, claimSell);
        console2.log("(G) claim: unreached sell", claimFar);
    }

    /// The repro's dense pool (a position at every bucket up to +12,000) and a buy-heavy book clearing at +12,000:
    /// the gas a cold ringOpen() uses with ample gas.
    function test_G_measure_denseRingGas() public {
        Mkt memory m = _market(0x7d, type(MarketHoursHook).creationCode, 60, 1e20);
        for (int24 b = 60; b < 12_000; b += 60) {
            lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(b, b + 60, 1e20, 0), "");
        }
        address se = _player(m, "seller", 0, 10e18);
        address bu = _player(m, "buyer", 1_000e18, 0);
        _at(D, 1 hours);
        _orderAs(m, se, 2 * D, false, 0, 1e18);
        _orderAs(m, bu, 2 * D, true, 12_000, 900e18);
        _at(D, OPEN);
        _coolAll(m);
        uint256 g0 = gasleft();
        m.hook.ringOpen();
        console2.log("(G) ringOpen, cold, dense band, ample gas", g0 - gasleft());
    }

    /// The repro's dense pool on one side of tick 0, a position at every bucket of the band (L = 1e20 each), and a
    /// two-order book whose residual crosses the whole band: up to +12,000 (buy-heavy), or down to -12,000.
    function _denseBand(bool up, uint256 tag) internal returns (Mkt memory m) {
        m = _market(tag, type(MarketHoursHook).creationCode, 60, 1e20);
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
        if (up) {
            _orderAs(m, se, 2 * D, false, 0, 1e18);
            _orderAs(m, bu, 2 * D, true, 12_000, 900e18);
        } else {
            _orderAs(m, bu, 2 * D, true, 0, 1e18);
            _orderAs(m, se, 2 * D, false, -12_000, 900e18);
        }
        _at(D, OPEN);
    }

}
