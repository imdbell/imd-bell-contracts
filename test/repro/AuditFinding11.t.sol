// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ReproBase} from "./ReproBase.sol";

/// Audit finding 11 (info): book-rationed strictly-inside orders pay the unfilled-order fee; a rationed marginal bucket does not.
/// The pool cannot fill a buy residual here (its limit, price(P*) with the fee inward, sits below spot), as the audit report
/// assumes.
contract AuditFinding11Test is ReproBase {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function _i2c(uint256 i, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(i, Q96, sp), Q96, sp);
    }

    /// X: 100 IMD net at bucket 60 (inner); Y: 1 IMD net at bucket 0 (marginal); sells at 0: coin worth 100 IMD at
    /// price(60), plus one wei, so bucket 60 matches one wei less than bucket 0 and P* = 0.
    function test_F11_innerRationedRemainderPaysNoFee() public {
        Mkt memory m = mkt;
        address x = _player(m, "x", 200e18, 0);
        address y = _player(m, "y", 10e18, 0);
        address se = _player(m, "seller", 0, 200e18);
        uint256 sAmt = _i2c(100e18, TickMath.getSqrtPriceAtTick(60)) + 1;
        _at(D, 1 hours);
        uint256 idX = _orderAs(m, x, 2 * D, true, 60, 101.25e18);
        _orderAs(m, y, 2 * D, true, 0, 1.0125e18);
        _orderAs(m, se, 2 * D, false, 0, sAmt);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p,, bool heavy, uint64 inner, uint64 marg, uint64 rf) = m.hook.bells(2 * D);
        console2.log("pStar", int256(p));
        console2.log("innerFill / marginalFill", inner, marg);
        console2.log("residualFill", rf);
        assertTrue(p == 0 && heavy && inner < 1e18 && marg == 0 && rf == 0, "precondition: inner rationed, pool unfilled");
        Out memory o = _claimOut(m, idX, x, true);
        console2.log("X coin out / IMD refund", o.out, o.refund);
        console2.log("X unfilled fee", o.unfilledFee);
        assertEq(o.unfilledFee, 0, "a book-rationed inner remainder must come back whole");
    }

    /// CONTROL: the marginal bucket rationed (marginalFill > 0): Y's remainder comes back without the fee.
    function test_F11_control_marginalRationedRemainderPaysNoFee() public {
        Mkt memory m = mkt;
        address x = _player(m, "x", 200e18, 0);
        address y = _player(m, "y", 200e18, 0);
        address se = _player(m, "seller", 0, 200e18);
        _at(D, 1 hours);
        _orderAs(m, x, 2 * D, true, 60, 10.125e18);
        uint256 idY = _orderAs(m, y, 2 * D, true, 0, 101.25e18);
        _orderAs(m, se, 2 * D, false, 0, 50e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p,, bool heavy, uint64 inner, uint64 marg, uint64 rf) = m.hook.bells(2 * D);
        assertTrue(p == 0 && heavy && inner == 1e18 && marg > 0 && marg < 1e18 && rf == 0, "precondition: marginal rationed");
        Out memory o = _claimOut(m, idY, y, true);
        console2.log("Y coin out / IMD refund", o.out, o.refund);
        console2.log("Y unfilled fee", o.unfilledFee);
        assertEq(o.unfilledFee, 0);
    }
}
