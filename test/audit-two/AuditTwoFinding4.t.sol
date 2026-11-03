// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BellRinger} from "src/BellRinger.sol";
import {ReproBase} from "../repro/ReproBase.sol";
import {IERC20T} from "../Base.sol";
import {setRingRate} from "../RingRate.sol";

/// One transaction: sell IMD into a thin ETH/IMD pool so its price parks far above, ring, buy the IMD back.
contract RewardMover {
    PoolSwapTest internal immutable router;
    BellRinger internal immutable ringer;
    address internal immutable imd;

    constructor(PoolSwapTest r, BellRinger g, address i) {
        router = r;
        ringer = g;
        imd = i;
        IERC20T(i).approve(address(r), type(uint256).max);
    }

    receive() external payable {}

    function run(PoolKey memory k, uint160 parkAt, uint160 back) external {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings(false, false);
        uint256 e0 = address(this).balance;
        router.swap(k, IPoolManager.SwapParams(false, -100e18, parkAt), ts, "");
        uint256 got = address(this).balance - e0;
        ringer.ring{gas: 13_000_000}();
        router.swap{value: got}(k, IPoolManager.SwapParams(true, -int256(got), back), ts, "");
    }
}

/// Audit 2, finding 4: the ring reward is priced at the ETH/IMD pool's live spot, which the ringer moves inside its own
/// transaction. The audit report's pool: native ETH / IMD, fee 1 %, spacing 200, at 100 IMD per ETH, one position
/// [40,000, 60,000) of L = 1e18; the purse holds 10 IMD; the reward rate 1 gwei. An honest opening bell rings first, so a
/// price from a ring before this one exists; the closing bell is then rung honestly or by the mover, from one snapshot.
contract AuditTwoFinding4Test is ReproBase {
    PoolKey internal ek;

    function _ethPool() internal {
        ek = PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 200, IHooks(address(0)));
        manager.initialize(ek, uint160(10 << 96));
        vm.deal(address(this), 100 ether);
        _fundImd(address(this), 1_000e18);
        lp.modifyLiquidity{value: 10 ether}(ek, IPoolManager.ModifyLiquidityParams(40_000, 60_000, 1e18, 0), "");
        _fundImd(address(this), 10e18);
        IERC20T(imd).approve(address(_ringer(mkt)), 10e18);
        _ringer(mkt).topUp(10e18);
        setRingRate(_ringer(mkt), 1 gwei);
    }

    function _paidOf(Vm.Log[] memory lg) internal view returns (uint256 paid) {
        for (uint256 i; i < lg.length; ++i) {
            if (lg[i].emitter == address(_ringer(mkt)) && lg[i].topics[0] == BellRinger.Rewarded.selector) {
                (paid,) = abi.decode(lg[i].data, (uint256, bool));
            }
        }
    }

    function _honestRing(address who) internal returns (uint256 paid) {
        BellRinger r = _ringer(mkt);
        vm.recordLogs();
        vm.prank(who, who);
        r.ring{gas: 13_000_000}();
        paid = _paidOf(vm.getRecordedLogs());
    }

    function _setUpTwoBells() internal returns (uint256 openPaid) {
        _ethPool();
        _at(D, OPEN);
        _nextBlock();
        openPaid = _honestRing(makeAddr("open ringer"));
        _at(D, CLOSE);
        _nextBlock();
    }

    function test_A2F4_rewardNotRaisedByTheRingersOwnSwap() public {
        uint256 openPaid = _setUpTwoBells();
        uint256 snap = vm.snapshotState();
        uint256 honest = _honestRing(makeAddr("close ringer"));
        vm.revertToState(snap);
        RewardMover mv = new RewardMover(router, _ringer(mkt), imd);
        _fundImd(address(mv), 100e18);
        uint256 i0 = IERC20T(imd).balanceOf(address(mv));
        uint256 e0 = address(mv).balance;
        vm.recordLogs();
        vm.prank(address(mv), address(mv));
        mv.run(ek, uint160(100 << 96), uint160(10 << 96));
        uint256 moved = _paidOf(vm.getRecordedLogs());
        console2.log("open (honest) / close honest / close moved reward (wei IMD)", openPaid, honest, moved);
        console2.log("mover IMD delta (wei, signed)", int256(IERC20T(imd).balanceOf(address(mv))) - int256(i0));
        console2.log("mover ETH delta (wei, signed)", int256(address(mv).balance) - int256(e0));
        assertGt(honest, 0, "precondition: the honest close is paid");
        assertLe(moved, honest + honest / 100, "the ringer's own swap must not raise its reward");
    }

    /// CONTROL: the honest closing reward is gas-fair: above zero and below the cap.
    function test_A2F4_control_honestRewardBelowCap() public {
        _setUpTwoBells();
        uint256 honest = _honestRing(makeAddr("close ringer"));
        assertGt(honest, 0);
        assertLt(honest, _ringer(mkt).RING_REWARD_CAP());
    }
}
