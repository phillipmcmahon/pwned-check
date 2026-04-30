"""Smoke test the packaged binary against a mocked range service."""
from __future__ import annotations

import os
import subprocess
import sys
import threading
from hashlib import sha1
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def hash_parts(password: str) -> tuple[str, str]:
    digest = sha1(password.encode("utf-8")).hexdigest().upper()
    return digest[:5], digest[5:]


def find_binary() -> Path:
    candidates = [
        ROOT / "dist" / "pwned-check",
        ROOT / "dist" / "pwned-check.exe",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("expected binary at dist/pwned-check or dist/pwned-check.exe")


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    binary = Path(args[0]) if args else find_binary()
    prefix, suffix = hash_parts("password")

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
            [str(binary), "--stdin"],
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

    if proc.returncode != 1:
        sys.stderr.write(proc.stderr)
        sys.stderr.write(proc.stdout)
        return proc.returncode or 1
    if "password" in proc.stderr:
        sys.stderr.write("binary smoke test failed: password leaked to stderr\n")
        return 1
    if "prefix=5BAA6 pwned=True count=123" not in proc.stderr:
        sys.stderr.write(proc.stderr)
        sys.stderr.write("binary smoke test failed: expected mocked pwned result\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
