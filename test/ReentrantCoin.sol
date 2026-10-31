// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IHarvestT {
    function harvest() external;
}

/// A hostile coin for the reentrancy test: when the PoolManager pays the armed hook (the `take` inside the hook's own
/// unlockCallback), it calls `hook.harvest()` and records what happened. Its own file, importing only the ERC-20, so
/// its CREATE2 address does not move with edits of the hook.
contract ReentrantCoin is ERC20 {
    address public target;
    address public manager;
    uint256 public calls;
    bool public harvested;
    bytes public lastError;

    constructor() ERC20("Test Coin", "TEST") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function arm(address target_, address manager_) external {
        (target, manager) = (target_, manager_);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && from == manager && to == target) {
            ++calls;
            try IHarvestT(target).harvest() {
                harvested = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
    }
}
