// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {setRingRate} from "./RingRate.sol";
import {SwarmBudget, IERC20B} from "../src/SwarmBudget.sol";
import {IIntake} from "../src/IIntake.sol";
import {
    ChoreBox,
    MockRingHook,
    MockBridgeExecutor,
    MockManager,
    BombIntake,
    FeeOnTransferToken,
    ReentrantToken,
    OK,
    REVERT,
    STARVE,
    REVERT_BOMB,
    RETURN_BOMB,
    REENTER
} from "./RingerMocks.sol";

/// The ringer alone, against stand-ins whose every chore can misbehave: the bell by the clock, the entry gas check,
/// each chore failing every way, the reward's every bound, the price read failing, top-ups, the push reward, reentrancy,
/// and the 63/64 rule. The ringer's behaviour with the real hook is in test/Ringer.sol.
abstract contract RingerUnit is Test {
    uint256 internal constant OPEN = 43200;
    uint256 internal constant CLOSE = 57600;
    uint256 internal constant DEADLINE = 72000;
    uint256 internal constant FLOOR = 7_000_000;
    uint64 internal constant LN = 770003;
    // 400 IMD per ETH exactly: sqrtP = 20 x 2^96
    uint256 internal constant SP400 = 20 << 96;

    bytes4 internal constant CLAIM_FEES = 0xe0d0eac4;
    bytes4 internal constant HARVEST = 0x4641257d;
    bytes4 internal constant SWARM = 0xabb74d4b;
    bytes4 internal constant PURSE = 0x6b58a30f;
    bytes4 internal constant NETWORK = 0xe67eccdd;
    bytes4 internal constant SETTLE = 0x8df82800;
    bytes4 internal constant NIGHT = 0x01e20f20;

    MockERC20 internal imd;
    MockRingHook internal hook;
    ChoreBox internal factory;
    ChoreBox internal game;
    ChoreBox internal budget;
    MockManager internal mgr;
    BellRinger internal r;
    address internal bot = makeAddr("bot");
    uint256 internal day = 20_400;

    function setUp() public virtual {
        imd = new MockERC20("Stand-in", "STAND", 18);
        _build(imd);
    }

    function _build(MockERC20 token) internal {
        imd = token;
        hook = new MockRingHook(token);
        factory = new ChoreBox();
        game = new ChoreBox();
        budget = new ChoreBox();
        mgr = new MockManager();
        factory.setPeer(hook);
        game.setPeer(budget);
        r = new BellRinger(address(hook), address(factory), address(game), address(budget), address(token), address(mgr), LN, FLOOR);
        _price(SP400, 0);
        // base fee 0, so the reward's rate is the allowance alone; a caller paying exactly that
        vm.fee(0);
        vm.txGasPrice(r.TIP_ALLOWANCE());
    }

    function _priceSlot() internal view returns (bytes32) {
        return keccak256(abi.encode(r.ethImdPoolId(), bytes32(uint256(6))));
    }

    function _price(uint256 sp, uint8 how) internal {
        // slot0's word: sqrtPriceX96 in the low 160 bits, the tick and fees above it (set, to show they are masked off)
        mgr.set(_priceSlot(), bytes32(sp | (uint256(0xabcdef) << 160)), how);
    }

    function _fund(uint256 a) internal {
        imd.mint(address(r), a);
    }

    function _at(uint256 tod) internal {
        vm.warp(day * 1 days + tod);
    }

    function _ring() internal returns (uint256 paid, bool open) {
        Vm.Log[] memory lg;
        vm.recordLogs();
        vm.prank(bot, bot);
        r.ring{gas: 9_000_000}();
        lg = vm.getRecordedLogs();
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.Rewarded.selector) {
                assertEq(address(uint160(uint256(lg[i].topics[1]))), bot, "Rewarded names the caller");
                (paid, open) = abi.decode(lg[i].data, (uint256, bool));
                return (paid, open);
            }
        }
        fail("no Rewarded event");
    }

    function _skips(Vm.Log[] memory lg) internal view returns (uint256 mask, bytes4[8] memory reasons) {
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.ChoreSkipped.selector) {
                uint8 id = uint8(uint256(lg[i].topics[1]));
                mask |= 1 << id;
                reasons[id] = abi.decode(lg[i].data, (bytes4));
            }
        }
    }

    // ── the bell by the clock ──
    function test_RU_bellByTheClock() public {
        uint256[6] memory tods = [OPEN - 1, OPEN, CLOSE - 1, CLOSE, DEADLINE - 1, DEADLINE];
        // -1 none, 0 close, 1 open
        int8[6] memory want = [int8(-1), 1, 1, 0, 0, -1];
        for (uint256 i; i < 6; ++i) {
            ++day; // a fresh day each time, so no bell is already rung
            _at(tods[i]);
            if (want[i] < 0) {
                vm.expectRevert(BellRinger.NoBellDue.selector);
                r.ring{gas: 9_000_000}();
                continue;
            }
            (, bool open) = _ring();
            assertEq(open, want[i] == 1, "the bell the clock chose");
            assertTrue(hook.rung(2 * day + (want[i] == 1 ? 0 : 1)), "that bell rang");
            assertFalse(hook.rung(2 * day + (want[i] == 1 ? 1 : 0)), "the other did not");
        }
    }

    function test_RU_closingChoresNameTheirDays() public {
        _at(CLOSE);
        _ring();
        assertEq(game.arg(SETTLE), day, "settle(d)");
        assertEq(budget.arg(NIGHT), day + 1, "requestNight(d+1)");
        assertEq(game.peerAt(SETTLE), 0, "settle before requestNight");
        assertEq(game.calls(SETTLE), 1);
        assertEq(budget.calls(NIGHT), 1);
        assertEq(factory.calls(CLAIM_FEES), 0, "no opening chore at the close");
    }

    function test_RU_openingChoresInOrder() public {
        _at(OPEN);
        r.ring{gas: 9_000_000}();
        assertEq(factory.arg(CLAIM_FEES), LN, "claimFees(launchNumber)");
        assertEq(factory.peerAt(CLAIM_FEES), 0, "the fees are claimed before any hook chore");
        assertEq(hook.order(HARVEST), 1, "then harvest");
        assertEq(hook.order(SWARM), 2, "then claimSwarmBudget");
        assertEq(hook.order(PURSE), 3, "then claimBellPurse");
        assertEq(hook.order(NETWORK), 4, "then claimNetworkFees");
        assertEq(game.calls(SETTLE) + budget.calls(NIGHT), 0, "no closing chore at the open");
    }

    // ── a bell rings once ──
    function test_RU_ringWhenAlreadyRungRevertsAndPaysNothing() public {
        _fund(10e18);
        _at(OPEN);
        _ring();
        uint256 held = imd.balanceOf(address(r));
        uint256 botHeld = imd.balanceOf(bot);
        vm.prank(bot, bot);
        vm.expectRevert(MockRingHook.BellAlreadyRung.selector);
        r.ring{gas: 9_000_000}();
        assertEq(imd.balanceOf(address(r)), held, "nothing left the purse");
        assertEq(imd.balanceOf(bot), botHeld, "the second ringer was paid nothing");
    }

    function test_RU_secondRingerSameBlock() public {
        _fund(10e18);
        _at(OPEN);
        _ring();
        address other = makeAddr("other");
        vm.prank(other, other);
        (bool ok, bytes memory e) = address(r).call{gas: 9_000_000}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok, "a second ring in the block reverts");
        assertEq(bytes4(e), MockRingHook.BellAlreadyRung.selector);
        assertEq(imd.balanceOf(other), 0, "and pays nothing");
    }

    // ── the entry gas check ──
    function test_RU_entryGasCheck() public {
        _fund(10e18);
        _at(OPEN);
        uint256 need = FLOOR + r.CHORE_GAS_OPEN();
        // the smallest gas the call passes the check with: gasleft() at the check is the call's gas less the dispatch
        uint256 lo = need - 1;
        uint256 hi = need + 20_000;
        uint256 snap = vm.snapshotState();
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(snap);
            (bool ok, bytes memory e) = address(r).call{gas: mid}(abi.encodeCall(BellRinger.ring, ()));
            if (!ok && bytes4(e) == BellRinger.GasShort.selector) lo = mid;
            else hi = mid;
        }
        vm.revertToState(snap);
        console2.log("(RU) open: floor + chores / smallest call gas past the check", need, hi);
        assertGe(hi, need, "below floor + chores the check refuses");
        assertLt(hi - need, 2_000, "the check sits at floor + chores, less only the dispatch");
        (bool ok2, bytes memory e2) = address(r).call{gas: hi - 1}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok2);
        assertEq(bytes4(e2), BellRinger.GasShort.selector, "one gas less: refused before the bell");
        assertFalse(hook.rung(2 * day), "and the bell did not ring");
        (ok2,) = address(r).call{gas: hi}(abi.encodeCall(BellRinger.ring, ()));
        assertTrue(ok2, "at the check's own figure the ring passes");
        assertTrue(hook.rung(2 * day));
        // the close needs its own chores' sum
        _at(CLOSE);
        need = FLOOR + r.CHORE_GAS_CLOSE();
        (ok2, e2) = address(r).call{gas: need - 1}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok2);
        assertEq(bytes4(e2), BellRinger.GasShort.selector, "close: refused below floor + its chores");
    }

    // ── chores failing every way: skipped, the bell rung, the reward paid ──
    function _choreFails(uint8 how, bool open) internal {
        _fund(10e18);
        ++day;
        _at(open ? OPEN : CLOSE);
        bytes4[7] memory sels = [CLAIM_FEES, HARVEST, SWARM, PURSE, NETWORK, SETTLE, NIGHT];
        ChoreBox[7] memory at = [factory, ChoreBox(hook), ChoreBox(hook), ChoreBox(hook), ChoreBox(hook), game, budget];
        for (uint256 i; i < 7; ++i) at[i].setMode(sels[i], how);
        if (how == REENTER) {
            for (uint256 i; i < 7; ++i) at[i].setReenter(address(r), abi.encodeCall(BellRinger.ring, ()));
        }
        uint256 b0 = imd.balanceOf(bot);
        vm.recordLogs();
        vm.prank(bot, bot);
        r.ring{gas: 9_000_000}();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        (uint256 mask, bytes4[8] memory why) = _skips(lg);
        assertTrue(hook.rung(2 * day + (open ? 0 : 1)), "the bell rang");
        assertGt(imd.balanceOf(bot) - b0, 0, "the reward was paid");
        uint256 want = open ? 0x3e : 0xc0; // chores 1-5, or 6-7
        if (how == RETURN_BOMB) {
            assertEq(mask, 0, "a chore that returned (whatever it returned) is not skipped");
        } else {
            assertEq(mask, want, "every chore skipped");
            for (uint256 i = open ? 1 : 6; i <= (open ? 5 : 7); ++i) {
                bytes4 w = how == REVERT ? ChoreBox.Boom.selector : how == REVERT_BOMB ? bytes4(0xdeadbeef)
                    : how == REENTER ? BellRinger.Reentrant.selector : bytes4(0);
                assertEq(why[i], w, "the skip names the revert's first four bytes");
            }
        }
    }

    function test_RU_choresRevert() public {
        _choreFails(REVERT, true);
        _choreFails(REVERT, false);
    }

    function test_RU_choresStarve() public {
        _choreFails(STARVE, true);
        _choreFails(STARVE, false);
    }

    function test_RU_choresRevertBomb() public {
        _choreFails(REVERT_BOMB, true);
        _choreFails(REVERT_BOMB, false);
    }

    function test_RU_choresReturnGarbage() public {
        _choreFails(RETURN_BOMB, true);
        _choreFails(RETURN_BOMB, false);
    }

    function test_RU_choresReenter() public {
        _choreFails(REENTER, true);
        _choreFails(REENTER, false);
    }

    /// A bomb costs the ringer nothing beyond the chore's own stipend: the ring with a 64 kB revert bomb in every
    /// opening chore uses no more than the ring with plain reverts plus what the chores themselves spent.
    function test_RU_returnBombCostsTheRingerNothing() public {
        _fund(10e18);
        hook.setBomb(64_000);
        factory.setBomb(64_000);
        bytes4[5] memory sels = [CLAIM_FEES, HARVEST, SWARM, PURSE, NETWORK];
        uint256 snap = vm.snapshotState();
        uint256[2] memory used;
        for (uint256 k; k < 2; ++k) {
            vm.revertToState(snap);
            _at(OPEN);
            factory.setMode(sels[0], k == 0 ? REVERT : REVERT_BOMB);
            for (uint256 i = 1; i < 5; ++i) hook.setMode(sels[i], k == 0 ? REVERT : REVERT_BOMB);
            uint256 g0 = gasleft();
            r.ring{gas: 9_000_000}();
            used[k] = g0 - gasleft();
        }
        console2.log("(RU) ring with reverting chores / with 64 kB revert bombs (gas)", used[0], used[1]);
        // each bomb costs its chore about 64 kB of memory (~17,500 gas) inside its stipend; the ringer copies 4 bytes
        assertLt(used[1] - used[0], 5 * 25_000, "the bombs cost only what the chores spent inside their stipends");
    }

    /// The real purse in front of an Intake that answers with a 100 kB bomb, returned or reverted: whatever the purse
    /// makes of it inside the night's stipend, the bell rings and the reward is paid.
    function test_RU_bombingIntakeBehindTheRealPurse() public {
        BombIntake bi = new BombIntake();
        SwarmBudget sb = new SwarmBudget(IERC20B(address(imd)), IIntake(address(bi)), address(hook));
        r = new BellRinger(address(hook), address(factory), address(game), address(sb), address(imd), address(mgr), LN, FLOOR);
        _price(SP400, 0);
        _fund(10e18);
        uint8[3] memory hows = [uint8(0), 1, 2];
        for (uint256 i; i < 3; ++i) {
            ++day;
            _at(CLOSE);
            imd.mint(address(sb), 2e18);
            bi.set(hows[i], 100_000);
            uint256 b0 = imd.balanceOf(bot);
            vm.recordLogs();
            vm.prank(bot, bot);
            r.ring{gas: 9_000_000}();
            (uint256 mask, bytes4[8] memory why) = _skips(vm.getRecordedLogs());
            (bool requested,,) = sb.nights(day + 1);
            console2.log("(RU) bombing Intake: how / night skipped / requested", hows[i], mask >> 7 & 1, requested ? 1 : 0);
            assertTrue(hook.rung(2 * day + 1), "the bell rang");
            assertGt(imd.balanceOf(bot) - b0, 0, "the reward was paid");
            if (hows[i] == 0) assertTrue(requested && mask == 0, "control: a well-behaved Intake takes the night");
            if (hows[i] == 2) assertEq(mask, 1 << 7, "a reverting bomb skips the night");
            why;
        }
    }

    // ── the stipends under the 63/64 rule ──
    /// At the entry check's own figure, after the heaviest ring the floor's x2 rule allows (half the floor), every chore
    /// is handed its whole stipend: the 63/64 rule never cuts one.
    function test_RU_stipendsWholeAtTheFloor() public {
        hook.setRingGas(FLOOR / 2);
        _at(OPEN);
        r.ring{gas: FLOOR + r.CHORE_GAS_OPEN() + 2_000}();
        assertGe(factory.gasAtEntry(CLAIM_FEES) + 1_000, r.GAS_CLAIM_FEES(), "claimFees got its stipend");
        assertGe(hook.gasAtEntry(HARVEST) + 1_000, r.GAS_HARVEST(), "harvest got its stipend");
        assertGe(hook.gasAtEntry(SWARM) + 1_000, r.GAS_SWARM(), "claimSwarmBudget got its stipend");
        assertGe(hook.gasAtEntry(PURSE) + 1_000, r.GAS_PURSE(), "claimBellPurse got its stipend");
        assertGe(hook.gasAtEntry(NETWORK) + 1_000, r.GAS_NETWORK(), "claimNetworkFees got its stipend");
        assertLe(factory.gasAtEntry(CLAIM_FEES), r.GAS_CLAIM_FEES(), "and no more");
        _at(CLOSE);
        r.ring{gas: FLOOR + r.CHORE_GAS_CLOSE() + 2_000}();
        assertGe(game.gasAtEntry(SETTLE) + 1_000, r.GAS_SETTLE(), "settle got its stipend");
        assertGe(budget.gasAtEntry(NIGHT) + 1_000, r.GAS_NIGHT(), "requestNight got its stipend");
        assertLe(budget.gasAtEntry(NIGHT), r.GAS_NIGHT(), "and no more");
    }

    /// A ring heavy enough that the 63/64 rule cuts a stipend (a ring far past the floor's x2 rule, which the hook never
    /// reaches): a chore that fits in what it was handed still runs and the ring pays; a chore that starves in it takes
    /// the whole transaction down with it (no bell, no pay), never a rung bell with a skipped reward.
    function test_RU_stipendLargerThan63_64OfWhatIsLeft() public {
        _fund(10e18);
        _at(CLOSE);
        uint256 total = FLOOR + r.CHORE_GAS_CLOSE() + 2_000;
        // leave the night about 400,000 of its 760,000 stipend
        hook.setRingGas(total - 520_000);
        uint256 snap = vm.snapshotState();
        vm.prank(bot, bot);
        r.ring{gas: total}();
        uint256 got = budget.gasAtEntry(NIGHT);
        console2.log("(RU) requestNight stipend / handed under 63/64", r.GAS_NIGHT(), got);
        assertLt(got, r.GAS_NIGHT(), "the 63/64 rule cut the stipend");
        assertTrue(hook.rung(2 * day + 1), "the bell rang");
        assertGt(imd.balanceOf(bot), 0, "a chore that fits in the cut stipend still runs; the reward is paid");
        vm.revertToState(snap);
        budget.setMode(NIGHT, STARVE);
        vm.prank(bot, bot);
        (bool ok,) = address(r).call{gas: total}(abi.encodeCall(BellRinger.ring, ()));
        assertFalse(ok, "a starving chore under a cut stipend leaves too little to pay: the whole ring reverts");
        assertFalse(hook.rung(2 * day + 1), "no bell");
        assertEq(imd.balanceOf(bot), 0, "no pay");
    }

    // ── the reward ──
    /// 400 IMD per ETH, a base fee of 1 gwei and the allowance make the reward exactly 1.5 x 400 x (1 gwei + allowance)
    /// x the counted gas, so the count can be read back from the event. The caller pays 6 gwei, 5 above the base fee;
    /// the reward follows the base fee and the allowance, not that.
    function test_RU_rewardIsIndexed() public {
        _fund(10e18);
        _at(OPEN);
        vm.fee(1 gwei);
        vm.txGasPrice(6 gwei);
        (uint256 paid,) = _ring();
        uint256 per = (1 gwei + r.TIP_ALLOWANCE()) * 3 / 2 * 400;
        assertEq(paid % per, 0, "1.5 x gas x (base fee + allowance) x 400");
        uint256 counted = paid / per;
        console2.log("(RU) counted gas incl. OVERHEAD, mock open", counted);
        assertGt(counted, r.OVERHEAD(), "the count includes the ring");
        assertLt(counted, 1_000_000, "the mock ring is light");
    }

    /// (B4 a) Two rings of the same bell from the same state, one tipping 1 wei over the base fee and one 100 gwei over
    /// it, are paid exactly the same.
    function test_RU_rewardIgnoresTheGasPrice() public {
        _fund(10e18);
        _at(OPEN);
        vm.fee(1 gwei);
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(1 gwei + 1);
        (uint256 low,) = _ring();
        vm.revertToState(snap);
        vm.txGasPrice(1 gwei + 100 gwei);
        (uint256 high,) = _ring();
        console2.log("(RU) reward at a 1 wei tip / at a 100 gwei tip", low, high);
        assertGt(low, 0, "paid");
        assertLt(low, r.RING_REWARD_CAP(), "under the cap, so the rate decides it");
        assertEq(high, low, "the same reward whatever gas price the caller chose");
    }

    /// (B4 b) A ringer that tips above the allowance is paid the same, so it nets less by exactly its extra tip x gas;
    /// a ringer at the allowance nets half its cost. Values in ETH wei: the reward / 400 (IMD per ETH) less gas x price.
    function test_RU_tipAboveTheAllowanceIsTheRingersCost() public {
        _fund(10e18);
        _at(OPEN);
        uint256 bf = 1 gwei;
        uint256 tip = r.TIP_ALLOWANCE();
        vm.fee(bf);
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(bf + tip);
        (uint256 paidAt,) = _ring();
        vm.revertToState(snap);
        vm.txGasPrice(bf + tip + 5 gwei);
        (uint256 paidOver,) = _ring();
        assertEq(paidOver, paidAt, "the same reward");
        uint256 g = paidAt / ((bf + tip) * 3 / 2 * 400); // the counted gas, read back as in test_RU_rewardIsIndexed
        int256 netAt = int256(paidAt / 400) - int256(g * (bf + tip));
        int256 netOver = int256(paidOver / 400) - int256(g * (bf + tip + 5 gwei));
        console2.log("(RU) net (ETH wei) at the allowance / at 5 gwei over it");
        console2.logInt(netAt);
        console2.logInt(netOver);
        assertEq(netAt, int256(g * (bf + tip) / 2), "at the allowance the ringer nets half its cost");
        assertLt(netOver, netAt, "tipping more nets less");
        assertEq(netAt - netOver, int256(g * 5 gwei), "by exactly the extra tip x gas");
    }

    /// (B4 c) Base fee 0 pays 1.5 x gas x TIP_ALLOWANCE: against a ring of the same bell from the same state at a 1 gwei
    /// base fee, the two rewards stand exactly in the ratio allowance : (1 gwei + allowance).
    function test_RU_baseFeeZeroPaysTheAllowance() public {
        _fund(10e18);
        _at(OPEN);
        uint256 tip = r.TIP_ALLOWANCE();
        uint256 snap = vm.snapshotState();
        vm.fee(0);
        vm.txGasPrice(0);
        (uint256 p0,) = _ring();
        vm.revertToState(snap);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + tip);
        (uint256 p1,) = _ring();
        console2.log("(RU) reward at base fee 0 / at 1 gwei", p0, p1);
        assertGt(p0, 0, "base fee 0 still pays the allowance");
        assertEq(p0 % (tip * 3 / 2 * 400), 0, "1.5 x gas x allowance x 400");
        assertEq(p0 * (1 gwei + tip), p1 * tip, "exactly allowance : (1 gwei + allowance)");
        assertTrue(hook.rung(2 * day));
    }

    /// (B4 d) A base-fee spike reaches the cap and no further: below it the reward follows the base fee, from there on
    /// every ring pays exactly the cap and the purse falls by exactly the cap.
    function test_RU_baseFeeSpikeReachesTheCapNoFurther() public {
        _fund(30e18);
        uint256 cap = r.RING_REWARD_CAP();
        _at(OPEN);
        vm.fee(10 gwei);
        (uint256 under,) = _ring();
        assertLt(under, cap, "10 gwei: under the cap");
        uint256[4] memory spikes = [uint256(100 gwei), 1_000 gwei, 100_000 gwei, 1e18];
        for (uint256 i; i < 4; ++i) {
            ++day;
            _at(OPEN);
            vm.fee(spikes[i]);
            uint256 held = r.purse();
            (uint256 paid,) = _ring();
            assertEq(paid, cap, "a spike pays the cap");
            assertEq(held - r.purse(), cap, "and the purse falls by the cap, no further");
        }
    }

    function test_RU_rewardCapped() public {
        _fund(10e18);
        _at(OPEN);
        // at the cap: a gas price that makes the uncapped reward 3 IMD to the wei is not reachable exactly; just below
        // and above it instead
        setRingRate(r, 1 gwei);
        (uint256 paid,) = _ring();
        assertLt(paid, r.RING_REWARD_CAP(), "below the cap: indexed");
        ++day;
        _at(OPEN);
        setRingRate(r, 1_000 gwei);
        (paid,) = _ring();
        assertEq(paid, r.RING_REWARD_CAP(), "above the cap: the cap");
    }

    function test_RU_rewardAboveThePurse() public {
        _fund(1e12);
        _at(OPEN);
        setRingRate(r, 1 gwei);
        (uint256 paid,) = _ring();
        assertEq(paid, 1e12, "a reward larger than the purse pays the purse");
        assertEq(imd.balanceOf(address(r)), 0);
        assertEq(imd.balanceOf(bot), 1e12);
    }

    function test_RU_emptyPurseRingsForNothing() public {
        _at(OPEN);
        setRingRate(r, 1 gwei);
        (uint256 paid,) = _ring();
        assertEq(paid, 0, "an empty purse pays nothing");
        assertTrue(hook.rung(2 * day), "the bell still rings");
    }

    function test_RU_rewardPaidAfterTheRing() public {
        _fund(10e18);
        _at(OPEN);
        setRingRate(r, 1 gwei);
        _ring();
        assertEq(hook.lastRinger(), address(r), "the hook sees the ringer");
        assertEq(hook.ringerPurseAtRing(), 10e18, "the purse was whole when the bell rang");
        assertEq(hook.callerImdAtRing(), 0, "the caller had not been paid when the bell rang");
        assertGt(imd.balanceOf(bot), 0, "paid after");
    }

    function test_RU_priceReadFails() public {
        _fund(30e18);
        uint8[3] memory hows = [uint8(1), 2, 3];
        for (uint256 i; i < 3; ++i) {
            ++day;
            _at(OPEN);
            _price(SP400, hows[i]);
            (uint256 paid,) = _ring();
            assertEq(paid, r.RING_REWARD_CAP(), "a reverting, short or starving read pays the cap");
        }
        ++day;
        _at(OPEN);
        _price(0, 0);
        (uint256 p0,) = _ring();
        assertEq(p0, r.RING_REWARD_CAP(), "a zero read pays the cap");
        ++day;
        _at(OPEN);
        _price(uint256(1) << 128, 0);
        (p0,) = _ring();
        assertEq(p0, r.RING_REWARD_CAP(), "an absurd read (2^64 IMD per ETH or more) pays the cap");
        ++day;
        _at(OPEN);
        _price(type(uint160).max, 0);
        (p0,) = _ring();
        assertEq(p0, r.RING_REWARD_CAP(), "the largest sqrt price pays the cap, it does not overflow");
    }

    /// The price is IMD per ETH: a dearer ETH (more IMD per ETH) pays more IMD for the same gas.
    function test_RU_priceOrientation() public {
        _fund(10e18);
        _at(OPEN);
        uint256 snap = vm.snapshotState();
        _price(SP400, 0);
        (uint256 p400,) = _ring();
        vm.revertToState(snap);
        _price(10 << 96, 0); // 100 IMD per ETH, from the same state
        (uint256 p100,) = _ring();
        assertApproxEqRel(p400, 4 * p100, 0.001e18, "four times the IMD per ETH, four times the reward");
        assertEq(r.ethImdPoolId(), keccak256(abi.encode(address(0), address(imd), uint24(10_000), int24(200), address(0))),
            "the pool is ETH (currency0) / IMD, fee 1 %, spacing 200, no hook");
    }

    // ── top-ups ──
    function test_RU_topUpMeasured() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        _build(MockERC20(address(t)));
        t.mint(address(this), 100e18);
        t.approve(address(r), 100e18);
        vm.expectEmit(true, false, false, true, address(r));
        emit BellRinger.ToppedUp(address(this), 99e18);
        r.topUp(100e18);
        assertEq(r.purse(), 99e18, "the purse holds what arrived");
    }

    function test_RU_topUpPlain() public {
        imd.mint(address(this), 5e18);
        imd.approve(address(r), 5e18);
        vm.expectEmit(true, false, false, true, address(r));
        emit BellRinger.ToppedUp(address(this), 5e18);
        r.topUp(5e18);
        assertEq(r.purse(), 5e18);
    }

    // ── the push reward ──
    function _push(uint256 value) internal returns (uint256 paid, bool bridged, uint256 ethBack) {
        vm.deal(bot, value);
        vm.recordLogs();
        vm.prank(bot, bot);
        r.pushBurnRewarded{value: value}();
        ethBack = bot.balance;
        Vm.Log[] memory lg = vm.getRecordedLogs();
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(r) && lg[i].topics[0] == BellRinger.PushRewarded.selector) {
                (paid, bridged) = abi.decode(lg[i].data, (uint256, bool));
            }
        }
    }

    function test_RU_pushBridged() public {
        _fund(10e18);
        imd.mint(address(hook), 9_205_508_960_207_920_806);
        hook.setBurnAccrued(9_205_508_960_207_920_806);
        setRingRate(r, 1 gwei);
        (uint256 paid, bool bridged, uint256 back) = _push(0.001 ether);
        assertTrue(bridged, "the dust the bridge leaves is not 'not bridged'");
        assertEq(back, 0.001 ether - 0.0002 ether, "the excess came back");
        assertGt(paid, 0, "paid");
        assertLe(paid, r.PUSH_REWARD_CAP());
        // the fee is in the cost: 1.5 x (gas x 1 gwei + 0.0002 ETH) x 400 IMD per ETH is at least 0.12 IMD
        assertGe(paid, 0.12e18, "the bridge fee is counted");
        assertEq(imd.balanceOf(hook.burnExecutor()), 9_205_508_960_207_920_806 % 1e12, "the executor kept only dust");
        assertEq(address(r).balance, 0, "the ringer kept no ETH");
    }

    function test_RU_pushNotBridged() public {
        _fund(10e18);
        imd.mint(address(hook), 6e18);
        hook.setBurnAccrued(6e18);
        hook.executor().set(0.0002 ether, 1e12, true);
        (uint256 paid, bool bridged, uint256 back) = _push(0.001 ether);
        assertFalse(bridged);
        assertEq(paid, 0, "not bridged: nothing paid");
        assertEq(back, 0.001 ether, "all the ETH came back");
        assertEq(imd.balanceOf(address(r)), 10e18, "the purse untouched");
        // and with no ETH at all
        imd.mint(address(hook), 6e18);
        hook.setBurnAccrued(6e18);
        hook.executor().set(0.0002 ether, 1e12, false);
        (paid, bridged,) = _push(0);
        assertFalse(bridged);
        assertEq(paid, 0, "an ETH-less push cannot farm the reward");
    }

    /// The executor already holds dust from earlier burns: a bridged burn still reads as bridged, an unbridged one as not.
    function test_RU_pushDustOnly() public {
        _fund(10e18);
        imd.mint(hook.burnExecutor(), 999_999_999_999);
        imd.mint(address(hook), 6e18 + 5);
        hook.setBurnAccrued(6e18 + 5);
        (uint256 paid, bool bridged,) = _push(0.0002 ether);
        assertTrue(bridged, "bridged with old dust present");
        assertGt(paid, 0);
        hook.executor().set(0.0002 ether, 1e12, true);
        imd.mint(address(hook), 6e18);
        hook.setBurnAccrued(6e18);
        (paid, bridged,) = _push(0.0002 ether);
        assertFalse(bridged, "unbridged with old dust present");
        assertEq(paid, 0);
    }

    function test_RU_pushCapped() public {
        _fund(10e18);
        imd.mint(address(hook), 6e18);
        hook.setBurnAccrued(6e18);
        hook.executor().set(1 ether, 1e12, false);
        (uint256 paid, bool bridged,) = _push(1 ether);
        assertTrue(bridged);
        assertEq(paid, r.PUSH_REWARD_CAP(), "a dear bridge pays the push cap");
    }

    function test_RU_pushBelowMinimumReverts() public {
        imd.mint(address(hook), 1e18);
        hook.setBurnAccrued(1e18);
        vm.deal(bot, 1 ether);
        vm.prank(bot, bot);
        vm.expectRevert(MockRingHook.BelowMinBurn.selector);
        r.pushBurnRewarded{value: 1 ether}();
    }

    function test_RU_noEthOutsideThePush() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory e) = address(r).call{value: 1}("");
        assertFalse(ok, "stray ETH is refused");
        assertEq(bytes4(e), BellRinger.NoEth.selector);
    }

    // ── reentrancy ──
    function test_RU_reentryThroughTheTokenTransfer() public {
        ReentrantToken t = new ReentrantToken();
        _build(MockERC20(address(t)));
        t.mint(address(r), 10e18);
        bytes[3] memory calls = [
            abi.encodeCall(BellRinger.topUp, (1)),
            abi.encodeCall(BellRinger.ring, ()),
            abi.encodeCall(BellRinger.pushBurnRewarded, ())
        ];
        for (uint256 i; i < 3; ++i) {
            ++day;
            _at(OPEN);
            setRingRate(r, 1 gwei);
            t.arm(address(r), calls[i]);
            uint256 a0 = t.attempts();
            vm.prank(bot, bot);
            r.ring{gas: 9_000_000}();
            assertEq(t.attempts(), a0 + 1, "the reward transfer called back in");
            assertFalse(t.lastOk(), "the call back in failed");
            assertEq(bytes4(t.lastErr()), BellRinger.Reentrant.selector, "refused by the lock");
        }
    }

    function test_RU_reentryThroughAChore() public {
        _fund(10e18);
        _at(OPEN);
        hook.setMode(HARVEST, REENTER);
        hook.setReenter(address(r), abi.encodeCall(BellRinger.topUp, (1)));
        vm.recordLogs();
        vm.prank(bot, bot);
        r.ring{gas: 9_000_000}();
        (uint256 mask, bytes4[8] memory why) = _skips(vm.getRecordedLogs());
        assertEq(mask, 1 << 2, "only the reentering chore was skipped");
        assertEq(why[2], BellRinger.Reentrant.selector, "refused by the lock");
    }

    // ── nothing else ──
    function test_RU_noOwnerPath() public view {
        bytes memory code = address(r).code;
        bytes4[8] memory f = [
            bytes4(keccak256("owner()")), bytes4(keccak256("withdraw()")), bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("withdraw(address,uint256)")), bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("transferOwnership(address)")), bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("setReward(uint256)"))
        ];
        for (uint256 i; i < f.length; ++i) {
            for (uint256 j; j + 5 <= code.length; ++j) {
                bool hit = code[j] == 0x63 && code[j + 1] == f[i][0] && code[j + 2] == f[i][1] && code[j + 3] == f[i][2]
                    && code[j + 4] == f[i][3];
                assertFalse(hit, "a forbidden function is dispatched");
            }
        }
    }
}
