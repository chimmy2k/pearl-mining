#!/usr/bin/env bash
# PearlHash benchmark sweep — finds the best intensity/threads/power combo on
# YOUR cards instead of trusting generic recommendations.
#
# Each combo runs for SETTLE seconds, then the miner's own API is sampled every
# SAMPLE_INTERVAL seconds for MEASURE seconds. Results are ranked by mean H/s
# and by efficiency (H/s per watt) so you can pick for speed OR for profit.
#
# Usage:
#   ./bench.sh                                  # default grid
#   INTENSITIES="20 22 24" ./bench.sh           # custom intensities
#   THREADS="1 2" POWERS="300 400 500" ./bench.sh
#   QUICK=1 ./bench.sh                          # short timings, rough result
#
# Requires: miner binary, POOL_URL, USER_STR, python3, curl.
# The miner's API port is deliberately offset from the production port so a
# running production miner does not collide with the sweep.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
[[ -f "${LIB_DIR}/common.sh" ]] || LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh" || { echo "FATAL: cannot source lib/common.sh" >&2; exit 1; }

PARSER="${LIB_DIR}/parse_api.py"

MINER_BIN="${MINER_BIN:-/opt/wildrig/wildrig-multi}"
POOL_URL="${POOL_URL:-}"
USER_STR="${USER_STR:-}"
API_PORT="${API_PORT:-4069}"
INTENSITIES="${INTENSITIES:-20 21 22 23 24 25}"
THREADS="${THREADS:-1 2}"
POWERS="${POWERS:-}"            # empty = don't touch power limits
GPU_LIST="${GPU_LIST:-}"
OUT="${OUT:-./bench-results.tsv}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"

if [[ "${QUICK:-0}" == "1" ]]; then
    SETTLE="${SETTLE:-20}"
    MEASURE="${MEASURE:-30}"
else
    SETTLE="${SETTLE:-45}"
    MEASURE="${MEASURE:-90}"
fi

# --------------------------------------------------------------------------
# Validation — fail loudly before touching hardware
# --------------------------------------------------------------------------
[[ -x "$MINER_BIN" ]] || die "miner not executable: $MINER_BIN (set MINER_BIN=...)"
[[ -n "$POOL_URL" ]]  || die "POOL_URL is required (e.g. stratum+tcp://host:port)"
[[ -n "$USER_STR" ]]  || die "USER_STR is required (e.g. 'prl1...@nock=...')"
is_uint "$API_PORT"   || die "API_PORT must be an integer, got: $API_PORT"
is_uint "$SETTLE"     || die "SETTLE must be an integer, got: $SETTLE"
is_uint "$MEASURE"    || die "MEASURE must be an integer, got: $MEASURE"
[[ "$SETTLE" -gt 0 && "$MEASURE" -gt 0 ]] || die "SETTLE and MEASURE must be > 0"

require_cmd curl
require_cmd python3

# Refuse to sweep on top of a running production miner using the same port.
if curl -sf -m 2 "http://127.0.0.1:${API_PORT}/" >/dev/null 2>&1; then
    die "something is already answering on port ${API_PORT}; pick another API_PORT"
fi

# --------------------------------------------------------------------------
# Cleanup — a Ctrl-C must never leave an orphan miner burning GPU time
# --------------------------------------------------------------------------
MINER_PID=""

cleanup() {
    if [[ -n "$MINER_PID" ]] && kill -0 "$MINER_PID" 2>/dev/null; then
        kill -INT "$MINER_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$MINER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$MINER_PID" 2>/dev/null || true
    fi
    MINER_PID=""
}
trap 'cleanup; log "interrupted, miner stopped"' INT TERM
trap 'cleanup' EXIT

# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------
# Mean of the samples collected during the measure window. Echoes "<mean> <max>"
# and returns 1 if no valid sample was seen (API silent = combo likely crashed).
sample_hashrate() {
    local duration="$1"
    local sum="0" max="0" count="0"
    local deadline
    deadline=$(( $(date +%s) + duration ))

    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        local total
        total="$(read_hashrate "$API_PORT" "$PARSER")"
        total="${total%% *}"

        if hashrate_positive "$total"; then
            sum="$(awk -v s="$sum" -v t="$total" 'BEGIN { printf "%.2f", s + t }')"
            max="$(awk -v m="$max" -v t="$total" 'BEGIN { printf "%.2f", (t > m ? t : m) }')"
            count=$((count + 1))
        fi
        sleep "$SAMPLE_INTERVAL"
    done

    if [[ "$count" -eq 0 ]]; then
        printf '0 0\n'
        return 1
    fi

    local mean
    mean="$(awk -v s="$sum" -v n="$count" 'BEGIN { printf "%.2f", s / n }')"
    printf '%s %s\n' "$mean" "$max"
    return 0
}

# --------------------------------------------------------------------------
# Sweep
# --------------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
printf 'intensity\tthreads\tpower\thashrate_avg\thashrate_max\twatts\ttemp_c\tstatus\n' > "$OUT"

n_int=$(printf '%s\n' $INTENSITIES | wc -l | tr -d ' ')
n_thr=$(printf '%s\n' $THREADS | wc -l | tr -d ' ')
if [[ -n "$POWERS" ]]; then
    n_pwr=$(printf '%s\n' $POWERS | wc -l | tr -d ' ')
