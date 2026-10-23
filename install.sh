#!/usr/bin/env bash
# PearlHash mining stack installer — for YOUR OWN hardware.
#
# Installs a supervised miner with pool failover, boot-persistent GPU tuning,
# and a hashrate watchdog. No evasion layer: on your own box there is nothing
# to hide, and hiding would only blind you to your own telemetry.
#
# Usage:
#   export POOL_URL=stratum+tcp://pool:port
#   export POOL_URL_2=stratum+tls://backup:port    # optional failover
#   sudo -E ./install.sh
#
# Everything is configurable by environment variable; see --help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh" || { echo "FATAL: cannot source lib/common.sh" >&2; exit 1; }

# --------------------------------------------------------------------------
# Configuration (all overridable)
# --------------------------------------------------------------------------
PRL_ADDR="${PRL_ADDR:-}"
NOCK_ADDR="${NOCK_ADDR:-}"
POOL_URL="${POOL_URL:-}"
POOL_URL_2="${POOL_URL_2:-}"
POOL_URL_3="${POOL_URL_3:-}"
POOL_PASS="${POOL_PASS:-x}"

MINER_BIN="${MINER_BIN:-/opt/wildrig/wildrig-multi}"
API_PORT="${API_PORT:-4068}"

INTENSITY="${INTENSITY:-22}"
THREADS="${THREADS:-2}"
POWER="${POWER:-400}"
CORE_CLOCK="${CORE_CLOCK:-1600}"
MEM_CLOCK="${MEM_CLOCK:-2619}"
TEMP_LIMIT="${TEMP_LIMIT:-80}"
TEMP_RESUME="${TEMP_RESUME:-70}"

INSTALL_DIR="${INSTALL_DIR:-/opt/pearl-mining}"
CONF_DIR="${CONF_DIR:-/etc/pearl-mining}"
STATE_DIR="${STATE_DIR:-/var/lib/pearl-mining}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"
ZERO_STRIKES="${ZERO_STRIKES:-3}"

DRY_RUN=0
FORCE=0

# True when this install actually writes to the live systemd directory. An
# overridden SYSTEMD_DIR means a sandboxed/test install that touches nothing
# privileged, so root is not required.
installs_into_real_systemd() {
    [[ "$SYSTEMD_DIR" == "/etc/systemd/system" ]]
}

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'HELP'

Environment variables:
  POOL_URL, POOL_URL_2, POOL_URL_3   stratum endpoints (first is primary)
  PRL_ADDR, NOCK_ADDR                worker identity (required)
  POOL_PASS                          pool password (default: x)
  MINER_BIN                          path to wildrig-multi
  API_PORT                           miner API port (default 4068)
  INTENSITY, THREADS                 GPU tuning (default 22, 2)
  POWER, CORE_CLOCK, MEM_CLOCK       GPU limits (default 400W, 1600, 2619)
  TEMP_LIMIT, TEMP_RESUME            thermal cutoffs (default 80, 70)
  INSTALL_DIR, CONF_DIR, STATE_DIR   install paths
  TG_TOKEN, TG_CHAT                  Telegram alerts (optional)
  ZERO_STRIKES                       checks before restart (default 3)

Flags:
  --dry-run    render everything, change nothing
  --force      overwrite an existing installation
  --help       this message
HELP
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# Validation — fail before touching the filesystem
# --------------------------------------------------------------------------
errors=0
err() { printf '  ✗ %s\n' "$*" >&2; errors=$((errors + 1)); }
ok()  { printf '  ✓ %s\n' "$*"; }

printf '=== validating configuration ===\n'

[[ -n "$PRL_ADDR" ]]  || err "PRL_ADDR is required (your prl1... address)"
[[ -n "$NOCK_ADDR" ]] || err "NOCK_ADDR is required (the value after @nock=)"
[[ -n "$POOL_URL" ]]  || err "POOL_URL is required (stratum+tcp://host:port)"

for pair in "PRL_ADDR:$PRL_ADDR" "NOCK_ADDR:$NOCK_ADDR"; do
    name="${pair%%:*}"
    val="${pair#*:}"
    if [[ -n "$val" && "$val" == *" "* ]]; then
        err "${name} contains a space — check your shell quoting"
    fi
