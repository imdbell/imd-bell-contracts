// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// The two figures the launch sets from its own seed depth, printed for candidate seeds. Never broadcasts.
///   ticks(X)       = floor(ln(1 + X / 10^4) / ln 1.0001), the most ticks a block's price may move
///   MAX_SWAP_IMD   = the IMD it costs to move the coin's price ticks(X) up from the launch bucket at the seed's
///                    liquidity, gross of the pool fee: one maximum swap moves the price by at most X. "Up" is the coin
///                    getting dearer in IMD: the pool tick rises when the coin is currency0 and falls when it is
///                    currency1, so the IMD side is currency1 or currency0 accordingly.
/// Run: forge script script/SeedFigures.s.sol --sig "seedTable(uint128,int24,uint24)" <L> <launchBucket> <fee>
contract SeedFigures is Script {
    uint256 internal constant X_BPS = 500;
    uint256 internal constant Q96 = 1 << 96;

    /// ln(1.0001^n) = n * ln 1.0001; the largest n with 1.0001^n <= 1 + X/10^4, found by walking the tick table
    function ticksOf(uint256 xBps) public pure returns (int24 n) {
        uint160 target = uint160(FullMath.mulDiv(Q96, _sqrtBps(10_000 + xBps), 1 << 48)); // sqrt(1 + X) in Q96
        while (TickMath.getSqrtPriceAtTick(n + 1) <= target) ++n;
    }

    /// sqrt(b / 10^4) in Q48, by integer square root of (b << 96) / 10^4
    function _sqrtBps(uint256 b) internal pure returns (uint256) {
        uint256 x = (b << 96) / 10_000;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// IMD in to move the pool `ticks` up from `tick` at liquidity `l`, gross of `fee` ppm, IMD as currency1
    function imdToMove(uint128 l, int24 tick, int24 ticks, uint24 fee) public pure returns (uint256) {
        uint256 net = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick + ticks), l, true);
        return FullMath.mulDivRoundingUp(net, 1_000_000, 1_000_000 - uint256(fee));
    }

    /// IMD in to move the pool `ticks` down from `tick` at liquidity `l`, gross of `fee` ppm, IMD as currency0: the
    /// coin (currency1) gets dearer in IMD as the pool's coin-per-IMD price falls
    function imdToMove0(uint128 l, int24 tick, int24 ticks, uint24 fee) public pure returns (uint256) {
        uint256 net = SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(tick - ticks), TickMath.getSqrtPriceAtTick(tick), l, true);
        return FullMath.mulDivRoundingUp(net, 1_000_000, 1_000_000 - uint256(fee));
    }

    /// The figures for a coin that is currency0 (pool tick = bucket).
    function figures(uint128 l, int24 launchTick, uint24 fee)
        public
        pure
        returns (int24 ticksX, uint256 maxSwapImd)
    {
        return figuresFor(l, launchTick, fee, true);
    }

    /// The figures for either side: `startBucket` is the launch price in IMD per coin (the pool tick when the coin is
    /// currency0, minus the pool tick when it is currency1).
    function figuresFor(uint128 l, int24 startBucket, uint24 fee, bool coinIs0)
        public
        pure
        returns (int24 ticksX, uint256 maxSwapImd)
    {
        ticksX = ticksOf(X_BPS);
        maxSwapImd = coinIs0 ? imdToMove(l, startBucket, ticksX, fee) : imdToMove0(l, -startBucket, ticksX, fee);
    }

    function seedTable(uint128 l, int24 launchTick, uint24 fee) external pure {
        uint128[3] memory ls = [l / 2, l, l * 2];
        string[3] memory label = ["half", "the seed", "double"];
        console2.log("X = 500 bps -> ticks(X)", int256(ticksOf(X_BPS)));
        for (uint256 i; i < 3; ++i) {
            (int24 t, uint256 ms) = figures(ls[i], launchTick, fee);
            console2.log(label[i]);
            console2.log("   L", uint256(ls[i]));
            console2.log("   ticks(X)", int256(t));
            console2.log("   MAX_SWAP_IMD (wei)", ms);
        }
    }
}
