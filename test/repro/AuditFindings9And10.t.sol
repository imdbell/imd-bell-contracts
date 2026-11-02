// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BellRinger} from "src/BellRinger.sol";
import {ReproBase} from "./ReproBase.sol";
import {IERC20T} from "../Base.sol";

/// Audit finding 9 (info): the ringer pays the cap when the ETH/IMD price read is zero. Audit finding 10 (info): a direct hook ring makes the
/// ringer's ring revert, skipping its chores.
contract AuditFindings9And10Test is ReproBase {
    function _topUp(uint256 a) internal {
        _fundImd(address(this), a);
        IERC20T(imd).approve(address(_ringer(mkt)), a);
        _ringer(mkt).topUp(a);
        assertEq(_ringer(mkt).purse(), a, "harness: purse topped up");
    }

    function _ringPaid(address who) internal returns (bool ok, uint256 paid, bytes memory e) {
        uint256 b0 = IERC20T(imd).balanceOf(who);
        address r = address(_ringer(mkt)); // an external read: resolve it before the prank, which the next call spends
        vm.prank(who, who);
        (ok, e) = r.call{gas: 20_000_000}(abi.encodeCall(BellRinger.ring, ()));
        paid = IERC20T(imd).balanceOf(who) - b0;
    }

    /// Audit finding 9: no ETH/IMD pool on this PoolManager; correct per the audit report's fallback: a zero read does not pay the cap.
    function test_F9_zeroPriceReadDoesNotPayTheCap() public {
        _topUp(10e18);
        vm.fee(1 gwei);
        _at(D, OPEN);
        (bool ok, uint256 paid, bytes memory e) = _ringPaid(makeAddr("ringer"));
        assertTrue(ok, _why(ok, e));
        console2.log("reward with no ETH/IMD pool (wei)", paid);
        assertLt(paid, _ringer(mkt).RING_REWARD_CAP(), "a ring with no ETH/IMD price must not pay the cap");
    }

    /// CONTROL: with the ETH/IMD pool initialised (100 IMD per ETH), the reward follows gas and is below the cap.
    function test_F9_control_pricedRewardBelowCap() public {
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 200, IHooks(address(0)));
        manager.initialize(k, uint160(10 << 96));
        _topUp(10e18);
        vm.fee(1 gwei);
        _at(D, OPEN);
        (bool ok, uint256 paid, bytes memory e) = _ringPaid(makeAddr("ringer"));
        assertTrue(ok, _why(ok, e));
        console2.log("reward at 100 IMD/ETH, 1 gwei (wei)", paid);
        assertGt(paid, 0);
        assertLt(paid, _ringer(mkt).RING_REWARD_CAP());
    }

    /// Audit finding 10: a direct hook.ringOpen() first; correct: the ringer's ring still runs its chores (does not revert).
    function test_F10_ringerStillRunsChoresAfterDirectRing() public {
        _topUp(10e18);
        _at(D, OPEN);
        vm.prank(makeAddr("griefer"));
        mkt.hook.ringOpen();
        uint256 calls0 = claimFeesCalls;
        (bool ok, uint256 paid, bytes memory e) = _ringPaid(makeAddr("ringer"));
        console2.log("ring ok", ok);
        console2.log("paid / claimFees chore calls added", paid, claimFeesCalls - calls0);
        assertTrue(ok, string.concat("the ringer's ring after a direct ring must still run the chores: ", _why(ok, e)));
    }

    /// CONTROL: no direct ring first; ring() rings, runs the claimFees chore and pays.
    function test_F10_control_ringAlone() public {
        // audit finding 9's fix pays nothing without an ETH/IMD price, so this control gets the pool audit finding 9's own control
        // initialises (100 IMD per ETH) for its "paid > 0"
        manager.initialize(
            PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 200, IHooks(address(0))), uint160(10 << 96)
        );
        _topUp(10e18);
        _at(D, OPEN);
        uint256 calls0 = claimFeesCalls;
        (bool ok, uint256 paid, bytes memory e) = _ringPaid(makeAddr("ringer"));
        assertTrue(ok, _why(ok, e));
        assertEq(claimFeesCalls, calls0 + 1, "claimFees chore ran");
        assertGt(paid, 0);
    }
}
