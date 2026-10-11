# Compiling Rust Functions to PostgreSQL-WASM (`pg_tle` + `plv8`)

`pg_tle` and `plv8` provide a first-class WebAssembly (`LANGUAGE "pl/v8-wasm"`) execution engine backed by V8's Liftoff/TurboFan native WebAssembly compiler and a cross-backend shared memory (`DSA` + `dshash`) native machine code cache.

You can compile Rust crates to WebAssembly and deploy them into PostgreSQL as Trusted Language Extensions (`CREATE EXTENSION`) or standalone `"pl/v8-wasm"` functions without filesystem access on the database server.

Two workflows are supported for Rust:

1. **Workflow A (Recommended): Raw `wasm32-unknown-unknown` (`cdylib`) + `tle-pack wasm` / `pgtle.install_wasm_extension()`**
   - Produces a compact standalone `.wasm` binary (`~3 KB – 35 KB`) with zero JavaScript glue.
   - Supports scalar primitives (`int2`, `int4`, `int8`/`bigint`, `float4`, `float8`, `bool`), linear memory buffers (`text`, `bytea`), custom PostgreSQL base types (`CREATE TYPE` via `pgtle.create_base_type_if_not_exists`), custom operators (`CREATE OPERATOR`), and PostgreSQL SPI/logging host imports (`postgres.spi_exec`, `postgres.elog_notice`, `postgres.elog_error`).
   - Compiled native machine code is cached across all PostgreSQL backends in shared memory (`plv8_wasm_shared_cache`).
2. **Workflow B: `wasm-bindgen` (`--target web`) + `pg_tle/tools/pgwasm_pack.py` or `tle-pack wasm --glue-js`**
   - Lets you write idiomatic high-level Rust signatures (`&str`, `String`, `&[u8]`, `Vec<u8>`, `Result<T, JsError>`) annotated with `#[wasm_bindgen]` while `wasm-bindgen` generates the JS memory-marshalling glue automatically.

---

## 1. The `pl/v8-wasm` ABI Reference for Rust

When `LANGUAGE "pl/v8-wasm"` invokes an exported Rust function in raw `.wasm` mode (Workflow A), arguments and return values are marshalled between PostgreSQL Datums and WebAssembly according to the following ABI rules:

### 1.1 Scalar Types

| PostgreSQL SQL Type | Rust Type | WebAssembly ABI Type | Marshalling Details |
| :--- | :--- | :--- | :--- |
| `int2` (`smallint`) | `i16` / `i32` | `i32` | Sign-extended 32-bit integer |
| `int4` (`integer`) | `i32` | `i32` | 32-bit signed integer (`Number(arg) \| 0`) |
| `int8` (`bigint`) | `i64` | `i64` | 64-bit signed integer (`BigInt` $\leftrightarrow$ `i64`) |
| `float4` (`real`) | `f32` | `f32` | IEEE-754 single-precision float |
| `float8` (`double precision`) | `f64` | `f64` | IEEE-754 double-precision float |
| `bool` (`boolean`) | `i32` / `bool` | `i32` | `0` = `false`, non-zero (`1`) = `true` |

### 1.2 Linear Memory Management (`alloc`/`dealloc`, `malloc`/`free`, `__wbindgen_malloc`/`__wbindgen_free`)

When passing `text`, `bytea`, or custom base type binary payloads into a raw `.wasm` function, the runtime looks up your module's allocator and deallocator exports in the following priority order (unless overridden via `"alloc_export"` / `"free_export"` in the function config):

| Priority | Allocator Export | Paired Deallocator Export | Call Signature Used by Host |
| :--- | :--- | :--- | :--- |
| **1 (Recommended)** | `alloc(size: usize) -> *mut u8` | `dealloc(ptr: *mut u8, size: usize)` | `alloc(len + 1, 1)` / `dealloc(ptr, len + 1, 1)` |
| **2 (C / libc)** | `malloc(size: usize) -> *mut u8` | `free(ptr: *mut u8)` | `malloc(len + 1, 1)` / `free(ptr, len + 1, 1)` |
| **3 (`wasm-bindgen`)** | `__wbindgen_malloc(size: usize, align: usize) -> *mut u8` | `__wbindgen_free(ptr: *mut u8, size: usize, align: usize)` | `__wbindgen_malloc(len + 1, 1)` / `__wbindgen_free(ptr, len + 1, 1)` |
| **4 (Scratch Fallback)** | *(none exported)* | *(none)* | Bump-allocates per call starting at `__heap_base` (or `scratch_offset`, default `32768`) |

