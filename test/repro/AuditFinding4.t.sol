// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {BellGame} from "src/BellGame.sol";
import {ReproBase} from "./ReproBase.sol";

/// Audit finding 4 (low): an opening bell rung at or after 15:30 leaves no reveal window.
contract AuditFinding4Test is ReproBase {
    address internal pl;
    uint256 internal id;
    uint256 internal guess;
    bytes32 internal constant SALT = keccak256("f4 salt");

    /// Day D: an order that pays for its ticket (a buy below the reference, never reached) and a commit for day D + 1.
    function _ticket(Mkt memory m) internal {
        pl = _player(m, "player", 100e18, 0);
        _at(D, 1 hours);
        id = _orderAs(m, pl, 2 * D, true, -60, 1e18);
        guess = _guessOf(0);
        vm.prank(pl);
        m.game.commit(id, _commitOf(guess, SALT, pl, D + 1));
        _at(D, OPEN);
        m.hook.ringOpen();
        assertTrue(m.hook.ticketPaid(id), "precondition: the ticket is paid");
    }

    /// Rings day D + 1's open at `ringTod`, settles at the first second settle allows, then tries the reveal.
    function _play(Mkt memory m, uint256 ringTod) internal returns (bool settledVoid, bool revealOk, bytes memory e) {
        _at(D + 1, ringTod);
        m.hook.ringOpen();
        uint256 earliest = ringTod + WINDOW_T;
        if (earliest > ringTod) {
            _at(D + 1, earliest - 1);
            (bool early,) = address(m.game).call(abi.encodeCall(BellGame.settle, (D + 1)));
            assertFalse(early, "settle one second before the window ends is refused");
        }
        _at(D + 1, earliest);
        m.game.settle(D + 1);
        (, settledVoid,,) = m.game.dayState(D + 1);
        vm.prank(pl);
        (revealOk, e) = address(m.game).call(abi.encodeCall(BellGame.reveal, (id, guess, SALT)));
        console2.log("bell tod / settle tod", ringTod, earliest);
    }

    /// Audit finding 4: a bell at 15:31; correct is a void day (ticket not lost) or a successful reveal.
    function test_F4_lateBellLeavesARevealWindowOrVoids() public {
        Mkt memory m = mkt;
        _ticket(m);
        (bool v, bool ok, bytes memory e) = _play(m, 55_860);
        (bool fin,,, uint32[3] memory count,,) = m.game.finalRanks(D + 1);
        console2.log("isVoid", v);
        console2.log("reveal ok", ok);
        console2.log("finalRanks isFinal", fin);
        console2.log("finalRanks slot0 count", uint256(count[0]));
        console2.log("ticketUsed", m.game.ticketUsed(id));
        assertTrue(v || ok, string.concat("a ticket for a late-bell day must be revealable or the day void: ", _why(ok, e)));
    }

    /// CONTROL: the bell at 12:00; settle 12:30, reveal succeeds.
    function test_F4_control_bellAtNoon() public {
        Mkt memory m = mkt;
        _ticket(m);
        (bool v, bool ok, bytes memory e) = _play(m, OPEN);
        assertFalse(v);
        assertTrue(ok, _why(ok, e));
    }

    /// CONTROL (boundary): the bell at 15:29:59; settle at 15:59:59, reveal still succeeds.
    function test_F4_control_bellOneSecondBefore1530() public {
        Mkt memory m = mkt;
        _ticket(m);
        (bool v, bool ok, bytes memory e) = _play(m, CLOSE - WINDOW_T - 1);
        assertFalse(v);
        assertTrue(ok, _why(ok, e));
    }
}
