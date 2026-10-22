# Ryo watcher interface

Ryo is a Balancer V2 flash-loan arbitrage executor on **Base mainnet (chain id 8453)**. This
document is the integration contract for the off-chain watcher: ABI signatures, calldata
encodings, profit semantics, simulations, errors, and operational limits.

The Solidity source of truth is [`src/Ryo.sol`](src/Ryo.sol).

---

## 1. Roles and lifecycle

| Role | Can do | Cannot do |
| --- | --- | --- |
| `owner` | Everything the operator can do, plus admin functions, unpause, ownership transfer | — |
| `operator` | `execute`, `executePrimary`, `simulate`, `simulatePrimary`, `pause` | Admin functions, unpause, withdraw/rescue |
| Anyone else | Read-only views | Any state-changing call |

- `operator` is intended for the watcher hot wallet.
- Ownership uses OpenZeppelin `Ownable2Step`: `transferOwnership` then `acceptOwnership`.
- `pause()` can be called by either role. Only `owner` can `unpause()`.
- Execution is blocked while paused. Simulations are not blocked by pause because they are
  `eth_call`-only and never persist state.

Read role/state with:

```solidity
owner() external view returns (address)
pendingOwner() external view returns (address)
operator() external view returns (address)
paused() external view returns (bool)
maxGasPrice() external view returns (uint256)
maxTradeSize(address asset) external view returns (uint256)
isRouterWhitelisted(address router) external view returns (bool)
isSupportedDexType(uint8 dexType) external view returns (bool)
primaryRoute(uint8 routeId) external view returns (PrimaryRouteConfig)
```

`PrimaryRouteConfig` is the tuple:

```solidity
(address asset, address intermediate, address buyRouter, address sellRouter,
 uint8 buyDexType, uint8 sellDexType, uint24 buyFee, uint24 sellFee)
```

`asset == address(0)` means the primary route is disabled. Primary routes are immutable; changing
one requires deploying a new executor.

---

## 2. Execution entry points

### 2.1 Parameterized route

```solidity
function execute(
    address asset,
    uint256 amount,
    Swap[] calldata swaps,
    uint256 minProfit
) external returns (uint256 profit);
```

ABI form:

```text
execute(address,uint256,(uint8,address,address,address,bytes)[],uint256)
```

- `asset`: token borrowed from Balancer. It must equal `swaps[0].tokenIn` and the last
  `swaps[n-1].tokenOut`.
- `amount`: amount borrowed, in `asset` units.
- `swaps`: at least 2 swaps. Each `tokenIn` must equal the previous `tokenOut`.
- `minProfit`: minimum acceptable profit, in `asset` units, after repayment. Reverts if actual profit
  is negative or `< minProfit`.
- Returns the profit that was transferred to `owner()`.

Supported adapters in `swaps[].dexType`: `4` Aerodrome classic, `6` Uniswap V3, `7` Aerodrome
Slipstream, `8` Uniswap V2-style. See section 4 for the `extraData` encoding of each.

### 2.2 Immutable primary route

```solidity
function executePrimary(
    uint8 routeId,
    uint256 amount,
    uint256 minProfit
) external returns (uint256 profit);
```

- `routeId` must be `0` or `1` and that route must be configured (`asset != address(0)`).
- The route executes exactly two swaps: `asset -> intermediate -> asset`.
- Minimum calldata and no dynamic route decoding. Intended as the watcher fast path.
- Same `minProfit` semantics as `execute`.

### 2.3 Example primary routes

The example deployment in `.env.example` configures:

| Route | Asset | Path | Buy | Sell |
| ---: | --- | --- | --- | --- |
| `0` | WETH | WETH -> USDC -> WETH | Uniswap V3, fee 500 | Uniswap V2 direct |
| `1` | USDC | USDC -> WETH -> USDC | Uniswap V3, fee 500 | Uniswap V2 direct |

Both routes rely on `minProfit`; the internal per-swap floor is `1`. Query the live configuration
with `primaryRoute(0)` / `primaryRoute(1)`.

### 2.4 `Swap`

```solidity
struct Swap {
    uint8 dexType;       // 6 = Uniswap V3 / SwapRouter02; 8 = Uniswap V2-style
    address router;      // must be whitelisted by the owner
    address tokenIn;
    address tokenOut;
    bytes extraData;     // adapter-specific, see section 4
}
```