> **Important Memory Lifecycle Rule:**
> - **Input buffers (`PostgreSQL -> Rust`)** are allocated by the host via `alloc(len + 1)` before calling your exported function (with a trailing NUL byte written at `ptr + len`), and **automatically freed by the host** via `dealloc(ptr, len + 1)` in a `finally` block immediately after your function returns.
> - **Return buffers (`Rust -> PostgreSQL`)** are copied out of `instance.exports.memory.buffer` by the host immediately after your function returns, but the host does *not* call `dealloc` on your return pointer. To avoid leaking heap memory across cached `WebAssembly.Instance` calls, write return payloads into a **reusable static `Vec<u8>` buffer** (`RETURN_BUF`) rather than calling `alloc()` or `std::mem::forget` on every return.

### 1.3 Linear Memory Buffer Calling & Return Conventions (`text`, `bytea`, Custom Base Types)

- **Input Arguments (`PostgreSQL -> Rust`)**:
  - **Default (`"arg_mode": "auto"` / `"ptr_len"`)**: Each `text`, `bytea`, or custom base type argument is passed as **two `i32` parameters `(ptr: *const u8, len: usize)`**.
  - **C-String / Pointer-Only (`"arg_mode": "cstring"` / `"ptr_only"`, or auto-detected via `fn.length`)**: Passes a single `ptr: *const u8` (guaranteed NUL-terminated at `ptr + len`).

- **Return Values (`Rust -> PostgreSQL`)**:
  `LANGUAGE "pl/v8-wasm"` automatically inspects the return value of your exported WASM function and supports **five return conventions**:
  1. **Packed `i64` (`-> i64` / `-> u64`, default `"return_mode": "auto"`)**:
     - Packs `((payload_len as u64) << 32) | (ptr as u32 as u64)` (length in upper 32 bits, pointer in lower 32 bits).
     - If `"return_mode": "ptr_len"` is set in the function/type config, unpacks `((ptr as u64) << 32) | (payload_len as u64)` (pointer in upper 32 bits, length in lower 32 bits).
     - Returning `0` produces SQL `NULL`.
  2. **Length-Prefixed `i32` Pointer (`-> *const u8` / `-> i32`, default `"return_mode": "auto"`)**:
     - Returns a 32-bit pointer `ptr` where `memory[ptr .. ptr + 4]` contains `payload_len as u32` in **little-endian** byte order and `memory[ptr + 4 .. ptr + 4 + payload_len]` contains the payload bytes.
     - Returning `0` (`std::ptr::null()`) produces SQL `NULL`.
  3. **Multi-Value `[ptr, len]` (`(result i32 i32)`)**:
     - When compiled with WebAssembly multi-value returns (`-C target-feature=+multivalue`), V8 returns a 2-element JS array `[ptr, len]`, which `pl/v8-wasm` unpacks directly.
  4. **Null-Terminated C-String Pointer (`-> *const u8` with `"return_mode": "cstring"`)**:
     - Scans `memory[ptr..]` up to the first `0` byte.
  5. **Fixed-Length Pointer (`-> *const u8` with `"return_length": N`, `"input_returns_fixed_ptr": true`, or `"return_mode": "fixed"`)**:
     - Reads exactly `N` bytes from `memory[ptr .. ptr + N]` without a 4-byte length prefix.

### 1.4 Host Imports Provided by PostgreSQL (`"postgres"`, `"wasi_snapshot_preview1"`, `"env"`)

Every WebAssembly module instantiated by `pg_tle` / `plv8` is provided with three host import namespaces:

#### A. `"postgres"` Namespace (Database SPI & Logging)

```rust
#[link(wasm_import_module = "postgres")]
extern "C" {
    /// 4-argument overload: Execute a SQL query via PostgreSQL SPI (`plv8.execute(sql)`)
    /// and write the UTF-8 JSON result array into `out_ptr[0..out_cap]`.
    /// Returns the total UTF-8 byte length of the JSON result. If the return value
    /// exceeds `out_cap`, resize your buffer to the returned length and call again.
    fn spi_exec(sql_ptr: *const u8, sql_len: usize, out_ptr: *mut u8, out_cap: usize) -> i32;

    /// Emit a PostgreSQL `NOTICE` log message.
    fn elog_notice(msg_ptr: *const u8, msg_len: usize);

    /// Raise a PostgreSQL `ERROR` exception (cleanly aborts the call and evicts the instance).
    fn elog_error(msg_ptr: *const u8, msg_len: usize);
}
```

