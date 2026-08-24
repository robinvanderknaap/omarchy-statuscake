"""A stand-in for the StatusCake uptime API, used by helper-test.sh.

Serves /v1/uptime on 127.0.0.1:8933 and records every request it receives so the
test can assert on pagination, query parameters, and the Authorization header.

Usage: python3 mock-api.py [ok|401|403|429|500|garbage|huge|huge-nolength]
Prints "ready" once listening; writes seen.json and exits when stdin closes.
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
PORT = 8933
PAGES = 3
PER_PAGE = 100
LAST_PAGE_COUNT = 7

# Comfortably past the helper's 4 MB per-page cap. "huge" declares the length
# up front, which is the case curl refuses before reading a byte of body;
# "huge-nolength" streams it chunked, so the cap has to hold while the transfer
# is already running.
HUGE_BYTES = 6 * 1024 * 1024

seen = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep the test output clean

    def do_GET(self):
        parsed = urlparse(self.path)
        seen.append({
            "path": parsed.path,
            "query": parse_qs(parsed.query),
            "auth": self.headers.get("Authorization"),
        })

        if MODE in ("401", "403", "429", "500"):
            self.send_response(int(MODE))
            self.end_headers()
            self.wfile.write(b'{"errors":["denied"]}')
            return

        if MODE == "garbage":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"<html>not json at all</html>")
            return

        if MODE in ("huge", "huge-nolength"):
            self.serve_huge(declare_length=MODE == "huge")
            return

        page = int(parsed.query and parse_qs(parsed.query).get("page", ["1"])[0] or 1)

        # Two full pages then a short one: a wrong merge or an off-by-one in the
        # page loop shows up as a wrong total rather than passing silently.
        count = PER_PAGE if page < PAGES else LAST_PAGE_COUNT
        data = [
            {
                "id": f"p{page}-{i}",
                "name": f"check {page}-{i}",
                "website_url": f"https://example{page}-{i}.test",
                "test_type": "HTTP",
                "status": "down" if (page == 1 and i < 2) else "up",
                "paused": page == 2 and i == 0,
                "uptime": 99.9,
                # Varied on purpose: bin/statuscake-tags has to merge the
                # distinct tags across every page, not just report page one's.
                "tags": ["prod"] + (["web"] if i == 1 else []) + ([f"page{page}"] if i == 0 else []),
            }
            for i in range(count)
        ]
        body = json.dumps({
            "data": data,
            "metadata": {
                "page": page,
                "per_page": PER_PAGE,
                "page_count": PAGES,
                "total_count": PER_PAGE * (PAGES - 1) + LAST_PAGE_COUNT,
            },
        }).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_huge(self, declare_length):
        """Valid JSON, one enormous string field, sent a megabyte at a time."""
        head = b'{"data":[],"metadata":{"page_count":1},"pad":"'
        tail = b'"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        if declare_length:
            self.send_header("Content-Length", str(len(head) + HUGE_BYTES + len(tail)))
        self.end_headers()
        # The client is expected to hang up partway through, which arrives here
        # as a broken pipe rather than as a test failure.
        try:
            self.wfile.write(head)
            chunk = b"x" * (1024 * 1024)
            sent = 0
            while sent < HUGE_BYTES:
                self.wfile.write(chunk[:min(len(chunk), HUGE_BYTES - sent)])
                sent += len(chunk)
            self.wfile.write(tail)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = HTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
print("ready", flush=True)
sys.stdin.readline()
with open("seen.json", "w") as f:
    json.dump(seen, f, indent=2)
