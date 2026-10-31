// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// The launch's pool shape from the planned one, whichever way the coin sorts against IMD. The factory assigns the
/// launch number and the coin's address follows from it and the name, so the side is not ours to choose. The planned
/// range [tl, tu] and its start price at the lower edge are written for a coin that is currency0, where a pool tick is
/// a bucket (IMD per coin). When the coin is currency1 the pool tick is minus the bucket, so the range is mirrored to
/// [-tu, -tl] and the start sits at -tl, the mirrored edge (now the upper one): the seed is coin-only either way, and the
/// start price in IMD per coin, the bucket tl, is the same.
library LaunchShape {
    struct Shape {
        bool coinIs0;
        int24 tickLower;
        int24 tickUpper;
        int24 startTick;
        uint160 sqrtPriceX96;
        /// the start price as a bucket, IMD per coin, whichever side the coin is
        int24 startBucket;
    }

    function shapeOf(address coin, address imd, int24 tl, int24 tu) internal pure returns (Shape memory s) {
        require(coin != imd, "LaunchShape: the coin is IMD");
        require(tl < tu, "LaunchShape: the planned range is empty");
        s.coinIs0 = coin < imd;
        if (s.coinIs0) {
            (s.tickLower, s.tickUpper, s.startTick) = (tl, tu, tl);
        } else {
            (s.tickLower, s.tickUpper, s.startTick) = (-tu, -tl, -tl);
        }
        s.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(s.startTick);
        s.startBucket = s.coinIs0 ? s.startTick : -s.startTick;
    }

    /// The seed at liquidity `l` over the shape's range at its start price, in (coin, IMD): at the lower edge a
    /// currency0 coin holds the whole position, at the upper edge a currency1 coin does, so the IMD side is zero.
    function seed(Shape memory s, uint128 l) internal pure returns (uint256 coinAmt, uint256 imdAmt) {
        uint160 sa = TickMath.getSqrtPriceAtTick(s.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(s.tickUpper);
        uint160 sp = s.sqrtPriceX96;
        // v4's split of a position at price sp: token0 over [max(sp, sa), sb], token1 over [sa, min(sp, sb)]
        uint256 a0 = sp < sb ? SqrtPriceMath.getAmount0Delta(sp > sa ? sp : sa, sb, l, true) : 0;
        uint256 a1 = sp > sa ? SqrtPriceMath.getAmount1Delta(sa, sp < sb ? sp : sb, l, true) : 0;
        (coinAmt, imdAmt) = s.coinIs0 ? (a0, a1) : (a1, a0);
    }
}
