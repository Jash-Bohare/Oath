# Oath — Math

Every formula Oath uses, with units, rounding and worked examples. The contracts implement exactly these: `src/libraries/ValuationLib.sol` (§2, §3, §7), `BenchmarkLib.sol` (§6) and `SettlementLib.sol` (§9). NatSpec in the code cites the sections below as `MATH.md §n`.

A high-precision reference model, `script/reference/oath_math.py`, reproduces every worked example here and generates the test vectors (§14).

## 1. Conventions

- Pool: `currency0`, `currency1`, `tickSpacing`. Demo pool: ETH (18 decimals) / USDC (6 decimals), fee 500, tickSpacing 10.
- **Numeraire = currency1.** Every "value" is in raw currency1 units (USDC: 1e6 = $1).
- Raw price `P = 1.0001^tick` = currency1 raw units per currency0 raw unit. `sqrtPriceX96 = sqrt(P) · 2^96`.
- `Q96 = 2^96`, `Q128 = 2^128`. `mulDiv` = `FullMath.mulDiv` (rounds down) unless marked `mulDivUp`.
- Fee-growth and fee-growth-inside values are `uint256` that may **wrap**. All differences of them are computed in `unchecked` blocks, exactly as v4's `Position.sol` does.
- Full range for the pool: `tickMin = TickMath.minUsableTick(tickSpacing)`, `tickMax = TickMath.maxUsableTick(tickSpacing)`. For spacing 10: −887270 and 887270.
- Rounding rule of thumb: anything **paid to** the curator rounds down; amounts the benchmark **pays** to enter the pool round up, as the pool charges them. Values compared at settlement round down on both sides.

## 2. Valuation

```
value(a0, a1, sqrtP) = a1 + mulDiv(mulDiv(a0, sqrtP, Q96), sqrtP, Q96)
```

Two-step mulDiv avoids overflow (`sqrtP²` can exceed 256 bits). Implemented in `ValuationLib.value`.

## 3. Position principal at a price

For liquidity `L` on range `[tA, tB)` with `sA = sqrtAt(tA)`, `sB = sqrtAt(tB)`, at `sP`:

| Case | amount0 | amount1 |
| --- | --- | --- |
| `sP ≤ sA` | `getAmount0Delta(sA, sB, L, false)` | 0 |
| `sA < sP < sB` | `getAmount0Delta(sP, sB, L, false)` | `getAmount1Delta(sA, sP, L, false)` |
| `sP ≥ sB` | 0 | `getAmount1Delta(sA, sB, L, false)` |

`getAmountXDelta` = v4's `SqrtPriceMath`. Implemented in `ValuationLib.principal`. This mirrors how v4 itself values a position, so a real withdrawal at `sP` returns exactly these amounts (tested to the wei on the real `PoolManager`, including both range boundaries).

## 4. TWAP (hook accumulator)

The hook keeps `tickCumulative` (int256) and `lastTimestamp`. Price only changes inside swaps, so between two swaps the tick is constant and the accumulator is **exact**:

```
cumulativeAt(t) = tickCumulative + tick_current · (t − lastTimestamp)     for t ≥ lastTimestamp
twapTick(t1, t2) = floorDiv(cumulativeAt(t2) − cumulativeAt(t1), t2 − t1)
```

`floorDiv` rounds toward −∞ (if the quotient is negative and there is a remainder, subtract 1), matching Uniswap v3's oracle convention. The TWAP price used for marking is `sqrtP = TickMath.getSqrtPriceAtTick(twapTick)`.

Checkpoints at past times `t*` are recorded the first time the hook runs with `now ≥ t*` and `lastTimestamp < t*`, using `tick_current` (the tick that held throughout `(lastTimestamp, now]`). They are exact, not interpolated.

## 5. Epoch prices

| Price | Definition |
| --- | --- |
| Start price `sqrtP_S` | `twapTick(T0, S)`, where `T0` = open-window start (settlement or vault creation) and `S` = `startEpoch` time. Requires `W ≤ S − T0 ≤ maxOpen` |
| End price `sqrtP_E` | `twapTick(E − W, E)`, with both checkpoints recorded by the hook |

Defaults: `W = 30 min`, `maxOpen = 6 h`.

## 6. Benchmark

The benchmark is hypothetical: the vault's start value placed full-range in the same pool at `S`, split 50/50 by value. It never touches the pool.

### 6.1 Creation at epoch start (`BenchmarkLib.create`)

Input: start value `V_S` (vault NAV at `sqrtP_S`, §7), `sqrtP_S`, full-range bounds.

