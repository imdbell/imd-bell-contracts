// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursCoin} from "../src/MarketHoursCoin.sol";
import {BellGame} from "../src/BellGame.sol";
import {SwarmBudget} from "../src/SwarmBudget.sol";
import {LaunchShape} from "../script/LaunchShape.sol";
import {SeedFigures} from "../script/SeedFigures.s.sol";
import {Ringer} from "./Ringer.sol";
import {IERC20T} from "./Base.sol";

/// The launch works whichever way the coin sorts against IMD. Two markets are built through the launch shape
/// (script/LaunchShape.sol) from one planned range, one with the coin as currency0 and one with it as currency1, and the
/// same day is played on both in bucket terms (IMD per coin). Every `imdIs0` path in the hook and the game is crossed on
/// the way: the pool key (`_key`), the reference at initialisation (`beforeInitialize`), the size cap in all four
/// swap kinds (`_sizeCap`), the residual swap's direction and price limit (`unlockCallback`), the zero-match reference
/// from the session's mean (`_scan`) and the game's scored bucket (`settle`). The two must agree.
abstract contract Mirror is Ringer {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // the planned shape, as written for a currency0 coin: start at the lower edge, a bucket away from zero so that a
    // sign error cannot hide at bucket 0
    int24 internal constant M_TL = 6_000;
    int24 internal constant M_TU = 18_000;
    uint256 internal constant TAG_M0 = 0x7a;
    uint256 internal constant TAG_M1 = 0x7b;

    /// a coin from `new`, its CREATE2 salt searched so it sorts below IMD (`above` false) or above it
    function _newCoinSide(uint256 tag, bool above) internal returns (MarketHoursCoin c) {
        bytes32 h = keccak256(abi.encodePacked(type(MarketHoursCoin).creationCode, abi.encode("Test Coin", "TEST")));
        uint256 i = tag << 128;
        while ((_create2At(bytes32(i), h) > imd) != above) ++i;
        c = new MarketHoursCoin{salt: bytes32(i)}("Test Coin", "TEST");
        require((address(c) > imd) == above, "coin landed on the wrong side of IMD");
    }

    /// A market launched as the factory would launch it with the deploy's shape: the pool key in sorted order, the price
    /// and the coin-only range from LaunchShape.
    function _mirrorMarket(uint256 tag, bool coinAbove) internal returns (Mkt memory m, LaunchShape.Shape memory sh) {
        m.coin = _newCoinSide(tag, coinAbove);
        bytes memory init = _hookInit(type(MarketHoursHook).creationCode, address(m.coin));
        (bytes32 salt, address at,) = _mineSalt(keccak256(init), tag << 128, false);
        address hookAt = _create2(init, salt);
        require(hookAt == at && _hasFlags(hookAt), "hook landed off the mined address");
        m.hook = MarketHoursHook(hookAt);
        m.game = BellGame(m.hook.game());
        m.budget = SwarmBudget(m.hook.swarmBudget());
        sh = LaunchShape.shapeOf(address(m.coin), imd, M_TL, M_TU);
        (address c0, address c1) = sh.coinIs0 ? (address(m.coin), imd) : (imd, address(m.coin));
        m.key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(hookAt));
        assertEq(abi.encode(m.hook.poolKey()), abi.encode(m.key), "the hook's own key is the sorted one");
        manager.initialize(m.key, sh.sqrtPriceX96);
        uint256 imd0 = IERC20T(imd).balanceOf(address(this));
        uint256 coin0 = m.coin.balanceOf(address(this));
        m.coin.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(sh.tickLower, sh.tickUpper, int256(uint256(WIDE_L)), 0), "");
        (uint256 wantCoin, uint256 wantImd) = LaunchShape.seed(sh, WIDE_L);
        assertEq(wantImd, 0, "the shape's seed is coin-only");
        assertEq(IERC20T(imd).balanceOf(address(this)), imd0, "the seed took no IMD");
        assertEq(coin0 - m.coin.balanceOf(address(this)), wantCoin, "the seed took the shape's coin");
        m.coin.transfer(trader, 10_000_000e18);
        vm.startPrank(trader);
        m.coin.approve(address(router), type(uint256).max);
        m.coin.approve(hookAt, type(uint256).max);
        IERC20T(imd).approve(hookAt, type(uint256).max);
        vm.stopPrank();
    }

    function _imdIs0(Mkt memory m) internal view returns (bool) {
        return Currency.unwrap(m.key.currency0) == imd;
    }

    /// the pool's price as a bucket coordinate (IMD per coin), not rounded to the grid
    function _bucketTick(Mkt memory m) internal view returns (int24) {
        int24 t = _tick(m);
        return _imdIs0(m) ? -t : t;
    }

    /// exact input through the router, either side: `imdIn` buys the coin with IMD
    function _swapM(Mkt memory m, bool imdIn, uint256 amountIn) internal {
        _swapMS(m, imdIn, -int256(amountIn));
    }

    /// a swap with a signed amount (v4: negative = exact input of what is paid, positive = exact output of what is got)
    function _swapMS(Mkt memory m, bool imdIn, int256 amountSpecified) internal {
        bool zfo = imdIn == _imdIs0(m);
        vm.prank(trader);
        router.swap(
            m.key,
            IPoolManager.SwapParams(zfo, amountSpecified, zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _close(uint256 a, uint256 b, string memory what) internal pure {
        uint256 d = a > b ? a - b : b - a;
        uint256 tol = (a > b ? a : b) / 1e12;
        if (tol < 1e6) tol = 1e6;
        require(d <= tol, string.concat(what, ": the two orientations differ beyond rounding"));
    }

    // ── the launch shape itself: the planned figures, both ways ──
    function test_M_launchShapeBothWays() public {
        int24 tl = -128_940;
        int24 tu = 887_220;
        uint128 l = 1_395_488_085_257_384_418_720_526;
        address lo = address(0x1000);
        address hi = address(0xF000);
        address imdAt = address(0x8000);
        LaunchShape.Shape memory a = LaunchShape.shapeOf(lo, imdAt, tl, tu);
        LaunchShape.Shape memory b = LaunchShape.shapeOf(hi, imdAt, tl, tu);
        assertTrue(a.coinIs0 && !b.coinIs0, "the side follows the sort");
        assertEq(a.tickLower, tl);
        assertEq(a.tickUpper, tu);
        assertEq(a.startTick, tl, "currency0 coin: start at the planned lower edge");
        assertEq(b.tickLower, -tu, "currency1 coin: the range mirrored");
        assertEq(b.tickUpper, -tl, "currency1 coin: the range mirrored");
        assertEq(b.startTick, -tl, "currency1 coin: start at the mirrored edge");
        assertEq(a.sqrtPriceX96, TickMath.getSqrtPriceAtTick(tl));
        assertEq(b.sqrtPriceX96, TickMath.getSqrtPriceAtTick(-tl));
        assertEq(a.startBucket, tl, "the start price in IMD per coin");
        assertEq(b.startBucket, tl, "the same start price in IMD per coin");
        assertEq(TickMath.getTickAtSqrtPrice(b.sqrtPriceX96), b.startTick, "the pool's tick at the start is the shape's");
        (uint256 ca, uint256 ia) = LaunchShape.seed(a, l);
        (uint256 cb, uint256 ib) = LaunchShape.seed(b, l);
        assertEq(ia, 0, "coin-only seed, currency0 coin");
        assertEq(ib, 0, "coin-only seed, currency1 coin");
        _close(ca, cb, "seed coin");
        // the start price, IMD per coin, both ways: sqrtP^2 for a currency0 coin, 1/sqrtP^2 for a currency1 coin
        uint256 pa = uint256(a.sqrtPriceX96) * a.sqrtPriceX96 >> 96; // Q96 IMD per coin
        uint256 pb = (uint256(1) << 192) / b.sqrtPriceX96 * (uint256(1) << 96) / b.sqrtPriceX96; // Q96 IMD per coin
        console2.log(string.concat("(M) model range, coin currency1: tickLower / tickUpper ", vm.toString(b.tickLower), " ", vm.toString(b.tickUpper)));
        console2.log("(M) start sqrtPriceX96 currency0 / currency1", uint256(a.sqrtPriceX96), uint256(b.sqrtPriceX96));
        console2.log("(M) start price IMD per coin (Q96) currency0 / currency1", pa, pb);
        console2.log("(M) seed coin (wei) currency0 / currency1", ca, cb);
        uint256 dp = pa > pb ? pa - pb : pb - pa;
        assertLe(dp * 1e9, pa, "the start price agrees to 1e-9 both ways");
        // the swap cap's figure, both ways
        SeedFigures fig = new SeedFigures();
        (int24 xa, uint256 ma) = fig.figuresFor(l, a.startBucket, 12_500, true);
        (int24 xb, uint256 mb) = fig.figuresFor(l, b.startBucket, 12_500, false);
        (int24 xo, uint256 mo) = fig.figures(l, tl, 12_500);
        assertEq(xa, xb);
        assertEq(xa, xo);
        assertEq(ma, mo, "the currency0 figure is build 2's");
        _close(ma, mb, "MAX_SWAP_IMD");
        console2.log("(M) MAX_SWAP_IMD (wei) currency0 / currency1", ma, mb);
    }

    // ── the day, both ways ──
    struct Side {
        Mkt m;
        uint256 b1;
        uint256 b2;
        uint256 s1;
        uint256 sClose;
    }

    function test_M_dayBothWays() public {
        _at(D - 1, 21 hours);
        Side memory x;
        Side memory y;
        LaunchShape.Shape memory shx;
        LaunchShape.Shape memory shy;
        (x.m, shx) = _mirrorMarket(TAG_M0, false);
        (y.m, shy) = _mirrorMarket(TAG_M1, true);
        assertTrue(!_imdIs0(x.m) && _imdIs0(y.m), "one market each way");
        assertEq(shx.startBucket, shy.startBucket, "one start price in IMD per coin");
        // beforeInitialize: the reference is the start bucket both ways
        assertEq(x.m.hook.lastCleared(), M_TL, "reference from the launch tick, coin currency0");
        assertEq(y.m.hook.lastCleared(), M_TL, "reference from the launch tick, coin currency1");
        _sizeCapBothWays(x.m);
        _sizeCapBothWays(y.m);
        _openDay(x);
        _openDay(y);
        _compareBells(x.m, y.m, 2 * D);
        _sessionAndSettle(x.m);
        _sessionAndSettle(y.m);
        (,, bool fx, int24 scx) = x.m.game.dayState(D);
        (,, bool fy, int24 scy) = y.m.game.dayState(D);
        assertTrue(fx && fy, "both scored from the window");
        assertEq(scx, scy, "the game's scored bucket is the same both ways");
        console2.log("(M) scored bucket both ways", int256(scx));
        _zeroMatchClose(x);
        _zeroMatchClose(y);
        _compareBells(x.m, y.m, 2 * D + 1);
        _claimsAgree(x, y);
    }

    /// _sizeCap: IMD in, coin in, IMD out, coin out, at the cap and over it (each over-cap swap is refused before it
    /// moves anything; an at-cap swap goes through and is undone)
    function _sizeCapBothWays(Mkt memory m) internal {
        // the size cap is checked in session only: an empty book's bell opens it, and everything is undone after
        uint256 snap = vm.snapshotState();
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        uint256 cap = m.hook.maxSwapImd();
        uint160 sp = _sqrt(m);
        // the coin worth `cap` IMD at the pool's price, in the coin's currency
        uint256 capCoin = _imdIs0(m)
            ? uint256(cap) * sp / (uint256(1) << 96) * sp / (uint256(1) << 96) // coin = IMD * (coin per IMD)
            : uint256(cap) * (uint256(1) << 96) / sp * (uint256(1) << 96) / sp; // coin = IMD / (IMD per coin)
        _nextBlock();
        _expectCapRevert(m, true, -int256(cap + 1)); // IMD in, exact input
        _expectCapRevert(m, false, -int256(capCoin * 101 / 100)); // coin in, exact input
        _expectCapRevert(m, false, int256(cap + 1)); // coin in, IMD out exact
        _expectCapRevert(m, true, int256(capCoin * 101 / 100)); // IMD in, coin out exact
        uint256 s2 = vm.snapshotState();
        _swapMS(m, true, -int256(cap)); // at the cap: passes
        vm.revertToState(s2);
        _swapMS(m, false, -int256(capCoin * 99 / 100)); // coin worth just under the cap: passes
        vm.revertToState(s2);
        _swapMS(m, false, int256(cap * 99 / 100)); // IMD out just under the cap: passes
        vm.revertToState(s2);
        _swapMS(m, true, int256(capCoin * 99 / 100)); // coin out worth just under the cap: passes
        vm.revertToState(snap);
    }

    function _expectCapRevert(Mkt memory m, bool imdIn, int256 amountSpecified) internal {
        bool zfo = imdIn == _imdIs0(m);
        vm.prank(trader);
        try router.swap(
            m.key,
            IPoolManager.SwapParams(zfo, amountSpecified, zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            fail("the size cap let an over-cap swap through");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.SwapTooLarge.selector), "refused by the size cap");
        }
    }

    /// the opening book: a buy-heavy cross whose remainder goes through the pool (the residual swap's direction and
    /// its fee-inclusive limit), plus a small sell
    function _openDay(Side memory s) internal {
        _at(D, 1 hours);
        // P* lands at the big buy's bucket, far enough above the pool (more than the fee's 126 ticks) for the residual
        // to move it; the small buy at the start bucket is not reached
        s.s1 = _order(s.m, 2 * D, false, M_TL - 60, 5e18);
        s.b1 = _order(s.m, 2 * D, true, M_TL + 600, 960e18);
        s.b2 = _order(s.m, 2 * D, true, M_TL, 5e18);
        _at(D, OPEN);
        _nextBlock();
        s.m.hook.ringOpen();
        (int24 p,, bool bh,,, uint64 rf) = s.m.hook.bells(2 * D);
        assertTrue(bh, "buy-heavy");
        assertGt(rf, 0, "the residual went through the pool");
        // the residual never pays past price(P*): the pool sits at or below P* in IMD per coin
        assertLe(_bucketTick(s.m), p, "the residual swap stopped inside P*");
        assertEq(IERC20T(imd).balanceOf(address(s.m.hook)), s.m.hook.imdAccounted(), "IMD accounting after the ring");
        assertEq(s.m.coin.balanceOf(address(s.m.hook)), s.m.hook.coinAccounted(), "coin accounting after the ring");
    }

    function _compareBells(Mkt memory a, Mkt memory b, uint256 s) internal view {
        (int24 pa, bool ra, bool ha, uint64 ia, uint64 ma, uint64 fa) = a.hook.bells(s);
        (int24 pb, bool rb, bool hb, uint64 ib, uint64 mb, uint64 fb) = b.hook.bells(s);
        console2.log(string.concat("(M) bell ", vm.toString(s), ": P* both ways ", vm.toString(pa), " ", vm.toString(pb)));
        console2.log("(M) residualFill both ways", uint256(fa), uint256(fb));
        assertTrue(ra && rb);
        assertEq(pa, pb, "P* is the same bucket both ways");
        assertEq(ha, hb, "the same side is heavy");
        assertEq(ia, ib, "the same inner fill");
        assertEq(ma, mb, "the same marginal fill");
        _close(fa, fb, "residual fill");
    }

    /// the session: three swaps in the window, one after it (the freeze), then the settle from the window's mean
    function _sessionAndSettle(Mkt memory m) internal {
        _at(D, OPEN + 5 minutes);
        _nextBlock();
        _swapM(m, true, 30e18);
        _at(D, OPEN + 10 minutes);
        _nextBlock();
        _swapM(m, false, 4e18);
        _at(D, OPEN + 20 minutes);
        _nextBlock();
        _swapM(m, true, 20e18);
        _at(D, OPEN + WINDOW_T + 60);
        _nextBlock();
        _swapM(m, true, 1e18);
        (int256 sum, uint256 n,, bool frozen) = m.hook.sessionMean();
        assertTrue(frozen && n == 3, "three checkpoints, frozen");
        m.game.settle(D);
        (,,, int24 sc) = m.game.dayState(D);
        assertEq(sc, _nearest(_imdIs0(m) ? -(sum / int256(n)) : sum / int256(n)), "scored from the window's mean, in buckets");
    }

    /// the closing book with only sellers: no match, so the reference is the session's mean bucket (`_scan`'s
    /// zero-match path), read from the live counters
    function _zeroMatchClose(Side memory s) internal {
        _at(D, OPEN + 1 hours);
        _nextBlock();
        _swapM(s.m, true, 2e18);
        s.sClose = _order(s.m, 2 * D + 1, false, M_TL + 1200, 1e18);
        (,, int48 sum, uint16 n) = s.m.hook.checkpoint();
        int24 want = _nearest(_imdIs0(s.m) ? -(int256(sum) / int256(uint256(n))) : int256(sum) / int256(uint256(n)));
        _at(D, CLOSE);
        _nextBlock();
        s.m.hook.ringClose();
        (int24 p,,,,,) = s.m.hook.bells(2 * D + 1);
        assertGt(n, 0, "the session traded");
        assertEq(p, want, "a zero-match close takes the session's mean bucket");
    }

    function _claimsAgree(Side memory x, Side memory y) internal {
        uint256[4] memory ix = [x.s1, x.b1, x.b2, x.sClose];
        uint256[4] memory iy = [y.s1, y.b1, y.b2, y.sClose];
        for (uint256 i; i < 4; ++i) {
            (uint256 ox, uint256 rx) = _claimOut(x.m, ix[i]);
            (uint256 oy, uint256 ry) = _claimOut(y.m, iy[i]);
            _close(ox, oy, "claim out");
            _close(rx, ry, "claim refund");
        }
        assertEq(IERC20T(imd).balanceOf(address(x.m.hook)), x.m.hook.imdAccounted(), "IMD accounting, coin currency0");
        assertEq(IERC20T(imd).balanceOf(address(y.m.hook)), y.m.hook.imdAccounted(), "IMD accounting, coin currency1");
        assertEq(x.m.coin.balanceOf(address(x.m.hook)), x.m.hook.coinAccounted(), "coin accounting, coin currency0");
        assertEq(y.m.coin.balanceOf(address(y.m.hook)), y.m.hook.coinAccounted(), "coin accounting, coin currency1");
    }

    function _claimOut(Mkt memory m, uint256 id) internal returns (uint256 out, uint256 refund) {
        (, , bool buy,,) = m.hook.orderInfo(id);
        (address gets, address back) = buy ? (address(m.coin), imd) : (imd, address(m.coin));
        uint256 g0 = IERC20T(gets).balanceOf(trader);
        uint256 b0 = IERC20T(back).balanceOf(trader);
        m.hook.claim(id);
        out = IERC20T(gets).balanceOf(trader) - g0;
        refund = IERC20T(back).balanceOf(trader) - b0;
    }
}