The ABI tuple order is exactly `(uint8,address,address,address,bytes)`. The final `bytes` is
dynamic, so use the canonical tuple array encoding from your ABI library.

---

## 3. Profit, repayment, and limits

### 3.1 Repayment

Balancer V2 flash loans are **not repaid by allowance**. The Vault:

1. Records its pre-loan token balance.
2. Transfers `amount` to Ryo.
3. Calls `receiveFlashLoan`.
4. After the callback returns, checks that its balance is at least `preLoanBalance + fee`.

Ryo therefore transfers `amount + feeAmounts[0]` directly back to the Vault inside the callback.
An approval to the Vault is neither needed nor used.

Balancer's current Base flash-loan fee is `0`, but the implementation uses the `feeAmounts` supplied
by the Vault, so a future non-zero fee is handled automatically.

### 3.2 Profit measurement

`profit` is the **balance delta of `asset` on Ryo after repayment**:

```text
profit = balanceOf(asset, Ryo) after Vault repayment - balanceOf(asset, Ryo) before flashLoan
```

- Positive profit is transferred to `owner()` before the execution returns.
- Ryo keeps no funds between transactions (apart from accidental dust that the owner can rescue).
- If the result is negative or below `minProfit`, the whole transaction reverts, including repayment.
- `minProfit = 0` still rejects a loss; it only allows zero or positive profit.

### 3.3 Per-swap output floors

Every swap enforces a non-zero `amountOutMinimum`/`minAmountOut`:

- V3: `minAmountOut` from `extraData`, or `1` if omitted.
- V2: `minAmountOut` from `extraData`, or `1` if omitted.
- A supplied value of `0` is normalized to `1`.

The per-swap floor mainly protects against a router returning less than the encoded expectation. The
final economic guard is `minProfit`, because an attacker cannot make the route profitable by
manipulating a single hop without changing the final balance.

For strong per-hop slippage protection, the watcher should encode an explicit `minAmountOut` in
`extraData` for each swap in addition to `minProfit`. The primary routes intentionally use only the
non-zero `1` floor and rely on `minProfit`.

### 3.4 Trade size and gas price

- `maxTradeSize[asset]`: maximum borrow amount per execution. `0` means unlimited.
  Exceeding it reverts with `TradeSizeExceeded(asset, amount, maxAmount)`.
- `maxGasPrice`: maximum `tx.gasprice`. `0` disables the check.
  Exceeding it reverts with `GasPriceTooHigh(maxGasPrice, actualGasPrice)`.
- Both checks happen before the flash loan. The gas-price check applies to `execute` and
  `executePrimary`, not to simulations.

### 3.5 Router whitelist

Every `router` must be whitelisted. Routing is checked before the loan and re-checked in the
callback. Primary routers are auto-whitelisted at deployment. The owner can add or remove routers
with `setRouterWhitelist`.

To use Aerodrome or Slipstream, the owner must whitelist their routers once:

```solidity
ryo.setRouterWhitelist(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43, true); // Aerodrome classic
ryo.setRouterWhitelist(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5, true); // Aerodrome Slipstream
```

If the owner removes a primary route's router, that primary route stops working until it is
re-added or the contract is redeployed.

---

## 4. `extraData` encodings

### 4.1 `dexType = 6` — Uniswap V3 / SwapRouter02

Two exact lengths are accepted:

| Length | Encoding | Meaning |
| --- | --- | --- |
| 32 bytes | `abi.encode(uint24 fee)` | Fee tier; `minAmountOut = 1` |
| 64 bytes | `abi.encode(uint24 fee, uint256 minAmountOut)` | Fee tier and explicit floor |

Examples:

```solidity
abi.encode(uint24(500))                    // 32 bytes, 0.05% pool
abi.encode(uint24(3000), uint256(1_000e6)) // 64 bytes, 0.30% pool, min 1,000 USDC
```

Ryo calls SwapRouter02 `exactInputSingle` with:

```solidity
ExactInputSingleParams({
    tokenIn: tokenIn,
    tokenOut: tokenOut,
    fee: fee,
    recipient: address(ryo),
    amountIn: amountIn,
    amountOutMinimum: minAmountOut,
    sqrtPriceLimitX96: 0
})
```

