// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Deploys a hook by CREATE at this contract's first nonce (1), so hooks built from different code land at one address
/// when deployed from the same state. Its own file with no imports: a contract's metadata hash covers every source in its
/// compilation unit, so inside a file that imports the hook this contract's bytecode, and so its CREATE2 address, would
/// change with every edit of the hook.
contract HookDeployer {
    function deploy(bytes memory initcode) external returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(a != address(0), "hook CREATE failed");
    }
}
