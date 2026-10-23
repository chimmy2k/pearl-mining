#!/usr/bin/env bash
# Shared helpers for the PearlHash mining stack.
# Sourced by bench.sh, watchdog.sh, watch.sh. Not executed directly.
#
# Deliberately portable: works on bash 3.2 (macOS) as well as bash 5 (Linux).
# Avoids ${arr[@]} on empty arrays, which is an unbound-variable error under
# `set -u` before bash 4.4 — a real crash we hit while building this.

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
# All log lines go to stderr so command substitution capturing a function's
# stdout never picks up log noise.
log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# --------------------------------------------------------------------------
# Dependency checks
# --------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# --------------------------------------------------------------------------
# Hashrate API
# --------------------------------------------------------------------------
# Prints "<total> <peak>". Always succeeds; prints "0.00 0.00" when the API is
# unreachable or returns junk. Never let a monitoring probe crash the caller.
read_hashrate() {
    local port="${1:-4068}"
    local parser="${2:-}"
    local payload

    payload="$(curl -sf -m 5 "http://127.0.0.1:${port}/" 2>/dev/null || true)"

    if [[ -z "$payload" ]]; then
        printf '0.00 0.00\n'
        return 0
    fi

    if [[ -n "$parser" && -f "$parser" ]]; then
        printf '%s' "$payload" | python3 "$parser" 2>/dev/null || printf '0.00 0.00\n'
    else
        # Minimal fallback: extract the first number after "total"
        printf '%s' "$payload" \
            | tr -d '\n' \
            | sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\[\{0,1\}[[:space:]]*\([0-9.]*\).*/\1 \1/p' \
            | head -1 \
            || printf '0.00 0.00\n'
        printf '\n'
    fi
}

# Returns 0 if hashrate > 0, 1 otherwise. Float-safe (bash has no float compare).
hashrate_positive() {
    awk -v h="${1:-0}" 'BEGIN { exit !(h > 0) }'
}

# --------------------------------------------------------------------------
# GPU telemetry
# --------------------------------------------------------------------------
# Prints "<total_watts> <max_temp_c>" across all GPUs. Prints "0 0" if
# nvidia-smi is absent — never fails, monitoring must not break the caller.
read_gpu_power_temp() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf '0 0\n'
        return 0
    fi
    nvidia-smi --query-gpu=power.draw,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null \
        | awk -F',[[:space:]]*' '
            { p += $1 + 0; if ($2 + 0 > t) t = $2 + 0 }
            END { printf "%d %d\n", p, t }
        ' || printf '0 0\n'
}

# --------------------------------------------------------------------------
# Portable locking
# --------------------------------------------------------------------------
# flock(1) is Linux-only. Fall back to an atomic mkdir lock with stale-PID
# detection so the watchdog cannot stack up overlapping runs on systems where
# a check takes longer than the timer interval.
LOCK_DIR=""
LOCK_ACQUIRED=0

acquire_lock() {
    local name="$1"
    local dir="${2:-/var/lib/pearl-mining}"
    LOCK_DIR="${dir}/.${name}.lock"

    mkdir -p "$dir" 2>/dev/null || true

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_ACQUIRED=1
        trap 'release_lock' EXIT INT TERM
        return 0
    fi

    # Lock exists — is the holder still alive?
    local holder
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
        log "another instance is running (pid $holder), skipping"
        return 1
    fi

    log "stale lock from pid ${holder:-unknown}, taking over"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_ACQUIRED=1
        trap 'release_lock' EXIT INT TERM
        return 0
    fi

    log "could not acquire lock, skipping"
    return 1
}

release_lock() {
    if [[ "$LOCK_ACQUIRED" -eq 1 && -n "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        LOCK_ACQUIRED=0
    fi
}

# --------------------------------------------------------------------------
# Misc
# --------------------------------------------------------------------------
# Portable "is this a positive integer" check used by arg validation.
is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# True when running as root (needed for nvidia-smi -pl / systemctl).
is_root() {
    [[ "$(id -u)" -eq 0 ]]
}
