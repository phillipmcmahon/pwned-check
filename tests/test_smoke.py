"""CLI smoke tests against a mocked HIBP-compatible range service."""
from __future__ import annotations

import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pwned_check.core import _hash


def test_cli_rejects_pwned_password_with_mocked_range_service():
    prefix, suffix = _hash("password")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != f"/range/{prefix}":
                self.send_response(404)
                self.end_headers()
                return

            body = f"{suffix}:123\n".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        env = os.environ.copy()
        env.update(
            {
                "PWNED_CHECK_PROVIDER": "local",
                "PWNED_CHECK_LOCAL_URL": f"http://127.0.0.1:{server.server_port}",
            }
        )
        proc = subprocess.run(
            [sys.executable, "-m", "pwned_check.cli", "--stdin"],
            input="password\n",
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    assert proc.returncode == 1
    assert "prefix=5BAA6 pwned=True count=123" in proc.stderr
    assert "password" not in proc.stderr
