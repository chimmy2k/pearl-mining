#!/usr/bin/env python3
"""Parse wildrig-multi's HTTP API into a stable two-field line: "<total> <peak>".

Single source of truth — every script shells out to this instead of embedding
its own copy of the parser. Shape drift between copies was a real bug source.

wildrig reports hashrate in several shapes depending on version and algo:
    {"hashrate": {"total": [1234.5, 1300.0], "highest": 1300.0}}   <- usual
    {"hashrate": {"total": 999.9}}                                 <- scalar
    {"hashrate": 555.5}                                            <- bare
    {"gpus": [{"hashrate": 100}, ...]}                             <- no total
    {} / non-JSON / no response                                    <- dead miner

Output contract (never raises, never exits nonzero on bad input):
    <total:.2f> <peak:.2f>
"""

import json
import sys


def num(value):
    """Coerce a wildrig hashrate field into a float. Unknown shapes -> 0.0."""
    if isinstance(value, bool):  # bool is an int subclass; never a hashrate
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return 0.0
    if isinstance(value, list) and value:
        # wildrig sends [current, highest, ...]; first element is current
        return num(value[0])
    if isinstance(value, dict):
        for key in ("total", "current", "hashrate", "total_hashrate"):
            if key in value:
                return num(value[key])
    return 0.0


def extract(payload):
    """Return (total, peak) hashrate from a decoded API payload."""
    if not isinstance(payload, dict):
        return 0.0, 0.0

    hr = payload.get("hashrate", payload)
    if isinstance(hr, dict):
        total = num(hr.get("total", 0))
        peak = num(hr.get("highest", hr.get("highest_hashrate", 0)))
    else:
        total = num(hr)
        peak = 0.0

    gpus = payload.get("gpus")
    if isinstance(gpus, list) and gpus:
        if total <= 0:
            total = sum(num(g.get("hashrate", 0)) for g in gpus if isinstance(g, dict))
        if peak <= 0:
            peak = sum(
                num(g.get("highest", g.get("hashrate", 0)))
                for g in gpus
                if isinstance(g, dict)
            )

    return total, peak


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        print("0.00 0.00")
        return 0
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        print("0.00 0.00")
        return 0
    total, peak = extract(payload)
    print(f"{total:.2f} {peak:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
