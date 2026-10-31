// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title The Market Hours coin
/// @notice A plain ERC-20. The whole supply is minted once, to whoever deploys it, and nothing can mint again. Anyone
///         may burn their own coin, or coin they were approved to spend, and `totalSupply` falls by what was burned.
/// @dev No owner, no pause, no hook into transfers. The deployer is the launch factory, which checks that it holds the
///      whole supply before it seeds the pool; a mint to anyone else would fail that check.
contract MarketHoursCoin is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Destroys `amount` of the caller's coin. The supply falls; nothing is parked at a dead address.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Destroys `amount` of `from`'s coin, within what `from` approved the caller to spend.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
