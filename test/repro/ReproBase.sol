// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {DevEnv} from "../Offline.t.sol";
import {IERC20T} from "../Base.sol";

/// The audit-repro harness: the offline environment of the existing suite (local PoolManager, stand-in IMD, the test
/// contract as factory, pool (coin, IMD) at tick 0 seeded coin-only over [0, 12000)), plus the readouts the findings
/// need. Every repro test asserts the behaviour the audit report says is correct, so it fails while the defect is present.
abstract contract ReproBase is DevEnv {
    struct Out {
        uint256 out; // the order's fill, in the other currency
        uint256 refund; // back in the order's own currency
        uint256 unfilledFee; // from the UnfilledFeeTaken event, 0 if none was emitted
    }

    /// Claims `id` for `who` and reads back what it paid and charged.
    function _claimOut(Mkt memory m, uint256 id, address who, bool buy) internal returns (Out memory o) {
        address outTok = buy ? address(m.coin) : imd;
        address inTok = buy ? imd : address(m.coin);
        uint256 o0 = IERC20T(outTok).balanceOf(who);
        uint256 i0 = IERC20T(inTok).balanceOf(who);
        vm.recordLogs();
        m.hook.claim(id);
        Vm.Log[] memory lg = vm.getRecordedLogs();
        for (uint256 i; i < lg.length; ++i) {
            if (
                lg[i].emitter == address(m.hook) && lg[i].topics[0] == MarketHoursHook.UnfilledFeeTaken.selector
                    && uint256(lg[i].topics[1]) == id
            ) {
                (, o.unfilledFee) = abi.decode(lg[i].data, (bool, uint256));
            }
        }
        o.out = IERC20T(outTok).balanceOf(who) - o0;
        o.refund = IERC20T(inTok).balanceOf(who) - i0;
    }

    function _residualFill(Mkt memory m, uint256 s) internal view returns (uint64 rf) {
        (,,,,, rf) = m.hook.bells(s);
    }

    /// "ok" or the raw revert data, for an assertion message
    function _why(bool ok, bytes memory e) internal pure returns (string memory) {
        return ok ? "ok" : string.concat("revert data ", vm.toString(e));
    }

    /// A hook from `p` by CREATE2 at a mined flag address, not initialised; zero if the constructor refused `p`.
    function _deployHook(MarketHoursHook.Params memory p, uint256 tag) internal returns (address at) {
        bytes memory init = abi.encodePacked(type(MarketHoursHook).creationCode, abi.encode(p));
        (bytes32 salt,,) = _mineSalt(keccak256(init), tag << 128, false);
        assembly ("memory-safe") {
            at := create2(0, add(init, 0x20), mload(init), salt)
        }
    }
}