```
half1  = V_S / 2                    (currency1 side)
x      = mulDiv(mulDiv(half1, Q96, sqrtP_S), Q96, sqrtP_S)   (currency0 worth half1)
y      = V_S − half1
L_b    = LiquidityAmounts.getLiquidityForAmounts(sqrtP_S, sqrtMin, sqrtMax, x, y)
cost0  = getAmount0Delta(sqrtP_S, sqrtMax, L_b, true)
cost1  = getAmount1Delta(sqrtMin, sqrtP_S, L_b, true)
r0     = x > cost0 ? x − cost0 : 0          (leftover held, not in the pool)
r1     = y > cost1 ? y − cost1 : 0
G0_S, G1_S = getFeeGrowthGlobals(pool)  at S
```

Stored per epoch: `L_b, r0, r1, G0_S, G1_S`. For full range a 50/50 value split is almost exactly the pool ratio, so `r0, r1` are dust (worked example: < 1e-10 USDC). For the costs, `sqrtP_S` is clamped into `[sqrtMin, sqrtMax]`; this changes nothing for any in-range price and matches what v4 would charge at the extremes.

**Vault and benchmark start equal.** The benchmark's value at `sqrtP_S` is never above `V_S`, and below it only by rounding: at most `6u`, where `u = value(1 wei of currency0) + 1` (on the demo pool `u` = 1 raw unit, so ≤ $0.000006). Proof sketch: `x`'s double floor loses ≤ `sqrtP + P ≤ 2u` of value, principal-vs-cost rounding ≤ `u + 1`, and the value floors ≤ 2. Fuzz-tested over ±400,000 ticks.

### 6.2 Value at epoch end (`BenchmarkLib.valueAt`)

```
(p0, p1) = principal(L_b, tickMin, tickMax, sqrtP_E)
f0       = mulDiv(G0_E − G0_S, L_b, Q128)     (unchecked difference)
f1       = mulDiv(G1_E − G1_S, L_b, Q128)
B_E      = value(p0 + f0 + r0, p1 + f1 + r1, sqrtP_E)
```

`G_E` comes from the hook's boundary snapshot (§8). Exactness: on a real `PoolManager`, a real full-range position of `L_b` added at `S` is charged exactly `cost0, cost1` and withdraws exactly `p + f` at `E` after any swaps and donations, to the wei (fuzz-tested). On mainnet, §13 F1–F3.

## 7. Vault NAV

At any mark price `sqrtP` with vault position `(L_v, tA, tB)`:

```
(p0, p1) = principal(L_v, tA, tB, sqrtP)
u0       = mulDiv(fgIn0_mark − fgIn0_last, L_v, Q128)    (uncollected fees, unchecked difference)
u1       = mulDiv(fgIn1_mark − fgIn1_last, L_v, Q128)
NAV      = value(idle0 + p0 + u0, idle1 + p1 + u1, sqrtP)
```

- `idle0`, `idle1`: vault token balances **excluding** the bond (`idle1 = balance1 − bondBalance`).
- `fgIn_last`: from `StateLibrary.getPositionInfo(manager, poolId, vault, tA, tB, POSITION_SALT)`.
- `fgIn_mark`: at settlement, the hook's boundary snapshot of `getFeeGrowthInside(tA, tB)`. At epoch start the vault has no position (all idle), so `NAV_S = value(idle0, idle1, sqrtP_S)`.

Implemented in `ValuationLib.nav` (with `ValuationLib.feesOwed` for `u0, u1`).

## 8. Boundary snapshot (keeperless, exact)

The epoch is the half-open interval `[S, E)`. Global fee growth changes only in swaps and donations; fee growth inside a range changes only through global growth and tick crossings, which happen only in swaps. Therefore, the first time the hook runs `beforeSwap` or `beforeDonate` with `now ≥ E` (or anyone calls `poke` with `now ≥ E`), the current values are exactly the values at `E`:

```
snapshot = { G0_E, G1_E = getFeeGrowthGlobals;  fgIn0_E, fgIn1_E = getFeeGrowthInside(vaultLower, vaultUpper) }
```

The vault is frozen from `E` until settlement, so its range, liquidity and idle balances at settlement equal those at `E`.

## 9. Settlement (`SettlementLib.settle`, pure)

Inputs: `NAV_E`, `B_E`, `bond`, `totalShares`, `bandBps = 35`, `perfFeeBps = 2000`.

```
d    = int256(NAV_E) − int256(B_E)
band = mulDiv(B_E, bandBps, 10_000)

if d < −band:   payout = min(uint256(−d) − band, bond);     fee = 0
elif d > band:  fee    = mulDiv(uint256(d) − band, perfFeeBps, 10_000); payout = 0
else:           payout = 0; fee = 0

feeShares = fee == 0 ? 0 : mulDiv(totalShares, fee, NAV_E − fee)
```

