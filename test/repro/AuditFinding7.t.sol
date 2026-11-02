// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MarketHoursCoin} from "src/MarketHoursCoin.sol";
import {ReproBase} from "./ReproBase.sol";
import {IERC20T} from "../Base.sol";

/// Audit finding 7 (low): orders are accepted before the pool is initialised, valued at reference 0.
contract AuditFinding7Test is ReproBase {
    MarketHoursHook internal h;
    MarketHoursCoin internal c;
    PoolKey internal k;

    function _uninitialised(uint256 tag) internal {
        c = _newCoin(tag);
        address at = _deployHook(_params(address(c)), tag);
        require(at != address(0), "deploy");
        h = MarketHoursHook(at);
        k = PoolKey(Currency.wrap(address(c)), Currency.wrap(imd), 12_500, 60, IHooks(at));
        assertFalse(h.initialized(), "precondition: not initialised");
    }

    function _who(string memory label, uint256 coinAmt, uint256 imdAmt) internal returns (address p) {
        p = makeAddr(label);
        if (coinAmt > 0) c.transfer(p, coinAmt);
        if (imdAmt > 0) _fundImd(p, imdAmt);
        vm.startPrank(p);
        c.approve(address(h), type(uint256).max);
        IERC20T(imd).approve(address(h), type(uint256).max);
        vm.stopPrank();
    }

    function _try(address who, bytes memory data) internal returns (bool ok, bytes memory e) {
        vm.prank(who);
        (ok, e) = address(h).call(data);
    }

    /// Audit finding 7 core: refused before initialisation, or cancellable after it.
    function test_F7_preInitOrderRefusedOrCancellable() public {
        _uninitialised(0x77);
        address u = _who("u", 10e18, 0);
        _at(D, 2 hours);
        (bool placed, bytes memory r) = _try(u, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, false, int24(0), 1e18)));
        if (!placed) return; // refused: correct
        uint256 id = abi.decode(r, (uint256));
        console2.log("bookImdTotal after the pre-init sell", h.bookImdTotal(2 * D));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(6_000));
        console2.log("lastCleared after initialise", int256(h.lastCleared()));
        _at(D, 3 hours);
        (bool ok, bytes memory e) = _try(u, abi.encodeCall(MarketHoursHook.cancelOrder, (id)));
        assertTrue(ok, string.concat("an order the hook accepted must be cancellable: ", _why(ok, e)));
    }

    /// Audit finding 7 cap accounting: an honest post-init order's cancel is broken by an earlier pre-init order's cancel.
    function test_F7_honestPostInitCancel() public {
        _uninitialised(0x78);
        address u = _who("u", 10e18, 0);
        address v = _who("v", 10e18, 0);
        _at(D, 2 hours);
        (bool placed, bytes memory r) = _try(u, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, false, int24(0), 1e18)));
        if (!placed) return;
        uint256 idU = abi.decode(r, (uint256));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(6_000));
        vm.prank(v);
        uint256 idV = h.placeOrder(2 * D, false, 6_000, 1e18);
        console2.log("bookImdTotal, both placed", h.bookImdTotal(2 * D));
        _at(D, 3 hours);
        vm.prank(u);
        h.cancelOrder(idU);
        console2.log("bookImdTotal after the pre-init order's cancel", h.bookImdTotal(2 * D));
        (bool ok, bytes memory e) = _try(v, abi.encodeCall(MarketHoursHook.cancelOrder, (idV)));
        assertTrue(ok, string.concat("an honest post-init order must be cancellable: ", _why(ok, e)));
    }

    /// Audit finding 7 beyond the audit report: a pre-init sell left below the new band is never in the scan but is paid as filled.
    /// Correct: every claim of the bell succeeds (the hook stays solvent).
    function test_F7_preInitOrderOutsideBandAllClaimsPay() public {
        _uninitialised(0x79);
        address u = _who("u", 10e18, 0);
        address s2 = _who("s2", 20e18, 0);
        address b = _who("b", 0, 200e18);
        _at(D, 2 hours);
        (bool placed, bytes memory r) =
            _try(u, abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, false, int24(-12_000), 1e18)));
        if (!placed) return;
        uint256 idU = abi.decode(r, (uint256));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(6_000));
        vm.prank(s2);
        uint256 idS = h.placeOrder(2 * D, false, 6_000, 10e18);
        vm.prank(b);
        uint256 idB = h.placeOrder(2 * D, true, 6_000, 100e18);
        _at(D, OPEN);
        h.ringOpen();
        (int24 p,, bool heavy,,,) = h.bells(2 * D);
        console2.log("pStar", int256(p));
        console2.log("buyHeavy", heavy);
        console2.log("hook IMD held before claims", IERC20T(imd).balanceOf(address(h)));
        uint256 u0 = IERC20T(imd).balanceOf(u);
        (bool okU,) = address(h).call(abi.encodeCall(MarketHoursHook.claim, (idU)));
        console2.log("pre-init seller (never in the scan) paid IMD", IERC20T(imd).balanceOf(u) - u0);
        (bool okS,) = address(h).call(abi.encodeCall(MarketHoursHook.claim, (idS)));
        (bool okB, bytes memory eB) = address(h).call(abi.encodeCall(MarketHoursHook.claim, (idB)));
        console2.log("claim ok: pre-init seller", okU);
        console2.log("claim ok: seller", okS);
        console2.log("claim ok: buyer", okB);
        console2.log("hook IMD held after claims", IERC20T(imd).balanceOf(address(h)));
        assertTrue(okU && okS && okB, string.concat("every claim of the bell must pay: buyer ", _why(okB, eB)));
    }

    /// CONTROL: after initialisation, place and cancel round-trip the cap total to zero.
    function test_F7_control_postInitPlaceCancel() public {
        _uninitialised(0x7a);
        manager.initialize(k, TickMath.getSqrtPriceAtTick(6_000));
        address u = _who("u", 10e18, 0);
        _at(D, 2 hours);
        vm.prank(u);
        uint256 id = h.placeOrder(2 * D, false, 0, 1e18);
        _at(D, 3 hours);
        vm.prank(u);
        h.cancelOrder(id);
        assertEq(h.bookImdTotal(2 * D), 0);
    }
}
