#!/usr/bin/env python3
"""Local stand-in for an OpenAI-compatible chat completions endpoint.

Used by scripts/check-enhancement-single-attempt.sh. The last path segment picks the answer:
429* rate limit, 500* server error, slow* a 2 s delay, anything else a normal completion.
GET …/stats returns how often each path was requested, plus the last body and headers.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
counts: dict = {}
bodies: dict = {}
headers: dict = {}

COMPLETION = {"choices": [{"message": {"role": "assistant", "content": "Hallo Welt."}}]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rsplit("/", 1)[-1] != "stats":
            self.send_json(404, {})
            return
        with lock:
            self.send_json(200, {"counts": counts, "bodies": bodies, "headers": headers})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        name = self.path.rsplit("/", 1)[-1]
        with lock:
            counts[name] = counts.get(name, 0) + 1
            bodies[name] = json.loads(body or b"null")
            headers[name] = {key: self.headers.get(key) for key in ("Authorization", "Content-Type")}

        if name.startswith("429"):
            self.send_json(429, {"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}})
        elif name.startswith("500"):
            self.send_json(500, {"error": {"message": "Internal server error"}})
        elif name.startswith("slow"):
            time.sleep(2)
            self.send_json(200, COMPLETION)
        elif name.startswith("truncated"):
            self.send_json(200, {"choices": [{"message": {"content": "Unvollständiger Text"}, "finish_reason": "length"}]})
        elif name.startswith("empty"):
            self.send_json(200, {"choices": []})
        else:
            self.send_json(200, COMPLETION)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
