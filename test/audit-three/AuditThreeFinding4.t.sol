// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {IERC20T} from "../Base.sol";
import {ReproBase} from "../repro/ReproBase.sol";

/// Audit 3, finding 4: the first swap of each block was sampled whatever its tick, including a tick reached for free
/// through zero liquidity (a dust sell under the coin-only launch seed, where nothing sits below the start price).
/// Correct: a swap that starts where nothing is in range is neither sampled nor the block's checkpoint, so the scored
/// bucket and the next book's reference stay near the only price anyone traded at. On the repo's offline harness
/// (pool at tick 0 seeded coin-only over [0, 12000)). Every defect test asserts the correct behaviour; controls pass.
contract AuditThreeFinding4Test is ReproBase {
    /// the session's mean after two first-of-block swaps, the game's scored bucket at 12:31, the next book's reference
    function _sessionAfter(bool voidSell) internal returns (int256 scored, int24 nextRef, int256 sum, uint256 count) {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
        // block 1: a dust sell of the coin; voidSell: no price limit (the audit report), else limited to the seed's edge
        uint256 c0 = m.coin.balanceOf(trader);
        uint256 i0 = IERC20T(imd).balanceOf(trader);
        vm.prank(trader);
        router.swap(
            m.key,
            IPoolManager.SwapParams(true, -1e15, voidSell ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.getSqrtPriceAtTick(-1)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        console2.log("tick after the dust sell", int256(_tick(m)));
        console2.log("dust sell: coin spent / IMD received (wei)", c0 - m.coin.balanceOf(trader), IERC20T(imd).balanceOf(trader) - i0);
        console2.log("in-range liquidity after the dust sell", uint256(_liq(m)));
        _nextBlock();
        // block 2: a dust buy back; its block's first swap samples where the sell left the price
        _swap(m, true, 1e15);
        console2.log("tick after the dust buy", int256(_tick(m)));
        (sum, count,,) = m.hook.sessionMean();
        _at(D, OPEN + WINDOW_T + 60);
        m.game.settle(D);
        (,,, int24 sc) = m.game.dayState(D);
        scored = sc;
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        nextRef = m.hook.referenceOf(2 * D + 2);
    }

    /// The audit report's reproduction: the dust sell with no limit leaves the price at the minimum tick, which the next
    /// block's first swap samples. Correct: the scored bucket and the next book's reference stay near the only price
    /// anyone traded at (0), |x| < 12,000.
    function test_A3F4_voidSampleMovesTheScoredBucketAndReference() public {
        (int256 scored, int24 nextRef, int256 sum, uint256 count) = _sessionAfter(true);
        console2.log("session tickSum", sum);
        console2.log("session tickCount", count);
        console2.log("game scored bucket", scored);
        console2.log("next book reference", int256(nextRef));
        assertLt(scored < 0 ? -scored : scored, 12_000, "the scored bucket must stay near the traded price");
        assertLt(nextRef < 0 ? -int256(nextRef) : int256(nextRef), 12_000, "the next reference must stay near the traded price");
    }

    /// CONTROL: the same two dust swaps with the sell limited at the seed's edge (tick -1): both samples near 0.
    function test_A3F4_control_noVoidNoMove() public {
        (int256 scored, int24 nextRef,,) = _sessionAfter(false);
        console2.log("game scored bucket", scored);
        console2.log("next book reference", int256(nextRef));
        assertLt(scored < 0 ? -scored : scored, 12_000);
        assertLt(nextRef < 0 ? -int256(nextRef) : int256(nextRef), 12_000);
    }

    /// The finding's consequence (2): after the void sample, an order at the real price (bucket 0) in the next book is
    /// refused BadBucket. Correct: it is accepted.
    function test_A3F4_nextBookRefusesTheRealPrice() public {
        _sessionAfter(true);
        address p = _player(mkt, "f4 player", 100e18, 0);
        _at(D, CLOSE + 1 hours);
        vm.prank(p);
        (bool ok, bytes memory e) =
            address(mkt.hook).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * D + 2, true, int24(0), 10e18)));
        assertTrue(ok, string.concat("a buy at the traded price must be accepted: ", _why(ok, e)));
    }

    /// A swap from the void is not the block's checkpoint either: the next swap in the same block, starting inside
    /// liquidity again, is the block's first checkpoint and is not measured against the void's price. Correct: it goes
    /// through, the checkpoint is its own price, and the session gained exactly one sample from that block.
    function test_A3F4_voidSwapIsNotTheBlocksCheckpoint() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
        _swap(m, false, 1e15); // block 1: the dust sell, no limit, into the void (sampled at 0, where it started)
        (, uint16 n1) = _counters(m);
        _nextBlock();
        _swap(m, true, 1e15); // block 2, first swap: starts in the void, trades once it reaches the seed
        (uint32 cpBlock, uint160 cpSp, , uint16 n2) = m.hook.checkpoint();
        console2.log("block 2 after the void buy: checkpoint block / this block", uint256(cpBlock), vm.getBlockNumber());
        console2.log("samples after block 1 / after the void buy", uint256(n1), uint256(n2));
        uint160 before = _sqrt(m);
        vm.prank(trader);
        (bool ok, bytes memory e) = address(router).call(
            abi.encodeCall(
                PoolSwapTest.swap,
                (m.key, IPoolManager.SwapParams(false, -1e15, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), bytes(""))
            )
        );
        assertFalse(_has(e, MarketHoursHook.PriceMoved.selector), "the second swap was measured against the void's price");
        assertTrue(ok, _why(ok, e));
        (uint32 cpBlock2, uint160 cpSp2, , uint16 n3) = m.hook.checkpoint();
        assertEq(uint256(cpBlock2), vm.getBlockNumber(), "the block now has a checkpoint");
        assertEq(cpSp2, before, "the checkpoint is the second swap's starting price, inside liquidity");
        assertEq(n3, n1 + 1, "the block added exactly one sample, the in-range one");
        cpSp;
        n2;
    }
}
