"""Out-of-database CLI packaging & bundling tools for pg_tle (JS/npm and WebAssembly).

Provides:
  - `pgtle_tools.tle_pack` (`tle-pack` CLI):
      Universal zero-dependency bundler & packager for JS/npm packages (`tle-pack js`)
      and WebAssembly `.wasm` binaries (`tle-pack wasm`, supporting Rust, Go, TinyGo, C/C++,
      and `--glue-js` for `wasm-bindgen`).
  - `pgtle_tools.pgwasm_pack` (`pgwasm-pack` CLI):
      One-step Rust `#[wasm_bindgen]` crate builder (`cargo build` + `wasm-bindgen`)
      and PostgreSQL `pl/v8-wasm` SQL packager.
"""

from __future__ import annotations

from . import pgwasm_pack
from . import tle_pack

__version__ = "1.6.0"

__all__ = [
    "__version__",
    "tle_pack",
    "pgwasm_pack",
]