> **2-Argument `postgres.spi_exec` Overload:**
> You can also declare `fn spi_exec(sql_ptr: *const u8, sql_len: usize) -> u64;`. In 2-argument mode, the host executes the query, allocates `json_len` bytes in guest linear memory using your exported `alloc(json_len)` function, copies the UTF-8 JSON bytes into `ptr`, and returns packed `((json_len as u64) << 32) | (ptr as u64)`. After parsing the JSON slice, call `dealloc(ptr as *mut u8, json_len)` to free the buffer.

#### B. `"wasi_snapshot_preview1"` / `"wasi_unstable"` & `"env"` Namespaces
- `wasi_snapshot_preview1` / `wasi_unstable`: Provides `args_sizes_get`, `args_get`, `environ_sizes_get`, `environ_get`, `clock_res_get`, `clock_time_get`, `fd_write` (capturing `stderr` on fd `2`), `fd_read`, `fd_close`, `fd_fdstat_get`, `fd_fdstat_set_flags`, `fd_prestat_get`, `fd_prestat_dir_name`, `fd_seek`, `path_open`, `random_get`, `poll_oneoff`, `sched_yield`, and `proc_exit` (throwing a PostgreSQL `ERROR` containing any captured `stderr` text).
- `env`: Provides `abort()`, `__wasi_fd_write`, `plv8_elog_notice(ptr, len)`, and `plv8_elog_error(ptr, len)`.
- If a module exports `_initialize()` (e.g. `wasm32-wasip1` reactor modules), the runtime automatically invokes `instance.exports._initialize()` once upon instantiation.

---

## 2. Workflow A: Raw `wasm32-unknown-unknown` (`cdylib`) + `tle-pack wasm`

### Step 1: Install the Rust WebAssembly Target

```bash
rustup target add wasm32-unknown-unknown
```

### Step 2: Create Cargo Project and `Cargo.toml`

```bash
cargo new --lib rust_wasm_ext
cd rust_wasm_ext
```

Configure `Cargo.toml` with `crate-type = ["cdylib"]` and `panic = "abort"` for small, fast binaries:

```toml
[package]
name = "rust_wasm_ext"
version = "1.0.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[profile.release]
opt-level = "s"
lto = true
codegen-units = 1
panic = "abort"
strip = true
```

### Step 3: Write `src/lib.rs`

Below is a complete, production-ready `src/lib.rs` demonstrating:
- Required `alloc` and `dealloc` linear memory exports paired with a zero-leak reusable `RETURN_BUF`
- Custom panic hook forwarding Rust panics to PostgreSQL `ERROR` via `postgres.elog_error`
- Scalar functions (`i32`, `i64`, `f64`, `bool`)
- Linear memory `text` and `bytea` functions (demonstrating both 4-byte length-prefixed `-> *const u8` and packed `-> i64` return conventions)
- A custom 8-byte PostgreSQL base type `rust_vec2i` (`(x,y)` 2D integer vector) with `input`, `output`, `+`, `=`, and dot product functions
- Executing SQL via `postgres.spi_exec` with automatic buffer resize for arbitrary-size query results

