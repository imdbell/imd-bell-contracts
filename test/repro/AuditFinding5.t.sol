// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {BellGame} from "src/BellGame.sol";
import {ReproBase} from "./ReproBase.sol";

/// Audit finding 5 (low): the smallest buy that fills whole is not counted as having paid for its ticket. Audit 2
/// raised the smallest ticket order to 5 IMD; the rule stays (a whole fill has paid) from that size up.
contract AuditFinding5Test is ReproBase {
    bytes32 internal constant SALT = keccak256("f5 salt");

    /// Sell-heavy book at bucket 0: the `buyAmt` buy is the lighter side and fills whole.
    function _lightBuy(Mkt memory m, uint256 buyAmt) internal returns (uint256 b, address bu) {
        bu = _player(m, "buyer", 10e18, 0);
        address se = _player(m, "seller", 0, 10e18);
        _at(D, 1 hours);
        b = _orderAs(m, bu, 2 * D, true, 0, buyAmt);
        _orderAs(m, se, 2 * D, false, 0, 6e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p,, bool heavy,,,) = m.hook.bells(2 * D);
        assertTrue(p == 0 && !heavy, "precondition: sell-heavy at bucket 0");
    }

    function test_F5_smallestBuyFilledWholeHasPaid() public {
        Mkt memory m = mkt;
        (uint256 b, address bu) = _lightBuy(m, 5e18);
        Out memory o = _claimOut(m, b, bu, true);
        console2.log("5 IMD buy: coin out / IMD refund", o.out, o.refund);
        console2.log("5 IMD buy: unfilled fee", o.unfilledFee);
        assertTrue(m.hook.ticketPaid(b), "a 5 IMD buy that filled whole and paid the bell fee has paid for its ticket");
    }

    /// End to end: that order's sealed guess for day D + 1 cannot be revealed.
    function test_F5_smallestBuyFilledWholeCanReveal() public {
        Mkt memory m = mkt;
        address bu = _player(m, "buyer", 10e18, 0);
        address se = _player(m, "seller", 0, 10e18);
        _at(D, 1 hours);
        uint256 b = _orderAs(m, bu, 2 * D, true, 0, 5e18);
        _orderAs(m, se, 2 * D, false, 0, 6e18);
        uint256 g = _guessOf(0);
        vm.prank(bu);
        m.game.commit(b, _commitOf(g, SALT, bu, D + 1));
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D + 1, OPEN);
        m.hook.ringOpen();
        _at(D + 1, OPEN + WINDOW_T);
        m.game.settle(D + 1);
        vm.prank(bu);
        (bool ok, bytes memory e) = address(m.game).call(abi.encodeCall(BellGame.reveal, (b, g, SALT)));
        assertTrue(ok, string.concat("the smallest whole-filled buy's guess must be revealable: ", _why(ok, e)));
    }

    /// CONTROL: a buy just under 5 IMD that fills whole has not paid: under the ticket's minimum, whatever it filled.
    function test_F5_control_buyUnderTheTicketMinimumHasNotPaid() public {
        Mkt memory m = mkt;
        (uint256 b,) = _lightBuy(m, 4.99e18);
        assertFalse(m.hook.ticketPaid(b));
    }

    /// CONTROL: a sell worth 5 IMD that fills whole (buy-heavy book) has paid.
    function test_F5_control_smallestSellFilledWholeHasPaid() public {
        Mkt memory m = mkt;
        address bu = _player(m, "buyer", 10e18, 0);
        address se = _player(m, "seller", 0, 10e18);
        _at(D, 1 hours);
        _orderAs(m, bu, 2 * D, true, 0, 10e18);
        uint256 s = _orderAs(m, se, 2 * D, false, 0, 5e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        (int24 p,, bool heavy,,,) = m.hook.bells(2 * D);
        assertTrue(p == 0 && heavy, "precondition: buy-heavy at bucket 0");
        assertTrue(m.hook.ticketPaid(s));
    }
}
