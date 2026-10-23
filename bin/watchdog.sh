#!/usr/bin/env bash
# PearlHash watchdog — detects a miner that is running but not mining.
#
# The failure systemd structurally cannot see: the process is alive, exit code
# is 0, but hashrate is 0. Causes: stale stratum connection, driver wedge,
# sustained rejects, thermal throttle to zero. systemd reports "running" and
# does nothing, so the rig silently earns nothing for hours.
#
# Exit codes:
#   0 healthy
#   1 degraded — a strike was recorded, threshold not yet reached
#   2 restarted (or started) the miner
#   3 unrecoverable — could not bring the miner back up
#
# Environment (all optional except SERVICE):
#   SERVICE       systemd unit name              default: pearl-mining
#   API_PORT      miner API port                 default: 4068
#   STATE_DIR     state/log directory            default: /var/lib/pearl-mining
#   ZERO_STRIKES  consecutive zeros before restart  default: 3
#   TG_TOKEN      Telegram bot token (alerts)
#   TG_CHAT       Telegram chat id (alerts)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
[[ -f "${LIB_DIR}/common.sh" ]] || LIB_DIR="${SCRIPT_DIR}/../lib"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh" || { echo "FATAL: cannot source lib/common.sh" >&2; exit 3; }

PARSER="${LIB_DIR}/parse_api.py"

SERVICE="${SERVICE:-pearl-mining}"
API_PORT="${API_PORT:-4068}"
STATE_DIR="${STATE_DIR:-/var/lib/pearl-mining}"
ZERO_STRIKES="${ZERO_STRIKES:-3}"
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"
BOOT_GRACE="${BOOT_GRACE:-30}"

STRIKE_FILE="${STATE_DIR}/zero_strikes"
LOG="${STATE_DIR}/watchdog.log"

is_uint "$ZERO_STRIKES" || die "ZERO_STRIKES must be a positive integer, got: $ZERO_STRIKES"
[[ "$ZERO_STRIKES" -ge 1 ]] || die "ZERO_STRIKES must be >= 1"

mkdir -p "$STATE_DIR" || die "cannot create state dir: $STATE_DIR"

# Overlapping timer runs would double-count strikes and race on the state file.
acquire_lock "watchdog" "$STATE_DIR" || exit 1

require_cmd systemctl
require_cmd curl

# --------------------------------------------------------------------------
# Alerts
# --------------------------------------------------------------------------
alert() {
    local msg="$1"
    log "ALERT: ${msg//$'\n'/ | }"

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]]; then
        return 0
    fi

    # Markdown is fine here: messages are plain text plus *asterisks*, no
    # characters that MarkdownV2 would require escaping.
    local resp
    resp="$(curl -sf -m 10 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" \
        --data-urlencode "text=${msg}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" 2>/dev/null || true)"

    if [[ -z "$resp" ]]; then
        log "alert delivery failed (network or bad token/chat)"
    fi
}

# --------------------------------------------------------------------------
# Read current hashrate
# --------------------------------------------------------------------------
current_hashrate() {
    local out
    out="$(read_hashrate "$API_PORT" "$PARSER")"
    printf '%s' "${out%% *}"
}

# --------------------------------------------------------------------------
# Count reject/disconnect lines in recent journal output.
# grep -c prints "0" AND exits 1 when there are no matches, so a naive
# `|| echo 0` yields "0\n0" and breaks integer comparison. Strip to digits.
# --------------------------------------------------------------------------
recent_rejects() {
    local n
    n="$(journalctl -u "$SERVICE" --since "10 min ago" --no-pager 2>/dev/null \
        | grep -ciE 'reject|unauthor|stale|disconnect|timeout' 2>/dev/null || true)"
    n="${n//[!0-9]/}"
    printf '%s' "${n:-0}"
}

# --------------------------------------------------------------------------
# 1. Is the service up at all?
# --------------------------------------------------------------------------
if ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    log "service ${SERVICE} is not active — attempting start"
    systemctl start "$SERVICE" 2>/dev/null || true
    sleep "$BOOT_GRACE"

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        alert "⚠️ *Pearl miner was down*
Restarted OK. Check \`journalctl -u ${SERVICE}\` for the cause."
        exit 2
    fi

    alert "🔴 *Pearl miner failed to start*
Unit: \`${SERVICE}\`
Run: \`systemctl status ${SERVICE}\`"
    exit 3
fi

# --------------------------------------------------------------------------
# 2. Is it actually producing hashrate?
# --------------------------------------------------------------------------
HR="$(current_hashrate)"
STRIKES="$(cat "$STRIKE_FILE" 2>/dev/null || echo 0)"
STRIKES="${STRIKES//[!0-9]/}"
STRIKES="${STRIKES:-0}"

if hashrate_positive "$HR"; then
    if [[ "$STRIKES" -gt 0 ]]; then
        log "hashrate recovered: ${HR} H/s after ${STRIKES} strike(s)"
    else
        log "healthy: ${HR} H/s"
    fi
    printf '0\n' > "$STRIKE_FILE"
    exit 0
fi

# --------------------------------------------------------------------------
# 3. Zero hashrate — count the strike
# --------------------------------------------------------------------------
STRIKES=$((STRIKES + 1))
printf '%s\n' "$STRIKES" > "$STRIKE_FILE"
log "zero hashrate, strike ${STRIKES}/${ZERO_STRIKES}"

REJECTS="$(recent_rejects)"
if [[ "$REJECTS" -gt 0 ]]; then
    log "journal shows ${REJECTS} reject/disconnect line(s) in the last 10 min"
fi

if [[ "$STRIKES" -lt "$ZERO_STRIKES" ]]; then
    exit 1
fi

# --------------------------------------------------------------------------
# 4. Threshold reached — restart with diagnostics captured
# --------------------------------------------------------------------------
log "strikes exhausted — restarting ${SERVICE}"

{
    printf '\n===== restart at %s (strikes=%s rejects=%s) =====\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STRIKES" "$REJECTS"
    journalctl -u "$SERVICE" --since "15 min ago" --no-pager 2>/dev/null | tail -40
} >> "$LOG" 2>/dev/null || true

systemctl restart "$SERVICE" 2>/dev/null || true
printf '0\n' > "$STRIKE_FILE"
sleep "$BOOT_GRACE"

NEW="$(current_hashrate)"
if hashrate_positive "$NEW"; then
    alert "🔄 *Pearl miner restarted*
Was: 0 H/s for ${STRIKES} consecutive checks
Rejects in last 10m: ${REJECTS}
Now: ${NEW} H/s"
    exit 2
fi

alert "🔴 *Pearl miner restarted but still at 0 H/s*
Rejects in last 10m: ${REJECTS}
Needs manual attention: \`systemctl status ${SERVICE}\`"
exit 3
