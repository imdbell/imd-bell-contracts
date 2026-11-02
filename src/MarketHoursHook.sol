// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BellGame} from "./BellGame.sol";
import {SwarmBudget, IERC20B} from "./SwarmBudget.sol";
import {IIntake} from "./IIntake.sol";
import {BellRinger} from "./BellRinger.sol";

interface IERC20H {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function burn(uint256 amount) external;
}

/// @dev The network's burn executor: quotes the bridge fee and bridges IMD to the chain where it is destroyed.
interface IBurnExecutor {
    function quoteBridgeFee(uint256 requested) external view returns (uint256 nativeFee, uint256 lzTokenFee);
    function bridgeToBaseBurnReceiver(uint256 requested, address refundTo) external payable;
}

interface ILaunchFees {
    function feeRecipient() external view returns (address);
}

/// @title Market Hours: a coin that trades four hours a day
/// @notice While the market is closed anyone may leave a limit order in the next book. At 12:00 UTC the opening bell
///         clears the book at one price; the pool then trades until 16:00 UTC, when the closing bell clears a second
///         book. Fills, refunds and fee shares are all pulled, never pushed; nobody owns the contract and nothing in it
///         can be changed after it is deployed.
/// @dev Buckets are ticks on the 60-tick grid in "IMD per coin" orientation: price(b) = 1.0001^b IMD per coin, so a
///      higher bucket is a dearer coin whichever way the pool sorts. The pool tick is b when IMD is currency1 and -b
///      when IMD is currency0. The hook creates its three companions itself: the game that keeps the sealed guesses and
///      the points, the purse that pays the swarm, and the ringer that pays whoever rings a bell, so all four are fixed
///      to each other from one deployment.
contract MarketHoursHook is IUnlockCallback {
    using StateLibrary for IPoolManager;

    // ── errors ──
    error NotPoolManager();
    error NotFactory();
    error BadPool();
    error AlreadyInitialized();
    error MarketClosed();
    error AwaitingBell();
    error NotEnterable();
    error BadBucket();
    error BelowMinOrder();
    error BookFull();
    error InexactPull();
    error NotOwner();
    error CancelLocked();
    error NotAtBell();
    error BellAlreadyRung();
    error GasFloor();
    error NotClaimable();
    error AlreadyClaimed();
    error ExitClosed();
    error Slippage();
    error BelowMinBurn();
    error Reentrant();
    error NotInUnlock();
    error SwapTooLarge();
    error PriceMoved();
    error RoundTrip();
    error TransferFailed();
    error SharesNotWhole();
    error PoolUnlocked();

    // ── schedule (UTC seconds into the day) ──
    uint256 internal constant OPEN_BELL = 43200;
    uint256 internal constant CLOSE_BELL = 57600;
    uint256 internal constant FREEZE = 600;
    uint256 internal constant NO_CANCEL = 3600;
    uint256 internal constant CLOSE_DEADLINE = 72000;
    /// @notice The thirty minutes after the opening bell whose checkpoints the game scores against.
    uint256 public constant SETTLE_WINDOW = 1800;

    // ── pool and book shape ──
    uint24 internal constant FEE = 12_500;
    int24 internal constant TS = 60;
    int24 internal constant BAND = 200;

    // ── figures ──
    uint256 internal constant BELL_FEE_BPS = 125;
    uint256 internal constant CANCEL_FEE_BPS = 50;
    uint256 internal constant EXIT_PENALTY_BPS = 500;
    /// @dev The smallest order, in IMD at the book's reference; one order of at least this earns one guess ticket.
    uint256 internal constant MIN_ORDER = 0.5e18;
    uint256 internal constant MIN_BURN = 5e18;
    /// @dev The smallest coin burn, so each burn is worth its gas.
    uint256 internal constant MIN_COIN_BURN = 100_000e18;
    /// @dev The band's worst residual plus at least 15 %: a pool with a position at every bucket, and a residual that
    ///      crosses the most the cap allows (RESIDUAL_MAX_BUCKETS: 120 initialised ticks never crossed before, with fee
    ///      growth in both tokens), needs 9,176,237 gas to ring and fill (the sell residual down, measured cold); x 1.15
    ///      is 10,552,673, rounded up to the next 100,000. Below it a bell is refused; above it a residual that still runs
    ///      out of gas (a pool spot outside the band) reverts the bell, never drops the residual.
    uint256 public constant BELL_GAS_FLOOR = 10_600_000;
    /// @dev The most a bell's residual may move the pool, in buckets from the pool's own price at the ring, in the
    ///      residual's direction. It bounds the initialised ticks a residual can cross (one per bucket at most), so no
    ///      set of planted dust positions can make a bell need more gas than one transaction may carry.
    uint256 internal constant RESIDUAL_MAX_BUCKETS = 120;
    /// @dev The cap as divisors of the pool's sqrt price in Q192: R = sqrt(1.0001)^(RESIDUAL_MAX_BUCKETS * 60) in Q96
    ///      (TickMath.getSqrtPriceAtTick(7_200)) takes the price down by the cap, 2^192 / R (rounded down) up by it.
    uint256 internal constant CAP_DOWN = 113_558_011_866_913_733_348_073_426_848;
    uint256 internal constant CAP0 = 1_000e18;
    uint256 internal constant CAP_MAX = 100_000e18;
    /// @dev Of harvested IMD, the swarm's slice (the bell purse takes its own bps too, the rest burns); of harvested
    ///      coin, the slice burned as the coin (the rest goes to the fee wallet).
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant PRIZE_BPS = 5_000;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    /// @dev sqrt(1 - FEE) in Q96, rounded down: floor(sqrt(((1_000_000 - 12_500) << 192) / 1_000_000)). A constant
    ///      rather than computed per residual (Math.sqrt is ~260 B of code the bucket cap needs): the pool's fee can never
    ///      differ from FEE, because beforeInitialize accepts only the pool whose id is _key()'s, and _key() is built
    ///      with FEE, a static fee (no dynamic-fee flag). test_H_feeRootIsTheSqrtOfTheFee checks the figure.
    uint256 internal constant FEE_ROOT_Q96 = 78_731_429_325_869_267_202_663_517_946;
    // transient-storage slots: the reentrancy guard, and the flag that admits unlockCallback
    uint256 internal constant LOCK_SLOT = 0x6d682e6c6f636b;
    uint256 internal constant UNLOCK_SLOT = 0x6d682e756e6c6f636b;

    /// @notice Everything the constructor takes, so one deployment fixes every reference and figure.
    struct Params {
        IPoolManager manager;
        address factory;
        address imd;
        address coin;
        address feeWallet;
        address burnExecutor;
        address launchFees;
        address intake;
        /// @dev The most a block's price may move from its first swap, in basis points.
        uint256 maxBlockMoveBps;
        /// @dev The most one swap may be worth, in IMD.
        uint256 maxSwapImd;
        /// @dev The bell fee's five shares, in basis points of the fee; they must sum to 10,000.
        uint16 networkBps;
        uint16 feeWalletBps;
        uint16 swarmFeeBps;
        uint16 burnBps;
        /// @dev The bell purse's share; the same figure is its slice of harvested IMD.
        uint16 bellPurseBps;
        /// @dev The launch's number at the factory, which the ringer's opening chore claims the pool's fees by.
        uint64 launchNumber;
    }

    IPoolManager public immutable manager;
    address public immutable factory;
    address public immutable imd;
    address public immutable coin;
    address public immutable feeWallet;
    address public immutable burnExecutor;
    address public immutable launchFees;
    /// @notice The game that keeps the sealed guesses and the points, created by this hook. It holds no tokens.
    address public immutable game;
    /// @notice The purse the swarm's slice is paid to, created by this hook.
    address public immutable swarmBudget;
    /// @notice The bell ringer, created by this hook; `claimBellPurse` pays it the bell purse's slice.
    address public immutable bellPurse;
    uint256 public immutable maxBlockMoveBps;
    uint256 public immutable maxSwapImd;
    uint16 public immutable networkBps;
    uint16 public immutable feeWalletBps;
    uint16 public immutable swarmFeeBps;
    uint16 public immutable burnBps;
    uint16 public immutable bellPurseBps;
    bool internal immutable imdIs0;
    uint256 public immutable d0;
    bytes32 internal immutable poolId;

    struct Order {
        address owner;
        uint40 s;
        bool buy;
        bool claimed;
        bool cancelled;
        int24 bucket;
        uint256 amount;
    }

    struct Bell {
        int24 pStar;
        bool rung;
        bool buyHeavy;
        uint64 innerFill;
        uint64 marginalFill;
        uint64 residualFill;
    }

    /// @dev The charge side of a bell's ratios. `Bell` keeps the payout ratios, rounded down; a charge uses the same
    ///      ratio rounded up: `roundUp` bit 0 / bit 1 say the inner / marginal fill had a remainder (so its ceiling is
    ///      one more), bit 2 that the residual stopped at RESIDUAL_MAX_BUCKETS, and `residualUp` is the residual's charge
    ///      ratio, rounded up.
    struct Charge {
        uint8 roundUp;
        uint64 residualUp;
    }

    /// @dev One slot: the breaker's per-block checkpoint and the counters behind the zero-match reference.
    struct Checkpoint {
        uint32 blockNumber;
        uint160 sqrtPriceX96;
        int48 tickSum;
        uint16 tickCount;
    }

    /// @dev One slot: the settle window of the day whose open rang last, the thirty minutes from the bell's own time.
    ///      The first checkpoint at or after the window's end copies the counters in and freezes them, so nobody can
    ///      pick the window by picking a time.
    struct Window {
        uint24 day;
        uint32 openedAt;
        int48 tickSum;
        uint16 tickCount;
        bool frozen;
    }

    event OrderPlaced(uint256 indexed orderId, address indexed owner, uint256 indexed s, bool buy, int24 bucket, uint256 amount);
    event OrderCancelled(uint256 indexed orderId, uint256 fee);
    event Claimed(uint256 indexed orderId, address indexed owner, uint256 out, uint256 refund);
    event FeeTaken(uint256 indexed orderId, uint256 amount);
    /// @notice The unfilled-order fee: an order whose bucket the bell did not reach pays it at claim, in its own currency.
    event UnfilledFeeTaken(uint256 indexed orderId, bool buy, uint256 amount);
    event Exited(address indexed who, uint256 coinIn, uint256 imdOut, uint256 penalty);
    event Harvested(uint256 imd, uint256 coin);
    event BurnPushed(uint256 amount, bool bridged);
    event CoinBurned(uint256 amount);
    event BellRung(uint256 indexed s, int24 pStar, uint256 matchedTok, uint256 residualFilled, address ringer);
    event DustSeeded(address indexed payer, uint256 imd, uint256 coin);
    event SwarmBudgetPaid(uint256 sent, uint256 toBurn);
    event BellPursePaid(uint256 sent);

    bool public initialized;
    /// @notice The reference of the book open for entry (see referenceOf). The name is kept from when it was the last
    ///         clearing price; it is now the pool's own price, set at initialisation and by each bell before its residual.
    int24 public lastCleared;
    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => mapping(int24 => uint256)) public buyImd;
    mapping(uint256 => mapping(int24 => uint256)) public sellTok;
    /// @notice Per book, the orders' counted amounts (IMD weighted by distance from the reference) against the cap.
    mapping(uint256 => uint256) public bookImdTotal;
    /// @dev What each order counted toward its book's cap when placed; a cancel takes back exactly this.
    mapping(uint256 => uint256) internal countedOf;
    mapping(uint256 => Bell) public bells;
    mapping(uint256 => Charge) public charges;
    Checkpoint public checkpoint;
    Window public window;
    mapping(address => uint256) public lastSwap;

    uint256 public burnAccrued;
    uint256 public coinBurnAccrued;
    uint256 public networkAccrued;
    uint256 public feeWalletImdAccrued;
    uint256 public feeWalletCoinAccrued;
    uint256 public swarmAccrued;
    uint256 public bellPurseAccrued;
    uint256 public dustImd;
    uint256 public dustCoin;
    uint256 public imdAccounted;
    uint256 public coinAccounted;
    // the dust reserve, inside imdAccounted / coinAccounted so the claims draw on it; never burned, never harvested,
    // never decremented (what is left stays in the hook)
    uint256 public reserveImd;
    uint256 public reserveCoin;

    constructor(Params memory p) {
        // the purse also takes bellPurseBps of harvested IMD beside the swarm's slice, so those two may not pass the whole
        // (else harvest() underflows on any inflow)
        if (
            uint256(p.networkBps) + p.feeWalletBps + p.swarmFeeBps + p.burnBps + p.bellPurseBps != 10_000
                || SWARM_BPS + p.bellPurseBps > 10_000
        ) {
            revert SharesNotWhole();
        }
        manager = p.manager;
        factory = p.factory;
        imd = p.imd;
        coin = p.coin;
        feeWallet = p.feeWallet;
        burnExecutor = p.burnExecutor;
        launchFees = p.launchFees;
        maxBlockMoveBps = p.maxBlockMoveBps;
        maxSwapImd = p.maxSwapImd;
        networkBps = p.networkBps;
        feeWalletBps = p.feeWalletBps;
        swarmFeeBps = p.swarmFeeBps;
        burnBps = p.burnBps;
        bellPurseBps = p.bellPurseBps;
        imdIs0 = p.imd < p.coin;
        d0 = block.timestamp / 1 days;
        poolId = PoolId.unwrap(PoolIdLibrary.toId(_key()));
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // the companions are created here, by this hook, so their addresses follow from this one and nothing has to be
        // predicted or set afterwards
        swarmBudget = address(new SwarmBudget(IERC20B(p.imd), IIntake(p.intake), address(this)));
        game = address(new BellGame(address(this), p.imd < p.coin));
        // the ringer last: it is handed the game and the purse, and its address is the one the purse's slice is paid to
        bellPurse = address(
            new BellRinger(address(this), p.factory, game, swarmBudget, p.imd, address(p.manager), p.launchNumber, BELL_GAS_FLOOR)
        );
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    // ── book ──
    function placeOrder(uint256 s, bool buy, int24 bucket, uint256 amount)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (!_enterable(s)) revert NotEnterable();
        int24 ref = lastCleared;
        if (bucket % TS != 0 || bucket > ref + BAND * TS || bucket < ref - BAND * TS) revert BadBucket();
        uint256 imdValue = buy ? amount : _coinToImd(amount, _sqrtAt(ref));
        if (imdValue < MIN_ORDER) revert BelowMinOrder();
        // the cap counts an order by its distance from the reference: in full at it, falling linearly to a tenth at the
        // band's edge, (40,000 - 3 x |bucket - ref|) / 40,000 with the distance in ticks (12,000 at the edge), so one far
        // order that will not trade cannot fill the book
        uint256 counted;
        unchecked {
            // |bucket - ref| <= 12,000 after the band check: no wrap
            counted = imdValue * (40_000 - 3 * uint256(int256(bucket > ref ? bucket - ref : ref - bucket))) / 40_000;
        }
        uint256 total = bookImdTotal[s] + counted;
        if (total > depositCap()) revert BookFull();
        bookImdTotal[s] = total;
        _pull(buy ? imd : coin, amount);
        // a bucket's buy total is the sum of its orders' own nets, so the scan's demand and the residual it offers are
        // exactly the sum of what the claims will charge against (a bucket-level net would count up to a wei per order
        // that no order's claim covers)
        if (buy) buyImd[s][bucket] += _net(amount);
        else sellTok[s][bucket] += amount;
        orderId = nextOrderId++;
        orders[orderId] = Order(msg.sender, uint40(s), buy, false, false, bucket, amount);
        countedOf[orderId] = counted;
        emit OrderPlaced(orderId, msg.sender, s, buy, bucket, amount);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.owner != msg.sender) revert NotOwner();
        if (o.claimed || !_cancellable(o.s)) revert CancelLocked();
        o.claimed = true;
        o.cancelled = true;
        uint256 a = o.amount;
        uint256 fee = _divUp(a * CANCEL_FEE_BPS, 10_000);
        bookImdTotal[o.s] -= countedOf[orderId]; // exactly what the order counted when placed, never re-valued
        if (o.buy) {
            buyImd[o.s][o.bucket] -= _net(a);
            burnAccrued += fee;
            _pay(imd, msg.sender, a - fee);
        } else {
            sellTok[o.s][o.bucket] -= a;
            coinBurnAccrued += fee; // burned as the coin, never sold
            _pay(coin, msg.sender, a - fee);
        }
        emit OrderCancelled(orderId, fee);
    }

    /// @dev Pays the order's owner: the fill at P* (the bell fee on book-matched volume only) plus the refund of the
    ///      unfilled remainder, less the unfilled-order fee on every unfilled part except the marginal bucket's pro-rata
    ///      remainder; the whole escrow if the book's bell never rang by its deadline.
    function claim(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.owner == address(0)) revert NotClaimable();
        if (o.claimed) revert AlreadyClaimed();
        uint256 s = o.s;
        if (!bells[s].rung && block.timestamp < (s / 2) * 1 days + (s & 1 == 0 ? CLOSE_BELL : CLOSE_DEADLINE)) {
            revert NotClaimable();
        }
        (uint256 out, uint256 refund, uint256 fee, uint256 unfilledFee,) = _outcome(o);
        if (fee > 0) _splitFee(orderId, fee);
        if (unfilledFee > 0) {
            if (o.buy) burnAccrued += unfilledFee;
            else coinBurnAccrued += unfilledFee; // burned as the coin, never sold
            emit UnfilledFeeTaken(orderId, o.buy, unfilledFee);
        }
        o.claimed = true;
        if (out > 0) _pay(o.buy ? coin : imd, o.owner, out);
        if (refund > 0) _pay(o.buy ? imd : coin, o.owner, refund);
        emit Claimed(orderId, o.owner, out, refund);
    }

    /// @dev What a claim of `o` pays and charges, read from its bell alone, so a view gives the same answer before the
    ///      claim as the claim itself: `out` and `refund` to the owner, the bell fee, the unfilled-order fee and the IMD
    ///      worth of what filled. An unrung bell refunds the whole escrow. After a rung bell every unfilled part of an
    ///      order pays the cancel fee, rounded up, in its own currency: all of an order the bell did not reach, and what
    ///      neither the book nor the pool filled of one it did reach (a one-sided or zero-match book included). The one
    ///      exception is the marginal bucket's pro-rata remainder: an order at P* on the heavier side, when the book
    ///      rationed that bucket (a marginal fill above zero), gets its remainder back whole; so does every reached order
    ///      on the heavier side when the residual stopped at RESIDUAL_MAX_BUCKETS. The fee's base is the
    ///      unfilled share of the escrow, so an order that filled nothing pays on all of it, bell-fee headroom included.
    function _outcome(Order memory o)
        internal
        view
        returns (uint256 out, uint256 refund, uint256 fee, uint256 unfilledFee, bool paid)
    {
        uint256 s = o.s;
        Bell memory bl = bells[s];
        uint256 a = o.amount;
        refund = a;
        if (!bl.rung) return (0, a, 0, 0, false);
        if (o.buy ? o.bucket >= bl.pStar : o.bucket <= bl.pStar) {
            uint160 sp = _sqrtAt(bl.pStar);
            bool rationed; // the marginal bucket's pro-rata remainder, exempt from the unfilled-order fee
            uint256 net = o.buy ? _net(a) : a; // what the scan counted as this order's demand
            // per currency, every payout rounds down and every charge rounds up. `bookIn` / `resIn` are charged in the
            // order's own currency (ratio rounded up); `bookOut` / `resOut` are the same legs as payout bases (ratio
            // rounded down), converted at P* rounding down. The lighter side fills exactly.
            uint256 bookIn = net;
            uint256 bookOut = net;
            uint256 resIn;
            uint256 resOut;
            uint256 filledImd;
            if (o.buy == bl.buyHeavy) {
                Charge memory ch = charges[s];
                bool marg = o.bucket == bl.pStar;
                // the book rationed this order: the marginal bucket pro rata, or every inner order when the book filled
                // them only in part (an inner fill above zero and below one); either way its remainder comes back whole
                rationed = (marg ? bl.marginalFill > 0 : bl.innerFill > 0 && bl.innerFill < ONE) || ch.roundUp > 3;
                uint256 f = marg ? bl.marginalFill : bl.innerFill;
                bookIn = FullMath.mulDivRoundingUp(net, f + ((ch.roundUp >> (marg ? 1 : 0)) & 1), ONE);
                bookOut = net * f / ONE;
                // the residual share's base is what the charged book left: these sum to at most what the ring offered
                // the pool, so the shares sum to at most what it filled (the filled base, never the larger unfilled one)
                uint256 u = net - bookIn;
                resIn = FullMath.mulDivRoundingUp(u, ch.residualUp, ONE);
                resOut = u * bl.residualFill / ONE;
            }
            refund = a - bookIn - resIn;
            if (o.buy) {
                // the fee is IMD on top of the book fill, never taken out of it before the IMD -> coin conversion.
                // bookIn + resIn <= net and net + fee <= a, so the refund cannot underflow.
                fee = _divUp(bookIn * BELL_FEE_BPS, 10_000);
                out = _imdToCoin(bookOut, sp) + _imdToCoin(resOut, sp);
                refund -= fee;
                filledImd = bookIn + resIn;
            } else {
                uint256 gross = _coinToImd(bookOut, sp);
                fee = _divUp(gross * BELL_FEE_BPS, 10_000);
                out = gross - fee + _coinToImd(resOut, sp);
                filledImd = _coinToImd(bookIn + resIn, sp);
            }
            if (!rationed && bookIn + resIn < net) {
                // the unfilled share of the escrow; capped by the refund, so a wei-sized base cannot underflow it
                unfilledFee = _divUp(FullMath.mulDiv(a, net - bookIn - resIn, net) * CANCEL_FEE_BPS, 10_000);
                if (unfilledFee > refund) unfilledFee = refund;
                refund -= unfilledFee;
            }
            // the ticket: paid by the unfilled-order fee, by a fill of at least the smallest order, or by filling whole
            // whatever the order's size (a buy's whole fill is its net, below MIN_ORDER for the smallest buys); a buy
            // and a sell alike
            paid = unfilledFee > 0 || filledImd >= MIN_ORDER || bookIn + resIn >= net;
        } else {
            unfilledFee = _divUp(a * CANCEL_FEE_BPS, 10_000);
            refund = a - unfilledFee;
            paid = true; // the unfilled-order fee
        }
    }

    /// @dev The bell fee five ways; the burn takes the remainder so the five parts are exactly the fee.
    function _splitFee(uint256 orderId, uint256 fee) internal {
        uint256 n = fee * networkBps / 10_000;
        uint256 w = fee * feeWalletBps / 10_000;
        uint256 sw = fee * swarmFeeBps / 10_000;
        uint256 bp = fee * bellPurseBps / 10_000;
        networkAccrued += n;
        feeWalletImdAccrued += w;
        swarmAccrued += sw;
        bellPurseAccrued += bp;
        burnAccrued += fee - n - w - sw - bp;
        emit FeeTaken(orderId, fee);
    }

    // ── bells ──
    function ringOpen() external nonReentrant {
        uint256 t = block.timestamp;
        uint256 tod = t % 1 days;
        if (tod < OPEN_BELL || tod >= CLOSE_BELL) revert NotAtBell();
        _ring(2 * (t / 1 days));
    }

    function ringClose() external nonReentrant {
        uint256 t = block.timestamp;
        uint256 tod = t % 1 days;
        if (tod < CLOSE_BELL || tod >= CLOSE_DEADLINE) revert NotAtBell();
        _ring(2 * (t / 1 days) + 1);
    }

    function indicativePrice(uint256 s)
        external
        view
        returns (int24 bucket, uint256 matchedTok, bool residualIsSell, uint256 residualTok)
    {
        Scan memory r = _scan(s);
        uint256 d = _imdToCoin(r.bCum, _sqrtAt(r.p));
        return (r.p, r.matched, r.sCum > d, r.sCum > d ? r.sCum - d : d - r.sCum);
    }

    /// @notice The reference of the book open for entry, the band's centre: the pool's own price at the bell that opened
    ///         the book's entry window (at initialisation for the first book), fixed for the whole window; never a
    ///         clearing price, so a self-matched pair can move one bell's P* inside the band but never the next band.
    function referenceOf(uint256) public view returns (int24) {
        return lastCleared;
    }

    // ── the views the game reads ──
    function orderInfo(uint256 orderId)
        external
        view
        returns (address owner, uint256 s, bool buy, int24 bucket, uint256 amount)
    {
        Order memory o = orders[orderId];
        return (o.owner, o.s, o.buy, o.bucket, o.amount);
    }

    /// @notice Whether `orderId` paid for its guess ticket: it was cancelled (and paid the cancel fee), or its bell rang
    ///         and it filled whole (whatever its size), filled at least the smallest order's worth in IMD, or its claim
    ///         charges the unfilled-order fee (whenever it is made). Read from the order and its bell, never from
    ///         whether the claim has happened yet.
    function ticketPaid(uint256 orderId) external view returns (bool) {
        Order memory o = orders[orderId];
        if (o.cancelled) return true;
        if (!bells[o.s].rung) return false;
        (,,,, bool paid) = _outcome(o);
        return paid;
    }

    /// @notice Today's settle window: the frozen counters once a checkpoint has frozen them, the live counters until
    ///         then, the time the opening bell rang (the window runs `SETTLE_WINDOW` seconds from it), and zeros before
    ///         today's open rang.
    function sessionMean() external view returns (int256 tickSum, uint256 tickCount, uint256 openedAt, bool frozen) {
        Window memory w = window;
        if (w.day != uint24(block.timestamp / 1 days)) return (0, 0, 0, false);
        if (w.frozen) return (w.tickSum, w.tickCount, w.openedAt, true);
        Checkpoint memory cp = checkpoint;
        return (cp.tickSum, cp.tickCount, w.openedAt, false);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key();
    }

    /// @dev The clearing scan over the band around reference(s). O(BAND), independent of order count.
    struct Scan {
        int24 p; // chosen bucket
        uint256 matched; // matched volume at p, coin
        uint256 sCum; // S(p): sells with limit <= p, coin
        uint256 bCum; // buys with limit >= p, IMD
        uint256 sellAt; // sells at exactly p, coin
        uint256 buyAt; // buys at exactly p, IMD
        int24 a; // the pool's own price as a bucket, read before any residual: the next book's reference
    }

    function _scan(uint256 s) internal view returns (Scan memory r) {
        int24 lo = referenceOf(s) - BAND * TS;
        uint256 n = uint256(uint24(2 * BAND + 1));
        uint256[] memory S = new uint256[](n);
        uint256[] memory B = new uint256[](n);
        uint256 acc;
        for (uint256 i; i < n; ++i) {
            int24 b = lo + int24(int256(i)) * TS;
            acc += sellTok[s][b];
            S[i] = acc;
            B[i] = buyImd[s][b]; // already the orders' nets (the bell fee sits on top in escrow)
        }
        acc = 0;
        for (uint256 i = n; i > 0; --i) {
            acc += B[i - 1];
            B[i - 1] = acc;
        }
        uint256 best;
        uint256 bestImb = type(uint256).max;
        uint256 bestDist = type(uint256).max;
        uint256 bi = uint256(uint24(BAND));
        for (uint256 i; i < n; ++i) {
            if (S[i] == 0 || B[i] == 0) continue;
            uint256 d = _imdToCoin(B[i], _sqrtAt(lo + int24(int256(i)) * TS));
            uint256 m = S[i] < d ? S[i] : d;
            uint256 imb = S[i] > d ? S[i] - d : d - S[i];
            uint256 dist = i > uint256(uint24(BAND)) ? i - uint256(uint24(BAND)) : uint256(uint24(BAND)) - i;
            // tie-breaks: larger match, then smaller imbalance, then nearer the reference, then the lower bucket
            if (m > best || (m == best && (imb < bestImb || (imb == bestImb && dist < bestDist)))) {
                (best, bestImb, bestDist, bi) = (m, imb, dist, i);
            }
        }
        {
            // the pool's own price, from what the breaker already keeps: the session's checkpoint mean when the session
            // traded (one sample per block, so no one block moves it far), else the last checkpoint's price (the start of
            // the last block that traded through the pool; the hook's own exits and residuals never set it), else, with
            // no checkpoint ever, the reference as it stands
            Checkpoint memory cp = checkpoint;
            r.a = lastCleared;
            if (cp.tickCount > 0 || cp.sqrtPriceX96 != 0) {
                int256 t = cp.tickCount > 0
                    ? int256(cp.tickSum) / int256(uint256(cp.tickCount))
                    : int256(TickMath.getTickAtSqrtPrice(cp.sqrtPriceX96));
                // held where its whole band is a valid price (the grid's last bucket is 887,220), so the next book and its
                // bell can always be priced
                if (t > 875_220) t = 875_220;
                if (t < -875_220) t = -875_220;
                r.a = _nearestBucket(imdIs0 ? -t : t);
            }
        }
        if (best == 0) {
            // zero matches: the pool's own price, held inside the band
            int256 j = (int256(r.a) - int256(lo)) / 60;
            bi = j < 0 ? 0 : j >= int256(n) ? n - 1 : uint256(j);
        }
        r.p = lo + int24(int256(bi)) * TS;
        r.matched = best;
        r.sCum = S[bi];
        r.bCum = B[bi];
        r.sellAt = S[bi] - (bi > 0 ? S[bi - 1] : 0);
        r.buyAt = B[bi] - (bi + 1 < n ? B[bi + 1] : 0);
    }

    /// @dev One code path for both bells. The cross is plain code; the residual swap runs in the hook's own unlock, and
    ///      only the pool's own refusal inside it (see unlockCallback) leaves a residual unfilled: any other failure, out
    ///      of gas included, reverts the bell, so a bell never goes final with its residual dropped.
    function _ring(uint256 s) internal {
        Bell storage bl = bells[s];
        if (bl.rung) revert BellAlreadyRung();
        // rung from inside somebody else's unlock, a bell could not run its residual, and a swap after it in that same
        // unlock would trade before the residual: refused, residual or not. exttload(bytes32) of the manager's own lock
        // flag (v4's Lock.IS_UNLOCKED_SLOT).
        if (_managerWord(0xf135baaa, 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23) != 0) {
            revert PoolUnlocked();
        }
        if (gasleft() < BELL_GAS_FLOOR) revert GasFloor();
        Scan memory r = _scan(s);
        uint160 sp = _sqrtAt(r.p);
        bool buyHeavy = _imdToCoin(r.bCum, sp) > r.sCum;
        uint64 inner;
        uint64 marg;
        Charge memory ch;
        uint256 resIn;
        if (buyHeavy) {
            uint256 need = _coinToImd(r.matched, sp); // IMD the buyers pay for the matched coin
            (inner, marg, ch.roundUp) = _fills(need, r.bCum - r.buyAt, r.buyAt);
            resIn = r.bCum > need ? r.bCum - need : 0;
        } else {
            (inner, marg, ch.roundUp) = _fills(r.matched, r.sCum - r.sellAt, r.sellAt);
            resIn = r.sCum - r.matched;
        }
        bl.pStar = r.p;
        bl.rung = true;
        bl.buyHeavy = buyHeavy;
        bl.innerFill = inner;
        bl.marginalFill = marg;
        lastCleared = r.a; // the next book's reference: the pool's own price, never this bell's P*
        _windowAtBell(s);
        (checkpoint.tickSum, checkpoint.tickCount) = (0, 0);
        uint256 filled;
        if (resIn > 0) {
            // the heavier side's remainder through the curve, never past price(P*) with the pool's fee included
            _tset(UNLOCK_SLOT, 1);
            // no `try` here: an unlock that fails (a manager already unlocked, a failed settle, too little gas) reverts the
            // bell instead of finalising it with its residual dropped; the pool's own refusal comes back as (0, 0)
            (uint256 spent, uint256 got) =
                abi.decode(manager.unlock(abi.encode(buyHeavy, resIn, true, r.p)), (uint256, uint256));
            {
                // `pay` is the payout base in the rationed side's own currency, `charge` the charge base
                uint256 pay;
                uint256 charge;
                if (buyHeavy) {
                    pay = _coinToImd(got, sp); // the coin bought, at exactly P*: what the residual buyers are paid
                    if (pay > resIn) pay = resIn;
                    charge = pay > spent ? pay : spent; // what they are charged in all; never less than the hook spent
                    burnAccrued += charge - spent; // the pool's price improvement, in IMD
                    coinBurnAccrued += got - _imdToCoin(pay, sp); // and the coin it bought beyond what the buyers are paid
                    filled = pay;
                } else {
                    pay = _imdToCoin(got, sp); // the coin whose P* value the IMD received covers
                    if (pay > spent) pay = spent;
                    charge = spent; // the coin the hook sold
                    burnAccrued += got - _coinToImd(pay, sp);
                    filled = spent;
                }
                bl.residualFill = uint64(pay * ONE / resIn); // payout ratio: rounds down
                ch.residualUp = uint64(FullMath.mulDivRoundingUp(charge, ONE, resIn)); // charge ratio: rounds up
            }
            // bit 2: the hook's own bucket cap was the residual's nearer limit, so what it left unfilled is the cap's
            // doing, not the market's, and comes back without the unfilled-order fee (see _outcome); a residual that
            // filled whole leaves nothing for the flag to waive
            ch.roundUp |= uint8(_tget(UNLOCK_SLOT) & 4);
            _tset(UNLOCK_SLOT, 0);
        }
        charges[s] = ch;
        emit BellRung(s, r.p, r.matched, filled, msg.sender);
    }

    /// @dev The opening bell starts the day's settle window; the closing bell freezes it with the live counters if no
    ///      checkpoint did, so a settle after the close still reads the window and not a later day's.
    function _windowAtBell(uint256 s) internal {
        if (s & 1 == 0) {
            window = Window(uint24(s / 2), uint32(block.timestamp), 0, 0, false);
            return;
        }
        Window memory w = window;
        if (w.day == uint24(s / 2) && !w.frozen) {
            w.tickSum = checkpoint.tickSum;
            w.tickCount = checkpoint.tickCount;
            w.frozen = true;
            window = w;
        }
    }

    /// @dev Book fill ratios for the heavier side: `need` of it is matched; strictly-inside orders first, then the
    ///      marginal bucket pro rata by size. Each ratio rounds down (the payout ratio); `up` flags a remainder (bit 0
    ///      inner, bit 1 marginal), so the charge ratio is that ratio plus one.
    function _fills(uint256 need, uint256 innerAmt, uint256 margAmt)
        internal
        pure
        returns (uint64 inner, uint64 marg, uint8 up)
    {
        if (need >= innerAmt) {
            inner = uint64(ONE);
            uint256 u = need - innerAmt;
            if (margAmt > 0) {
                uint256 x = (u < margAmt ? u : margAmt) * ONE;
                marg = uint64(x / margAmt);
                if (x % margAmt != 0) up = 2;
            }
        } else {
            inner = uint64(need * ONE / innerAmt);
            if ((need * ONE) % innerAmt != 0) up = 1;
        }
    }

    /// @dev cap(d) = min(CAP0 * 2^((d - d0) / 7), CAP_MAX), an immutable weekly doubling from launch day.
    function depositCap() public view returns (uint256) {
        uint256 w = (block.timestamp / 1 days - d0) / 7;
        if (w >= 64) return CAP_MAX;
        uint256 c = CAP0 << w;
        return c > CAP_MAX ? CAP_MAX : c;
    }

    // ── windows ──
    function closeSettled(uint256 d) public view returns (bool) {
        return bells[2 * d + 1].rung || block.timestamp >= d * 1 days + CLOSE_DEADLINE;
    }

    /// @dev Book 2d: from closeSettled(d-1) to 11:50 of d. Book 2d+1: from ringOpen to 15:50 of d.
    function _enterable(uint256 s) internal view returns (bool) {
        // no book before the pool has a price: placeOrder (NotEnterable) and cancelOrder (CancelLocked) both refuse, so
        // no order is ever valued at a reference that initialisation then moves
        if (!initialized) return false;
        uint256 t = block.timestamp;
        uint256 d = t / 1 days;
        uint256 tod = t % 1 days;
        uint256 sd = s / 2;
        if (s & 1 == 1) return sd == d && bells[s - 1].rung && tod < CLOSE_BELL - FREEZE;
        if (sd == d) return tod < OPEN_BELL - FREEZE && closeSettled(d - 1);
        return sd == d + 1 && closeSettled(d);
    }

    /// @dev Enterable and before the no-cancel hour: 10:50 for book 2d, 14:50 for book 2d+1.
    function _cancellable(uint256 s) internal view returns (bool) {
        if (!_enterable(s)) return false;
        uint256 t = block.timestamp;
        uint256 tod = t % 1 days;
        if (s & 1 == 1) return tod < CLOSE_BELL - FREEZE - NO_CANCEL;
        return s / 2 != t / 1 days || tod < OPEN_BELL - FREEZE - NO_CANCEL;
    }

    // ── token movement: every pull is measured, every flow is accounted ──
    function _pull(address token, uint256 amount) internal {
        uint256 b0 = IERC20H(token).balanceOf(address(this));
        if (!IERC20H(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (IERC20H(token).balanceOf(address(this)) - b0 != amount) revert InexactPull();
        if (token == imd) imdAccounted += amount;
        else coinAccounted += amount;
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (token == imd) imdAccounted -= amount;
        else coinAccounted -= amount;
        if (!IERC20H(token).transfer(to, amount)) revert TransferFailed();
    }

    /// @dev The part of a buy escrow that is demand, the rest covering the bell fee charged on top: x / (1 + fee),
    ///      rounded down so the book never counts IMD the buyer cannot also pay the fee on.
    function _net(uint256 x) internal pure returns (uint256) {
        return x * 10_000 / (10_000 + BELL_FEE_BPS);
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

    // ── pricing helpers ──
    function _sqrtAt(int24 b) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(b);
    }

    function _coinToImd(uint256 c, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(c, sp, Q96), sp, Q96);
    }

    function _imdToCoin(uint256 i, uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(i, Q96, sp), Q96, sp);
    }

    function _key() internal view returns (PoolKey memory k) {
        (address a, address b) = imdIs0 ? (imd, coin) : (coin, imd);
        k = PoolKey(Currency.wrap(a), Currency.wrap(b), FEE, TS, IHooks(address(this)));
    }

    // ── guards ──
    modifier nonReentrant() {
        if (_tget(LOCK_SLOT) != 0) revert Reentrant();
        _tset(LOCK_SLOT, 1);
        _;
        _tset(LOCK_SLOT, 0);
    }

    /// @dev One word from the manager: `sel(w)` for a one-word read (exttload here), its one-word answer.
    function _managerWord(uint256 sel, bytes32 w) internal view returns (uint256 v) {
        address m = address(manager);
        assembly ("memory-safe") {
            mstore(0, shl(224, sel))
            mstore(4, w)
            if iszero(staticcall(gas(), m, 0, 36, 0, 32)) { revert(0, 0) }
            v := mload(0)
        }
    }

    function _tget(uint256 slot) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tset(uint256 slot, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    // ── exits, burns, fee claims ──
    /// @dev CLOSED only (not FROZEN, not AWAITING, not in session). Sell-only, through the hook's own unlock.
    function emergencyExit(uint256 coinAmount, uint256 minImdOut) external nonReentrant {
        uint256 t = block.timestamp;
        uint256 d = t / 1 days;
        if (!(closeSettled(d) || (t % 1 days < OPEN_BELL - FREEZE && closeSettled(d - 1)))) revert ExitClosed();
        _pull(coin, coinAmount);
        _tset(UNLOCK_SLOT, 1);
        (uint256 spent, uint256 got) = abi.decode(manager.unlock(abi.encode(false, coinAmount, false, int24(0))), (uint256, uint256));
        _tset(UNLOCK_SLOT, 0);
        uint256 pen = _divUp(got * EXIT_PENALTY_BPS, 10_000);
        burnAccrued += pen;
        if (got - pen < minImdOut) revert Slippage();
        _pay(imd, msg.sender, got - pen);
        if (spent < coinAmount) _pay(coin, msg.sender, coinAmount - spent);
        emit Exited(msg.sender, spent, got - pen, pen);
    }

    /// @dev The dust reserve. Anyone (the launch's payer, at launch) seeds both currencies; both are pulled and
    ///      accounted, so the claims draw on them and `harvest` never sees them as inflow; nothing burns them.
    function seedDust(uint256 imdAmount, uint256 coinAmount) external nonReentrant {
        if (imdAmount > 0) _pull(imd, imdAmount);
        if (coinAmount > 0) _pull(coin, coinAmount);
        reserveImd += imdAmount;
        reserveCoin += coinAmount;
        emit DustSeeded(msg.sender, imdAmount, coinAmount);
    }

    /// @dev Folds unaccounted inflow (the factory's requester push, stray transfers): IMD to the swarm's slice, the bell
    ///      purse's slice and the burn, coin to the coin burn and the fee wallet. Shares the guard with the hook's swaps, so it can never run
    ///      inside unlockCallback.
    function harvest() external nonReentrant {
        uint256 bi = IERC20H(imd).balanceOf(address(this));
        uint256 bc = IERC20H(coin).balanceOf(address(this));
        uint256 hi = bi - imdAccounted;
        uint256 hc = bc - coinAccounted;
        uint256 sw = hi * SWARM_BPS / 10_000;
        uint256 bp = hi * bellPurseBps / 10_000;
        swarmAccrued += sw;
        bellPurseAccrued += bp;
        burnAccrued += hi - sw - bp;
        uint256 cb = hc * PRIZE_BPS / 10_000;
        coinBurnAccrued += cb;
        feeWalletCoinAccrued += hc - cb;
        (imdAccounted, coinAccounted) = (bi, bc);
        emit Harvested(hi, hc);
    }

    /// @dev Hands the accrued IMD to the burn executor, quotes the bridge fee and bridges it to the chain where it is
    ///      destroyed, with the caller's ETH. If the quote reverts or answers fewer than two words, if the caller sent
    ///      less than it, or if the bridge call reverts, the IMD stays with the executor for anyone's later bridge, and
    ///      the caller's ETH is returned. The reply is read raw and its length checked before it is decoded, so no
    ///      reply can revert this call.
    function pushBurn() external payable nonReentrant {
        uint256 a = burnAccrued;
        if (a < MIN_BURN) revert BelowMinBurn();
        burnAccrued = 0;
        _pay(imd, burnExecutor, a);
        bool bridged;
        (bool ok, bytes memory ret) = burnExecutor.staticcall(abi.encodeCall(IBurnExecutor.quoteBridgeFee, (a)));
        if (ok && ret.length >= 64 && msg.value >= abi.decode(ret, (uint256))) {
            try IBurnExecutor(burnExecutor).bridgeToBaseBurnReceiver{value: msg.value}(a, msg.sender) {
                bridged = true;
            } catch {}
        }
        if (!bridged && msg.value > 0) {
            (bool sent,) = msg.sender.call{value: msg.value}("");
            if (!sent) revert TransferFailed();
        }
        emit BurnPushed(a, bridged);
    }

    function burnCoin() external nonReentrant {
        uint256 a = coinBurnAccrued;
        if (a < MIN_COIN_BURN) revert BelowMinBurn();
        coinBurnAccrued = 0;
        coinAccounted -= a;
        IERC20H(coin).burn(a); // the supply falls
        emit CoinBurned(a);
    }

    function claimFeeWallet() external nonReentrant {
        (uint256 i, uint256 c) = (feeWalletImdAccrued, feeWalletCoinAccrued);
        (feeWalletImdAccrued, feeWalletCoinAccrued) = (0, 0);
        if (i > 0) _pay(imd, feeWallet, i);
        if (c > 0) _pay(coin, feeWallet, c);
    }

    /// @dev Pays the network's fee recipient read at call time. A reverting read, a reply shorter than one word, a
    ///      first word that is not an address, or the zero address sends the share to the burn. The reply is read raw and its length checked
    ///      before it is decoded, so no reply can revert this call.
    function claimNetworkFees() external nonReentrant {
        uint256 a = networkAccrued;
        networkAccrued = 0;
        address to;
        (bool ok, bytes memory ret) = launchFees.staticcall(abi.encodeCall(ILaunchFees.feeRecipient, ()));
        if (ok && ret.length >= 32) {
            uint256 w = abi.decode(ret, (uint256));
            if (w >> 160 == 0) to = address(uint160(w));
        }
        if (to == address(0)) burnAccrued += a;
        else if (a > 0) _pay(imd, to, a);
    }

    /// @dev Pays the swarm's purse what fits under its cap; the rest joins the burn.
    function claimSwarmBudget() external nonReentrant {
        uint256 a = swarmAccrued;
        swarmAccrued = 0;
        uint256 held = IERC20H(imd).balanceOf(swarmBudget);
        uint256 cap = SwarmBudget(swarmBudget).CAP();
        uint256 room = held >= cap ? 0 : cap - held;
        uint256 send = a < room ? a : room;
        if (send > 0) _pay(imd, swarmBudget, send);
        burnAccrued += a - send;
        emit SwarmBudgetPaid(send, a - send);
    }

    /// @dev Pays the bell purse its whole accrued slice, uncapped: the ringer pays it out only as capped rewards.
    function claimBellPurse() external nonReentrant {
        uint256 a = bellPurseAccrued;
        bellPurseAccrued = 0;
        if (a > 0) _pay(imd, bellPurse, a);
        emit BellPursePaid(a);
    }

    // ── v4 callbacks ──
    /// @dev Accepts exactly the factory's pool, once: the coin, IMD, fee 12500, spacing 60, this hook.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        if (sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        if (PoolId.unwrap(PoolIdLibrary.toId(key)) != poolId) revert BadPool();
        initialized = true;
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        lastCleared = _nearestBucket(imdIs0 ? -int256(tick) : int256(tick));
        return IHooks.beforeInitialize.selector;
    }

    /// @dev The gate, then the three anti-bot checks in order: size cap, price breaker, round trip.
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata p, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(manager)) revert NotPoolManager();
        uint256 t = block.timestamp;
        uint256 tod = t % 1 days;
        if (tod < OPEN_BELL || tod >= CLOSE_BELL) revert MarketClosed();
        if (!bells[2 * (t / 1 days)].rung) revert AwaitingBell();
        (uint160 sp, int24 tick,,) = manager.getSlot0(PoolId.wrap(poolId));
        _sizeCap(p.zeroForOne, p.amountSpecified, sp);
        _breaker(sp, tick);
        _roundTrip(p.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Size cap, in IMD terms; a coin-specified amount converts at the current pool price.
    function _sizeCap(bool zeroForOne, int256 amountSpecified, uint160 sp) internal view {
        uint256 amt = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if ((zeroForOne == (amountSpecified < 0)) != imdIs0) {
            amt = imdIs0
                ? FullMath.mulDiv(FullMath.mulDiv(amt, Q96, sp), Q96, sp) // token1 (coin) -> token0 (IMD)
                : FullMath.mulDiv(FullMath.mulDiv(amt, sp, Q96), sp, Q96); // token0 (coin) -> token1 (IMD)
        }
        if (amt > maxSwapImd) revert SwapTooLarge();
    }

    /// @dev Breaker: the block's first swap checkpoints spot; a later one may not start more than X from it. The first
    ///      swap of a block also feeds the counters, and the first one at or after the settle window's end freezes it.
    function _breaker(uint160 sp, int24 tick) internal {
        Checkpoint memory cp = checkpoint;
        if (cp.blockNumber != uint32(block.number)) {
            _windowCheckpoint(cp);
            cp.blockNumber = uint32(block.number);
            cp.sqrtPriceX96 = sp;
            cp.tickSum += int48(tick);
            ++cp.tickCount;
            checkpoint = cp;
        } else {
            uint256 r = FullMath.mulDiv(sp, Q96, cp.sqrtPriceX96);
            r = FullMath.mulDiv(r, r, Q96);
            if ((r > Q96 ? r - Q96 : Q96 - r) * 10_000 > maxBlockMoveBps * Q96) revert PriceMoved();
        }
    }

    /// @dev At or after today's window's end, once: freeze the counters as they stand, before this checkpoint adds to
    ///      them.
    function _windowCheckpoint(Checkpoint memory cp) internal {
        Window memory w = window;
        if (w.day != uint24(block.timestamp / 1 days) || w.frozen || block.timestamp < w.openedAt + SETTLE_WINDOW) return;
        w.tickSum = cp.tickSum;
        w.tickCount = cp.tickCount;
        w.frozen = true;
        window = w;
    }

    /// @dev Round trip: one direction per transaction signer per block (a speed bump, not a wall). The identity is the
    ///      signer, tx.origin, whatever the router: a router that reports the signer through msgSender() resolved to it
    ///      before, and one that does not was keyed on the router itself, which coupled every user of that router. No
    ///      router can spend somebody else's direction, since it cannot sign for them.
    function _roundTrip(bool zeroForOne) internal {
        address id = tx.origin;
        uint256 dir = zeroForOne ? 1 : 0;
        uint256 last = lastSwap[id];
        if (last >> 1 == block.number && last & 1 != dir) revert RoundTrip();
        lastSwap[id] = (block.number << 1) | dir;
    }

    /// @dev Nearest bucket on the 60-tick grid; an exact half rounds to the lower bucket.
    function _nearestBucket(int256 x) internal pure returns (int24) {
        int256 q = x / 60;
        int256 rem = x % 60;
        if (rem > 30) ++q;
        else if (rem <= -30) --q;
        return int24(q * 60);
    }

    /// @dev The bucket edge moved inward by the pool's fee (FEE ppm, through FEE_ROOT_Q96). The pool takes the fee from
    ///      the input, so a swap whose spot stays within `edge` pays at worst spot/(1 - fee) per unit out; scaling the
    ///      price limit by (1 - fee) (the sqrt by its root) makes that fee-inclusive worst case exactly the edge price.
    ///      zeroForOne moves the price down, so its floor goes up; oneForZero moves it up, so its ceiling comes down.
    ///      Both roundings (the floor sqrt, the round-up on the floor) move the limit further inward, never outward.
    function _feeInward(uint160 edge, bool zfo) internal pure returns (uint160) {
        return uint160(zfo ? FullMath.mulDivRoundingUp(edge, Q96, FEE_ROOT_Q96) : FullMath.mulDiv(edge, FEE_ROOT_Q96, Q96));
    }

    /// @dev Runs the one swap the hook queued (a bell's residual or an exit), exact input, and settles it from the hook's
    ///      own ERC-20 balances. `imdIn`: the hook pays IMD for coin. With `limited`, the pool may not trade past bucket
    ///      `limitB`'s price with the fee included: a buy never pays more than price(limitB) per coin, a sell never takes
    ///      less.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || _tget(UNLOCK_SLOT) == 0) revert NotInUnlock();
        (bool imdIn, uint256 amountIn, bool limited, int24 limitB) = abi.decode(data, (bool, uint256, bool, int24));
        bool zfo = imdIn == imdIs0;
        PoolKey memory k = _key();
        uint160 limit = limited
            ? _feeInward(TickMath.getSqrtPriceAtTick(imdIs0 ? -limitB : limitB), zfo)
            : (zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        if (limited) {
            // a bell's residual also stops RESIDUAL_MAX_BUCKETS buckets from the pool's price now, whichever comes first.
            // Without it, dust positions planted at every bucket on the way could make the residual need more gas than a
            // transaction may carry. The pool's sqrt price is the low 160 bits of its state's first word: v4's pools
            // mapping (slot 6) at the pool's id (the key's hash, as PoolIdLibrary.toId makes it), read by
            // extsload(bytes32) from the caller, the manager. Shifted up 96 bits (the rest of the word falls off the top)
            // over the cap's divisor, it is the price RESIDUAL_MAX_BUCKETS buckets on, to within a wei.
            assembly ("memory-safe") {
                mstore(0, keccak256(k, 0xa0))
                mstore(32, 6)
                let w := keccak256(0, 64)
                mstore(0, shl(224, 0x1e2eaeaf))
                mstore(4, w)
                if iszero(staticcall(gas(), caller(), 0, 36, 0, 32)) { revert(0, 0) }
                // down (zfo) over R, up over 2^192 / R
                let q := CAP_DOWN
                if iszero(zfo) { q := div(shl(192, 1), q) }
                let c := div(shl(96, mload(0)), q)
                // the cap is the nearer limit (down: above P*'s, up: below it): it becomes the limit, flagged for _ring
                // (UNLOCK_SLOT = 5, bit 2), which waives the unfilled-order fee on what it leaves unfilled
                if xor(zfo, lt(c, add(limit, zfo))) {
                    limit := c
                    tstore(UNLOCK_SLOT, 5)
                }
            }
        }
        BalanceDelta d;
        // the swap in its own `try`, so the pool's own refusal is told apart from every other failure: the price already
        // at or past the limit trades nothing (a zero delta, so (0, 0) goes back); with no liquidity in range the swap
        // itself returns nothing traded. Anything else, out of gas included, reverts the unlock and the bell with it.
        try manager.swap(k, IPoolManager.SwapParams(zfo, -int256(amountIn), limit), "") returns (BalanceDelta x) {
            d = x;
        } catch {
            assembly ("memory-safe") {
                let e := mload(0x40)
                returndatacopy(e, 0, returndatasize())
                // PriceLimitAlreadyExceeded(uint160,uint160), v4's Pool library refusal
                if iszero(and(gt(returndatasize(), 3), eq(shr(224, mload(e)), 0x7c9c6e8f))) { revert(e, returndatasize()) }
            }
        }
        uint256 spent = uint256(uint128(-(zfo ? d.amount0() : d.amount1())));
        uint256 got = uint256(uint128(zfo ? d.amount1() : d.amount0()));
        (Currency cin, Currency cout) = zfo ? (k.currency0, k.currency1) : (k.currency1, k.currency0);
        manager.sync(cin);
        if (!IERC20H(Currency.unwrap(cin)).transfer(address(manager), spent)) revert TransferFailed();
        manager.settle();
        if (got > 0) manager.take(cout, address(this), got);
        if (imdIn) {
            imdAccounted -= spent;
            coinAccounted += got;
        } else {
            coinAccounted -= spent;
            imdAccounted += got;
        }
        return abi.encode(spent, got);
    }
}
