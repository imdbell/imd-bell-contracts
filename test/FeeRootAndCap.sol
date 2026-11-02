// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursCoin} from "../src/MarketHoursCoin.sol";
import {Base} from "./Base.sol";

/// The hook with two of its internals exposed, so the tests read the deployed code's own constant and function rather
/// than a copy of them. Deployed at a mined flag address like the hook (its constructor validates the flags).
contract FeeInwardProbe is MarketHoursHook {
    constructor(Params memory p) MarketHoursHook(p) {}

    function feeRoot() external pure returns (uint256) {
        return FEE_ROOT_Q96;
    }

    function capDown() external pure returns (uint256 r, uint256 buckets) {
        return (CAP_DOWN, RESIDUAL_MAX_BUCKETS);
    }

    function feeInward(uint160 edge, bool zfo) external pure returns (uint160) {
        return _feeInward(edge, zfo);
    }
}

/// The fee root's constant and the residual cap's constants, read from the deployed code.
abstract contract FeeRootAndCap is Base {
    uint256 internal constant POOL_FEE = 12_500; // the hook's FEE, the only fee its pool can have

    function _probe() internal returns (FeeInwardProbe p) {
        MarketHoursCoin c = _newCoin(0x3480);
        bytes memory init = abi.encodePacked(type(FeeInwardProbe).creationCode, abi.encode(_params(address(c))));
        (bytes32 salt, address at,) = _mineSalt(keccak256(init), 0x3480 << 128, false);
        p = FeeInwardProbe(_create2(init, salt));
        require(address(p) == at && _hasFlags(at), "probe landed off the mined address");
    }

    /// _feeInward with its root computed at run time (Math.sqrt), as the audited code had it: the reference the constant
    /// must reproduce exactly.
    function _feeInwardComputed(uint160 edge, bool zfo, uint24 fee) internal pure returns (uint160) {
        uint256 rootQ96 = Math.sqrt(((1_000_000 - uint256(fee)) << 192) / 1_000_000);
        return uint160(zfo ? FullMath.mulDivRoundingUp(edge, 2 ** 96, rootQ96) : FullMath.mulDiv(edge, rootQ96, 2 ** 96));
    }

    /// The precomputed root is Math.sqrt of the expression the audited code evaluated at run time, for the pool's one fee; the control:
    /// the same expression at a fee one ppm away gives a different root, so the equality is not vacuous.
    function test_H_feeRootIsTheSqrtOfTheFee() public {
        FeeInwardProbe p = _probe();
        uint256 want = Math.sqrt(((1_000_000 - POOL_FEE) << 192) / 1_000_000);
        assertEq(p.feeRoot(), want, "FEE_ROOT_Q96 = sqrt(((1e6 - FEE) << 192) / 1e6)");
        assertEq(want, 78_731_429_325_869_267_202_663_517_946, "the figure, recomputed independently");
        assertTrue(Math.sqrt(((1_000_000 - (POOL_FEE + 1)) << 192) / 1_000_000) != want, "control: another fee, another root");
    }

    /// _feeInward returns exactly the computed value for a spread of edges, both directions: the ends of the tick range, the
    /// band's edges around 0 and the real seed's launch tick, single buckets, and the extreme sqrt prices.
    function test_H_feeInwardSameAsComputedOnASpread() public {
        FeeInwardProbe p = _probe();
        int24[15] memory ts = [
            int24(-887_220), -600_000, -140_940, -128_940, -116_940, -12_000, -60, 0, 60, 12_000, 116_940, 128_940,
            140_940, 600_000, 887_220
        ];
        uint256 n;
        for (uint256 i; i < ts.length; ++i) {
            uint160 e = TickMath.getSqrtPriceAtTick(ts[i]);
            for (uint256 z; z < 2; ++z) {
                assertEq(p.feeInward(e, z == 1), _feeInwardComputed(e, z == 1, uint24(POOL_FEE)), "same as computed");
                ++n;
            }
        }
        uint160[4] memory xs = [TickMath.MIN_SQRT_PRICE, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1, TickMath.MAX_SQRT_PRICE];
        for (uint256 i; i < xs.length; ++i) {
            for (uint256 z; z < 2; ++z) {
                assertEq(p.feeInward(xs[i], z == 1), _feeInwardComputed(xs[i], z == 1, uint24(POOL_FEE)), "same as computed at the extremes");
                ++n;
            }
        }
        assertEq(n, 38, "every edge compared, both ways");
        // control: the comparison can fail (a down limit moves up, an up limit moves down, never equal to the edge)
        uint160 e0 = TickMath.getSqrtPriceAtTick(0);
        assertGt(p.feeInward(e0, true), e0, "control: down, the limit is above the edge");
        assertLt(p.feeInward(e0, false), e0, "control: up, the limit is below the edge");
    }

    /// The residual cap: 120 buckets, and its divisor is exactly the sqrt price of 120 x 60 ticks (control: one bucket more or
    /// fewer is a different divisor).
    function test_H_capIs120BucketsAsASqrtPrice() public {
        FeeInwardProbe p = _probe();
        (uint256 r, uint256 k) = p.capDown();
        assertEq(k, 120, "RESIDUAL_MAX_BUCKETS = 120");
        assertEq(r, TickMath.getSqrtPriceAtTick(int24(int256(k)) * 60), "CAP_DOWN = getSqrtPriceAtTick(120 x 60)");
        assertTrue(r != TickMath.getSqrtPriceAtTick(119 * 60) && r != TickMath.getSqrtPriceAtTick(121 * 60), "control");
    }

    /// The same over any sqrt price in the pool's range.
    function testFuzz_H_feeInwardSameAsComputed(uint160 e, bool zfo) public {
        e = uint160(bound(e, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        FeeInwardProbe p = _probe();
        assertEq(p.feeInward(e, zfo), _feeInwardComputed(e, zfo, uint24(POOL_FEE)), "same as computed");
    }
}
