#!/usr/bin/env python3
"""Validate jenkins/globalVars.yaml for the Jenkins agent global-vars ConfigMap.

Rules (from the file header):
  - top level is a flat map
  - keys are valid environment variable names  ([A-Za-z_][A-Za-z0-9_]*)
  - values are strings only (numbers / booleans must be quoted)

Usage:
  validate_global_vars.py [PATH]            # default: $ROOT/jenkins/globalVars.yaml
  validate_global_vars.py --root /repo      # resolves /repo/jenkins/globalVars.yaml
  validate_global_vars.py --quiet PATH      # exit code only

Exit codes:
  0  valid
  1  invalid content
  2  file missing / unreadable / YAML parse error
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("PyYAML missing: pip install -r requirements.txt\n")
    sys.exit(2)

ENV_KEY_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DEFAULT_REL_PATH = Path("jenkins") / "globalVars.yaml"


def resolve_path(path: str | None, root: str | None) -> Path:
    if path:
        return Path(path)
    base = root or os.environ.get("ROOT") or "."
    return Path(base) / DEFAULT_REL_PATH


def load(path: Path) -> dict:
    """Parse the YAML file. Raises on I/O or syntax error."""
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    return {} if data is None else data


def validate(data: object) -> list[str]:
    """Return a list of problems; empty list means valid."""
    if not isinstance(data, dict):
        return [f"top level must be a map, got {type(data).__name__}"]

    problems: list[str] = []
    for key, value in data.items():
        if not isinstance(key, str) or not ENV_KEY_RE.fullmatch(key):
            problems.append(f"{key!r}: key is not a valid env var name")
        elif not isinstance(value, str):
            problems.append(
                f"{key}: value must be a quoted string (got {type(value).__name__})"
            )
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", nargs="?", help="path to globalVars.yaml")
    ap.add_argument("--root", help="repo root (used when PATH is omitted)")
    ap.add_argument("-q", "--quiet", action="store_true", help="no output, exit code only")
    args = ap.parse_args(argv)

    path = resolve_path(args.path, args.root)

    def say(msg: str, err: bool = False) -> None:
        if not args.quiet:
            (sys.stderr if err else sys.stdout).write(msg + "\n")

    if not path.is_file():
        say(f"MISSING  {path}: create it (see README: Global env vars)", err=True)
        return 2

    try:
        data = load(path)
    except yaml.YAMLError as exc:
        say(f"ERROR    {path}: YAML parse error: {exc}", err=True)
        return 2
    except OSError as exc:
        say(f"ERROR    {path}: {exc}", err=True)
        return 2

    problems = validate(data)
    if problems:
        say(f"INVALID  {path}", err=True)
        for p in problems:
            say(f"  - {p}", err=True)
        return 1

    say(f"OK       {path}: {len(data)} keys")
    for key, value in data.items():
        say(f"  {key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