done

if [[ -n "$PRL_ADDR" && "$PRL_ADDR" != prl1* ]]; then
    err "PRL_ADDR does not start with 'prl1' (got: ${PRL_ADDR:0:12}...)"
fi

for pvar in POOL_URL POOL_URL_2 POOL_URL_3; do
    val="${!pvar}"
    [[ -z "$val" ]] && continue
    case "$val" in
        stratum+tcp://*|stratum+tls://*|stratum+ssl://*|tls://*|ssl://*) ;;
        *) err "${pvar} should start with stratum+tcp:// or stratum+tls:// (got: ${val:0:20})" ;;
    esac
done

[[ -x "$MINER_BIN" ]] || err "miner not executable: ${MINER_BIN} (set MINER_BIN=...)"

for pair in "API_PORT:$API_PORT" "INTENSITY:$INTENSITY" "THREADS:$THREADS" \
            "POWER:$POWER" "CORE_CLOCK:$CORE_CLOCK" "ZERO_STRIKES:$ZERO_STRIKES" \
            "TEMP_LIMIT:$TEMP_LIMIT" "TEMP_RESUME:$TEMP_RESUME"; do
    name="${pair%%:*}"
    val="${pair#*:}"
    is_uint "$val" || err "${name} must be a non-negative integer (got: ${val})"
done

if is_uint "$POWER" && { [[ "$POWER" -lt 100 || "$POWER" -gt 700 ]]; }; then
    err "POWER=${POWER} outside the H100 SXM range of 100-700W"
fi
if is_uint "$TEMP_LIMIT" && is_uint "$TEMP_RESUME" && [[ "$TEMP_RESUME" -ge "$TEMP_LIMIT" ]]; then
    err "TEMP_RESUME (${TEMP_RESUME}) must be below TEMP_LIMIT (${TEMP_LIMIT})"
fi
if is_uint "$API_PORT" && { [[ "$API_PORT" -lt 1024 || "$API_PORT" -gt 65535 ]]; }; then
    err "API_PORT=${API_PORT} must be between 1024 and 65535"
fi

if [[ "$errors" -gt 0 ]]; then
    printf '\n%d validation error(s). Nothing was changed.\n' "$errors" >&2
    exit 2
fi

ok "worker identity: ${PRL_ADDR:0:16}...@nock=${NOCK_ADDR:0:12}..."
ok "primary pool: ${POOL_URL}"
[[ -n "$POOL_URL_2" ]] && ok "failover pool 2: ${POOL_URL_2}"
[[ -n "$POOL_URL_3" ]] && ok "failover pool 3: ${POOL_URL_3}"
ok "tuning: intensity=${INTENSITY} threads=${THREADS} power=${POWER}W core=${CORE_CLOCK}MHz"
ok "miner: ${MINER_BIN}"

# --------------------------------------------------------------------------
# Environment checks
# --------------------------------------------------------------------------
# In --dry-run the target machine is NOT this machine, so a missing systemd or
# GPU is a warning, not an error. Only hard-fail on things that make rendering
# itself impossible.
printf '\n=== environment ===\n'

warn() { printf '  ! %s\n' "$*"; }

if is_root; then
    ok "running as root"
elif [[ "$DRY_RUN" -eq 1 ]]; then
    ok "not root — acceptable for --dry-run"
elif ! installs_into_real_systemd; then
    # Sandboxed install (SYSTEMD_DIR overridden): nothing touches /etc, so no
    # privilege is required. This is what makes the real install path testable
    # in CI without root.
    ok "not root — sandboxed install into ${SYSTEMD_DIR}"
else
    err "must run as root for systemd installation (use: sudo -E ./install.sh)"
fi

for cmd in systemctl python3 curl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd found"
    elif [[ "$DRY_RUN" -eq 1 ]] || ! installs_into_real_systemd; then
        warn "$cmd not found here (not required for this install target)"
    else
        err "$cmd not found"
    fi
done

if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
    ok "nvidia-smi found — ${gpu_count} GPU(s) visible"
    [[ "$gpu_count" -eq 0 ]] && err "nvidia-smi reports zero GPUs"
