"""CLI entrypoint.

Exit codes:
  0 - clean
  1 - pwned
  2 - config/usage error
  3 - network error (only when fail_closed=True)
"""
from __future__ import annotations
import argparse
import getpass
import sys
from pathlib import Path

from .config import load as load_config
from .core import validate
from .logging_setup import setup as setup_logging
from .providers.base import NetworkError

PROVIDER_ERROR_EXIT = 3


def _build_provider(cfg):
    if cfg.provider == "local":
        from .providers.local_service import LocalServiceProvider
        if not cfg.local_url:
            raise SystemExit("missing local_url for provider=local")
        return LocalServiceProvider(cfg.local_url, timeout=cfg.timeout_seconds)
    from .providers.hibp_api import HibpApiProvider
    return HibpApiProvider(timeout=cfg.timeout_seconds)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="pwned-check")
    p.add_argument("--stdin", action="store_true", help="read password from stdin")
    p.add_argument("--config", type=Path, default=None)
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args(argv)

    cfg = load_config(args.config)
    log = setup_logging("DEBUG" if args.verbose else "INFO")

    if args.stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = getpass.getpass("Password: ")
    if not password:
        print("empty password", file=sys.stderr)
        return 2

    provider = _build_provider(cfg)
    try:
        res = validate(password, provider)
    except NetworkError as e:
        if cfg.fail_closed:
            log.error("network failure fail_closed=true: %s", e)
            return PROVIDER_ERROR_EXIT
        log.warning("network failure fail_open: %s", e)
        return 0

    log.info("prefix=%s pwned=%s count=%d", res.prefix, res.pwned, res.count)
    return 1 if res.pwned else 0


if __name__ == "__main__":
    raise SystemExit(main())
