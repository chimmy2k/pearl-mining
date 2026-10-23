#!/usr/bin/env bash
# PearlHash live monitor — one-shot readout for humans.
#   watch -n5 ./watch.sh
#
# Prints per-GPU hashrate from the miner API plus power/clocks from nvidia-smi.
# Read-only: never writes state, never restarts anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
[[ -f "${LIB_DIR}/common.sh" ]] || LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh" || { echo "FATAL: cannot source lib/common.sh" >&2; exit 1; }

API_PORT="${API_PORT:-4068}"

printf '=== miner API (127.0.0.1:%s) ===\n' "$API_PORT"

payload="$(curl -sf -m 5 "http://127.0.0.1:${API_PORT}/" 2>/dev/null || true)"

if [[ -z "$payload" ]]; then
    printf '  no response — miner down, still starting, or API port wrong\n'
else
    # Per-GPU breakdown is only available from the raw payload; the parser
    # intentionally returns just totals so monitoring stays shape-agnostic.
    printf '%s' "$payload" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print("  unparseable API response")
    raise SystemExit

def num(v):
    if isinstance(v, bool): return 0.0
    if isinstance(v, (int, float)): return float(v)
    if isinstance(v, list) and v:
        try: return float(v[0])
        except (TypeError, ValueError): return 0.0
    if isinstance(v, dict):
        for k in ("total", "current", "hashrate"):
            if k in v: return num(v[k])
    return 0.0

hr = d.get("hashrate", {})
total = num(hr.get("total", 0) if isinstance(hr, dict) else hr)
gpus = d.get("gpus") or []
if not total and isinstance(gpus, list):
    total = sum(num(g.get("hashrate", 0)) for g in gpus if isinstance(g, dict))

print(f"  total: {total:,.2f} H/s")
if isinstance(gpus, list):
    for g in gpus:
        if not isinstance(g, dict):
            continue
        bid = g.get("bus_id", g.get("id", "?"))
        ghr = num(g.get("hashrate", 0))
        tmp = g.get("temperature", "?")
        fan = g.get("fan_speed", "?")
        print(f"    gpu{bid}: {ghr:,.2f} H/s   {tmp}C   fan {fan}%")
' 2>/dev/null || printf '  parse failed\n'
fi

printf '\n=== GPUs (nvidia-smi) ===\n'
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi \
        --query-gpu=index,name,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,utilization.gpu \
        --format=csv,noheader 2>/dev/null \
        || printf '  nvidia-smi failed\n'
else
    printf '  nvidia-smi not installed\n'
fi

printf '\n=== service ===\n'
if command -v systemctl >/dev/null 2>&1; then
    printf '  pearl-mining: %s\n' "$(systemctl is-active pearl-mining 2>/dev/null || echo unknown)"
else
    printf '  systemctl unavailable\n'
fi
