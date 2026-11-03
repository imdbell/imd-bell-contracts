// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

interface IERC20W {
    function transferFrom(address, address, uint256) external returns (bool);
}

/// A router whose msgSender() answers one word the test sets (zero, an address, or a word that is no address), so
/// the round-trip rule's reading of the answer can be tested. Exact-input swaps; the caller pays and receives directly.
contract WordRouter is IUnlockCallback {
    IPoolManager internal immutable manager;
    uint256 internal word;
    address internal payer;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function msgSender() external view returns (uint256) {
        return word;
    }

    function swapAnswering(uint256 w, PoolKey memory key, IPoolManager.SwapParams memory p) external {
        (word, payer) = (w, msg.sender);
        manager.unlock(abi.encode(key, p));
        (word, payer) = (0, address(0));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        (PoolKey memory key, IPoolManager.SwapParams memory p) = abi.decode(data, (PoolKey, IPoolManager.SwapParams));
        BalanceDelta d = manager.swap(key, p, "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            manager.sync(c);
            require(IERC20W(Currency.unwrap(c)).transferFrom(payer, address(manager), uint128(-amt)), "pay failed");
            manager.settle();
        } else if (amt > 0) {
            manager.take(c, payer, uint128(amt));
        }
    }
}
