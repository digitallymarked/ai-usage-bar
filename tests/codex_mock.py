#!/usr/bin/env python3
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.headers.get("Authorization") == "Bearer test-token" and \
             self.headers.get("chatgpt-account-id") == "acct-123"
        now = int(time.time())
        body = {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": True, "limit_reached": False,
                "primary_window": {"used_percent": 72, "limit_window_seconds": 18000,
                                   "reset_after_seconds": 5400, "reset_at": now + 5400},
                "secondary_window": {"used_percent": 41, "limit_window_seconds": 604800,
                                     "reset_after_seconds": 200000, "reset_at": now + 200000},
            },
        }
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body if ok else {"error": "unauthorized"}).encode())

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 8765), H).serve_forever()
