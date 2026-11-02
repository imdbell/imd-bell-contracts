// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MarketHoursCoin} from "src/MarketHoursCoin.sol";

/// An attacker that rings the bell from inside its own PoolManager unlock. The hook's residual swap then calls
/// `manager.unlock` while the manager is already unlocked, which reverts with AlreadyUnlocked; `_ring` swallows it.
contract NestedRinger is IUnlockCallback {
    IPoolManager immutable manager;
    MarketHoursHook immutable hook;

    constructor(IPoolManager m, MarketHoursHook h) {
        manager = m;
        hook = h;
    }

    function attack() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.ringOpen();
        return "";
    }
}

contract NestedUnlockRingTest is Test {
    uint256 constant OPEN = 43200;
    uint256 constant CLOSE = 57600;

    IPoolManager manager;
    address imd;
    MarketHoursCoin coin;
    MarketHoursHook hook;
    PoolKey key;
    PoolModifyLiquidityTest lp;
    address trader = makeAddr("trader");
    uint256 D;

    // ── the harness: the test plays the factory ──
    function claimFees(uint64) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function feeRecipient() external view returns (address) {
        return address(this);
    }

    function _create2At(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        // IMD sorts high, the coin low, so the pool is (coin, IMD) and bucket b is pool tick b
        bytes32 hi = keccak256(abi.encodePacked(type(MockERC20).creationCode, abi.encode("IMD", "IMD", uint8(18))));
        uint256 i;
        while (_create2At(bytes32(i), hi) < address(uint160(0xD0) << 152)) ++i;
        imd = address(new MockERC20{salt: bytes32(i)}("IMD", "IMD", 18));
        bytes32 hc = keccak256(abi.encodePacked(type(MarketHoursCoin).creationCode, abi.encode("Coin", "COIN")));
        i = 0;
        while (_create2At(bytes32(i), hc) > imd) ++i;
        coin = new MarketHoursCoin{salt: bytes32(i)}("Coin", "COIN");

        MarketHoursHook.Params memory p;
        p.manager = manager;
        p.factory = address(this);
        p.imd = imd;
        p.coin = address(coin);
        p.feeWallet = makeAddr("feeWallet");
        p.burnExecutor = makeAddr("burnExecutor");
        p.launchFees = address(this);
        p.intake = makeAddr("intake");
        p.maxBlockMoveBps = 500;
        p.maxSwapImd = 10_000e18;
        p.networkBps = 2000;
        p.feeWalletBps = 2000;
        p.swarmFeeBps = 1000;
        p.burnBps = 4000;
        p.bellPurseBps = 1000;
        p.launchNumber = 1;
        bytes memory init = abi.encodePacked(type(MarketHoursHook).creationCode, abi.encode(p));
        bytes32 ih = keccak256(init);
        i = 0;
        while (uint160(_create2At(bytes32(i), ih)) & 0x3FFF != 0x2080) ++i;
        address at;
        bytes32 salt = bytes32(i);
        assembly ("memory-safe") {
            at := create2(0, add(init, 0x20), mload(init), salt)
        }
        require(at != address(0), "hook create2 failed");
        hook = MarketHoursHook(at);

        key = PoolKey(Currency.wrap(address(coin)), Currency.wrap(imd), 12_500, 60, IHooks(at));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        lp = new PoolModifyLiquidityTest(manager);
        coin.approve(address(lp), type(uint256).max);
        MockERC20(imd).mint(address(this), 1e30);
        MockERC20(imd).approve(address(lp), type(uint256).max);
        // a coin-only seed above spot, as the factory places it: the opening residual buys from it
        lp.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(0, 12_000, int256(uint256(1e23)), 0), "");

        coin.transfer(trader, 1_000_000e18);
        MockERC20(imd).mint(trader, 1_000_000e18);
        vm.startPrank(trader);
        coin.approve(at, type(uint256).max);
        MockERC20(imd).approve(at, type(uint256).max);
        vm.stopPrank();
        D = block.timestamp / 1 days + 1;
    }

    /// A buy-heavy opening book: one sell of 1 coin at bucket 0 and a 900 IMD buy at bucket 300. The book matches
    /// 1 coin and leaves about 888 IMD of residual, which the ring sends through the pool at up to price(300).
    function _book() internal {
        vm.warp(D * 1 days + 1 hours);
        vm.startPrank(trader);
        hook.placeOrder(2 * D, false, 0, 1e18);
        hook.placeOrder(2 * D, true, 300, 900e18);
        vm.stopPrank();
        vm.warp(D * 1 days + OPEN);
    }

    function test_ringFromInsideForeignUnlockDropsTheResidual() public {
        _book();
        // control: a plain ring fills the residual through the pool
        uint256 snap = vm.snapshotState();
        hook.ringOpen();
        (, bool rung0, bool heavy0,,, uint64 rf0) = hook.bells(2 * D);
        assertTrue(rung0 && heavy0, "precondition: the open rang buy-heavy");
        assertGt(rf0, 0, "precondition: a plain ring fills the residual");
        vm.revertToState(snap);

        // the same book, rung from inside an unrelated unlock
        NestedRinger a = new NestedRinger(manager, hook);
        try a.attack() {
            (, bool rung,,,, uint64 rf) = hook.bells(2 * D);
            assertTrue(rung, "the bell rang");
            // on the code as it stands this fails: the bell is rung with residualFill == 0, the residual never
            // reached the pool, and every heavy-side order's unfilled part now pays the unfilled-order fee
            assertGt(rf, 0, "a bell rung from inside a foreign unlock cleared without its residual");
        } catch {
            // fixed: the hook refuses to ring while the PoolManager is already unlocked
        }
    }
}
