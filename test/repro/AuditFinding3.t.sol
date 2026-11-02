// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {ReproBase} from "./ReproBase.sol";

/// Audit finding 3 (medium): one never-matched order at the band's floor fills the shared deposit cap.
contract AuditFinding3Test is ReproBase {
    address internal occ;
    address internal hon;

    function _occupy(Mkt memory m) internal returns (uint256 id) {
        occ = _player(m, "occupier", 2_000e18, 0);
        hon = _player(m, "honest", 100e18, 100e18);
        _at(D, 1 hours);
        assertEq(m.hook.depositCap(), 1_000e18, "precondition: launch-week cap");
        id = _orderAs(m, occ, 2 * D, true, -12_000, 1_000e18);
        // the decided cap counts an order at the band's edge at a tenth (1,000 IMD -> 100)
        assertEq(m.hook.bookImdTotal(2 * D), 100e18, "precondition: the one order counts a tenth of its size");
    }

    function test_F3_honestBuyJoinsAfterFarOrder() public {
        Mkt memory m = mkt;
        _occupy(m);
        vm.prank(hon);
        (bool ok, bytes memory e) =
            address(m.hook).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, true, int24(0), 1e18)));
        assertTrue(ok, string.concat("an honest buy at the reference must be placeable: ", _why(ok, e)));
    }

    function test_F3_honestSellJoinsAfterFarOrder() public {
        Mkt memory m = mkt;
        _occupy(m);
        vm.prank(hon);
        (bool ok, bytes memory e) =
            address(m.hook).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, false, int24(0), 1e18)));
        assertTrue(ok, string.concat("an honest sell at the reference must be placeable: ", _why(ok, e)));
    }

    /// CONTROL: without the occupier (and with one that leaves 1 IMD of room) the honest order goes in.
    function test_F3_control_roomLeftHonestJoins() public {
        Mkt memory m = mkt;
        // 998 IMD of counted room at the band's edge takes ten times that in escrow
        occ = _player(m, "occupier", 10_000e18, 0);
        hon = _player(m, "honest", 100e18, 100e18);
        _at(D, 1 hours);
        _orderAs(m, hon, 2 * D, true, 0, 1e18);
        _orderAs(m, occ, 2 * D, true, -12_000, 9_980e18);
        _orderAs(m, hon, 2 * D, false, 0, 1e18);
        assertEq(m.hook.bookImdTotal(2 * D), 1_000e18);
    }

    /// FIGURES (passes = the audit report's cost figure holds): the occupier's whole cost for one bell.
    function test_F3_measure_occupierCostPerBell() public {
        Mkt memory m = mkt;
        uint256 id = _occupy(m);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p,,,,,) = m.hook.bells(2 * D);
        Out memory o = _claimOut(m, id, occ, true);
        console2.log("pStar", int256(p));
        console2.log("occupier refund / unfilled fee", o.refund, o.unfilledFee);
        assertEq(o.unfilledFee, 5e18, "fee 0.5% of the cap");
        assertEq(o.refund, 995e18);
    }

    /// FIGURES: cancel at 10:49 and re-place keeps the book full through the no-cancel hour.
    function test_F3_measure_cancelReplaceHoldsThroughNoCancelHour() public {
        Mkt memory m = mkt;
        uint256 id = _occupy(m);
        _at(D, OPEN - 600 - 3600 - 60); // 10:49
        vm.prank(occ);
        m.hook.cancelOrder(id);
        // refilling the counted cap at the band's edge takes ten times the cap in escrow
        _fundImd(occ, 9_000e18);
        _orderAs(m, occ, 2 * D, true, -12_000, 9_950e18);
        _orderAs(m, occ, 2 * D, true, -12_000, 50e18);
        _at(D, OPEN - 600 - 60); // 11:49, inside the no-cancel hour
        vm.prank(hon);
        (bool ok, bytes memory e) =
            address(m.hook).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, true, int24(0), 1e18)));
        assertFalse(ok, "figures: still full");
        assertEq(bytes4(e), MarketHoursHook.BookFull.selector);
    }

    /// FIGURES: depositCap() by week from launch day.
    function test_F3_measure_capByWeek() public {
        Mkt memory m = mkt;
        uint256 d0 = m.hook.d0();
        for (uint256 w; w <= 8; ++w) {
            vm.warp((d0 + 7 * w) * 1 days + 1 hours);
            console2.log("week / depositCap (IMD)", w, m.hook.depositCap() / 1e18);
        }
    }
}