```rust
use std::alloc::{alloc as sys_alloc, dealloc as sys_dealloc, Layout};
use std::cell::UnsafeCell;
use std::slice;
use std::str;
use std::sync::Once;

#[link(wasm_import_module = "postgres")]
extern "C" {
    fn spi_exec(sql_ptr: *const u8, sql_len: usize, out_ptr: *mut u8, out_cap: usize) -> i32;
    fn elog_notice(msg_ptr: *const u8, msg_len: usize);
    fn elog_error(msg_ptr: *const u8, msg_len: usize);
}

static INIT_PANIC_HOOK: Once = Once::new();

fn ensure_panic_hook() {
    INIT_PANIC_HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let msg = info.to_string();
            unsafe {
                elog_error(msg.as_ptr(), msg.len());
            }
        }));
    });
}

fn pg_error(msg: &str) -> ! {
    unsafe {
        elog_error(msg.as_ptr(), msg.len());
    }
    core::arch::wasm32::unreachable();
}

// ============================================================================
// 1. Required Linear Memory Allocator Exports (`alloc` / `dealloc`)
//    & Zero-Leak Reusable Return Buffer (`RETURN_BUF`)
// ============================================================================

#[no_mangle]
pub extern "C" fn alloc(size: usize) -> *mut u8 {
    ensure_panic_hook();
    let Ok(layout) = Layout::from_size_align(size.max(1), 8) else {
        return std::ptr::null_mut();
    };
    unsafe { sys_alloc(layout) }
}

#[no_mangle]
pub extern "C" fn dealloc(ptr: *mut u8, size: usize) {
    if ptr.is_null() {
        return;
    }
    if let Ok(layout) = Layout::from_size_align(size.max(1), 8) {
        unsafe { sys_dealloc(ptr, layout) };
    }
}

struct ReturnBuffer(UnsafeCell<Vec<u8>>);
unsafe impl Sync for ReturnBuffer {}
static RETURN_BUF: ReturnBuffer = ReturnBuffer(UnsafeCell::new(Vec::new()));

/// Write a 4-byte little-endian length-prefixed payload into `RETURN_BUF` and return its pointer.
/// Reuses the underlying `Vec<u8>` allocation across calls so zero heap memory is leaked.
fn make_len_prefixed_buffer(payload: &[u8]) -> *const u8 {
    let buf = unsafe { &mut *RETURN_BUF.0.get() };
    buf.clear();
    buf.reserve(4 + payload.len());
    buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    buf.extend_from_slice(payload);
    buf.as_ptr()
}

/// Write `payload` into `RETURN_BUF` and return packed `((len as u64) << 32) | (ptr as u64)`.
fn pack_return_buffer(payload: &[u8]) -> i64 {
    let buf = unsafe { &mut *RETURN_BUF.0.get() };
    buf.clear();
    if payload.is_empty() {
        buf.push(0);
        return (buf.as_ptr() as u32) as i64;
    }
    buf.extend_from_slice(payload);
    let ptr = buf.as_ptr() as u32;
    let len = buf.len() as u32;
    (((len as u64) << 32) | (ptr as u64)) as i64
}

fn read_bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    unsafe { slice::from_raw_parts(ptr, len) }
}

// ============================================================================
// 2. Scalar Functions (int4, int8, float8, bool)
// ============================================================================

#[no_mangle]
pub extern "C" fn add_i32(a: i32, b: i32) -> i32 {
    a.wrapping_add(b)
}

#[no_mangle]
pub extern "C" fn fib_i64(n: i64) -> i64 {
    if n <= 0 {
        return 0;
    }
    let (mut a, mut b) = (0i64, 1i64);
    for _ in 1..n {
        let next = a.wrapping_add(b);
        a = b;
        b = next;
    }
    b
}

#[no_mangle]
pub extern "C" fn hypot_f64(x: f64, y: f64) -> f64 {
    (x * x + y * y).sqrt()
}

#[no_mangle]
pub extern "C" fn is_prime_bool(n: i32) -> i32 {
    if n < 2 {
        return 0;
    }
    if n == 2 {
        return 1;
    }
    if n % 2 == 0 {
        return 0;
    }
    let mut d = 3i32;
    while d.saturating_mul(d) <= n {
        if n % d == 0 {
            return 0;
        }
        d += 2;
    }
    1
}

// ============================================================================
// 3. Linear Memory Functions (`text` and `bytea`)
// ============================================================================

/// Reverses a UTF-8 string by Unicode scalar values (`char`) and uppercases ASCII.
/// Demonstrates returning a packed `i64` (`(len << 32) | ptr`).
#[no_mangle]
pub extern "C" fn reverse_upper_text(ptr: *const u8, len: usize) -> i64 {
    ensure_panic_hook();
    let s = str::from_utf8(read_bytes(ptr, len)).unwrap_or_else(|_| pg_error("invalid UTF-8"));
    let transformed: String = s.to_uppercase().chars().rev().collect();
    pack_return_buffer(transformed.as_bytes())
}

/// Repeating-key XOR cipher over two `bytea` buffers.
/// Demonstrates returning a 4-byte little-endian length-prefixed pointer (`*const u8`).
#[no_mangle]
pub extern "C" fn xor_cipher_bytea(
    data_ptr: *const u8,
    data_len: usize,
    key_ptr: *const u8,
    key_len: usize,
) -> *const u8 {
    ensure_panic_hook();
    let data = read_bytes(data_ptr, data_len);
    let key = read_bytes(key_ptr, key_len);
    if key.is_empty() {
        return make_len_prefixed_buffer(data);
    }
    let out: Vec<u8> = data
        .iter()
        .enumerate()
        .map(|(i, &b)| b ^ key[i % key.len()])
        .collect();
    make_len_prefixed_buffer(&out)
}

// ============================================================================
// 4. Custom PostgreSQL Base Type `rust_vec2i` (8-byte 2D integer vector)
// ============================================================================

fn parse_vec2i_text(s: &str) -> Option<(i32, i32)> {
    let trimmed = s.trim();
    let inner = trimmed.strip_prefix('(')?.strip_suffix(')')?;
    let (left, right) = inner.split_once(',')?;
    let x = left.trim().parse::<i32>().ok()?;
    let y = right.trim().parse::<i32>().ok()?;
    Some((x, y))
}

#[no_mangle]
pub extern "C" fn vec2i_in(ptr: *const u8, len: usize) -> *const u8 {
    ensure_panic_hook();
    let Ok(s) = str::from_utf8(read_bytes(ptr, len)) else {
        pg_error("invalid UTF-8 in rust_vec2i input");
    };
    let Some((x, y)) = parse_vec2i_text(s) else {
        pg_error(&format!("invalid input syntax for type rust_vec2i: \"{}\"", s));
    };
    let mut payload = [0u8; 8];
    payload[0..4].copy_from_slice(&x.to_le_bytes());
    payload[4..8].copy_from_slice(&y.to_le_bytes());
    make_len_prefixed_buffer(&payload)
}

#[no_mangle]
pub extern "C" fn vec2i_out(ptr: *const u8, len: usize) -> *const u8 {
    ensure_panic_hook();
    let bytes = read_bytes(ptr, len);
    if bytes.len() < 8 {
        pg_error("corrupt internal representation for rust_vec2i");
    }
    let x = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    let y = i32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    let formatted = format!("({},{})", x, y);
    make_len_prefixed_buffer(formatted.as_bytes())
}

#[no_mangle]
pub extern "C" fn vec2i_add(
    a_ptr: *const u8,
    a_len: usize,
    b_ptr: *const u8,
    b_len: usize,
) -> *const u8 {
    let a = read_bytes(a_ptr, a_len);
    let b = read_bytes(b_ptr, b_len);
    if a.len() < 8 || b.len() < 8 {
        pg_error("corrupt rust_vec2i operand");
    }
    let ax = i32::from_le_bytes([a[0], a[1], a[2], a[3]]);
    let ay = i32::from_le_bytes([a[4], a[5], a[6], a[7]]);
    let bx = i32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    let by = i32::from_le_bytes([b[4], b[5], b[6], b[7]]);
    let mut payload = [0u8; 8];
    payload[0..4].copy_from_slice(&ax.wrapping_add(bx).to_le_bytes());
    payload[4..8].copy_from_slice(&ay.wrapping_add(by).to_le_bytes());
    make_len_prefixed_buffer(&payload)
}

#[no_mangle]
pub extern "C" fn vec2i_eq(a_ptr: *const u8, a_len: usize, b_ptr: *const u8, b_len: usize) -> i32 {
    let a = read_bytes(a_ptr, a_len);
    let b = read_bytes(b_ptr, b_len);
    if a.len() < 8 || b.len() < 8 {
        return 0;
    }
    i32::from(a[0..8] == b[0..8])
}

#[no_mangle]
pub extern "C" fn vec2i_dot(a_ptr: *const u8, a_len: usize, b_ptr: *const u8, b_len: usize) -> i32 {
    let a = read_bytes(a_ptr, a_len);
    let b = read_bytes(b_ptr, b_len);
    if a.len() < 8 || b.len() < 8 {
        return 0;
    }
    let ax = i32::from_le_bytes([a[0], a[1], a[2], a[3]]);
    let ay = i32::from_le_bytes([a[4], a[5], a[6], a[7]]);
    let bx = i32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    let by = i32::from_le_bytes([b[4], b[5], b[6], b[7]]);
    ax.wrapping_mul(bx).wrapping_add(ay.wrapping_mul(by))
}

// ============================================================================
// 5. PostgreSQL SPI & Logging Host Calls (`postgres.spi_exec`, `elog_notice`)
// ============================================================================

#[no_mangle]
pub extern "C" fn run_spi_query(sql_ptr: *const u8, sql_len: usize) -> i64 {
    ensure_panic_hook();
    let sql_bytes = read_bytes(sql_ptr, sql_len);
    let notice = format!(
        "Executing SPI query from Rust WASM: {}",
        str::from_utf8(sql_bytes).unwrap_or("<invalid utf8>")
    );
    unsafe {
        elog_notice(notice.as_ptr(), notice.len());
    }
    let mut out_buf = vec![0u8; 4096];
    let needed = unsafe { spi_exec(sql_ptr, sql_len, out_buf.as_mut_ptr(), out_buf.len()) };
    if needed <= 0 {
        return pack_return_buffer(b"[]");
    }
    let needed_len = needed as usize;
    if needed_len > out_buf.len() {
        out_buf.resize(needed_len, 0);
        unsafe {
            spi_exec(sql_ptr, sql_len, out_buf.as_mut_ptr(), out_buf.len());
        }
    } else {
        out_buf.truncate(needed_len);
    }
    pack_return_buffer(&out_buf)
}
```

