# Ryo

`Ryo` is a Balancer V2 flash-loan arbitrage executor for **Base mainnet**. It borrows a single
ERC20 asset from the Balancer Vault, executes a coherent DEX route, repays the loan plus fee, checks
the realized profit, and sends that profit to the owner — all in one atomic transaction.

- Solidity `0.8.38` (source pragma `^0.8.28`), Foundry, `forge-std`, OpenZeppelin.
- Two immutable primary routes for the watcher's fast path.
- One parameterized route with an arbitrary number of swaps (>= 2).
- Four adapters: Uniswap V3 `SwapRouter02`, Uniswap V2-style, Aerodrome classic (volatile and
  stable pools), and Aerodrome Slipstream (concentrated liquidity).
- `eth_call`-only simulations that revert with the measured profit.
- Owner/operator separation, two-step ownership, pause, router whitelist, per-asset trade caps, and a
  gas-price cap.

Watcher ABI, `Swap` layout, `extraData` encodings, errors, and events:
[`WATCHER_INTERFACE.md`](WATCHER_INTERFACE.md).

---

## How it works

```text
owner / operator
      │
      ▼
execute(asset, amount, swaps, minProfit)
executePrimary(routeId, amount, minProfit)
      │
      ├─ validate role, pause, gas price, trade size, route, router whitelist, extraData
      │
      ▼
Balancer Vault.flashLoan(Ryo, [asset], [amount], userData)
      │
      ├─ Vault transfers `amount` to Ryo
      ├─ Vault calls Ryo.receiveFlashLoan(...)
      │     ├─ require msg.sender == vault
      │     ├─ require keccak256(userData) == transient expected hash
      │     ├─ require callback not already consumed
      │     ├─ require borrowed token/amount match transient state
      │     ├─ re-validate route and execute swaps
      │     │     ├─ approve exact amount to router
      │     │     ├─ swap
      │     │     ├─ measure output by balance difference
      │     │     ├─ enforce non-zero minOut
      │     │     └─ reset router approval
      │     └─ transfer amount + Balancer fee back to the Vault
      │
      ├─ Vault verifies its post-loan balance
      └─ Ryo measures profit as its asset balance delta
      │
      ├─ revert if profit < minProfit
      ├─ transfer profit to owner
      └─ emit execution event
```

Balancer V2 does **not** pull repayment through an allowance. The recipient must transfer the loan
plus fee back to the Vault inside the callback; the Vault then checks its own balance. Ryo follows
that model.

The contract holds no funds between transactions. Profit is sent to `owner()` before returning.
The owner retains `withdraw`/`rescue` functions for accidental balances.

---

## Repository layout

```text
src/
  Ryo.sol                       Executor
  interfaces/
    IBalancerVault.sol          Minimal Vault interface
    IFlashLoanRecipient.sol     Balancer callback interface
    ISwapRouter02.sol           SwapRouter02 struct and function
    IUniswapV2Router02.sol      V2 router function
    IAerodromeRouter.sol        Aerodrome classic router (route hops)
    ISlipstreamSwapRouter.sol   Aerodrome Slipstream router (tick spacing)
script/
  Deploy.s.sol                  Env-driven Base mainnet deployment
test/
  Ryo.t.sol                     Unit, access, adversarial, token, admin tests
  RyoAssembly.t.sol             Calldata differential and gas tests
  RyoFork.t.sol                 Base fork tests, profit paths, historical replay
  harness/RyoHarness.sol        Test-only access to the production paths
  harness/RyoPlainReference.sol Plain-Solidity reference implementations
  mocks/                        Tokens, Vault, V2/V3/Aerodrome/Slipstream routers
foundry.toml
WATCHER_INTERFACE.md
GAS.md
.env.example
LICENSE
.gas-snapshot
```

---

## Setup

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation) and a Base RPC
endpoint for fork tests.

```bash
git clone --recurse-submodules <repo-url> ryo
cd ryo

# If the repo was cloned without submodules:
git submodule update --init --recursive

cp .env.example .env
# Edit OWNER, OPERATOR, caps, etc.
set -a
source .env
set +a
```

```bash
forge build
forge test
```

The default test suite is offline and uses mocks. Fork tests are skipped automatically when
`BASE_RPC_URL` is empty.

---

## Tests

