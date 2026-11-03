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
| `MarketHoursHook.sol` | The Uniswap v4 hook: the order books, the two bells, the session rules and the fee shares. Nobody owns it and nothing in it can be changed after deployment. At deployment it creates `BellGame`, `BellRinger` and `SwarmBudget`. |
| `MarketHoursCoin.sol` | A plain ERC-20 with a fixed supply minted once at deployment; anyone may burn their own coin. |
| `BellGame.sol` | The guessing game: sealed guesses (one per wallet per day, each on an order of at least 5 IMD kept in its book through the bell), reveals after the open settles, ranks and points. It holds no tokens. |
| `BellRinger.sol` | Rings whichever bell is due, runs that bell's chores, and pays the caller from the bell purse. |
| `SwarmBudget.sol` | A small purse that can only pay for two nightly requests to the network's Intake: a guess at the next open and a short report on the day. |
| `IIntake.sol` | The part of the network's Intake interface that `SwarmBudget` calls. |

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

## Build and test

```sh
forge build
forge test
```

The tests run offline against a local PoolManager and stand-in contracts (`test/Offline.t.sol`); no RPC URL or key is
needed. `test/repro/` holds one test file per finding of the first audit, and `test/audit-two/` one per finding of
the second (findings 1 and 2 share a file, as do 6 and 7), each asserting the behaviour the audit report calls
correct; for finding 6, that a settle at 12:30 opens the reveal window. `test/variants/` holds an earlier version of
the hook, used only for a gas comparison.

Compiler settings are in `foundry.toml`: solc 0.8.26, via-IR, optimizer 50 runs, EVM version cancun, no metadata
hash. The tests pass on Foundry (forge) 1.5.1 and 1.8.3, each with its default settings. Dependencies are vendored
in `lib/`: forge-std v1.17.0 and Uniswap v4-core v4.0.0.

## Licence

MIT, see `LICENSE`.