### Step 4: Compile the `.wasm` Binary

```bash
cargo build --target wasm32-unknown-unknown --release
cp target/wasm32-unknown-unknown/release/rust_wasm_ext.wasm ./
```

### Step 5: Write `manifest.json` and Package with `tle-pack wasm`

While `pgtle.install_wasm_extension()` and `tle-pack wasm` can automatically introspect your `.wasm` export table to generate `int4`/`int8`/`float4`/`float8` scalar SQL wrappers when no manifest is given, providing a `manifest.json` lets you declare `boolean`, `text`, `bytea`, custom base types, and custom operators:

```json
{
  "types": [
    {
      "schema": "public",
      "name": "rust_vec2i",
      "internallength": 8,
      "alignment": "int4",
      "storage": "plain",
      "input_export": "vec2i_in",
      "output_export": "vec2i_out",
      "operators": [
        {
          "name": "rust_vec2i_add",
          "export": "vec2i_add",
          "nargs": 2,
          "returns": "public.rust_vec2i",
          "operator": "+"
        },
        {
          "name": "rust_vec2i_eq",
          "export": "vec2i_eq",
          "nargs": 2,
          "returns": "boolean",
          "operator": "="
        },
        {
          "name": "rust_vec2i_dot",
          "export": "vec2i_dot",
          "nargs": 2,
          "returns": "int4"
        }
      ]
    }
  ],
  "functions": [
    {
      "name": "rust_add_i32",
      "args": ["int4", "int4"],
      "returns": "int4",
      "export": "add_i32",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "rust_fib_i64",
      "args": ["int8"],
      "returns": "int8",
      "export": "fib_i64",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "rust_hypot_f64",
      "args": ["float8", "float8"],
      "returns": "float8",
      "export": "hypot_f64",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "rust_is_prime",
      "args": ["int4"],
      "returns": "boolean",
      "export": "is_prime_bool",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "rust_reverse_upper",
      "args": ["text"],
      "returns": "text",
      "export": "reverse_upper_text",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "rust_xor_cipher",
      "args": ["bytea", "bytea"],
      "returns": "bytea",
      "export": "xor_cipher_bytea",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "rust_spi_query",
      "args": ["text"],
      "returns": "text",
      "export": "run_spi_query",
      "volatility": "VOLATILE"
    }
  ]
}
```

