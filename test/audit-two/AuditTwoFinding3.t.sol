// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MsgSenderRouter} from "../MsgSenderRouter.sol";
import {ReproBase} from "../repro/ReproBase.sol";
import {IERC20T} from "../Base.sol";

/// Audit 2, finding 3: the round-trip guard keyed on tx.origin couples two smart accounts whose user operations one
/// bundler sends in one block. Here the router reports each account through msgSender(), as the periphery routers do;
/// the second account's opposite swap must go through.
contract AuditTwoFinding3Test is ReproBase {
    address internal bundler = makeAddr("bundler");
    MsgSenderRouter internal msr;

    function _setUp2(Mkt memory m) internal returns (address a, address b) {
        msr = new MsgSenderRouter(manager);
        a = _player(m, "smart account A", 100e18, 100e18);
        b = _player(m, "smart account B", 100e18, 100e18);
        address[2] memory w = [a, b];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(w[i]);
            IERC20T(imd).approve(address(msr), type(uint256).max);
            m.coin.approve(address(msr), type(uint256).max);
            IERC20T(imd).approve(address(router), type(uint256).max);
            m.coin.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        // an IMD-only position under the price, so a one-wei sell does not empty the price (the proof's own setup)
        _fundImd(address(this), 100_000e18);
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(-12_000, 0, 1e23, 0), "");
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
    }

    function _msrSwap(Mkt memory m, address who, address origin, bool zfo, int256 amt)
        internal
        returns (bool ok, bytes memory e)
    {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams(zfo, amt, zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        vm.prank(who, origin);
        (ok, e) = address(msr).call(abi.encodeCall(MsgSenderRouter.swap, (m.key, p)));
    }

    function test_A2F3_reportingRouterKeepsBundledAccountsApart() public {
        Mkt memory m = mkt;
        (address a, address b) = _setUp2(m);
        (bool okA, bytes memory eA) = _msrSwap(m, a, bundler, true, -1);
        assertTrue(okA, string.concat("precondition: A's sell: ", _why(okA, eA)));
        (bool okB, bytes memory eB) = _msrSwap(m, b, bundler, false, -1e18);
        if (!okB) assertFalse(_has(eB, MarketHoursHook.RoundTrip.selector), "B refused by the round-trip rule");
        assertTrue(okB, _why(okB, eB));
    }

    /// CONTROL: one account, both directions in one block through the reporting router, is still refused.
    function test_A2F3_control_sameAccountStillRefused() public {
        Mkt memory m = mkt;
        (address a,) = _setUp2(m);
        (bool ok1, bytes memory e1) = _msrSwap(m, a, bundler, true, -1);
        assertTrue(ok1, _why(ok1, e1));
        (bool ok2, bytes memory e2) = _msrSwap(m, a, bundler, false, -1e18);
        assertFalse(ok2, "the same account's round trip in one block");
        assertTrue(_has(e2, MarketHoursHook.RoundTrip.selector), "refused by the round-trip rule");
    }

    /// CONTROL: two accounts that sign their own transactions are apart under any key.
    function test_A2F3_control_ownSignersApart() public {
        Mkt memory m = mkt;
        (address a, address b) = _setUp2(m);
        (bool okA, bytes memory eA) = _msrSwap(m, a, a, true, -1);
        assertTrue(okA, _why(okA, eA));
        (bool okB, bytes memory eB) = _msrSwap(m, b, b, false, -1e18);
        assertTrue(okB, _why(okB, eB));
    }
}
