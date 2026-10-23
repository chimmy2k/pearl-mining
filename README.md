# pearl-mining

Production mining stack for **PearlHash** on `wildrig-multi` — supervised
miner, pool failover, boot-persistent GPU tuning, and a watchdog that catches
the one failure systemd cannot see.

Built for H100 SXM (HBM3) but the tuning layer is optional, so it runs on any
NVIDIA box.

> **Own hardware only.** There is deliberately no evasion layer here. On a
> machine you own there is nothing to hide, and hiding only blinds you to your
> own telemetry — `--no-nvml` silences *your* monitoring while the host, the
> PDU, and the network still see everything. If you are renting the GPU, mining
> against the provider's terms is a contract breach and this repo will not help
> you do it quietly.

---

## What it actually solves

Four ways a rig silently earns nothing, and what covers each:

| Failure | Who catches it |
|:--|:--|
| Miner process dies | systemd `Restart=always` |
| Process alive, hashrate 0 | `watchdog.sh` — **systemd is blind to this** |
| Pool connection drops | 3-pool failover, `--retries 2` |
| Reboot resets GPU clocks | `pearl-tune.service` runs before the miner |

The second one is the expensive one. A wedged driver or a stale stratum socket
leaves the process running at exit code 0, so systemd reports "active" while the
card earns nothing for hours.

---

## Install

```bash
git clone <this-repo> pearl-mining && cd pearl-mining

export PRL_ADDR=prl1...            # your Pearl address
export NOCK_ADDR=4He...            # the value after @nock=
export POOL_URL=stratum+tcp://pool:port
export POOL_URL_2=stratum+tls://backup:port   # optional failover

sudo -E ./install.sh
```

Preview without touching the machine (works on a laptop with no GPU):

```bash
./install.sh --dry-run
```

Then:

```bash
sudo systemctl start pearl-mining
sudo /opt/pearl-mining/watchdog-monitor.sh     # confirm it is hashing
sudo systemctl start pearl-watchdog.timer
```

---

## Order of operations

Do not skip step 2. Generic tuning numbers are guesses about your silicon.

1. **Install** — `install.sh` renders `run.sh`, installs units, enables them.
2. **Benchmark** — `bench.sh` sweeps intensity × threads against the live pool
   and ranks by measured H/s. This is the only number that matters.
3. **Tune power** — `tune.sh`, then re-measure. Compare H/s ÷ watts.
4. **Wire alerts** — set `TG_TOKEN` / `TG_CHAT`, reinstall.

```bash
sudo /opt/pearl-mining/bench.sh
# then apply the winner
INTENSITY=23 THREADS=2 sudo -E ./install.sh --force
```

---

## Layout

```
install.sh              installer + validator (--dry-run supported)
bin/
  bench.sh              intensity × threads × power sweep, ranked results
  watchdog.sh           zero-hashrate detection, restart, alerting
  watch.sh              live readout for humans
  tune.sh               power/clock, boot-persistent, --reset to stock
lib/
  common.sh             shared helpers (API read, locking, validation)
  parse_api.py          single API parser — one source of truth
systemd/                unit templates (@PLACEHOLDER@ substituted on install)
tests/
  run-tests.sh          full suite, no GPU or root required
  fake_miner.py         serves a real HTTP API so bench is tested end-to-end
```

The API parser lives in exactly one file. It used to be copied into three
scripts, which is how monitoring drifts and starts reporting phantom hashrate.

---

## Flags that do not exist

`wildrig-multi` (per its README) defines:

| Flag | Status |
|:--|:--|
| `-i, --gpu-intensity N` | ✅ |
| `--gpu-threads N` | ✅ |
| `--gpu-powerlimit N` | ✅ |
| `--gpu-core-clock N` | ✅ |
| `--gpu-memory-clock N` | ✅ |
| `--gpu-temp-limit N` / `--gpu-temp-resume N` | ✅ |
| `--worksize N` | ❌ does not exist |
| `--kernel NAME` | ❌ does not exist |

