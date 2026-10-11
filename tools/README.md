# `pgtle-tools`: Standalone Out-of-Database Packaging & Bundling CLI Tools for `pg_tle`

This directory provides the out-of-database developer tools for packaging JavaScript/npm libraries and Rust, Go, and TinyGo WebAssembly (`.wasm`) modules into self-contained, reproducible SQL installation scripts for PostgreSQL (`pg_tle`, `plv8`, `pl/v8-wasm`, and `pljs`).

Both `tle-pack` and `pgwasm-pack` are written in pure Python (`>= 3.8`) using **only the Python standard library** (zero third-party runtime dependencies), making them trivial to share and distribute as standalone packages or single-file executables.

---

## Included Tools

| Tool | Entry Point / Script | Description |
| :--- | :--- | :--- |
| **`tle-pack`** | `tle-pack` (`pgtle_tools.tle_pack:main`) | Universal zero-dependency bundler & packager for **JavaScript / npm packages** (`tle-pack js`) and **WebAssembly `.wasm` binaries** (`tle-pack wasm`, supporting Rust, Go, TinyGo, C/C++, Zig, and `--glue-js` for `wasm-bindgen`). Auto-introspects WebAssembly Type/Import/Function/Export sections. |
| **`pgwasm-pack`** | `pgwasm-pack` / `pgwasm_pack.py` (`pgtle_tools.pgwasm_pack:main`) | One-step **Rust `#[wasm_bindgen]`** crate builder (`cargo build --target wasm32-unknown-unknown --release` + `wasm-bindgen --target web --no-typescript`), synchronous PLV8 glue transformer, Rust signature parser, and SQL bundle generator. |
| **`pg_tle_manage_local_extension.sh`** | [`pg_tle_manage_local_extension/pg_tle_manage_local_extension.sh`](./pg_tle_manage_local_extension/README.md) | Bash CLI utility to install, update, list, and uninstall local SQL-based extensions in PostgreSQL via `pgtle.*` functions. |

---

## Standalone Distribution & Installation Options

Pre-built distribution artifacts are located in [`./dist/`](./dist/) and can be regenerated at any time with `python3 ./build_dist.py` (or `make dist`).

### Option 1: Install via `pip`, `pipx`, or `uv` (Wheel / Sdist / Source Directory)

```bash
# From the pre-built Wheel or Source Distribution in dist/:
pip install ./dist/pgtle_tools-1.6.0-py3-none-any.whl
# or:
pipx install ./dist/pgtle_tools-1.6.0-py3-none-any.whl
# or directly from this directory:
pip install .
```

This installs the `tle-pack`, `pgwasm-pack`, and `pgwasm_pack` console commands on your `PATH`, as well as the `pgtle_tools` Python package (`python3 -m pgtle_tools.tle_pack` and `python3 -m pgtle_tools.pgwasm_pack`).

### Option 2: Single-File Executable Python Zipapps (`.pyz` — Zero Install)

[`dist/tle-pack.pyz`](./dist/tle-pack.pyz) and [`dist/pgwasm-pack.pyz`](./dist/pgwasm-pack.pyz) are self-contained [PEP 441](https://peps.python.org/pep-0441/) executable archives. Copy either file to any machine with `python3` (`>= 3.8`) and run it directly:

```bash
./dist/tle-pack.pyz --tool-version
./dist/pgwasm-pack.pyz --tool-version
```

### Option 3: Portable Standalone Tarball / `install.sh` (No `pip` Required)

On minimal servers or containers where `pip` is not installed, extract `dist/pgtle-tools-standalone-1.6.0.tar.gz` (or run `./install.sh` directly) to install `tle-pack`, `pgwasm-pack`, `pgwasm_pack.py`, and `pg_tle_manage_local_extension.sh`:

```bash
tar -xzf ./dist/pgtle-tools-standalone-1.6.0.tar.gz
cd pgtle-tools-1.6.0
./install.sh --prefix ~/.local
```

### Option 4: Direct Single-File Execution

`./tle-pack` and `./pgwasm_pack.py` (and `./pgwasm-pack`) remain standalone single-file scripts with zero external dependencies and can be invoked in place or copied directly into `/usr/local/bin`:

```bash
./tle-pack wasm ./my_module.wasm --name my_module -o my_module.sql
./pgwasm_pack.py --crate-dir ./my_rust_crate --module-name my_rust_crate -o my_rust_crate.sql
```

---

## Quick Usage Reference

### 1. `tle-pack wasm` (Rust, Go, TinyGo, C/C++ WebAssembly Extensions)

```bash
# Auto-introspect a raw .wasm binary (Rust cdylib, Go wasip1, or TinyGo) into a pg_tle SQL installer:
tle-pack wasm ./suite.wasm \
  --name wasm_suite \
  --version 1.0.0 \
  --output wasm_suite.sql

# Merge with a manifest.json (custom PostgreSQL base types, operators, text/bytea functions):
tle-pack wasm ./rust_wasm_ext.wasm \
  --name rust_wasm_ext \
  --version 1.0.0 \
  --manifest ./manifest.json \
  --create-extension \
  --output rust_wasm_ext.sql

# Bundle a pre-built wasm-bindgen _bg.wasm + JS glue file:
tle-pack wasm ./pkg/sample_rust_udf_bg.wasm \
  --glue-js ./pkg/sample_rust_udf.js \
  --name sample_rust_udf \
  --version 1.0.0 \
  --manifest ./manifest.json \
  --output sample_rust_udf.sql
```

### 2. `tle-pack js` (JavaScript / npm Packages for `plv8` and `pljs`)

```bash
# Bundle an npm package directory or entry .js/.mjs file into pgtle.install_module() calls:
tle-pack js ./my_pkg \
  --as-extension \
  --compile-bytecode \
  --engine plv8 \
  --output my_pkg.sql
```

> **Environment Variables for `tle-pack`:**
> - `TLE_PACK_DSN`: Default PostgreSQL connection string for offline `--compile-bytecode`.
> - `TLE_PACK_PSQL`: Explicit path to `psql` (defaults to `psql` on `PATH` or `$(pg_config --bindir)/psql`).

### 3. `pgwasm-pack` (`pgwasm_pack.py`) (Rust `#[wasm_bindgen]` Crates)

```bash
# Workflow 1: Build a Rust #[wasm_bindgen] crate and emit a self-contained SQL bundle:
pgwasm-pack \
  --crate-dir ./sample_rust_udf \
  --module-name sample_rust_udf \
  --out-sql ./sample_rust_udf--1.0.sql

# Workflow 2: Package pre-built wasm-bindgen _bg.wasm + .js glue (with optional src/lib.rs or manifest.json):
pgwasm-pack \
  --wasm ./pkg/sample_rust_udf_bg.wasm \
  --js ./pkg/sample_rust_udf.js \
  --src ./src/lib.rs \
  --module-name sample_rust_udf \
  --as-extension \
  --create-extension \
  --out-sql ./sample_rust_udf--1.0.sql
```

---

## Building Distribution Packages & Running Tests

```bash
# Rebuild all artifacts in ./dist/ (.whl, .tar.gz sdist, .pyz zipapps, standalone tarball):
make dist

# Run the automated standalone packaging & CLI verification test suite:
make test
```

---

## License

Licensed under the [Apache-2.0 License](./LICENSE).
