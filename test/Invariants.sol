// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {Scenarios} from "./Scenarios.sol";
import {Base, IERC20T} from "./Base.sol";
import {ReentrantCoin} from "./ReentrantCoin.sol";
import {MsgSenderRouter} from "./MsgSenderRouter.sol";

/// One unit test per hook invariant. Environment-agnostic like Scenarios.
abstract contract Invariants is Scenarios {
    uint256 internal constant Q96 = 1 << 96;

    bytes32 internal constant CLAIMED = keccak256("Claimed(uint256,address,uint256,uint256)");
    bytes32 internal constant FEE_TAKEN = keccak256("FeeTaken(uint256,uint256)");
    bytes32 internal constant CANCELLED = keccak256("OrderCancelled(uint256,uint256)");

    function _i2c(uint256 i, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(i, Q96, sp), Q96, sp);
    }

    function _c2i(uint256 c, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(c, sp, Q96), sp, Q96);
    }

    function _up(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

    function _claimLog(Vm.Log[] memory logs, uint256 id)
        internal
        pure
        returns (uint256 out, uint256 refund, uint256 fee, uint256 nClaimed, uint256 nFee)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[1] != bytes32(id)) continue;
            if (logs[i].topics[0] == CLAIMED) {
                (out, refund) = abi.decode(logs[i].data, (uint256, uint256));
                ++nClaimed;
            } else if (logs[i].topics[0] == FEE_TAKEN) {
                fee = abi.decode(logs[i].data, (uint256));
                ++nFee;
            }
        }
    }

    function _accrued(Mkt memory m) internal view returns (uint256) {
        return m.hook.burnAccrued() + m.hook.networkAccrued() + m.hook.feeWalletImdAccrued() + m.hook.swarmAccrued()
            + m.hook.bellPurseAccrued();
    }

    // ── two bells ──
    function test_I5_twoBellsOncePerDay() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D, OPEN + 60);
        try m.hook.ringOpen() {
            fail("two bells: a second ringOpen the same day must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.BellAlreadyRung.selector), "two bells: second ringOpen refused for the wrong reason");
        }
        _at(D, CLOSE - 1);
        try m.hook.ringClose() {
            fail("two bells: ringClose at 15:59:59 must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.NotAtBell.selector), "two bells: early ringClose refused for the wrong reason");
        }
        _at(D, CLOSE);
        m.hook.ringClose();
        try m.hook.ringClose() {
            fail("two bells: a second ringClose the same day must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.BellAlreadyRung.selector), "two bells: second ringClose refused for the wrong reason");
        }
    }

    // ── fee-sum: 1.25 % of the book fill per side, none on the residual, five shares exactly the fee ──
    function test_I2_feeOnBookFillOnly() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 sId = _order(m, 2 * D, false, -60, 10e18);
        uint256 bId = _order(m, 2 * D, true, 300, 980e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        (int24 p,, bool buyHeavy,, uint64 marg, uint64 rf) = m.hook.bells(2 * D);
        assertEq(p, 300, "precondition: P* = bucket 300");
        assertTrue(buyHeavy, "precondition: buy-heavy");
        assertGt(rf, 0, "precondition: the residual filled (the fee-on-residual check is not vacuous)");
        uint160 sp = TickMath.getSqrtPriceAtTick(p);
        uint256 acc0 = _accrued(m);
        uint256 b0 = m.hook.burnAccrued();
        (uint8 up, uint64 rUp) = m.hook.charges(2 * D);
        uint256 fee = _checkBuyerI2(m, bId, sp, marg, rf, up, rUp);
        uint256 sFee = _checkSellerI2(m, sId, sp);
        assertEq(_accrued(m) - acc0, fee + sFee, "fee split: accruals rose by exactly the two fees");
        assertEq(m.hook.networkAccrued(), fee * 2000 / 10_000 + sFee * 2000 / 10_000, "fee split: network share = 20% of each fee");
        assertEq(m.hook.feeWalletImdAccrued(), fee * 2000 / 10_000 + sFee * 2000 / 10_000, "fee split: fee wallet share = 20%");
        assertEq(m.hook.swarmAccrued(), fee * 1000 / 10_000 + sFee * 1000 / 10_000, "fee split: swarm share = 10%");
        assertEq(m.hook.bellPurseAccrued(), fee * 1000 / 10_000 + sFee * 1000 / 10_000, "fee split: bell purse share = 10%");
        // the burn is each fee's remainder, so the five shares are each fee exactly
        uint256 rest = fee - 2 * (fee * 2000 / 10_000) - 2 * (fee * 1000 / 10_000);
        uint256 sRest = sFee - 2 * (sFee * 2000 / 10_000) - 2 * (sFee * 1000 / 10_000);
        assertEq(m.hook.burnAccrued() - b0, rest + sRest, "fee split: the burn takes each fee's remainder");
    }

    struct Exp {
        uint256 fee;
        uint256 out;
        uint256 refund;
    }

    function _expBuyer(uint256 a, uint64 marg, uint64 rf, uint8 up, uint64 rUp, uint160 sp)
        internal
        pure
        returns (Exp memory x)
    {
        uint256 net = a * 10_000 / 10_125;
        uint256 bookIn = FullMath.mulDivRoundingUp(net, uint256(marg) + ((up >> 1) & 1), 1e18);
        uint256 bookOut = net * marg / 1e18;
        uint256 u = net - bookIn;
        uint256 resIn = FullMath.mulDivRoundingUp(u, rUp, 1e18);
        uint256 resOut = u * rf / 1e18;
        x.fee = _up(bookIn * 125, 10_000);
        x.out = _i2c(bookOut, sp) + _i2c(resOut, sp);
        x.refund = a - bookIn - resIn - x.fee;
    }

    function _checkBuyerI2(Mkt memory m, uint256 bId, uint160 sp, uint64 marg, uint64 rf, uint8 up, uint64 rUp)
        internal
        returns (uint256)
    {
        Exp memory x = _expBuyer(980e18, marg, rf, up, rUp, sp);
        vm.recordLogs();
        m.hook.claim(bId);
        (uint256 out, uint256 refund, uint256 feeLog, uint256 nc, uint256 nf) = _claimLog(vm.getRecordedLogs(), bId);
        assertEq(nc + nf, 2, "one Claimed and one FeeTaken");
        assertEq(feeLog, x.fee, "fee split: the buyer's fee is 1.25% of the book fill only, rounded up; nothing on the residual");
        assertEq(out, x.out, "fee split: the buyer receives book / P* + residual / P* in coin, each rounded down, no coin-side fee");
        assertEq(refund, x.refund, "fee split: the buyer's refund = escrow - book - residual - fee");
        return x.fee;
    }

    function _checkSellerI2(Mkt memory m, uint256 sId, uint160 sp) internal returns (uint256 sFee) {
        uint256 gross = _c2i(10e18, sp);
        sFee = _up(gross * 125, 10_000);
        vm.recordLogs();
        m.hook.claim(sId);
        (uint256 out, uint256 refund, uint256 feeLog,,) = _claimLog(vm.getRecordedLogs(), sId);
        assertEq(feeLog, sFee, "fee split: the seller's fee is 1.25% of its IMD leg");
        assertEq(out, gross - sFee, "fee split: the seller receives its IMD leg less its fee");
        assertEq(refund, 0, "fee split: the lighter side has nothing to refund");
    }

    // ── monotone rounding ──
    function test_I9_cancelFeeRoundsUp() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 id = _order(m, 2 * D, true, 0, 1e18 + 1);
        vm.recordLogs();
        vm.prank(trader);
        m.hook.cancelOrder(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == CANCELLED) fee = abi.decode(logs[i].data, (uint256));
        }
        assertEq(fee, 5e15 + 1, "rounding: the cancel fee rounds up, toward the hook");
    }

    // ── the gas floor is checked before the cross ──
    function test_I8_gasFloorBeforeTheCross() public {
        Mkt memory m = mkt;
        assertEq(m.hook.BELL_GAS_FLOOR(), GAS_FLOOR_T, "the harness's floor figure equals the hook's");
        assertEq(GAS_FLOOR_T, 10_600_000, "the band's worst residual + 15 %, rounded up");
        _at(D, 1 hours);
        _order(m, 2 * D, false, -60, 10e18);
        _order(m, 2 * D, true, 60, 980e18);
        _at(D, OPEN);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        _coolAll(m);
        uint256 g = gasleft();
        m.hook.ringOpen();
        uint256 cost = g - gasleft();
        vm.revertToState(snap);
        uint256 give = GAS_FLOOR_T + 600_000;
        console2.log("(gas floor) cold ring cost with unlimited gas / gas given at entry", cost, give);
        assertLt(cost + 50_000, give, "precondition: the ring fits in floor + 600k");
        _coolAll(m);
        try m.hook.ringOpen{gas: give}() {}
        catch (bytes memory e) {
            console2.logBytes(e);
            fail("gas floor: a ring given the floor (+600k) at entry must complete");
        }
        (, bool rung,,,,) = m.hook.bells(2 * D);
        assertTrue(rung, "gas floor: a ring given the floor at entry completes");
        vm.revertToState(snap);
        _coolAll(m);
        try m.hook.ringOpen{gas: GAS_FLOOR_T - 1}() {
            fail("gas floor: a ring with less than the floor at entry must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.GasFloor.selector), "gas floor: refused for the wrong reason");
        }
    }

    // ── liveness ──
    function test_I6_claimOnce() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 sId = _order(m, 2 * D, false, -60, 10e18);
        uint256 bId = _order(m, 2 * D, true, 60, 980e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        m.hook.claim(sId);
        m.hook.claim(bId);
        try m.hook.claim(bId) {
            fail("claims: a second claim of one order must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.AlreadyClaimed.selector), "claims: second claim refused for the wrong reason");
        }
    }

    // ── exits refused in the freeze and in session ──
    function test_I7_exitRefusedInFreezeAndSession() public {
        Mkt memory m = mkt;
        _at(D, OPEN - FREEZE_T - 60);
        vm.prank(trader);
        try m.hook.emergencyExit(0, 0) {}
        catch (bytes memory e) {
            assertFalse(_has(e, MarketHoursHook.ExitClosed.selector), "session rules control: 11:49 is CLOSED, the window admits exits");
        }
        _at(D, OPEN - 300);
        vm.prank(trader);
        try m.hook.emergencyExit(1e18, 0) {
            fail("session rules: an exit in the opening freeze must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.ExitClosed.selector), "session rules: freeze exit refused for the wrong reason");
        }
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D, OPEN + 1 hours);
        vm.prank(trader);
        try m.hook.emergencyExit(1e18, 0) {
            fail("session rules: an exit in session must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.ExitClosed.selector), "session rules: session exit refused for the wrong reason");
        }
    }

    // ── reference chain ──
    function test_I15_referenceIsTheBellPrice() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 pOpen,,,,,) = m.hook.bells(2 * D);
        assertEq(m.hook.referenceOf(2 * D + 1), pOpen, "reference chain: the closing book's reference is the opening P*");
        for (uint256 i; i < 3; ++i) {
            _nextBlock();
            _swap(m, true, 1_000e18);
        }
        _at(D, CLOSE);
        m.hook.ringClose();
        int24 lc = m.hook.lastCleared();
        int24 spotB = _nearest(_tick(m));
        assertTrue(spotB != lc, "precondition: spot sits in another bucket than the closing P*");
        assertEq(m.hook.referenceOf(2 * (D + 1)), lc, "reference chain: the overnight book's reference is the closing P*, never spot");
    }

    // ── breaker ──
    function test_I10_breakerFromTheBlockCheckpoint() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
        uint160 sp0 = _sqrt(m);
        _swap(m, true, 1_500e18);
        _swap(m, true, 1_500e18);
        uint256 r = FullMath.mulDiv(_sqrt(m), Q96, sp0);
        r = FullMath.mulDiv(r, r, Q96);
        uint256 moveBps = (r - Q96) * 10_000 / Q96;
        assertGt(moveBps, 500, "precondition: the third swap starts beyond X = 500 bps of the block's first price");
        vm.prank(trader);
        try router.swap(
            m.key, IPoolManager.SwapParams(false, -1_500e18, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        ) {
            fail("price breaker: a swap starting more than X from the block's checkpoint must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.PriceMoved.selector), "price breaker: refused for the wrong reason");
        }
    }

    // ── size cap in IMD terms ──
    function test_I11_capInImdTerms() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
        vm.prank(trader);
        try router.swap(
            m.key, IPoolManager.SwapParams(false, -10_001e18, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        ) {
            fail("size cap: an IMD-specified buy over the cap must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.SwapTooLarge.selector), "size cap: IMD over-cap refused for the wrong reason");
        }
        _nextBlock();
        _swap(m, true, 9_000e18);
        _nextBlock();
        _swap(m, true, 9_000e18);
        _nextBlock();
        uint160 sp = _sqrt(m);
        uint256 coinAmt = _i2c(10_500e18, sp);
        assertLt(coinAmt, 10_000e18, "precondition: the coin amount alone is under the IMD cap");
        vm.prank(trader);
        try router.swap(
            m.key, IPoolManager.SwapParams(true, -int256(coinAmt), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        ) {
            fail("size cap: a coin-specified sell worth more than the cap in IMD must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.SwapTooLarge.selector), "size cap: coin over-cap refused for the wrong reason");
        }
    }

    // ── round trip through a router ──
    function test_I12_roundTripThroughARouter() public {
        Mkt memory m = mkt;
        MsgSenderRouter r2 = new MsgSenderRouter(manager);
        address other = makeAddr("other");
        m.coin.transfer(other, 1_000e18);
        vm.startPrank(trader);
        IERC20T(imd).approve(address(r2), type(uint256).max);
        m.coin.approve(address(r2), type(uint256).max);
        vm.stopPrank();
        vm.prank(other);
        m.coin.approve(address(r2), type(uint256).max);
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
        // each swapper signs its own transaction: the router's msgSender() is the transaction's signer, so it is the
        // identity the rule keys on
        vm.prank(trader, trader);
        r2.swap(m.key, IPoolManager.SwapParams(false, -100e18, TickMath.MAX_SQRT_PRICE - 1));
        vm.prank(trader, trader);
        try r2.swap(m.key, IPoolManager.SwapParams(true, -50e18, TickMath.MIN_SQRT_PRICE + 1)) {
            fail("round trip: the same swapper selling in the block it bought, through a router, must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.RoundTrip.selector), "round trip: refused for the wrong reason");
        }
        vm.prank(other, other);
        r2.swap(m.key, IPoolManager.SwapParams(true, -10e18, TickMath.MIN_SQRT_PRICE + 1));
    }

    // ── cancel windows ──
    function test_I14_noCancelHour() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 a = _order(m, 2 * D, true, 0, 10e18);
        uint256 b = _order(m, 2 * D, true, 0, 10e18);
        _at(D, OPEN - FREEZE_T - NO_CANCEL_T - 60);
        vm.prank(trader);
        m.hook.cancelOrder(a);
        _at(D, OPEN - FREEZE_T - NO_CANCEL_T + 300);
        vm.prank(trader);
        try m.hook.cancelOrder(b) {
            fail("cancel window: a cancel at 10:55 must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.CancelLocked.selector), "cancel window: 10:55 cancel refused for the wrong reason");
        }
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D, OPEN + 60);
        uint256 c = _order(m, 2 * D + 1, true, m.hook.referenceOf(2 * D + 1), 10e18);
        _at(D, CLOSE - FREEZE_T - NO_CANCEL_T + 300);
        vm.prank(trader);
        try m.hook.cancelOrder(c) {
            fail("cancel window: a cancel at 14:55 must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.CancelLocked.selector), "cancel window: 14:55 cancel refused for the wrong reason");
        }
    }

    // ── coin supply ──
    /// The coin burn's floor is 100,000 coin: two cancels of 400 coin (4 coin of fees) stay below it, then
    /// 200,000 coin of harvested inflow puts its half on the burn and lifts the accrual over the floor.
    function test_I13_burnCoinLowersSupply() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        for (uint256 i; i < 2; ++i) {
            uint256 id = _order(m, 2 * D, false, 0, 400e18);
            vm.prank(trader);
            m.hook.cancelOrder(id);
        }
        assertEq(m.hook.coinBurnAccrued(), 4e18, "precondition: 4 coin of cancel fees accrued");
        try m.hook.burnCoin() {
            fail("coin supply: a coin burn below 100,000 coin must revert");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.BelowMinBurn.selector), "coin supply: refused for the wrong reason");
        }
        m.coin.transfer(address(m.hook), 200_000e18);
        m.hook.harvest();
        assertEq(m.hook.coinBurnAccrued(), 100_004e18, "precondition: half the harvested coin joined the coin burn");
        uint256 s0 = m.coin.totalSupply();
        m.hook.burnCoin();
        assertEq(s0 - m.coin.totalSupply(), 100_004e18, "coin supply: burnCoin lowers totalSupply by the amount");
        assertEq(m.hook.coinBurnAccrued(), 0, "coin supply: accrual cleared");
    }

    // ── deposit cap ──
    function test_I16_depositCapSchedule() public {
        Mkt memory m = mkt;
        uint256 d0 = m.hook.d0();
        assertEq(CAP0_T, 1_000e18, "deposit cap: the harness's CAP0 is the decided 1,000 IMD");
        assertEq(CAP_MAX_T, 100_000e18, "deposit cap: the harness's CAP_MAX is the decided 100,000 IMD");
        _at(d0, 1 hours);
        assertEq(m.hook.depositCap(), 1_000e18, "deposit cap: week 0, launch day = 1,000");
        _at(d0 + 6, 23 hours);
        assertEq(m.hook.depositCap(), 1_000e18, "deposit cap: week 0, day 6 = 1,000");
        _at(d0 + 7, 0);
        assertEq(m.hook.depositCap(), 2_000e18, "deposit cap: week 1 = 2,000");
        _at(d0 + 14, 0);
        assertEq(m.hook.depositCap(), 4_000e18, "deposit cap: week 2 = 4,000");
        _at(d0 + 21, 0);
        assertEq(m.hook.depositCap(), 8_000e18, "deposit cap: week 3 = 8,000");
        _at(d0 + 28, 0);
        assertEq(m.hook.depositCap(), 16_000e18, "deposit cap: week 4 = 16,000");
        _at(d0 + 35, 0);
        assertEq(m.hook.depositCap(), 32_000e18, "deposit cap: week 5 = 32,000");
        _at(d0 + 42, 0);
        assertEq(m.hook.depositCap(), 64_000e18, "deposit cap: week 6 = 64,000");
        _at(d0 + 49, 0);
        assertEq(m.hook.depositCap(), 100_000e18, "deposit cap: week 7 = CAP_MAX 100,000 (128,000 capped)");
        _at(d0 + 56, 0);
        assertEq(m.hook.depositCap(), 100_000e18, "deposit cap: week 8 = CAP_MAX 100,000");
    }

    // ── reentrancy: harvest refused inside the hook's own unlockCallback ──
    function test_R_harvestRefusedInsideUnlock() public {
        bytes memory init = type(ReentrantCoin).creationCode;
        bytes32 h = keccak256(init);
        uint256 i = TAG_RE << 128;
        while (_create2At(bytes32(i), h) > imd) ++i;
        ReentrantCoin rc = new ReentrantCoin{salt: bytes32(i)}();
        Mkt memory m = _marketFixedAddressWithCoin(TAG_RE, type(MarketHoursHook).creationCode, "", address(rc), WIDE, WIDE_L);
        rc.arm(address(m.hook), address(manager));
        _at(D, 1 hours);
        _order(m, 2 * D, false, -60, 10e18);
        _order(m, 2 * D, true, 300, 980e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        (,,,,, uint64 rf) = m.hook.bells(2 * D);
        assertGt(rc.calls(), 0, "precondition: the coin called harvest from inside the hook's unlock (not vacuous)");
        assertFalse(rc.harvested(), "reentrancy: harvest ran inside unlockCallback");
        assertTrue(_has(rc.lastError(), MarketHoursHook.Reentrant.selector), "reentrancy: harvest refused for the wrong reason");
        assertGt(rf, 0, "the residual still filled");
    }

    // ── harvest splits: IMD to the swarm slice, the bell purse slice and the burn, coin to the coin burn and the fee wallet ──
    function test_harvestSplitsFourWays() public {
        Mkt memory m = mkt;
        _fundImd(address(this), 1_000e18);
        IERC20T(imd).transfer(address(m.hook), 1_000e18);
        m.coin.transfer(address(m.hook), 400e18);
        m.hook.harvest();
        assertEq(m.hook.swarmAccrued(), 100e18, "10% of harvested IMD to the swarm slice");
        assertEq(m.hook.bellPurseAccrued(), 100e18, "10% of harvested IMD to the bell purse slice");
        assertEq(m.hook.burnAccrued(), 800e18, "the other 80% of harvested IMD to the burn");
        assertEq(m.hook.coinBurnAccrued(), 200e18, "50% of harvested coin to the coin burn");
        assertEq(m.hook.feeWalletCoinAccrued(), 200e18, "50% of harvested coin to the fee wallet");
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), m.hook.imdAccounted(), "IMD accounting after harvest");
        assertEq(m.coin.balanceOf(address(m.hook)), m.hook.coinAccounted(), "coin accounting after harvest");
    }
}
