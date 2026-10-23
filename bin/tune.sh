#!/usr/bin/env bash
# Apply PearlHash GPU power/clock settings. Idempotent — safe to run repeatedly.
#
# Why these settings (H100 SXM, HBM3):
#   power limit   H100 SXM default 700W, adjustable range 200-700W. Lowering it
#                 on a bandwidth-bound algo usually costs less hashrate than it
#                 saves watts, so H/s per watt improves. MEASURE IT — the exact
#                 gain depends on your silicon and cooling.
#   core lock     Base 1590 MHz, boost ~1980 MHz. Locking low stops the boost
#                 controller from pulling power budget away from the memory
#                 subsystem on a memory-bound workload.
#   memory lock   ⚠ HBM3 on H100 SXM runs a FIXED 2619 MHz. Locking it is a
#                 no-op: it pins the only value the card accepts. There is no
#                 memory overclock available on this SKU. Do not expect gains.
#
# Usage:
#   sudo ./tune.sh                  # apply defaults (400W / 1600MHz)
#   sudo POWER=450 CORE=1700 ./tune.sh
#   sudo ./tune.sh --reset          # restore stock (700W, unlocked clocks)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
[[ -f "${LIB_DIR}/common.sh" ]] || LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh" || { echo "FATAL: cannot source lib/common.sh" >&2; exit 1; }

POWER="${POWER:-400}"
CORE="${CORE:-1600}"
MEM="${MEM:-2619}"
RESET=0

for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $arg (try --help)" ;;
    esac
done

# Check root BEFORE nvidia-smi: on a non-GPU dev box the more actionable error
# is "you need sudo", not "nvidia-smi is missing".
is_root || die "requires root: sudo $0"
require_cmd nvidia-smi

mapfile_gpus() {
    nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr -d ' '
}

GPUS="$(mapfile_gpus)"
[[ -n "$GPUS" ]] || die "no NVIDIA GPUs detected"

gpu_count="$(printf '%s\n' "$GPUS" | wc -l | tr -d ' ')"
printf 'detected %s GPU(s)\n\n' "$gpu_count"

printf '=== BEFORE ===\n'
nvidia-smi --query-gpu=index,name,power.draw,power.limit,clocks.sm,clocks.mem,temperature.gpu \
    --format=csv

if [[ "$RESET" -eq 1 ]]; then
    printf '\n=== RESETTING to stock (700W, unlocked clocks) ===\n'
    for i in $GPUS; do
        nvidia-smi -i "$i" -rgc 2>/dev/null || log "gpu${i}: core reset rejected"
        nvidia-smi -i "$i" -rmc 2>/dev/null || log "gpu${i}: mem reset rejected"
        nvidia-smi -i "$i" -pl 700 2>/dev/null || log "gpu${i}: power reset rejected"
    done
else
    printf '\n=== APPLYING power=%sW core=%sMHz mem=%sMHz ===\n' "$POWER" "$CORE" "$MEM"
    for i in $GPUS; do
        nvidia-smi -i "$i" -pl "$POWER" 2>/dev/null \
            || log "gpu${i}: power limit rejected (out of 200-700W range, or locked by host)"

        nvidia-smi -i "$i" -lgc "$CORE" 2>/dev/null \
            || log "gpu${i}: core lock rejected (needs persistence mode, no active compute)"

        nvidia-smi -i "$i" -lmc "$MEM" 2>/dev/null \
            || log "gpu${i}: mem lock rejected (HBM3 is fixed at 2619MHz on H100 SXM)"
    done
fi

printf '\n=== AFTER ===\n'
nvidia-smi --query-gpu=index,power.draw,power.limit,clocks.sm,clocks.mem,temperature.gpu \
    --format=csv

cat <<'NOTE'

=== VERIFY, DON'T ASSUME ===
The commonly quoted "power -35%, hashrate -10%, efficiency +40%" pattern is
plausible for a bandwidth-bound algorithm but it is NOT guaranteed on your
card, driver, or silicon.

Measure it properly:
  1. Run the miner at stock power for 10 min, record H/s
  2. Apply this script, wait 10 min for clocks to settle
  3. Record H/s again
  4. efficiency = H/s / watts  ->  compare, keep the winner

Rule of thumb: if hashrate drops more than ~15% at 400W, step up to 450-500W.
If it drops less than ~5%, try 350W.

RESET EVERYTHING:
  sudo ./tune.sh --reset
NOTE
