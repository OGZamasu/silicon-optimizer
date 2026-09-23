"""Tiny loopback HTTPS fixture for the artifact transport tests. No external network."""

import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/audio")
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", "1000000")
            self.end_headers()
            self.wfile.write(b"redirect body must not reach disk")
            return
        if self.path == "/to-private":
            self.send_response(302)
            self.send_header("Location", "https://127.0.0.1/private")
            self.end_headers()
            return
        if self.path == "/loop":
            self.send_response(302)
            self.send_header("Location", "/loop")
            self.end_headers()
            return
        if self.path == "/bad-type":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"oops")
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg ; charset=binary")
        self.send_header("Content-Length", "5")
        self.end_headers()
        self.wfile.write(b"audio")

    def log_message(self, format, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
print(f"{server.server_port:05d}", flush=True)
server.serve_forever()