Package the `.wasm` binary and `manifest.json` into a single SQL installer script using `tle-pack wasm`:

```bash
pg_tle/tools/tle-pack wasm ./rust_wasm_ext.wasm \
  --name rust_wasm_ext \
  --version 1.0.0 \
  --description "Rust WebAssembly extension for PostgreSQL" \
  --manifest ./manifest.json \
  --output ./rust_wasm_ext.sql
```

### Step 6: Install and Run in PostgreSQL

```sql
\i rust_wasm_ext.sql
CREATE EXTENSION rust_wasm_ext;

-- 1. Scalar functions
SELECT
  rust_add_i32(125, 225) AS rust_add,
  rust_fib_i64(50) AS rust_fib_50,
  rust_hypot_f64(3.0, 4.0) AS rust_hypot,
  rust_is_prime(97) AS prime_97,
  rust_is_prime(99) AS prime_99;

-- 2. Linear memory text and bytea functions
SELECT
  rust_reverse_upper('PostgreSQL Rust WASM!') AS rev_upper,
  convert_from(
    rust_xor_cipher(
      rust_xor_cipher('Rust Linear Memory Bytea!'::bytea, 'k3y'::bytea),
      'k3y'::bytea
    ),
    'UTF8'
  ) AS xor_roundtrip;

-- 3. Custom base type rust_vec2i with table storage and + / = operators
CREATE TEMP TABLE rust_vecs (id int PRIMARY KEY, v rust_vec2i NOT NULL);
INSERT INTO rust_vecs VALUES (1, '(12,-5)'::rust_vec2i), (2, '(8,20)'::rust_vec2i);

SELECT
  v1.v::text AS v1,
  v2.v::text AS v2,
  (v1.v + v2.v)::text AS v_sum,
  (v1.v = '(12,-5)'::rust_vec2i) AS eq_true,
  rust_vec2i_dot(v1.v, v2.v) AS dot_prod
FROM rust_vecs v1
JOIN rust_vecs v2 ON v1.id = 1 AND v2.id = 2;

-- 4. Execute SQL inside Rust WASM via postgres.spi_exec (including recursive WASM calls)
SELECT rust_spi_query('SELECT id, v::text AS vec, rust_reverse_upper(''nested'') AS nested FROM rust_vecs ORDER BY id');
```

