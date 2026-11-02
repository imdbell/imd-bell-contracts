// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRingerHook {
    function ringOpen() external;
    function ringClose() external;
    function pushBurn() external payable;
    function burnExecutor() external view returns (address);
    function burnAccrued() external view returns (uint256);
}

interface IRingerToken {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title The bell ringer: whoever rings a bell first is paid from the bell purse
/// @notice `ring()` rings whichever bell the clock says is due, runs that bell's chores, then pays the caller the ring's
///         gas at the base fee plus a fixed tip allowance, half again, in IMD at the ETH/IMD pool's price (nothing if
///         that price cannot be read), at most 3 IMD and at most what the purse holds. An empty purse pays nothing and the bell still rings. A chore that fails
///         is skipped and never stops the bell or the reward. `pushBurnRewarded()` does the same for the hook's burn, at
///         most 0.5 IMD, and only when the burn crossed the bridge. Anyone may top the purse up.
/// @dev Created by the hook in its constructor, so every reference here is fixed by that one deployment. Nobody owns it;
///      there is no withdraw, sweep or setter. IMD leaves only as one reward to the caller of a ring that rang a bell or
///      a push that bridged; ETH passes through `pushBurnRewarded` and nowhere else.
contract BellRinger {
    error NoBellDue();
    error GasShort();
    error Reentrant();
    error TransferFailed();
    error NoEth();
    error BellAlreadyRung();

    /// @notice `caller` rang a bell (`open` says which) and was paid `amount` IMD; 0 when the purse was empty.
    event Rewarded(address indexed caller, uint256 amount, bool open);
    event PushRewarded(address indexed caller, uint256 amount, bool bridged);
    event ToppedUp(address indexed from, uint256 amount);
    /// @notice A chore failed and was skipped: 1 claimFees, 2 harvest, 3 claimSwarmBudget, 4 claimBellPurse,
    ///         5 claimNetworkFees, 6 settle, 7 requestNight; `reason` is the revert's first four bytes (zero when it ran
    ///         out of gas or reverted without data).
    event ChoreSkipped(uint8 indexed chore, bytes4 reason);
    /// @notice The ETH/IMD price read failed, was zero or was out of range, so this reward was 0.
    event NoPrice();

    // the hook's schedule, in UTC seconds into the day
    uint256 internal constant OPEN_BELL = 43200;
    uint256 internal constant CLOSE_BELL = 57600;
    uint256 internal constant CLOSE_DEADLINE = 72000;

    uint256 public constant RING_REWARD_CAP = 3e18;
    uint256 public constant PUSH_REWARD_CAP = 0.5e18;

    // Each chore's gas, about twice the most it was measured to need, so a chore that behaves always fits
    // and one that misbehaves can take no more than this. harvest's is set by its worst case instead: seven storage
    // slots it can write from zero.
    uint256 public constant GAS_CLAIM_FEES = 360_000;
    uint256 public constant GAS_HARVEST = 160_000;
    uint256 public constant GAS_SWARM = 60_000;
    uint256 public constant GAS_PURSE = 80_000;
    uint256 public constant GAS_NETWORK = 80_000;
    uint256 public constant GAS_SETTLE = 80_000;
    uint256 public constant GAS_NIGHT = 760_000;
    uint256 public constant CHORE_GAS_OPEN = GAS_CLAIM_FEES + GAS_HARVEST + GAS_SWARM + GAS_PURSE + GAS_NETWORK;
    uint256 public constant CHORE_GAS_CLOSE = GAS_SETTLE + GAS_NIGHT;

    // The gas a ring or a push costs its caller that the in-call count cannot see: the transaction's own 21,000 and
    // calldata, the dispatch before the count starts, and the price read, payment and event after it ends.
    uint256 public constant OVERHEAD = 60_000;
    uint256 public constant PUSH_OVERHEAD = 60_000;

    /// @notice The priority fee per gas the reward allows on top of the base fee. The reward follows the base fee, which
    ///         the protocol sets, plus this fixed allowance, never the gas price the caller chooses: a caller who tips
    ///         more pays the difference itself. Set from the median of mainnet's per-block median priority fees.
    uint256 public constant TIP_ALLOWANCE = 0.01 gwei;

    // the canonical ETH/IMD pool: native ETH (always currency0), IMD, fee 1 %, spacing 200, no hook
    uint24 internal constant ETH_IMD_FEE = 10_000;
    int24 internal constant ETH_IMD_SPACING = 200;
    // v4's `pools` mapping slot, whose entry's first word is the pool's slot0
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    // a read of one storage word costs about 4,700 gas cold; the PoolManager is fixed, the cap only bounds a surprise
    uint256 internal constant PRICE_READ_GAS = 50_000;
    uint256 internal constant LOCK_SLOT = 0x6d682e72696e676572;

    IRingerHook public immutable hook;
    address public immutable factory;
    address public immutable game;
    address public immutable swarmBudget;
    IRingerToken public immutable imd;
    address public immutable manager;
    uint64 public immutable launchNumber;
    /// @notice The gas the hook requires before it crosses a book; `ring()` requires this plus the bell's chores.
    uint256 public immutable bellGasFloor;
    bytes32 public immutable ethImdPoolId;
    bytes32 internal immutable priceSlot;
    /// @dev The last bell (its book: 2 x day for the open, 2 x day + 1 for the close) whose chores ran here. `ring()`
    ///      only ever serves the bell due now, so one word does the work of a flag per bell.
    uint256 internal choresDone;

    constructor(
        address hook_,
        address factory_,
        address game_,
        address swarmBudget_,
        address imd_,
        address manager_,
        uint64 launchNumber_,
        uint256 bellGasFloor_
    ) {
        hook = IRingerHook(hook_);
        factory = factory_;
        game = game_;
        swarmBudget = swarmBudget_;
        imd = IRingerToken(imd_);
        manager = manager_;
        launchNumber = launchNumber_;
        bellGasFloor = bellGasFloor_;
        // the id is derived here from the key, not taken as an argument, so the pool is the ETH/IMD one with ETH as
        // currency0 by construction and the price below is IMD per ETH whatever is passed in
        bytes32 id = keccak256(abi.encode(address(0), imd_, ETH_IMD_FEE, ETH_IMD_SPACING, address(0)));
        ethImdPoolId = id;
        priceSlot = keccak256(abi.encode(id, POOLS_SLOT));
    }

    modifier nonReentrant() {
        if (_locked()) revert Reentrant();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    /// @notice What the purse holds now.
    function purse() external view returns (uint256) {
        return imd.balanceOf(address(this));
    }

    /// @notice Rings the bell that is due, runs its chores, pays the caller. A bell somebody already rang straight at the
    ///         hook is not rung again, but its chores still run here once and the caller is paid for this call's gas.
    ///         Once a bell's chores have run here a further call reverts, so a second ringer pays gas and is paid
    ///         nothing; a bell the hook refuses to ring (out of gas included) reverts the whole call.
    function ring() external nonReentrant {
        uint256 gasStart = gasleft();
        uint256 t = block.timestamp;
        uint256 tod = t % 1 days;
        uint256 d = t / 1 days;
        bool open = tod >= OPEN_BELL && tod < CLOSE_BELL;
        if (!open && (tod < CLOSE_BELL || tod >= CLOSE_DEADLINE)) revert NoBellDue();
        // the hook checks its floor itself; this one also covers every chore, so no gas limit can ring the bell and
        // leave a chore short of its stipend. The chores' sum is far above 1/64 of the floor, so the 63/64 the hook
        // is passed still clears the hook's own check.
        if (gasStart < bellGasFloor + (open ? CHORE_GAS_OPEN : CHORE_GAS_CLOSE)) revert GasShort();
        // one round of chores and one reward per bell, whether this call rings the bell or somebody rang it straight at
        // the hook first (a direct ring would otherwise make every ring() revert and skip the chores)
        uint256 s = open ? 2 * d : 2 * d + 1;
        if (choresDone == s) revert BellAlreadyRung();
        choresDone = s;
        address h = address(hook);
        uint256 sel = open ? 0x5e552393 : 0xae072a89; // ringOpen() / ringClose()
        assembly ("memory-safe") {
            // bells(uint256): its second word says whether the bell is rung already
            mstore(0, shl(224, 0x507338ec))
            mstore(4, s)
            if iszero(staticcall(gas(), h, 0, 36, 0, 64)) { revert(0, 0) }
            if iszero(mload(32)) {
                // not rung: ring it; any refusal of the hook's, out of gas included, reverts this whole call
                mstore(0, shl(224, sel))
                if iszero(call(gas(), h, 0, 0, 4, 0, 0)) {
                    let e := mload(0x40)
                    returndatacopy(e, 0, returndatasize())
                    revert(e, returndatasize())
                }
            }
        }
        if (open) {
            _chore(1, factory, abi.encodeWithSelector(0xe0d0eac4, launchNumber), GAS_CLAIM_FEES); // claimFees(uint64)
            _chore(2, address(hook), abi.encodeWithSelector(0x4641257d), GAS_HARVEST); // harvest()
            _chore(3, address(hook), abi.encodeWithSelector(0xabb74d4b), GAS_SWARM); // claimSwarmBudget()
            _chore(4, address(hook), abi.encodeWithSelector(0x6b58a30f), GAS_PURSE); // claimBellPurse()
            _chore(5, address(hook), abi.encodeWithSelector(0xe67eccdd), GAS_NETWORK); // claimNetworkFees()
        } else {
            _chore(6, game, abi.encodeWithSelector(0x8df82800, d), GAS_SETTLE); // settle(uint256)
            _chore(7, swarmBudget, abi.encodeWithSelector(0x01e20f20, d + 1), GAS_NIGHT); // requestNight(uint256)
        }
        uint256 paid = _payOut(_reward(gasStart - gasleft() + OVERHEAD, 0, RING_REWARD_CAP));
        emit Rewarded(msg.sender, paid, open);
    }

    /// @notice Forwards the caller's ETH to the hook's burn and returns whatever comes back. Pays a reward only when the
    ///         burn bridged: the executor kept less than it was handed. A bridged burn can leave the bridge's sub-unit
    ///         dust behind, so "kept all of it" is the test for "not bridged", not "kept none of it".
    function pushBurnRewarded() external payable nonReentrant {
        uint256 gasStart = gasleft();
        address ex = hook.burnExecutor();
        uint256 a = hook.burnAccrued();
        uint256 e0 = imd.balanceOf(ex);
        uint256 eth0 = address(this).balance - msg.value;
        hook.pushBurn{value: msg.value}();
        bool bridged = imd.balanceOf(ex) < e0 + a;
        uint256 back = address(this).balance - eth0;
        uint256 paid;
        // the cost includes the bridge fee: the ETH the push kept
        if (bridged) {
            uint256 kept = back < msg.value ? msg.value - back : 0;
            paid = _payOut(_reward(gasStart - gasleft() + PUSH_OVERHEAD, kept, PUSH_REWARD_CAP));
        }
        if (back > 0) {
            (bool sent,) = msg.sender.call{value: back}("");
            if (!sent) revert TransferFailed();
        }
        emit PushRewarded(msg.sender, paid, bridged);
    }

    /// @notice Adds IMD to the purse from the caller (who approved it); the event carries what actually arrived.
    function topUp(uint256 amount) external nonReentrant {
        uint256 b0 = imd.balanceOf(address(this));
        if (!imd.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit ToppedUp(msg.sender, imd.balanceOf(address(this)) - b0);
    }

    /// @dev ETH arrives only inside `pushBurnRewarded`, from the hook (an unbridged burn's fee) or the bridge (its
    ///      refund), and leaves in the same call; anything sent outside it is refused rather than stranded.
    receive() external payable {
        if (!_locked()) revert NoEth();
    }

    /// @dev One chore: a plain call with a fixed gas stipend and no return data copied, so a reverting, starving or
    ///      return-bombing chore costs at most its stipend and can never revert the ring.
    function _chore(uint8 id, address target, bytes memory data, uint256 stipend) internal {
        bool ok;
        bytes4 reason;
        assembly ("memory-safe") {
            ok := call(stipend, target, 0, add(data, 0x20), mload(data), 0, 0)
            if and(iszero(ok), gt(returndatasize(), 3)) {
                returndatacopy(0, 0, 4)
                reason := and(mload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000)
            }
        }
        if (!ok) emit ChoreSkipped(id, reason);
    }

    /// @dev min(cap, 1.5 x (gasUsed x (basefee + TIP_ALLOWANCE) + extraWei) in IMD at the pool's spot). The spot is
    ///      sqrtP^2 / 2^192 IMD per ETH. A failed, zero or out-of-range read pays nothing, with `NoPrice`: without a
    ///      price there is no reward, never the cap. A cost too large to price safely pays the cap.
    function _reward(uint256 gasUsed, uint256 extraWei, uint256 cap) internal returns (uint256) {
        uint256 costWei = gasUsed * (block.basefee + TIP_ALLOWANCE) + extraWei;
        address mgr = manager;
        bytes32 slot = priceSlot;
        bool ok;
        uint256 sp;
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x1e2eaeaf)) // extsload(bytes32)
            mstore(4, slot)
            ok := staticcall(PRICE_READ_GAS, mgr, 0, 36, 0, 32)
            if and(ok, gt(returndatasize(), 31)) { sp := and(mload(0), 0xffffffffffffffffffffffffffffffffffffffff) }
        }
        // a sqrt price at or above 2^128 is a price of 2^64 IMD per ETH or more; past it the product below could overflow
        if (sp == 0 || sp >> 128 != 0) {
            emit NoPrice();
            return 0;
        }
        if (costWei >> 95 != 0) return cap;
        uint256 r = (costWei * 3 / 2) * (sp * sp >> 96) >> 96;
        return r < cap ? r : cap;
    }

    function _payOut(uint256 reward) internal returns (uint256 paid) {
        uint256 held = imd.balanceOf(address(this));
        paid = reward < held ? reward : held;
        if (paid > 0 && !imd.transfer(msg.sender, paid)) revert TransferFailed();
    }

    function _locked() internal view returns (bool l) {
        assembly ("memory-safe") {
            l := tload(LOCK_SLOT)
        }
    }
}
