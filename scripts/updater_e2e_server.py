#!/usr/bin/env python3
"""Local stand-in for GitHub + ntfy in scripts/updater_e2e.sh (SE-015).

Serves the files of <dir> (appcast.xml, Valse.zip, deltas) and an ntfy-like stream at /push/json: an "open" event,
a keepalive every 2 s, and a "message" event each time <dir>/.push is created (the file is then removed).
Usage: updater_e2e_server.py <port> <dir>
"""
import http.server
import json
import os
import sys
import time

PORT, ROOT = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def do_GET(self):
        if self.path.split("?")[0] != "/push/json":
            return super().do_GET()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()
        self.log_message("push stream opened")
        trigger = os.path.join(ROOT, ".push")
        try:
            self.wfile.write((json.dumps({"event": "open"}) + "\n").encode()); self.wfile.flush()
            last = time.time()
            while True:
                if os.path.exists(trigger):
                    os.remove(trigger)
                    self.wfile.write((json.dumps({"event": "message", "message": "release"}) + "\n").encode())
                    self.wfile.flush()
                    self.log_message("push message sent")
                if time.time() - last > 2:
                    self.wfile.write((json.dumps({"event": "keepalive"}) + "\n").encode()); self.wfile.flush()
                    last = time.time()
                time.sleep(0.2)
        except (BrokenPipeError, ConnectionResetError):
            pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
