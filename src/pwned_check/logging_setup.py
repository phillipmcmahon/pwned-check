"""Structured logging. ONLY emits the 5-char prefix + outcome - never the password or full hash."""
import logging
import sys


def setup(level: str = "INFO") -> logging.Logger:
    logger = logging.getLogger("pwned_check")
    if logger.handlers:
        return logger
    h = logging.StreamHandler(sys.stderr)
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(h)
    logger.setLevel(level)
    return logger
