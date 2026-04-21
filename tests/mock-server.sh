#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mock scanner server backed by fixture files. Run in the background from
# tests/test.sh. Reads the POST body's `url` field and returns a fixture
# based on its path prefix:
#
#   url ending with  ...#level=N    -> tests/fixtures/level-N.json
#   url ending with  ...#malformed  -> tests/fixtures/malformed.json
#   url ending with  ...#scanner-500 -> HTTP 500 with body from
#                                       tests/fixtures/scanner-500.txt
#
# Anything else returns a 400. Fragment selectors are used because they are
# never sent to real servers (so the mock reads them but a real browser /
# scanner would never leak them).

set -euo pipefail

PORT="${1:-8765}"
FIXTURE_DIR="${2:-$(dirname "$0")/fixtures}"

exec python3 - "$PORT" "$FIXTURE_DIR" <<'PY'
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
fixture_dir = sys.argv[2]


def load(name: str) -> bytes:
    with open(os.path.join(fixture_dir, name), "rb") as f:
        return f.read()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_error(400, "bad json")
            return

        url = body.get("url", "")
        fragment = url.split("#", 1)[1] if "#" in url else ""

        if fragment == "malformed":
            payload = load("malformed.json")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if fragment == "scanner-500":
            payload = load("scanner-500.txt")
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if fragment.startswith("level="):
            level = fragment.split("=", 1)[1]
            try:
                payload = load(f"level-{level}.json")
            except FileNotFoundError:
                self.send_error(404, f"no fixture for level {level}")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_error(400, "unknown fragment selector")

    def log_message(self, format, *args):  # noqa: A002
        # Silence default stderr logging — tests supply their own.
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
