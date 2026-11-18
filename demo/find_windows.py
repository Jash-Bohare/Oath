#!/usr/bin/env python3
"""Find ranging windows of the Uniswap v4 ETH/USDC 0.05% pool: 1-3 day spans whose hourly high/low range
stayed under 2.5%, the candidates for the demo's win window.

Samples the pool price (StateView.getSlot0 at the end of the block) every 300 blocks (~1 hour) over the last
WEEKS weeks, with each sampled block's timestamp. For every sample taken as a window start, it keeps the
longest window (at most MAX_H hours) whose high/low range stays under MAX_RANGE, then ranks those windows by
the number of daily epochs the replay fits into them (one epoch per 24.5 h: a 30-minute open window plus a
1-day epoch), then by range, ascending. It reports greedily chosen non-overlapping windows, best first.

The range compares prices, so it is computed from sqrtPriceX96 directly: high/low = (sqrtHigh/sqrtLow)^2,
independent of token decimals. Hourly samples can miss intra-hour extremes; the swaps fetched for a chosen
window carry every price.

Output (JSON): head block, sampling parameters, and `windows` (name, fromBlock, toBlock, fromTimestamp,
toTimestamp, hours, epochs, rangeBps, low, high in USDC per ETH).

Usage:
  ETH_RPC_URL=... python3 -I demo/find_windows.py <out.json> [weeks=8]
  python3 -I demo/find_windows.py --self-test
"""
import json, os, sys, time, urllib.request
from datetime import datetime, timezone

STATE_VIEW = "0x7ffe42c4a5deea5b0fec41c94c136cf115597227"
POOL_ID = "21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
HEADERS = {"content-type": "application/json", "user-agent": "oath-demo/1.0"}
STEP = 300  # blocks between samples, ~1 hour at 12 s slots
MAX_RANGE = 0.025  # high/low - 1
MIN_H, MAX_H = 24.5, 72.0  # one epoch needs 24.5 h; windows span 1-3 days
EPOCH_H = 24.5  # 30-minute open window + 1-day epoch
TOP = 3


def post(body):
    rpc = os.environ["ETH_RPC_URL"]
    for attempt in range(10):
        try:
            req = urllib.request.Request(rpc, json.dumps(body).encode(), HEADERS)
            res = json.loads(urllib.request.urlopen(req, timeout=120).read())
            items = res if isinstance(res, list) else [res]
            if all("result" in r for r in items):
                return res
        except Exception:  # network / http errors
            pass
        time.sleep(1 + attempt)
    raise SystemExit("RPC failed after retries")


def sample(blocks):
    """(timestamp, sqrtPriceX96) at the end of each block, 10 blocks per batch request."""
    out = []
    for i in range(0, len(blocks), 10):
        chunk = blocks[i:i + 10]
        body = []
        for k, b in enumerate(chunk):
            body.append({"jsonrpc": "2.0", "id": 2 * k, "method": "eth_getBlockByNumber", "params": [hex(b), False]})
            body.append({"jsonrpc": "2.0", "id": 2 * k + 1, "method": "eth_call",
                         "params": [{"to": STATE_VIEW, "data": "0xc815641c" + POOL_ID}, hex(b)]})
        res = {r["id"]: r["result"] for r in post(body)}
        for k in range(len(chunk)):
            out.append((int(res[2 * k]["timestamp"], 16), int(res[2 * k + 1][2:66], 16)))
        time.sleep(0.2)
    return out


def price(sqrt_x96):
    """USDC per ETH (token0 ETH, 18 decimals; token1 USDC, 6 decimals)."""
    return (sqrt_x96 / 2**96) ** 2 * 1e12


def price_range(lo_sqrt, hi_sqrt):
    """high/low - 1 from two sqrtPriceX96 values."""
    return (hi_sqrt / lo_sqrt) ** 2 - 1


