// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

interface IERC20R {
    function transferFrom(address, address, uint256) external returns (bool);
}

/// A router that exposes `msgSender()` (selector 0xd737d0c7), as the periphery routers do, so the hook's round-trip rule
/// resolves the swapper behind it. Exact-input swaps only; the caller pays and receives directly.
contract MsgSenderRouter is IUnlockCallback {
    IPoolManager internal immutable manager;
    address public msgSender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory p) external {
        msgSender = msg.sender;
        manager.unlock(abi.encode(key, p));
        msgSender = address(0);
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
            require(IERC20R(Currency.unwrap(c)).transferFrom(msgSender, address(manager), uint128(-amt)), "pay failed");
            manager.settle();
        } else if (amt > 0) {
            manager.take(c, msgSender, uint128(amt));
        }
    }
}
