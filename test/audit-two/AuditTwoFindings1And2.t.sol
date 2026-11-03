// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {ReproBase} from "../repro/ReproBase.sol";
import {IERC20T} from "../Base.sol";

/// Audit 2, findings 1 and 2: the deposit cap's distance weight. Pool at tick 0, the book's reference 0, day D in
/// launch week, so depositCap() is 1,000 IMD. Each test asserts what the audit report says is correct, so it fails while the
/// defect is there; each has a control that passes either way.
contract AuditTwoFindings1And2Test is ReproBase {
    function _try(address who, uint256 s, bool buy, int24 bucket, uint256 amount)
        internal
        returns (bool ok, bytes memory e)
    {
        address h = address(mkt.hook);
        vm.prank(who);
        (ok, e) = h.call(abi.encodeCall(MarketHoursHook.placeOrder, (s, buy, bucket, amount)));
    }

    /// Finding 1: one buy of ten times the cap at the band's lower edge must not close the book to everyone else.
    function test_A2F1_edgeOrderDoesNotCloseTheBook() public {
        Mkt memory m = mkt;
        assertEq(m.hook.depositCap(), 1_000e18, "precondition: launch week");
        address griefer = _player(m, "griefer", 10_000e18, 0);
        address honest = _player(m, "honest", 10e18, 10e18);
        _at(D, 1 hours);
        uint256 id = _orderAs(m, griefer, 2 * D, true, -12_000, 10_000e18);
        console2.log("bookImdTotal after the edge order", m.hook.bookImdTotal(2 * D));
        (bool okB, bytes memory eB) = _try(honest, 2 * D, true, 0, 1e18);
        (bool okS, bytes memory eS) = _try(honest, 2 * D, false, 0, 1e18);
        // the griefer's whole cost, for the audit report: cancel before 10:50
        _at(D, OPEN - FREEZE_T - NO_CANCEL_T - 60); // 10:49, the last minute a cancel is open
        uint256 b0 = IERC20T(imd).balanceOf(griefer);
        vm.prank(griefer);
        m.hook.cancelOrder(id);
        console2.log("griefer cost (wei IMD)", 10_000e18 - (IERC20T(imd).balanceOf(griefer) - b0));
        assertTrue(okB, string.concat("an honest buy at the reference must be accepted: ", _why(okB, eB)));
        assertTrue(okS, string.concat("an honest sell at the reference must be accepted: ", _why(okS, eS)));
    }

    /// CONTROL: no edge order, the same honest orders are accepted.
    function test_A2F1_control_honestOrdersAccepted() public {
        Mkt memory m = mkt;
        address honest = _player(m, "honest", 10e18, 10e18);
        _at(D, 1 hours);
        (bool okB, bytes memory eB) = _try(honest, 2 * D, true, 0, 1e18);
        (bool okS, bytes memory eS) = _try(honest, 2 * D, false, 0, 1e18);
        assertTrue(okB, _why(okB, eB));
        assertTrue(okS, _why(okS, eS));
    }

    /// Finding 2, the audit report's book: a buy at +12,000 of 5,000 IMD is marketable (it buys up to about 3.3x the
    /// reference); counted in full it is five times the cap, so it must be refused.
    function test_A2F2_marketableBuyOverTheCapRefused() public {
        Mkt memory m = mkt;
        address w = _player(m, "wallet", 10_000e18, 10_000e18);
        _at(D, 1 hours);
        (bool ok, bytes memory e) = _try(w, 2 * D, true, 12_000, 5_000e18);
        if (ok) {
            // the audit report's second order and its figures, for the record
            (bool ok2,) = _try(w, 2 * D, false, -12_000, 5_000e18);
            console2.log("report's pair admitted (1 = yes)", ok2 ? 1 : 0);
            console2.log("bookImdTotal", m.hook.bookImdTotal(2 * D));
            (int24 p, uint256 matched,,) = m.hook.indicativePrice(2 * D);
            console2.log("indicative P*", int256(p));
            console2.log("indicative matched coin", matched);
        }
        assertFalse(ok, "a marketable buy of five times the cap must be refused");
        assertTrue(_has(e, MarketHoursHook.BookFull.selector), "with BookFull");
    }

    /// Finding 2, at the cap: a marketable buy of exactly the cap fills the book, so a marketable sell after it must be
    /// refused.
    function test_A2F2_marketableSellAfterAFullBookRefused() public {
        Mkt memory m = mkt;
        address w = _player(m, "wallet", 10_000e18, 10_000e18);
        _at(D, 1 hours);
        (bool ok1, bytes memory e1) = _try(w, 2 * D, true, 12_000, 1_000e18);
        assertTrue(ok1, string.concat("precondition: a buy of the cap fits: ", _why(ok1, e1)));
        (bool ok, bytes memory e) = _try(w, 2 * D, false, -12_000, 1e18);
        console2.log("bookImdTotal after the buy", m.hook.bookImdTotal(2 * D));
        assertFalse(ok, "a marketable sell must not fit in a book its marketable buy already fills");
        assertTrue(_has(e, MarketHoursHook.BookFull.selector), "with BookFull");
    }

    /// CONTROL: a book exactly at the cap from orders at the reference (weight one under any rule) is full.
    function test_A2F2_control_atTheReferenceCountsInFull() public {
        Mkt memory m = mkt;
        address w = _player(m, "wallet", 10_000e18, 10_000e18);
        _at(D, 1 hours);
        _orderAs(m, w, 2 * D, true, 0, 500e18);
        _orderAs(m, w, 2 * D, false, 0, 500e18);
        assertEq(m.hook.bookImdTotal(2 * D), 1_000e18, "at the reference: counted in full");
        (bool ok, bytes memory e) = _try(w, 2 * D, true, 0, 1e18);
        assertFalse(ok);
        assertTrue(_has(e, MarketHoursHook.BookFull.selector), "with BookFull");
    }

    /// FIGURES (not a defect test): the cheapest order that blocks a launch-week book on this code, one bucket
    /// below the reference (it never trades unless P* falls a bucket), and its cancel fee.
    function test_A2F1_measure_cheapestNearBlock() public {
        Mkt memory m = mkt;
        address griefer = _player(m, "griefer", 10_000e18, 0);
        address honest = _player(m, "honest", 10e18, 10e18);
        _at(D, 1 hours);
        // the escrow whose count is exactly the cap at 60 ticks: x * w / 40,000 = 1,000e18 under the symmetric weight
        uint256 cap = 1_000e18;
        uint256 x = (cap * 40_000 + 39_819) / 39_820;
        uint256 id = _orderAs(m, griefer, 2 * D, true, -60, x);
        console2.log("near block: escrow / bookImdTotal", x, m.hook.bookImdTotal(2 * D));
        (bool okB,) = _try(honest, 2 * D, true, 0, 1e18);
        console2.log("honest buy after it accepted (1 = yes)", okB ? 1 : 0);
        _at(D, OPEN - FREEZE_T - NO_CANCEL_T - 60); // 10:49, the last minute a cancel is open
        uint256 b0 = IERC20T(imd).balanceOf(griefer);
        vm.prank(griefer);
        m.hook.cancelOrder(id);
        console2.log("near block cost (wei IMD)", x - (IERC20T(imd).balanceOf(griefer) - b0));
    }
}
