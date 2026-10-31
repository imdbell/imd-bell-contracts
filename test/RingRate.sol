// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BellRinger} from "../src/BellRinger.sol";

Vm constant RR_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// The reward follows block.basefee + TIP_ALLOWANCE, never tx.gasprice. This sets the reward's per-gas rate to exactly
/// `p`: the base fee at `p` less the allowance, and a caller who pays exactly the base fee plus the allowance.
/// Returns the base fee it replaced, for `clearRingRate`.
function setRingRate(BellRinger ringer, uint256 p) returns (uint256 baseFeeBefore) {
    uint256 tip = ringer.TIP_ALLOWANCE();
    require(p >= tip, "setRingRate: a rate below the allowance cannot be set");
    baseFeeBefore = block.basefee;
    RR_VM.fee(p - tip);
    RR_VM.txGasPrice(p);
}

/// Back to the base fee before `setRingRate`, and a zero gas price (a gas price left set is charged to the sender).
function clearRingRate(uint256 baseFeeBefore) {
    RR_VM.fee(baseFeeBefore);
    RR_VM.txGasPrice(0);
}
