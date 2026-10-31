// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursHookBaseline} from "./variants/MarketHoursHookBaseline.sol";
import {SwarmBudget} from "../src/SwarmBudget.sol";
import {Fees} from "./Fees.sol";
import {IIntakeH} from "./Budget.sol";
import {IERC20T} from "./Base.sol";

/// Cold gas, method stated per figure: `vm.cool` on every contract the call touches right before it, then the
/// gasleft() delta around the external call from the test contract (includes the call's cold account access, excludes
/// the 21,000 intrinsic gas and calldata).
abstract contract Gas is Fees {
    uint256 internal constant TAG_W = 0x66;

    // ── the settle window: a first-swap-of-block checkpoint inside it, the freezing one, and one outside, against the
    //    baseline hook (test/variants) at the same address from the same state ──
    function _baselineInit(address coinAt) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(MarketHoursHookBaseline).creationCode,
            abi.encode(manager, address(this), imd, coinAt, feeWallet, burnExecutor, launchFees)
        );
    }

    /// three swaps, gas read cold, on a hook at the fixed address: returns their cold gas and the hook's address
    function _windowSwaps(Mkt memory m) internal returns (uint256 inside, uint256 freezing, uint256 outside) {
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        // a warm-up swap in its own block, so the checkpoint and the round-trip word are non-zero from here on
        _nextBlock();
        _at(D, OPEN + 60);
        _swap(m, true, 100e18);
        // inside the window: the block's first swap feeds the counters
        _nextBlock();
        _at(D, OPEN + 5 minutes);
        _coolAll(m);
        uint256 g = gasleft();
        _swap(m, true, 100e18);
        inside = g - gasleft();
        // the freezing checkpoint: the first block's first swap at or after 12:30
        _nextBlock();
        _at(D, OPEN + WINDOW_T + 30);
        _coolAll(m);
        g = gasleft();
        _swap(m, true, 100e18);
        freezing = g - gasleft();
        // outside, frozen: a plain checkpoint
        _nextBlock();
        _at(D, OPEN + WINDOW_T + 10 minutes);
        _coolAll(m);
        g = gasleft();
        _swap(m, true, 100e18);
        outside = g - gasleft();
    }

    function test_w_windowGasAgainstBaseline() public {
        uint256 snap = vm.snapshotState();
        address coinAt = address(_newCoin(TAG_W));
        Mkt memory m = _marketFixedAddressWithCoin(TAG_W, type(MarketHoursHook).creationCode, "", coinAt, WIDE, WIDE_L);
        (uint256 a1, uint256 a2, uint256 a3) = _windowSwaps(m);
        (, uint256 tc,, bool frozen) = m.hook.sessionMean();
        assertEq(tc, 2, "two in-window checkpoints (the warm-up and the timed one)");
        assertTrue(frozen, "frozen by the 12:30 checkpoint");
        address atNew = address(m.hook);
        vm.revertToState(snap);
        coinAt = address(_newCoin(TAG_W));
        Mkt memory b = _marketFixedAddressWithCoin(TAG_W, "", _baselineInit(coinAt), coinAt, WIDE, WIDE_L);
        assertEq(address(b.hook), atNew, "one address for both hooks");
        (uint256 b1, uint256 b2, uint256 b3) = _windowSwaps(b);
        console2.log("(w) hook address, both variants", atNew);
        console2.log("(w) router swap, first in block INSIDE the window, cold: finished / baseline", a1, b1);
        console2.log("(w) router swap, the FREEZING checkpoint, cold: finished / baseline", a2, b2);
        console2.log("(w) router swap, first in block OUTSIDE (frozen), cold: finished / baseline", a3, b3);
        console2.log("(w) delta inside / freezing / outside", a1 - b1, a2 - b2, a3 - b3);
    }

    // ── the game and the purse, cold ──
    function _coolGame(Mkt memory m) internal {
        vm.cool(address(m.game));
        vm.cool(address(m.hook));
        vm.cool(imd);
        vm.cool(address(m.coin));
    }

    function _coolBudget(Mkt memory m) internal {
        vm.cool(address(m.budget));
        vm.cool(address(m.hook));
        vm.cool(imd);
        vm.cool(intake);
    }

    /// the game's figures, cold: the first commit of the day, settle from the window, the three reveal shapes (each
    /// reveal also reads the hook's ticketPaid view), tally. Nothing here touches the Intake.
    function test_g_gameGas() public {
        Mkt memory m = mkt;
        address[6] memory p;
        uint256[6] memory ids;
        _at(D, 1 hours);
        for (uint256 i; i < 6; ++i) {
            p[i] = _player(m, string.concat("g", vm.toString(i)), 1_000e18, 0);
            ids[i] = _orderAs(m, p[i], 2 * D, true, 60, 10e18);
        }
        _order(m, 2 * D, false, -60, 100e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, CLOSE);
        _nextBlock();
        m.hook.ringClose();
        // a dry run of the day to find the scored bucket, then commits around it (back on D)
        uint256 snap = vm.snapshotState();
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _session(m, D + 1, 3, 500e18, OPEN);
        _at(D + 1, OPEN + WINDOW_T);
        m.game.settle(D + 1);
        int24 sc = _scoredOf(m, D + 1);
        vm.revertToState(snap);
        _at(D, 15 hours);
        bytes32 salt = keccak256("s");
        int24[6] memory off = [int24(10), 20, 30, 5, 15, 100]; // the last three: rank 1, rank 3, unranked
        for (uint256 i; i < 6; ++i) {
            _coolGame(m);
            uint256 g1 = gasleft();
            vm.prank(p[i]);
            m.game.commit(ids[i], _commitOf(_guessOf(sc + off[i] * 60), salt, p[i], D + 1));
            if (i == 0) console2.log("(g) commit, first for the day, cold (gas)", g1 - gasleft());
        }
        _at(D + 1, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _session(m, D + 1, 3, 500e18, OPEN);
        _at(D + 1, OPEN + WINDOW_T);
        _coolGame(m);
        uint256 g2 = gasleft();
        m.game.settle(D + 1);
        console2.log("(g) settle from the window, cold (gas)", g2 - gasleft());
        assertEq(_scoredOf(m, D + 1), sc, "settled where the dry run did");
        for (uint256 i; i < 3; ++i) {
            vm.prank(p[i]);
            m.game.reveal(ids[i], _guessOf(sc + off[i] * 60), salt);
        }
        string[3] memory label = ["(g) reveal landing rank 1, cold (gas)", "(g) reveal landing rank 3, cold (gas)", "(g) reveal unranked, cold (gas)"];
        for (uint256 i = 3; i < 6; ++i) {
            _coolGame(m);
            uint256 g3 = gasleft();
            vm.prank(p[i]);
            m.game.reveal(ids[i], _guessOf(sc + off[i] * 60), salt);
            console2.log(label[i - 3], g3 - gasleft());
        }
        (uint32 r0,) = m.game.rankOf(D + 1, 0);
        assertEq(r0, 5, "rank 1 = the 5-bucket guess");
        // the points
        _at(D + 1, CLOSE);
        _coolGame(m);
        uint256 g5 = gasleft();
        m.game.tally(D + 1, p[3]);
        console2.log("(g) tally, rank 1, cold (gas)", g5 - gasleft());
        assertEq(m.game.points(p[3]), 3);
    }

    /// claim, cold: a filled buy (bell fee), a buy the bell did not reach (the unfilled-order fee), the same for sells,
    /// and an order of an unrung bell (refunded whole, no fee)
    function test_g_claimGas() public {
        Mkt memory m = mkt;
        _at(D, 1 hours);
        uint256 bFill = _order(m, 2 * D, true, 60, 10e18);
        uint256 sFill = _order(m, 2 * D, false, -60, 5e18);
        uint256 bOut = _order(m, 2 * D, true, -1200, 10e18);
        uint256 sOut = _order(m, 2 * D, false, 1200, 10e18);
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        uint256[4] memory ids = [bFill, sFill, bOut, sOut];
        string[4] memory label = [
            "(g) claim, filled buy (bell fee), cold (gas)",
            "(g) claim, filled sell (bell fee), cold (gas)",
            "(g) claim, buy not reached (unfilled-order fee), cold (gas)",
            "(g) claim, sell not reached (unfilled-order fee), cold (gas)"
        ];
        for (uint256 i; i < 4; ++i) {
            _coolAll(m);
            uint256 g = gasleft();
            m.hook.claim(ids[i]);
            console2.log(label[i], g - gasleft());
        }
        // an unrung bell: book 2(D+1), nobody rings D+1's open
        _at(D, CLOSE);
        m.hook.ringClose();
        _at(D, 18 hours);
        uint256 u = _order(m, 2 * (D + 1), true, -1200, 10e18);
        _at(D + 1, 17 hours);
        _coolAll(m);
        uint256 g2 = gasleft();
        m.hook.claim(u);
        console2.log("(g) claim, unrung bell (whole refund, no fee), cold (gas)", g2 - gasleft());
    }

    /// the purse's figures, cold: requestNight (both requests) and the three completions through the Intake, top level,
    /// the writer impersonated; the callback frames themselves are read from a -vvvv trace.
    function test_g_budgetGas() public {
        Mkt memory m = mkt;
        _fundImd(address(this), 3e18);
        IERC20T(imd).transfer(address(m.budget), 3e18);
        _at(D, OPEN);
        m.hook.ringOpen();
        _at(D, CLOSE);
        m.hook.ringClose();
        _at(D, 17 hours);
        _coolBudget(m);
        uint256 g0 = gasleft();
        m.budget.requestNight(D + 1);
        console2.log("(g) requestNight, both requests, cold (gas)", g0 - gasleft());
        (, bytes32 gid, bytes32 rid) = m.budget.nights(D + 1);
        // the callbacks through the Intake, the writer impersonated; frames are inside the Intake's own call
        bytes memory cbd = _job(gid, GUESS_HASH, URI_78);
        _coolBudget(m);
        uint256 g4 = gasleft();
        _complete(gid, 0, GUESS_HASH, URI_78, cbd);
        console2.log("(g) completion carrying onGuess (job shape, on time), top level, cold (gas)", g4 - gasleft());
        assertEq(m.budget.guessHash(D + 1), GUESS_HASH, "the guess was stored");
        _coolBudget(m);
        g4 = gasleft();
        _complete(rid, 0, keccak256("r"), URI_78, abi.encode(rid, keccak256("r"), URI_78));
        console2.log("(g) completion carrying onReport, top level, cold (gas)", g4 - gasleft());
        // a failure on a fresh night: D+1's close settles by its deadline (no bell rang on D+1 here)
        _at(D + 1, 20 hours + 1);
        m.budget.requestNight(D + 2);
        (, bytes32 gid2,) = m.budget.nights(D + 2);
        _coolBudget(m);
        g4 = gasleft();
        _complete(gid2, 1, bytes32(0), "", abi.encode(gid2, uint8(1), bytes32("refused"), uint16(0), uint16(0), bytes("")));
        console2.log("(g) completion carrying onFailure (status 1), top level, cold (gas)", g4 - gasleft());
        assertEq(m.budget.failStatus(D + 2, 1), 1, "the failure hook stored status 1 for the guess");
    }

    /// the two callbacks' own frames, cold, with a real result uri's length (78 B): called by the Intake's address directly, so the figure is the callback's
    /// own cost, without the Intake's completion around it (the Intake gives each 200,000 gas)
    function test_g_callbackFrames() public {
        Mkt memory m = mkt;
        (bytes32 g, bytes32 r) = _night(m, 3e18);
        uint256 snap = vm.snapshotState();
        _coolBudget(m);
        vm.prank(intake);
        uint256 g0 = gasleft();
        m.budget.onGuess(g, GUESS_HASH, URI_78);
        console2.log("(g) onGuess frame, stored on time (job shape), cold (gas)", g0 - gasleft());
        assertFalse(m.budget.guessLate(D + 1));
        vm.revertToState(snap);
        _at(D + 1, OPEN);
        _coolBudget(m);
        vm.prank(intake);
        g0 = gasleft();
        m.budget.onGuess(g, GUESS_HASH, URI_78);
        console2.log("(g) onGuess frame, stored and marked late, cold (gas)", g0 - gasleft());
        assertTrue(m.budget.guessLate(D + 1));
        _coolBudget(m);
        vm.prank(intake);
        g0 = gasleft();
        m.budget.onReport(r, keccak256("r"), URI_78);
        console2.log("(g) onReport frame, cold (gas)", g0 - gasleft());
    }

    /// the hook's creation bytes as the factory deploys them: its creation code (the two companions' creation code
    /// inside it) plus the ABI-encoded constructor arguments, against the 49,152-byte initcode limit
    function test_s_hookCreationWithArgs() public view {
        bytes memory args = abi.encode(_params(address(mkt.coin)));
        uint256 code = type(MarketHoursHook).creationCode.length;
        console2.log("(s) hook creation code (B) / constructor args (B) / total (B)", code, args.length, code + args.length);
        console2.log("(s) margin to 49,152 (B)", 49_152 - code - args.length);
        assertLe(code + args.length, 49_152, "hook creation over the initcode limit");
    }

    function test_g_settleGasFallback() public {
        Mkt memory m = mkt;
        _at(D, OPEN);
        _nextBlock();
        m.hook.ringOpen();
        _at(D, OPEN + WINDOW_T);
        _coolGame(m);
        uint256 g = gasleft();
        m.game.settle(D);
        console2.log("(g) settle falling back to P* (no checkpoint), cold (gas)", g - gasleft());
    }
}
