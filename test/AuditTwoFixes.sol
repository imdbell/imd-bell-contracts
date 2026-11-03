// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {BellGame} from "../src/BellGame.sol";
import {Base, IERC20T} from "./Base.sol";
import {MsgSenderRouter} from "./MsgSenderRouter.sol";
import {WordRouter} from "./WordRouter.sol";

/// The design rules behind audit 2's fixes, beyond the audit's own reproduction tests (test/audit-two).
abstract contract AuditTwoFixes is Base {
    // ── the round-trip key: the router's reported identity, else the signer ──
    function _rtSetUp(Mkt memory m, address router_, string memory la, string memory lb) internal returns (address a, address b) {
        a = _player(m, la, 100e18, 100e18);
        b = _player(m, lb, 100e18, 100e18);
        address[2] memory w = [a, b];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(w[i]);
            IERC20T(imd).approve(router_, type(uint256).max);
            m.coin.approve(router_, type(uint256).max);
            vm.stopPrank();
        }
        _fundImd(address(this), 100_000e18);
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(-12_000, 0, 1e23, 0), "");
        _at(D, OPEN);
        m.hook.ringOpen();
        _nextBlock();
    }

    function _p(bool zfo) internal pure returns (IPoolManager.SwapParams memory) {
        return zfo
            ? IPoolManager.SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1)
            : IPoolManager.SwapParams(false, -1e18, TickMath.MAX_SQRT_PRICE - 1);
    }

    function _word(Mkt memory m, WordRouter r, address who, address origin, uint256 w, bool zfo)
        internal
        returns (bool ok, bytes memory e)
    {
        vm.prank(who, origin);
        (ok, e) = address(r).call(abi.encodeCall(WordRouter.swapAnswering, (w, m.key, _p(zfo))));
    }

    /// One account through a reporting router, from two different signers (two bundlers): still one direction a block,
    /// because the key is the account the router reports, not the signer.
    function test_I_reportedIdentityKeysTheGuardWhateverTheSigner() public {
        Mkt memory m = mkt;
        MsgSenderRouter r = new MsgSenderRouter(manager);
        (address a,) = _rtSetUp(m, address(r), "account", "unused");
        vm.prank(a, makeAddr("bundler 1"));
        r.swap(m.key, _p(true));
        vm.prank(a, makeAddr("bundler 2"));
        (bool ok, bytes memory e) = address(r).call(abi.encodeCall(MsgSenderRouter.swap, (m.key, _p(false))));
        assertFalse(ok, "the reported account's round trip in one block");
        assertTrue(_has(e, MarketHoursHook.RoundTrip.selector), "refused by the round-trip rule");
    }

    /// A router that reports nothing (PoolSwapTest has no msgSender()): the key is the signer. Two signers are apart;
    /// one signer's round trip is refused; two accounts behind one signer share its direction, by design.
    function test_I_silentRouterKeysOnTheSigner() public {
        Mkt memory m = mkt;
        (address a, address b) = _rtSetUp(m, address(router), "a", "b");
        vm.prank(a, a);
        router.swap(m.key, _p(true), PoolSwapTest.TestSettings(false, false), "");
        vm.prank(b, b);
        router.swap(m.key, _p(false), PoolSwapTest.TestSettings(false, false), "");
        _nextBlock();
        address bundler = makeAddr("bundler");
        vm.prank(a, bundler);
        router.swap(m.key, _p(true), PoolSwapTest.TestSettings(false, false), "");
        vm.prank(b, bundler);
        (bool ok, bytes memory e) = address(router).call(
            abi.encodeCall(PoolSwapTest.swap, (m.key, _p(false), PoolSwapTest.TestSettings(false, false), bytes("")))
        );
        assertFalse(ok, "behind one signer, a silent router's users share its direction");
        assertTrue(_has(e, MarketHoursHook.RoundTrip.selector), "refused by the round-trip rule");
    }

    /// Answers that are no identity fall back to the signer: zero (a router at rest), and a word with bits above the
    /// address. Two signers through such a router are apart; one signer's round trip is refused.
    function test_I_zeroOrNonAddressAnswerIsNoIdentity() public {
        Mkt memory m = mkt;
        WordRouter r = new WordRouter(manager);
        (address a, address b) = _rtSetUp(m, address(r), "a", "b");
        uint256[2] memory words = [uint256(0), (uint256(1) << 160) | uint160(makeAddr("x"))];
        for (uint256 i; i < 2; ++i) {
            _nextBlock();
            (bool ok1, bytes memory e1) = _word(m, r, a, a, words[i], true);
            assertTrue(ok1, string.concat("a's sell: ", vm.toString(e1)));
            (bool ok2, bytes memory e2) = _word(m, r, b, b, words[i], false);
            assertTrue(ok2, string.concat("b's buy, its own signer: ", vm.toString(e2)));
            (bool ok3, bytes memory e3) = _word(m, r, a, a, words[i], false);
            assertFalse(ok3, "a's round trip, keyed on its signer");
            assertTrue(_has(e3, MarketHoursHook.RoundTrip.selector), "refused by the round-trip rule");
        }
    }

    /// The same router answering two different addresses keeps them apart even from one signer.
    function test_I_twoReportedAccountsOneSignerApart() public {
        Mkt memory m = mkt;
        WordRouter r = new WordRouter(manager);
        (address a, address b) = _rtSetUp(m, address(r), "a", "b");
        address bundler = makeAddr("bundler");
        (bool ok1, bytes memory e1) = _word(m, r, a, bundler, uint160(a), true);
        assertTrue(ok1, vm.toString(e1));
        (bool ok2, bytes memory e2) = _word(m, r, b, bundler, uint160(b), false);
        assertTrue(ok2, string.concat("b reported apart from a: ", vm.toString(e2)));
        console2.log("(I) two reported accounts behind one signer, one block: apart");
    }

    // ── the cap's weight: a marketable order in full, a passive one by its distance, 1 % at the band's edge ──
    function _counted(Mkt memory m, uint256 s, bool buy, int24 bucket, uint256 amount) internal returns (uint256) {
        uint256 t0 = m.hook.bookImdTotal(s);
        _order(m, s, buy, bucket, amount);
        return m.hook.bookImdTotal(s) - t0;
    }

    function test_I_marketableOrdersCountInFull() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        assertEq(m.hook.referenceOf(2 * D), 0, "precondition: the reference is 0, a coin worth one IMD there");
        int24[4] memory off = [int24(0), 60, 6_000, 12_000];
        for (uint256 i; i < 4; ++i) {
            assertEq(_counted(m, 2 * D, true, off[i], 10e18), 10e18, "a buy at or above the reference counts in full");
            assertEq(_counted(m, 2 * D, false, -off[i], 10e18), 10e18, "a sell at or below the reference counts in full");
        }
    }

    function test_I_passiveWeightFallsLinearlyToOnePercent() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256[5] memory k = [uint256(1), 2, 100, 199, 200];
        for (uint256 i; i < 5; ++i) {
            uint256 d = 60 * k[i];
            uint256 want = 10e18 * (1_200_000 - 99 * d) / 1_200_000;
            assertEq(_counted(m, 2 * D, true, -int24(int256(d)), 10e18), want, "a buy below the reference, by distance");
            assertEq(_counted(m, 2 * D, false, int24(int256(d)), 10e18), want, "a sell above the reference, by distance");
        }
        assertEq(_counted(m, 2 * D, true, -12_000, 10e18), 0.1e18, "1 % at the band's edge");
        console2.log("(I) passive weight one bucket out / half way / edge, of 10 IMD", _counted(m, 2 * D, true, -60, 10e18), _counted(m, 2 * D, true, -6_000, 10e18));
    }

    /// What blocking a book costs under the one-sided weight, in launch week and at the cap's top: the escrow whose
    /// count is exactly the cap, three ways, the refusal of a victim's order after it, and the cancel fee at 10:49.
    /// The holder's cheapest is the order nearest the reference: marketable at it (which can trade) or one bucket
    /// passive (which cannot unless P* falls a bucket).
    function test_I_measure_blockCostUnderTheOneSidedWeight() public {
        Mkt memory m = mkt;
        uint256 d0 = m.hook.d0();
        uint256[2] memory week = [uint256(0), 7];
        int24[3] memory bucket = [int24(-12_000), -60, 0];
        string[3] memory label = ["passive at the band's edge", "passive one bucket off", "marketable at the reference"];
        for (uint256 w; w < 2; ++w) {
            uint256 day = d0 + 7 * week[w] + 1;
            vm.warp(day * 1 days + 1 hours);
            uint256 cap = m.hook.depositCap();
            uint256 snap = vm.snapshotState();
            for (uint256 j; j < 3; ++j) {
                vm.revertToState(snap);
                uint256 wt = bucket[j] < 0 ? 1_200_000 - 99 * uint256(int256(-bucket[j])) : 1_200_000;
                uint256 esc = (cap * 1_200_000 + wt - 1) / wt;
                address g = _player(m, string.concat("holder", vm.toString(j)), esc, 0);
                uint256 id = _orderAs(m, g, 2 * day, true, bucket[j], esc);
                assertEq(m.hook.bookImdTotal(2 * day), cap, "precondition: the holder's order counts exactly the cap");
                address v = _player(m, string.concat("victim", vm.toString(j)), 10e18, 10e18);
                vm.prank(v);
                (bool ok, bytes memory e) = address(m.hook).call(abi.encodeCall(MarketHoursHook.placeOrder, (2 * day, false, int24(0), 1e18)));
                assertFalse(ok, "the held book refuses the victim's sell");
                assertTrue(_has(e, MarketHoursHook.BookFull.selector), "with BookFull");
                vm.warp(day * 1 days + OPEN - FREEZE_T - NO_CANCEL_T - 60);
                uint256 b0 = IERC20T(imd).balanceOf(g);
                vm.prank(g);
                m.hook.cancelOrder(id);
                uint256 cost = esc - (IERC20T(imd).balanceOf(g) - b0);
                console2.log(string.concat("(I) week ", vm.toString(week[w]), ", cap (IMD) ", vm.toString(cap / 1e18), ": ", label[j]));
                console2.log("    escrow / cancel fee (wei IMD)", esc, cost);
            }
        }
    }

    // ── the ticket: at least 5 IMD at the book's reference, kept through a bell that rang ──
    /// A sell is valued at its book's reference when placed, not at P*: 5 coin at the reference 0 (5 IMD) sold where
    /// the bell clears 600 ticks lower (worth about 4.7 IMD there) earns its ticket; 4.99 coin does not.
    function test_I_ticketMinimumValuedAtTheReference() public {
        Mkt memory m = mkt;
        address se = _player(m, "seller", 0, 100e18);
        address se2 = _player(m, "seller 2", 0, 100e18);
        address bu = _player(m, "buyer", 1_000e18, 0);
        _at(D, 1 hours);
        uint256 s5 = _orderAs(m, se, 2 * D, false, -600, 5e18);
        uint256 s499 = _orderAs(m, se2, 2 * D, false, -600, 4.99e18);
        _orderAs(m, bu, 2 * D, true, -600, 100e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p,,,,,) = m.hook.bells(2 * D);
        assertEq(p, -600, "precondition: the bell cleared 600 ticks under the reference");
        assertTrue(m.hook.ticketPaid(s5), "5 coin worth 5 IMD at the reference: a ticket");
        assertFalse(m.hook.ticketPaid(s499), "4.99 coin: no ticket");
    }

    /// One guess a wallet a day, whichever of its books: orders in the opening and the closing book of day D both
    /// guess D + 1, so the second commit is refused; the next day's book guesses D + 2 and is taken.
    function test_I_oneGuessAcrossBothBooksOfADay() public {
        Mkt memory m = mkt;
        address a = _player(m, "a", 1_000e18, 1_000e18);
        bytes32 salt = keccak256("s");
        _at(D, 1 hours);
        uint256 o1 = _orderAs(m, a, 2 * D, true, 0, 10e18);
        vm.prank(a);
        m.game.commit(o1, _commitOf(_guessOf(0), salt, a, D + 1));
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, OPEN + 10 minutes);
        uint256 o2 = _orderAs(m, a, 2 * D + 1, true, m.hook.referenceOf(2 * D + 1), 10e18);
        vm.prank(a);
        vm.expectRevert(BellGame.OneGuessPerDay.selector);
        m.game.commit(o2, _commitOf(_guessOf(60), salt, a, D + 1));
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        _at(D, 17 hours);
        uint256 o3 = _orderAs(m, a, 2 * (D + 1), true, m.hook.referenceOf(2 * (D + 1)), 10e18);
        vm.prank(a);
        m.game.commit(o3, _commitOf(_guessOf(0), salt, a, D + 2));
        assertTrue(m.game.ticketUsed(o3), "the next day's guess is taken");
        assertFalse(m.game.ticketUsed(o2), "the refused commit used nothing");
    }

    /// An order under the ticket's minimum still trades normally: it is filled and paid; it just earns no ticket.
    function test_I_orderUnderTheTicketMinimumStillTrades() public {
        Mkt memory m = mkt;
        address bu = _player(m, "buyer", 10e18, 0);
        address se = _player(m, "seller", 0, 10e18);
        _at(D, 1 hours);
        uint256 b = _orderAs(m, bu, 2 * D, true, 0, 1e18);
        _orderAs(m, se, 2 * D, false, 0, 5e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        uint256 c0 = m.coin.balanceOf(bu);
        vm.prank(bu);
        m.hook.claim(b);
        assertGt(m.coin.balanceOf(bu) - c0, 0.98e18, "the 1 IMD buy filled whole at the bell");
        assertFalse(m.hook.ticketPaid(b), "and earned no ticket");
    }
}
