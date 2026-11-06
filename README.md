# IMD Bell contracts

IMD Bell is a coin that trades during one session a day. While the market is closed, anyone may leave a limit
order; the orders wait in a book and are filled at one price when the opening bell rings at 12:00 UTC. The pool then
trades until 16:00 UTC, when the closing bell clears a second book the same way. An order of at least 5 IMD that
stays in its book through the bell earns a sealed guess at the next day's opening price, one guess per wallet per day,
and the closest guesses score points (never money). Whoever rings a bell first is paid a small reward for the gas.

**Not yet deployed.**

A transaction that calls `BellRinger.ring()` needs a gas limit of at least 11,461,642; below that the ringer refuses
before it rings (`GasShort`).

## Contracts (`src/`)

| File | What it is |
|---|---|
| `MarketHoursHook.sol` | The Uniswap v4 hook: the order books, the two bells, the session rules and the fee shares. Nobody owns it and nothing in it can be changed after deployment. At deployment it creates `BellGame`, `BellRinger` and `SwarmBudget`. Its round-trip guard allows one swap direction per identity per block; `lastSwap(bytes32)` holds the record, keyed on the transaction's signer as a padded word, or, when the router reports an account through `msgSender()`, on the hash of that router and that account. |
| `MarketHoursCoin.sol` | A plain ERC-20 with a fixed supply minted once at deployment; anyone may burn their own coin. |
| `BellGame.sol` | The guessing game: sealed guesses (one per wallet per day, each on an order of at least 5 IMD kept in its book through the bell), reveals after the open settles, ranks and points. A revealed guess must be a bucket, on the 60-tick grid and no higher than the grid's top word; any other guess cannot be revealed. It holds no tokens. |
| `BellRinger.sol` | Rings whichever bell is due, runs that bell's chores, and pays the caller from the bell purse. |
| `SwarmBudget.sol` | A small purse that can only pay for two nightly requests to the network's Intake: a guess at the next open and a short report on the day. |
| `IIntake.sol` | The part of the network's Intake interface that `SwarmBudget` calls. |

## Since the third audit

Commit 4eb95e3 was audited in the public audit job d2e99057-f18f-44d5-852b-53d5bb1b4ca0. This commit answers its
seven findings:

- Finding 1: no contract change; accepted, see "Known and accepted" (the ring reward after a moved ring).
- Finding 2, `MarketHoursHook`: the round-trip guard's key is scoped to the router that reports it. When the router
  reports an account through `msgSender()`, the key is `keccak256(abi.encode(router, account))`; otherwise it is the
  transaction's signer as a padded word. The public record is `lastSwap(bytes32)`, which takes that key. A router can
  spend only the direction of an account it reports itself.
- Finding 3, `BellGame`: `reveal` refuses a guess that is not a bucket, off the 60-tick grid or above the grid's top
  word (`BadReveal`). An off-grid committer has spent the day's guess and reveals nothing.
- Finding 4, `MarketHoursHook`: a swap that starts where the pool has no liquidity in range is neither sampled nor the
  block's checkpoint; the block's first swap that starts inside liquidity is.
- Finding 5, `MarketHoursHook`: the reference set when the pool is initialised is held to ±875,220 and taken as the
  nearest bucket, exactly as each bell's reference is, so the first bell rings from any initial price and no bucket
  past the grid's last one enters a band.
- Finding 6, `MarketHoursHook`: the reply-length check in the round-trip guard reads the length of the router's own
  reply, so a reply shorter than a word is no identity and the signer is keyed.
