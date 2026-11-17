#!/usr/bin/env python3
"""Fetch every Swap of the Uniswap v4 ETH/USDC 0.05% pool between two blocks, with block timestamps.

Ported from our own pre-hookathon fork-test feasibility study (fetch_swaps.py), extended with block
timestamps and an uncapped range so the demo and the fork tests can replay real flow in real time.

Output (JSON, parallel arrays of decimal strings so Foundry's vm.parseJson* can read them):
  amount0, amount1   the swapper's deltas (negative = paid into the pool)
  sqrtPriceX96       the pool price after the swap
  blocks, timestamps the swap's block number and block timestamp
  logIndex, tx       the log position and transaction hash
plus metadata: fromBlock, toBlock, fromTimestamp (of fromBlock), count, zeroForOneCount,
modifyLiquidityEvents (liquidity changes in the same span, which the replay does not reproduce), fees.

Sign convention: Swap.amount0/amount1 are the swapper's balance deltas (negative = paid in), not the pool's.
The script checks this against the recorded prices and exits non-zero on any violation.

Usage:
  ETH_RPC_URL=... python3 -I demo/fetch_swaps.py <fromBlock> <toBlock> <out.json>
Logs come from LOGS_RPC (default https://eth.drpc.org, 100-block windows; many free RPCs cap eth_getLogs
lower). Block headers come from ETH_RPC_URL in batches.
"""
import json, os, sys, time, urllib.request

LOGS_RPC = os.environ.get("LOGS_RPC", "https://eth.drpc.org")
RPC = os.environ["ETH_RPC_URL"]
WINDOW = 100
PM = "0x000000000004444c5dc75cB358380D2e3dE08A90"
POOL_ID = "0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
SWAP_T = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
MODLIQ_T = "0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec"
STATE_VIEW = "0x7ffe42c4a5deea5b0fec41c94c136cf115597227"
HEADERS = {"content-type": "application/json", "user-agent": "oath-demo/1.0"}


def post(url, body):
    for attempt in range(10):
        try:
            req = urllib.request.Request(url, json.dumps(body).encode(), HEADERS)
            res = json.loads(urllib.request.urlopen(req, timeout=120).read())
            items = res if isinstance(res, list) else [res]
            if all("result" in r for r in items):
                return res
            err = [r.get("error") for r in items if "result" not in r][:1]
        except Exception as e:  # network / http errors
            err = str(e)
        time.sleep(1.5 * (attempt + 1))
    raise SystemExit(f"RPC failed after retries: {err}")


def rpc(url, method, params):
    return post(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})["result"]


def timestamps(blocks):
    """Block timestamps, 20 headers per batch request."""
    out = {}
    blocks = sorted(set(blocks))
    for i in range(0, len(blocks), 20):
        chunk = blocks[i:i + 20]
        body = [{"jsonrpc": "2.0", "id": k, "method": "eth_getBlockByNumber", "params": [hex(b), False]}
                for k, b in enumerate(chunk)]
        for r in sorted(post(RPC, body), key=lambda r: r["id"]):
            out[chunk[r["id"]]] = int(r["result"]["timestamp"], 16)
        time.sleep(0.2)
    return out


def s(word):  # signed 256-bit word
    v = int(word, 16)
    return v - (1 << 256) if v >> 255 else v


def main():
    from_block, to_block, out_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

    # Pool price at the end of fromBlock (StateView.getSlot0), the reference for the first swap's sign check.
    slot0 = rpc(RPC, "eth_call", [{"to": STATE_VIEW, "data": "0xc815641c" + POOL_ID[2:]}, hex(from_block)])
    prev = int(slot0[2:66], 16)

    swaps, modliq = [], 0
    blk = from_block + 1
    while blk <= to_block:
        to = min(blk + WINDOW - 1, to_block)
        logs = rpc(LOGS_RPC, "eth_getLogs", [{"fromBlock": hex(blk), "toBlock": hex(to), "address": PM,
                                              "topics": [[SWAP_T, MODLIQ_T], POOL_ID]}])
        logs.sort(key=lambda l: (int(l["blockNumber"], 16), int(l["logIndex"], 16)))
        for l in logs:
            if l["topics"][0] == MODLIQ_T:
                modliq += 1
                continue
            d = l["data"][2:]
            w = [d[i * 64:(i + 1) * 64] for i in range(6)]
            swaps.append({
                "block": int(l["blockNumber"], 16), "logIndex": int(l["logIndex"], 16), "tx": l["transactionHash"],
                "amount0": s(w[0]), "amount1": s(w[1]), "sqrtPriceX96": int(w[2], 16), "fee": int(w[5], 16),
            })
        print(f"blocks {blk}-{to}: swaps {len(swaps)} modifyLiquidity {modliq}", file=sys.stderr)
        blk = to + 1

    # ---- sign check on real data: fail loudly ----
    bad = []
    for i, x in enumerate(swaps):
        a0, a1, p = x["amount0"], x["amount1"], x["sqrtPriceX96"]
        if a0 < 0 and a1 >= 0:      # swapper paid ETH -> zeroForOne -> price must not rise
            ok = p <= prev
        elif a1 < 0 and a0 >= 0:    # swapper paid USDC -> oneForZero -> price must not fall
            ok = p >= prev
        else:
            ok = False              # exactly one side must be paid in
        if not ok:
            bad.append((i, x["tx"], a0, a1, prev, p))
        prev = p
    if bad:
        for b in bad[:20]:
            print("SIGN CHECK FAIL", b, file=sys.stderr)
        raise SystemExit(f"sign check failed on {len(bad)} of {len(swaps)} swaps")

    ts = timestamps([from_block] + [x["block"] for x in swaps])
    out = {
        "fromBlock": from_block, "toBlock": to_block, "fromTimestamp": ts[from_block],
        "count": len(swaps), "zeroForOneCount": sum(1 for x in swaps if x["amount0"] < 0),
        "modifyLiquidityEvents": modliq, "fees": sorted(set(x["fee"] for x in swaps)),
        "amount0": [str(x["amount0"]) for x in swaps],
        "amount1": [str(x["amount1"]) for x in swaps],
        "sqrtPriceX96": [str(x["sqrtPriceX96"]) for x in swaps],
        "blocks": [str(x["block"]) for x in swaps],
        "timestamps": [str(ts[x["block"]]) for x in swaps],
        "logIndex": [str(x["logIndex"]) for x in swaps],
        "tx": [x["tx"] for x in swaps],
    }
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1)
    print(f"OK: {len(swaps)} swaps in blocks {from_block + 1}..{to_block}, {out['zeroForOneCount']} zeroForOne, "
          f"{modliq} ModifyLiquidity events, fees {out['fees']}; sign check passed -> {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