Notes:

- SwapRouter02 has no `deadline` field in `ExactInputSingleParams`.
- The call is made to the router configured in the swap; the selector is
  `0x04e45aaf`.
- The return value is ignored. Output is measured by Ryo's balance difference and checked against
  `minAmountOut`.
- The fee tier must correspond to a pool deployed on that router. Ryo does not validate pool
  existence.

### 4.2 `dexType = 8` — Uniswap V2-style

| Length | Encoding | Meaning |
| --- | --- | --- |
| `0` bytes | empty | Direct `tokenIn -> tokenOut` pair; `minAmountOut = 1` |
| `>= 160` bytes, multiple of 32 | `abi.encode(address[] path, uint256 minAmountOut)` | Explicit V2 path and floor |

Examples:

```solidity
"" // direct pair
abi.encode(path, uint256(1_000e6)) // custom path, e.g. WETH -> USDC -> DAI
```

Rules:

- `path.length >= 2`.
- `path[0] == swap.tokenIn`.
- `path[path.length - 1] == swap.tokenOut`.
- No zero addresses in `path`.
- `minAmountOut = 0` is normalized to `1`.
- Ryo calls `swapExactTokensForTokens(amountIn, minAmountOut, path, address(ryo), block.timestamp)`.

### 4.3 `dexType = 4` — Aerodrome classic (volatile and stable pools)

Aerodrome's router takes a list of **hops** rather than a plain token list, and every hop says
whether its pool is a "stable" pool (pegged assets) or a "volatile" one.

| Length | Encoding | Meaning |
| --- | --- | --- |
| `>= 256` bytes, multiple of 32 | `abi.encode(address[] path, bool[] stablePerHop, uint256 minAmountOut)` | Token path, one pool-type flag per hop, output floor |

Example:

```solidity
address[] memory path = new address[](2);
path[0] = USDC;
path[1] = WETH;
bool[] memory stablePerHop = new bool[](1);
stablePerHop[0] = false; // volatile pool
bytes memory extra = abi.encode(path, stablePerHop, uint256(1));
```

Rules:

- `path.length >= 2`.
- `stablePerHop.length == path.length - 1` — one flag per hop.
- `path[0] == swap.tokenIn`, `path[path.length - 1] == swap.tokenOut`.
- No zero addresses in `path`.
- `minAmountOut = 0` is normalized to `1`.
- The encoding must be exact: `extraData.length == 32 * (5 + path.length + stablePerHop.length)`.
  Trailing junk is rejected with `InvalidExtraData`.
- The pool factory is always the router's default factory. To trade a pool from a different
  Aerodrome factory, point `swap.router` at the router of that factory.
- Ryo calls
  `swapExactTokensForTokens(amountIn, minAmountOut, routes, address(ryo), block.timestamp)` where
  each route is `{from: path[i], to: path[i+1], stable: stablePerHop[i], factory: address(0)}`.

### 4.4 `dexType = 7` — Aerodrome Slipstream (concentrated liquidity)

Slipstream is Aerodrome's Uniswap-V3-style concentrated liquidity AMM. Its router identifies a
pool by **tick spacing** rather than a fee tier, and it carries an extra deadline field.

| Length | Encoding | Meaning |
| --- | --- | --- |
| 32 bytes | `abi.encode(int24 tickSpacing)` | Tick spacing; `minAmountOut = 1` |
| 64 bytes | `abi.encode(int24 tickSpacing, uint256 minAmountOut)` | Tick spacing and explicit floor |

Example:

```solidity
abi.encode(int24(1))                     // 32 bytes, tick spacing 1
abi.encode(int24(1), uint256(1_000e6))   // 64 bytes, tick spacing 1 with a floor
```

Rules:

- `tickSpacing` is signed and must be a valid Slipstream tick spacing for the pool.
- `minAmountOut = 0` is normalized to `1`.
- Ryo calls `exactInputSingle` with
  `(tokenIn, tokenOut, tickSpacing, recipient, deadline = block.timestamp, amountIn, amountOutMinimum, sqrtPriceLimitX96 = 0)`.

### 4.3 `dexType` ids

