// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20T} from "../Base.sol";
import {ReproBase} from "../repro/ReproBase.sol";

/// Audit 3, finding 7, ACCEPTED: a 5 IMD buy at the band's passive edge is never reached by the bell, so at claim it
/// pays only the 0.5 % unfilled-order fee, 0.025 IMD, and holds a paid guess ticket; it counts 1 % of its value, 0.05
/// IMD, toward the deposit cap. Points only; one fresh wallet per bucket is the limit of any per-wallet rule, so no
/// change. These tests assert the ACCEPTED behaviour and pin the audit's own figures, so they PASS here and would fail
/// if the ticket or the weight changed.
contract AuditThreeFinding7Test is ReproBase {
    function _edgeTicket(int24 bucket) internal returns (uint256 counted, bool paid, uint256 cost, uint256 id) {
        address p = _player(mkt, "f7 player", 100e18, 0);
        _at(D, 1 hours);
        uint256 b0 = IERC20T(imd).balanceOf(p);
        id = _orderAs(mkt, p, 2 * D, true, bucket, 5e18);
        counted = mkt.hook.bookImdTotal(2 * D);
        _at(D, OPEN);
        mkt.hook.ringOpen();
        vm.prank(p);
        mkt.hook.claim(id);
        paid = mkt.hook.ticketPaid(id);
        cost = b0 - IERC20T(imd).balanceOf(p);
    }

    /// ACCEPTED, pinned: a 5 IMD buy at ref - 12,000 counts 0.05 IMD, holds a paid ticket, and costs 0.025 IMD.
    function test_A3F7_accepted_edgeTicketCountsOnePercentAndCostsTheUnfilledFee() public {
        (uint256 counted, bool paid, uint256 cost,) = _edgeTicket(-12_000);
        console2.log("counted toward the cap (wei IMD)", counted);
        console2.log("ticketPaid", paid ? 1 : 0);
        console2.log("net cost of the ticket (wei IMD)", cost);
        assertEq(counted, 50_000_000_000_000_000, "counted: 1 % of 5 IMD");
        assertTrue(paid, "the edge order holds a paid ticket");
        assertEq(cost, 25_000_000_000_000_000, "cost: the 0.5 % unfilled-order fee on 5 IMD");
    }

    /// CONTROL: a 5 IMD buy at the reference counts 5 IMD and holds a paid ticket.
    function test_A3F7_control_ticketAtTheReference() public {
        (uint256 counted, bool paid,,) = _edgeTicket(0);
        assertEq(counted, 5e18);
        assertTrue(paid);
    }
}
