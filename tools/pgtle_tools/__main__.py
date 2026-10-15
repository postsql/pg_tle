#!/usr/bin/env python3
"""Unified `python3 -m pgtle_tools` entrypoint dispatching to `tle-pack` or `pgwasm-pack`."""

from __future__ import annotations

import sys
from typing import List, Optional

from . import __version__
from . import pgwasm_pack
from . import tle_pack


def main(argv: Optional[List[str]] = None) -> int:
  args = list(sys.argv[1:] if argv is None else argv)
  if not args or args[0] in ("-h", "--help"):
    print(
        f"pgtle-tools {__version__} - Out-of-database CLI packaging tools for pg_tle\n\n"
        "Usage:\n"
        "  tle-pack [js|wasm] <input> [options]\n"
        "  pgwasm-pack (--crate-dir <dir> | --wasm <file> --js <file>) [options]\n\n"
        "Or via module invocation:\n"
        "  python3 -m pgtle_tools tle-pack ...\n"
        "  python3 -m pgtle_tools pgwasm-pack ...\n"
        "  python3 -m pgtle_tools.tle_pack ...\n"
        "  python3 -m pgtle_tools.pgwasm_pack ..."
    )
    return 0
  if args[0] in ("-V", "--version", "--tool-version"):
    print(f"pgtle-tools {__version__}")
    return 0
  subcmd = args[0]
  rest = args[1:]
  if subcmd in ("tle-pack", "tle_pack"):
    return tle_pack.main(rest)
  if subcmd in ("pgwasm-pack", "pgwasm_pack", "pgwasm_pack.py"):
    return pgwasm_pack.main(rest)
  # Default to tle-pack if the first argument is 'js', 'wasm', 'auto', or a path
  return tle_pack.main(args)


if __name__ == "__main__":
  sys.exit(main())
