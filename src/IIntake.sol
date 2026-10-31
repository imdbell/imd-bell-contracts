// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The part of the network's Intake a paying contract calls
/// @notice A request names an action, carries a body, and says where the answer goes: a callback target and selector,
///         plus a failure selector on the same target for a refused or unanswered request. The Intake pulls the price
///         in `asset` from the caller, which must have approved it.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}