- `payout` moves `payout` units of currency1 from the bond to the vault's idle balance (accounting only; the bond is already held by the vault).
- `feeShares` are minted to the curator. After minting, the curator owns `fee / NAV_E` of the vault, which is the standard fund-fee dilution formula (tested: within 1 raw unit).
- The band absorbs measurement error (§13 F3) and is symmetric: the curator is neither paid nor charged for differences inside it.

### 9.1 Worked examples (test vectors)

Common inputs (real data where available):

- Start TWAP tick −199196 → $2,235.94 per ETH. `V_S = $30,000`. Bond $3,000 (10%). Total shares 30,000.
- Benchmark: x = 6.708588 ETH, y = 15,000 USDC, `L_b = 317,220,452,305,763` (≈ 3.17e14). Cap check vs the real pool's active liquidity 153,902,357,621,796,655: limit 3.85e14 → passes.
- Benchmark fees use the real Nov 8–15 fee growth of the mainnet ETH/USDC pool (§13 F2): `ΔG0 = 5685705715728585446726598611346846337347`, `ΔG1 = 10323568296605520673412669325024` → 0.005300 ETH + 9.62 USDC.
- Curator range `[−199400, −199000)`, `L_v ≈ 3.126e16`, idle after adding: 0.261795 ETH + 0 USDC.
- Vault fees are **illustrative inputs** (stated per example).

| Example | End TWAP tick (price) | Vault fees (input) | NAV_E | B_E | d | Band | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Loss (real Nov 8–15 move) | −201275 ($1,816.25) | 0.006 ETH + 11.25 USDC | $24,515.96 | $27,057.50 | −$2,541.54 | $94.70 | **Bond pays $2,446.84** (of $3,000) |
| Win | −199150 ($2,246.25) | 0.045 ETH + 105 USDC | $30,267.40 | $30,090.61 | +$176.79 | $105.32 | **Fee $14.30** → 14.1758 shares |
| Flat | −199196 ($2,235.94) | 0.000375 ETH + 0.75 USDC | $30,001.59 | $30,021.48 | −$19.89 | $105.08 | Inside band: nothing |

Context for the loss example: HODL 50/50 would be $27,184.45. The curator's tight range left the range early and ended 100% in ETH (13.224155 ETH), so it fell with ETH; the passive full-range position lost less. **The benchmark is "passive LP", not "make money"**: in a falling market a curator can beat the benchmark and still lose dollars. Tests reproduce every NAV_E, B_E, d, band, payout and fee in this table to within $0.01 from the stated inputs (`test/unit/SettlementLib.t.sol`).

### 9.2 Edge cases

| Case | Behaviour |
| --- | --- |
| `B_E == 0` | Cannot happen if `V_S > 0`; reverts `ZeroBenchmark()` defensively |
| Shortfall larger than the bond | `payout = bond`; the remaining shortfall stays with depositors; the vault emits `BondExhausted(shortfallUncovered)` |
| `fee ≥ NAV_E` | Impossible: `fee ≤ (d − band) · perfFeeBps / 10,000 ≤ d < NAV_E` (perfFeeBps ≤ 5,000); asserted anyway |
| `totalShares` includes the dead shares | Yes; fee dilution applies to everyone pro-rata, including dead shares |
| `d = ±band` | Nothing. `d = −band − 1` → payout 1. `d = band + 1` → fee = floor(0.2) = 0 |

### 9.3 Why the comparison is fair

- **Same marks:** vault and benchmark are both valued at `sqrtP_S` at start (they start equal by construction, §6.1) and at `sqrtP_E` at the end. Spot-price manipulation at `E` cannot shift one relative to the other because neither uses spot.
- **Same fee source:** both draw from the same pool's fee growth. Under arbitrage-driven flow the benchmark is exact (§13 F3, to the wei); under fixed-size flow it understates fees, which favours the curator by at most the measured error, absorbed by the 35 bps band at ≤ 0.25% of active liquidity.
- **Costs count:** the vault pays swap fees and price impact on its own rebalances; the benchmark pays nothing. A curator must beat passive **after** costs.
- **No look-ahead:** the epoch boundary snapshot is exact and taken before any post-`E` activity can affect it (§8).

## 10. Caps and minimums (checked at `startEpoch`)

```
L_b      ≤ mulDiv(activeLiquidity_S, capBps, 10_000)        capBps = 25     (activeLiquidity before the vault adds its position)
bond     ≥ mulDiv(V_S, minBondBps, 10_000)                  minBondBps = 1_000
V_S      > 0
```

