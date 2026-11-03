// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {BellGame} from "src/BellGame.sol";
import {ReproBase} from "../repro/ReproBase.sol";
import {IERC20T} from "../Base.sol";

/// Audit 2, finding 5: a cancelled minimum order is a paid guess ticket for 0.0025 IMD, so a wallet seals one guess per
/// bucket and, after settle, reveals the one that matches. Day D 01:00, reference 0; day D + 1's open scores 0.
contract AuditTwoFinding5Test is ReproBase {
    bytes32 internal constant SALT = keccak256("audit 2 f5 salt");

    function _commitTry(address w, uint256 id, bytes32 c) internal returns (bool ok, bytes memory e) {
        address g = address(mkt.game);
        vm.prank(w);
        (ok, e) = g.call(abi.encodeCall(BellGame.commit, (id, c)));
    }

    /// Places and cancels 41 minimum buys, sealing one guess per bucket from -1,200 to +1,200 with each. Returns the
    /// order ids, how many commits went through, and the IMD it cost.
    function _bulk(address w) internal returns (uint256[41] memory ids, uint256 commits, uint256 cost) {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 b0 = IERC20T(imd).balanceOf(w);
        for (uint256 i; i < 41; ++i) {
            int24 k = int24(int256(i)) - 20;
            vm.prank(w);
            ids[i] = m.hook.placeOrder(2 * D, true, 0, 0.5e18);
            vm.prank(w);
            m.hook.cancelOrder(ids[i]);
            (bool ok,) = _commitTry(w, ids[i], _commitOf(_guessOf(k * 60), SALT, w, D + 1));
            if (ok) ++commits;
        }
        cost = b0 - IERC20T(imd).balanceOf(w);
    }

    function _toTheScore() internal returns (int24 scored) {
        _at(D + 1, OPEN);
        mkt.hook.ringOpen();
        _at(D + 1, OPEN + WINDOW_T);
        mkt.game.settle(D + 1);
        (,,, scored) = mkt.game.dayState(D + 1);
    }

    /// The audit report's loop: a wallet must not hold more than one sealed guess for one day.
    function test_A2F5_oneSealedGuessPerWalletPerDay() public {
        address w = _player(mkt, "bulk wallet", 100e18, 0);
        (, uint256 commits, uint256 cost) = _bulk(w);
        console2.log("commits accepted / IMD cost (wei)", commits, cost);
        assertLe(commits, 1, "one wallet, one sealed guess for a day");
    }

    /// A cancelled order never stayed in its book through the bell: its ticket must not pay.
    function test_A2F5_cancelledOrderEarnsNoTicket() public {
        Mkt memory m = mkt;
        address w = _player(m, "canceller", 100e18, 0);
        _at(D, 1 hours);
        vm.prank(w);
        uint256 id = m.hook.placeOrder(2 * D, true, 0, 0.5e18);
        vm.prank(w);
        m.hook.cancelOrder(id);
        assertFalse(m.hook.ticketPaid(id), "a cancelled order's ticket is unpaid");
    }

    /// End to end: after the loop the wallet must not be able to reveal the guess that matches the scored bucket.
    function test_A2F5_cannotPickTheMatchingGuessAfterSettle() public {
        address w = _player(mkt, "bulk wallet", 100e18, 0);
        (uint256[41] memory ids,,) = _bulk(w);
        int24 scored = _toTheScore();
        uint256 i = uint256(int256(scored / 60) + 20);
        vm.prank(w);
        (bool ok, bytes memory e) = address(mkt.game).call(abi.encodeCall(BellGame.reveal, (ids[i], _guessOf(scored), SALT)));
        if (ok) console2.log("revealed distance", mkt.game.distOf(D + 1, w));
        assertFalse(ok, string.concat("the matching guess, picked after settle, must not be revealable: ", _why(ok, e)));
    }

    /// CONTROL: one order of 5 IMD kept through the bell, one sealed guess, revealed after settle.
    function test_A2F5_control_oneRealOrderOneGuess() public {
        Mkt memory m = mkt;
        address w = _player(m, "player", 100e18, 0);
        _at(D, 1 hours);
        vm.prank(w);
        uint256 id = m.hook.placeOrder(2 * D, true, 0, 5e18);
        (bool okc, bytes memory ec) = _commitTry(w, id, _commitOf(_guessOf(0), SALT, w, D + 1));
        assertTrue(okc, _why(okc, ec));
        _at(D, OPEN);
        m.hook.ringOpen();
        _toTheScore();
        vm.prank(w);
        (bool ok, bytes memory e) = address(m.game).call(abi.encodeCall(BellGame.reveal, (id, _guessOf(0), SALT)));
        assertTrue(ok, _why(ok, e));
        assertEq(m.game.distOf(D + 1, w), 0);
    }
}
