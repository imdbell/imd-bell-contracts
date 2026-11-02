// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {ReproBase} from "./ReproBase.sol";
import {MsgSenderRouter} from "../MsgSenderRouter.sol";
import {IERC20T} from "../Base.sol";

/// Audit finding 8 (low): for a router without msgSender(), the round-trip rule couples every user of that router.
contract AuditFinding8Test is ReproBase {
    address internal g;
    address internal hn;

    function _users(Mkt memory m, address r) internal {
        g = _player(m, "griefer", 100e18, 100e18);
        hn = _player(m, "honest", 100e18, 100e18);
        vm.startPrank(g);
        IERC20T(imd).approve(r, type(uint256).max);
        m.coin.approve(r, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(hn);
        IERC20T(imd).approve(r, type(uint256).max);
        m.coin.approve(r, type(uint256).max);
        vm.stopPrank();
        // an IMD-only position below spot, so a 1-wei sell stays in range instead of emptying the price to its limit
        _fundImd(address(this), 100_000e18);
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(-12_000, 0, 1e23, 0), "");
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
    }

    function _sell1Wei() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1);
    }

    function _buy1Imd() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(false, -1e18, TickMath.MAX_SQRT_PRICE - 1);
    }

    /// Audit finding 8: through PoolSwapTest (no msgSender()), a griefer's 1-wei sell blocks an honest buy in the same block.
    function test_F8_unrelatedUsersOfARouterAreNotCoupled() public {
        Mkt memory m = mkt;
        _users(m, address(router));
        vm.prank(g, g);
        router.swap(m.key, _sell1Wei(), PoolSwapTest.TestSettings(false, false), "");
        vm.prank(hn, hn);
        (bool ok, bytes memory e) = address(router).call(
            abi.encodeCall(PoolSwapTest.swap, (m.key, _buy1Imd(), PoolSwapTest.TestSettings(false, false), bytes("")))
        );
        if (!ok) console2.log("refused by RoundTrip", _has(e, MarketHoursHook.RoundTrip.selector));
        assertTrue(ok, string.concat("an unrelated user's swap through the same router must not be blocked: ", _why(ok, e)));
    }

    /// CONTROL: through a router that answers msgSender() with the signer, the two users are independent.
    function test_F8_control_msgSenderRouterDecouples() public {
        Mkt memory m = mkt;
        MsgSenderRouter r = new MsgSenderRouter(manager);
        _users(m, address(r));
        vm.prank(g, g);
        r.swap(m.key, _sell1Wei());
        vm.prank(hn, hn);
        r.swap(m.key, _buy1Imd());
    }

    /// CONTROL: the guard still stops one signer's round trip through that router.
    function test_F8_control_sameSignerRoundTripRefused() public {
        Mkt memory m = mkt;
        MsgSenderRouter r = new MsgSenderRouter(manager);
        _users(m, address(r));
        vm.prank(hn, hn);
        r.swap(m.key, _sell1Wei());
        vm.prank(hn, hn);
        (bool ok, bytes memory e) = address(r).call(abi.encodeCall(MsgSenderRouter.swap, (m.key, _buy1Imd())));
        assertFalse(ok, "one signer, both directions, one block: refused");
        assertTrue(_has(e, MarketHoursHook.RoundTrip.selector), "refused by the round-trip rule");
    }
}
