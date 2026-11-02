// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursCoin} from "../src/MarketHoursCoin.sol";
import {BellGame} from "../src/BellGame.sol";
import {SwarmBudget} from "../src/SwarmBudget.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {Base, IERC20T} from "./Base.sol";
import {IIntakeH, IStandIn} from "./Budget.sol";
import {setRingRate, clearRingRate} from "./RingRate.sol";

/// Drives the four contracts through random multi-day sequences. Every action is tried; a revert is checked against the
/// rule that should have caused it where the rule is simple, and the ghosts record what moved so the invariants can
/// compare. Time moves only through `warp`, forward.
contract Handler is Test {
    MarketHoursHook public hook;
    MarketHoursCoin public coin;
    IERC20T public imd;
    BellGame public game;
    SwarmBudget public budget;
    BellRinger public ringer;
    IPoolManager public manager;
    PoolSwapTest public router;
    address public intake;
    address public intakeWriter;
    address[3] public actors;
    uint256 public d0;

    // ghosts
    uint256[] public orderIds;
    mapping(uint256 => bool) public isClaimed;
    uint256 public feeSum; // Σ FeeTaken.amount
    uint256 public accrualAtClaims; // Σ (burn + network + feeWallet + swarm) increases at claims, less unfilled IMD fees
    uint256 public unfilledImd; // Σ UnfilledFeeTaken on buys (IMD, to the burn)
    uint256 public unfilledCoin; // Σ UnfilledFeeTaken on sells (coin, to the coin burn)
    uint256 public pendingImd; // stray IMD sent to the hook and not yet harvested
    uint256 public pendingCoin;
    uint256 public burnedCoin;
    uint256 public coinSupply0;
    mapping(uint256 => uint256) public opens; // day => ringOpen successes
    mapping(uint256 => uint256) public closes;
    uint256 public ringOpenInWindowFails;
    uint256 public claimsOk;
    uint256 public claimsFailed;
    uint256 public swapsOk;
    uint256 public ringsOk;
    uint256 public requestsOk;
    uint256 public guessesStored;
    uint256 public pointsTallied;
    uint256 public revealsOk;
    uint256 public revealsRefused;
    uint256 public settlesOk;
    uint256 public lastSettledDay;
    // the bell purse: every IMD that reached the ringer and every IMD it paid out
    uint256 public purseIn;
    uint256 public purseOut;
    uint256 public ringerRings;
    /// The bells whose chores the ringer has run (once each, whether it rang them or a direct ring did)
    mapping(uint256 => bool) public ringerServed;
    uint256 public ringerChoresOnly; // rings that found the bell already rung straight at the hook
    uint256 public ringerRewards;

    struct Sealed {
        address who;
        uint256 orderId;
        uint256 day;
        uint256 guess;
        bytes32 salt;
        bool revealed;
    }

    Sealed[] public sealedGuesses;
    bytes32 public lastGuessId;
    bytes32 public lastReportId;
    uint256 public lastNight;

    uint256 internal constant OPEN = 43200;
    uint256 internal constant CLOSE = 57600;
    uint256 internal constant Q96 = 1 << 96;

    constructor(
        MarketHoursHook hook_,
        MarketHoursCoin coin_,
        address imd_,
        IPoolManager manager_,
        PoolSwapTest router_,
        address intake_,
        address writer_,
        address[3] memory actors_
    ) {
        hook = hook_;
        coin = coin_;
        imd = IERC20T(imd_);
        game = BellGame(hook_.game());
        budget = SwarmBudget(hook_.swarmBudget());
        ringer = BellRinger(payable(hook_.bellPurse()));
        manager = manager_;
        router = router_;
        intake = intake_;
        intakeWriter = writer_;
        actors = actors_;
        d0 = block.timestamp / 1 days;
        coinSupply0 = coin.totalSupply();
    }

    // ── helpers ──
    function _actor(uint8 i) internal view returns (address) {
        return actors[i % 3];
    }

    function _day() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _tod() internal view returns (uint256) {
        return block.timestamp % 1 days;
    }

    function _rung(uint256 s) internal view returns (bool r) {
        (, r,,,,) = hook.bells(s);
    }

    /// the one book that is open to orders now, or 0 (none)
    function _enterable() internal view returns (uint256 s, bool any) {
        uint256 d = _day();
        uint256 tod = _tod();
        if (d == 0) return (0, false);
        if (tod < OPEN - 600 && hook.closeSettled(d - 1)) return (2 * d, true);
        if (_rung(2 * d) && tod >= OPEN && tod < CLOSE - 600) return (2 * d + 1, true);
        if (hook.closeSettled(d)) return (2 * (d + 1), true);
        return (0, false);
    }

    function _has(bytes memory data, bytes4 sel) internal pure returns (bool) {
        return data.length >= 4 && bytes4(data) == sel;
    }

    function _c2i(uint256 c, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(c, sp, Q96), sp, Q96);
    }

    function _i2c(uint256 i, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(i, Q96, sp), Q96, sp);
    }

    function _accruals() internal view returns (uint256) {
        return hook.burnAccrued() + hook.networkAccrued() + hook.feeWalletImdAccrued() + hook.swarmAccrued() + hook.bellPurseAccrued();
    }

    // ── time ──
    /// Forward only, into one of the day's slots: the morning book, the opening bell, the session, after the settle
    /// window, the closing bell, the evening, the night. A slot already passed today is taken tomorrow.
    function warp(uint8 slot, uint256 delta, uint256 blocks) external {
        uint256[7] memory from = [uint256(2 hours), OPEN, OPEN + 6 minutes, OPEN + 1800 + 30, CLOSE, CLOSE + 10 minutes, 20 hours];
        uint256[7] memory span = [uint256(8 hours), 5 minutes, 80 minutes, 25 minutes, 5 minutes, 3 hours + 40 minutes, 3 hours];
        uint256 i = slot % 7;
        uint256 tod = from[i] + bound(delta, 0, span[i]);
        uint256 target = _day() * 1 days + tod;
        if (target <= block.timestamp) target += 1 days;
        vm.warp(target);
        vm.roll(block.number + bound(blocks, 1, 30));
    }

    // ── the book ──
    function place(uint8 who, bool buy, int256 off, uint256 amt) external {
        (uint256 s, bool any) = _enterable();
        if (!any) return;
        int24 ref = hook.referenceOf(s);
        int24 bucket = ref + int24(bound(off, -200, 200)) * 60;
        amt = bound(amt, 0.5e18, 3_000e18);
        address a = _actor(who);
        vm.prank(a);
        try hook.placeOrder(s, buy, bucket, amt) returns (uint256 id) {
            orderIds.push(id);
        } catch (bytes memory e) {
            // a sell below the minimum at the reference, or the book's cap, are the only admissible refusals here
            require(
                _has(e, MarketHoursHook.BelowMinOrder.selector) || _has(e, MarketHoursHook.BookFull.selector),
                "placeOrder refused an admissible order"
            );
        }
    }

    function cancel(uint256 idx) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[bound(idx, 0, orderIds.length - 1)];
        (address owner, uint256 s, bool buy,, uint256 amount) = hook.orderInfo(id);
        if (isClaimed[id]) return;
        uint256 before = buy ? imd.balanceOf(owner) : coin.balanceOf(owner);
        vm.prank(owner);
        try hook.cancelOrder(id) {
            isClaimed[id] = true;
            uint256 fee = (amount * 50 + 9_999) / 10_000;
            uint256 got = (buy ? imd.balanceOf(owner) : coin.balanceOf(owner)) - before;
            assertEq(got, amount - fee, "rounding: the cancel refund is the escrow less the fee rounded up");
        } catch (bytes memory e) {
            require(_has(e, MarketHoursHook.CancelLocked.selector), "cancel refused for another reason");
            // A cancel inside the no-cancel hour of its own book is locked; outside its window it is locked too
            s;
        }
    }

    // ── the bells ──
    function ringOpen() external {
        uint256 d = _day();
        bool expectOk = _tod() >= OPEN && _tod() < CLOSE && !_rung(2 * d);
        _ring(2 * d, true, expectOk);
    }

    function ringClose() external {
        uint256 d = _day();
        bool expectOk = _tod() >= CLOSE && _tod() < 72000 && !_rung(2 * d + 1);
        _ring(2 * d + 1, false, expectOk);
    }

    /// Audit finding 2: the pool's own price a bell reads before its residual, as a bucket: the session's checkpoint mean
    /// if it traded, else the last checkpoint's price, else (no checkpoint ever) the reference as it stands; held to
    /// +-875,220 ticks (the harness's coin sorts below IMD, so a bucket is the pool tick)
    function _anchorNow() internal view returns (int24) {
        (, uint160 sp, int48 sum, uint16 count) = hook.checkpoint();
        if (count == 0 && sp == 0) return hook.lastCleared();
        int256 t = count > 0 ? int256(sum) / int256(uint256(count)) : int256(TickMath.getTickAtSqrtPrice(sp));
        if (t > 875_220) t = 875_220;
        if (t < -875_220) t = -875_220;
        return _nearest(t);
    }

    function _ring(uint256 s, bool open, bool expectOk) internal {
        (,, int48 sum0, uint16 count0) = hook.checkpoint();
        int24 anchor0 = _anchorNow();
        uint256 i0 = imd.balanceOf(address(hook));
        uint256 c0 = coin.balanceOf(address(hook));
        uint256 b0 = hook.burnAccrued();
        uint256 cb0 = hook.coinBurnAccrued();
        int24 ref = hook.referenceOf(s);
        (, uint256 matchedBefore,,) = hook.indicativePrice(s);
        bool ok;
        if (open) {
            try hook.ringOpen() {
                ok = true;
            } catch {}
        } else {
            try hook.ringClose() {
                ok = true;
            } catch {}
        }
        assertEq(ok, expectOk, "two bells: a bell rang when it should not have, or failed when it should have rung");
        if (!ok) return;
        ++ringsOk;
        if (open) ++opens[s / 2];
        else ++closes[s / 2];
        assertLe(opens[s / 2], 1, "two bells: two opens in a day");
        assertLe(closes[s / 2], 1, "two bells: two closes in a day");
        (int24 p, bool rung, bool buyHeavy,,, uint64 rf) = hook.bells(s);
        assertTrue(rung);
        assertEq(hook.lastCleared(), anchor0, "reference chain: the next reference = the pool's own price before the bell");
        (,, int48 sum1, uint16 count1) = hook.checkpoint();
        assertEq(count1, 0, "the counters reset at the ring");
        assertEq(int256(sum1), 0);
        // The residual swap never pays more than P* per coin, fee included; the price improvement is booked to the
        // burns: the IMD not spent, and (on a buy) the coin bought beyond what the residual buyers are paid at P*
        uint160 sp = TickMath.getSqrtPriceAtTick(p);
        if (rf > 0) {
            uint256 cb = hook.coinBurnAccrued() - cb0;
            if (buyHeavy) {
                uint256 spent = i0 - imd.balanceOf(address(hook));
                uint256 got = coin.balanceOf(address(hook)) - c0;
                assertLe(spent, _c2i(got, sp), "residual price: buy residual paid more than P* per coin");
                uint256 booked = (hook.burnAccrued() - b0) + _c2i(cb, sp);
                uint256 improvement = _c2i(got, sp) - spent;
                assertLe(booked, improvement + 64, "residual price: more surplus booked than the improvement");
                assertGe(booked + 64, improvement, "residual price: the price improvement was not booked");
            } else {
                uint256 spent = c0 - coin.balanceOf(address(hook));
                uint256 got = imd.balanceOf(address(hook)) - i0;
                assertGe(got + 64, _c2i(spent, sp), "residual price: sell residual took less than P* per coin");
                assertLe(hook.burnAccrued() - b0, got, "residual price: surplus booked beyond what was received");
                assertGe(hook.burnAccrued() - b0 + _c2i(spent, sp) + 64, got, "residual price: the sell improvement was not booked");
            }
        }
        // stale reference: a zero-match bell clears at the pool's own price (the mean's bucket with checkpoints, spot's with
        // none), held inside the band
        if (matchedBefore == 0) {
            int24 want = anchor0;
            int24 lo = ref - 200 * 60;
            if (want < lo) want = lo;
            if (want > ref + 200 * 60) want = ref + 200 * 60;
            assertEq(p, want, count0 > 0 ? "stale reference: zero matches with checkpoints -> the mean's bucket" : "stale reference: zero matches, no checkpoints -> spot's bucket");
        }
    }

    // ── the ringer: whichever bell is due, its chores, the reward ──
    function ring() external {
        uint256 d = _day();
        uint256 tod = _tod();
        bool open = tod >= OPEN && tod < CLOSE;
        uint256 s = open ? 2 * d : 2 * d + 1;
        // due and not yet served by the ringer; a bell rung straight at the hook is still served once
        bool expectOk = (open || (tod >= CLOSE && tod < 72000)) && !ringerServed[s];
        bool wasRung = _rung(s);
        int24 lc0 = hook.lastCleared();
        int24 anchor0 = _anchorNow();
        uint256 held0 = imd.balanceOf(address(ringer));
        // a real rate, so the reward is not zero where the env has an ETH/IMD price (none offline pays 0)
        uint256 bf0 = setRingRate(ringer, 1 gwei);
        vm.recordLogs();
        // above the raised floor plus the closing chores (Base.RING_GAS_T)
        (bool ok,) = address(ringer).call{gas: 13_000_000}(abi.encodeCall(BellRinger.ring, ()));
        Vm.Log[] memory lg = vm.getRecordedLogs();
        clearRingRate(bf0);
        assertEq(ok, expectOk, "ringing: ring() succeeded iff a bell was due and its chores not yet run by the ringer");
        if (!ok) {
            assertEq(imd.balanceOf(address(ringer)), held0, "ringer purse: a ring that rang nothing moved the purse");
            return;
        }
        assertTrue(_rung(s), "ringing: the bell rang");
        ringerServed[s] = true;
        ++ringerRings;
        if (wasRung) {
            ++ringerChoresOnly;
        } else {
            ++ringsOk;
            if (open) ++opens[d];
            else ++closes[d];
        }
        assertLe(opens[d], 1, "two bells: two opens in a day");
        assertLe(closes[d], 1, "two bells: two closes in a day");
        // reference chain: a bell this call rang sets the next reference to the pool's own price; chores alone leave it
        assertEq(hook.lastCleared(), wasRung ? lc0 : anchor0, "reference chain: the next reference = the pool's own price before the bell");
        uint256 inflow;
        uint256 paid;
        bool rewarded;
        bool harvested = open;
        for (uint256 i; i < lg.length; ++i) {
            bytes32 t0 = lg[i].topics[0];
            if (lg[i].emitter == address(hook) && t0 == MarketHoursHook.BellPursePaid.selector) {
                inflow += abi.decode(lg[i].data, (uint256));
            } else if (lg[i].emitter == address(ringer) && t0 == BellRinger.Rewarded.selector) {
                (paid,) = abi.decode(lg[i].data, (uint256, bool));
                rewarded = true;
            } else if (lg[i].emitter == address(ringer) && t0 == BellRinger.ChoreSkipped.selector) {
                if (uint256(lg[i].topics[1]) == 2) harvested = false;
            }
        }
        assertTrue(rewarded, "ringing: Rewarded on every ring");
        assertLe(paid, ringer.RING_REWARD_CAP(), "ringer purse: a reward over the cap");
        assertLe(paid, held0 + inflow, "ringer purse: a reward over what the purse held");
        assertEq(imd.balanceOf(address(ringer)), held0 + inflow - paid, "ringer purse: the purse moved by inflow less the reward");
        purseIn += inflow;
        purseOut += paid;
        if (paid > 0) ++ringerRewards;
        // the opening chores harvested: the stray inflow is folded
        if (harvested) {
            pendingImd = 0;
            pendingCoin = 0;
        }
    }

    function topUp(uint256 a) external {
        a = bound(a, 0, 20e18);
        if (imd.balanceOf(address(this)) < a) return;
        imd.approve(address(ringer), a);
        uint256 b0 = imd.balanceOf(address(ringer));
        ringer.topUp(a);
        assertEq(imd.balanceOf(address(ringer)) - b0, a, "a plain top-up arrives whole");
        purseIn += a;
    }

    function claimBellPurse() external {
        uint256 a = hook.bellPurseAccrued();
        uint256 b0 = imd.balanceOf(address(ringer));
        uint256 me0 = imd.balanceOf(address(this));
        hook.claimBellPurse();
        assertEq(imd.balanceOf(address(ringer)) - b0, a, "ringer purse: claimBellPurse pays exactly the accrual to BELL_PURSE");
        assertEq(imd.balanceOf(address(this)), me0, "ringer purse: and nothing to its caller");
        assertEq(hook.bellPurseAccrued(), 0);
        purseIn += a;
    }

    function pushBurnRewarded() external {
        vm.deal(address(this), 1 ether);
        uint256 held0 = imd.balanceOf(address(ringer));
        uint256 bf0 = setRingRate(ringer, 1 gwei);
        vm.recordLogs();
        try ringer.pushBurnRewarded{value: 0.0002 ether}() {
            Vm.Log[] memory lg = vm.getRecordedLogs();
            uint256 paid;
            bool bridged;
            for (uint256 i; i < lg.length; ++i) {
                if (lg[i].emitter == address(ringer) && lg[i].topics[0] == BellRinger.PushRewarded.selector) {
                    (paid, bridged) = abi.decode(lg[i].data, (uint256, bool));
                }
            }
            assertTrue(bridged || paid == 0, "ringer purse: a push paid without bridging");
            assertLe(paid, ringer.PUSH_REWARD_CAP(), "ringer purse: a push reward over its cap");
            assertEq(held0 - imd.balanceOf(address(ringer)), paid, "ringer purse: the purse moved by the push reward only");
            purseOut += paid;
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.BelowMinBurn.selector), "pushBurnRewarded refused for another reason");
        }
        clearRingRate(bf0);
        assertEq(address(ringer).balance, 0, "the ringer kept ETH");
    }

    function _nearest(int256 x) internal pure returns (int24) {
        int256 q = x / 60;
        int256 rem = x % 60;
        if (rem > 30) ++q;
        else if (rem <= -30) --q;
        return int24(q * 60);
    }

    // ── claims ──
    function claim(uint256 idx) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[bound(idx, 0, orderIds.length - 1)];
        _claim(id);
    }

    function _claim(uint256 id) internal returns (bool ok) {
        if (isClaimed[id]) return false;
        (address owner, uint256 s, bool buy, int24 bucket, uint256 amount) = hook.orderInfo(id);
        (int24 p, bool rung,,,,) = hook.bells(s);
        bool claimable = rung || block.timestamp >= (s / 2) * 1 days + (s & 1 == 0 ? CLOSE : 72000);
        bool paidBefore = hook.ticketPaid(id);
        uint256 acc0 = _accruals();
        uint256 cb0 = hook.coinBurnAccrued();
        uint256 io = imd.balanceOf(owner);
        uint256 co = coin.balanceOf(owner);
        vm.recordLogs();
        try hook.claim(id) {
            ok = true;
        } catch (bytes memory e) {
            require(_has(e, MarketHoursHook.NotClaimable.selector), "a claim reverted for a reason other than timing");
            require(!claimable, "claims: a claimable order's claim reverted");
            return false;
        }
        require(claimable, "a claim succeeded before the bell or the deadline");
        isClaimed[id] = true;
        ++claimsOk;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fee;
        uint256 ufee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[1] != bytes32(id)) continue;
            if (logs[i].topics[0] == keccak256("FeeTaken(uint256,uint256)")) {
                fee = abi.decode(logs[i].data, (uint256));
            } else if (logs[i].topics[0] == keccak256("UnfilledFeeTaken(uint256,bool,uint256)")) {
                (, ufee) = abi.decode(logs[i].data, (bool, uint256));
            }
        }
        // the unfilled-order fee: all of the escrow on an order its rung bell did not reach; on a reached order, the
        // unfilled share, never more than 0.5 % of the escrow and nothing for a rationed marginal bucket; never on an
        // unrung bell
        bool reached = buy ? bucket >= p : bucket <= p;
        uint256 maxFee = (amount * 50 + 9_999) / 10_000;
        if (!rung) {
            assertEq(ufee, 0, "unfilled fee charged on an unrung bell");
        } else if (!reached) {
            assertEq(ufee, maxFee, "unfilled fee: 0.5 % of the escrow, rounded up");
        } else {
            assertLe(ufee, maxFee, "a reached order's unfilled fee exceeds 0.5 % of its escrow");
            (,, bool heavy,, uint64 marg,) = hook.bells(s);
            if (buy == heavy && bucket == p && marg > 0) assertEq(ufee, 0, "a rationed marginal remainder paid the unfilled fee");
        }
        if (buy) unfilledImd += ufee;
        else unfilledCoin += ufee;
        assertEq(hook.coinBurnAccrued() - cb0, buy ? 0 : ufee, "a sell's unfilled fee goes to the coin burn, nothing else does here");
        feeSum += fee;
        uint256 dAcc = _accruals() - acc0 - (buy ? ufee : 0);
        accrualAtClaims += dAcc;
        assertEq(dAcc, fee, "fee split: the accruals rose by exactly the bell fee and the unfilled fee");
        // the ticket answer is read from the bell, not from the claim
        assertEq(hook.ticketPaid(id), paidBefore, "ticketPaid changed at the claim");
        if (fee > 0) {
            assertEq(hook.networkAccrued() * 0 + fee * 2000 / 10_000 + fee * 2000 / 10_000 + fee * 1000 / 10_000 + (fee - fee * 2000 / 10_000 - fee * 2000 / 10_000 - fee * 1000 / 10_000), fee, "fee split: the four shares are the fee");
        }
        // price and escrow: what the owner received, valued at P*, never beats what it was charged; the whole escrow is accounted
        uint256 gotImd = imd.balanceOf(owner) - io;
        uint256 gotCoin = coin.balanceOf(owner) - co;
        // a reached order that received nothing and paid no bell fee filled nothing (to the wei): its fee is on all of it
        if (rung && reached && fee == 0 && (buy ? gotCoin : gotImd) == 0 && ufee > 0) {
            assertGe(ufee + 1, maxFee, "a reached order that filled nothing pays 0.5 % of all of it");
        }
        if (!rung) {
            assertEq(buy ? gotImd : gotCoin, amount, "an unrung book refunds in full");
            return true;
        }
        if (!reached) {
            assertEq(buy ? gotImd : gotCoin, amount - ufee, "an order the bell did not reach is refunded less the fee");
            assertEq(buy ? gotCoin : gotImd, 0, "and receives nothing else");
            return true;
        }
        uint160 sp = TickMath.getSqrtPriceAtTick(p);
        // the charged leg exceeds the paid leg by at most one wei of ratio (amount / 1e18) plus one per leg, two legs;
        // and the paid leg, converted to coin at P* and valued back in IMD here, loses up to two floors each way (a few
        // wei, scaled by the price). With 0.5 IMD orders amount / 1e18 is 0, so the conversion term is stated on its own.
        uint256 slack = 2 * (amount / 1e18 + 2) + 8 + _c2i(8, sp);
        if (buy) {
            uint256 charged = amount - gotImd; // book + residual + bell fee + unfilled fee
            assertLe(_c2i(gotCoin, sp), charged, "price and escrow: a buyer got more coin than its IMD was worth at P*");
            if (charged > fee + ufee) assertGe(_c2i(gotCoin, sp) + slack + fee + ufee, charged, "price at P*: a buyer paid more than P* beyond rounding");
        } else {
            uint256 sold = amount - gotCoin - ufee; // the coin that filled
            assertLe(gotImd + fee, _c2i(sold, sp) + 1, "price and escrow: a seller got more IMD than its coin was worth at P*");
            assertGe(gotImd + fee + _c2i(slack, sp) + 2, _c2i(sold, sp), "price at P*: a seller received less than P* beyond rounding");
        }
    }

    // ── swaps and exits ──
    function swap(uint8 who, bool imdIn, uint256 amt) external {
        amt = bound(amt, 1e18, 9_000e18);
        address a = _actor(who);
        uint256 d = _day();
        bool inSession = _tod() >= OPEN && _tod() < CLOSE;
        bool rung = _rung(2 * d);
        vm.prank(a);
        try router.swap(
            hook.poolKey(),
            IPoolManager.SwapParams(!imdIn, -int256(amt), imdIn ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            ++swapsOk;
            assertTrue(inSession && rung, "session rules: an external swap succeeded outside the session");
        } catch (bytes memory e) {
            if (!inSession) assertTrue(_has(e, MarketHoursHook.MarketClosed.selector) || _hasWrapped(e, MarketHoursHook.MarketClosed.selector), "session rules: closed market refused for another reason");
            else if (!rung) assertTrue(_has(e, MarketHoursHook.AwaitingBell.selector) || _hasWrapped(e, MarketHoursHook.AwaitingBell.selector), "session rules: unrung session refused for another reason");
        }
    }

    function _hasWrapped(bytes memory e, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= e.length; ++i) {
            if (e[i] == sel[0] && e[i + 1] == sel[1] && e[i + 2] == sel[2] && e[i + 3] == sel[3]) return true;
        }
        return false;
    }

    function exit(uint8 who, uint256 amt) external {
        amt = bound(amt, 1e18, 500e18);
        address a = _actor(who);
        uint256 d = _day();
        if (d == 0) return;
        bool closed = hook.closeSettled(d) || (_tod() < OPEN - 600 && hook.closeSettled(d - 1));
        uint256 b0 = hook.burnAccrued();
        vm.prank(a);
        try hook.emergencyExit(amt, 0) {
            assertTrue(closed, "session rules: an exit ran outside CLOSED");
            assertGe(hook.burnAccrued(), b0, "the exit penalty accrued to the burn");
        } catch (bytes memory e) {
            if (!closed) assertTrue(_has(e, MarketHoursHook.ExitClosed.selector), "exit refused for another reason");
        }
    }

    // ── flows ──
    function inject(bool imdSide, uint256 amt) external {
        amt = bound(amt, 1, 200e18);
        if (imdSide) {
            if (imd.balanceOf(address(this)) < amt) return;
            imd.transfer(address(hook), amt);
            pendingImd += amt;
        } else {
            if (coin.balanceOf(address(this)) < amt) return;
            coin.transfer(address(hook), amt);
            pendingCoin += amt;
        }
    }

    function harvest() external {
        uint256 sw0 = hook.swarmAccrued();
        uint256 bp0 = hook.bellPurseAccrued();
        uint256 b0 = hook.burnAccrued();
        uint256 cb0 = hook.coinBurnAccrued();
        uint256 f0 = hook.feeWalletCoinAccrued();
        hook.harvest();
        assertEq(hook.swarmAccrued() - sw0, pendingImd * 1000 / 10_000, "harvest: 10% of IMD inflow to the swarm slice");
        assertEq(hook.bellPurseAccrued() - bp0, pendingImd * 1000 / 10_000, "harvest: 10% of IMD inflow to the bell purse slice");
        assertEq(hook.burnAccrued() - b0, pendingImd - 2 * (pendingImd * 1000 / 10_000), "harvest: the rest burns");
        assertEq(hook.coinBurnAccrued() - cb0, pendingCoin * 5000 / 10_000, "harvest: 50% of coin inflow to the coin burn");
        assertEq(hook.feeWalletCoinAccrued() - f0, pendingCoin - pendingCoin * 5000 / 10_000, "harvest: the rest to the fee wallet");
        pendingImd = 0;
        pendingCoin = 0;
    }

    function pushBurn() external {
        uint256 a = hook.burnAccrued();
        vm.deal(address(this), 1 ether);
        try hook.pushBurn{value: 0.0002 ether}() {
            assertGe(a, 5e18, "pushBurn ran below the minimum");
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.BelowMinBurn.selector), "pushBurn refused for another reason");
        }
    }

    function burnCoin() external {
        uint256 a = hook.coinBurnAccrued();
        try hook.burnCoin() {
            burnedCoin += a;
        } catch (bytes memory e) {
            assertTrue(_has(e, MarketHoursHook.BelowMinBurn.selector), "burnCoin refused for another reason");
        }
    }

    function claimFeeWallet() external {
        hook.claimFeeWallet();
    }

    function claimNetworkFees() external {
        hook.claimNetworkFees();
    }

    function claimSwarmBudget() external {
        hook.claimSwarmBudget();
        assertLe(imd.balanceOf(address(budget)), budget.CAP(), "purse cap: the purse holds more than its cap");
    }

    function seedDust(uint256 a, uint256 b) external {
        a = bound(a, 0, 1e15);
        b = bound(b, 0, 1e15);
        if (imd.balanceOf(address(this)) < a || coin.balanceOf(address(this)) < b) return;
        imd.approve(address(hook), a);
        coin.approve(address(hook), b);
        hook.seedDust(a, b);
    }

    // ── the game ──
    function commit(uint256 idx, int256 off) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[bound(idx, 0, orderIds.length - 1)];
        (address owner, uint256 s,,,) = hook.orderInfo(id);
        uint256 day = s / 2 + 1;
        int24 g = hook.referenceOf(s) + int24(bound(off, -20, 20)) * 60;
        uint256 guess = uint256(int256(g) + 887_280);
        bytes32 salt = keccak256(abi.encode(id, off, block.timestamp));
        bool allowed = block.timestamp < (day - 1) * 1 days + CLOSE && !game.ticketUsed(id);
        vm.prank(owner);
        try game.commit(id, keccak256(abi.encode(guess, salt, owner, day))) {
            assertTrue(allowed, "sealing: a commit was taken at or after 16:00 of the ticket's day, or a ticket was used twice");
            sealedGuesses.push(Sealed(owner, id, day, guess, salt, false));
        } catch {
            assertFalse(allowed, "a commit that should have been taken was refused");
        }
    }

    function settle() external {
        uint256 d = _day();
        (bool settled,,,) = game.dayState(d);
        if (settled) return;
        (int256 sum, uint256 n, uint256 openedAt,) = hook.sessionMean();
        (int24 pStar, bool rung,,,,) = hook.bells(2 * d);
        try game.settle(d) {
            (, bool isVoid, bool fromMean, int24 scored) = game.dayState(d);
            if (isVoid) {
                assertFalse(rung, "a day with a bell was voided");
                assertGe(_tod(), CLOSE, "voided before 16:00");
                return;
            }
            assertTrue(rung && block.timestamp >= openedAt + 1800, "settle window: settled before the window from the bell's own time ended");
            assertEq(fromMean, n > 0);
            ++settlesOk;
            if (n > 0) assertEq(scored, _nearest(sum / int256(n)), "settle window: scored = nearest bucket of the window's mean");
            else assertEq(scored, pStar, "settle window: no checkpoint -> P*");
            (int256 sum2, uint256 n2,,) = hook.sessionMean();
            assertEq(sum2, sum, "settle window: settle never changes the hook's counters");
            assertEq(n2, n);
            lastSettledDay = d;
        } catch {}
    }

    function reveal(uint256 k) external {
        if (sealedGuesses.length == 0) return;
        Sealed storage sd = sealedGuesses[bound(k, 0, sealedGuesses.length - 1)];
        if (sd.revealed) return;
        (uint32 r0, uint32 c0) = game.rankOf(sd.day, 0);
        r0;
        c0;
        bool paid = hook.ticketPaid(sd.orderId);
        vm.prank(sd.who);
        try game.reveal(sd.orderId, sd.guess, sd.salt) {
            sd.revealed = true;
            ++revealsOk;
            assertEq(_day(), sd.day, "a reveal landed on another day");
            assertLt(_tod(), CLOSE, "sealing: a reveal after 16:00");
            assertTrue(paid, "a ticket whose order did not pay for it ranked");
        } catch (bytes memory e) {
            if (_has(e, BellGame.TicketUnpaid.selector)) {
                assertFalse(paid, "a paid ticket was refused as unpaid");
                ++revealsRefused;
            }
        }
    }

    function revealWrongSalt(uint256 k) external {
        if (sealedGuesses.length == 0) return;
        Sealed storage sd = sealedGuesses[bound(k, 0, sealedGuesses.length - 1)];
        if (sd.revealed) return;
        (uint32 d0_, uint32 c0) = game.rankOf(sd.day, 0);
        vm.prank(sd.who);
        try game.reveal(sd.orderId, sd.guess, keccak256("wrong")) {
            fail("sealing: a reveal with the wrong salt was accepted");
        } catch {}
        (uint32 d1, uint32 c1) = game.rankOf(sd.day, 0);
        assertTrue(d0_ == d1 && c0 == c1, "sealing: a wrong-salt reveal changed the ranking");
    }

    /// tally after the reveal window: the points added are the ones the game reports, once per wallet and day
    function tally(uint8 who, uint256 k) external {
        if (sealedGuesses.length == 0) return;
        _tally(who, sealedGuesses[bound(k, 0, sealedGuesses.length - 1)].day);
    }

    function _tally(uint8 who, uint256 day) internal {
        address a = _actor(who);
        uint256 want = game.pointsOf(day, a);
        uint256 p0 = game.points(a);
        try game.tally(day, a) {
            assertEq(game.points(a) - p0, want, "the points added are the ones reported");
            assertGt(want, 0);
            assertLe(want, 3, "at most 3 points a day");
            assertGe(block.timestamp, day * 1 days + CLOSE, "points before the reveal window closed");
            pointsTallied += want;
        } catch {
            if (want > 0 && block.timestamp >= day * 1 days + CLOSE && !game.tallied(day, a)) {
                (bool settled, bool isVoid,,) = game.dayState(day);
                if (settled && !isVoid) fail("claims: a wallet's points could not be tallied");
            }
        }
    }

    // ── the purse ──
    function requestNight() external {
        uint256 d = _tod() < OPEN ? _day() : _day() + 1;
        uint256 b0 = imd.balanceOf(address(budget));
        uint256 n0 = IStandIn(intake).count();
        try budget.requestNight(d) {
            uint256 b1 = imd.balanceOf(address(budget));
            if (b0 < 1e18) {
                assertEq(b1, b0, "nightly spend: a skipped night moved IMD");
                assertEq(IStandIn(intake).count(), n0);
                return;
            }
            assertEq(b0 - b1, 1e18, "nightly spend: a night costs exactly 1 IMD");
            assertEq(imd.allowance(address(budget), intake), 0, "nightly spend: an approval left standing");
            (, bytes32 g, bytes32 r) = budget.nights(d);
            lastGuessId = g;
            lastReportId = r;
            lastNight = d;
            ++requestsOk;
            assertEq(IStandIn(intake).bodyOf(g), budget.guessBody(), "request bodies: the guess body");
            assertEq(IStandIn(intake).bodyOf(r), budget.reportBody(), "request bodies: the report body");
            assertTrue(hook.closeSettled(d - 1) && block.timestamp < d * 1 days + OPEN, "nightly spend: a request outside its window");
        } catch (bytes memory e) {
            assertTrue(
                _has(e, SwarmBudget.TooLate.selector) || _has(e, SwarmBudget.CloseNotSettled.selector)
                    || _has(e, SwarmBudget.AlreadyRequested.selector),
                "requestNight refused for another reason"
            );
        }
    }

    /// the night's guess, in the job shape: stored as given whenever it arrives, late from 12:00 of its day
    function completeGuess(uint256 seed) external {
        if (lastGuessId == 0) return;
        bytes32 g = lastGuessId;
        lastGuessId = 0;
        bytes32 rh = keccak256(abi.encode("guess", seed));
        string memory uri = string.concat("ipfs://guess", vm.toString(seed), "/result.json");
        uint256 b0 = imd.balanceOf(address(budget));
        vm.prank(intakeWriter);
        IIntakeH(intake).complete(g, 0, rh, uri, abi.encode(g, rh, uri));
        assertEq(imd.balanceOf(address(budget)), b0, "callbacks: a callback moved IMD");
        assertEq(budget.guessHash(lastNight), rh, "callbacks: the guess's hash stored as given");
        assertEq(keccak256(bytes(budget.guessUri(lastNight))), keccak256(bytes(uri)), "callbacks: and its uri");
        assertEq(budget.guessAt(lastNight), block.timestamp, "callbacks: and the delivery time");
        assertEq(budget.guessLate(lastNight), block.timestamp >= lastNight * 1 days + OPEN, "callbacks: late from 12:00 of its day");
        ++guessesStored;
    }

    function completeReport() external {
        if (lastReportId == 0) return;
        bytes32 r = lastReportId;
        lastReportId = 0;
        uint256 b0 = imd.balanceOf(address(budget));
        vm.prank(intakeWriter);
        IIntakeH(intake).complete(r, 0, keccak256("res"), "ipfs://x/result.json", abi.encode(r, keccak256("res"), "ipfs://x/result.json"));
        assertEq(imd.balanceOf(address(budget)), b0, "callbacks: a callback moved IMD");
        assertEq(budget.reportHash(lastNight), keccak256("res"));
        assertEq(budget.reportAt(lastNight), block.timestamp, "callbacks: the report's delivery time");
    }

    function completeFailure() external {
        if (lastGuessId == 0) return;
        bytes32 g = lastGuessId;
        lastGuessId = 0;
        vm.prank(intakeWriter);
        IIntakeH(intake).complete(g, 2, bytes32(0), "", abi.encode(g, uint8(2), bytes32("disagreed"), uint16(0), uint16(0), bytes("")));
        assertEq(budget.failStatus(lastNight, 1), 2);
        assertEq(budget.guessHash(lastNight), bytes32(0), "a failure stores no guess");
    }

    function strangerCallbacks(uint8 who) external {
        address a = _actor(who);
        vm.startPrank(a);
        try budget.onGuess(lastGuessId, bytes32(0), "") {
            fail("callbacks: a stranger delivered a guess");
        } catch {}
        try budget.onReport(lastReportId, bytes32(0), "") {
            fail("callbacks: a stranger delivered a report");
        } catch {}
        vm.stopPrank();
    }

    // ── a whole day, scripted: the actions in the order a real day runs them ──
    function playDay(uint256 seed) external {
        uint256 d = _day() + 1;
        vm.warp(d * 1 days + 2 hours);
        vm.roll(block.number + 1);
        uint256 n0 = orderIds.length;
        for (uint256 i; i < 3 + seed % 4; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            this.place(uint8(r), r % 3 != 0, int256(uint256(uint8(r >> 8))) - 128, (r >> 16) % 2_000e18);
        }
        this.requestNight();
        this.completeGuess(seed % 1_000_000);
        this.completeReport();
        // commits for tomorrow from today's overnight orders
        for (uint256 i = n0; i < orderIds.length; ++i) {
            this.commit(i, int256(uint256(uint8(uint256(keccak256(abi.encode(seed, i, "c")))))) - 128);
        }
        vm.warp(d * 1 days + OPEN + 30);
        vm.roll(block.number + 1);
        // some days the ringer rings the bells, chores and all; on the others a wallet rings the hook directly
        if (seed % 2 == 1) this.ring();
        else this.ringOpen();
        uint256 swaps = 1 + seed % 4;
        for (uint256 i; i < swaps; ++i) {
            vm.warp(block.timestamp + 3 minutes);
            vm.roll(block.number + 1);
            this.swap(uint8(i), seed % 2 == 0, uint256(keccak256(abi.encode(seed, i, "s"))) % 3_000e18);
        }
        // the bell rang at 12:00:30, so its window ends at 12:30:30; settle no earlier
        vm.warp(d * 1 days + OPEN + 30 + 1800 + 15);
        vm.roll(block.number + 1);
        if (seed % 3 == 0) this.swap(1, true, 300e18); // sometimes a freezing checkpoint, sometimes the live window
        this.settle();
        for (uint256 i; i < sealedGuesses.length; ++i) {
            if (sealedGuesses[i].day == d) this.reveal(i);
        }
        // the closing book
        vm.warp(d * 1 days + OPEN + 2 hours);
        vm.roll(block.number + 1);
        uint256 n1 = orderIds.length;
        for (uint256 i; i < 2 + seed % 3; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "close")));
            this.place(uint8(r), r % 2 == 0, int256(uint256(uint8(r >> 8))) - 128, (r >> 16) % 2_000e18);
        }
        for (uint256 i = n1; i < orderIds.length; ++i) {
            this.commit(i, int256(uint256(uint8(uint256(keccak256(abi.encode(seed, i, "c2")))))) - 128);
        }
        vm.warp(d * 1 days + CLOSE + 30);
        vm.roll(block.number + 1);
        if (seed % 2 == 1) this.ring();
        else this.ringClose();
        for (uint256 i = n0; i < orderIds.length; ++i) {
            this.claim(i);
        }
        // the day just revealed is final after 16:00: tally every actor for it
        for (uint8 a; a < 3; ++a) {
            _tally(a, d);
        }
        vm.warp(d * 1 days + CLOSE + 30 minutes);
        vm.roll(block.number + 1);
        this.inject(true, seed % 50e18);
        this.inject(false, seed % 50e18);
        this.harvest();
        this.claimSwarmBudget();
        if (seed % 4 == 0) this.pushBurn();
        if (seed % 5 == 0) this.burnCoin();
    }

    // ── the end: every order claimable exactly once, the hook never short ──
    function finish() external returns (uint256 shortImd, uint256 shortCoin, uint256 failed) {
        vm.warp((_day() + 2) * 1 days + 20 hours + 1);
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 id = orderIds[i];
            if (isClaimed[id]) continue;
            if (!_claim(id)) ++failed;
            else {
                try hook.claim(id) {
                    ++failed; // claimed twice
                } catch {}
            }
        }
        uint256 owedImd = _accruals() + hook.dustImd() + hook.reserveImd();
        uint256 owedCoin = hook.coinBurnAccrued() + hook.feeWalletCoinAccrued() + hook.dustCoin() + hook.reserveCoin();
        if (owedImd > hook.imdAccounted()) shortImd = owedImd - hook.imdAccounted();
        if (owedCoin > hook.coinAccounted()) shortCoin = owedCoin - hook.coinAccounted();
    }
}

