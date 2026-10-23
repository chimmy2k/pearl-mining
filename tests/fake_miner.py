#!/usr/bin/env python3
"""Fake wildrig-multi for testing. Mimics the real CLI and HTTP API.

Serves a hashrate that peaks at a known intensity so bench.sh can be verified
end-to-end: it must find that peak and rank it first.

Usage (called by the miner under test, same flags):
    fake_miner.py --algo pearlhash --url ... --user ... --pass x \
                  --api-port 4069 --gpu-intensity 22 --gpu-threads 2

Behaviour knobs (env):
    FAKE_PEAK_INTENSITY   intensity that yields the highest hashrate (default 23)
    FAKE_DEAD             "1" -> start but never serve the API (crash simulation)
    FAKE_RECORD           path to append the received argv, one arg per line
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULTS = {
    "--algo": "pearlhash",
    "--api-port": "4069",
    "--gpu-intensity": "22",
    "--gpu-threads": "2",
}


def parse_args(argv):
    """Accept both '--flag value' and '--flag=value'. Unknown flags ignored."""
    out = dict(DEFAULTS)
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg.startswith("--"):
            if "=" in arg:
                key, val = arg.split("=", 1)
                out[key] = val
            elif i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                out[arg] = argv[i + 1]
                i += 1
            else:
                out[arg] = "true"
        i += 1
    return out


def hashrate_for(intensity, threads, peak_intensity):
    """Triangular curve peaking at peak_intensity. Deterministic, no randomness,
    so the expected winner is computable in the test."""
    try:
        i = float(intensity)
        t = float(threads)
        p = float(peak_intensity)
    except (TypeError, ValueError):
        return 0.0
    if p <= 0:
        return 0.0
    distance = abs(i - p)
    base = 1000.0 - (distance * 120.0)
    if base < 0:
        base = 0.0
    # 2 threads is 8% better than 1, as on real SXM cards
    return base * (1.08 if t >= 2 else 1.0)


class Handler(BaseHTTPRequestHandler):
    intensity = "22"
    threads = "2"
    peak_intensity = "23"

    def do_GET(self):  # noqa: N802 - http.server API
        hr = hashrate_for(self.intensity, self.threads, self.peak_intensity)
        payload = {
            "hashrate": {"total": [hr, hr], "highest": hr},
            "gpus": [
                {
                    "bus_id": 1,
                    "hashrate": hr,
                    "temperature": 62,
                    "fan_speed": 55,
                    "accepted": 10,
                    "rejected": 0,
                }
            ],
            "algorithm": "pearlhash",
        }
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        """Silence request logging — tests read stdout, keep it clean."""
        return


def main():
    args = parse_args(sys.argv[1:])

    record = os.environ.get("FAKE_RECORD")
    if record:
        with open(record, "a", encoding="utf-8") as fh:
            for a in sys.argv[1:]:
                fh.write(a + "\n")

    if os.environ.get("FAKE_DEAD") == "1":
        # Simulate a miner that starts but never answers its API.
        threading.Event().wait()
        return 0

    Handler.intensity = args["--gpu-intensity"]
    Handler.threads = args["--gpu-threads"]
    Handler.peak_intensity = os.environ.get("FAKE_PEAK_INTENSITY", "23")

    port = int(args["--api-port"])
    server = HTTPServer(("127.0.0.1", port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