### Offline suite

```bash
forge test -vv
```

Coverage includes:

- profit paths through primary and parameterized routes;
- triangular routes and explicit V2 multi-hop paths;
- Aerodrome classic (volatile and stable pools) and Slipstream routes, with the pool-type flag and
  tick spacing checked;
- simulation profit/loss and exact `SimulationResult` decoding;
- route length/coherence/asset-return validation;
- unsupported DEX ids, malformed `extraData`, bad V2 paths;
- router whitelist, pause, roles, two-step ownership;
- gas-price and per-asset trade-size limits;
- direct/fake-vault callbacks, skipped callbacks, replay/consumed callback;
- reentrancy through a malicious router;
- fee-on-transfer repayment failure;
- withdraw/rescue and no-funds-held behavior;
- byte-for-byte calldata differential against a plain-Solidity reference.

### Assembly differential tests

```bash
forge test --match-path test/RyoAssembly.t.sol -vv
```

These compare the hand-written V3 calldata against a plain ABI-encoded call, byte for byte,
including a fuzzed fee and amount, and measure the gas of both.

### Base fork tests

```bash
BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path test/RyoFork.t.sol -vvv
```

The profit tests deliberately create a deterministic price gap in the Uniswap V2 or Aerodrome
WETH/USDC pair:

- Route 0 dumps `100 ether` of WETH into Uniswap V2, then runs WETH -> USDC (V3) -> WETH (V2).
- Route 1 dumps `100,000 USDC` into Uniswap V2, then runs USDC -> WETH (V3) -> USDC (V2).
- The Aerodrome test dumps `100 ether` of WETH into the Aerodrome volatile pool, then runs
  WETH -> USDC (V3) -> WETH (Aerodrome).

Additional fork tests round-trip through the real Aerodrome volatile pool, the Aerodrome stable pool
and the real Slipstream router.

The historical replay test logs the simulated primary-route result at the fork block.

Pin a block for reproducible runs:

```bash
BASE_RPC_URL=... BASE_FORK_BLOCK=52943185 \
  forge test --match-path test/RyoFork.t.sol -vvv
```

### Gas snapshot and report

```bash
forge snapshot
forge test --gas-report
```

See [`GAS.md`](GAS.md) for the recorded hot-path numbers and the assembly comparison.

---

## Deployment (Base mainnet)

The deploy script refuses any chain other than Base mainnet (8453) and requires the Vault address to
have code. It reads all constructor arguments from environment variables.

1. Fund the deployer.
2. Import a keystore account (no raw private key in shell history):

```bash
cast wallet import ryo-deployer --interactive
```

3. Fill `.env` from `.env.example`. At minimum: `BASE_RPC_URL`, `OWNER`, `OPERATOR`, and the two
   route configurations. `EXTRA_ROUTERS` is comma-separated and may be empty. `MAX_GAS_PRICE=0`
   disables the gas-price check.
4. Dry run against Base (no broadcast):

```bash
set -a; source .env; set +a

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BASE_RPC_URL" \
  --account ryo-deployer
```

5. Broadcast and verify:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BASE_RPC_URL" \
  --account ryo-deployer \
  --broadcast \
  --verify \
  --etherscan-api-key "$BASESCAN_API_KEY"
```

6. If automatic verification fails, verify manually:

```bash
forge verify-contract <DEPLOYED_ADDRESS> src/Ryo.sol:Ryo \
  --chain base \
  --guess-constructor-args \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  --watch