- Finding 7: no contract change; accepted, see "Known and accepted" (a guess ticket at the band's passive edge).

## Since the second audit

Commit bc64b98 was audited in the public audit job 193411a0-b64c-477e-a785-e57fb254dd91. This commit answers its
eight findings:

- Findings 1 and 2, `MarketHoursHook`: the deposit cap counts a marketable order (a buy at or above the reference, a
  sell at or below it) in full, and a passive order by its distance from the reference, falling linearly from full at
  the reference to 1 % at the band's edge. A cancel still releases exactly what was counted.
- Finding 3, `MarketHoursHook`: the round-trip guard keys on the account the router reports through `msgSender()`
  when it answers with an address, and on the transaction's signer otherwise.
- Finding 4, `BellRinger`: the ring reward is priced at the lower of the ETH/IMD spot and the spot the previous ring
  read, so moving the pool inside the ringing transaction cannot raise the reward.
- Finding 5, `MarketHoursHook` and `BellGame`: a guess ticket needs an order of at least 5 IMD, valued at its book's
  reference, that stays in its book through a bell that rings; a cancelled order never earns one. Each wallet may
  seal one guess per day (`OneGuessPerDay`).
- Finding 6: no contract change: settle is permissionless and the site calls it at 12:30.
- Finding 7, `MarketHoursHook`: a bell refuses to ring before the pool is initialised (`NotEnterable`).
- Finding 8, `BellRinger`: `OVERHEAD`, the gas a ring costs its caller beyond what the ring counts itself, rises from
  60,000 to 95,000, and its test now counts the gas right when the test runner runs each call as its own
  transaction.

## Since the first audit

Commit 672a97b was audited in the public audit job a300cdb8-36eb-408a-9b46-c8d94d108cda. This commit fixes its
eleven findings and adds a cap on the residual swap:

1. `MarketHoursHook`: a bell rung from inside an already unlocked PoolManager is refused (`PoolUnlocked`). The only
   failure of the residual swap that is tolerated is the pool's own price limit; any other, running out of gas
   included, reverts the bell. The bell's gas floor rises from 7,000,000 to 10,600,000.
2. `MarketHoursHook`: a book's reference is the pool's own price (the session's checkpoint mean, else the last
   checkpoint's price), set by the bell that opens the book, never the last clearing price, and held inside the tick
   range.
3. `MarketHoursHook`: the deposit cap counts an order by its distance from the reference (in full at it, a tenth at
   the band's edge), and a cancel releases exactly what was counted.
4. `BellGame`: a day whose opening bell rings too late to leave a reveal window settles as void; no points are scored.
5. `MarketHoursHook`: an order that fills whole has paid for its guess ticket whatever its size, buy or sell.
6. `MarketHoursHook`: the constructor refuses a bell purse share that, with the swarm's share, exceeds the whole.
7. `MarketHoursHook`: `placeOrder` and `cancelOrder` refuse while the pool is not initialised.
8. `MarketHoursHook`: the round-trip guard keys on the transaction's signer, whatever the router.
9. `BellRinger`: a zero, absent or out-of-range ETH/IMD price read pays no reward (`NoPrice`), never the cap.
10. `BellRinger`: after a bell was rung directly at the hook, `ring()` still runs that bell's chores once and pays for
    its own gas; a second `ring()` for the same bell reverts (`BellAlreadyRung`) and pays nothing.
11. `MarketHoursHook`: an inner order the book fills only in part gets its remainder back without the unfilled-order
    fee, like the rationed marginal bucket.

Residual cap, `MarketHoursHook`: a bell's residual swap stops 120 buckets from the pool's price at the ring, or at the
clearing price's fee-inward limit, whichever is nearer. What the cap leaves unfilled comes back without the
unfilled-order fee. This bounds the gas a bell can need.

## Known and accepted

**The ring reward after a moved ring.** The ringer prices its reward at the lower of the ETH/IMD pool's spot and the
spot the previous ring stored, and it stores the raw spot its own transaction read. A ring made with the pool moved
the same way twice running is therefore paid at the moved price on the second, up to the 3 IMD cap; the first moved
ring is paid the honest stored price. This is accepted: moving the pool and moving it back inside one transaction
costs the mover the pool's 1 % fee on both legs, and nobody can trade between the two legs. Pushing the stored spot
down instead, so that the next honest ring is paid almost nothing, costs the mover the same fee on both legs. The
worst case is bounded: the purse pays at most the two ring caps and the push caps in a day, and the bells still ring,
because the reward is a bonus on a ring anyone can make. After a bell has been rung straight at the hook, the
ringer's own call runs without the hook's unlock guard, so the move, the ring and the restore can share one pool
unlock and settle net: the mover then needs the fee, not capital. No change; `test/RingerPrice.sol` keeps the
two-rings test and `test/audit-three/AuditThreeFinding1.t.sol` pins the accepted behaviour.

**A guess ticket at the band's passive edge.** A 5 IMD buy at the far passive edge of the book's band is never
reached by the bell, so at claim it pays only the 0.5 % unfilled-order fee, 0.025 IMD, and holds a paid guess ticket;
it counts 1 % of its value, 0.05 IMD, toward the deposit cap. Covering the 41 buckets within 1,200 ticks of the
reference this way costs about 1.025 IMD in fees plus gas, with 205 IMD held for a few hours, one fresh wallet per
bucket. The game pays points only, and one wallet per bucket is the limit of any per-wallet rule. No change; the
figures are pinned by `test/audit-three/AuditThreeFinding7.t.sol`.

## Build and test

```sh
forge build
forge test
```

The tests run offline against a local PoolManager and stand-in contracts (`test/Offline.t.sol`); no RPC URL or key is
needed. `test/repro/` holds one test file per finding of the first audit, and `test/audit-two/` one per finding of
the second (findings 1 and 2 share a file, as do 6 and 7), each asserting the behaviour the audit report calls
correct; for finding 6, that a settle at 12:30 opens the reveal window. `test/audit-three/` holds one per finding of
the third (findings 2 and 6 share a file): findings 2 to 6 assert the behaviour the audit report calls correct, and
the tests for findings 1 and 7, both accepted, pin the accepted behaviour, so they would fail if it changed.
`test/variants/` holds an earlier version of the hook, used only for a gas comparison.

Compiler settings are in `foundry.toml`: solc 0.8.26, via-IR, optimizer 50 runs, EVM version cancun, no metadata
hash. The tests pass on Foundry (forge) 1.5.1 and 1.8.3, each with its default settings. Dependencies are vendored
in `lib/`: forge-std v1.17.0 and Uniswap v4-core v4.0.0.

## Licence

MIT, see `LICENSE`.