| ID | Adapter | Status |
| --- | --- | --- |
| `4` | Aerodrome classic (volatile + stable pools) | Implemented |
| `6` | Uniswap V3 / SwapRouter02 | Implemented |
| `7` | Aerodrome Slipstream (concentrated liquidity) | Implemented |
| `8` | Uniswap V2-style `swapExactTokensForTokens` | Implemented |

Reserved and currently unsupported: `1` canonical Uniswap V2, `2` SushiSwap V2, `3` PancakeSwap V2,
`5` Curve, `9` WOOFi, `10` Maverick, `11` Algebra (concentrated liquidity with a different router
ABI). Any other value reverts with `UnsupportedDexType(id)`. Do not reuse ids.

The exact set is queryable with `isSupportedDexType(uint8)`.

> **Note:** Uniswap V2 and other classic V2-style routers (SushiSwap, PancakeSwap, BaseSwap) are
> *not* limited to `dexType 8`. Any router exposing the standard
> `swapExactTokensForTokens(amountIn, minOut, path, to, deadline)` ABI can be whitelisted and used
> with `dexType 8` today — no contract change needed. `dexType 8` does not check which factory the
> router belongs to.
>
> `dexType 4` and `dexType 7` are needed because Aerodrome's routers speak a different language:
> Aerodrome classic takes a list of "route hops" instead of a token list, and Slipstream identifies
> pools by tick spacing instead of a fee tier.

---

## 5. Simulations

Simulations are `eth_call`-only. They always revert, even on success, with:

```solidity
error SimulationResult(int256 profit);
```

Selector: `0x00cf1ea6`.

```solidity
function simulate(address asset, uint256 amount, Swap[] calldata swaps) external;
function simulatePrimary(uint8 routeId, uint256 amount) external;
```

- Call from the `operator` (or owner) address.
- Decode the revert data after the 4-byte selector as `int256`.
- Positive = profit in `asset` units; negative = loss.
- Simulations do not require the route to be profitable.
- For a loss, the callback reverts with `SimulationResult` before repaying the Vault, so an
  unaffordable simulation does not produce `BAL#515`/`INVALID_POST_LOAN_BALANCE`.
- Validation errors (bad route, unwhitelisted router, bad `extraData`, oversized trade) revert with
  their normal custom error instead of `SimulationResult`.
- Pause and `maxGasPrice` do not block simulation.

Example watcher flow:

```ts
// ethers v6
try {
  await ryo.connect(operator).simulate.staticCall(asset, amount, swaps);
} catch (err) {
  const data = err.data ?? err.error?.data;
  if (data?.slice(0, 10) === "0x00cf1ea6") {
    const [profit] = ethers.AbiCoder.defaultAbiCoder().decode(
      ["int256"],
      "0x" + data.slice(10),
    );
    // profit is signed; compare against minProfit
  }
}
```

`simulatePrimary` uses the same `SimulationResult` error.

---

## 6. Errors

All errors are custom errors (4-byte selector, no revert strings).

