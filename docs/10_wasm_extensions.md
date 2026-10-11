# PostgreSQL-WASM Extensions in `pg_tle` (`LANGUAGE "pl/v8-wasm"`)

`pg_tle` and `plv8` provide a native WebAssembly (`LANGUAGE "pl/v8-wasm"`) execution engine backed by V8's Liftoff/TurboFan WebAssembly compiler and a cross-backend shared memory (`DSA` + `dshash`) native machine code cache.

## Language-Specific Developer Guides

- **[Compiling Rust Functions to PostgreSQL-WASM (`10_wasm_rust_examples.md`)](./10_wasm_rust_examples.md)**:
  - Workflow A: Raw `wasm32-unknown-unknown` (`cdylib`) + `tle-pack wasm` / `pgtle.install_wasm_extension()`
  - Workflow B: High-level `wasm-bindgen` (`--target web`) + `pg_tle/tools/pgwasm_pack.py` or `tle-pack wasm --glue-js`
  - Ultra-tiny `#![no_std]` + `alloc` builds
  - Linear memory `alloc` / `dealloc` & zero-leak reusable `RETURN_BUF`
  - Custom PostgreSQL base types (`CREATE TYPE`), operators (`CREATE OPERATOR`), and SPI (`postgres.spi_exec`)
- **[Compiling Go and TinyGo Functions to PostgreSQL-WASM (`11_wasm_go_tinygo_examples.md`)](./11_wasm_go_tinygo_examples.md)**:
  - Standard Go (`go` 1.24+): `GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -ldflags="-s -w"`
  - TinyGo (`tinygo` 0.33+) WASI Reactor: `tinygo build -target=wasi -buildmode=c-shared -no-debug`
  - TinyGo (`tinygo` 0.33+) Freestanding: `tinygo build -target=wasm-unknown -no-debug`
  - WASI Reactor `_initialize()` lifecycle, `//go:wasmexport` vs `//export`, GC-safe `pinnedAllocs` (`alloc`/`dealloc`), custom base types, and `//go:wasmimport postgres spi_exec`

## Quick Reference: SQL & CLI Entry Points

1. **`pgtle.install_wasm_extension(name text, version text, description text, wasm_bytes bytea, manifest jsonb DEFAULT NULL, requires text[] DEFAULT '{}')`**:
   Validates the `.wasm` binary, stores it in `pgtle.modules` and `public.plv8_wasm_modules`, introspects the binary's Type/Function/Export sections (or merges your `manifest`), and registers the TLE extension for `CREATE EXTENSION <name>`.
2. **`tle-pack` (`pg_tle/tools/tle-pack wasm <input.wasm> --name <ext> --version <ver> [--manifest manifest.json] [--glue-js glue.js] --output <ext.sql>`)**:
   Packages a `.wasm` binary (and optional `manifest.json` / `wasm-bindgen` JS glue) into a single SQL file calling `pgtle.install_wasm_extension(...)`.
3. **`pgwasm-pack` (`pg_tle/tools/pgwasm_pack.py` / `pg_tle/tools/pgwasm-pack`)**:
   Builds a Rust `wasm-bindgen` crate (`--crate-dir`) or takes pre-built `--wasm` + `--js` files, transforms the `wasm-bindgen` glue for synchronous execution in V8, and emits a self-contained `.sql` file.
4. **[Standalone CLI Distribution (`pg_tle/tools/README.md`)](../tools/README.md)**:
   Both `tle-pack` and `pgwasm-pack` are packaged as standalone zero-dependency distributions in `pg_tle/tools/dist/` (standard Python wheel `pgtle_tools-1.6.0-py3-none-any.whl`, sdist `pgtle_tools-1.6.0.tar.gz`, single-file PEP 441 executables `tle-pack.pyz` / `pgwasm-pack.pyz`, and `pgtle-tools-standalone-1.6.0.tar.gz` with `install.sh`).
