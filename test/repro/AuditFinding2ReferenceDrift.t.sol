// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {MarketHoursCoin} from "src/MarketHoursCoin.sol";

/// The book's reference is whatever the last bell cleared at, and a bell clears at the bucket with the most matched
/// volume, however small. One actor who places the two smallest orders at the top edge of the band matches with
/// itself there, so the bell clears 200 buckets (x3.32) above the pool's price for about 0.02 IMD of fees. Two such
/// bells (open and close of one day) put the pool's actual price outside the next book's band: no honest order can be
/// placed at or near the market price any more (BadBucket), while the pool itself has not moved a tick.
contract ReferenceDriftTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant FLAGS = 0x2080; // BEFORE_INITIALIZE | BEFORE_SWAP
    uint256 internal constant OPEN = 43200;
    uint256 internal constant CLOSE = 57600;

    IPoolManager internal manager;
    MockERC20 internal imd;
    MarketHoursCoin internal coin;
    MarketHoursHook internal hook;
    PoolKey internal key;
    address internal attacker = makeAddr("attacker");
    address internal honest = makeAddr("honest");
    uint256 internal D;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        imd = new MockERC20("IMD", "IMD", 18);
        coin = new MarketHoursCoin("Coin", "COIN");
        MarketHoursHook.Params memory p;
        p.manager = manager;
        p.factory = address(this);
        p.imd = address(imd);
        p.coin = address(coin);
        p.feeWallet = makeAddr("feeWallet");
        p.burnExecutor = makeAddr("burnExecutor");
        p.launchFees = makeAddr("launchFees");
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
        bytes32 h = keccak256(init);
        bytes32 salt;
        for (uint256 i;; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), h)))));
            if (uint160(a) & 0x3FFF == FLAGS) {
                salt = bytes32(i);
                break;
            }
        }
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(init, 0x20), mload(init), salt)
        }
        require(at != address(0), "hook CREATE2 failed");
        hook = MarketHoursHook(at);
        (address c0, address c1) =
            address(imd) < address(coin) ? (address(imd), address(coin)) : (address(coin), address(imd));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(at));
        // the factory (this contract) initialises the pool at tick 0: 1 IMD per coin, so bucket 0 is the market price
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        imd.mint(attacker, 100e18);
        coin.transfer(attacker, 100e18);
        imd.mint(honest, 1_000e18);
        vm.startPrank(attacker);
        imd.approve(at, type(uint256).max);
        coin.approve(at, type(uint256).max);
        vm.stopPrank();
        vm.prank(honest);
        imd.approve(at, type(uint256).max);
        D = block.timestamp / 1 days + 1;
    }

    function test_twoSmallestSelfMatchedOrdersLockTheMarketPriceOutOfTheBook() public {
        int24 ref0 = hook.lastCleared();
        assertEq(ref0, 0, "the reference starts at the pool's launch price");
        int256 imd0 = int256(imd.balanceOf(attacker));
        int256 coin0 = int256(coin.balanceOf(attacker));

        // day D, 01:00: the open book. Two smallest orders, both at the band's top edge, ref + 200 buckets.
        vm.warp(D * 1 days + 1 hours);
        vm.startPrank(attacker);
        uint256 b1 = hook.placeOrder(2 * D, true, ref0 + 12_000, 0.5e18);
        uint256 s1 = hook.placeOrder(2 * D, false, ref0 + 12_000, 0.5e18);
        vm.stopPrank();
        vm.warp(D * 1 days + OPEN);
        hook.ringOpen();
        (int24 pOpen,,,,,) = hook.bells(2 * D);
        assertEq(pOpen, ref0 + 12_000, "the open cleared at the attacker's bucket, 200 buckets above the market");
        // the next reference is the pool's own price, not P* (was: lastCleared == ref0 + 12,000)
        assertEq(hook.lastCleared(), ref0, "the close book's reference stays on the pool's price");

        // the close book: again at the band's top edge; that edge is ref0 + 12,000 now (was 24,000,
        // which is outside the band and refused); the sell is valued at the reference, so it takes 0.5 coin
        vm.startPrank(attacker);
        uint256 b2 = hook.placeOrder(2 * D + 1, true, ref0 + 12_000, 0.5e18);
        uint256 s2 = hook.placeOrder(2 * D + 1, false, ref0 + 12_000, 0.5e18);
        vm.stopPrank();
        vm.warp(D * 1 days + CLOSE);
        hook.ringClose();
        // was lastCleared == ref0 + 24,000 ("two bells: 400 buckets above the pool")
        assertEq(hook.lastCleared(), ref0, "two bells and the reference is still the pool's price");

        // the attacker takes everything back; the whole exercise cost the attacker the fees on two 0.5 IMD matches
        hook.claim(b1);
        hook.claim(s1);
        hook.claim(b2);
        hook.claim(s2);
        int256 lostImd = imd0 - int256(imd.balanceOf(attacker));
        int256 lostCoin = coin0 - int256(coin.balanceOf(attacker));
        console2.log("attacker IMD lost (wei)", lostImd);
        console2.log("attacker coin lost (wei)", lostCoin);
        assertLt(lostImd + lostCoin, 0.1e18, "the drift cost less than 0.1 IMD at the pool's price of 1 IMD per coin");

        // the pool never traded: its price is still bucket 0
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, 0, "the pool's price did not move");

        // day D+1, 01:00: the open book's band is [ref0 + 12000, ref0 + 36000]; a buy at the pool's price is refused.
        // Expected: an order at the market price is always placeable; actual: BadBucket.
        vm.warp((D + 1) * 1 days + 1 hours);
        vm.prank(honest);
        hook.placeOrder(2 * (D + 1), true, ref0, 100e18);
    }
}
