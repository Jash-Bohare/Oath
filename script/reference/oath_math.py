#!/usr/bin/env python3
"""Oath reference model (MATH.md).

High-precision (Decimal) model of valuation, benchmark and settlement.
Used to (1) reproduce the worked examples in MATH.md section 9.1 and
(2) generate test vectors for the Solidity libraries.

The contracts use integer math (TickMath, SqrtPriceMath, FullMath). Results
here match them to well under $0.01 for the documented examples; tests assert
within that tolerance.

Usage:
  python3 script/reference/oath_math.py             # print worked examples
  python3 script/reference/oath_math.py --vectors   # JSON vectors for ValuationLib tests
                                                    # (> test/vectors/valuation.json)
"""
import json, random, sys
from decimal import Decimal as D, getcontext

getcontext().prec = 80
Q128 = D(2) ** 128
DEC0, DEC1 = 18, 6                 # ETH / USDC
TICK_MIN, TICK_MAX = -887270, 887270   # minUsable/maxUsable for tickSpacing 10


def price(t):                      # raw currency1 units per raw currency0 unit
    return D("1.0001") ** t

def sqrtp(t):
    return price(t).sqrt()

def usd(raw1):
    return raw1 / D(10) ** DEC1

def value(a0, a1, t):              # MATH.md section 2 (in currency1 raw units)
    return a1 + a0 * price(t)

def principal(L, tA, tB, t):       # MATH.md section 3
    sP, sA, sB = sqrtp(t), sqrtp(tA), sqrtp(tB)
    if sP <= sA:
        return L * (1 / sA - 1 / sB), D(0)
    if sP >= sB:
        return D(0), L * (sB - sA)
    return L * (1 / sP - 1 / sB), L * (sP - sA)

def liquidity_for_amounts(t, tA, tB, x, y):
    sP, sA, sB = sqrtp(t), sqrtp(tA), sqrtp(tB)
    if sP <= sA:
        return x * sA * sB / (sB - sA)
    if sP >= sB:
        return y / (sB - sA)
    return min(x * sP * sB / (sB - sP), y / (sP - sA))

def benchmark_create(V_S, tS):     # MATH.md section 6.1
    half1 = V_S / 2
    x, y = half1 / price(tS), V_S - half1
    L = liquidity_for_amounts(tS, TICK_MIN, TICK_MAX, x, y)
    c0, c1 = principal(L, TICK_MIN, TICK_MAX, tS)
    return {"L": L, "x": x, "y": y, "r0": max(x - c0, D(0)), "r1": max(y - c1, D(0))}

def benchmark_value(b, tE, dG0, dG1):   # MATH.md section 6.2
    p0, p1 = principal(b["L"], TICK_MIN, TICK_MAX, tE)
    f0, f1 = dG0 * b["L"] / Q128, dG1 * b["L"] / Q128
    return value(p0 + f0 + b["r0"], p1 + f1 + b["r1"], tE), (f0, f1)

def settle(nav, bench, bond, supply, band_bps=35, fee_bps=2000):   # MATH.md section 9
    d = nav - bench
    band = bench * band_bps / 10000
    payout = fee = shares = D(0)
    if d < -band:
        payout = min(-d - band, bond)
    elif d > band:
        fee = (d - band) * fee_bps / 10000
        shares = supply * fee / (nav - fee)
    return {"diff": d, "band": band, "payout": payout, "fee": fee, "feeShares": shares}


def worked_examples():
    # Real Nov 8-15 fee growth of the mainnet ETH/USDC pool (MATH.md section 13, F2)
    dG0 = D(5685705715728585446726598611346846337347)
    dG1 = D(10323568296605520673412669325024)
    tS = -199196
    V_S = D(30000) * D(10) ** DEC1
    bond, supply = V_S / 10, D(30000)
    b = benchmark_create(V_S, tS)
    tA, tB = -199400, -199000
    Lv = liquidity_for_amounts(tS, tA, tB, b["x"], b["y"])
    v0, v1 = principal(Lv, tA, tB, tS)
    idle0, idle1 = b["x"] - v0, b["y"] - v1
    print(f"Start price ${usd(price(tS) * D(10) ** DEC0):.2f}  L_b {b['L']:.6e}  L_v {Lv:.6e}")
    print(f"Benchmark x {b['x'] / D(10) ** DEC0:.6f} ETH, y {usd(b['y']):.2f} USDC; vault idle {idle0 / D(10) ** DEC0:.6f} ETH")
    cases = [("Loss", -201275, D("0.006"), D("11.25")),
             ("Win", -199150, D("0.045"), D("105")),
             ("Flat", -199196, D("0.000375"), D("0.75"))]
    for name, tE, fe0, fe1 in cases:
        p0, p1 = principal(Lv, tA, tB, tE)
        nav = value(idle0 + p0 + fe0 * D(10) ** DEC0, idle1 + p1 + fe1 * D(10) ** DEC1, tE)
        bench, _ = benchmark_value(b, tE, dG0, dG1)
        r = settle(nav, bench, bond, supply)
        print(f"{name:5s} end ${usd(price(tE) * D(10) ** DEC0):9.2f}  NAV ${usd(nav):10.2f}  "
              f"Bench ${usd(bench):10.2f}  d ${usd(r['diff']):9.2f}  band ${usd(r['band']):7.2f}  "
              f"payout ${usd(r['payout']):8.2f}  fee ${usd(r['fee']):6.2f}  feeShares {r['feeShares']:.4f}")


def vectors(n=1000, seed=7):
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        t = rnd.randint(-250000, -150000)
        a0 = rnd.randint(0, 10 ** 22)
        a1 = rnd.randint(0, 10 ** 12)
        out.append({"tick": t, "a0": str(a0), "a1": str(a1), "value": str(int(value(D(a0), D(a1), t)))})
    print(json.dumps(out))


if __name__ == "__main__":
    vectors() if "--vectors" in sys.argv else worked_examples()
