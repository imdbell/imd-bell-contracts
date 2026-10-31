// An earlier version of the hook, kept for a same-address gas comparison. Not the product; not built into it.
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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERC20H {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function burn(uint256 amount) external;
}

/// @dev The mainnet BurnExecutor's permissionless bridge-out (verified source: `quoteBridgeFee(uint256)` returns
///      `MessagingFee{nativeFee, lzTokenFee}`; `bridgeToBaseBurnReceiver(uint256 requested, address refundTo)`).
interface IBurnExecutor {
    function quoteBridgeFee(uint256 requested) external view returns (uint256 nativeFee, uint256 lzTokenFee);
    function bridgeToBaseBurnReceiver(uint256 requested, address refundTo) external payable;
}

interface ILaunchFees {
    function feeRecipient() external view returns (address);
}

/// @title A baseline hook kept for gas comparisons. Not the product; not deployed; not audited.
/// @dev Buckets are ticks on the 60-tick grid in "IMD per coin" orientation: price(b) = 1.0001^b IMD per coin, so a
///      higher bucket is a dearer coin whichever way the pool sorts. The pool tick is b when IMD is currency1, -b when
///      IMD is currency0.
contract MarketHoursHookBaseline is IUnlockCallback {
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

    // ── schedule (UTC seconds into the day) ──
    uint256 internal constant OPEN_BELL = 43200;
    uint256 internal constant CLOSE_BELL = 57600;
    uint256 internal constant FREEZE = 600;
    uint256 internal constant NO_CANCEL = 3600;
    uint256 internal constant CLOSE_DEADLINE = 72000;

    // ── pool and book shape ──
    uint24 internal constant FEE = 12_500;
    int24 internal constant TS = 60;
    int24 internal constant BAND = 200;

    // ── figures (placeholders) ──
    uint256 internal constant BELL_FEE_BPS = 125;
    uint256 internal constant CANCEL_FEE_BPS = 50;
    uint256 internal constant EXIT_PENALTY_BPS = 500;
    uint256 internal constant MIN_ORDER = 1e18;
    uint256 internal constant MIN_BURN = 5e18;
    uint256 internal constant MIN_COIN_BURN = 1_000e18;
    uint256 internal constant BELL_GAS_FLOOR = 2_000_000;
    uint256 internal constant MAX_SWAP_IMD = 10_000e18;
    uint256 internal constant MAX_BLOCK_MOVE_BPS = 500;
    uint256 internal constant CAP0 = 100_000e18;
    uint256 internal constant CAP_MAX = 10_000_000e18;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    // transient-storage slots: the reentrancy guard, and the flag that admits unlockCallback
    uint256 internal constant LOCK_SLOT = 0x6d682e6c6f636b;
    uint256 internal constant UNLOCK_SLOT = 0x6d682e756e6c6f636b;

    IPoolManager public immutable manager;
    address public immutable factory;
    address public immutable imd;
    address public immutable coin;
    address public immutable feeWallet;
    address public immutable burnExecutor;
    address public immutable launchFees;
    bool internal immutable imdIs0;
    uint256 public immutable d0;
    bytes32 internal immutable poolId;

    struct Order {
        address owner;
        uint40 s;
        bool buy;
        bool claimed;
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

    /// @dev the charge side of a bell's ratios. `Bell` keeps the payout ratios (rounded down); a charge
    ///      uses the same ratio rounded up: `roundUp` bit 0 / bit 1 = the inner / marginal fill had a remainder (so its
    ///      ceiling is one more), and `residualUp` is the residual's charge ratio, rounded up. Its own slot, so `bells()`
    ///      keeps its shape.
    struct Charge {
        uint8 roundUp;
        uint64 residualUp;
    }

    /// @dev One slot: the breaker's per-block checkpoint and the  stale-reference counters.
    struct Checkpoint {
        uint32 blockNumber;
        uint160 sqrtPriceX96;
        int48 tickSum;
        uint16 tickCount;
    }

    event OrderPlaced(uint256 indexed orderId, address indexed owner, uint256 indexed s, bool buy, int24 bucket, uint256 amount);
    event OrderCancelled(uint256 indexed orderId, uint256 fee);
    event Claimed(uint256 indexed orderId, address indexed owner, uint256 out, uint256 refund);
    event FeeTaken(uint256 indexed orderId, uint256 amount);
    event Exited(address indexed who, uint256 coinIn, uint256 imdOut, uint256 penalty);
    event Harvested(uint256 imd, uint256 coin);
    event BurnPushed(uint256 amount, bool bridged);
    event CoinBurned(uint256 amount);
    event BellRung(uint256 indexed s, int24 pStar, uint256 matchedTok, uint256 residualFilled, address ringer);
    event DustSeeded(address indexed payer, uint256 imd, uint256 coin);

    bool public initialized;
    int24 public lastCleared;
    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => mapping(int24 => uint256)) public buyImd;
    mapping(uint256 => mapping(int24 => uint256)) public sellTok;
    mapping(uint256 => uint256) public bookImdTotal;
    mapping(uint256 => Bell) public bells;
    mapping(uint256 => Charge) public charges;
    Checkpoint public checkpoint;
    mapping(address => uint256) public lastSwap;

    uint256 public burnAccrued;
    uint256 public coinBurnAccrued;
    uint256 public networkAccrued;
    uint256 public feeWalletImdAccrued;
    uint256 public feeWalletCoinAccrued;
    uint256 public dustImd;
    uint256 public dustCoin;
    uint256 public imdAccounted;
    uint256 public coinAccounted;
    // the dust reserve, inside imdAccounted / coinAccounted so the claims draw on it; never burned, never
    // harvested, never decremented (what is left stays in the hook)
    uint256 public reserveImd;
    uint256 public reserveCoin;

    constructor(
        IPoolManager manager_,
        address factory_,
        address imd_,
        address coin_,
        address feeWallet_,
        address burnExecutor_,
        address launchFees_
    ) {
        manager = manager_;
        factory = factory_;
        imd = imd_;
        coin = coin_;
        feeWallet = feeWallet_;
        burnExecutor = burnExecutor_;
        launchFees = launchFees_;
        imdIs0 = imd_ < coin_;
        d0 = block.timestamp / 1 days;
        poolId = PoolId.unwrap(PoolIdLibrary.toId(_key()));
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
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
        int24 ref = referenceOf(s);
        if (bucket % TS != 0 || bucket > ref + BAND * TS || bucket < ref - BAND * TS) revert BadBucket();
        uint256 imdValue = buy ? amount : _coinToImd(amount, _sqrtAt(ref));
        if (imdValue < MIN_ORDER) revert BelowMinOrder();
        uint256 total = bookImdTotal[s] + imdValue;
        if (total > depositCap()) revert BookFull();
        bookImdTotal[s] = total;
        _pull(buy ? imd : coin, amount);
        // a bucket's buy total is the sum of its orders' own nets, so the scan's demand and the residual it offers
        // are exactly the sum of what the claims will charge against (a bucket-level _net would count up to a wei per order
        // that no order's claim covers)
        if (buy) buyImd[s][bucket] += _net(amount);
        else sellTok[s][bucket] += amount;
        orderId = nextOrderId++;
        orders[orderId] = Order(msg.sender, uint40(s), buy, false, bucket, amount);
        emit OrderPlaced(orderId, msg.sender, s, buy, bucket, amount);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.owner != msg.sender) revert NotOwner();
        if (o.claimed || !_cancellable(o.s)) revert CancelLocked();
        o.claimed = true;
        uint256 a = o.amount;
        uint256 fee = _divUp(a * CANCEL_FEE_BPS, 10_000);
        bookImdTotal[o.s] -= o.buy ? a : _coinToImd(a, _sqrtAt(referenceOf(o.s)));
        if (o.buy) {
            buyImd[o.s][o.bucket] -= _net(a);
            burnAccrued += fee;
            _pay(imd, msg.sender, a - fee);
        } else {
            sellTok[o.s][o.bucket] -= a;
            coinBurnAccrued += fee; // burned as the coin
            _pay(coin, msg.sender, a - fee);
        }
        emit OrderCancelled(orderId, fee);
    }

    /// @dev Pays the order's owner: the fill at P* (bell fee on book-matched volume only) plus the refund of the
    ///      unfilled remainder; or the whole escrow if the book's bell never rang by its deadline.
    function claim(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.owner == address(0)) revert NotClaimable();
        if (o.claimed) revert AlreadyClaimed();
        uint256 s = o.s;
        Bell memory bl = bells[s];
        uint256 a = o.amount;
        uint256 out;
        uint256 refund = a;
        if (!bl.rung) {
            if (block.timestamp < (s / 2) * 1 days + (s & 1 == 0 ? CLOSE_BELL : CLOSE_DEADLINE)) revert NotClaimable();
        } else if (o.buy ? o.bucket >= bl.pStar : o.bucket <= bl.pStar) {
            uint160 sp = _sqrtAt(bl.pStar);
            uint256 net = o.buy ? _net(a) : a; // what the scan counted as this order's demand
            // per currency, every payout rounds down and every charge rounds up. `bookIn` / `resIn` are
            // charged in the order's own currency (ratio rounded up); `bookOut` / `resOut` are the same legs as payout
            // bases (ratio rounded down), converted at P* rounding down. The lighter side fills exactly.
            uint256 bookIn = net;
            uint256 bookOut = net;
            uint256 resIn;
            uint256 resOut;
            if (o.buy == bl.buyHeavy) {
                Charge memory ch = charges[s];
                bool marg = o.bucket == bl.pStar;
                uint256 f = marg ? bl.marginalFill : bl.innerFill;
                bookIn = FullMath.mulDivRoundingUp(net, f + ((ch.roundUp >> (marg ? 1 : 0)) & 1), ONE);
                bookOut = net * f / ONE;
                // the residual share's base is what the charged book left: these sum to at most what the ring offered the
                // pool, so the shares sum to at most what it filled (the filled base, never the larger unfilled one)
                uint256 u = net - bookIn;
                resIn = FullMath.mulDivRoundingUp(u, ch.residualUp, ONE);
                resOut = u * bl.residualFill / ONE;
            }
            refund = a - bookIn - resIn;
            uint256 fee;
            if (o.buy) {
                // the fee is IMD on top of the book fill, never taken out of it before the IMD -> coin
                // conversion. bookIn + resIn <= net and net + fee <= a, so the refund cannot underflow.
                fee = _divUp(bookIn * BELL_FEE_BPS, 10_000);
                out = _imdToCoin(bookOut, sp) + _imdToCoin(resOut, sp);
                refund -= fee;
            } else {
                uint256 gross = _coinToImd(bookOut, sp);
                fee = _divUp(gross * BELL_FEE_BPS, 10_000);
                out = gross - fee + _coinToImd(resOut, sp);
            }
            if (fee > 0) {
                uint256 fifth = fee / 5; // 20 % network, 20 % fee wallet, 60 % burn (the remainder)
                networkAccrued += fifth;
                feeWalletImdAccrued += fifth;
                burnAccrued += fee - 2 * fifth;
                emit FeeTaken(orderId, fee);
            }
        }
        o.claimed = true;
        if (out > 0) _pay(o.buy ? coin : imd, o.owner, out);
        if (refund > 0) _pay(o.buy ? imd : coin, o.owner, refund);
        emit Claimed(orderId, o.owner, out, refund);
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

    function referenceOf(uint256 s) public view returns (int24) {
        if (s & 1 == 1 && bells[s - 1].rung) return bells[s - 1].pStar;
        return lastCleared;
    }

    /// @dev The clearing scan over the band around reference(s). O(BAND), independent of order count.
    struct Scan {
        int24 p; // chosen bucket
        uint256 matched; // matched volume at p, coin
        uint256 sCum; // S(p): sells with limit <= p, coin
        uint256 bCum; // buys with limit >= p, IMD
        uint256 sellAt; // sells at exactly p, coin
        uint256 buyAt; // buys at exactly p, IMD
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
            B[i] = buyImd[s][b]; //  / : already the orders' nets (the bell fee sits on top in escrow)
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
        if (best == 0) {
            bi = uint256(uint24(BAND)); // zero matches: the reference bucket, unless the session traded
            Checkpoint memory cp = checkpoint; // 
            if (cp.tickCount > 0) { // 
                int256 mean = int256(cp.tickSum) / int256(uint256(cp.tickCount)); // 
                int256 j = (int256(_nearestBucket(imdIs0 ? -mean : mean)) - int256(lo)) / 60; // 
                bi = j < 0 ? 0 : j >= int256(n) ? n - 1 : uint256(j); // 
            } // 
        }
        r.p = lo + int24(int256(bi)) * TS;
        r.matched = best;
        r.sCum = S[bi];
        r.bCum = B[bi];
        r.sellAt = S[bi] - (bi > 0 ? S[bi - 1] : 0);
        r.buyAt = B[bi] - (bi + 1 < n ? B[bi + 1] : 0);
    }

    /// @dev The bell's steps, shared by both bells. The cross is plain code; only the residual swap sits in a `try`.
    function _ring(uint256 s) internal {
        Bell storage bl = bells[s];
        if (bl.rung) revert BellAlreadyRung();
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
        lastCleared = r.p;
        (checkpoint.tickSum, checkpoint.tickCount) = (0, 0); // 
        uint256 filled;
        if (resIn > 0) {
            // the heavier side's remainder through the curve, never past price(P*) LP fee included
            _tset(UNLOCK_SLOT, 1);
            try manager.unlock(abi.encode(buyHeavy, resIn, true, r.p)) returns (bytes memory ret) {
                (uint256 spent, uint256 got) = abi.decode(ret, (uint256, uint256));
                // `pay` is the payout base in the rationed side's own currency, `charge` the charge base.
                uint256 pay;
                uint256 charge;
                if (buyHeavy) {
                    pay = _coinToImd(got, sp); // the coin bought, at exactly P*: what the residual buyers are paid
                    if (pay > resIn) pay = resIn;
                    charge = pay > spent ? pay : spent; // what they are charged in all; never less than the hook spent
                    burnAccrued += charge - spent; // the pool's price improvement
                    filled = pay;
                } else {
                    pay = _imdToCoin(got, sp); // the coin whose P* value the IMD received covers
                    if (pay > spent) pay = spent;
                    charge = spent; // the coin the hook sold
                    burnAccrued += got - _coinToImd(pay, sp); // 
                    filled = spent;
                }
                bl.residualFill = uint64(pay * ONE / resIn); // payout ratio: rounds down
                ch.residualUp = uint64(FullMath.mulDivRoundingUp(charge, ONE, resIn)); // charge ratio: rounds up
            } catch {}
            _tset(UNLOCK_SLOT, 0);
        }
        charges[s] = ch;
        emit BellRung(s, r.p, r.matched, filled, msg.sender);
    }

    /// @dev Book fill ratios for the heavier side: `need` of it is matched; strictly-inside orders first, then the
    ///      marginal bucket pro rata by size.
    /// each ratio rounds down (the payout ratio); `up` flags a remainder (bit 0 inner, bit 1 marginal), so the
    ///      charge ratio is that ratio plus one.
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

    // ── token movement: every pull is counted, every flow is accounted ──
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

    /// @dev : the part of a buy escrow that is demand, the rest covering the bell fee charged on top: x / (1 + fee),
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

    /// @dev the dust reserve. Anyone (the payer wallet at launch) seeds both currencies; both are pulled
    ///      and accounted, so the claims draw on them and `harvest` never sees them as inflow; nothing burns them.
    function seedDust(uint256 imdAmount, uint256 coinAmount) external nonReentrant {
        if (imdAmount > 0) _pull(imd, imdAmount);
        if (coinAmount > 0) _pull(coin, coinAmount);
        reserveImd += imdAmount;
        reserveCoin += coinAmount;
        emit DustSeeded(msg.sender, imdAmount, coinAmount);
    }

    /// @dev Folds unaccounted inflow (the factory's requester push, stray transfers): IMD -> burn, coin -> fee wallet
    ///. Shares the guard with the hook's swaps, so it can never run inside unlockCallback.
    function harvest() external nonReentrant {
        uint256 bi = IERC20H(imd).balanceOf(address(this));
        uint256 bc = IERC20H(coin).balanceOf(address(this));
        uint256 hi = bi - imdAccounted;
        uint256 hc = bc - coinAccounted;
        burnAccrued += hi;
        feeWalletCoinAccrued += hc;
        (imdAccounted, coinAccounted) = (bi, bc);
        emit Harvested(hi, hc);
    }

    /// @dev Shape (b), : hand the IMD to the BurnExecutor, quote the LayerZero fee and bridge it to the Base burn
    ///      receiver with the caller's ETH. Shape (a) is the fallback: if the quote reverts or the caller sent less
    ///      than it, the IMD stays with the executor for anyone's later bridge, and the caller's ETH is returned.
    function pushBurn() external payable nonReentrant {
        uint256 a = burnAccrued;
        if (a < MIN_BURN) revert BelowMinBurn();
        burnAccrued = 0;
        _pay(imd, burnExecutor, a);
        bool bridged;
        try IBurnExecutor(burnExecutor).quoteBridgeFee(a) returns (uint256 fee, uint256) {
            if (msg.value >= fee) {
                IBurnExecutor(burnExecutor).bridgeToBaseBurnReceiver{value: msg.value}(a, msg.sender);
                bridged = true;
            }
        } catch {}
        if (!bridged && msg.value > 0) {
            (bool ok,) = msg.sender.call{value: msg.value}("");
            if (!ok) revert TransferFailed();
        }
        emit BurnPushed(a, bridged);
    }

    function burnCoin() external nonReentrant {
        uint256 a = coinBurnAccrued;
        if (a < MIN_COIN_BURN) revert BelowMinBurn();
        coinBurnAccrued = 0;
        coinAccounted -= a;
        IERC20H(coin).burn(a); // totalSupply falls
        emit CoinBurned(a);
    }

    function claimFeeWallet() external nonReentrant {
        (uint256 i, uint256 c) = (feeWalletImdAccrued, feeWalletCoinAccrued);
        (feeWalletImdAccrued, feeWalletCoinAccrued) = (0, 0);
        if (i > 0) _pay(imd, feeWallet, i);
        if (c > 0) _pay(coin, feeWallet, c);
    }

    /// @dev Pays LaunchFees.feeRecipient read at call time; a zero or reverting read sends the share to the burn.
    function claimNetworkFees() external nonReentrant {
        uint256 a = networkAccrued;
        networkAccrued = 0;
        address to;
        try ILaunchFees(launchFees).feeRecipient() returns (address r) {
            to = r;
        } catch {}
        if (to == address(0)) burnAccrued += a;
        else if (a > 0) _pay(imd, to, a);
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
    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata p, bytes calldata)
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
        _roundTrip(sender, p.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev (3) size cap, in IMD terms; a coin-specified amount converts at the current pool price.
    function _sizeCap(bool zeroForOne, int256 amountSpecified, uint160 sp) internal view {
        uint256 amt = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if ((zeroForOne == (amountSpecified < 0)) != imdIs0) {
            amt = imdIs0
                ? FullMath.mulDiv(FullMath.mulDiv(amt, Q96, sp), Q96, sp) // token1 (coin) -> token0 (IMD)
                : FullMath.mulDiv(FullMath.mulDiv(amt, sp, Q96), sp, Q96); // token0 (coin) -> token1 (IMD)
        }
        if (amt > MAX_SWAP_IMD) revert SwapTooLarge();
    }

    /// @dev (2) breaker: the block's first swap checkpoints spot; a later one may not start more than X from it.
    function _breaker(uint160 sp, int24 tick) internal {
        Checkpoint memory cp = checkpoint;
        if (cp.blockNumber != uint32(block.number)) {
            cp.blockNumber = uint32(block.number);
            cp.sqrtPriceX96 = sp;
            cp.tickSum += int48(tick); // 
            ++cp.tickCount; // 
            checkpoint = cp;
        } else {
            uint256 r = FullMath.mulDiv(sp, Q96, cp.sqrtPriceX96);
            r = FullMath.mulDiv(r, r, Q96);
            if ((r > Q96 ? r - Q96 : Q96 - r) * 10_000 > MAX_BLOCK_MOVE_BPS * Q96) revert PriceMoved();
        }
        tick; // read with the checkpoint; the  counters use it
    }

    /// @dev (4) round trip: one direction per resolved identity per block (a speed bump, not a wall).
    function _roundTrip(address sender, bool zeroForOne) internal {
        address id = sender;
        (bool ok, bytes memory ret) = sender.staticcall(abi.encodeWithSelector(0xd737d0c7)); // msgSender
        if (ok && ret.length == 32) id = abi.decode(ret, (address));
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

    /// @dev : the bucket edge moved inward by the pool's LP fee (`fee` ppm, from the PoolKey). v4 takes the fee from the
    ///      input, so a swap whose spot stays within `edge` pays at worst spot/(1 - fee) per unit out; scaling the price limit
    ///      by (1 - fee) (the sqrt by its root) makes that fee-inclusive worst case exactly the edge price. zeroForOne moves the
    ///      price down, so its floor goes up; oneForZero moves it up, so its ceiling comes down. Both roundings (the floor
    ///      sqrt, the round-up on the floor) move the limit further inward, never outward. 12,500 ppm is about 126 ticks.
    function _feeInward(uint160 edge, bool zfo, uint24 fee) internal pure returns (uint160) {
        uint256 rootQ96 = Math.sqrt(((1_000_000 - uint256(fee)) << 192) / 1_000_000); // sqrt(1 - fee) in Q96, rounded down
        return uint160(zfo ? FullMath.mulDivRoundingUp(edge, Q96, rootQ96) : FullMath.mulDiv(edge, rootQ96, Q96));
    }

    /// @dev Runs the one swap the hook queued (a bell's residual or an exit), exact input, and settles it from the hook's
    ///      own ERC-20 balances. `imdIn`: the hook pays IMD for coin. With `limited`, the pool may not trade past bucket
    ///      `limitB`'s price LP fee included: a buy never pays more than price(limitB) per coin, a sell never takes less.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || _tget(UNLOCK_SLOT) == 0) revert NotInUnlock();
        (bool imdIn, uint256 amountIn, bool limited, int24 limitB) = abi.decode(data, (bool, uint256, bool, int24));
        bool zfo = imdIn == imdIs0;
        PoolKey memory k = _key();
        uint160 limit = limited
            ? _feeInward(TickMath.getSqrtPriceAtTick(imdIs0 ? -limitB : limitB), zfo, k.fee) // 
            : (zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        BalanceDelta d = manager.swap(k, IPoolManager.SwapParams(zfo, -int256(amountIn), limit), "");
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