| Error | Selector | Meaning |
| --- | --- | --- |
| `NotOperator(address caller)` | `0x76c6c93a` | Caller is neither operator nor owner |
| `ContractPaused()` | `0xab35696f` | Execution while paused |
| `AlreadyPaused()` | `0x1785c681` | `pause()` called twice |
| `NotPaused()` | `0x6cd60201` | `unpause()` while not paused |
| `ZeroAddress()` | `0xd92e233d` | Required address is zero |
| `ZeroAmount()` | `0x1f2a2005` | Borrow amount is zero |
| `InvalidRouteId(uint8 routeId)` | `0x74ccd6f2` | Route id is not 0/1 or route is disabled |
| `RouteTooShort()` | `0x1910af8f` | Fewer than 2 swaps |
| `RouteMismatch(uint256 index)` | `0x4b2b2d57` | Token chain is incoherent or does not return to borrowed asset |
| `InvalidSwap(uint256 index)` | `0x9b4409ec` | `tokenIn == tokenOut` |
| `RouterNotWhitelisted(address router)` | `0x82e73dd1` | Router is not allowed |
| `UnsupportedDexType(uint8 dexType)` | `0x873cacfe` | No adapter for id |
| `InvalidExtraData(uint256 index)` | `0x07a0578a` | Wrong length/encoding for adapter |
| `InvalidPath(uint256 index)` | `0xa876f871` | Bad V2 path endpoints/zero address |
| `UnauthorizedCallback()` | `0xf5c6c81a` | Callback not from the configured Vault |
| `UnexpectedCallback()` | `0xdab1e993` | Callback lacks a matching active loan, replayed, or Vault skipped callback |
| `InvalidFlashLoanData()` | `0x19dbc929` | Unexpected token/amount in callback |
| `InsufficientProfit(uint256 minProfit, int256 actualProfit)` | `0x4e8fafd1` | Actual profit is negative or below `minProfit` |
| `TradeSizeExceeded(address asset, uint256 amount, uint256 maxAmount)` | `0x57f3d5b9` | Borrow exceeds `maxTradeSize` |
| `GasPriceTooHigh(uint256 maxGasPrice, uint256 actualGasPrice)` | `0x94118333` | `tx.gasprice` exceeds configured maximum |
| `SwapBalanceDecreased(uint256 index)` | `0x055348e0` | Measured output balance fell (adapter/token anomaly) |
| `InsufficientOutput(uint256 index, uint256 minOut, uint256 actualOut)` | `0x3f612d47` | Measured output below encoded floor |
| `InvalidPrimaryRoute(uint8 routeId)` | `0x67df7008` | Constructor config invalid |
| `EthTransferFailed()` | `0x6d963f88` | ETH withdraw/rescue failed |
| `SimulationResult(int256 profit)` | `0x00cf1ea6` | Simulation result; always reverts |

---

## 7. Events

```solidity
event PrimaryExecuted(
    address indexed operator, uint8 indexed routeId, address indexed asset,
    uint256 amountBorrowed, uint256 profit
);

event ArbitrageExecuted(
    address indexed operator, address indexed asset,
    uint256 amountBorrowed, uint256 profit, uint256 swapCount
);

event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
event RouterWhitelistUpdated(address indexed router, bool allowed);
event MaxTradeSizeUpdated(address indexed asset, uint256 maxAmount);
event MaxGasPriceUpdated(uint256 maxGasPrice);
event Paused(address indexed account);
event Unpaused(address indexed account);
event Withdrawn(address indexed token, address indexed to, uint256 amount);
event EthWithdrawn(address indexed to, uint256 amount);
event Rescued(address indexed token, address indexed to, uint256 amount);
event EthRescued(address indexed to, uint256 amount);
```

`PrimaryExecuted` and `ArbitrageExecuted` are emitted only after a successful execution and profit
transfer. Reverted transactions emit nothing.

---

## 8. Admin interface

```solidity
function setOperator(address newOperator) external;                 // owner
function setRouterWhitelist(address router, bool allowed) external; // owner
function setMaxTradeSize(address asset, uint256 maxAmount) external; // owner, 0 = unlimited
function setMaxGasPrice(uint256 newMaxGasPrice) external;           // owner, 0 = disabled
function pause() external;                                          // operator or owner
function unpause() external;                                        // owner
function withdraw(address token, uint256 amount) external;          // owner, sends to owner
function withdrawETH(uint256 amount) external;                      // owner, sends to owner
function rescueTokens(address token, address to, uint256 amount) external; // owner
function rescueETH(address to, uint256 amount) external;            // owner
```

`withdraw`/`withdrawETH` always send to `owner()`. `rescueTokens`/`rescueETH` allow the owner to
send accidental balances to an arbitrary recipient.

To change the operator after a key rotation, call `setOperator` from the owner.

---

## 9. Security model relevant to integration

- `receiveFlashLoan` requires `msg.sender == vault`.
- The callback must match `keccak256(userData)` stored transiently immediately before
  `vault.flashLoan`; the expected hash is cleared after the loan.
- A transient consumed flag rejects a second callback in the same transaction.
- Borrowed token and amount must match the transient expected values.
- `ReentrancyGuardTransient` covers the outer entry points, so a malicious router cannot re-enter
  `execute`/`simulate`.
- The callback re-validates every decoded swap, router whitelist, and token chain before spending
  loaned funds.
- Approvals to routers are exact and reset after each swap.
- Output is measured by token balance difference, not by router return data.
- Ryo holds no funds between executions; profit is sent to the owner.

