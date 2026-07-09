#!/usr/bin/env python3
"""S0 spike: minimal HTTP logger standing in for pass's HookServer.

Logs every request (method, path, headers, body, timestamp) to stdout AND to
a JSONL file, then returns 200 immediately. Used to observe exactly what
Claude Code / Codex hooks actually POST.

Usage: python3 hook_logger.py [port] [logfile]
"""
import sys, json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 49817
LOGFILE = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pass_hook_log.jsonl"


class Handler(BaseHTTPRequestHandler):
    def _log(self, method):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        rec = {
            "t": round(time.time(), 3),
            "method": method,
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
            "body_raw": body,
        }
        try:
            rec["body_json"] = json.loads(body) if body else None
        except Exception:
            rec["body_json"] = None
        with open(LOGFILE, "a") as f:
            f.write(json.dumps(rec) + "\n")
        # concise console line
        ev = (rec.get("body_json") or {}).get("hook_event_name", "?")
        nt = (rec.get("body_json") or {}).get("notification_type", "")
        sess = self.headers.get("X-Pass-Session", "-")
        print(f"[{rec['t']}] {method} {self.path}  event={ev} {nt}  X-Pass-Session={sess}", flush=True)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        self._log("POST")

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self._log("GET")

    def log_message(self, *a):
        pass  # silence default noisy logging


if __name__ == "__main__":
    open(LOGFILE, "w").close()  # truncate
    print(f"pass hook logger on 127.0.0.1:{PORT} -> {LOGFILE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
