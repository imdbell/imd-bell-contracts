// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {Gas} from "./Gas.sol";
import {IERC20T} from "./Base.sol";
import {setRingRate} from "./RingRate.sol";

/// The ringer with the real hook, game and purse (and, in a mainnet environment, the real Intake, PoolManager and ETH/IMD pool): the
/// opening bell's five chores and the closing bell's two, the bell by the clock, the second ringer, the entry check,
/// the reward read back from the event and recomputed, the purse's slice, and the hook's bells unchanged whoever rings.
abstract contract Ringer is Gas {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Rung {
        uint256 paid;
        bool open;
        uint256 skipped; // bit i: chore i skipped
        bytes4[8] why;
        address bellRinger; // the hook's BellRung ringer field
        uint256 frame; // gas the call took from the test frame
    }

    /// whether the environment's Intake is the real one; the offline stand-in stores every body and costs
    /// several times the night's stipend
    function _intakeIsReal() internal view virtual returns (bool) {
        return false;
    }

    function _ringVia(Mkt memory m, address who, uint256 gas) internal returns (Rung memory o) {
        BellRinger r = _ringer(m);
        vm.recordLogs();
        vm.prank(who, who);
        uint256 g0 = gasleft();
        r.ring{gas: gas}();
        o.frame = g0 - gasleft();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.Rewarded.selector) {
                assertEq(address(uint160(uint256(lg[i].topics[1]))), who, "Rewarded names the caller");
                (o.paid, o.open) = abi.decode(lg[i].data, (uint256, bool));
                seen = true;
            } else if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.ChoreSkipped.selector) {
                uint8 id = uint8(uint256(lg[i].topics[1]));
                o.skipped |= 1 << id;
                o.why[id] = abi.decode(lg[i].data, (bytes4));
            } else if (lg[i].emitter == address(m.hook) && lg[i].topics[0] == MarketHoursHook.BellRung.selector) {
                (,,, o.bellRinger) = abi.decode(lg[i].data, (int24, uint256, uint256, address));
            }
        }
        assertTrue(seen, "Rewarded is emitted on every ring");
    }

    function _topUp(Mkt memory m, uint256 a) internal {
        _fundImd(address(this), a);
        IERC20T(imd).approve(address(_ringer(m)), a);
        _ringer(m).topUp(a);
    }

    /// the env's ETH/IMD pool: in a mainnet environment the canonical one exists; offline it is initialised here at 400 IMD per ETH
    function _ethImdPrice() internal returns (uint160 sp) {
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 200, IHooks(address(0)));
        assertEq(PoolId.unwrap(k.toId()), _ringer(mkt).ethImdPoolId(), "the ringer reads the ETH/IMD pool");
        (sp,,,) = manager.getSlot0(k.toId());
        if (sp == 0) {
            manager.initialize(k, uint160(20 << 96));
            (sp,,,) = manager.getSlot0(k.toId());
        }
    }

    // ── the opening bell and its five chores ──
    function test_R_openRingRunsItsChores() public {
        Mkt memory m = mkt;
        BellRinger r = _ringer(m);
        _topUp(m, 10e18);
        // day D: a book that fills, claimed, so the network, fee wallet, swarm, purse and burn shares have all accrued
        _at(D, 1 hours);
        uint256 b1 = _order(m, 2 * D, true, 60, 100e18);
        uint256 s1 = _order(m, 2 * D, false, -60, 50e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        m.hook.claim(b1);
        m.hook.claim(s1);
        uint256 bp0 = m.hook.bellPurseAccrued();
        assertGt(bp0, 0, "precondition: the purse's share accrued");
        assertGt(m.hook.networkAccrued(), 0, "precondition: the network's share accrued");
        // day D+1: the factory pushes 50 IMD of pool fees at its claimFees, as the real one pushes the requester share
        _fundImd(address(this), 50e18);
        feePush = 50e18;
        feePushTo = address(m.hook);
        uint256 purse0 = IERC20T(imd).balanceOf(address(r));
        // the network's recipient as the hook reads it: the stand-in's offline, the real fee setting's on mainnet
        (, bytes memory rec) = launchFees.staticcall(abi.encodeWithSignature("feeRecipient()"));
        address network = abi.decode(rec, (address));
        uint256 network0 = IERC20T(imd).balanceOf(network);
        _at(D + 1, OPEN);
        _nextBlock();
        address bot = makeAddr("bot");
        Rung memory o = _ringVia(m, bot, RING_GAS_T);
        assertTrue(o.open, "the opening bell");
        (, bool rung,,,,) = m.hook.bells(2 * (D + 1));
        assertTrue(rung, "the opening bell rang");
        assertEq(o.bellRinger, address(r), "BellRung names the ringer contract");
        assertEq(o.skipped, 0, "no chore was skipped");
        assertEq(lastClaimFeesLaunch, LAUNCH_T, "claimFees(launchNumber)");
        // claimFees before harvest: the 50 IMD the factory pushed is folded in the same transaction
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), m.hook.imdAccounted(), "harvest ran after the fee push");
        assertEq(m.hook.swarmAccrued(), 0, "claimSwarmBudget ran");
        assertEq(m.hook.bellPurseAccrued(), 0, "claimBellPurse ran");
        assertEq(m.hook.networkAccrued(), 0, "claimNetworkFees ran");
        assertGt(IERC20T(imd).balanceOf(network), network0, "the network was paid");
        assertEq(IERC20T(imd).balanceOf(address(r)) + o.paid - purse0, bp0 + 5e18, "the purse received its accrual and 10 % of the push");
        assertEq(IERC20T(imd).balanceOf(bot), o.paid, "the caller was paid what Rewarded says");
        assertLe(o.paid, r.RING_REWARD_CAP());
    }

    // ── the closing bell and its two chores ──
    function test_R_closeRingSettlesAndRequestsTheNight() public {
        Mkt memory m = mkt;
        BellRinger r = _ringer(m);
        _ethImdPrice(); // no ETH/IMD price pays nothing, so the offline env needs its pool for a reward
        _topUp(m, 10e18);
        _fundImd(address(m.budget), 2e18); // the night costs 1 IMD
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, CLOSE);
        _nextBlock();
        Rung memory o = _ringVia(m, makeAddr("bot"), RING_GAS_T);
        assertFalse(o.open, "the closing bell");
        (, bool rung,,,,) = m.hook.bells(2 * D + 1);
        assertTrue(rung, "the closing bell rang");
        (bool settled,,,) = m.game.dayState(D);
        assertTrue(settled, "settle(d) ran");
        assertEq(o.skipped & (1 << 6), 0, "settle was not skipped");
        (bool requested,,) = m.budget.nights(D + 1);
        if (_intakeIsReal()) {
            assertEq(o.skipped, 0, "no chore was skipped");
            assertTrue(requested, "requestNight(d+1) ran on the real Intake");
        } else {
            // the stand-in Intake keeps every body in storage: past the stipend, so the chore starves and is skipped
            assertEq(o.skipped, 1 << 7, "only the night was skipped offline");
            assertEq(o.why[7], bytes4(0), "it ran out of gas");
            assertFalse(requested);
            uint256 g0 = gasleft();
            m.budget.requestNight(D + 1);
            assertGt(g0 - gasleft(), r.GAS_NIGHT(), "the stand-in's night is dearer than the stipend");
        }
        assertGt(o.paid, 0, "paid");
    }

    // ── the bell by the clock, on the hook ──
    function test_R_bellByTheClockOnTheHook() public {
        Mkt memory m = mkt;
        uint256[6] memory tods = [OPEN - 1, OPEN, CLOSE - 1, CLOSE, DEADLINE_T - 1, DEADLINE_T];
        int8[6] memory want = [int8(-1), 1, 1, 0, 0, -1];
        for (uint256 i; i < 6; ++i) {
            uint256 d = D + i;
            _at(d, tods[i]);
            _nextBlock();
            if (want[i] < 0) {
                BellRinger r = _ringer(m);
                vm.expectRevert(BellRinger.NoBellDue.selector);
                r.ring{gas: RING_GAS_T}();
                continue;
            }
            Rung memory o = _ringVia(m, makeAddr("bot"), RING_GAS_T);
            assertEq(o.open, want[i] == 1, "the bell the clock chose");
            (, bool rungOpen,,,,) = m.hook.bells(2 * d);
            (, bool rungClose,,,,) = m.hook.bells(2 * d + 1);
            assertEq(rungOpen, want[i] == 1, "the open rang iff chosen");
            assertEq(rungClose, want[i] == 0, "the close rang iff chosen");
        }
    }

    function test_R_secondRingerPaysGasAndGetsNothing() public {
        Mkt memory m = mkt;
        _topUp(m, 10e18);
        _at(D, OPEN);
        _nextBlock();
        _ringVia(m, makeAddr("first"), RING_GAS_T);
        address second = makeAddr("second");
        uint256 held = _ringer(m).purse();
        vm.prank(second, second);
        (bool ok, bytes memory e) = address(_ringer(m)).call{gas: RING_GAS_T}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok, "the second ring in the block reverts");
        assertTrue(_has(e, MarketHoursHook.BellAlreadyRung.selector), "with the hook's own reason");
        assertEq(IERC20T(imd).balanceOf(second), 0, "and pays nothing");
        assertEq(_ringer(m).purse(), held, "the purse is untouched");
    }

    function test_R_entryCheckOnTheHook() public {
        Mkt memory m = mkt;
        BellRinger r = _ringer(m);
        assertEq(r.bellGasFloor(), m.hook.BELL_GAS_FLOOR(), "the ringer's floor is the hook's");
        _at(D, OPEN);
        _nextBlock();
        uint256 need = r.bellGasFloor() + r.CHORE_GAS_OPEN();
        (bool ok, bytes memory e) = address(r).call{gas: need - 1}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok);
        assertEq(bytes4(e), BellRinger.GasShort.selector, "below floor + chores: refused before the bell");
        (, bool rung,,,,) = m.hook.bells(2 * D);
        assertFalse(rung);
        (ok,) = address(r).call{gas: need + 2_000}(abi.encodeCall(BellRinger.ring, ()));
        assertTrue(ok, "at floor + chores (and the dispatch): rings");
        (, rung,,,,) = m.hook.bells(2 * D);
        assertTrue(rung);
    }

    function test_R_emptyPurseRingsForNothing() public {
        Mkt memory m = mkt;
        assertEq(_ringer(m).purse(), 0);
        setRingRate(_ringer(m), 1 gwei);
        _at(D, OPEN);
        _nextBlock();
        Rung memory o = _ringVia(m, makeAddr("bot"), RING_GAS_T);
        assertEq(o.paid, 0, "an empty purse pays nothing");
        (, bool rung,,,,) = m.hook.bells(2 * D);
        assertTrue(rung, "and the bell rang");
    }

    // ── the five shares must be the whole fee ──
    function test_R_fiveSharesMustSumToWhole() public {
        MarketHoursHook.Params memory p = _params(address(mkt.coin));
        p.bellPurseBps = 900; // 9,900 in all
        try new MarketHoursHook(p) {
            fail("a split of 9,900 bps deployed");
        } catch (bytes memory e) {
            assertEq(bytes4(e), MarketHoursHook.SharesNotWhole.selector, "refused for its shares");
        }
        p.bellPurseBps = 1000;
        p.burnBps = 5000; // the old four shares whole, the purse on top: 11,000
        try new MarketHoursHook(p) {
            fail("a split of 11,000 bps deployed");
        } catch (bytes memory e) {
            assertEq(bytes4(e), MarketHoursHook.SharesNotWhole.selector, "refused for its shares");
        }
    }

    // ── the purse's slice ──
    function test_R_claimBellPursePaysTheRingerExactly() public {
        Mkt memory m = mkt;
        _fundImd(address(this), 1_000e18);
        IERC20T(imd).transfer(address(m.hook), 1_000e18);
        m.hook.harvest();
        uint256 a = m.hook.bellPurseAccrued();
        assertEq(a, 100e18, "10 % of harvested IMD");
        address stranger = makeAddr("stranger");
        uint256 r0 = IERC20T(imd).balanceOf(address(_ringer(m)));
        vm.expectEmit(false, false, false, true, address(m.hook));
        emit MarketHoursHook.BellPursePaid(a);
        vm.prank(stranger);
        m.hook.claimBellPurse();
        assertEq(IERC20T(imd).balanceOf(address(_ringer(m))) - r0, a, "the whole accrual to the ringer");
        assertEq(IERC20T(imd).balanceOf(stranger), 0, "nothing to the caller");
        assertEq(m.hook.bellPurseAccrued(), 0);
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), m.hook.imdAccounted(), "IMD accounting after claimBellPurse");
        // nothing accrued: pays nothing, still fine
        m.hook.claimBellPurse();
        assertEq(IERC20T(imd).balanceOf(address(_ringer(m))) - r0, a);
    }

    // ── the reward read back and recomputed; OVERHEAD covers what the in-call count cannot see ──
    /// The counted gas is read back from the event (reward = 1.5 x gas x (base fee + allowance) x IMD per ETH, at 1 gwei); a real
    /// transaction costs its caller 21,064 (intrinsic and the four calldata bytes) plus the call's own gas, which is
    /// the test frame's figure less the cold account access the frame adds (2,600). OVERHEAD must cover the gap.
    function test_R_rewardRecomputedAndOverheadCovers() public {
        Mkt memory m = mkt;
        BellRinger r = _ringer(m);
        _topUp(m, 30e18);
        uint160 sp = _ethImdPrice();
        uint256 priceX96 = uint256(sp) * sp >> 96;
        setRingRate(_ringer(m), 1 gwei);
        for (uint256 k; k < 2; ++k) {
            bool open = k == 0;
            _at(D, open ? OPEN : CLOSE);
            _nextBlock();
            address fresh = makeAddr(open ? "fresh open" : "fresh close"); // no IMD yet: the dearest payment
            _coolAll(m);
            vm.cool(address(r));
            vm.cool(address(m.game));
            vm.cool(address(m.budget));
            Rung memory o = _ringVia(m, fresh, RING_GAS_T);
            assertLt(o.paid, r.RING_REWARD_CAP(), "precondition: under the cap, so the count can be read back");
            uint256 counted = (o.paid << 96) / priceX96 * 2 / 3 / 1 gwei;
            uint256 txCost = 21_064 + o.frame - 2_600;
            console2.log(open ? "(R) open: counted (incl. OVERHEAD) / tx cost / frame" : "(R) close: counted (incl. OVERHEAD) / tx cost / frame", counted, txCost, o.frame);
            console2.log("    OVERHEAD needed / set", txCost - (counted - r.OVERHEAD()), r.OVERHEAD());
            assertGe(counted + 1, txCost, "the reward covers the whole transaction's gas");
            assertLe(counted, txCost + 40_000, "and not far more");
        }
    }

    // ── the chores, each alone, cold, in the bundle's state; each fits its stipend ──
    function test_R_choresFitTheirStipends() public {
        Mkt memory m = mkt;
        BellRinger r = _ringer(m);
        // a day with fees: orders through the open, claimed, so every accrual is non-zero
        _at(D, 1 hours);
        uint256 b1 = _order(m, 2 * D, true, 60, 100e18);
        uint256 s1 = _order(m, 2 * D, false, -60, 50e18);
        _fundImd(address(m.budget), 2e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        m.hook.claim(b1);
        m.hook.claim(s1);
        _fundImd(address(this), 50e18);
        IERC20T(imd).transfer(address(m.hook), 50e18); // a fee push waiting to be harvested
        uint256[7] memory g;
        g[1] = _choreGas(m, abi.encodeCall(MarketHoursHook.harvest, ()));
        m.hook.harvest();
        g[2] = _choreGas(m, abi.encodeCall(MarketHoursHook.claimSwarmBudget, ()));
        m.hook.claimSwarmBudget();
        g[3] = _choreGas(m, abi.encodeCall(MarketHoursHook.claimBellPurse, ()));
        m.hook.claimBellPurse();
        g[4] = _choreGas(m, abi.encodeCall(MarketHoursHook.claimNetworkFees, ()));
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        _coolGame(m);
        uint256 g0 = gasleft();
        m.game.settle(D);
        g[5] = g0 - gasleft();
        _coolBudget(m);
        g0 = gasleft();
        m.budget.requestNight(D + 1);
        g[6] = g0 - gasleft();
        console2.log("(R) chores alone, cold: harvest / swarm / purse / network", g[1], g[2], g[3]);
        console2.log("    ", g[4]);
        console2.log("(R) settle / requestNight", g[5], g[6]);
        assertLe(g[1], r.GAS_HARVEST(), "harvest fits");
        assertLe(g[2], r.GAS_SWARM(), "claimSwarmBudget fits");
        assertLe(g[3], r.GAS_PURSE(), "claimBellPurse fits");
        assertLe(g[4], r.GAS_NETWORK(), "claimNetworkFees fits");
        assertLe(g[5], r.GAS_SETTLE(), "settle fits");
        if (_intakeIsReal()) assertLe(g[6], r.GAS_NIGHT(), "requestNight fits on the real Intake");
    }

    function _choreGas(Mkt memory m, bytes memory call) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        vm.cool(address(m.hook));
        vm.cool(imd);
        vm.cool(address(m.budget));
        vm.cool(address(_ringer(m)));
        vm.cool(launchFees);
        uint256 g0 = gasleft();
        (bool ok,) = address(m.hook).call(call);
        used = g0 - gasleft();
        assertTrue(ok, "the chore ran");
        vm.revertToState(snap);
    }

    // ── the hook's bells behave as before whoever rings them ──
    function test_R_hookBellsUnchangedWhoeverRings() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        _order(m, 2 * D, true, 120, 300e18);
        _order(m, 2 * D, false, -60, 100e18);
        _at(D, OPEN);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        m.hook.ringOpen();
        (int24 p1, bool r1, bool h1, uint64 i1, uint64 mg1, uint64 rf1) = m.hook.bells(2 * D);
        uint256 bal1 = IERC20T(imd).balanceOf(address(m.hook));
        uint256 burn1 = m.hook.burnAccrued();
        (uint8 cu, uint64 cr) = m.hook.charges(2 * D);
        bytes memory ch1 = abi.encode(cu, cr);
        int24 lc1 = m.hook.lastCleared();
        (uint24 wd, uint32 wo, int48 ws, uint16 wc, bool wf) = m.hook.window();
        bytes memory w1 = abi.encode(wd, wo, ws, wc, wf);
        vm.revertToState(snap);
        _ringVia(m, makeAddr("bot"), RING_GAS_T);
        (int24 p2, bool r2, bool h2, uint64 i2, uint64 mg2, uint64 rf2) = m.hook.bells(2 * D);
        assertEq(abi.encode(p1, r1, h1, i1, mg1, rf1), abi.encode(p2, r2, h2, i2, mg2, rf2), "the same bell");
        (cu, cr) = m.hook.charges(2 * D);
        assertEq(abi.encode(cu, cr), ch1, "the same charge ratios");
        assertEq(m.hook.lastCleared(), lc1, "the same reference");
        (wd, wo, ws, wc, wf) = m.hook.window();
        assertEq(abi.encode(wd, wo, ws, wc, wf), w1, "the same settle window");
        // nothing had accrued and nothing was pushed, so the chores moved nothing: the hook's books are identical too
        assertEq(m.hook.burnAccrued(), burn1, "the same burn accrual");
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), bal1, "the same IMD held");
    }

    // ── the push reward on the hook ──
    /// Offline the stand-in executor never moves the IMD it is handed, so every push reads as not bridged and pays
    /// nothing; on mainnet the real executor bridges and the push is paid. Either way: paid only when bridged, the
    /// caller's ETH accounted for, the ringer left with none.
    function test_R_pushBurnRewardedOnTheHook() public {
        Mkt memory m = mkt;
        BellRinger r = _ringer(m);
        _topUp(m, 10e18);
        _fundImd(address(this), 100e18);
        IERC20T(imd).transfer(address(m.hook), 100e18);
        m.hook.harvest();
        address pusher = makeAddr("pusher");
        vm.deal(pusher, 1 ether);
        address ex = m.hook.burnExecutor();
        uint256 a = m.hook.burnAccrued();
        uint256 e0 = IERC20T(imd).balanceOf(ex);
        (bool qok, bytes memory q) = ex.staticcall(abi.encodeWithSignature("quoteBridgeFee(uint256)", a));
        uint256 fee = qok && q.length >= 64 ? abi.decode(q, (uint256)) : 0;
        vm.recordLogs();
        vm.prank(pusher, pusher);
        r.pushBurnRewarded{value: fee + 0.001 ether}();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        uint256 paid;
        bool bridged;
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.PushRewarded.selector) {
                (paid, bridged) = abi.decode(lg[i].data, (uint256, bool));
            }
        }
        assertEq(bridged, IERC20T(imd).balanceOf(ex) < e0 + a, "bridged is the executor's balance rule");
        assertEq(paid > 0, bridged, "paid only when bridged");
        assertEq(IERC20T(imd).balanceOf(pusher), paid);
        assertLe(paid, r.PUSH_REWARD_CAP());
        assertEq(address(r).balance, 0, "the ringer kept no ETH");
        console2.log("(R) push: bridged / paid / ETH spent", bridged ? 1 : 0, paid, 1 ether - pusher.balance);
    }
}