## 11. Shares (open window only)

- First deposit: `shares = sqrt(a0 · a1) − MIN_SHARES` with `MIN_SHARES = 1_000` minted to `address(0xdead)`; both amounts must be > 0. No price needed; blocks the first-depositor inflation attack.
- Later deposits (vault fully idle in the open window): `shares = min(S·a0/h0, S·a1/h1)` using only tokens the vault holds (if `h0 = 0`, only currency1 counts, and vice versa). Amounts actually taken: `mulDivUp(h_i, shares, S)`; the excess is refunded.
- Withdraw: `out_i = mulDiv(h_i, shares, S)` for both tokens.

Deposits and withdrawals are in-kind and price-free, so they cannot be manipulated by moving the pool price.

## 12. Parameters (per vault, immutable)

| Name | Default | Demo | Bounds enforced by the factory | Why this value |
| --- | --- | --- | --- | --- |
| `epochDuration` | 7 days | 1 day | ≥ 2 × `twapWindow` | |
| `twapWindow` (W) | 30 min | 30 min | 5 min – 2 h | Settlement-time manipulation must hold the price off-market for 30 min |
| `maxOpen` | 6 h | 6 h | > W | |
| `rebalanceCooldown` | 1 h | 1 h | ≤ epochDuration | |
| `maxIntraBlockTicks` | 50 | 50 | 1 – 1,000 | Intra-block guard on the vault's own liquidity changes |
| `bandBps` | 35 | 35 | ≤ 500 | Covers the worst measured benchmark error, 34 bps at 1% of TVL (§13 F3) |
| `perfFeeBps` | 2,000 | 2,000 | ≤ 5,000 | 20% of the excess above the band |
| `minBondBps` | 1,000 | 1,000 | ≥ 100 | Bond ≥ 10% of start value |
| `capBps` | 25 | 25 | 1 – 1,000 | 0.25% of active liquidity ≈ 1% of TVL on the demo pool, where error was measured |

## 13. Evidence (Ethereum mainnet fork, real v4 `PoolManager`)

Measured before the build on the real ETH/USDC v4 pool (currency0 native ETH, currency1 USDC, fee 500, tickSpacing 10, no hook; pool id `0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27`; `PoolManager` `0x000000000004444c5dc75cB358380D2e3dE08A90`). Forks pinned at B0 = 26,367,600 (Nov 8, 2026) and B1 = 26,418,000 (Nov 15, 2026). At B0: tick −199196, active liquidity 153,902,357,621,796,655, TVL $4,055,374.61. These tests are being ported to `test/fork/`, where they run against this repo's libraries.

| Test | Result |
| --- | --- |
| **F1** full-range identity | A full-range position's fees and withdrawn amounts equal the closed form **to the wei** after 100 real-pool swaps: fees 24,028,771,676,984,960 wei ETH and 1,766,158 USDC units; amounts 13,289,530,942,672,613,789 wei and 136,681,124 units, each actual = predicted |
| **F2** 7 days of history | Over Nov 8–15, Δ fee growth inside the full range equals Δ global fee growth **exactly**: ΔG0 = 5685705715728585446726598611346846337347, ΔG1 = 10323568296605520673412669325024 (X128). A 1-ETH-equivalent full-range position earned $1.43 in fees (6 bps) and trailed HODL by 0.42% while ETH fell from $2,236.09 to $1,816.43 |
| **F3** 500 real swaps replayed | Under arbitrage-driven (price-anchored) flow, the hypothetical benchmark's fees equal a real full-range position's **to the wei** at 0.1% and 1% of TVL. Under fixed-size (amount-anchored) flow the benchmark understates fees; total-value error is 3.38 bps at 0.1% of TVL and **33.96 bps at 1%**, which sets the 35 bps band. A per-swap dilution correction would over-pay by 23% of fees at 1% of TVL under arbitrage flow, so it is not used |
| **F4** gas | One benchmark checkpoint (two fee-growth reads): **16,062 gas** cold |

## 14. Reproduce

```bash
python3 script/reference/oath_math.py             # prints the §9.1 worked examples
python3 script/reference/oath_math.py --vectors   # regenerates test/vectors/valuation.json (fixed seed)
forge test --match-path "test/unit/*Lib.t.sol"    # library tests: vectors, worked examples, real-pool identities
```

The reference model uses exact powers of 1.0001 with 80-digit decimals; the contracts use `TickMath`. They agree within 1e-9 relative on 1,000 random points and within $0.01 on every worked example.