elif [[ "$DRY_RUN" -eq 1 ]] || ! installs_into_real_systemd; then
    warn "nvidia-smi not found here (not required for this install target)"
else
    err "nvidia-smi not found — GPU tuning and thermal limits will not work"
fi

[[ "$errors" -gt 0 ]] && { printf '\n%d error(s). Nothing was changed.\n' "$errors" >&2; exit 2; }

if [[ -d "$INSTALL_DIR" && "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    printf '\n%s already exists. Re-run with --force to overwrite.\n' "$INSTALL_DIR" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Render
# --------------------------------------------------------------------------
printf '\n=== rendering ===\n'

render() {
    # Replace @PLACEHOLDER@ tokens.
    #
    # The substitution map is passed through a temp file, not `awk -v`: a
    # multi-line -v value aborts awk with "newline in string", which silently
    # produced empty unit files. Using index()/substr() instead of gsub() also
    # avoids regex and '&' escaping hazards in URLs and paths.
    local src="$1" dst="$2"
    shift 2

    local map_path
    map_path="$(mktemp)"
    printf '%s\n' "$@" > "$map_path"

    awk -v map_path="$map_path" '
        BEGIN {
            while ((getline line < map_path) > 0) {
                eq = index(line, "=")
                if (eq == 0) continue
                rep["@" substr(line, 1, eq - 1) "@"] = substr(line, eq + 1)
            }
            close(map_path)
        }
        {
            out = $0
            for (k in rep) {
                while ((idx = index(out, k)) > 0) {
                    out = substr(out, 1, idx - 1) rep[k] substr(out, idx + length(k))
                }
            }
            print out
        }
    ' "$src" > "$dst"

    rm -f "$map_path"
}

# Build pool argument block: one -o/-O pair per pool, in failover order.
build_pool_args() {
    local p
    for p in "$POOL_URL" "$POOL_URL_2" "$POOL_URL_3"; do
        [[ -z "$p" ]] && continue
        printf '  -o %q -O %q \\\n' "$p" "${PRL_ADDR}@nock=${NOCK_ADDR}:${POOL_PASS}"
    done
}

render_run_sh() {
    local dst="$1"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# GENERATED by install.sh — edit install.sh or the environment, not this.\n'
        printf '# Regenerated on every install; local edits are lost.\n'
        printf 'set -euo pipefail\n\n'
        printf 'exec %q \\\n' "$MINER_BIN"
        printf '  --algo pearlhash \\\n'
        build_pool_args
        printf '  --api-port %q \\\n' "$API_PORT"
        printf '  --gpu-intensity %q \\\n' "$INTENSITY"
        printf '  --gpu-threads %q \\\n' "$THREADS"
        printf '  --gpu-powerlimit %q \\\n' "$POWER"
        printf '  --gpu-core-clock %q \\\n' "$CORE_CLOCK"
        printf '  --gpu-temp-limit %q \\\n' "$TEMP_LIMIT"
        printf '  --gpu-temp-resume %q \\\n' "$TEMP_RESUME"
        printf '  --retries 2 \\\n'
        printf '  --retry-pause 5 \\\n'
        printf '  --print-time 60 \\\n'
        printf '  --no-color\n'
    } > "$dst"
    chmod 755 "$dst"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    printf '\n--- generated run.sh (dry run) ---\n'
    render_run_sh "$tmpdir/run.sh"
    cat "$tmpdir/run.sh"
    printf '\n--- generated systemd units (dry run) ---\n'
    for unit in "$SCRIPT_DIR"/systemd/*; do
        [[ -f "$unit" ]] || continue
        printf '\n# %s\n' "$(basename "$unit")"
        render "$unit" "$tmpdir/$(basename "$unit")" \
            "INSTALL_DIR=$INSTALL_DIR" "CONF_DIR=$CONF_DIR"
        cat "$tmpdir/$(basename "$unit")"
    done
    printf '\nDry run complete. Nothing was written to the system.\n'
    exit 0
fi

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
printf '\n=== installing to %s ===\n' "$INSTALL_DIR"

# Back up any previous install instead of clobbering it silently.
if [[ -d "$INSTALL_DIR" && "$FORCE" -eq 1 ]]; then
    backup="${INSTALL_DIR}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$INSTALL_DIR" "$backup"
    ok "previous install moved to ${backup}"
fi

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$CONF_DIR" "$STATE_DIR" "$SYSTEMD_DIR"
chmod 755 "$STATE_DIR"

install -m 644 "$LIB_DIR/common.sh"    "$INSTALL_DIR/lib/common.sh"
install -m 644 "$LIB_DIR/parse_api.py" "$INSTALL_DIR/lib/parse_api.py"
install -m 755 "$SCRIPT_DIR/bin/watch.sh"    "$INSTALL_DIR/watchdog-monitor.sh"
install -m 755 "$SCRIPT_DIR/bin/watchdog.sh" "$INSTALL_DIR/watchdog.sh"
install -m 755 "$SCRIPT_DIR/bin/bench.sh"    "$INSTALL_DIR/bench.sh"
install -m 755 "$SCRIPT_DIR/bin/tune.sh"     "$INSTALL_DIR/tune.sh"
ok "scripts installed"

render_run_sh "$INSTALL_DIR/run.sh"
ok "run.sh generated"

# Secrets go in a 0600 EnvironmentFile, not inline in a world-readable unit.
umask 077
{
    printf 'TG_TOKEN=%s\n' "$TG_TOKEN"
    printf 'TG_CHAT=%s\n' "$TG_CHAT"
    printf 'API_PORT=%s\n' "$API_PORT"
    printf 'STATE_DIR=%s\n' "$STATE_DIR"
    printf 'ZERO_STRIKES=%s\n' "$ZERO_STRIKES"
} > "$CONF_DIR/watchdog.env"
umask 022
chmod 600 "$CONF_DIR/watchdog.env"
ok "watchdog.env written (mode 600)"

for unit in pearl-tune.service pearl-mining.service pearl-watchdog.service pearl-watchdog.timer; do
    render "$SCRIPT_DIR/systemd/$unit" "$SYSTEMD_DIR/$unit" \
        "INSTALL_DIR=$INSTALL_DIR" "CONF_DIR=$CONF_DIR"
    chmod 644 "$SYSTEMD_DIR/$unit"
    ok "unit installed: $unit"
done

if installs_into_real_systemd; then
    if ! systemctl daemon-reload; then
        err "systemctl daemon-reload failed"
    fi
    if ! systemctl enable pearl-tune.service pearl-mining.service pearl-watchdog.timer >/dev/null 2>&1; then
        err "systemctl enable failed — check unit files in ${SYSTEMD_DIR}"
    fi
    ok "units enabled via systemctl"
else
    ok "sandboxed install — systemctl not invoked (units written to ${SYSTEMD_DIR})"
fi

if [[ "$errors" -gt 0 ]]; then
    printf '\nInstall finished with %d error(s).\n' "$errors" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
cat <<SUMMARY

=== installed ===

  ${INSTALL_DIR}/run.sh                  miner invocation (generated)
  ${INSTALL_DIR}/tune.sh                 power/clock (also runs at boot)
  ${INSTALL_DIR}/watchdog.sh             hashrate watchdog
  ${INSTALL_DIR}/watchdog-monitor.sh     live readout
  ${INSTALL_DIR}/bench.sh                intensity/threads sweep
  ${INSTALL_DIR}/lib/                    shared parser + helpers
  ${CONF_DIR}/watchdog.env               alerts + watchdog config (0600)

  systemd: pearl-tune.service, pearl-mining.service,
           pearl-watchdog.service, pearl-watchdog.timer

--- NEXT STEPS ---

1. Start the miner:
     systemctl start pearl-mining

2. Confirm it is actually hashing (do not assume):
     ${INSTALL_DIR}/watchdog-monitor.sh
     journalctl -u pearl-mining -n 50 --no-pager

3. Find YOUR best tuning before trusting any default:
     sudo ${INSTALL_DIR}/bench.sh
   Then reinstall with the winning values:
     INTENSITY=<best> THREADS=<best> sudo -E ./install.sh --force

4. Start the watchdog:
     systemctl start pearl-watchdog.timer

Reset GPU settings to stock:
     sudo ${INSTALL_DIR}/tune.sh --reset
SUMMARY