else
    n_pwr=1
fi
total_combos=$((n_int * n_thr * n_pwr))

printf '=== PearlHash sweep ===\n'
printf 'miner      : %s\n' "$MINER_BIN"
printf 'grid       : intensities=[%s] threads=[%s] powers=[%s]\n' \
    "$INTENSITIES" "$THREADS" "${POWERS:-unchanged}"
printf 'timing     : %ss settle + %ss measure per combo\n' "$SETTLE" "$MEASURE"
printf 'combos     : %s (est. %s min)\n' "$total_combos" \
    "$(awk -v c="$total_combos" -v s="$SETTLE" -v m="$MEASURE" 'BEGIN { printf "%.0f", c*(s+m)/60 }')"
printf 'output     : %s\n\n' "$OUT"

combo=0
for power in ${POWERS:-0}; do
    if [[ "$power" != "0" ]] && is_root; then
        for i in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr -d ' '); do
            nvidia-smi -i "$i" -pl "$power" 2>/dev/null || true
        done
        sleep 3
    elif [[ "$power" != "0" ]]; then
        log "power sweep requested but not root — skipping power=${power}W"
        continue
    fi

    for intensity in $INTENSITIES; do
        for threads in $THREADS; do
            combo=$((combo + 1))
            printf '[%s/%s] intensity=%s threads=%s power=%s\n' \
                "$combo" "$total_combos" "$intensity" "$threads" "${power/0/unchanged}"

            # Array is empty when GPU_LIST is unset. Expanding "${arr[@]}" on an
            # empty array under `set -u` is an unbound-variable error on bash
            # < 4.4, so use the ${arr[@]+...} guard instead.
            gpu_args=()
            [[ -n "$GPU_LIST" ]] && gpu_args=(-d "$GPU_LIST")

            "$MINER_BIN" --algo pearlhash \
                --url "$POOL_URL" \
                --user "$USER_STR" \
                --pass x \
                --api-port "$API_PORT" \
                --gpu-intensity "$intensity" \
                --gpu-threads "$threads" \
                --print-time 9999 \
                --no-color \
                ${gpu_args[@]+"${gpu_args[@]}"} \
                >/dev/null 2>&1 &
            MINER_PID=$!

            sleep "$SETTLE"

            sample_rc=0
            sample_out="$(sample_hashrate "$MEASURE")" || sample_rc=$?
            mean="${sample_out%% *}"
            peak="${sample_out##* }"

            read -r watts temp <<< "$(read_gpu_power_temp)"
            watts="${watts:-0}"
            temp="${temp:-0}"

            if [[ "$sample_rc" -eq 0 ]]; then
                status="ok"
                printf '    -> avg %s H/s  peak %s H/s  %sW  %sC\n' \
                    "$mean" "$peak" "$watts" "$temp"
            else
                status="no-api"
                mean="0"
                peak="0"
                printf '    -> NO API RESPONSE (combo crashed or miner exited)\n'
            fi

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$intensity" "$threads" "${power/0/-}" \
                "$mean" "$peak" "$watts" "$temp" "$status" >> "$OUT"

            cleanup
            sleep 3
        done
    done
done

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
printf '\n=== RESULTS (by mean hashrate) ===\n'
{
    head -1 "$OUT"
    tail -n +2 "$OUT" | grep -v 'no-api' | sort -t"$(printf '\t')" -k4 -gr
} | column -t -s"$(printf '\t')" 2>/dev/null || cat "$OUT"

BEST_LINE="$(tail -n +2 "$OUT" | grep -v 'no-api' | sort -t"$(printf '\t')" -k4 -gr | head -1)"

if [[ -z "$BEST_LINE" ]]; then
    printf '\nNo valid combo produced hashrate.\n'
    printf 'Check: pool reachable? worker string accepted? driver/OpenCL OK?\n'
    exit 1
fi

best_int="$(printf '%s' "$BEST_LINE" | cut -f1)"
best_thr="$(printf '%s' "$BEST_LINE" | cut -f2)"
best_avg="$(printf '%s' "$BEST_LINE" | cut -f4)"
best_w="$(printf '%s' "$BEST_LINE" | cut -f6)"

printf '\n=== BEST BY HASHRATE ===\n'
printf '  --gpu-intensity %s --gpu-threads %s   (%s H/s)\n' \
    "$best_int" "$best_thr" "$best_avg"

# Efficiency view — only meaningful when power was actually measured
if [[ "${best_w:-0}" -gt 0 ]]; then
    printf '\n=== BEST BY EFFICIENCY (H/s per watt) ===\n'
    tail -n +2 "$OUT" | grep -v 'no-api' \
        | awk -F'\t' '$6 > 0 && $4 > 0 { printf "%.4f\t%s\t%s\t%s\t%s\t%s\n", $4/$6, $1, $2, $4, $6, $3 }' \
        | sort -gr \
        | head -3 \
        | awk -F'\t' '{ printf "  %s H/W  ->  intensity=%s threads=%s  (%s H/s @ %sW)\n", $1, $2, $3, $4, $5 }'
fi

printf '\nApply with:\n'
printf '  INTENSITY=%s THREADS=%s sudo -E ./install.sh\n' "$best_int" "$best_thr"
printf 'Results saved to %s\n' "$OUT"
