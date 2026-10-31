// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {BellGame} from "../src/BellGame.sol";
import {Invariants} from "./Invariants.sol";
import {IERC20T} from "./Base.sol";

/// Guess the Bell: tickets and what pays for them, sealing, the settled open, the ranks and the points. The game pays
/// points, never money, and holds no tokens.
abstract contract Game is Invariants {
    /// Day `d`: `n` blocks each with one external buy of `size` IMD at `tod0 + i minutes`, from the bell.
    function _session(Mkt memory m, uint256 d, uint256 n, uint256 size, uint256 tod0) internal {
        for (uint256 i; i < n; ++i) {
            _nextBlock();
            _at(d, tod0 + 60 * (i + 1));
            _swap(m, true, size);
        }
    }

    function _scoredOf(Mkt memory m, uint256 day) internal view returns (int24 sc) {
        (,,, sc) = m.game.dayState(day);
    }

    function _gameHoldsNothing(Mkt memory m, string memory when) internal view {
        assertEq(IERC20T(imd).balanceOf(address(m.game)), 0, string.concat("the game holds no IMD ", when));
        assertEq(m.coin.balanceOf(address(m.game)), 0, string.concat("the game holds no coin ", when));
    }

    /// Book 2D: `n` players each with a 10 IMD buy at bucket 60 (a ticket for D+1) and the trader's 100-coin sell at
    /// -60, so every buy fills whole when D's open rings. Returns the players and their order ids.
    function _paidTickets(Mkt memory m, uint256 n, string memory tag)
        internal
        returns (address[] memory p, uint256[] memory ids)
    {
        p = new address[](n);
        ids = new uint256[](n);
        _at(D, 1 hours);
        for (uint256 i; i < n; ++i) {
            p[i] = _player(m, string.concat(tag, vm.toString(i)), 1_000e18, 0);
            ids[i] = _orderAs(m, p[i], 2 * D, true, 60, 10e18);
        }
        _order(m, 2 * D, false, -60, 100e18);
    }

    // ── the whole game on two days: tickets on D, the bell and the settle on D+1, points after 16:00 ──
    function test_G_wholeGame() public {
        Mkt memory m = mkt;
        (address[] memory p, uint256[] memory ids) = _paidTickets(m, 4, "player");
        _gameHoldsNothing(m, "at the start");
        // D's bells: the open fills every ticket order
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        for (uint256 i; i < 4; ++i) {
            assertTrue(m.hook.ticketPaid(ids[i]), "a filled order of 10 IMD paid for its ticket");
        }
        // commits for D+1 before 16:00 of D
        int24[4] memory guessB = [int24(60), 120, 0, 300];
        bytes32[4] memory salt;
        for (uint256 i; i < 4; ++i) {
            salt[i] = keccak256(abi.encode("salt", i));
            vm.prank(p[i]);
            m.game.commit(ids[i], _commitOf(_guessOf(guessB[i]), salt[i], p[i], D + 1));
        }
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();

        // D+1: the bell, three swaps inside the window, then the freezing one at 12:31
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        int256 sum;
        for (uint256 i; i < 3; ++i) {
            _nextBlock();
            _at(D + 1, OPEN + 5 minutes * (i + 1));
            sum += _tick(m);
            _swap(m, true, 500e18);
        }
        (int256 ts, uint256 tc, uint256 openedAt, bool frozen) = m.hook.sessionMean();
        assertEq(tc, 3, "three in-window checkpoints");
        assertEq(ts, sum, "tickSum of the three");
        assertEq(openedAt, (D + 1) * 1 days + OPEN, "the window opens at the bell's own time");
        assertFalse(frozen, "not frozen before a checkpoint at or after the window's end");
        _nextBlock();
        _at(D + 1, OPEN + WINDOW_T + 60);
        _swap(m, true, 500e18);
        (int256 ts2, uint256 tc2,, bool frozen2) = m.hook.sessionMean();
        assertTrue(frozen2, "frozen by the first checkpoint at or after the window's end");
        assertEq(tc2, 3, "settle window: the window's count is frozen; the 12:31 checkpoint is outside it");
        assertEq(ts2, sum, "settle window: the window's sum is frozen");
        _session(m, D + 1, 2, 500e18, OPEN + WINDOW_T + 120);
        (int256 ts3, uint256 tc3,,) = m.hook.sessionMean();
        assertEq(tc3, 3, "settle window: later swaps do not change the frozen window");
        assertEq(ts3, sum, "settle window: later swaps do not change the frozen window (sum)");
        (int48 liveSum, uint16 liveCount) = _counters(m);
        assertEq(liveCount, 6, "the live counters kept running for the zero-match reference");
        assertTrue(int256(liveSum) != sum, "the live sum moved on");

        // settle at 13:00: the frozen window, not the live counters
        _at(D + 1, 13 hours);
        m.game.settle(D + 1);
        (bool settled, bool isVoid, bool fromMean, int24 scored) = m.game.dayState(D + 1);
        assertTrue(settled && !isVoid && fromMean, "settled from the mean");
        assertEq(scored, _nearest(sum / 3), "settle window: scored = the bucket nearest the frozen window's mean");
        (int256 ts4, uint256 tc4,,) = m.hook.sessionMean();
        assertEq(tc4, 3, "settle window: settle never changes the hook's counters");
        assertEq(ts4, sum, "settle window: settle never changes the hook's counters (sum)");
        console2.log("(G) scored bucket", int256(scored));

        // reveals: distances from the scored bucket
        uint256[4] memory dist;
        for (uint256 i; i < 4; ++i) {
            int256 diff = int256(guessB[i]) - int256(scored);
            dist[i] = uint256(diff < 0 ? -diff : diff) / 60;
            vm.prank(p[i]);
            m.game.reveal(ids[i], _guessOf(guessB[i]), salt[i]);
        }
        // before 16:00 the ranks are not final and nothing can be tallied
        (bool fin0,,,,,) = m.game.finalRanks(D + 1);
        assertFalse(fin0, "not final before the reveal window closes");
        vm.expectRevert(BellGame.NotFinal.selector);
        m.game.tally(D + 1, p[0]);
        _at(D + 1, CLOSE);
        (bool fin, int24 sc, uint32[3] memory rd, uint32[3] memory rc, uint256[3] memory rp, address[][3] memory rw) =
            m.game.finalRanks(D + 1);
        assertTrue(fin, "final once the reveal window closed");
        assertEq(sc, scored, "the final ranks carry the scored bucket");
        uint256 seen;
        for (uint256 k; k < 3; ++k) {
            assertEq(rw[k].length, rc[k], "each slot lists exactly its wallets");
            for (uint256 j; j < rw[k].length; ++j) {
                assertEq(m.game.pointsOf(D + 1, rw[k][j]), rp[k], "a listed wallet scores its slot's points");
                assertEq(m.game.distOf(D + 1, rw[k][j]), rd[k], "a listed wallet is at its slot's distance");
                ++seen;
            }
        }
        assertGe(seen, 3, "at least three wallets hold a slot");
        // every wallet's points follow the rule written out independently; tally adds them once
        uint256 totalPts;
        for (uint256 i; i < 4; ++i) {
            uint256 want = _expectedPoints(dist, i);
            assertEq(m.game.pointsOf(D + 1, p[i]), want, "the wallet's points follow 3 / 2 / 1, ties take the higher place");
            if (want == 0) {
                vm.expectRevert(BellGame.NoPoints.selector);
                m.game.tally(D + 1, p[i]);
            } else {
                m.game.tally(D + 1, p[i]);
                assertEq(m.game.points(p[i]), want, "the running total holds the day's points");
                vm.expectRevert(BellGame.AlreadyTallied.selector);
                m.game.tally(D + 1, p[i]);
                totalPts += want;
            }
        }
        assertGe(totalPts, 6, "the day handed out at least 3 + 2 + 1 points");
        _gameHoldsNothing(m, "after the whole day");
    }

    /// the rule, written out independently: the wallets strictly closer than `i` fill places 0.. closer-1; `i` and its
    /// ties take place `closer`, which scores 3 / 2 / 1 for places 0 / 1 / 2 and nothing after; only the three best
    /// distinct distances are ranked at all
    function _expectedPoints(uint256[4] memory dist, uint256 i) internal pure returns (uint256) {
        uint256 closer;
        uint256 distinctCloser;
        for (uint256 j; j < 4; ++j) {
            if (dist[j] < dist[i]) {
                ++closer;
                bool seenBefore;
                for (uint256 k; k < j; ++k) {
                    if (dist[k] == dist[j]) seenBefore = true;
                }
                if (!seenBefore) ++distinctCloser;
            }
        }
        if (distinctCloser >= 3 || closer >= 3) return 0;
        return 3 - closer;
    }

    // ── sealing ──
    function test_I19_sealed() public {
        Mkt memory m = mkt;
        address a = _player(m, "a", 1_000e18, 1_000e18);
        _at(D, 1 hours);
        uint256 id1 = _orderAs(m, a, 2 * D, true, 60, 10e18);
        uint256 id2 = _orderAs(m, a, 2 * D, true, 60, 10e18);
        _order(m, 2 * D, false, -60, 100e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        bytes32 salt = keccak256("s");
        // a commit at 16:00:00 of D is refused; at 15:59:59 it is taken
        _at(D, CLOSE);
        vm.prank(a);
        vm.expectRevert(BellGame.CommitsClosed.selector);
        m.game.commit(id1, _commitOf(_guessOf(0), salt, a, D + 1));
        _at(D, CLOSE - 1);
        vm.prank(a);
        m.game.commit(id1, _commitOf(_guessOf(0), salt, a, D + 1));
        vm.prank(a);
        m.game.commit(id2, _commitOf(_guessOf(60), salt, a, D + 1));
        // one ticket per order
        vm.prank(a);
        vm.expectRevert(BellGame.TicketUsed.selector);
        m.game.commit(id1, _commitOf(_guessOf(0), salt, a, D + 1));
        // somebody else's order is not a ticket
        address b = _player(m, "b", 1_000e18, 0);
        vm.prank(b);
        vm.expectRevert(BellGame.NotYourOrder.selector);
        m.game.commit(id2, _commitOf(_guessOf(0), salt, b, D + 1));
        // no reveal before the settle; no Scored event can precede the bell
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        vm.prank(a);
        vm.expectRevert(BellGame.NotSettled.selector);
        m.game.reveal(id1, _guessOf(0), salt);
        _at(D + 1, OPEN + WINDOW_T);
        m.game.settle(D + 1);
        // a wrong salt changes nothing
        vm.prank(a);
        vm.expectRevert(BellGame.BadReveal.selector);
        m.game.reveal(id1, _guessOf(0), keccak256("wrong"));
        (, uint32 c0) = m.game.rankOf(D + 1, 0);
        assertEq(c0, 0, "sealing: nothing ranked after a bad reveal");
        // a wrong guess changes nothing
        vm.prank(a);
        vm.expectRevert(BellGame.BadReveal.selector);
        m.game.reveal(id1, _guessOf(60), salt);
        // the right reveal ranks; a second reveal by the same wallet the same day is refused
        vm.prank(a);
        m.game.reveal(id1, _guessOf(0), salt);
        (, uint32 c1) = m.game.rankOf(D + 1, 0);
        assertEq(c1, 1, "the wallet ranks once");
        vm.prank(a);
        vm.expectRevert(BellGame.AlreadyRevealed.selector);
        m.game.reveal(id2, _guessOf(60), salt);
        (, uint32 c2) = m.game.rankOf(D + 1, 1);
        assertEq(c2, 0, "a wallet never ranks twice");
        // reveals close at 16:00
        _at(D + 1, CLOSE);
        vm.prank(a);
        vm.expectRevert(BellGame.RevealClosed.selector);
        m.game.reveal(id2, _guessOf(60), salt);
    }

    // ── the settle time cannot change the scored price; only beforeSwap checkpoints contribute ──
    function test_I20_settleTimeCannotChangeScored() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        int256 sum;
        for (uint256 i; i < 4; ++i) {
            _nextBlock();
            _at(D, OPEN + 4 minutes * (i + 1));
            sum += _tick(m);
            _swap(m, true, 800e18);
        }
        uint256 snap = vm.snapshotState();
        // settle at the window's end sharp, no freezing checkpoint yet: the live counters are exactly the window's
        _at(D, OPEN + WINDOW_T);
        m.game.settle(D);
        int24 sEarly = _scoredOf(m, D);
        vm.revertToState(snap);
        // swaps after the window freeze it first; a settle at 15:00 reads the same figures
        _nextBlock();
        _at(D, OPEN + WINDOW_T + 30);
        _swap(m, true, 800e18);
        _session(m, D, 5, 800e18, 13 hours);
        _at(D, 15 hours);
        m.game.settle(D);
        int24 sLate = _scoredOf(m, D);
        assertEq(sLate, _nearest(sum / 4), "settle window: scored from the frozen window");
        assertEq(sEarly, sLate, "settle window: the time of the settle call cannot change the scored price");
        // the emergency exit's own swap never feeds the window: an exit the next night, then a day with no swaps
        vm.revertToState(snap);
        _at(D, CLOSE);
        m.hook.ringClose();
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        (, uint256 tc,,) = m.hook.sessionMean();
        assertEq(tc, 0, "no checkpoints in a session with no external swap");
        _at(D + 1, OPEN + WINDOW_T);
        m.game.settle(D + 1);
        (int24 pStar,,,,,) = m.hook.bells(2 * (D + 1));
        (,, bool fromMean, int24 sc) = m.game.dayState(D + 1);
        assertFalse(fromMean, "no checkpoint: the bell price");
        assertEq(sc, pStar, "settle window: with no checkpoint in the window the scored price is the bell's P*");
    }

    // ── settle: not before the window has ended, counted from the bell's own time ──
    function test_G_settleNotBeforeTheWindowEnds() public {
        Mkt memory m = mkt;
        uint256 snap = vm.snapshotState();
        // a bell at 12:00: the window ends 12:30
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, OPEN + WINDOW_T - 1);
        vm.expectRevert(BellGame.TooEarly.selector);
        m.game.settle(D);
        _at(D, OPEN + WINDOW_T);
        m.game.settle(D);
        (bool settled,,,) = m.game.dayState(D);
        assertTrue(settled, "settled at 12:30:00 after a 12:00 bell");
        // a bell at 12:10: 12:30 is too early, the window ends 12:40
        vm.revertToState(snap);
        _at(D, OPEN + 10 minutes);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, OPEN + WINDOW_T);
        vm.expectRevert(BellGame.TooEarly.selector);
        m.game.settle(D);
        _at(D, OPEN + 10 minutes + WINDOW_T - 1);
        vm.expectRevert(BellGame.TooEarly.selector);
        m.game.settle(D);
        _at(D, OPEN + 10 minutes + WINDOW_T);
        m.game.settle(D);
        (settled,,,) = m.game.dayState(D);
        assertTrue(settled, "settled at 12:40:00 after a 12:10 bell");
    }

    // ── the void day: no opening bell ──
    function test_G_voidDay() public {
        Mkt memory m = mkt;
        address a = _player(m, "a", 1_000e18, 1_000e18);
        _at(D, 1 hours);
        uint256 id = _orderAs(m, a, 2 * D, true, 0, 10e18);
        bytes32 salt = keccak256("s");
        vm.prank(a);
        m.game.commit(id, _commitOf(_guessOf(0), salt, a, D + 1));
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D, CLOSE);
        m.hook.ringClose();
        // D+1: nobody rings the open; settle at 12:30 is too early to call the day void, at 16:00 it is void
        _at(D + 1, OPEN + WINDOW_T);
        vm.expectRevert(BellGame.TooEarly.selector);
        m.game.settle(D + 1);
        _at(D + 1, CLOSE);
        m.game.settle(D + 1);
        (bool settled, bool isVoid,,) = m.game.dayState(D + 1);
        assertTrue(settled && isVoid, "the day is void");
        vm.prank(a);
        vm.expectRevert(BellGame.NotSettled.selector);
        m.game.reveal(id, _guessOf(0), salt);
        (bool fin,,,,,) = m.game.finalRanks(D + 1);
        assertFalse(fin, "a void day has no final ranks");
        vm.expectRevert(BellGame.NotFinal.selector);
        m.game.tally(D + 1, a);
        _gameHoldsNothing(m, "on a void day");
    }

    // ── ties: every tied wallet scores the highest place the tie covers ──
    /// the day's bell and a session, then the settle once the window has ended: returns the scored bucket
    function _dayWithSession(Mkt memory m, uint256 d) internal returns (int24) {
        _at(d, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _session(m, d, 3, 500e18, OPEN);
        _at(d, OPEN + WINDOW_T);
        m.game.settle(d);
        return _scoredOf(m, d);
    }

    function test_G_tiesScoreTheHigherPlace() public {
        Mkt memory m = mkt;
        (address[] memory p, uint256[] memory ids) = _paidTickets(m, 5, "t");
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        // a dry run of D+1 says where the open settles, so the guesses can be placed around it; the commits are then
        // made back on D (the state is rewound), before 16:00 as the rule requires
        uint256 snap = vm.snapshotState();
        int24 sc = _dayWithSession(m, D + 1);
        vm.revertToState(snap);
        _at(D, 15 hours);
        bytes32 salt = keccak256("s");
        // two tied closest, two tied one bucket out, one two buckets out
        int24[5] memory g = [sc, sc, sc + 60, sc - 60, sc + 120];
        for (uint256 i; i < 5; ++i) {
            vm.prank(p[i]);
            m.game.commit(ids[i], _commitOf(_guessOf(g[i]), salt, p[i], D + 1));
        }
        assertEq(_dayWithSession(m, D + 1), sc, "the day settles where the dry run did");
        for (uint256 i; i < 5; ++i) {
            vm.prank(p[i]);
            m.game.reveal(ids[i], _guessOf(g[i]), salt);
        }
        (uint32 d0, uint32 c0) = m.game.rankOf(D + 1, 0);
        (uint32 d1, uint32 c1) = m.game.rankOf(D + 1, 1);
        (uint32 d2, uint32 c2) = m.game.rankOf(D + 1, 2);
        assertEq(d0, 0);
        assertEq(c0, 2, "two wallets tied at the first place");
        assertEq(d1, 1);
        assertEq(c1, 2, "two wallets tied at the third place");
        assertEq(d2, 2);
        assertEq(c2, 1);
        _at(D + 1, CLOSE);
        uint256[5] memory want = [uint256(3), 3, 1, 1, 0];
        for (uint256 i; i < 5; ++i) {
            assertEq(m.game.pointsOf(D + 1, p[i]), want[i], "tied wallets each score the highest place their tie covers");
            if (want[i] > 0) m.game.tally(D + 1, p[i]);
            assertEq(m.game.points(p[i]), want[i], "the running total");
        }
        (,,,, uint256[3] memory rp, address[][3] memory rw) = m.game.finalRanks(D + 1);
        assertEq(rp[0], 3);
        assertEq(rp[1], 1, "the slot after a two-way tie for first starts at the third place");
        assertEq(rp[2], 0, "a slot starting past the third place scores nothing");
        assertEq(rw[0].length, 2);
        assertEq(rw[1].length, 2);
        assertEq(rw[2].length, 1);
        _gameHoldsNothing(m, "after the tallies");
    }

    // ── what pays for a ticket ──
    /// A ticket ranks only if its order paid for it. Five orders, five answers: a fill of at least 0.5 IMD (paid); a
    /// cancel (paid, the cancel fee); a bucket the bell did not reach (paid, the unfilled-order fee at claim, whether or
    /// not it has been claimed yet); a fill below 0.5 IMD with no fee (unpaid); an order of a bell that never rang,
    /// refunded whole (unpaid). An unpaid ticket's reveal is refused and changes nothing.
    function test_G_ticketPaidRule() public {
        Mkt memory m = mkt;
        address a = _player(m, "a", 1_000e18, 1_000e18);
        _at(D, 1 hours);
        uint256 filled = _orderAs(m, a, 2 * D, true, 60, 10e18);
        uint256 cancelled = _orderAs(m, a, 2 * D, true, -600, 1e18);
        uint256 notReached = _orderAs(m, a, 2 * D, true, -1200, 1e18);
        vm.prank(a);
        m.hook.cancelOrder(cancelled);
        // the only sell: 10.3 coin at -60, so the buy at 60 fills about 10 IMD and P* = -60
        _order(m, 2 * D, false, -60, 10.3e18);
        assertFalse(m.hook.ticketPaid(filled), "before the bell nothing has filled");
        assertTrue(m.hook.ticketPaid(cancelled), "a cancelled order paid the cancel fee");
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        assertTrue(m.hook.ticketPaid(filled), "a fill of at least 0.5 IMD pays for the ticket");
        assertTrue(m.hook.ticketPaid(notReached), "an order the bell did not reach pays the fee at claim, claimed or not");
        // a fill below 0.5 IMD: D's closing book, two 10 IMD buys at the reference against one 0.6-coin sell (the
        // smallest sell worth 0.5 IMD, split two ways); the buys are the marginal heavy side, each fills about 0.3 IMD
        // and its remainder comes back whole
        _at(D, OPEN + 10 minutes);
        int24 ref = m.hook.referenceOf(2 * D + 1);
        uint256 tiny = _orderAs(m, a, 2 * D + 1, true, ref, 10e18);
        _order(m, 2 * D + 1, true, ref, 10e18);
        _order(m, 2 * D + 1, false, ref, 0.6e18);
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        (int24 pc,,,,,) = m.hook.bells(2 * D + 1);
        assertEq(pc, ref, "precondition: the close cleared at the reference");
        assertFalse(m.hook.ticketPaid(tiny), "a fill below 0.5 IMD with no fee does not pay for a ticket");
        // an order of a bell that never rang: book 2(D+1), whose open nobody rings
        _at(D, 18 hours);
        uint256 unrung = _orderAs(m, a, 2 * (D + 1), true, 0, 10e18);
        _at(D + 1, 17 hours);
        assertFalse(m.hook.ticketPaid(unrung), "an order refunded whole because its bell never rang does not pay");
        uint256 b0 = IERC20T(imd).balanceOf(a);
        m.hook.claim(unrung);
        assertEq(IERC20T(imd).balanceOf(a) - b0, 10e18, "an unrung book refunds whole, no fee");
        // the claims do not change the answers
        m.hook.claim(notReached);
        m.hook.claim(tiny);
        assertTrue(m.hook.ticketPaid(notReached), "claimed: still paid");
        assertFalse(m.hook.ticketPaid(tiny), "claimed: still unpaid");
    }

    /// The reveal path: a wallet whose first ticket is unpaid is refused without spending its one reveal, and reveals
    /// its paid ticket instead.
    function test_G_unpaidTicketDoesNotRank() public {
        Mkt memory m = mkt;
        address a = _player(m, "a", 1_000e18, 1_000e18);
        _at(D, 1 hours);
        uint256 paid = _orderAs(m, a, 2 * D, true, 60, 10e18);
        _order(m, 2 * D, false, -60, 10.3e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        // the unpaid ticket: a closing-book buy at the reference that fills about 0.3 IMD (two buys share 0.6 coin)
        _at(D, OPEN + 10 minutes);
        int24 ref = m.hook.referenceOf(2 * D + 1);
        uint256 tiny = _orderAs(m, a, 2 * D + 1, true, ref, 10e18);
        _order(m, 2 * D + 1, true, ref, 10e18);
        _order(m, 2 * D + 1, false, ref, 0.6e18);
        bytes32 salt = keccak256("s");
        vm.startPrank(a);
        m.game.commit(tiny, _commitOf(_guessOf(0), salt, a, D + 1));
        m.game.commit(paid, _commitOf(_guessOf(600), salt, a, D + 1));
        vm.stopPrank();
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D + 1, OPEN + WINDOW_T);
        m.game.settle(D + 1);
        vm.prank(a);
        vm.expectRevert(BellGame.TicketUnpaid.selector);
        m.game.reveal(tiny, _guessOf(0), salt);
        assertFalse(m.game.revealed(D + 1, a), "the refused reveal did not spend the wallet's reveal");
        (, uint32 c0) = m.game.rankOf(D + 1, 0);
        assertEq(c0, 0, "nothing ranked");
        vm.prank(a);
        m.game.reveal(paid, _guessOf(600), salt);
        (, uint32 c1) = m.game.rankOf(D + 1, 0);
        assertEq(c1, 1, "the paid ticket ranks");
    }
}
