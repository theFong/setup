#!/usr/bin/env python3
"""Loopback HTTP server that rejects every request with 401.

Used by test.sh to prove pi/install.sh's assert_pi_endpoint reports a key the
endpoint refuses, without needing network access or a real credential. Binds
port 0 and writes the assigned port to the path given as argv[1]; exits on its
own after 20 seconds so a failed test can never leave it running.
"""

import http.server
import socketserver
import sys
import threading


class RejectAll(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - name required by BaseHTTPRequestHandler
        self.send_response(401)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    if len(sys.argv) != 2:
        print("usage: test-401-server.py PORT_FILE", file=sys.stderr)
        return 1
    with socketserver.TCPServer(("127.0.0.1", 0), RejectAll) as server:
        with open(sys.argv[1], "w") as handle:
            handle.write(str(server.server_address[1]))
        threading.Timer(20, server.shutdown).start()
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