def windows(ts, sq):
    """For each start, the longest window <= MAX_H with range < MAX_RANGE, if it is >= MIN_H long."""
    found = []
    for i in range(len(ts)):
        lo = hi = sq[i]
        best = None
        for j in range(i + 1, len(ts)):
            if ts[j] - ts[i] > MAX_H * 3600:
                break
            lo, hi = min(lo, sq[j]), max(hi, sq[j])
            if price_range(lo, hi) >= MAX_RANGE:
                break
            if ts[j] - ts[i] >= MIN_H * 3600:
                best = (j, lo, hi)
        if best:
            j, lo, hi = best
            hours = (ts[j] - ts[i]) / 3600
            found.append({"i": i, "j": j, "hours": hours, "epochs": int(hours // EPOCH_H),
                          "range": price_range(lo, hi), "lo": lo, "hi": hi})
    return found


def pick(found, top):
    """Best first (more epochs, then smaller range), skipping windows that overlap an earlier pick."""
    chosen = []
    for w in sorted(found, key=lambda w: (-w["epochs"], w["range"], w["i"])):
        if all(w["j"] <= c["i"] or w["i"] >= c["j"] for c in chosen):
            chosen.append(w)
        if len(chosen) == top:
            break
    return chosen


def name(t0, t1):
    f = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H")
    return f"{f(t0)}_{f(t1)}"


def self_test():
    q = 2**96
    # A sqrt ratio of 1.01 is a price ratio of 1.0201 (2.01%), whatever the scale.
    assert abs(price_range(79 * q, 79 * q * 1.01) - 0.0201) < 1e-12
    assert abs(price_range(3 * q, 3 * q) - 0.0) < 1e-15
    # 1 ETH = 2,500 USDC: sqrtPriceX96 = sqrt(2500e6 / 1e18) * 2^96.
    assert abs(price(int((2500e6 / 1e18) ** 0.5 * q)) - 2500) < 1e-6
    # Hourly series: flat for 80 h, then a 3% jump. Starts 0..7 reach 72 h; later starts stop at the jump (71 h, 70 h, ...).
    h = 3600
    ts = [k * h for k in range(100)]
    sq = [q] * 80 + [int(q * 1.03 ** 0.5)] * 20
    found = windows(ts, sq)
    assert [w["hours"] for w in found[:10]] == [72.0] * 8 + [71.0, 70.0], found[:10]
    assert all(w["epochs"] == 2 and w["range"] == 0 for w in found[:10])
    assert all(w["j"] < 80 or w["i"] >= 80 for w in found)  # no window spans the jump
    # A 2.4% band passes, 2.6% fails.
    assert windows([0, 25 * h], [q, int(q * 1.024 ** 0.5)])
    assert not windows([0, 25 * h], [q, int(q * 1.026 ** 0.5)])
    # Under 24.5 h: no window.
    assert not windows([0, 24 * h], [q, q])
    # Non-overlapping picks: best is 0..72, next must start at or after 72.
    chosen = pick(found, 3)
    assert chosen[0]["i"] == 0 and all(c["i"] >= 72 or c["j"] <= 0 for c in chosen[1:]), chosen
    print("self-test OK")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    self_test()
    out_path = sys.argv[1]
    weeks = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    head = int(post({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []})["result"], 16)
    head -= head % STEP
    blocks = list(range(head - weeks * 7 * 24 * STEP, head + 1, STEP))
    data = sample(blocks)
    ts, sq = [t for t, _ in data], [s for _, s in data]
    found = windows(ts, sq)
    chosen = pick(found, TOP)
    rows = [{"name": name(ts[w["i"]], ts[w["j"]]), "fromBlock": blocks[w["i"]], "toBlock": blocks[w["j"]],
             "fromTimestamp": ts[w["i"]], "toTimestamp": ts[w["j"]], "hours": round(w["hours"], 2),
             "epochs": w["epochs"], "rangeBps": round(w["range"] * 1e4, 1),
             "low": round(price(w["lo"]), 2), "high": round(price(w["hi"]), 2)} for w in chosen]
    with open(out_path, "w") as f:
        json.dump({"head": head, "weeks": weeks, "step": STEP, "samples": len(blocks), "maxRangeBps": MAX_RANGE * 1e4,
                   "candidates": len(found), "windows": rows}, f, indent=2)
    for r in rows:
        print(f"{r['name']}  blocks {r['fromBlock']}-{r['toBlock']}  {r['hours']} h  {r['epochs']} epochs  "
              f"range {r['rangeBps']} bps  {r['low']}-{r['high']}")
    print(f"OK: {len(blocks)} samples, {len(found)} candidate starts, {len(rows)} windows")


if __name__ == "__main__":
    main()
