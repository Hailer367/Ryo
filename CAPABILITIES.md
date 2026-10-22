# What Ryo Can (and Can't) Do

A plain-English guide to the Ryo smart contract's abilities. Ryo is the **engine**; your bot is the **driver**. Ryo never decides to trade on its own — it just does exactly what the bot tells it, safely, in one single transaction.

---

## What Ryo is

Ryo is a self-driving "trade machine" on Base. In one atomic transaction it:

1. Borrows a pile of one coin from Balancer (a "flash loan" — free to borrow, must be paid back in the same transaction).
2. Trades that pile across one or more DEXes to try to make it bigger.
3. Pays the loan back (plus any fee).
4. Checks that it actually made money.
5. Sends the profit to the owner.

If any step fails, the whole thing rewinds as if nothing happened. No money is ever left in the contract between trades.

---

## What it can do

### Borrowing and repaying
- Borrow **any single ERC-20 token** from the Balancer Vault (WETH, USDC, etc.) in one flash loan.
- Repay automatically, including Balancer's fee (currently 0 on Base, but supported if it changes).
- Measure profit as the real balance difference after repayment — not a guess.

### Trading
- **Two built-in "fast" routes** (cheapest to run, fixed at deploy time):
  - WETH → USDC → WETH (Uniswap V3 then Uniswap V2)
  - USDC → WETH → USDC (Uniswap V3 then Uniswap V2)
- **Any route your bot describes**, with as many steps as you want (at least 2), as long as the tokens chain together and end where they started.
- **Triangular routes** (A → B → C → A) and multi-hop routes.
- **Four exchange types**, mixed in any order:
  - Uniswap V3 (by pool fee: 0.01%, 0.05%, 0.3%, 1%)
  - Uniswap V2
  - Aerodrome (normal and "stable" pools)
  - Aerodrome Slipstream (concentrated liquidity, by tick spacing)
- Per-step safety floors: every step enforces a minimum output, so a router can't quietly give you nothing.
- A final profit floor (`minProfit`): the trade reverts if it doesn't beat it.

### Simulation (no risk)
- Simulate any route for free via `eth_call`. Ryo always reverts with a `SimulationResult(profit)` number — positive means profit, negative means loss. The bot uses this to decide whether to actually trade.

### Safety and limits
- **Per-asset cap** on how much can be borrowed in one trade (set by the owner; 0 = unlimited).
- **Gas-price cap** so the bot can't run when gas is too expensive.
- **Pause switch** the bot or owner can flip instantly; only the owner can unpause.
- **Router allow-list** — Ryo only trades through routers the owner has approved.
- **Reentrancy protection** — a malicious router can't trick Ryo into re-entering and losing money.
- **Callback hardening** — Ryo checks that the flash-loan callback really came from Balancer and matches what it asked for.

### Access control
- Two roles: **owner** (admin, holds the money) and **operator** (the bot's hot wallet).
- Ownership is transferred in two steps, so a typo can't hand the contract to the wrong address.
- The operator can execute trades, simulate, and pause — but cannot withdraw money, change routers, or unpause.

### Housekeeping
- Owner can pull out any leftover or accidental tokens/ETH.
- Accepts ETH sent to it (so the owner can rescue it later).

---

## What can be changed without redeploying

These are settings the owner tweaks on the live contract. No new contract needed.

| Setting | Who can change it |
|---|---|
| The operator (bot) address | Owner |
| The router allow-list (add/remove exchanges) | Owner |
| Max trade size per coin | Owner |
| Max gas price | Owner |
| Pause / unpause | Operator (pause) or owner (unpause) |
| Ownership | Two-step: owner proposes, new owner accepts |

---

## What cannot be changed without redeploying

These are baked into the contract at deploy time. To change them you deploy a new Ryo and point the bot at it.

- **The two fast routes** (which coins, which exchanges, which fee tiers).
- **The Balancer Vault address** (it's on Base mainnet, fixed).
- **The adapter set** — which DEX types Ryo knows (4, 6, 7, 8) and how they work. Adding a new exchange type means editing the contract code.
- **The core safety logic** (how profit is measured, how repayment works, the callback checks).
- **The primary routes are immutable** — even the owner can't edit them. They can only be disabled by removing the router from the allow-list.

---

## What Ryo cannot do

- **It can't watch prices or decide to trade.** That's the bot's job. Ryo only executes what it's told.
- **It can't handle native ETH.** It borrows and trades WETH (wrapped ETH) instead. WETH is ETH in a different form — same value, just labelled.
- **It can't handle "taxed" tokens.** Some tokens take a cut on every transfer; Ryo's balance checks would fail. Those tokens are unusable.
- **It can't borrow two coins at once.** One flash loan = one token.
- **The fast route has no per-step safety net.** It only checks the final profit, not each individual hop. (The dynamic route does have per-step floors.)
- **It's not upgradeable.** There's no proxy. If the code needs to change, deploy a new one.
- **It's not audited.** Use at your own risk.
- **It's built for Base mainnet.** The addresses and chain checks assume Base.

---

## In one sentence

Ryo is a cautious, atomic trade machine: it borrows, swaps, repays, checks the profit, and sends the profit to the owner — and if anything goes wrong, it pretends the whole thing never happened.