The `operator` key is hot. It cannot withdraw funds, change routers, unpause, or transfer ownership.
Keep `maxTradeSize` and `maxGasPrice` configured for the watcher's risk budget.

---

## 10. Verified Base addresses

These are the addresses used by the deployment example and fork tests. They were checked against
the official deployment registries and on-chain code; this document does not invent addresses.

| Contract | Base mainnet address |
| --- | --- |
| Balancer V2 Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Uniswap V2 Router02 | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| Uniswap V2 Factory | `0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6` |
| Aerodrome Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |
| Aerodrome PoolFactory | `0x420DD381b31aEf6683db6B902084cB0FFECe40Da` |
| Aerodrome Slipstream SwapRouter | `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` |
| Aerodrome Slipstream PoolFactory | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Uniswap V3 WETH/USDC 0.01% pool | `0xb4CB800910B228ED3d0834cF79D697127BBB00e5` |
| Uniswap V3 WETH/USDC 0.05% pool | `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| Uniswap V3 WETH/USDC 0.30% pool | `0x6c561B446416E1A00E8E93E221854d6eA4171372` |
| Uniswap V2 WETH/USDC pair | `0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C` |
| Aerodrome WETH/USDC volatile pool | `0xcDAC0d6c6C59727a65F871236188350531885C43` |
| Aerodrome WETH/USDC stable pool | `0x3548029694fbB241D45FB24Ba0cd9c9d4E745f16` |

References:

- Balancer deployments: <https://github.com/balancer/balancer-deployments>
- Balancer flash loans: <https://docs.balancer.fi/developer-reference/contracts/flash-loans.html>
- Aerodrome docs: <https://aerodrome.finance/docs>
- Uniswap V3 Base deployments: <https://docs.uniswap.org/contracts/v3/reference/deployments/base-deployments>
- Uniswap V2 deployment addresses: <https://docs.uniswap.org/contracts/v2/reference/smart-contracts/v2-deployments>
- Base contracts: <https://docs.base.org/base-contracts>

---

## 11. Interface assumptions and differences from common DEX APIs

1. **Balancer repayment is a transfer, not an approval.** This is the most common integration
   mistake; see section 3.1. The Vault checks its own balance after the callback.
2. **SwapRouter02 has no deadline in `ExactInputSingleParams`.** Do not append a deadline to
   `extraData`; only `uint24 fee` and optional `uint256 minAmountOut` are accepted.
3. **Uniswap V2 uses `block.timestamp` as the deadline.** There is no watcher-supplied deadline.
4. **Ryo supports ERC20 assets only.** Native ETH is not borrowed or routed; use WETH. The contract
   can receive ETH only for forced/accidental balances and owner rescue.
5. **The V3 adapter targets `SwapRouter02`-compatible routers.** `SwapRouter` (with deadline) and
   Algebra-style routers use different ABIs and need a new adapter id. Aerodrome Slipstream is such
   a router and therefore has its own id (`7`).
6. **The V2 adapter targets `swapExactTokensForTokens`.** Fee-on-transfer tokens are not supported:
   Balancer's post-loan balance check and Ryo's exact repayment would fail. The same applies to the
   Aerodrome classic adapter.
7. **Aerodrome classic takes hops, not a token path.** Each hop declares its own pool type
   (stable or volatile), so a single `Swap` can mix both pool types across its hops.
8. **Aerodrome Slipstream pools are identified by tick spacing, not a fee tier.** The watcher must
   know the tick spacing of the target pool (commonly 1, 10 or 100 on Base).
9. **`minAmountOut` defaults to 1, not to a percentage.** Encode explicit floors if the watcher
   needs per-hop slippage limits.
10. **Primary routes are immutable.** Route changes require a redeploy; router permissions remain
    mutable. The two primary routes stay on Uniswap V3 and Uniswap V2; Aerodrome and Slipstream are
    reached through the dynamic `execute` path.
11. **`maxTradeSize` is per borrowed asset, not per route.** Both routes and dynamic routes share the
    same cap for a given asset.
12. **A router address is whitelisted per address, not per DEX.** Adding the Aerodrome Router lets
    the watcher use `dexType 4`; adding the Slipstream SwapRouter lets it use `dexType 7`. Whitelisting
    is required either way.
