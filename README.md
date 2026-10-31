# IMD Bell contracts

IMD Bell is a coin that trades during one session a day. While the market is closed, anyone may leave a limit
order; the orders wait in a book and are filled at one price when the opening bell rings at 12:00 UTC. The pool then
trades until 16:00 UTC, when the closing bell clears a second book the same way. Every order also earns one sealed
guess at the next day's opening price, and the closest guesses score points (never money). Whoever rings a bell
first is paid a small reward for the gas.

**Not yet deployed.**

## Contracts (`src/`)

| File | What it is |
|---|---|
| `MarketHoursHook.sol` | The Uniswap v4 hook: the order books, the two bells, the session rules and the fee shares. Nobody owns it and nothing in it can be changed after deployment. At deployment it creates `BellGame`, `BellRinger` and `SwarmBudget`. |
| `MarketHoursCoin.sol` | A plain ERC-20 with a fixed supply minted once at deployment; anyone may burn their own coin. |
| `BellGame.sol` | The guessing game: sealed guesses, reveals after the open settles, ranks and points. It holds no tokens. |
| `BellRinger.sol` | Rings whichever bell is due, runs that bell's chores, and pays the caller from the bell purse. |
| `SwarmBudget.sol` | A small purse that can only pay for two nightly requests to the network's Intake: a guess at the next open and a short report on the day. |
| `IIntake.sol` | The part of the network's Intake interface that `SwarmBudget` calls. |

## Build and test

```sh
forge build
forge test
```

The tests run offline against a local PoolManager and stand-in contracts (`test/Offline.t.sol`); no RPC URL or key is
needed. `test/variants/` holds an earlier version of the hook, used only for a gas comparison.

Compiler settings are in `foundry.toml`: solc 0.8.26, via-IR, optimizer 200 runs, EVM version cancun, no metadata
hash. Built and tested with Foundry (forge) 1.5.1. Dependencies are vendored in `lib/`: forge-std v1.17.0 and
Uniswap v4-core v4.0.0.

## Licence

MIT, see `LICENSE`.
