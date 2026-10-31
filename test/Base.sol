// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursCoin} from "../src/MarketHoursCoin.sol";
import {BellGame} from "../src/BellGame.sol";
import {SwarmBudget} from "../src/SwarmBudget.sol";
import {BellRinger} from "../src/BellRinger.sol";
import {HookDeployer} from "./HookDeployer.sol";

interface IERC20T {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/// Shared harness. The environment (PoolManager, IMD, BurnExecutor, LaunchFees, Intake) comes from `_env()`: the real
/// mainnet contracts, or local stand-ins in the offline environment (test/Offline.t.sol). The test
/// contract plays the launch factory for its own test pools: it deploys the coin (whole supply minted to it), initialises
/// the pool through the hook's beforeInitialize, and seeds a coin-only position, as the factory does. Every contract is
/// created by CREATE or CREATE2, never placed by code replacement. The hook's address carries its flags by a CREATE2 salt
/// mined in the test.
abstract contract Base is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = 0x2080; // BEFORE_INITIALIZE | BEFORE_SWAP
    uint160 internal constant FLAG_MASK = 0x3FFF; // v4's 14 hook-permission bits
    uint256 internal constant MINE_LIMIT = 1 << 20; // ~16k tries expected (1 in 2^14); a miss this long is a harness bug

    uint256 internal constant OPEN = 43200;
    uint256 internal constant CLOSE = 57600;
    uint256 internal constant FREEZE_T = 600;
    uint256 internal constant NO_CANCEL_T = 3600;
    uint256 internal constant DEADLINE_T = 72000;
    uint256 internal constant WINDOW_T = 1800;
    int256 internal constant OFFSET_T = 887_280;

    // the harness's figures: the ones the hook takes as constructor arguments
    uint256 internal constant X_BPS = 500;
    uint256 internal constant MAX_SWAP_T = 10_000e18;
    uint256 internal constant GAS_FLOOR_T = 7_000_000; // must equal the hook's BELL_GAS_FLOOR (asserted in a test)
    uint256 internal constant CAP0_T = 1_000e18;
    uint256 internal constant CAP_MAX_T = 100_000e18;
    /// the launch number the harness's hooks are built with; the test contract plays the factory, so its own
    /// `claimFees` stand-in answers the ringer's opening chore
    uint64 internal constant LAUNCH_T = 7;

    IPoolManager internal manager;
    address internal imd;
    address internal burnExecutor;
    address internal launchFees;
    address internal intake;
    address internal intakeWriter;

    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal lp;
    address internal trader = makeAddr("trader");
    address internal feeWallet = makeAddr("feeWallet");
    uint256 internal D; // the test's trading day: tomorrow relative to the clock at setUp
    Mkt internal mkt; // the one test pool most tests share

    // a seed deep enough to cover the band: pool ticks [0, 12000), L = 1e23 (about 45,000 coin in range)
    int24 internal constant WIDE = 12_000;
    uint128 internal constant WIDE_L = 1e23;
    uint256 internal constant TAG = 0x11;
    uint256 internal constant TAG_F = 0x22;
    uint256 internal constant TAG_RE = 0x44;

    struct Mkt {
        MarketHoursHook hook;
        MarketHoursCoin coin;
        PoolKey key;
        BellGame game;
        SwarmBudget budget;
    }

    function _env() internal virtual;
    function _fundImd(address who, uint256 amount) internal virtual;

    function setUp() public virtual {
        _env();
        router = new PoolSwapTest(manager);
        lp = new PoolModifyLiquidityTest(manager);
        D = block.timestamp / 1 days + 1;
        _fundImd(trader, 10_000_000e18);
        vm.startPrank(trader);
        IERC20T(imd).approve(address(router), type(uint256).max);
        vm.stopPrank();
        IERC20T(imd).approve(address(lp), type(uint256).max);
        mkt = _marketFixedAddress(TAG, type(MarketHoursHook).creationCode, WIDE, WIDE_L);
    }