---

## 3. Alternative: Ultra-Tiny `#![no_std]` + `alloc` Rust Builds

If you want minimal `.wasm` binaries (`~3 KB – 30 KB`) without `std`, you can build `#![no_std]` Rust binaries using `core::arch::wasm32::{memory_size, memory_grow}` as your `#[global_allocator]` and forwarding panics to `postgres.elog_error`:

```rust
#![no_std]
extern crate alloc;

use alloc::format;
use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::panic::PanicInfo;

#[link(wasm_import_module = "postgres")]
extern "C" {
    fn elog_error(msg_ptr: *const u8, msg_len: usize);
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let msg = format!("Rust WASM panic: {}", info);
    unsafe {
        elog_error(msg.as_ptr(), msg.len());
    }
    core::arch::wasm32::unreachable()
}

struct WasmPageBumpAlloc {
    offset: UnsafeCell<usize>,
}
unsafe impl Sync for WasmPageBumpAlloc {}

#[global_allocator]
static ALLOCATOR: WasmPageBumpAlloc = WasmPageBumpAlloc {
    offset: UnsafeCell::new(0),
};

unsafe impl GlobalAlloc for WasmPageBumpAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let align = layout.align().max(8);
        let size = layout.size().max(1);
        let ptr_ref = &mut *self.offset.get();
        if *ptr_ref == 0 {
            *ptr_ref = 65536; // Start heap above 64 KiB static data boundary
        }
        let aligned = (*ptr_ref + align - 1) & !(align - 1);
        let next = aligned + size;
        let cur_bytes = core::arch::wasm32::memory_size(0) * 65536;
        if next > cur_bytes {
            let pages = (next - cur_bytes + 65535) / 65536;
            if core::arch::wasm32::memory_grow(0, pages) == usize::MAX {
                return core::ptr::null_mut();
            }
        }
        *ptr_ref = next;
        aligned as *mut u8
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {}
}
```

---

## 4. Workflow B: High-Level Rust with `wasm-bindgen` (`pgwasm_pack.py` / `tle-pack wasm --glue-js`)

If you prefer writing Rust functions with high-level types (`&str`, `String`, `&[u8]`, `Vec<u8>`, `Result<T, JsError>`) without manual pointer/length marshalling, you can use `wasm-bindgen` with `pg_tle/tools/pgwasm_pack.py` (or `pg_tle/tools/tle-pack wasm --glue-js`).

> **Why standard `wasm-pack` targets don't work directly in PostgreSQL:**
> - `wasm-pack build --target web` relies on asynchronous `fetch()` and `WebAssembly.instantiateStreaming()` Promises and ES `export` syntax.
> - `wasm-pack build --target nodejs` relies on Node's `require('fs').readFileSync()`.
> - `pgwasm_pack.py` and `tle-pack wasm --glue-js` transform `wasm-bindgen --target web --no-typescript` output into a synchronous two-phase initializer (`{ __wbg_get_imports, __wbg_set_wasm, exports }`) that runs inside V8's synchronous PostgreSQL execution context.

### Step 1: Add `wasm-bindgen` to `Cargo.toml`

```toml
[package]
name = "sample_rust_udf"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
wasm-bindgen = "0.2"
serde_json = "1.0"
```

### Step 2: Write `src/lib.rs` with `#[wasm_bindgen]`

