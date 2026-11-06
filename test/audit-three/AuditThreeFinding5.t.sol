// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MarketHoursCoin} from "src/MarketHoursCoin.sol";
import {IERC20T} from "../Base.sol";
import {ReproBase} from "../repro/ReproBase.sol";

/// Audit 3, finding 5: beforeInitialize rounded the initial tick to a bucket with no clamp, so an initial price at
/// |tick| >= 887,251 set the reference to +-887,280, past MAX_TICK, and the opening bell could never ring. Correct: the
/// initial reference is held to +-875,220 as the bell's own reference is, the first bell rings from any initial price,
/// and no bucket above the grid's last one (887,220) enters a band. Each test is the audit's reproduction or its mirror.
contract AuditThreeFinding5Test is ReproBase {
    /// A hook initialised by the factory (this test) at `tick` with no position; returns it and its key.
    function _initAt(uint256 tag, int24 tick) internal returns (MarketHoursHook h, PoolKey memory key) {
        MarketHoursCoin c = _newCoin(tag);
        h = MarketHoursHook(_deployHook(_params(address(c)), tag));
        key = PoolKey(Currency.wrap(address(c)), Currency.wrap(imd), 12_500, 60, IHooks(address(h)));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
    }

    function _player2(MarketHoursHook h, string memory label) internal returns (address p) {
        p = makeAddr(label);
        _fundImd(p, 100e18);
        MarketHoursCoin(h.coin()).transfer(p, 0);
        vm.startPrank(p);
        IERC20T(imd).approve(address(h), type(uint256).max);
        vm.stopPrank();
    }

    /// The audit report's reproduction: initialised at tick 887,260. Correct: the reference is held to 875,220, a buy at
    /// 887,280 (past the grid) is refused BadBucket, and the opening bell rings.
    function test_A3F5_extremeInitialPriceBellCannotRing() public {
        (MarketHoursHook h,) = _initAt(0x5a1, 887_260);
        console2.log("lastCleared after init at 887,260", int256(h.lastCleared()));
        assertEq(h.lastCleared(), 875_220, "the initial reference is held where its whole band is a valid price");
        _at(D, 1 hours);
        address p = _player2(h, "f5 player");
        vm.prank(p);
        (bool okBuy, bytes memory eb) = address(h).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, true, int24(887_280), 1e18)));
        console2.log(string.concat("buy at 887,280: ", _why(okBuy, eb)));
        assertFalse(okBuy, "a bucket past the grid entered the band");
        assertTrue(_has(eb, MarketHoursHook.BadBucket.selector), "refused BadBucket");
        vm.prank(p);
        (bool okTop, bytes memory et) = address(h).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * D, true, int24(887_220), 1e18)));
        assertTrue(okTop, string.concat("the grid's last bucket is in the band: ", _why(okTop, et)));
        _at(D, OPEN);
        (bool ok, bytes memory e) = address(h).call(abi.encodeCall(MarketHoursHook.ringOpen, ()));
        console2.log(string.concat("ringOpen: ", _why(ok, e)));
        assertTrue(ok, "the opening bell must ring");
    }

    /// The mirror: initialised at tick -887,260. Correct: the reference is held to -875,220 and the bell rings.
    function test_A3F5_extremeLowInitialPriceBellRings() public {
        (MarketHoursHook h,) = _initAt(0x5a3, -887_260);
        console2.log("lastCleared after init at -887,260", int256(h.lastCleared()));
        assertEq(h.lastCleared(), -875_220, "the initial reference is held where its whole band is a valid price");
        _at(D, OPEN);
        (bool ok, bytes memory e) = address(h).call(abi.encodeCall(MarketHoursHook.ringOpen, ()));
        assertTrue(ok, string.concat("the opening bell must ring: ", _why(ok, e)));
    }

    /// CONTROL: initialised at tick 887,240 (bucket 887,220, the grid's last valid one): the bell rings; and inside the
    /// held range the initial reference is the nearest bucket, unchanged (tick 875,200 -> 875,220; tick 30 -> 60).
    function test_A3F5_control_lastValidBucketRings() public {
        (MarketHoursHook h,) = _initAt(0x5a2, 887_240);
        console2.log("lastCleared after init at 887,240", int256(h.lastCleared()));
        _at(D, OPEN);
        (bool ok, bytes memory e) = address(h).call(abi.encodeCall(MarketHoursHook.ringOpen, ()));
        assertTrue(ok, _why(ok, e));
        (MarketHoursHook h2,) = _initAt(0x5a4, 875_200);
        assertEq(h2.lastCleared(), 875_220, "inside the held range: the nearest bucket");
        (MarketHoursHook h3,) = _initAt(0x5a5, 31);
        assertEq(h3.lastCleared(), 60, "inside the held range: the nearest bucket");
    }
}
