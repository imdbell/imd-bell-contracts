// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev What the game reads from the hook: four views. The game never touches the pool, never reads the hook's storage
///      directly, never places or claims an order and never holds or moves a token.
interface IHookForGame {
    function orderInfo(uint256 orderId)
        external
        view
        returns (address owner, uint256 s, bool buy, int24 bucket, uint256 amount);
    function ticketPaid(uint256 orderId) external view returns (bool);
    function sessionMean() external view returns (int256 tickSum, uint256 tickCount, uint256 openedAt, bool frozen);
    function bells(uint256 s)
        external
        view
        returns (int24 pStar, bool rung, bool buyHeavy, uint64 innerFill, uint64 marginalFill, uint64 residualFill);
}

/// @title Guess the Bell
/// @notice A wallet seals at most one guess a day at the next day's opening price, on one of its orders of that day.
///         Guesses are committed before the 16:00 close and revealed after the open settles. The three closest
///         distances score 3, 2 and 1 points; the game pays points, never money, and holds no tokens at all.
/// @dev Ownerless; the one reference is immutable. The game scores the settled open, not the bell: the bucket nearest the
///      mean of the per-block checkpoints in the thirty minutes from the bell's own time, which the hook freezes so the
///      caller of `settle` cannot choose the window, and which nobody may read before it has ended. A ticket ranks only
///      if its order earned it (the hook's ticketPaid: at least 5 IMD, kept in its book through a bell that rang).
contract BellGame {
    error NotYourOrder();
    error TicketUsed();
    error CommitsClosed();
    error NotSettled();
    error AlreadySettled();
    error TooEarly();
    error WrongDay();
    error RevealClosed();
    error NoCommit();
    error BadReveal();
    error TicketUnpaid();
    error NotFinal();
    error NoPoints();
    error AlreadyTallied();
    error OneGuessPerDay();

    event Committed(uint256 indexed day, address indexed who, uint256 indexed orderId);
    event Settled(uint256 indexed day, int24 scored, bool fromMean, bool windowFrozen);
    event DayVoid(uint256 indexed day);
    /// @notice A reveal. `ranked` says only that the distance entered the top three at that moment; the day's final
    ///         ranks are `finalRanks(day)`.
    event Scored(uint256 indexed day, address indexed who, uint256 indexed orderId, int24 bucket, uint32 dist, bool ranked);
    event PointsAdded(uint256 indexed day, address indexed who, uint256 points);

    uint256 internal constant OPEN_BELL = 43200;
    uint256 internal constant CLOSE_BELL = 57600;
    /// @notice The thirty minutes from the opening bell whose checkpoints set the scored price.
    uint256 public constant SETTLE_WINDOW = 1800;
    int24 internal constant TS = 60;
    /// @dev A guess is a bucket on the grid, sent as `bucket + OFFSET` so it fits an unsigned word; OFFSET is on the grid
    ///      and beyond the tick range, so every bucket encodes non-negative.
    int256 public constant OFFSET = 887_280;
    uint256 public constant WINNERS = 3;

    IHookForGame public immutable hook;
    /// @dev Whether IMD is the pool's currency0, so the pool tick is the negated bucket.
    bool internal immutable imdIs0;

    struct DayState {
        bool settled;
        bool isVoid;
        bool fromMean;
        int24 scored;
    }

    /// @dev One leaderboard slot: a distance in buckets and how many wallets share it.
    struct Slot {
        uint32 dist;
        uint32 count;
    }

    mapping(uint256 day => DayState) public dayState;
    mapping(uint256 day => Slot[3]) internal slots;
    /// @dev The wallets that revealed a distance while it held a slot. A distance that leaves the slots never returns,
    ///      so for every final slot this is exactly its wallets.
    mapping(uint256 day => mapping(uint32 dist => address[])) internal atDist;
    /// @notice Sealed guesses by the day of the bell they guess and the order that earned the ticket.
    mapping(uint256 day => mapping(uint256 orderId => bytes32)) public commits;
    mapping(uint256 orderId => bool) public ticketUsed;
    /// @dev The day of the bell each wallet last sealed a guess for. One guess a wallet a day, so no wallet can seal a
    ///      guess at every bucket and reveal, once the answer is public, the one that matches. A wallet's guessed days
    ///      only rise: the commits for a day close at 16:00 the day before, before any book whose tickets guess the
    ///      day after can open, so equality with the last one is the whole check. Committed(day, wallet) records it.
    mapping(address => uint256) internal lastGuessDay;
    mapping(uint256 day => mapping(address => bool)) public revealed;
    mapping(uint256 day => mapping(address => uint32)) public distOf;
    mapping(uint256 day => mapping(address => bool)) public tallied;
    /// @notice Every wallet's running total of points, across all days tallied so far.
    mapping(address => uint256) public points;

    constructor(address hook_, bool imdIs0_) {
        hook = IHookForGame(hook_);
        imdIs0 = imdIs0_;
    }

    // ── tickets and sealing ──
    /// @notice Seals a guess for the opening bell after the day of `orderId`'s book, before 16:00 of that day; once per
    ///         wallet and day, whichever of its orders it uses. `c = keccak256(abi.encode(guess, salt, owner, day))`, with
    ///         `guess = bucket + OFFSET`. The guess counts only if the order earns its ticket (see the hook's ticketPaid).
    function commit(uint256 orderId, bytes32 c) external {
        (address owner, uint256 s,,,) = hook.orderInfo(orderId);
        if (owner != msg.sender) revert NotYourOrder();
        uint256 ticketDay = s / 2;
        if (block.timestamp >= ticketDay * 1 days + CLOSE_BELL) revert CommitsClosed();
        if (ticketUsed[orderId]) revert TicketUsed();
        if (lastGuessDay[msg.sender] == ticketDay + 1) revert OneGuessPerDay();
        lastGuessDay[msg.sender] = ticketDay + 1;
        ticketUsed[orderId] = true;
        commits[ticketDay + 1][orderId] = c;
        emit Committed(ticketDay + 1, msg.sender, orderId);
    }

    /// @notice Settles `day`'s opening price for the game, once, on that day: once the thirty minutes from the bell's
    ///         own time have passed if the open rang (12:30 for a bell at 12:00, later for a later bell), else from 16:00,
    ///         when the day is void. A bell so late that its thirty minutes reach 16:00 leaves no time to reveal, so that
    ///         day is void too: no points, and nothing ranks. A day whose window held no checkpoint scores the bell's own
    ///         price. Reads the hook's window; never changes it.
    function settle(uint256 day) external {
        uint256 t = block.timestamp;
        if (t / 1 days != day) revert WrongDay();
        DayState storage ds = dayState[day];
        if (ds.settled) revert AlreadySettled();
        (int24 pStar, bool rung,,,,) = hook.bells(2 * day);
        (int256 sum, uint256 n, uint256 openedAt, bool frozen) = hook.sessionMean();
        // the window runs from the bell's own time; read before it ends, the caller would choose how much of it counts.
        // With no bell the day waits for the close.
        uint256 close = day * 1 days + CLOSE_BELL;
        uint256 end = rung ? openedAt + SETTLE_WINDOW : close;
        if (t < end) revert TooEarly();
        // no bell, or a bell so late that its window reaches the close: no reveal window is left, so the day is void
        if (end >= close) {
            ds.settled = true;
            ds.isVoid = true;
            emit DayVoid(day);
            return;
        }
        int24 scored = pStar;
        if (n > 0) scored = _nearestBucket(imdIs0 ? -(sum / int256(n)) : sum / int256(n));
        ds.settled = true;
        ds.fromMean = n > 0;
        ds.scored = scored;
        emit Settled(day, scored, n > 0, frozen);
    }

    /// @notice Reveals the wallet's sealed guess for today's bell after it settled and before 16:00. A wallet seals one
    ///         guess a day, so it has one to reveal (its commit is deleted here, so a second reveal finds none); a
    ///         ticket whose order did not earn it is refused, and so is a guess that is not a bucket (off the 60-tick
    ///         grid, or above the grid's words): its committer spent the day's guess and reveals nothing.
    function reveal(uint256 orderId, uint256 guess, bytes32 salt) external {
        uint256 day = block.timestamp / 1 days;
        DayState storage ds = dayState[day];
        if (!ds.settled || ds.isVoid) revert NotSettled();
        if (block.timestamp % 1 days >= CLOSE_BELL) revert RevealClosed();
        bytes32 c = commits[day][orderId];
        if (c == 0) revert NoCommit();
        if (keccak256(abi.encode(guess, salt, msg.sender, day)) != c) revert BadReveal();
        // a guess is a bucket: within the grid's words and on the 60-tick grid (OFFSET is itself on the grid, so the
        // guess is on it exactly when the bucket is). Off the grid, the floored distance below would make one sealed
        // guess an exact hit for two neighbouring buckets
        if (guess > uint256(2 * OFFSET) || guess % 60 != 0) revert BadReveal();
        if (!hook.ticketPaid(orderId)) revert TicketUnpaid();
        delete commits[day][orderId];
        revealed[day][msg.sender] = true;
        int256 bucket = int256(guess) - OFFSET;
        int256 diff = bucket - int256(ds.scored);
        uint256 dist = uint256(diff < 0 ? -diff : diff) / uint256(uint24(TS));
        uint32 dd = dist > type(uint32).max ? type(uint32).max : uint32(dist);
        distOf[day][msg.sender] = dd;
        bool ranked = _insert(slots[day], dd);
        if (ranked) atDist[day][dd].push(msg.sender);
        emit Scored(day, msg.sender, orderId, int24(bucket), dd, ranked);
    }

    /// @notice Adds `who`'s points for `day` to its running total, once, after the reveal window closed. Anyone may
    ///         call it for anyone.
    function tally(uint256 day, address who) external {
        if (!_final(day)) revert NotFinal();
        if (tallied[day][who]) revert AlreadyTallied();
        uint256 p = _pointsFor(day, who);
        if (p == 0) revert NoPoints();
        tallied[day][who] = true;
        points[who] += p;
        emit PointsAdded(day, who, p);
    }

    // ── views ──
    function rankOf(uint256 day, uint256 i) external view returns (uint32 dist, uint32 count) {
        Slot memory x = slots[day][i];
        return (x.dist, x.count);
    }

    /// @notice A day's ranks: the scored bucket, up to three distances in buckets (nearest first, `count` 0 for an empty
    ///         slot), the points each wallet at that distance scores, and those wallets. `isFinal` is true once the day
    ///         settled with a bell and its reveal window has closed; before then the ranks can still change.
    function finalRanks(uint256 day)
        external
        view
        returns (
            bool isFinal,
            int24 scored,
            uint32[3] memory dist,
            uint32[3] memory count,
            uint256[3] memory pts,
            address[][3] memory wallets
        )
    {
        isFinal = _final(day);
        scored = dayState[day].scored;
        Slot[3] storage r = slots[day];
        uint256 start;
        for (uint256 i; i < 3; ++i) {
            if (r[i].count == 0) break;
            dist[i] = r[i].dist;
            count[i] = r[i].count;
            pts[i] = _placePoints(start);
            wallets[i] = atDist[day][r[i].dist];
            start += r[i].count;
        }
    }

    /// @notice The points `who` scores for `day` by the ranks as they stand (final once `finalRanks` says so).
    function pointsOf(uint256 day, address who) external view returns (uint256) {
        return _pointsFor(day, who);
    }

    // ── internals ──
    function _final(uint256 day) internal view returns (bool) {
        DayState memory ds = dayState[day];
        return ds.settled && !ds.isVoid && block.timestamp >= day * 1 days + CLOSE_BELL;
    }

    /// @dev The three best distinct distances, nearest first, each with the number of wallets at it. A new distance
    ///      shifts worse ones down and the worst out; an equal one joins its slot. At most three slots are touched.
    function _insert(Slot[3] storage r, uint32 dd) internal returns (bool) {
        for (uint256 i; i < 3; ++i) {
            if (r[i].count == 0) {
                r[i] = Slot(dd, 1);
                return true;
            }
            if (dd == r[i].dist) {
                ++r[i].count;
                return true;
            }
            if (dd < r[i].dist) {
                for (uint256 j = 2; j > i; --j) {
                    r[j] = r[j - 1];
                }
                r[i] = Slot(dd, 1);
                return true;
            }
        }
        return false;
    }

    /// @dev A wallet at distance `dd` on `day` scores the points of the highest place its slot covers: the first place
    ///      after every wallet strictly closer. Tied wallets each score that place's points; a slot starting past the
    ///      third place scores nothing.
    function _pointsFor(uint256 day, address who) internal view returns (uint256) {
        if (!revealed[day][who]) return 0;
        uint32 dd = distOf[day][who];
        Slot[3] storage r = slots[day];
        uint256 start;
        for (uint256 i; i < 3; ++i) {
            if (r[i].count == 0) return 0;
            if (r[i].dist == dd) return _placePoints(start);
            start += r[i].count;
        }
        return 0;
    }

    /// @dev Place 0 scores 3, place 1 scores 2, place 2 scores 1, any later place 0.
    function _placePoints(uint256 place) internal pure returns (uint256) {
        return place < WINNERS ? WINNERS - place : 0;
    }

    /// @dev Nearest bucket on the grid; an exact half rounds to the lower bucket, as the hook's own rule does.
    function _nearestBucket(int256 x) internal pure returns (int24) {
        int256 q = x / 60;
        int256 rem = x % 60;
        if (rem > 30) ++q;
        else if (rem <= -30) --q;
        return int24(q * 60);
    }
}
