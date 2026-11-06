// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MarketHoursCoin} from "src/MarketHoursCoin.sol";
import {MsgSenderRouter} from "../MsgSenderRouter.sol";
import {IERC20T} from "../Base.sol";
import {ReproBase} from "../repro/ReproBase.sol";

interface IERC20S {
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// A router anyone can deploy: it pays from its own balance and answers msgSender() with whatever address it is told.
contract SpoofRouter is IUnlockCallback {
    IPoolManager internal immutable manager;
    address public msgSender;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swapAs(address reported, PoolKey memory key, IPoolManager.SwapParams memory p) external {
        msgSender = reported;
        manager.unlock(abi.encode(key, p));
        msgSender = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, IPoolManager.SwapParams memory p) = abi.decode(data, (PoolKey, IPoolManager.SwapParams));
        BalanceDelta d = manager.swap(key, p, "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            manager.sync(c);
            IERC20S(Currency.unwrap(c)).transfer(address(manager), uint128(-amt));
            manager.settle();
        } else if (amt > 0) {
            manager.take(c, address(this), uint128(amt));
        }
    }
}

/// Audit 3, finding 2: the audit's attached proof (imports adjusted only; its own PoolManager and pool). The round-trip
/// guard keyed on whatever address a swap's router reports, so a stranger's router could spend a victim's direction
/// for the block. Correct: the victim's own first swap of the block goes through; the victim's own round trip is still
/// refused (the control).
contract AuditThreeFinding2ProofTest is Test {
    uint256 internal constant D = 20_400;
    PoolManager internal manager;
    MarketHoursHook internal hook;
    MarketHoursCoin internal coin;
    MarketHoursCoin internal imd;
    PoolKey internal key;
    PoolSwapTest internal router;
    SpoofRouter internal spoof;
    address internal victim = makeAddr("victim");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(D * 1 days + 1 hours);
        manager = new PoolManager(address(this));
        coin = new MarketHoursCoin("Coin", "C");
        imd = new MarketHoursCoin("IMD", "IMD");
        MarketHoursHook.Params memory p;
        p.manager = manager;
        p.factory = address(this);
        p.imd = address(imd);
        p.coin = address(coin);
        p.feeWallet = address(0xFEE);
        p.burnExecutor = address(0xB0);
        p.launchFees = address(0x1F);
        p.intake = address(0x17);
        p.maxBlockMoveBps = 100;
        p.maxSwapImd = 1e30;
        (p.networkBps, p.feeWalletBps, p.swarmFeeBps, p.burnBps, p.bellPurseBps) = (2000, 2000, 2000, 2000, 2000);
        p.launchNumber = 1;
        bytes memory init = abi.encodePacked(type(MarketHoursHook).creationCode, abi.encode(p));
        bytes32 h = keccak256(init);
        uint160 flags = (1 << 13) | (1 << 7); // beforeInitialize | beforeSwap
        bytes32 salt;
        for (uint256 i;; ++i) {
            address a = vm.computeCreate2Address(bytes32(i), h, address(this));
            if (uint160(a) & ((1 << 14) - 1) == flags) {
                salt = bytes32(i);
                break;
            }
        }
        address at;
        assembly {
            at := create2(0, add(init, 0x20), mload(init), salt)
        }
        require(at != address(0), "deploy");
        hook = MarketHoursHook(at);
        key = hook.poolKey();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0)); // this test is the factory

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        router = new PoolSwapTest(manager);
        coin.approve(address(lp), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-6000, 6000, 1e24, 0), "");

        spoof = new SpoofRouter(manager);
        coin.transfer(address(spoof), 1e18);
        imd.transfer(address(spoof), 1e18);
        coin.transfer(victim, 100e18);
        imd.transfer(victim, 100e18);
        vm.startPrank(victim);
        coin.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.warp(D * 1 days + 12 hours);
        hook.ringOpen();
        vm.roll(block.number + 1);
    }

    function _victimSwap(bool zfo) internal returns (bool ok, bytes memory e) {
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams(zfo, -1e18, zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        vm.prank(victim, victim);
        (ok, e) = address(router).call(
            abi.encodeCall(PoolSwapTest.swap, (key, sp, PoolSwapTest.TestSettings(false, false), ""))
        );
    }

    function _has(bytes memory e, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= e.length; ++i) {
            if (e[i] == sel[0] && e[i + 1] == sel[1] && e[i + 2] == sel[2] && e[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /// A stranger's router reports the victim and spends the victim's direction: the victim's own first swap of the
    /// block, signed by the victim, must still go through.
    function test_strangerCannotSpendTheVictimsDirection() public {
        bool zfoAttack = true;
        vm.prank(attacker, attacker);
        spoof.swapAs(
            victim, key, IPoolManager.SwapParams(zfoAttack, -1, TickMath.MIN_SQRT_PRICE + 1)
        );
        (bool ok, bytes memory e) = _victimSwap(!zfoAttack);
        assertFalse(_has(e, MarketHoursHook.RoundTrip.selector), "victim refused with RoundTrip by a stranger's swap");
        assertTrue(ok, "victim's swap failed");
    }

    /// CONTROL: the victim's own round trip in one block is refused, with or without the fix.
    function test_control_ownRoundTripStillRefused() public {
        (bool ok1,) = _victimSwap(true);
        assertTrue(ok1, "first swap");
        (bool ok2, bytes memory e2) = _victimSwap(false);
        assertFalse(ok2, "round trip allowed");
        assertTrue(_has(e2, MarketHoursHook.RoundTrip.selector), "refused by RoundTrip");
    }
}

interface IERC20X {
    function transfer(address, uint256) external returns (bool);
}

/// A router that swaps from its own balance and answers msgSender() with a fixed raw reply of any length, so the hook's
/// reply-length rule can be tested. A 32-byte reply carries an address.
contract RawReplyRouter is IUnlockCallback {
    IPoolManager internal immutable manager;
    bytes internal reply;

    constructor(IPoolManager m, bytes memory reply_) {
        manager = m;
        reply = reply_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory p) external {
        manager.unlock(abi.encode(key, p));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        (PoolKey memory key, IPoolManager.SwapParams memory p) = abi.decode(data, (PoolKey, IPoolManager.SwapParams));
        BalanceDelta d = manager.swap(key, p, "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            manager.sync(c);
            IERC20X(Currency.unwrap(c)).transfer(address(manager), uint128(-amt));
            manager.settle();
        } else if (amt > 0) {
            manager.take(c, address(this), uint128(amt));
        }
    }

    /// msgSender() (0xd737d0c7) and anything else: the stored raw reply, whatever its length
    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory r = reply;
        assembly ("memory-safe") {
            return(add(r, 0x20), mload(r))
        }
    }
}

/// Audit 3, finding 2 (extra: a user of a router that reports msgSender(), as the Universal Router does, is reachable
/// by a stranger's router that reports the same address) and finding 6 (the reply-length check read the previous
/// call's return size, so a reply shorter than a word was taken as an identity). On the repo's offline harness. Every
/// defect test asserts the behaviour the audit report calls correct; every control passes on every build.
contract AuditThreeFindings2And6Test is ReproBase {
    /// the guard's key for a signer whose router reports nothing: the address as a padded word
    function _signerKey(address who) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }

    /// the guard's key for an identity a router reports: the hash of the router and the reported address
    function _routerKey(address router_, address reported) internal pure returns (bytes32) {
        return keccak256(abi.encode(router_, reported));
    }

    // ── finding 2, extra ──
    function _victimThroughReportingRouter(bool stranger) internal returns (bool ok, bytes memory e) {
        MsgSenderRouter ur = new MsgSenderRouter(manager);
        address victim = _player(mkt, "f2 victim", 100e18, 100e18);
        vm.startPrank(victim);
        IERC20T(imd).approve(address(ur), type(uint256).max);
        mkt.coin.approve(address(ur), type(uint256).max);
        vm.stopPrank();
        RawReplyRouter spoof = new RawReplyRouter(manager, abi.encode(victim));
        _fundImd(address(spoof), 1e18);
        _at(D, OPEN);
        mkt.hook.ringOpen();
        _nextBlock();
        _swap(mkt, true, 10e18); // a trade up first (signer: the default origin), so a sell has IMD to take
        _nextBlock();
        if (stranger) {
            // the stranger: 1 wei of IMD in (oneForZero), reported as the victim
            vm.prank(makeAddr("stranger"), makeAddr("stranger"));
            spoof.swap(mkt.key, IPoolManager.SwapParams(false, -1, TickMath.MAX_SQRT_PRICE - 1));
            // the stranger's router spent the direction in its own namespace, nowhere else
            assertGt(mkt.hook.lastSwap(_routerKey(address(spoof), victim)), 0, "the stranger's router's key for the victim");
            assertEq(mkt.hook.lastSwap(_routerKey(address(ur), victim)), 0, "the reporting router's key for the victim is untouched");
            assertEq(mkt.hook.lastSwap(_signerKey(victim)), 0, "the victim's signer key is untouched");
        }
        // the victim: sells 0.001 coin (zeroForOne) through the reporting router, same block
        vm.prank(victim, victim);
        (ok, e) = address(ur).call(
            abi.encodeCall(MsgSenderRouter.swap, (mkt.key, IPoolManager.SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1)))
        );
    }

    /// A victim trading through a router that reports the victim (MsgSenderRouter: the Universal Router's behaviour)
    /// and a stranger's own router reporting the victim earlier in the block. Correct: the victim's swap goes through.
    function test_A3F2x_reportingRouterUserIsReachable() public {
        (bool ok, bytes memory e) = _victimThroughReportingRouter(true);
        assertFalse(_has(e, MarketHoursHook.RoundTrip.selector), "the victim's swap through a reporting router was refused RoundTrip");
        assertTrue(ok, _why(ok, e));
    }

    /// CONTROL: with no stranger, the victim's same swap through the reporting router goes through.
    function test_A3F2x_control_reportingRouterUserTrades() public {
        (bool ok, bytes memory e) = _victimThroughReportingRouter(false);
        assertTrue(ok, _why(ok, e));
    }

    // ── finding 6 ──
    function _rawRouterSwap(bytes memory reply) internal returns (RawReplyRouter rr) {
        rr = new RawReplyRouter(manager, reply);
        _fundImd(address(rr), 1e18);
        _at(D, OPEN);
        mkt.hook.ringOpen();
        _nextBlock();
        vm.prank(trader, trader);
        rr.swap(mkt.key, IPoolManager.SwapParams(false, -1, TickMath.MAX_SQRT_PRICE - 1)); // 1 wei of IMD in
    }

    /// The audit report's reproduction: a 20-byte reply (12 zero bytes, eight 0x11 bytes). Correct (the guard's own comment):
    /// a reply shorter than a word is no answer, so the signer is keyed and the spliced address is not.
    function test_A3F6_shortReplyIsNoIdentity() public {
        bytes memory reply = abi.encodePacked(bytes12(0), bytes8(0x1111111111111111));
        RawReplyRouter rr = _rawRouterSwap(reply);
        address spliced = 0x1111111111111111000000000000000000000000;
        console2.log("lastSwap(router, spliced 0x1111111111111111...)", mkt.hook.lastSwap(_routerKey(address(rr), spliced)));
        console2.log("lastSwap(tx.origin = trader)", mkt.hook.lastSwap(_signerKey(trader)));
        assertEq(mkt.hook.lastSwap(_routerKey(address(rr), spliced)), 0, "a 20-byte reply was taken as an identity");
        assertEq(mkt.hook.lastSwap(_signerKey(spliced)), 0, "a 20-byte reply was taken as a signer");
        assertGt(mkt.hook.lastSwap(_signerKey(trader)), 0, "the signer must be keyed");
    }

    /// CONTROL: an empty reply is no answer either way: the signer is keyed.
    function test_A3F6_control_emptyReplyKeysTheSigner() public {
        _rawRouterSwap("");
        assertEq(mkt.hook.lastSwap(_signerKey(trader)), (vm.getBlockNumber() << 1), "the signer keyed, direction oneForZero");
    }

    /// CONTROL: a full 32-byte reply naming an address keys that address, in the reporting router's namespace (the
    /// documented rule); neither the reported address as a signer nor the real signer is keyed.
    function test_A3F6_control_wordReplyKeysTheReported() public {
        address who = makeAddr("reported");
        RawReplyRouter rr = _rawRouterSwap(abi.encode(who));
        assertEq(mkt.hook.lastSwap(_routerKey(address(rr), who)), (vm.getBlockNumber() << 1));
        assertEq(mkt.hook.lastSwap(_signerKey(who)), 0);
        assertEq(mkt.hook.lastSwap(_signerKey(trader)), 0);
    }
}