`--worksize` and `--kernel` are ccminer/SGminer flags. Passing them to wildrig
is not tuning — they are ignored or cause a startup error.

---

## H100 tuning reality check

- **HBM3 memory clock is fixed at 2619 MHz.** `nvidia-smi -lmc 2619` pins the
  only value the card accepts. It is *not* an overclock and produces no gain.
- **Power limit range is 200–700 W** (SXM default 700 W).
- **Core clock:** base 1590 MHz, boost ~1980 MHz. Locking to 1600 stops the
  boost controller from pulling power budget away from the memory subsystem on
  a bandwidth-bound algorithm.
- **The "-35 % power, -10 % hashrate, +40 % efficiency" pattern is a
  hypothesis, not a measurement.** It is plausible for a bandwidth-bound algo,
  but verify on your card: if hashrate drops >15 % at 400 W, step up to
  450–500 W; if it drops <5 %, try 350 W.

`tune.sh --reset` restores stock (700 W, unlocked clocks).

---

## Watchdog

| Exit | Meaning |
|:--|:--|
| 0 | healthy |
| 1 | degraded — one strike recorded |
| 2 | restarted (or started) the miner |
| 3 | unrecoverable — alerted, needs a human |

It requires **3 consecutive** zero-hashrate checks before restarting, so a slow
API read or a brief reconnect does not trigger a restart loop. On recovery the
strike counter resets. When it does restart it appends the last 40 journal lines
to `/var/lib/pearl-mining/watchdog.log` so you can see *why*.

A portable lock (mkdir-based, works where `flock` is absent) prevents overlapping
timer runs from double-counting strikes.

Alerts are optional. Without `TG_TOKEN`/`TG_CHAT` everything still works and
logs to the journal.

---

## Tests

```bash
./tests/run-tests.sh              # everything
./tests/run-tests.sh bench        # one group
```

No GPU, no root, no miner binary required. `fake_miner.py` serves a real HTTP
API with a deterministic hashrate curve, so `bench.sh` is driven end-to-end and
the suite asserts it finds the known peak. Watchdog behaviour is exercised
against mock `systemctl`/`curl`/`journalctl`.

Covered: shellcheck, syntax, 16 API payload shapes, lock contention and stale
lock takeover, install validation (10 rejection cases), rendered `run.sh` argv,
bench peak-finding, dead-miner handling, all watchdog exit paths, concurrency.

---

## Configuration reference

Every value is an environment variable; run `./install.sh --help`.

| Variable | Default | Notes |
|:--|:--|:--|
| `PRL_ADDR` | — | required, must start with `prl1` |
| `NOCK_ADDR` | — | required, the `@nock=` value |
| `POOL_URL` | — | required, `stratum+tcp://` or `stratum+tls://` |
| `POOL_URL_2/3` | — | optional failover, tried in order |
| `MINER_BIN` | `/opt/wildrig/wildrig-multi` | must be executable |
| `API_PORT` | `4068` | 1024–65535 |
| `INTENSITY` | `22` | `--gpu-intensity` |
| `THREADS` | `2` | `--gpu-threads` |
| `POWER` | `400` | 100–700 W validated |
| `CORE_CLOCK` | `1600` | MHz |
| `TEMP_LIMIT` / `TEMP_RESUME` | `80` / `70` | resume must be < limit |
| `ZERO_STRIKES` | `3` | checks before restart |
| `TG_TOKEN` / `TG_CHAT` | — | optional alerts |

---

## Uninstall

```bash
sudo systemctl disable --now pearl-mining pearl-watchdog.timer pearl-tune.service
sudo rm /etc/systemd/system/pearl-{mining,tune,watchdog}.service \
          /etc/systemd/system/pearl-watchdog.timer
sudo rm -rf /opt/pearl-mining /etc/pearl-mining /var/lib/pearl-mining
sudo systemctl daemon-reload
sudo nvidia-smi -rgc && sudo nvidia-smi -rmc && sudo nvidia-smi -pl 700
```

## License

MIT — see [LICENSE](LICENSE).
