#!/usr/bin/env python3
"""Deterministic loopback HTTP fixture for the DJS networking gate."""
import http.server
import socketserver
import sys
import threading

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/json":
            body = b'{"ok":true,"n":7}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/trunc":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            # A body that cannot satisfy its declared length must terminate
            # the connection; keeping it alive would leave the peer waiting
            # for bytes that will never arrive.
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"short")
            self.close_connection = True
        elif self.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"one", b"two", b"three"):
                self.wfile.write(("%x\r\n" % len(part)).encode() + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            body = b"hello-djs\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Test", "yes")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
srv.daemon_threads = True
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
    f.flush()
threading.Thread(target=srv.serve_forever, daemon=True).start()
try:
    threading.Event().wait()
except KeyboardInterrupt:
    srv.shutdown()