```

The script prints the deployed address, owner, operator, and primary routes.

### Default route configuration

`.env.example` deploys:

- Route 0: borrow WETH -> USDC on Uniswap V3 fee 500 -> WETH on Uniswap V2.
- Route 1: borrow USDC -> WETH on Uniswap V3 fee 500 -> USDC on Uniswap V2.
- Per-asset caps: `0` (unlimited) — the bot is the primary safety net. Set a number to add a
  hard ceiling on top of the bot's own limits.
- `MAX_GAS_PRICE=0` (disabled) — the bot checks gas itself.
- Routers are auto-whitelisted.

The primary route configuration is immutable. To change a route, deploy a new executor.

---

## Operations

### Rotate the operator

```solidity
ryo.setOperator(newOperator); // owner only
```

### Add or remove a router

```solidity
ryo.setRouterWhitelist(router, true);  // owner only
ryo.setRouterWhitelist(router, false); // owner only
```

The router must be whitelisted before a dynamic route can use it. Primary routers are
auto-whitelisted at deployment, but can still be removed.

To use Aerodrome, whitelist its two routers once:

```solidity
ryo.setRouterWhitelist(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43, true); // Aerodrome classic
ryo.setRouterWhitelist(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5, true); // Aerodrome Slipstream
```

### Set trade caps

```solidity
ryo.setMaxTradeSize(asset, maxAmount); // 0 = unlimited
ryo.setMaxGasPrice(maxGasPrice);       // 0 = disabled
```

### Pause

```solidity
ryo.pause();   // operator or owner
ryo.unpause(); // owner only
```

Simulations remain callable while paused because they are `eth_call`-only.

---

## Adding a DEX adapter

Adapters are branches in the contract, not separate deployed contracts. Supported today:

| `dexType` | Venue | Router ABI |
| ---: | --- | --- |
| `4` | Aerodrome classic | `swapExactTokensForTokens(uint256,uint256,Route[],address,uint256)` |
| `6` | Uniswap V3 / SwapRouter02 | `exactInputSingle(ExactInputSingleParams)` |
| `7` | Aerodrome Slipstream | `exactInputSingle(ExactInputSingleParams)` with tick spacing |
| `8` | Uniswap V2-style | `swapExactTokensForTokens(uint256,uint256,address[],address,uint256)` |

Any router that speaks one of these ABIs can be used with the matching `dexType` once it is
whitelisted — Uniswap V2, SushiSwap, PancakeSwap and BaseSwap all work with `dexType 8` today.

To add a genuinely new venue:

1. **Reserve a new `dexType` id.** Existing ids are listed in `WATCHER_INTERFACE.md`; do not reuse
   them.
2. **Add a constant** in `src/Ryo.sol`, e.g. `uint8 public constant DEX_NEW = 12`.
3. **Define its `extraData` encoding.** Keep it fixed-length where possible and validate exact
   lengths before decoding.
4. **Add validation** in `_validateExtraData` and a decoder (plain or assembly if it measurably
   saves gas).
5. **Add dispatch** in `_dispatch` and, if the primary routes should use it, in
   `_executePrimarySwaps` and `_validatePrimaryRoute`.
6. **Follow the safety pattern:** approve the exact input, call the router, measure output by
   balance difference, enforce a non-zero `minOut`, and reset the approval.
7. **Add tests:** mock adapter behavior, malformed data, output floor, router revert bubbling,
   reentrancy, and a differential or fork test against the real router where possible.
8. **Whitelist the router** with `setRouterWhitelist` after deployment.
9. **Redeploy** the executor; adapter code is not upgradeable.

A router with a different function signature or path model needs its own adapter id — that is
exactly why Aerodrome classic (`4`) and Aerodrome Slipstream (`7`) exist next to the Uniswap ones.

---

## Security notes

- The operator key is hot and limited to execution/simulation/pause. It cannot withdraw, rescue,
  change routers, unpause, or transfer ownership.
- `receiveFlashLoan` checks `msg.sender == vault`, a transient hash of the exact `userData`, a
  transient consumed flag, and the borrowed token/amount.
- `ReentrancyGuardTransient` covers the outer call, so routers cannot re-enter execution.
- Balancer's post-loan check enforces full repayment; Ryo transfers `amount + fee` explicitly.
- Output is measured by balance difference, not by router return values.
- Router approvals are exact and reset after each swap.
- `minProfit` is the final economic guard; per-hop `minAmountOut` defaults to `1`. Encode explicit
  per-hop floors if needed.
- Fee-on-transfer tokens are not supported as the borrowed asset or route token.
- Primary routes are immutable. The owner can still disable a primary router through the whitelist.

This code has not been audited. Use at your own risk.

---

## Verified Base addresses

See the address table and references in
[`WATCHER_INTERFACE.md`](WATCHER_INTERFACE.md#10-verified-base-addresses).

Key addresses used by the example deployment:

| Contract | Address |
| --- | --- |
| Balancer V2 Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Uniswap V2 Router02 | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| Aerodrome Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |
| Aerodrome Slipstream SwapRouter | `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

---

## License

MIT.
