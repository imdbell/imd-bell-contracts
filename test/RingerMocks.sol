// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IIntake} from "../src/IIntake.sol";

// Stand-ins for the ringer's unit tests: a chore target whose every function can be told to
// succeed, revert, starve, return-bomb, return garbage or call back in; a hook that rings like the real one (once a
// day, at its floor) and records what the ringer looked like when it rang; a PoolManager that answers one storage word;
// and tokens that take a fee on transfer or call back on transfer.

// Chore behaviour, per selector.
uint8 constant OK = 0;
uint8 constant REVERT = 1;
uint8 constant STARVE = 2;
uint8 constant REVERT_BOMB = 3;
uint8 constant RETURN_BOMB = 4;
uint8 constant REENTER = 5;

contract ChoreBox {
    error Boom();

    mapping(bytes4 => uint8) public mode;
    // one slot per selector, so the bookkeeping fits inside the smallest stipend: the gas at entry (bits 0-63), the
    // number of calls (64-95), this box's call order (96-127), the peer box's call count at entry (128-159), and the
    // first argument word's low 96 bits (160-255)
    mapping(bytes4 => uint256) public rec;
    uint256 public total;
    ChoreBox public peer;
    uint256 public bombBytes = 32_000;
    address public reenterTarget;
    bytes public reenterData;

    function setMode(bytes4 sel, uint8 m) external {
        mode[sel] = m;
    }

    function setBomb(uint256 n) external {
        bombBytes = n;
    }

    function setPeer(ChoreBox p) external {
        peer = p;
    }

    function setReenter(address t, bytes calldata data) external {
        reenterTarget = t;
        reenterData = data;
    }

    function gasAtEntry(bytes4 sel) external view returns (uint256) {
        return uint64(rec[sel]);
    }

    function calls(bytes4 sel) external view returns (uint256) {
        return uint32(rec[sel] >> 64);
    }

    function order(bytes4 sel) external view returns (uint256) {
        return uint32(rec[sel] >> 96);
    }

    function peerAt(bytes4 sel) external view returns (uint256) {
        return uint32(rec[sel] >> 128);
    }

    function arg(bytes4 sel) external view returns (uint256) {
        return rec[sel] >> 160;
    }

    fallback() external payable {
        _chore();
    }

    function _chore() internal {
        uint256 g = gasleft();
        bytes4 sel = msg.sig;
        uint8 m = mode[sel];
        if (m == STARVE) {
            uint256 i;
            while (true) ++i;
        }
        uint256 a = msg.data.length >= 36 ? uint96(uint256(bytes32(msg.data[4:36]))) : 0;
        uint256 n = ++total;
        uint256 pc = address(peer) == address(0) ? 0 : peer.total();
        rec[sel] = uint64(g) | (uint256(uint32(rec[sel] >> 64) + 1) << 64) | (n << 96) | (pc << 128) | (a << 160);
        if (m == REVERT) revert Boom();
        if (m == REVERT_BOMB || m == RETURN_BOMB) {
            uint256 nb = bombBytes;
            bool rv = m == REVERT_BOMB;
            assembly ("memory-safe") {
                mstore(0, 0xdeadbeef00000000000000000000000000000000000000000000000000000000)
                if rv { revert(0, nb) }
                return(0, nb)
            }
        }
        if (m == REENTER) {
            (bool ok, bytes memory e) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(e, 0x20), mload(e))
                }
            }
        }
    }
}

