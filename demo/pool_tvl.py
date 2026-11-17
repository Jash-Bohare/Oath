#!/usr/bin/env python3
"""Liquidity layout and TVL of the Uniswap v4 ETH/USDC 0.05% pool at a block, by walking the tick bitmap.

Ported from our own pre-hookathon fork-test feasibility study (pool_tvl.py), extended to write the layout
(every initialized tick and its liquidityNet) so the demo and the fork tests can clone the pool's liquidity.

Reads every tick-bitmap word in the usable range through StateView, then liquidityNet for each initialized
tick, rebuilds the liquidity profile and sums token amounts per segment (float sqrt prices, ~1e-12 relative
error, for the TVL only). Sanity check: the rebuilt liquidity at the current tick must equal getLiquidity(),
or the script exits non-zero.

Output (JSON): block, sqrtPriceX96 (exact), tick, activeLiquidity, ticks and liquidityNet (parallel arrays
of decimal strings, ascending ticks), and the TVL (ethWei, usdcUnits, tvlUSDCunits).

Usage: ETH_RPC_URL=... python3 -I demo/pool_tvl.py <block> <out.json>
"""
import json, os, sys, time, urllib.request

RPC = os.environ["ETH_RPC_URL"]
STATE_VIEW = "0x7ffe42c4a5deea5b0fec41c94c136cf115597227"
POOL_ID = "21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
SPACING, MIN_T, MAX_T = 10, -887270, 887270
HEADERS = {"content-type": "application/json", "user-agent": "oath-demo/1.0"}


def enc_int(v):
    return format(v & ((1 << 256) - 1), "064x")


def s256(h):
    v = int(h, 16)
    return v - (1 << 256) if v >> 255 else v


def batch_call(block, datas):
    """eth_call StateView at `block`, 10 calls per batch request."""
    out = []
    for i in range(0, len(datas), 10):
        chunk = datas[i:i + 10]
        body = [{"jsonrpc": "2.0", "id": k, "method": "eth_call", "params": [{"to": STATE_VIEW, "data": d}, hex(block)]}
                for k, d in enumerate(chunk)]
        for attempt in range(10):
            try:
                req = urllib.request.Request(RPC, json.dumps(body).encode(), HEADERS)
                res = sorted(json.loads(urllib.request.urlopen(req, timeout=120).read()), key=lambda r: r["id"])
                if all("result" in r for r in res):
                    break
            except Exception:  # network / http errors
                pass
            time.sleep(1 + attempt)
        else:
            raise SystemExit("RPC failed after retries")
        out.extend(r["result"][2:] for r in res)
        time.sleep(0.25)
    return out


def main():
    block, out_path = int(sys.argv[1]), sys.argv[2]
    slot0, liq = batch_call(block, ["0xc815641c" + POOL_ID, "0xfa6793d5" + POOL_ID])  # getSlot0, getLiquidity
    sqrt_price_x96 = int(slot0[0:64], 16)
    tick = s256(slot0[64:128])
    active = int(liq, 16)

    w_lo, w_hi = (MIN_T // SPACING) >> 8, (MAX_T // SPACING) >> 8
    words = list(range(w_lo, w_hi + 1))
    bitmaps = batch_call(block, ["0x1c7ccb4c" + POOL_ID + enc_int(w) for w in words])  # getTickBitmap
    ticks = []
    for w, bm in zip(words, bitmaps):
        b = int(bm, 16)
        for bit in range(256):
            if b >> bit & 1:
                ticks.append(((w << 8) + bit) * SPACING)
    ticks.sort()
    # getTickLiquidity returns (liquidityGross, liquidityNet)
    nets = [s256(r[64:128]) for r in batch_call(block, ["0xcaedab54" + POOL_ID + enc_int(t) for t in ticks])]

    sqrt_p = sqrt_price_x96 / 2**96
    amt0 = amt1 = 0.0
    L = 0
    L_at_price = None
    for i in range(len(ticks) - 1):
        L += nets[i]
        ta, tb = ticks[i], ticks[i + 1]
        if ta <= tick < tb:
            L_at_price = L
        if L == 0:
            continue
        sa, sb = 1.0001 ** (ta / 2), 1.0001 ** (tb / 2)
        if sqrt_p <= sa:
            amt0 += L * (1 / sa - 1 / sb)
        elif sqrt_p >= sb:
            amt1 += L * (sb - sa)
        else:
            amt0 += L * (1 / sqrt_p - 1 / sb)
            amt1 += L * (sqrt_p - sa)
    if L_at_price != active:
        raise SystemExit(f"rebuilt liquidity {L_at_price} != active liquidity {active}")
    price = sqrt_p ** 2 * 1e12  # USDC per ETH
    tvl_usdc = amt1 / 1e6 + amt0 / 1e18 * price
    out = {
        "block": block, "sqrtPriceX96": str(sqrt_price_x96), "tick": tick, "activeLiquidity": str(active),
        "initializedTicks": len(ticks), "bitmapWords": len(words),
        "ticks": [str(t) for t in ticks], "liquidityNet": [str(n) for n in nets],
        "priceUSDCperETH": price, "ethWei": str(int(amt0)), "usdcUnits": str(int(amt1)),
        "tvlUSDC": tvl_usdc, "tvlUSDCunits": str(int(tvl_usdc * 1e6)),
    }
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1)
    print(f"OK: {len(ticks)} initialized ticks, active liquidity {active} rebuilt exactly, "
          f"TVL ${tvl_usdc:,.2f} -> {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
