#!/usr/bin/env bash
# Test harness for the PearlHash mining stack.
#
# Runs without a GPU, without a miner binary, and without root. Every test
# exercises real code paths — the fake miner actually serves HTTP so bench.sh
# and watchdog.sh are driven end-to-end, not mocked at the function boundary.
#
# Usage:
#   ./tests/run-tests.sh          # all tests
#   ./tests/run-tests.sh parser   # only tests whose name matches "parser"

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${REPO_DIR}/tests"
FILTER="${1:-}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

# Colours only when attached to a terminal.
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_OFF=""
fi

section() { printf '\n%s── %s %s\n' "$C_DIM" "$*" "$C_OFF"; }

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES="${FAILED_NAMES}${1}"$'\n'
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
}
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s %s (%s)\n' "$C_YEL" "$C_OFF" "$1" "${2:-}"; }

# assert_eq <name> <expected> <actual>
assert_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "missing [$2] in output"; fi
}

# assert_not_contains <name> <needle> <haystack>
assert_not_contains() {
    if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected [$2] in output"; fi
}

should_run() {
    [[ -z "$FILTER" ]] && return 0
    [[ "$1" == *"$FILTER"* ]]
}

WORKDIR="$(mktemp -d)"
cleanup() {
    # Kill any fake miner left behind by an aborted test
    if [[ -n "${FAKE_PID:-}" ]] && kill -0 "$FAKE_PID" 2>/dev/null; then
        kill -9 "$FAKE_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

printf 'PearlHash stack test suite\n'
printf 'repo: %s\n' "$REPO_DIR"
printf 'bash: %s\n' "$(bash --version | head -1)"
[[ -n "$FILTER" ]] && printf 'filter: %s\n' "$FILTER"

# ==========================================================================
section "1. syntax — every script must parse"
# ==========================================================================
if should_run "syntax"; then
    for f in "$REPO_DIR"/*.sh "$REPO_DIR"/bin/*.sh "$REPO_DIR"/lib/*.sh "$TESTS_DIR"/*.sh; do
        [[ -f "$f" ]] || continue
        if bash -n "$f" 2>/dev/null; then
            pass "bash -n $(basename "$f")"
        else
            fail "bash -n $(basename "$f")" "$(bash -n "$f" 2>&1 | head -2)"
        fi
    done
    if python3 -m py_compile "$REPO_DIR/lib/parse_api.py" "$TESTS_DIR/fake_miner.py" 2>/dev/null; then
        pass "python compiles"
    else
        fail "python compiles"
    fi
fi

# ==========================================================================
section "2. shellcheck — static analysis"
# ==========================================================================
if should_run "shellcheck"; then
    if command -v shellcheck >/dev/null 2>&1; then
        SC_OUT="$(shellcheck -S warning -f gcc \
            "$REPO_DIR"/*.sh "$REPO_DIR"/bin/*.sh "$REPO_DIR"/lib/*.sh 2>&1 || true)"
        if [[ -z "$SC_OUT" ]]; then
            pass "shellcheck clean (severity >= warning)"
        else
            fail "shellcheck findings" "$(printf '%s' "$SC_OUT" | head -8)"
        fi
    else
        skip "shellcheck" "not installed"
    fi
fi

# ==========================================================================
section "3. parse_api.py — every API shape wildrig can emit"
# ==========================================================================
if should_run "parser"; then
    PARSER="$REPO_DIR/lib/parse_api.py"

    t() { # t <name> <json> <expected>
        local got
        got="$(printf '%s' "$2" | python3 "$PARSER" 2>/dev/null)"
        assert_eq "$1" "$3" "$got"
    }

    t "list form (wildrig actual)" \
        '{"hashrate":{"total":[1234.5,1300.0],"highest":1300.0}}' "1234.50 1300.00"
    t "scalar total" \
        '{"hashrate":{"total":999.9}}' "999.90 0.00"
    t "bare number" \
        '{"hashrate":555.5}' "555.50 0.00"
    t "gpus only, no total" \
        '{"gpus":[{"hashrate":100},{"hashrate":200}]}' "300.00 300.00"
    t "total zero falls back to gpus" \
        '{"hashrate":{"total":[0]},"gpus":[{"hashrate":42}]}' "42.00 42.00"
    t "empty object" '{}' "0.00 0.00"
    t "empty input" '' "0.00 0.00"
    t "invalid json" 'not json' "0.00 0.00"
    t "json array not object" '[1,2,3]' "0.00 0.00"
    t "null hashrate" '{"hashrate":null}' "0.00 0.00"
    t "string hashrate" '{"hashrate":"777.5"}' "777.50 0.00"
    t "bool hashrate (not a number)" '{"hashrate":true}' "0.00 0.00"
    t "nested dict total" '{"hashrate":{"total":{"current":88}}}' "88.00 0.00"
    t "empty gpus array" '{"gpus":[]}' "0.00 0.00"
    t "gpus not a list" '{"gpus":"nope"}' "0.00 0.00"
    t "gpu entry not a dict" '{"gpus":[1,2]}' "0.00 0.00"

    # Must never exit nonzero — monitoring cannot crash the caller
    rc=0
    printf 'garbage' | python3 "$PARSER" >/dev/null 2>&1 || rc=$?
    assert_eq "exit code 0 on garbage input" "0" "$rc"
fi

# ==========================================================================
section "4. common.sh — helpers"
# ==========================================================================
if should_run "common"; then
    run_common() {
        # shellcheck source=/dev/null
        ( . "$REPO_DIR/lib/common.sh" >/dev/null 2>&1; eval "$1" )
    }

    assert_eq "is_uint 123"   "0" "$(run_common 'is_uint 123'; echo $?)"
    assert_eq "is_uint empty" "1" "$(run_common 'is_uint ""'; echo $?)"
    assert_eq "is_uint -5"    "1" "$(run_common 'is_uint -5'; echo $?)"
    assert_eq "is_uint 12a"   "1" "$(run_common 'is_uint 12a'; echo $?)"

    assert_eq "hashrate_positive 1"    "0" "$(run_common 'hashrate_positive 1'; echo $?)"
    assert_eq "hashrate_positive 0"    "1" "$(run_common 'hashrate_positive 0'; echo $?)"
    assert_eq "hashrate_positive 0.001" "0" "$(run_common 'hashrate_positive 0.001'; echo $?)"

    assert_eq "read_hashrate on dead port" "0.00 0.00" \
        "$(run_common 'read_hashrate 59999 "$REPO_DIR/lib/parse_api.py"')"

    assert_eq "read_gpu_power_temp without nvidia-smi" "0 0" \
        "$(run_common 'PATH=/usr/bin:/bin read_gpu_power_temp')"

    # Locking: second acquire must fail while the first holds it
    locktest="$(run_common '
        TMPD=$(mktemp -d)
        acquire_lock testlock "$TMPD" && echo "first-ok" || echo "first-fail"
        ( acquire_lock testlock "$TMPD" && echo "second-ok" || echo "second-blocked" ) 2>/dev/null
        release_lock
        rm -rf "$TMPD"
    ' 2>/dev/null | tr '\n' ' ')"
    assert_contains "lock blocks concurrent run" "second-blocked" "$locktest"

    # Stale lock takeover
    staletest="$(run_common '
        TMPD=$(mktemp -d)
        mkdir -p "$TMPD/.testlock"; echo 999999 > "$TMPD/.testlock/pid"
        acquire_lock testlock "$TMPD" && echo "took-over" || echo "refused"
        release_lock
        rm -rf "$TMPD"
    ' 2>/dev/null | tr '\n' ' ')"
    assert_contains "stale lock is taken over" "took-over" "$staletest"
fi

# ==========================================================================
section "5. install.sh — validation rejects bad input"
# ==========================================================================
if should_run "install"; then
    INSTALL="$REPO_DIR/install.sh"

    # Fake miner binary so the executable check passes
    FAKEBIN="$WORKDIR/fake-miner"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN"
    chmod 755 "$FAKEBIN"

    BASE_ENV="MINER_BIN=$FAKEBIN"

    run_install() {
        env $BASE_ENV "$@" "$INSTALL" --dry-run 2>&1
    }

    out="$(run_install PRL_ADDR= NOCK_ADDR=abc POOL_URL=stratum+tcp://x:1 || true)"
    assert_contains "rejects missing PRL_ADDR" "PRL_ADDR is required" "$out"

    out="$(run_install PRL_ADDR=prl1abc NOCK_ADDR= POOL_URL=stratum+tcp://x:1 || true)"
    assert_contains "rejects missing NOCK_ADDR" "NOCK_ADDR is required" "$out"

    out="$(run_install PRL_ADDR=prl1abc NOCK_ADDR=def POOL_URL= || true)"
    assert_contains "rejects missing POOL_URL" "POOL_URL is required" "$out"

    out="$(run_install PRL_ADDR=wrongprefix NOCK_ADDR=def POOL_URL=stratum+tcp://x:1 || true)"
    assert_contains "rejects bad PRL prefix" "does not start with 'prl1'" "$out"

    out="$(run_install PRL_ADDR=prl1abc NOCK_ADDR=def POOL_URL=http://x:1 || true)"
    assert_contains "rejects non-stratum URL" "should start with stratum" "$out"

    out="$(run_install PRL_ADDR=prl1abc NOCK_ADDR=def POOL_URL=stratum+tcp://x:1 API_PORT=abc || true)"
    assert_contains "rejects non-numeric API_PORT" "API_PORT must be" "$out"

    out="$(run_install PRL_ADDR=prl1abc NOCK_ADDR=def POOL_URL=stratum+tcp://x:1 POWER=9000 || true)"
    assert_contains "rejects out-of-range POWER" "outside the H100 SXM range" "$out"

    out="$(run_install PRL_ADDR=prl1abc NOCK_ADDR=def POOL_URL=stratum+tcp://x:1 TEMP_LIMIT=70 TEMP_RESUME=80 || true)"
    assert_contains "rejects resume >= limit" "must be below TEMP_LIMIT" "$out"

    out="$(run_install PRL_ADDR="prl1a b" NOCK_ADDR=def POOL_URL=stratum+tcp://x:1 || true)"
    assert_contains "rejects address with space" "contains a space" "$out"

    # Exit code must be 2 on validation failure
    rc=0
    env $BASE_ENV PRL_ADDR= NOCK_ADDR=d POOL_URL=stratum+tcp://x:1 "$INSTALL" --dry-run >/dev/null 2>&1 || rc=$?
    assert_eq "validation failure exits 2" "2" "$rc"

    # --help works and exits 0
    rc=0
    "$INSTALL" --help >/dev/null 2>&1 || rc=$?
    assert_eq "--help exits 0" "0" "$rc"

    # Unknown flag rejected
    rc=0
    "$INSTALL" --nonsense >/dev/null 2>&1 || rc=$?
    assert_eq "unknown flag exits 2" "2" "$rc"
fi

# ==========================================================================
section "6. install.sh --dry-run — renders valid run.sh"
# ==========================================================================
if should_run "render"; then
    FAKEBIN="$WORKDIR/fake-miner"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN"
    chmod 755 "$FAKEBIN"

    out="$(env MINER_BIN="$FAKEBIN" \
        PRL_ADDR=prl1testaddr NOCK_ADDR=4HeTestAddr \
        POOL_URL=stratum+tcp://primary.example:3333 \
        POOL_URL_2=stratum+tls://backup.example:443 \
        API_PORT=4068 INTENSITY=22 THREADS=2 POWER=400 CORE_CLOCK=1600 \
        "$REPO_DIR/install.sh" --dry-run 2>&1 || true)"

    assert_contains "dry-run prints run.sh" "--- generated run.sh" "$out"
    assert_contains "run.sh has algo" "--algo pearlhash" "$out"
    assert_contains "run.sh has worker string" "@nock=4HeTestAddr" "$out"
    assert_contains "run.sh has intensity" "--gpu-intensity 22" "$out"
    assert_contains "run.sh has threads" "--gpu-threads 2" "$out"
    assert_contains "run.sh has powerlimit" "--gpu-powerlimit 400" "$out"
    assert_contains "run.sh has core clock" "--gpu-core-clock 1600" "$out"
    assert_contains "run.sh has both pools" "backup.example" "$out"
    assert_not_contains "run.sh has no --worksize" "--worksize" "$out"
    assert_not_contains "run.sh has no bare --kernel" "--kernel " "$out"
    assert_contains "dry-run says nothing written" "Nothing was written" "$out"

    # The rendered run.sh must be syntactically valid bash
    printf '%s' "$out" | sed -n '/--- generated run.sh/,/^--- generated systemd/p' \
        | sed '1d;$d' > "$WORKDIR/rendered.sh"
    if bash -n "$WORKDIR/rendered.sh" 2>/dev/null; then
        pass "rendered run.sh parses"
    else
        fail "rendered run.sh parses" "$(bash -n "$WORKDIR/rendered.sh" 2>&1 | head -3)"
    fi

    # Units rendered without leftover placeholders
    assert_not_contains "no @INSTALL_DIR@ left" "@INSTALL_DIR@" "$out"
    assert_not_contains "no @CONF_DIR@ left" "@CONF_DIR@" "$out"
fi

# ==========================================================================
section "7. run.sh — real execution passes correct argv to the miner"
# ==========================================================================
if should_run "argv"; then
    RECORD="$WORKDIR/argv.txt"
    : > "$RECORD"

    FAKEBIN="$WORKDIR/rec-miner"
    cat > "$FAKEBIN" <<'FEOF'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_RECORD"
exit 0
FEOF
    chmod 755 "$FAKEBIN"

    out="$(env MINER_BIN="$FAKEBIN" FAKE_RECORD="$RECORD" \
        PRL_ADDR=prl1abc NOCK_ADDR=4HeDef \
        POOL_URL=stratum+tcp://p1:1111 POOL_URL_2=stratum+tcp://p2:2222 \
        INTENSITY=24 THREADS=1 POWER=450 CORE_CLOCK=1700 TEMP_LIMIT=78 TEMP_RESUME=68 \
        "$REPO_DIR/install.sh" --dry-run 2>&1 || true)"

    printf '%s' "$out" | sed -n '/--- generated run.sh/,/^--- generated systemd/p' \
        | sed '1d;$d' > "$WORKDIR/run-real.sh"

    FAKE_RECORD="$RECORD" bash "$WORKDIR/run-real.sh" >/dev/null 2>&1 || true

    recorded="$(tr '\n' ' ' < "$RECORD")"
    assert_contains "argv: algo pearlhash" "--algo pearlhash" "$recorded"
    assert_contains "argv: primary pool" "stratum+tcp://p1:1111" "$recorded"
    assert_contains "argv: failover pool" "stratum+tcp://p2:2222" "$recorded"
    assert_contains "argv: worker @nock=" "@nock=4HeDef" "$recorded"
    assert_contains "argv: intensity 24" "--gpu-intensity 24" "$recorded"
    assert_contains "argv: threads 1" "--gpu-threads 1" "$recorded"
    assert_contains "argv: power 450" "--gpu-powerlimit 450" "$recorded"
    assert_contains "argv: core 1700" "--gpu-core-clock 1700" "$recorded"
    assert_contains "argv: temp limit 78" "--gpu-temp-limit 78" "$recorded"
    assert_contains "argv: temp resume 68" "--gpu-temp-resume 68" "$recorded"
    assert_not_contains "argv: no worksize" "--worksize" "$recorded"
fi

# ==========================================================================
section "8. bench.sh — end-to-end against a live fake miner API"
# ==========================================================================
if should_run "bench"; then
    BENCH_PORT=4079

    # Sanity: port must be free
    if curl -sf -m 1 "http://127.0.0.1:${BENCH_PORT}/" >/dev/null 2>&1; then
        skip "bench end-to-end" "port ${BENCH_PORT} busy"
    else
        BENCH_OUT="$WORKDIR/bench.tsv"

        # Intensity grid 21..25 with a known peak at 23 and 2 threads better.
        # Expect winner: intensity=23 threads=2
        (
            cd "$WORKDIR" || exit 1
            MINER_BIN="$TESTS_DIR/fake_miner.py" \
            POOL_URL=stratum+tcp://fake:1 \
            USER_STR="prl1fake@nock=4HeFake" \
            API_PORT="$BENCH_PORT" \
            INTENSITIES="21 22 23 24 25" \
            THREADS="1 2" \
            SETTLE=2 MEASURE=4 SAMPLE_INTERVAL=1 \
            OUT="$BENCH_OUT" \
            FAKE_PEAK_INTENSITY=23 \
            bash "$REPO_DIR/bin/bench.sh"
        ) > "$WORKDIR/bench.log" 2>&1
        bench_rc=$?

        assert_eq "bench.sh exits 0" "0" "$bench_rc"

        if [[ -f "$BENCH_OUT" ]]; then
            rows="$(tail -n +2 "$BENCH_OUT" | wc -l | tr -d ' ')"
            assert_eq "bench produced 10 rows (5 intensities x 2 threads)" "10" "$rows"

            winner="$(tail -n +2 "$BENCH_OUT" | grep -v 'no-api' \
                | sort -t"$(printf '\t')" -k4 -gr | head -1)"
            win_int="$(printf '%s' "$winner" | cut -f1)"
            win_thr="$(printf '%s' "$winner" | cut -f2)"

            assert_eq "bench finds intensity peak at 23" "23" "$win_int"
            assert_eq "bench prefers 2 threads" "2" "$win_thr"

            assert_contains "bench reports best combo" "BEST BY HASHRATE" \
                "$(cat "$WORKDIR/bench.log")"
            assert_contains "bench suggests install command" "install.sh" \
                "$(cat "$WORKDIR/bench.log")"
        else
            fail "bench produced results file" "no $BENCH_OUT"
        fi

        # Cleanup any stray miner from the sweep
        pkill -f "fake_miner.py.*${BENCH_PORT}" 2>/dev/null || true
    fi

    # Guard: refuses to run on an occupied API port
    python3 "$TESTS_DIR/fake_miner.py" --api-port 4078 --gpu-intensity 22 >/dev/null 2>&1 &
    FAKE_PID=$!
    sleep 1
    out="$(MINER_BIN="$TESTS_DIR/fake_miner.py" POOL_URL=stratum+tcp://f:1 \
        USER_STR=x API_PORT=4078 OUT="$WORKDIR/b2.tsv" \
        bash "$REPO_DIR/bin/bench.sh" 2>&1 || true)"
    assert_contains "bench refuses occupied port" "already answering on port" "$out"
    kill -9 "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""

    # Guard: missing config
    out="$(MINER_BIN="$TESTS_DIR/fake_miner.py" POOL_URL= USER_STR=x \
        bash "$REPO_DIR/bin/bench.sh" 2>&1 || true)"
    assert_contains "bench requires POOL_URL" "POOL_URL is required" "$out"

    out="$(MINER_BIN="$TESTS_DIR/fake_miner.py" POOL_URL=stratum+tcp://f:1 USER_STR= \
        bash "$REPO_DIR/bin/bench.sh" 2>&1 || true)"
    assert_contains "bench requires USER_STR" "USER_STR is required" "$out"

    out="$(MINER_BIN=/nonexistent POOL_URL=stratum+tcp://f:1 USER_STR=x \
        bash "$REPO_DIR/bin/bench.sh" 2>&1 || true)"
    assert_contains "bench requires miner binary" "miner not executable" "$out"
fi

# ==========================================================================
section "9. bench.sh — survives a miner that never answers its API"
# ==========================================================================
if should_run "benchdead"; then
    DEAD_PORT=4077
    out="$(
        cd "$WORKDIR" || exit 1
        MINER_BIN="$TESTS_DIR/fake_miner.py" \
        POOL_URL=stratum+tcp://fake:1 USER_STR=x API_PORT="$DEAD_PORT" \
        INTENSITIES="22" THREADS="1" SETTLE=1 MEASURE=2 SAMPLE_INTERVAL=1 \
        OUT="$WORKDIR/dead.tsv" FAKE_DEAD=1 \
        bash "$REPO_DIR/bin/bench.sh" 2>&1
    )"
    rc=$?
    assert_eq "dead-miner sweep exits 1 (no valid combo)" "1" "$rc"
    assert_contains "dead miner reported as no-api" "NO API RESPONSE" "$out"
    assert_contains "dead miner explains what to check" "worker string accepted" "$out"
    pkill -f "fake_miner.py.*${DEAD_PORT}" 2>/dev/null || true
fi

# ==========================================================================
section "10. watchdog.sh — strike logic and restart behaviour"
# ==========================================================================
if should_run "watchdog"; then
    WDT="$WORKDIR/wd"
    mkdir -p "$WDT/bin" "$WDT/state"

    # Mock systemctl driven by a state file. A successful start/restart also
    # restores the fake API to a positive hashrate, simulating a real recovery.
    cat > "$WDT/bin/systemctl" <<'MEOF'
#!/usr/bin/env bash
S="$(cat "$WDT_STATE/active" 2>/dev/null || echo active)"
case "$1" in
  is-active) [[ "$S" == "active" ]] && { echo active; exit 0; } || { echo failed; exit 3; } ;;
  start|restart)
    printf '%s\n' "$1" >> "$WDT_STATE/actions"
    echo active > "$WDT_STATE/active"
    [[ -n "${WDT_RECOVER:-}" ]] && printf '%s' '{"hashrate":{"total":[1500]}}' > "$WDT_STATE/api.json"
    exit 0 ;;
  *) exit 0 ;;
esac
MEOF
    chmod 755 "$WDT/bin/systemctl"

    # Mock curl: serve the API payload for 127.0.0.1, swallow alert posts
    cat > "$WDT/bin/curl" <<'CEOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *127.0.0.1*) cat "$WDT_STATE/api.json" 2>/dev/null || echo '{}'; exit 0 ;;
  esac
done
exit 0
CEOF
    chmod 755 "$WDT/bin/curl"

    # Mock journalctl emitting reject lines
    cat > "$WDT/bin/journalctl" <<'JEOF'
#!/usr/bin/env bash
echo "share rejected: low difficulty"
echo "share rejected: stale"
JEOF
    chmod 755 "$WDT/bin/journalctl"

    wd_run() {
        env -i \
            PATH="$WDT/bin:/usr/bin:/bin:/usr/local/bin" \
            WDT_STATE="$WDT/state" \
            ${WDT_RECOVER:+WDT_RECOVER="$WDT_RECOVER"} \
            SERVICE=pearl-mining API_PORT=4068 \
            STATE_DIR="$WDT/state" ZERO_STRIKES=3 BOOT_GRACE=0 \
            bash "$REPO_DIR/bin/watchdog.sh"
    }

    set_api() { printf '%s' "$1" > "$WDT/state/api.json"; }
    set_active() { printf '%s' "$1" > "$WDT/state/active"; }
    reset_state() {
        rm -f "$WDT/state/actions" "$WDT/state/zero_strikes" "$WDT/state/watchdog.log"
        rm -rf "$WDT/state"/.watchdog.lock
    }

    # --- 10a: two zero strikes then recovery must NOT restart
    reset_state; set_active active
    set_api '{"hashrate":{"total":[0]}}'
    wd_run >/dev/null 2>&1; rc1=$?
    wd_run >/dev/null 2>&1; rc2=$?
    set_api '{"hashrate":{"total":[1234.5]}}'
    wd_run >/dev/null 2>&1; rc3=$?
    assert_eq "watchdog strike 1 exits 1" "1" "$rc1"
    assert_eq "watchdog strike 2 exits 1" "1" "$rc2"
    assert_eq "watchdog recovery exits 0" "0" "$rc3"
    assert_eq "watchdog resets strikes on recovery" "0" \
        "$(cat "$WDT/state/zero_strikes" 2>/dev/null | tr -d '[:space:]')"
    if [[ -f "$WDT/state/actions" ]]; then
        fail "no restart before threshold" "actions: $(cat "$WDT/state/actions")"
    else
        pass "no restart before threshold"
    fi

    # --- 10b: three zero strikes must restart exactly once, then recover
    reset_state; set_active active
    set_api '{"hashrate":{"total":[0]}}'
    WDT_RECOVER=1
    wd_run >/dev/null 2>&1
    wd_run >/dev/null 2>&1
    wd_run >/dev/null 2>&1; rc3=$?
    assert_eq "watchdog restart exits 2 when hashrate recovers" "2" "$rc3"
    assert_contains "watchdog restarted the service" "restart" \
        "$(cat "$WDT/state/actions" 2>/dev/null)"
    assert_eq "watchdog restart count is exactly 1" "1" \
        "$(grep -c restart "$WDT/state/actions" 2>/dev/null || echo 0)"
    WDT_RECOVER=""

    # --- 10b2: restart happens but hashrate stays 0 -> exit 3 (needs a human)
    reset_state; set_active active
    set_api '{"hashrate":{"total":[0]}}'
    WDT_RECOVER=""
    wd_run >/dev/null 2>&1
    wd_run >/dev/null 2>&1
    wd_run >/dev/null 2>&1; rc=$?
    assert_eq "watchdog restart without recovery exits 3" "3" "$rc"
    assert_eq "watchdog still restarted once" "1" \
        "$(grep -c restart "$WDT/state/actions" 2>/dev/null || echo 0)"

    # --- 10c: REJECTS parsing must not corrupt the integer compare
    # (regression: `grep -c || echo 0` produced "0\n0" -> [[: syntax error)
    reset_state; set_active active
    set_api '{"hashrate":{"total":[0]}}'
    out="$(wd_run 2>&1)"
    assert_not_contains "no bash integer syntax error" "syntax error" "$out"
    assert_not_contains "no unbound variable error" "unbound variable" "$out"
    assert_contains "reject count parsed" "reject/disconnect line" "$out"

    # --- 10d: service down -> start, exit 2
    reset_state; set_active failed
    set_api '{"hashrate":{"total":[900]}}'
    wd_run >/dev/null 2>&1; rc=$?
    assert_eq "watchdog starts a down service, exits 2" "2" "$rc"
    assert_contains "watchdog issued start" "start" "$(cat "$WDT/state/actions" 2>/dev/null)"

    # --- 10e: service down and start fails -> exit 3
    reset_state; set_active failed
    cat > "$WDT/bin/systemctl" <<'MEOF'
#!/usr/bin/env bash
case "$1" in
  is-active) exit 3 ;;
  start) printf 'start\n' >> "$WDT_STATE/actions"; exit 1 ;;
  restart) printf 'restart\n' >> "$WDT_STATE/actions"; exit 1 ;;
  *) exit 0 ;;
esac
MEOF
    chmod 755 "$WDT/bin/systemctl"
    wd_run >/dev/null 2>&1; rc=$?
    assert_eq "watchdog unrecoverable exits 3" "3" "$rc"

    # restore working mock for later tests
    cat > "$WDT/bin/systemctl" <<'MEOF'
#!/usr/bin/env bash
S="$(cat "$WDT_STATE/active" 2>/dev/null || echo active)"
case "$1" in
  is-active) [[ "$S" == "active" ]] && { echo active; exit 0; } || { echo failed; exit 3; } ;;
  start|restart) printf '%s\n' "$1" >> "$WDT_STATE/actions"; echo active > "$WDT_STATE/active"; exit 0 ;;
  *) exit 0 ;;
esac
MEOF
    chmod 755 "$WDT/bin/systemctl"

    # --- 10f: concurrent runs must not double-count (lock)
    reset_state; set_active active
    set_api '{"hashrate":{"total":[0]}}'
    wd_run >/dev/null 2>&1 &
    wd_run >/dev/null 2>&1 &
    wait
    strikes="$(cat "$WDT/state/zero_strikes" 2>/dev/null | tr -d '[:space:]')"
    assert_eq "concurrent runs count one strike, not two" "1" "$strikes"

    # --- 10g: bad ZERO_STRIKES rejected
    reset_state; set_active active
    out="$(env -i PATH="$WDT/bin:/usr/bin:/bin" WDT_STATE="$WDT/state" \
        SERVICE=pearl-mining STATE_DIR="$WDT/state" ZERO_STRIKES=abc \
        bash "$REPO_DIR/bin/watchdog.sh" 2>&1 || true)"
    assert_contains "watchdog rejects non-numeric ZERO_STRIKES" "ZERO_STRIKES must be" "$out"
fi

# ==========================================================================
section "11. tune.sh — argument handling without touching a GPU"
# ==========================================================================
if should_run "tune"; then
    out="$(bash "$REPO_DIR/bin/tune.sh" --help 2>&1 || true)"
    assert_contains "tune --help shows usage" "power" "$out"

    out="$(bash "$REPO_DIR/bin/tune.sh" --bogus 2>&1 || true)"
    assert_contains "tune rejects unknown flag" "unknown argument" "$out"

    # Without root it must refuse, not silently no-op
    if [[ "$(id -u)" -ne 0 ]]; then
        out="$(bash "$REPO_DIR/bin/tune.sh" 2>&1 || true)"
        assert_contains "tune requires root" "requires root" "$out"
    else
        skip "tune requires root" "running as root"
    fi
fi

# ==========================================================================
section "11b. install.sh — REAL install into a sandbox (no root needed)"
# ==========================================================================
if should_run "realinstall"; then
    SB="$WORKDIR/sandbox"
    mkdir -p "$SB"
    FAKEBIN="$WORKDIR/fake-miner"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN"
    chmod 755 "$FAKEBIN"

    sb_env() {
        env MINER_BIN="$FAKEBIN" \
            PRL_ADDR=prl1sandbox NOCK_ADDR=4HeSandbox \
            POOL_URL=stratum+tcp://primary.example:3333 \
            POOL_URL_2=stratum+tls://backup.example:443 \
            INSTALL_DIR="$SB/opt" CONF_DIR="$SB/etc" STATE_DIR="$SB/state" \
            SYSTEMD_DIR="$SB/units" \
            INTENSITY=23 THREADS=2 POWER=420 CORE_CLOCK=1650 \
            TG_TOKEN=tok123 TG_CHAT=chat456 ZERO_STRIKES=4 \
            "$REPO_DIR/install.sh" "$@"
    }

    out="$(sb_env 2>&1)"; rc=$?
    assert_eq "sandboxed install exits 0" "0" "$rc"

    for f in run.sh tune.sh watchdog.sh watchdog-monitor.sh bench.sh; do
        [[ -x "$SB/opt/$f" ]] && pass "installed executable: $f" \
            || fail "installed executable: $f" "missing $SB/opt/$f"
    done

    [[ -f "$SB/opt/lib/common.sh" ]] && pass "lib/common.sh installed" || fail "lib/common.sh installed"
    [[ -f "$SB/opt/lib/parse_api.py" ]] && pass "lib/parse_api.py installed" || fail "lib/parse_api.py installed"

    for u in pearl-tune.service pearl-mining.service pearl-watchdog.service pearl-watchdog.timer; do
        [[ -f "$SB/units/$u" ]] && pass "unit written: $u" || fail "unit written: $u"
    done

    # Placeholders must be fully substituted
    units_content="$(cat "$SB/units"/* 2>/dev/null)"
    assert_not_contains "no @INSTALL_DIR@ in units" "@INSTALL_DIR@" "$units_content"
    assert_not_contains "no @CONF_DIR@ in units" "@CONF_DIR@" "$units_content"
    assert_contains "unit points at sandbox install dir" "$SB/opt/run.sh" "$units_content"

    # Rendered run.sh must carry the configured values
    runsh="$(cat "$SB/opt/run.sh")"
    assert_contains "run.sh uses INTENSITY=23" "--gpu-intensity 23" "$runsh"
    assert_contains "run.sh uses POWER=420" "--gpu-powerlimit 420" "$runsh"
    assert_contains "run.sh has failover pool" "backup.example" "$runsh"

    # Secrets must be in a 0600 env file, never inline in the unit
    envfile="$SB/etc/watchdog.env"
    if [[ -f "$envfile" ]]; then
        pass "watchdog.env created"
        mode="$(ls -l "$envfile" | cut -c1-10)"
        assert_eq "watchdog.env is 0600" "-rw-------" "$mode"
        assert_contains "env file carries ZERO_STRIKES" "ZERO_STRIKES=4" "$(cat "$envfile")"
    else
        fail "watchdog.env created"
    fi
    assert_not_contains "TG token NOT inline in unit" "tok123" "$units_content"

    # Re-running without --force must refuse
    out="$(sb_env 2>&1)"; rc=$?
    assert_eq "reinstall without --force exits 2" "2" "$rc"
    assert_contains "reinstall refusal is explained" "--force" "$out"

    # Re-running with --force must back up the previous install
    out="$(sb_env --force 2>&1)"; rc=$?
    assert_eq "reinstall with --force exits 0" "0" "$rc"
    backups="$(find "$SB" -maxdepth 1 -name 'opt.bak.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "previous install backed up" "1" "$backups"
fi

# ==========================================================================
section "12. docs — README claims match the code"
# ==========================================================================
if should_run "docs"; then
    README="$REPO_DIR/README.md"
    if [[ -f "$README" ]]; then
        pass "README exists"
        content="$(cat "$README")"
        assert_contains "README documents install.sh" "install.sh" "$content"
        assert_contains "README documents bench.sh" "bench.sh" "$content"
        assert_contains "README documents watchdog" "watchdog" "$content"
        assert_contains "README warns about --worksize" "worksize" "$content"
        assert_contains "README warns about HBM3 fixed clock" "2619" "$content"
    else
        fail "README exists"
    fi

    # LICENSE present
    [[ -f "$REPO_DIR/LICENSE" ]] && pass "LICENSE exists" || fail "LICENSE exists"
fi

# ==========================================================================
# Summary
# ==========================================================================
printf '\n%s════════════════════════════════════════%s\n' "$C_DIM" "$C_OFF"
printf 'PASS: %s   FAIL: %s   SKIP: %s\n' "$PASS" "$FAIL" "$SKIP"

if [[ "$FAIL" -gt 0 ]]; then
    printf '\n%sFailed tests:%s\n' "$C_RED" "$C_OFF"
    printf '%s' "$FAILED_NAMES" | sed 's/^/  - /'
    exit 1
fi

printf '%sAll tests passed.%s\n' "$C_GRN" "$C_OFF"
exit 0