    // ── deployment: CREATE / CREATE2 only ──
    function _create2At(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    /// the address a contract's first CREATE (nonce 1) gets: keccak256(rlp([deployer, 1]))
    function _create1At(address deployer) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), deployer, bytes1(0x01))))));
    }

    function _hasFlags(address a) internal pure returns (bool) {
        return uint160(a) & FLAG_MASK == FLAGS;
    }

    /// From salt `start` upward, the first CREATE2 address of `initHash` whose low 14 bits are exactly the hook's flags;
    /// with `viaDeployer`, the flags are wanted on the first CREATE of the contract at that address instead.
    function _mineSalt(bytes32 initHash, uint256 start, bool viaDeployer)
        internal
        view
        returns (bytes32 salt, address at, uint256 tries)
    {
        for (uint256 i = start; i < start + MINE_LIMIT; ++i) {
            address a = _create2At(bytes32(i), initHash);
            if (_hasFlags(viaDeployer ? _create1At(a) : a)) return (bytes32(i), a, i - start + 1);
        }
        revert("salt miner: no flag address within MINE_LIMIT");
    }

    function _create2(bytes memory initcode, bytes32 salt) internal returns (address a) {
        assembly ("memory-safe") {
            a := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        require(a != address(0), "CREATE2 failed");
    }

    function _params(address coinAt) internal view returns (MarketHoursHook.Params memory p) {
        p.manager = manager;
        p.factory = address(this);
        p.imd = imd;
        p.coin = coinAt;
        p.feeWallet = feeWallet;
        p.burnExecutor = burnExecutor;
        p.launchFees = launchFees;
        p.intake = intake;
        p.maxBlockMoveBps = X_BPS;
        p.maxSwapImd = MAX_SWAP_T;
        p.networkBps = 2000;
        p.feeWalletBps = 2000;
        p.swarmFeeBps = 1000;
        p.burnBps = 4000;
        p.bellPurseBps = 1000;
        p.launchNumber = LAUNCH_T;
    }

    function _hookInit(bytes memory creation, address coinAt) internal view returns (bytes memory) {
        return abi.encodePacked(creation, abi.encode(_params(coinAt)));
    }

    /// The coin, deployed with `new`; its CREATE2 salt is searched (no deployment per try) so that it sorts below IMD and
    /// the pool is (coin, IMD), the orientation the scenarios are written in.
    function _newCoin(uint256 tag) internal returns (MarketHoursCoin c) {
        bytes32 h = keccak256(abi.encodePacked(type(MarketHoursCoin).creationCode, abi.encode("Test Coin", "TEST")));
        uint256 i = tag << 128;
        while (_create2At(bytes32(i), h) > imd) ++i;
        c = new MarketHoursCoin{salt: bytes32(i)}("Test Coin", "TEST");
        require(address(c) < imd, "coin must sort below IMD for this harness");
    }

    /// The routers refund any ETH they hold to the caller; the test contract must accept it.
    receive() external payable {}

    // ── the factory's fee claim, played by the test contract for its own pools ──
    uint256 internal feePush; // IMD the next claimFees pushes to `feePushTo`, as the factory pushes the requester share
    address internal feePushTo;
    uint64 public lastClaimFeesLaunch;
    uint256 public claimFeesCalls;

    function claimFees(uint64 launchNumber) external returns (uint256, uint256) {
        lastClaimFeesLaunch = launchNumber;
        ++claimFeesCalls;
        uint256 a = feePush;
        feePush = 0;
        if (a > 0) IERC20T(imd).transfer(feePushTo, a);
        return (0, a);
    }

    function _ringer(Mkt memory m) internal view returns (BellRinger) {
        return BellRinger(payable(m.hook.bellPurse()));
    }

    // ── market setup ──
    /// The hook by CREATE2 at a mined salt.
    function _market(uint256 tag, bytes memory creation, int24 seedUpper, uint128 liquidity) internal returns (Mkt memory m) {
        m.coin = _newCoin(tag);
        bytes memory init = _hookInit(creation, address(m.coin));
        (bytes32 salt, address at, uint256 tries) = _mineSalt(keccak256(init), tag << 128, false);
        address hookAt = _create2(init, salt);
        require(hookAt == at && _hasFlags(hookAt), "hook landed off the mined address");
        console2.log("hook CREATE2 salt mined, tries:", tries);
        _open(m, hookAt, seedUpper, liquidity);
    }

    /// The hook by CREATE from a HookDeployer that is itself CREATE2-deployed at a mined salt. The deployer's code is
    /// fixed, so its address, and therefore the hook's, does not depend on which hook variant it deploys: from one
    /// snapshot, two variants land at one address with identical pool state.
    function _marketFixedAddress(uint256 tag, bytes memory creation, int24 seedUpper, uint128 liquidity)
        internal
        returns (Mkt memory m)
    {
        m = _marketFixedAddressWithCoin(tag, creation, "", address(0), seedUpper, liquidity);
    }

    /// The same with a coin the caller deployed (it must sort below IMD and mint to this contract), and with an
    /// init-code builder the caller controls (`initWithCoin` is ignored when `coinAt` is zero: the coin is made here).
    function _marketFixedAddressWithCoin(
        uint256 tag,
        bytes memory creation,
        bytes memory initOverride,
        address coinAt,
        int24 seedUpper,
        uint128 liquidity
    ) internal returns (Mkt memory m) {
        if (coinAt == address(0)) coinAt = address(_newCoin(tag));
        require(coinAt < imd, "coin must sort below IMD for this harness");
        m.coin = MarketHoursCoin(coinAt);
        (bytes32 salt, address dAt, uint256 tries) = _mineSalt(keccak256(type(HookDeployer).creationCode), tag << 128, true);
        HookDeployer dep = new HookDeployer{salt: salt}();
        require(address(dep) == dAt, "deployer landed off the mined address");
        address hookAt = dep.deploy(initOverride.length > 0 ? initOverride : _hookInit(creation, coinAt));
        require(hookAt == _create1At(dAt) && _hasFlags(hookAt), "hook landed off the mined address");
        console2.log("hook via CREATE2-mined deployer, tries:", tries);
        _open(m, hookAt, seedUpper, liquidity);
    }

    function _open(Mkt memory m, address hookAt, int24 seedUpper, uint128 liquidity) internal {
        address coinAt = address(m.coin);
        // the coin sorts below IMD, so the pool is (coin, IMD) and a bucket b equals the pool tick b
        m.hook = MarketHoursHook(hookAt);
        // a baseline variant (used only for a same-address gas comparison) has no companions
        try m.hook.game() returns (address g) {
            m.game = BellGame(g);
            m.budget = SwarmBudget(m.hook.swarmBudget());
        } catch {}
        m.key = PoolKey(Currency.wrap(coinAt), Currency.wrap(imd), 12_500, 60, IHooks(hookAt));
        manager.initialize(m.key, TickMath.getSqrtPriceAtTick(0));
        m.coin.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(m.key, IPoolManager.ModifyLiquidityParams(0, seedUpper, int256(uint256(liquidity)), 0), "");
        (, int24 t,,) = manager.getSlot0(m.key.toId());
        require(t == 0, "seed moved the price");
        // the trader holds coin and approves the hook (orders) and the router (swaps) for both tokens
        m.coin.transfer(trader, 10_000_000e18);
        vm.startPrank(trader);
        m.coin.approve(address(router), type(uint256).max);
        m.coin.approve(hookAt, type(uint256).max);
        IERC20T(imd).approve(hookAt, type(uint256).max);
        vm.stopPrank();
    }

    // ── clock ──
    function _at(uint256 day, uint256 tod) internal {
        vm.warp(day * 1 days + tod);
    }

    function _nextBlock() internal {
        // via-IR can cache `block.number` across a cheatcode roll, so a roll from it can land twice on one block; the
        // cheatcode reads the real current number
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ── actions ──
    function _order(Mkt memory m, uint256 s, bool buy, int24 bucket, uint256 amount) internal returns (uint256 id) {
        vm.prank(trader);
        id = m.hook.placeOrder(s, buy, bucket, amount);
    }

    function _orderAs(Mkt memory m, address who, uint256 s, bool buy, int24 bucket, uint256 amount)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = m.hook.placeOrder(s, buy, bucket, amount);
    }

    /// exact-input swap through PoolSwapTest; imdIn = buy the coin with IMD (pool currency1 in, oneForZero)
    function _swap(Mkt memory m, bool imdIn, uint256 amountIn) internal {
        vm.prank(trader);
        router.swap(
            m.key,
            IPoolManager.SwapParams(!imdIn, -int256(amountIn), imdIn ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _tick(Mkt memory m) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(m.key.toId());
    }

    function _sqrt(Mkt memory m) internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(m.key.toId());
    }

    function _liq(Mkt memory m) internal view returns (uint128) {
        return manager.getLiquidity(m.key.toId());
    }

    function _counters(Mkt memory m) internal view returns (int48 sum, uint16 count) {
        (,, sum, count) = m.hook.checkpoint();
    }

    /// the hook's nearest-bucket rule, replicated: truncating division, an exact half goes to the lower bucket
    function _nearest(int256 x) internal pure returns (int24) {
        int256 q = x / 60;
        int256 rem = x % 60;
        if (rem > 30) ++q;
        else if (rem <= -30) --q;
        return int24(q * 60);
    }

    /// cools every account a bell or a swap touches, so the next call pays cold-access prices
    function _coolAll(Mkt memory m) internal {
        vm.cool(address(m.hook));
        vm.cool(address(manager));
        vm.cool(imd);
        vm.cool(address(m.coin));
        vm.cool(address(router));
    }

    function _has(bytes memory data, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /// a player's full setup: IMD and coin, approvals to the hook
    function _player(Mkt memory m, string memory label, uint256 imdAmt, uint256 coinAmt) internal returns (address p) {
        p = makeAddr(label);
        if (imdAmt > 0) _fundImd(p, imdAmt);
        if (coinAmt > 0) m.coin.transfer(p, coinAmt);
        vm.startPrank(p);
        IERC20T(imd).approve(address(m.hook), type(uint256).max);
        m.coin.approve(address(m.hook), type(uint256).max);
        vm.stopPrank();
    }

    function _commitOf(uint256 guess, bytes32 salt, address who, uint256 day) internal pure returns (bytes32) {
        return keccak256(abi.encode(guess, salt, who, day));
    }

    function _guessOf(int24 bucket) internal pure returns (uint256) {
        return uint256(int256(bucket) + OFFSET_T);
    }
}
