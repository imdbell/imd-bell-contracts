// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MarketHoursCoin} from "src/MarketHoursCoin.sol";
import {BellGame} from "src/BellGame.sol";
import {BellRinger} from "src/BellRinger.sol";
import {ReproBase} from "../repro/ReproBase.sol";

/// Audit 2, finding 6 (info): the ringer's only settle chore runs at the closing bell, after the reveal window shut.
/// Audit 2, finding 7 (info): a bell can be rung on a hook whose pool is not initialised.
contract AuditTwoFindings6And7Test is ReproBase {
    bytes32 internal constant SALT = keccak256("audit 2 f6 salt");

    function _committed() internal returns (address w, uint256 id) {
        Mkt memory m = mkt;
        w = _player(m, "player", 100e18, 0);
        _at(D, 1 hours);
        vm.prank(w);
        id = m.hook.placeOrder(2 * D, true, 0, 5e18);
        vm.prank(w);
        m.game.commit(id, _commitOf(_guessOf(0), SALT, w, D + 1));
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
    }

    /// Finding 6 is accepted without a contract change: the site's settle trigger at 12:30 opens the reveal window (the
    /// ringer's close chore stays the void-day and safety path). Anyone settles at 12:30; the reveal before 16:00 is
    /// accepted. The audit report's own expectation (the close chore opens the window) fails by design and is not kept here.
    function test_A2F6_settleAt1230OpensTheWindow() public {
        (address w, uint256 id) = _committed();
        _at(D + 1, OPEN + WINDOW_T);
        vm.prank(makeAddr("anyone"));
        mkt.game.settle(D + 1);
        _at(D + 1, OPEN + WINDOW_T + 60);
        vm.prank(w);
        (bool ok, bytes memory e) = address(mkt.game).call(abi.encodeCall(BellGame.reveal, (id, _guessOf(0), SALT)));
        assertTrue(ok, _why(ok, e));
    }

    /// Finding 7: a hook created but not initialised must refuse a ring, as it refuses orders and cancels.
    function test_A2F7_ringRefusedBeforeInitialisation() public {
        MarketHoursCoin c = _newCoin(0x7a7);
        address h = _deployHook(_params(address(c)), 0x7a7);
        assertTrue(h != address(0), "harness: hook deployed");
        assertFalse(MarketHoursHook(h).initialized(), "precondition: not initialised");
        _at(D, OPEN);
        (bool ok, bytes memory e) = h.call(abi.encodeCall(MarketHoursHook.ringOpen, ()));
        if (ok) {
            (int24 p, bool rung,,,,) = MarketHoursHook(h).bells(2 * D);
            (uint24 wd, uint32 wo,,,) = MarketHoursHook(h).window();
            console2.log("rung", rung ? 1 : 0);
            console2.log("pStar", int256(p));
            console2.log("window day / openedAt", wd, wo);
        }
        assertFalse(ok, string.concat("a ring before initialisation must be refused: ", _why(ok, e)));
    }

    /// CONTROL: the initialised pool's hook rings at 12:00.
    function test_A2F7_control_initialisedRings() public {
        _at(D, OPEN);
        mkt.hook.ringOpen();
        (, bool rung,,,,) = mkt.hook.bells(2 * D);
        assertTrue(rung);
    }
}
