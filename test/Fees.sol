// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {Admission} from "./Admission.sol";
import {IERC20T} from "./Base.sol";

/// The unfilled-order fee: an order whose bucket the bell did not reach pays the cancel fee at claim, in its own
/// currency, to the burns; an order the bell reached is charged only for what filled; an unrung bell refunds whole.
abstract contract Fees is Admission {
    bytes32 internal constant UNFILLED = keccak256("UnfilledFeeTaken(uint256,bool,uint256)");

    /// the UnfilledFeeTaken amount a claim emitted for `id`, and how many such events it emitted
    function _unfilledLog(Vm.Log[] memory logs, uint256 id) internal pure returns (uint256 fee, uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != UNFILLED || logs[i].topics[1] != bytes32(id)) continue;
            (, fee) = abi.decode(logs[i].data, (bool, uint256));
            ++n;
        }
    }

    function _claimAs(Mkt memory m, uint256 id) internal returns (uint256 fee, uint256 n) {
        vm.recordLogs();
        m.hook.claim(id);
        (fee, n) = _unfilledLog(vm.getRecordedLogs(), id);
    }

    /// A buy below P* and a sell above it filled nothing: each is refunded its escrow less 0.5 % rounded up, the IMD
    /// fee to the IMD burn and the coin fee to the coin burn, each in one UnfilledFeeTaken event.
    function test_U_unreachedOrdersPayTheFee() public {
        Mkt memory m = mkt;
        address a = _player(m, "u", 1_000e18, 1_000e18);
        _at(D, 1 hours);
        uint256 bIn = _order(m, 2 * D, true, 60, 10e18);
        uint256 sIn = _order(m, 2 * D, false, -60, 5e18);
        uint256 bOut = _orderAs(m, a, 2 * D, true, -1200, 10e18 + 1);
        uint256 sOut = _orderAs(m, a, 2 * D, false, 1200, 7e18 + 3);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        (int24 p,,,,,) = m.hook.bells(2 * D);
        assertTrue(-1200 < p && p < 1200, "precondition: P* between the two unreached orders");
        // the buy the bell did not reach
        uint256 i0 = IERC20T(imd).balanceOf(a);
        uint256 b0 = m.hook.burnAccrued();
        (uint256 f1, uint256 n1) = _claimAs(m, bOut);
        uint256 want1 = _up((10e18 + 1) * 50, 10_000);
        assertEq(n1, 1, "one UnfilledFeeTaken");
        assertEq(f1, want1, "0.5 % of the escrow, rounded up");
        assertEq(IERC20T(imd).balanceOf(a) - i0, 10e18 + 1 - want1, "the refund is the escrow less the fee");
        assertEq(m.hook.burnAccrued() - b0, want1, "the IMD fee goes to the IMD burn");
        // the sell the bell did not reach
        uint256 c0 = m.coin.balanceOf(a);
        uint256 cb0 = m.hook.coinBurnAccrued();
        (uint256 f2, uint256 n2) = _claimAs(m, sOut);
        uint256 want2 = _up((7e18 + 3) * 50, 10_000);
        assertEq(n2, 1);
        assertEq(f2, want2, "0.5 % of the coin escrow, rounded up");
        assertEq(m.coin.balanceOf(a) - c0, 7e18 + 3 - want2, "the coin refund is the escrow less the fee");
        assertEq(m.hook.coinBurnAccrued() - cb0, want2, "the coin fee goes to the coin burn");
        // the two orders the bell reached pay no unfilled fee
        (, uint256 n3) = _claimAs(m, bIn);
        (, uint256 n4) = _claimAs(m, sIn);
        assertEq(n3 + n4, 0, "an order the bell reached pays no unfilled fee");
        assertEq(IERC20T(imd).balanceOf(address(m.hook)), m.hook.imdAccounted(), "IMD accounting after the claims");
        assertEq(m.coin.balanceOf(address(m.hook)), m.hook.coinAccounted(), "coin accounting after the claims");
    }

    /// The marginal bucket's remainder comes back whole: two buys at P* share a smaller sell pro rata; each pays the
    /// bell fee on its fill and nothing on the rest.
    function test_U_marginalRemainderComesBackWhole() public {
        Mkt memory m = mkt;
        address a = _player(m, "mA", 1_000e18, 0);
        address b = _player(m, "mB", 1_000e18, 0);
        _at(D, 1 hours);
        uint256 ia = _orderAs(m, a, 2 * D, true, 0, 10e18);
        uint256 ib = _orderAs(m, b, 2 * D, true, 0, 30e18);
        _order(m, 2 * D, false, 0, 8e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        (int24 p, bool rung, bool buyHeavy,, uint64 marg,) = m.hook.bells(2 * D);
        assertTrue(rung && p == 0 && buyHeavy, "precondition: P* = 0, the buys the heavier side");
        assertGt(marg, 0, "precondition: the marginal buys filled in part");
        assertLt(marg, 1e18, "precondition: in part only");
        uint256[2] memory ids = [ia, ib];
        address[2] memory who = [a, b];
        for (uint256 i; i < 2; ++i) {
            uint256 acc0 = m.hook.burnAccrued() + m.hook.networkAccrued() + m.hook.feeWalletImdAccrued() + m.hook.swarmAccrued()
                + m.hook.bellPurseAccrued();
            uint256 i0 = IERC20T(imd).balanceOf(who[i]);
            vm.recordLogs();
            m.hook.claim(ids[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (, uint256 n) = _unfilledLog(logs, ids[i]);
            (,, uint256 bellFee,,) = _claimLog(logs, ids[i]);
            assertEq(n, 0, "the marginal remainder pays no unfilled fee");
            uint256 acc1 = m.hook.burnAccrued() + m.hook.networkAccrued() + m.hook.feeWalletImdAccrued() + m.hook.swarmAccrued()
                + m.hook.bellPurseAccrued();
            assertEq(acc1 - acc0, bellFee, "the accruals rose by the bell fee only");
            assertGt(IERC20T(imd).balanceOf(who[i]) - i0, 0, "the remainder came back");
        }
    }

    /// A reached-side order that nothing filled pays the fee on all of its escrow: a zero-match book with one buy at
    /// P* (the reference; nothing rationed it, so the marginal exception does not apply) and one at the band's top,
    /// the pool's residual unable to fill either. A sell-only book at the floor the same, in coin.
    function test_U_reachedSideUnfilledPaysTheFee() public {
        Mkt memory m = mkt;
        uint256 snap = vm.snapshotState();
        _at(D, 1 hours);
        int24 ref = m.hook.referenceOf(2 * D);
        uint256 atP = _order(m, 2 * D, true, ref, 10e18 + 7);
        uint256 top = _order(m, 2 * D, true, ref + 200 * 60, 20e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        (int24 p,, bool buyHeavy,, uint64 marg, uint64 rf) = m.hook.bells(2 * D);
        assertTrue(p == ref && buyHeavy && marg == 0 && rf == 0, "precondition: zero matches at the reference, nothing filled");
        uint256[2] memory ids = [atP, top];
        uint256[2] memory amt = [uint256(10e18 + 7), 20e18];
        for (uint256 i; i < 2; ++i) {
            uint256 i0 = IERC20T(imd).balanceOf(trader);
            uint256 b0 = m.hook.burnAccrued();
            (uint256 f, uint256 n) = _claimAs(m, ids[i]);
            assertEq(n, 1, "one UnfilledFeeTaken");
            assertEq(f, _up(amt[i] * 50, 10_000), "a reached order that filled nothing pays 0.5 % of its escrow");
            assertEq(IERC20T(imd).balanceOf(trader) - i0, amt[i] - f, "refunded less the fee");
            assertEq(m.hook.burnAccrued() - b0, f, "to the IMD burn");
        }
        vm.revertToState(snap);
        _at(D, 1 hours);
        uint256 sl = _order(m, 2 * D, false, ref - 200 * 60, 30e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        uint256 c0 = m.coin.balanceOf(trader);
        uint256 cb0 = m.hook.coinBurnAccrued();
        (uint256 fs, uint256 ns) = _claimAs(m, sl);
        assertEq(ns, 1);
        assertEq(fs, _up(30e18 * 50, 10_000), "a reached sell that filled nothing pays 0.5 % in coin");
        assertEq(m.coin.balanceOf(trader) - c0, 30e18 - fs);
        assertEq(m.hook.coinBurnAccrued() - cb0, fs, "to the coin burn");
    }

    /// An unrung bell refunds every order whole, reached or not: no fee of any kind.
    function test_U_unrungBellRefundsWhole() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 b1 = _order(m, 2 * D, true, -1200, 10e18);
        uint256 s1 = _order(m, 2 * D, false, 1200, 10e18);
        uint256 b2 = _order(m, 2 * D, true, 60, 10e18);
        // nobody rings D's open; the book is refundable from 16:00
        _at(D, CLOSE);
        uint256 i0 = IERC20T(imd).balanceOf(trader);
        uint256 c0 = m.coin.balanceOf(trader);
        uint256 b0 = m.hook.burnAccrued();
        uint256 cb0 = m.hook.coinBurnAccrued();
        (, uint256 n1) = _claimAs(m, b1);
        (, uint256 n2) = _claimAs(m, s1);
        (, uint256 n3) = _claimAs(m, b2);
        assertEq(n1 + n2 + n3, 0, "no unfilled fee on an unrung bell");
        assertEq(IERC20T(imd).balanceOf(trader) - i0, 20e18, "both buys refunded whole");
        assertEq(m.coin.balanceOf(trader) - c0, 10e18, "the sell refunded whole");
        assertEq(m.hook.burnAccrued(), b0, "nothing to the IMD burn");
        assertEq(m.hook.coinBurnAccrued(), cb0, "nothing to the coin burn");
    }

    /// pushBurn's paths with the raw quote read: no ETH (held at the executor, not bridged), a reverting quote (held,
    /// the caller's ETH returned), the full fee (bridged); and claimNetworkFees with a zero recipient (to the burn).
    function test_U_pushBurnPathsAndNetworkFallback() public {
        Mkt memory m = mkt;
        IExecutorT ex = IExecutorT(burnExecutor);
        uint256[3] memory sent = [uint256(0), 0.0002 ether, 0.0002 ether];
        bool[3] memory quoteOff = [false, true, false];
        bool[3] memory wantBridged = [false, false, true];
        vm.deal(address(this), 1 ether);
        for (uint256 i; i < 3; ++i) {
            _fundImd(address(this), 100e18);
            IERC20T(imd).transfer(address(m.hook), 100e18);
            m.hook.harvest();
            ex.setQuoteReverts(quoteOff[i]);
            uint256 a = m.hook.burnAccrued();
            uint256 e0 = IERC20T(imd).balanceOf(burnExecutor);
            uint256 br0 = ex.bridged();
            uint256 eth0 = address(this).balance;
            m.hook.pushBurn{value: sent[i]}();
            assertEq(IERC20T(imd).balanceOf(burnExecutor) - e0, a, "the IMD reached the executor");
            assertEq(m.hook.burnAccrued(), 0, "nothing stays accrued");
            assertEq(ex.bridged() - br0, wantBridged[i] ? a : 0, "bridged only with a readable quote and the fee paid");
            assertEq(eth0 - address(this).balance, wantBridged[i] ? sent[i] : 0, "the caller's ETH comes back when nothing bridged");
        }
        ex.setQuoteReverts(false);
        // a zero fee recipient: the network share goes to the burn
        IFeesT(launchFees).set(address(0));
        _at(D, 1 hours);
        _order(m, 2 * D, true, 60, 100e18);
        _order(m, 2 * D, false, -60, 50e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        m.hook.claim(m.hook.nextOrderId() - 2);
        m.hook.claim(m.hook.nextOrderId() - 1);
        uint256 net = m.hook.networkAccrued();
        assertGt(net, 0, "precondition: a network share accrued");
        uint256 b0 = m.hook.burnAccrued();
        m.hook.claimNetworkFees();
        assertEq(m.hook.burnAccrued() - b0, net, "a zero recipient sends the network share to the burn");
        assertEq(m.hook.networkAccrued(), 0);
    }
}

interface IExecutorT {
    function setQuoteReverts(bool v) external;
    function bridged() external view returns (uint256);
}

interface IFeesT {
    function set(address r) external;
}
