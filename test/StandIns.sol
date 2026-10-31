// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../src/IIntake.sol";

interface IERC20SI {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// A stand-in Intake for the offline environment, written from the docs' description: pull the asset, store the callback, and
/// let the writer's completion call `selector(callbackData)` or `onFailure(callbackData)` with 200,000 gas inside a
/// `try`. It also keeps every body it was given, so a test can check what a request carried. The real Intake's
/// behaviour is never assumed from this.
contract StandInIntake is IIntake {
    struct Rec {
        address payer;
        address target;
        bytes4 sel;
        bytes4 onFail;
        bool done;
        bool delivered;
    }

    mapping(bytes32 => Rec) public recs;
    mapping(bytes32 => bytes) public bodyOf;
    mapping(bytes32 => bytes32) public actionOf;
    bytes32[] public ids;
    address public immutable writer;

    constructor(address writer_) {
        writer = writer_;
    }

    function count() external view returns (uint256) {
        return ids.length;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata cb, address asset, uint256 amount)
        external
        payable
        returns (bytes32 id)
    {
        return _take(action, body, cb, bytes4(0), asset, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 onFail,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        return _take(action, body, cb, onFail, asset, amount);
    }

    function _take(bytes32 action, bytes calldata body, Callback calldata cb, bytes4 onFail, address asset, uint256 amount)
        internal
        returns (bytes32 id)
    {
        require(IERC20SI(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        id = keccak256(abi.encode(ids.length + 1, msg.sender, action));
        ids.push(id);
        recs[id] = Rec(msg.sender, cb.target, cb.selector, onFail, false, false);
        bodyOf[id] = body;
        actionOf[id] = action;
    }

    /// The writer's completion: status 0 calls the callback, 1 or 2 the failure function; both with the Intake's gas limit
    /// inside a try, so a reverting callback never blocks the write.
    function complete(bytes32 id, uint8 status, bytes32, string calldata, bytes calldata cbd) external {
        require(msg.sender == writer, "writer only");
        Rec storage r = recs[id];
        require(!r.done, "done");
        r.done = true;
        bytes4 s = status == 0 ? r.sel : r.onFail;
        if (s == bytes4(0)) return;
        (bool ok,) = r.target.call{gas: 200_000}(abi.encodePacked(s, cbd));
        r.delivered = ok;
    }
}

/// A stand-in burn executor for the offline environment: quotes a fixed fee and records what was bridged.
contract StandInBurnExecutor {
    uint256 public constant FEE = 0.0002 ether;
    uint256 public bridged;
    bool public quoteReverts;

    function setQuoteReverts(bool v) external {
        quoteReverts = v;
    }

    function quoteBridgeFee(uint256) external view returns (uint256 nativeFee, uint256 lzTokenFee) {
        require(!quoteReverts, "quote off");
        return (FEE, 0);
    }

    function bridgeToBaseBurnReceiver(uint256 requested, address) external payable {
        require(msg.value >= FEE, "fee short");
        bridged += requested;
    }
}

/// A stand-in for the network's fee settings: the recipient the hook reads at claim time.
contract StandInLaunchFees {
    address public feeRecipient;

    constructor(address r) {
        feeRecipient = r;
    }

    function set(address r) external {
        feeRecipient = r;
    }
}