> **Important:** Use `#[wasm_bindgen(js_namespace = postgres)]` (not `raw_module = "postgres"`) to bind `spi_exec`, `elog_notice`, and `elog_error`. Using `js_namespace = postgres` calls `globalThis.postgres.*` directly without emitting top-level ES module `import` statements inside the `wasm-bindgen` glue.

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = postgres)]
    fn spi_exec(sql: &str) -> String;

    #[wasm_bindgen(js_namespace = postgres)]
    fn elog_notice(msg: &str);
}

#[wasm_bindgen]
pub fn greet_user(name: &str) -> String {
    elog_notice(&format!("Greeting user: {}", name));
    format!("Hello from Rust wasm-bindgen, {}!", name)
}

#[wasm_bindgen]
pub fn checked_divide(a: i32, b: i32) -> Result<i32, JsError> {
    if b == 0 {
        return Err(JsError::new("division by zero in Rust WASM UDF"));
    }
    Ok(a / b)
}

#[wasm_bindgen]
pub fn spi_sum_series(limit_n: i32) -> Result<i32, JsError> {
    let sql = format!("SELECT coalesce(sum(g), 0)::int AS total FROM generate_series(1, {}) g", limit_n);
    let rows_json = spi_exec(&sql);
    let rows: serde_json::Value = serde_json::from_str(&rows_json)
        .map_err(|e| JsError::new(&format!("SPI JSON parse error: {}", e)))?;
    let total = rows
        .get(0)
        .and_then(|r| r.get("total"))
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    Ok(total as i32)
}
```

### Step 3: Build and Package with `pgwasm_pack.py` (or `tle-pack wasm --glue-js`)

**Option 1: One-command build & bundle with `pgwasm_pack.py`**
```bash
python3 pg_tle/tools/pgwasm_pack.py \
  --crate-dir ./sample_rust_udf \
  --module-name sample_rust_udf \
  --out-sql ./sample_rust_udf--1.0.sql
```

**Option 2: Package pre-built `wasm-bindgen` outputs with `tle-pack wasm --glue-js`**
```bash
cargo build --target wasm32-unknown-unknown --release
wasm-bindgen --target web --no-typescript \
  --out-dir ./pkg \
  target/wasm32-unknown-unknown/release/sample_rust_udf.wasm

pg_tle/tools/tle-pack wasm ./pkg/sample_rust_udf_bg.wasm \
  --glue-js ./pkg/sample_rust_udf.js \
  --name sample_rust_udf \
  --version 1.0.0 \
  --manifest ./manifest.json \
  --output ./sample_rust_udf--1.0.sql
```

### Step 4: Deploy and Run in PostgreSQL

`pgwasm_pack.py` emits both the `INSERT INTO public.plv8_wasm_modules (module_name, wasm_bytecode, glue_js)` statement and the `CREATE OR REPLACE FUNCTION ... LANGUAGE "pl/v8-wasm"` declarations automatically:

```sql
\i sample_rust_udf--1.0.sql

SELECT greet_user('PostgreSQL');
SELECT checked_divide(84, 2);
SELECT spi_sum_series(100);
```

---

## 5. Standalone `"pl/v8-wasm"` Usage (Inline Base64 & Catalog Table)

In addition to packaging full `pg_tle` extensions with `tle-pack wasm`, you can create standalone `"pl/v8-wasm"` functions directly in SQL:

### 5.1 Inline Base64 Micro-Functions (`"wasm"`)

```sql
SELECT pgtle.bootstrap_wasm_engine();

CREATE OR REPLACE FUNCTION wasm_add_inline(a int4, b int4)
RETURNS int4 LANGUAGE "pl/v8-wasm" IMMUTABLE STRICT AS $$
{
  "export": "add",
  "wasm": "AGFzbQEAAAABBwFgAn9/AX8DAgEABwcBA2FkZAAACgkBBwAgACABags="
}
$$;

SELECT wasm_add_inline(20, 22);
-- Returns: 42
```

### 5.2 Direct `pgtle.install_wasm_extension()` SQL Call

```sql
SELECT pgtle.install_wasm_extension(
  'my_rust_ext',
  '1.0.0',
  'Rust WASM extension registered directly via SQL',
  pg_catalog.decode('<hex_encoded_wasm_bytes>', 'hex'),
  '{
    "functions": [
      {"name": "my_rust_add", "export": "add_i32", "args": ["int4", "int4"], "returns": "int4"}
    ]
  }'::jsonb
);

CREATE EXTENSION my_rust_ext;
SELECT my_rust_add(10, 32);
```