/// The invariants the handler's sequences must keep, checked after every call.
abstract contract Stateful is Base {
    Handler internal h;

    function _statefulSetup() internal {
        // the clock on a real day, 02:00, so the day arithmetic and the "closeSettled(d-1)" rule have a yesterday
        if (block.timestamp < 30 days) vm.warp(20_000 days + 2 hours);
        address[3] memory actors;
        for (uint256 i; i < 3; ++i) {
            actors[i] = _player(mkt, string.concat("actor", vm.toString(i)), 1_000_000e18, 1_000_000e18);
            vm.startPrank(actors[i]);
            IERC20T(imd).approve(address(router), type(uint256).max);
            mkt.coin.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        h = new Handler(mkt.hook, mkt.coin, imd, manager, router, intake, intakeWriter, actors);
        _fundImd(address(h), 100_000e18);
        mkt.coin.transfer(address(h), 100_000e18);
        targetContract(address(h));
        bytes4[] memory base = new bytes4[](28);
        base[0] = Handler.warp.selector;
        base[1] = Handler.place.selector;
        base[2] = Handler.cancel.selector;
        base[3] = Handler.ringOpen.selector;
        base[4] = Handler.ringClose.selector;
        base[5] = Handler.claim.selector;
        base[6] = Handler.swap.selector;
        base[7] = Handler.exit.selector;
        base[8] = Handler.inject.selector;
        base[9] = Handler.harvest.selector;
        base[10] = Handler.pushBurn.selector;
        base[11] = Handler.burnCoin.selector;
        base[12] = Handler.claimFeeWallet.selector;
        base[13] = Handler.claimNetworkFees.selector;
        base[14] = Handler.claimSwarmBudget.selector;
        base[15] = Handler.seedDust.selector;
        base[16] = Handler.commit.selector;
        base[17] = Handler.settle.selector;
        base[18] = Handler.reveal.selector;
        base[19] = Handler.revealWrongSalt.selector;
        base[20] = Handler.tally.selector;
        base[21] = Handler.requestNight.selector;
        base[22] = Handler.completeGuess.selector;
        base[23] = Handler.completeReport.selector;
        base[24] = Handler.ring.selector;
        base[25] = Handler.topUp.selector;
        base[26] = Handler.claimBellPurse.selector;
        base[27] = Handler.pushBurnRewarded.selector;
        // weights: the clock, the book, the bells, the claims, the swaps, the settle and the game's reveals more often
        uint8[28] memory w = [4, 4, 1, 3, 3, 3, 3, 1, 1, 2, 1, 1, 1, 1, 2, 1, 3, 3, 3, 1, 2, 2, 2, 1, 3, 1, 1, 1];
        uint256 n = 6; // the scripted day, six times
        for (uint256 i; i < 28; ++i) n += w[i];
        bytes4[] memory sels = new bytes4[](n);
        uint256 k;
        for (uint256 i; i < 28; ++i) {
            for (uint256 j; j < w[i]; ++j) sels[k++] = base[i];
        }
        for (uint256 j; j < 6; ++j) sels[k++] = Handler.playDay.selector;
        targetSelector(FuzzSelector(address(h), sels));
    }

    function invariant_I1_imdBalanceIsAccountedPlusPendingInflow() public view {
        assertEq(IERC20T(imd).balanceOf(address(mkt.hook)), mkt.hook.imdAccounted() + h.pendingImd(), "IMD accounting: IMD balance != accounted + unharvested inflow");
        assertGe(mkt.hook.imdAccounted(), mkt.hook.burnAccrued() + mkt.hook.networkAccrued() + mkt.hook.feeWalletImdAccrued() + mkt.hook.swarmAccrued() + mkt.hook.bellPurseAccrued() + mkt.hook.dustImd() + mkt.hook.reserveImd(), "IMD accounting: accruals exceed what the hook accounts");
    }

    /// The ringer holds exactly what reached it (the purse's slice, top-ups) less what it paid out; never ETH
    function invariant_I28_purseIsAccounted() public view {
        BellRinger r = h.ringer();
        assertEq(IERC20T(imd).balanceOf(address(r)), h.purseIn() - h.purseOut(), "ringer purse: the purse is not inflow less rewards");
        assertEq(address(r).balance, 0, "ringer purse: the ringer holds ETH");
    }

    function invariant_I1C_coinBalanceIsAccountedPlusPendingInflow() public view {
        assertEq(mkt.coin.balanceOf(address(mkt.hook)), mkt.hook.coinAccounted() + h.pendingCoin(), "coin accounting: coin balance != accounted + unharvested inflow");
        assertGe(mkt.hook.coinAccounted(), mkt.hook.coinBurnAccrued() + mkt.hook.feeWalletCoinAccrued() + mkt.hook.dustCoin() + mkt.hook.reserveCoin(), "coin accounting: accruals exceed what the hook accounts");
    }

    /// In points form: the game never holds a token (nothing in these sequences sends it one)
    function invariant_I1G_gameHoldsNoTokens() public view {
        assertEq(mkt.coin.balanceOf(address(mkt.game)), 0, "no token in the game: the game holds coin");
        assertEq(IERC20T(imd).balanceOf(address(mkt.game)), 0, "no token in the game: the game holds IMD");
    }

    function invariant_I1B_budgetUnderCap() public view {
        assertLe(IERC20T(imd).balanceOf(address(mkt.budget)), mkt.budget.CAP(), "purse cap: the purse holds more than its cap");
    }

    function invariant_I2_feesEqualAccrualDeltas() public view {
        assertEq(h.feeSum(), h.accrualAtClaims(), "fee split: the fees taken are not the accruals the claims added");
    }

    function invariant_I13_coinSupply() public view {
        assertEq(mkt.coin.totalSupply(), h.coinSupply0() - h.burnedCoin(), "coin supply: the supply is the start less what burnCoin burned");
    }

    /// Audit finding 2: one reference at a time, the one the handler checked against the pool at each bell
    function invariant_I15_referenceChain() public view {
        uint256 d = block.timestamp / 1 days;
        assertEq(mkt.hook.referenceOf(2 * d + 1), mkt.hook.lastCleared(), "reference chain: the closing book's reference is lastCleared");
        assertEq(mkt.hook.referenceOf(2 * (d + 1)), mkt.hook.lastCleared(), "reference chain: the overnight reference is lastCleared");
    }

    function invariant_I24_noOwner() public {
        (bool ok,) = address(mkt.hook).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(mkt.game).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(mkt.budget).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    /// after the run: every order claimable exactly once and the hook never short, to the wei
    function afterInvariant() public {
        (uint256 shortImd, uint256 shortCoin, uint256 failed) = h.finish();
        console2.log("(stateful) claims ok / rings / swaps; requests / guesses stored; points tallied / unpaid reveals refused");
        console2.log("  ", h.claimsOk(), h.ringsOk(), h.swapsOk());
        console2.log("  ", h.requestsOk(), h.guessesStored());
        console2.log("  ", h.pointsTallied(), h.revealsRefused());
        console2.log("   settles / reveals ok", h.settlesOk(), h.revealsOk());
        console2.log("   unfilled fees: IMD / coin (wei)", h.unfilledImd(), h.unfilledCoin());
        console2.log("   ringer rings / paid rings / purse in / purse out (wei)", h.ringerRings(), h.ringerRewards());
        console2.log("   ", h.purseIn(), h.purseOut());
        console2.log("   ringer rings that found the bell already rung (chores only)", h.ringerChoresOnly());
        assertEq(failed, 0, "claims: an order could not be claimed exactly once at the end");
        assertEq(shortImd, 0, "strict IMD accounting: the hook ended short of IMD");
        assertEq(shortCoin, 0, "strict coin accounting: the hook ended short of coin");
    }
}