/// Rings like the hook: once per book, the gas floor checked first, the caller recorded as the ringer. Its chores are
/// ChoreBox's; `pushBurn` hands the accrual to the executor, which bridges it (less any dust) or leaves it.
contract MockRingHook is ChoreBox {
    error BellAlreadyRung();
    error GasFloor();
    error BelowMinBurn();

    MockERC20 public immutable imdT;
    MockBridgeExecutor public immutable executor;
    mapping(uint256 => bool) public rung;
    uint256 public ringGas; // gas a ring burns, beyond its bookkeeping
    uint256 public floor = 7_000_000;
    address public lastRinger;
    uint256 public ringerPurseAtRing; // the ringer's IMD when the bell rang
    uint256 public callerImdAtRing; // the transaction's sender's IMD when the bell rang
    uint256 public purseFeed; // IMD claimBellPurse pays the ringer
    uint256 public burnAccrued;

    constructor(MockERC20 imd_) {
        imdT = imd_;
        executor = new MockBridgeExecutor(imd_);
    }

    function setRingGas(uint256 g) external {
        ringGas = g;
    }

    function setPurseFeed(uint256 a) external {
        purseFeed = a;
    }

    function setBurnAccrued(uint256 a) external {
        burnAccrued = a;
    }

    function burnExecutor() external view returns (address) {
        return address(executor);
    }

    /// the purse's precondition for a night: the previous close settled (always, here)
    function closeSettled(uint256) external pure returns (bool) {
        return true;
    }

    function ringOpen() external {
        _ring(2 * (block.timestamp / 1 days));
    }

    function ringClose() external {
        _ring(2 * (block.timestamp / 1 days) + 1);
    }

    function _ring(uint256 s) internal {
        if (rung[s]) revert BellAlreadyRung();
        if (gasleft() < floor) revert GasFloor();
        rung[s] = true;
        lastRinger = msg.sender;
        ringerPurseAtRing = imdT.balanceOf(msg.sender);
        callerImdAtRing = imdT.balanceOf(tx.origin);
        uint256 stop = gasleft() > ringGas ? gasleft() - ringGas : 0;
        uint256 i;
        while (gasleft() > stop) ++i;
    }

    /// claimBellPurse pays the ringer what it was told to (the real hook pays its accrual); every other chore is ChoreBox's
    function claimBellPurse() external {
        _chore();
        uint256 a = purseFeed;
        purseFeed = 0;
        if (a > 0) imdT.transfer(msg.sender, a);
    }

    function pushBurn() external payable {
        uint256 a = burnAccrued;
        if (a < 5e18) revert BelowMinBurn();
        burnAccrued = 0;
        imdT.transfer(address(executor), a);
        bool bridged;
        try executor.bridgeToBaseBurnReceiver{value: msg.value}(a, msg.sender) {
            bridged = true;
        } catch {}
        if (!bridged && msg.value > 0) {
            (bool sent,) = msg.sender.call{value: msg.value}("");
            require(sent, "refund");
        }
    }
}

/// Bridges like the network's executor: takes a fee, refunds the excess to `refundTo`, sends the amount on less the
/// bridge's dust below its shared decimals (or a set dust), or refuses.
contract MockBridgeExecutor {
    MockERC20 public immutable imdT;
    uint256 public fee = 0.0002 ether;
    uint256 public dust = 1e12; // the OFT moves whole multiples of 1e12 wei
    bool public refuse;

    constructor(MockERC20 imd_) {
        imdT = imd_;
    }

    function set(uint256 fee_, uint256 dust_, bool refuse_) external {
        (fee, dust, refuse) = (fee_, dust_, refuse_);
    }

    function bridgeToBaseBurnReceiver(uint256 requested, address refundTo) external payable {
        require(!refuse && msg.value >= fee, "fee short");
        uint256 moved = dust == 0 ? requested : requested - requested % dust;
        imdT.transfer(address(0xdEaD), moved);
        if (msg.value > fee) {
            (bool ok,) = refundTo.call{value: msg.value - fee}("");
            require(ok, "refund");
        }
    }
}

/// Answers `extsload(bytes32)` for one slot with a set word; or reverts, or answers short, or starves.
contract MockManager {
    bytes32 public slot;
    bytes32 public word;
    uint8 public how; // 0 answer, 1 revert, 2 short reply, 3 starve

    function set(bytes32 slot_, bytes32 word_, uint8 how_) external {
        (slot, word, how) = (slot_, word_, how_);
    }

    function extsload(bytes32 s) external view returns (bytes32) {
        if (how == 1) revert("no");
        if (how == 2) {
            assembly {
                mstore(0, 1)
                return(0, 16)
            }
        }
        if (how == 3) {
            uint256 i;
            while (true) ++i;
        }
        return s == slot ? word : bytes32(0);
    }
}

/// Keeps 1 % of every transferFrom: a top-up must be credited by what arrived.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 cut = amount / 100;
        super.transferFrom(from, to, amount);
        balanceOf[to] -= cut;
        balanceOf[address(0xFEE)] += cut;
        return true;
    }
}

/// Calls back into a set target on every transfer and records how the call ended.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public data;
    bool public lastOk;
    bytes public lastErr;
    uint256 public attempts;

    constructor() MockERC20("Re", "RE", 18) {}

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (target != address(0)) {
            ++attempts;
            (lastOk, lastErr) = target.call(data);
        }
        return super.transfer(to, amount);
    }
}

/// An Intake that takes the price and then answers with a bomb: `how` 1 returns `size` bytes of garbage, 2 reverts with
/// them; 0 answers an id like a well-behaved one.
contract BombIntake {
    uint8 public how;
    uint256 public size = 100_000;
    uint256 public taken;

    function set(uint8 how_, uint256 size_) external {
        (how, size) = (how_, size_);
    }

    function requestWithFailure(bytes32, bytes calldata, IIntake.Callback calldata, bytes4, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        ++taken;
        uint256 n = size;
        uint8 h = how;
        assembly ("memory-safe") {
            mstore(0, 0xdeadbeef00000000000000000000000000000000000000000000000000000000)
            if eq(h, 1) { return(0, n) }
            if eq(h, 2) { revert(0, n) }
        }
        return keccak256(abi.encode(taken));
    }
}
