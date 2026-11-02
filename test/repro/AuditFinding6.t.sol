// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MarketHoursHook} from "src/MarketHoursHook.sol";
import {ReproBase} from "./ReproBase.sol";

/// Audit finding 6 (low): the constructor accepts bellPurseBps > 9,000, and then harvest() underflows on any inflow.
contract AuditFinding6Test is ReproBase {
    function _hookWith(uint16 net, uint16 purse, uint256 tag) internal returns (address at) {
        MarketHoursHook.Params memory p = _params(address(_newCoin(tag)));
        (p.networkBps, p.feeWalletBps, p.swarmFeeBps, p.burnBps, p.bellPurseBps) = (net, 0, 0, 0, purse);
        at = _deployHook(p, tag);
    }

    function test_F6_acceptedConfigCanHarvest() public {
        address at = _hookWith(500, 9_500, 0x66);
        if (at == address(0)) return; // the constructor refused: correct
        _fundImd(at, 100e18);
        (bool ok, bytes memory e) = at.call(abi.encodeCall(MarketHoursHook.harvest, ()));
        assertTrue(ok, string.concat("a configuration the constructor accepted must be able to harvest: ", _why(ok, e)));
    }

    /// CONTROL: bellPurseBps 9,000 (SWARM_BPS + purse = 10,000) harvests, everything to swarm and purse, nothing burned.
    function test_F6_control_purse9000Harvests() public {
        address at = _hookWith(1_000, 9_000, 0x67);
        assertTrue(at != address(0), "deployed");
        _fundImd(at, 100e18);
        MarketHoursHook h = MarketHoursHook(at);
        h.harvest();
        console2.log("swarm / purse", h.swarmAccrued(), h.bellPurseAccrued());
        console2.log("burn", h.burnAccrued());
        assertEq(h.swarmAccrued() + h.bellPurseAccrued() + h.burnAccrued(), 100e18);
    }

    /// CONTROL: the deploy script's shares (bellPurseBps 1,000) harvest.
    function test_F6_control_defaultSharesHarvest() public {
        _fundImd(address(mkt.hook), 100e18);
        mkt.hook.harvest();
        assertEq(mkt.hook.burnAccrued(), 80e18);
    }
}
