"""PyInstaller entry point for the pwned-check console binary."""
from pwned_check.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
