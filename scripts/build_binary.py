"""Build the pwned-check single-file console binary with PyInstaller."""
from __future__ import annotations

from pathlib import Path

import PyInstaller.__main__


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    PyInstaller.__main__.run(
        [
            "--clean",
            "--onefile",
            "--name",
            "pwned-check",
            "--copy-metadata",
            "pwned-check",
            "--specpath",
            str(ROOT / "build"),
            "--paths",
            str(ROOT / "src"),
            str(ROOT / "packaging" / "pwned_check_entry.py"),
        ]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
