# Compiling Go and TinyGo Functions to PostgreSQL-WASM (`pg_tle` + `plv8`)

`pg_tle` and `plv8` include built-in **WASI Preview 1** (`wasi_snapshot_preview1` / `wasi_unstable`) support and automatic WASI Reactor initialization (`_initialize()`), allowing you to compile Go functions to WebAssembly using either:

1. **Standard Go (`go` 1.24+)**: `GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -ldflags="-s -w"`
2. **TinyGo (`tinygo` 0.33+)**:
   - **WASI Reactor target**: `tinygo build -target=wasi -buildmode=c-shared -no-debug`
   - **Freestanding target**: `tinygo build -target=wasm-unknown -no-debug`

The exact same `.go` source file compiles cleanly with all three toolchains and runs inside PostgreSQL via `LANGUAGE "pl/v8-wasm"` or ES module `import` in `LANGUAGE plv8`.

---

## 1. Compiler Comparison: Standard Go vs. TinyGo

| Feature / Metric | Standard Go (`GOOS=wasip1`) | TinyGo WASI (`-target=wasi`) | TinyGo Freestanding (`-target=wasm-unknown`) |
| :--- | :--- | :--- | :--- |
| **Build Command** | `GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -ldflags="-s -w"` | `tinygo build -target=wasi -buildmode=c-shared -no-debug` | `tinygo build -target=wasm-unknown -no-debug` |
| **Export Directive** | `//go:wasmexport <name>` | `//go:wasmexport <name>` or `//export <name>` | `//go:wasmexport <name>` or `//export <name>` |
| **Import Directive** | `//go:wasmimport <mod> <name>` | `//go:wasmimport <mod> <name>` | `//go:wasmimport <mod> <name>` |
| **Typical `.wasm` Size** | ~1.8 MB – 2.6 MB | ~150 KB – 210 KB | ~60 KB – 90 KB |
| **Go Standard Library** | Full `std` (`encoding/json`, `regexp`, `math/big`, `fmt`, reflection) | Most of `std` | Core packages (`strconv`, `strings`, `bytes`, `math`, `encoding/binary`) |
| **WASI Imports Needed** | `wasi_snapshot_preview1` (provided by `pg_tle`/`plv8`) | `wasi_snapshot_preview1` (provided by `pg_tle`/`plv8`) | None (`0` WASI imports; only `postgres.*` if used) |
| **Reactor Init Export** | `_initialize` (auto-called by `pg_tle`/`plv8`) | `_initialize` (auto-called by `pg_tle`/`plv8`) | `_initialize` (auto-called by `pg_tle`/`plv8`) |

---

## 2. Essential Rules for Go & TinyGo PostgreSQL-WASM Modules

### 2.1 Always Build as a WASI Reactor (`-buildmode=c-shared`)

By default, compiling `package main` with `GOOS=wasip1 GOARCH=wasm` (or `tinygo build -target=wasi`) produces a **WASI Command** module with a `_start` entry point that runs `main()` and immediately invokes `proc_exit(0)`. In WebAssembly/WASI, `proc_exit` terminates the instance and prevents subsequent exported function calls from running.

Passing **`-buildmode=c-shared`** (or using `tinygo build -target=wasm-unknown`) builds a **WASI Reactor** module:
- The compiler exports `_initialize()` instead of `_start()`.
- `pg_tle` and `plv8` automatically invoke `instance.exports._initialize()` once when instantiating the `WebAssembly.Instance`, initializing the Go runtime, garbage collector, and package `init()` functions while keeping the instance alive across thousands of SQL function calls.
- Even with `-buildmode=c-shared`, Go requires `package main` and an empty `func main() {}`.

### 2.2 Export Directives: `//go:wasmexport` vs. `//export`

- **`//go:wasmexport <export_name>`**: Supported by both **Standard Go 1.24+** (`GOOS=wasip1 GOARCH=wasm`) and **TinyGo 0.33+**. Using `//go:wasmexport` makes a single `.go` file portable across Standard Go and TinyGo.
- **`//export <export_name>`**: TinyGo's classic export pragma (supported across all TinyGo releases for `-target=wasm-unknown` and `-target=wasi`). Note that Standard Go (`go build`) ignores `//export` unless cgo is enabled (which is not supported on `GOOS=wasip1`), so prefer `//go:wasmexport` when targeting both compilers, or `//export` when targeting TinyGo exclusively:
  ```go
  // Portable across Standard Go 1.24+ and TinyGo 0.33+:
  //go:wasmexport add_i32
  func addI32(a int32, b int32) int32 {
      return a + b
  }

  // TinyGo-specific classic directive (works in all TinyGo versions):
  //export add_i32
  func addI32(a int32, b int32) int32 {
      return a + b
  }
  ```

### 2.3 Built-In WASI Preview 1 Host Environment (`wasi_snapshot_preview1`)

When instantiating a Go (`GOOS=wasip1`) or TinyGo (`-target=wasi`) module, `pg_tle` and `plv8` automatically provide `wasi_snapshot_preview1` and `wasi_unstable`:

| WASI Import | Behavior in `pl/v8-wasm` |
| :--- | :--- |
| `args_sizes_get`, `args_get` | Returns `0` arguments (`argc = 0`, `buf_size = 0`). |
| `environ_sizes_get`, `environ_get` | Returns `0` environment variables. |
| `clock_res_get`, `clock_time_get` | Returns nanosecond timestamp (`BigInt(Date.now()) * 1_000_000n`). |
| `fd_write` (and `env.__wasi_fd_write`) | Accepts scatter/gather `ciovec` arrays; captures UTF-8 output written to `stderr` (`fd = 2`) so Go `panic()` messages are included in the PostgreSQL `ERROR` report. |
| `fd_fdstat_get`, `fd_fdstat_set_flags` | Reports `CHARACTER_DEVICE` (`2`) for `fd <= 2` (`stdin`/`stdout`/`stderr`) and `EBADF` (`8`) otherwise. |
| `fd_prestat_get`, `fd_prestat_dir_name` | Returns `EBADF` (`8`) to cleanly terminate Go's `syscall/fs_wasip1.go` preopen directory scan during `_initialize()`. |
| `fd_read`, `fd_close`, `fd_seek`, `path_open` | Sandboxed no-op / `ESPIPE` (`29`) / `ENOENT` (`44`) (no host filesystem access). |
| `random_get` | Fills `memory[bufPtr .. bufPtr + bufLen]` with random bytes (required by Go runtime hash seed initialization in `_initialize()`). |
| `poll_oneoff`, `sched_yield` | Synchronous no-op returning `0`. |
| `proc_exit` | Throws a JS `Error('WASM proc_exit(code): <stderr>')` which translates to a PostgreSQL `ERROR` and evicts the instance for clean re-initialization on the next call. |

### 2.4 GC-Safe Linear Memory Management (`alloc` and `dealloc`)

Both Standard Go and TinyGo have garbage collectors. When PostgreSQL passes a `text`, `bytea`, or custom base type buffer into WebAssembly:
1. The host calls your exported `alloc(size uint32) uint32`.
2. If `alloc` simply returned `uint32(uintptr(unsafe.Pointer(&make([]byte, size)[0])))` without retaining a Go reference to the slice, Go's garbage collector could sweep the buffer before or during your exported function call.
3. **Solution**: Pin every host-allocated slice in a package-level `map[uint32][]byte` inside `alloc`, and delete it from the map inside `dealloc(ptr uint32, size uint32)` (which `pg_tle` calls in a `finally` block after every invocation).
4. Similarly, when returning a buffer from Go to PostgreSQL, copy the return bytes into a package-level slice (`var returnBuf []byte`) immediately before returning its pointer/length so the slice remains live while the host copies the bytes out of linear memory.

### 2.5 Returning Buffers: Packed `uint64` (`(len << 32) | ptr`) or Length-Prefixed `uint32`

`pg_tle` supports two primary buffer return conventions for `text`, `bytea`, and custom base types in Go:

1. **Packed `uint64` / `int64` (`(uint64(len) << 32) | uint64(ptr)`)**:
   ```go
   var returnBuf []byte

   func packReturnBuffer(payload []byte) uint64 {
       if len(payload) == 0 {
           returnBuf = []byte{0}
           ptr := uint32(uintptr(unsafe.Pointer(&returnBuf[0])))
           return uint64(ptr) // len = 0 in upper 32 bits, non-null ptr in lower 32 bits
       }
       if cap(returnBuf) < len(payload) {
           returnBuf = make([]byte, len(payload))
       } else {
           returnBuf = returnBuf[:len(payload)]
       }
       copy(returnBuf, payload)
       ptr := uint32(uintptr(unsafe.Pointer(&returnBuf[0])))
       return (uint64(uint32(len(payload))) << 32) | uint64(ptr)
   }
   ```
2. **Length-prefixed `uint32` pointer (`[u32_le(len), payload...]`)**:
   ```go
   func makeLenPrefixedBuffer(payload []byte) uint32 {
       total := 4 + len(payload)
       if cap(returnBuf) < total {
           returnBuf = make([]byte, total)
       } else {
           returnBuf = returnBuf[:total]
       }
       binary.LittleEndian.PutUint32(returnBuf[0:4], uint32(len(payload)))
       copy(returnBuf[4:], payload)
       return uint32(uintptr(unsafe.Pointer(&returnBuf[0])))
   }
   ```

---

## 3. Complete Step-by-Step Example (`main.go`)

### Step 1: Create `go.mod` and `main.go`

```bash
mkdir go_wasm_ext && cd go_wasm_ext
go mod init example.com/go_wasm_ext
```

Create `main.go` with scalar functions, `text` and `bytea` linear memory functions, a custom 8-byte PostgreSQL base type (`go_vec2i`), and PostgreSQL SPI query execution (`//go:wasmimport postgres spi_exec`):

```go
package main

import (
	"encoding/binary"
	"math"
	"strconv"
	"strings"
	"unsafe"
)

// ============================================================================
// 1. PostgreSQL Host Imports ("postgres" namespace)
// ============================================================================

//go:wasmimport postgres spi_exec
func hostSpiExec(sqlPtr uint32, sqlLen uint32, outPtr uint32, outCap uint32) int32

//go:wasmimport postgres elog_notice
func hostElogNotice(msgPtr uint32, msgLen uint32)

//go:wasmimport postgres elog_error
func hostElogError(msgPtr uint32, msgLen uint32)

func elogNotice(msg string) {
	if len(msg) == 0 {
		return
	}
	b := []byte(msg)
	hostElogNotice(uint32(uintptr(unsafe.Pointer(&b[0]))), uint32(len(b)))
}

func elogError(msg string) {
	b := []byte(msg)
	if len(b) == 0 {
		b = []byte("WASM error")
	}
	hostElogError(uint32(uintptr(unsafe.Pointer(&b[0]))), uint32(len(b)))
}

// ============================================================================
// 2. GC-Safe Linear Memory Allocator Exports (`alloc` / `dealloc`)
// ============================================================================

var pinnedAllocs = make(map[uint32][]byte)
var returnBuf []byte

//go:wasmexport alloc
func alloc(size uint32) uint32 {
	if size == 0 {
		size = 1
	}
	buf := make([]byte, size)
	ptr := uint32(uintptr(unsafe.Pointer(&buf[0])))
	pinnedAllocs[ptr] = buf
	return ptr
}

//go:wasmexport dealloc
func dealloc(ptr uint32, _ uint32) {
	delete(pinnedAllocs, ptr)
}

func readGuestBytes(ptr uint32, length uint32) []byte {
	if length == 0 || ptr == 0 {
		return nil
	}
	if buf, ok := pinnedAllocs[ptr]; ok && uint32(len(buf)) >= length {
		return buf[:length]
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(uintptr(ptr))), int(length))
}

func makeLenPrefixedBuffer(payload []byte) uint32 {
	total := 4 + len(payload)
	if cap(returnBuf) < total {
		returnBuf = make([]byte, total)
	} else {
		returnBuf = returnBuf[:total]
	}
	binary.LittleEndian.PutUint32(returnBuf[0:4], uint32(len(payload)))
	copy(returnBuf[4:], payload)
	return uint32(uintptr(unsafe.Pointer(&returnBuf[0])))
}

func packReturnBuffer(payload []byte) uint64 {
	if len(payload) == 0 {
		returnBuf = []byte{0}
		ptr := uint32(uintptr(unsafe.Pointer(&returnBuf[0])))
		return uint64(ptr)
	}
	if cap(returnBuf) < len(payload) {
		returnBuf = make([]byte, len(payload))
	} else {
		returnBuf = returnBuf[:len(payload)]
	}
	copy(returnBuf, payload)
	ptr := uint32(uintptr(unsafe.Pointer(&returnBuf[0])))
	return (uint64(uint32(len(payload))) << 32) | uint64(ptr)
}

// ============================================================================
// 3. Scalar Exports (int4, int8, float8, bool)
// ============================================================================

//go:wasmexport add_i32
func addI32(a int32, b int32) int32 {
	return a + b
}

//go:wasmexport fib_i64
func fibI64(n int64) int64 {
	if n <= 0 {
		return 0
	}
	if n == 1 {
		return 1
	}
	var a, b int64 = 0, 1
	for i := int64(2); i <= n; i++ {
		a, b = b, a+b
	}
	return b
}

//go:wasmexport hypot_f64
func hypotF64(x float64, y float64) float64 {
	return math.Sqrt(x*x + y*y)
}

//go:wasmexport is_prime_bool
func isPrimeBool(n int32) int32 {
	if n < 2 {
		return 0
	}
	if n == 2 {
		return 1
	}
	if n%2 == 0 {
		return 0
	}
	for d := int32(3); d*d <= n; d += 2 {
		if n%d == 0 {
			return 0
		}
	}
	return 1
}

// ============================================================================
// 4. Linear Memory Buffer Exports (`text` and `bytea`)
// ============================================================================

//go:wasmexport reverse_upper_text
func reverseUpperText(ptr uint32, length uint32) uint64 {
	input := string(readGuestBytes(ptr, length))
	runes := []rune(strings.ToUpper(input))
	for i, j := 0, len(runes)-1; i < j; i, j = i+1, j-1 {
		runes[i], runes[j] = runes[j], runes[i]
	}
	return packReturnBuffer([]byte(string(runes)))
}

//go:wasmexport xor_cipher_bytea
func xorCipherBytea(dataPtr uint32, dataLen uint32, keyPtr uint32, keyLen uint32) uint32 {
	data := readGuestBytes(dataPtr, dataLen)
	key := readGuestBytes(keyPtr, keyLen)
	if len(key) == 0 {
		return makeLenPrefixedBuffer(data)
	}
	out := make([]byte, len(data))
	for i, b := range data {
		out[i] = b ^ key[i%len(key)]
	}
	return makeLenPrefixedBuffer(out)
}

// ============================================================================
// 5. Custom PostgreSQL Base Type `go_vec2i` (8-byte 2D integer vector)
// ============================================================================

func parseVec2i(s string) (int32, int32, bool) {
	trimmed := strings.TrimSpace(s)
	if !strings.HasPrefix(trimmed, "(") || !strings.HasSuffix(trimmed, ")") {
		return 0, 0, false
	}
	inner := trimmed[1 : len(trimmed)-1]
	parts := strings.Split(inner, ",")
	if len(parts) != 2 {
		return 0, 0, false
	}
	x, err1 := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 32)
	y, err2 := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 32)
	if err1 != nil || err2 != nil {
		return 0, 0, false
	}
	return int32(x), int32(y), true
}

//go:wasmexport vec2i_in
func vec2iIn(ptr uint32, length uint32) uint32 {
	s := string(readGuestBytes(ptr, length))
	x, y, ok := parseVec2i(s)
	if !ok {
		elogError("invalid input syntax for type go_vec2i: \"" + s + "\"")
		return 0
	}
	var payload [8]byte
	binary.LittleEndian.PutUint32(payload[0:4], uint32(x))
	binary.LittleEndian.PutUint32(payload[4:8], uint32(y))
	return makeLenPrefixedBuffer(payload[:])
}

//go:wasmexport vec2i_out
func vec2iOut(ptr uint32, length uint32) uint32 {
	if length < 8 {
		elogError("corrupt go_vec2i binary length")
		return 0
	}
	b := readGuestBytes(ptr, 8)
	x := int32(binary.LittleEndian.Uint32(b[0:4]))
	y := int32(binary.LittleEndian.Uint32(b[4:8]))
	formatted := "(" + strconv.Itoa(int(x)) + "," + strconv.Itoa(int(y)) + ")"
	return makeLenPrefixedBuffer([]byte(formatted))
}

//go:wasmexport vec2i_add
func vec2iAdd(aPtr uint32, aLen uint32, bPtr uint32, bLen uint32) uint32 {
	if aLen < 8 || bLen < 8 {
		elogError("corrupt go_vec2i binary length")
		return 0
	}
	a := readGuestBytes(aPtr, 8)
	b := readGuestBytes(bPtr, 8)
	ax := int32(binary.LittleEndian.Uint32(a[0:4]))
	ay := int32(binary.LittleEndian.Uint32(a[4:8]))
	bx := int32(binary.LittleEndian.Uint32(b[0:4]))
	by := int32(binary.LittleEndian.Uint32(b[4:8]))
	var payload [8]byte
	binary.LittleEndian.PutUint32(payload[0:4], uint32(ax+bx))
	binary.LittleEndian.PutUint32(payload[4:8], uint32(ay+by))
	return makeLenPrefixedBuffer(payload[:])
}

//go:wasmexport vec2i_eq
func vec2iEq(aPtr uint32, aLen uint32, bPtr uint32, bLen uint32) int32 {
	if aLen < 8 || bLen < 8 {
		return 0
	}
	a := readGuestBytes(aPtr, 8)
	b := readGuestBytes(bPtr, 8)
	for i := 0; i < 8; i++ {
		if a[i] != b[i] {
			return 0
		}
	}
	return 1
}

//go:wasmexport vec2i_dot
func vec2iDot(aPtr uint32, aLen uint32, bPtr uint32, bLen uint32) int32 {
	if aLen < 8 || bLen < 8 {
		return 0
	}
	a := readGuestBytes(aPtr, 8)
	b := readGuestBytes(bPtr, 8)
	ax := int32(binary.LittleEndian.Uint32(a[0:4]))
	ay := int32(binary.LittleEndian.Uint32(a[4:8]))
	bx := int32(binary.LittleEndian.Uint32(b[0:4]))
	by := int32(binary.LittleEndian.Uint32(b[4:8]))
	return ax*bx + ay*by
}

// ============================================================================
// 6. PostgreSQL SPI Query Execution (`postgres.spi_exec`)
// ============================================================================

//go:wasmexport run_spi_query
func runSpiQuery(sqlPtr uint32, sqlLen uint32) uint32 {
	sql := string(readGuestBytes(sqlPtr, sqlLen))
	elogNotice("Executing SPI query from Go WASM: " + sql)
	outBuf := make([]byte, 4096)
	needed := hostSpiExec(sqlPtr, sqlLen, uint32(uintptr(unsafe.Pointer(&outBuf[0]))), uint32(len(outBuf)))
	if needed <= 0 {
		return makeLenPrefixedBuffer([]byte("[]"))
	}
	if int(needed) > len(outBuf) {
		outBuf = make([]byte, needed)
		hostSpiExec(sqlPtr, sqlLen, uint32(uintptr(unsafe.Pointer(&outBuf[0]))), uint32(len(outBuf)))
	} else {
		outBuf = outBuf[:needed]
	}
	return makeLenPrefixedBuffer(outBuf)
}

func main() {}
```

---

### Step 2: Compile with Standard Go or TinyGo

Choose any of the three supported compilation commands:

#### Option 1: Standard Go (`GOOS=wasip1 GOARCH=wasm`)

```bash
GOOS=wasip1 GOARCH=wasm go build \
  -buildmode=c-shared \
  -ldflags="-s -w" \
  -o go_wasm_ext.wasm \
  main.go
```

#### Option 2: TinyGo WASI Reactor (`-target=wasi`)

```bash
tinygo build \
  -target=wasi \
  -buildmode=c-shared \
  -no-debug \
  -o go_wasm_ext.wasm \
  main.go
```

#### Option 3: TinyGo Freestanding (`-target=wasm-unknown`)

```bash
tinygo build \
  -target=wasm-unknown \
  -no-debug \
  -o go_wasm_ext.wasm \
  main.go
```

---

### Step 3: Create `manifest.json` and Package with `tle-pack wasm`

Create `manifest.json`:

```json
{
  "types": [
    {
      "schema": "public",
      "name": "go_vec2i",
      "internallength": 8,
      "alignment": "int4",
      "storage": "plain",
      "input_export": "vec2i_in",
      "output_export": "vec2i_out",
      "operators": [
        {
          "name": "go_vec2i_add",
          "export": "vec2i_add",
          "nargs": 2,
          "returns": "public.go_vec2i",
          "operator": "+"
        },
        {
          "name": "go_vec2i_eq",
          "export": "vec2i_eq",
          "nargs": 2,
          "returns": "boolean",
          "operator": "="
        },
        {
          "name": "go_vec2i_dot",
          "export": "vec2i_dot",
          "nargs": 2,
          "returns": "int4"
        }
      ]
    }
  ],
  "functions": [
    {
      "name": "go_add_i32",
      "args": ["int4", "int4"],
      "returns": "int4",
      "export": "add_i32",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "go_fib_i64",
      "args": ["int8"],
      "returns": "int8",
      "export": "fib_i64",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "go_hypot_f64",
      "args": ["float8", "float8"],
      "returns": "float8",
      "export": "hypot_f64",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "go_is_prime",
      "args": ["int4"],
      "returns": "boolean",
      "export": "is_prime_bool",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "go_reverse_upper",
      "args": ["text"],
      "returns": "text",
      "export": "reverse_upper_text",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "go_xor_cipher",
      "args": ["bytea", "bytea"],
      "returns": "bytea",
      "export": "xor_cipher_bytea",
      "volatility": "IMMUTABLE"
    },
    {
      "name": "go_spi_query",
      "args": ["text"],
      "returns": "text",
      "export": "run_spi_query",
      "volatility": "VOLATILE"
    }
  ]
}
```

Package the `.wasm` binary into a deployable SQL file with `tle-pack wasm`:

```bash
pg_tle/tools/tle-pack wasm ./go_wasm_ext.wasm \
  --name go_wasm_ext \
  --version 1.0.0 \
  --description "Go/TinyGo WebAssembly extension for PostgreSQL" \
  --manifest ./manifest.json \
  --output ./go_wasm_ext.sql
```

> **Automatic Export Discovery (`--manifest` omitted):**
> If your Go/TinyGo module only exports scalar numerical functions (`int32`, `int64`, `float32`, `float64`), you can omit `--manifest` completely. `tle-pack wasm` parses the `.wasm` binary sections, filters out compiler/runtime exports (`_initialize`, `_start`, `alloc`, `dealloc`, `malloc`, `free`, `calloc`, `realloc`, `syscall.*`, `asyncify_*`), and generates SQL definitions for every `//go:wasmexport` / `//export` function automatically.

---

### Step 4: Install and Execute in PostgreSQL

```sql
\i go_wasm_ext.sql
CREATE EXTENSION go_wasm_ext;

-- 1. Scalar functions
SELECT
  go_add_i32(125, 225) AS go_add,
  go_fib_i64(50) AS go_fib_50,
  go_hypot_f64(3.0, 4.0) AS go_hypot,
  go_is_prime(97) AS prime_97,
  go_is_prime(99) AS prime_99;

-- 2. Linear memory text and bytea functions
SELECT
  go_reverse_upper('Standard Go WASI Preview 1!') AS go_rev_upper,
  convert_from(
    go_xor_cipher(
      go_xor_cipher('Standard Go Bytea Payload!'::bytea, 'gokey'::bytea),
      'gokey'::bytea
    ),
    'UTF8'
  ) AS go_xor_rt;

-- 3. Custom base type go_vec2i and operators (+, =)
CREATE TEMP TABLE go_vecs (id int PRIMARY KEY, v go_vec2i NOT NULL);
INSERT INTO go_vecs VALUES (1, '(15,-10)'::go_vec2i), (2, '(25,30)'::go_vec2i);

SELECT
  v1.v::text AS v1,
  v2.v::text AS v2,
  (v1.v + v2.v)::text AS v_sum,
  (v1.v = '(15,-10)'::go_vec2i) AS eq_true,
  go_vec2i_dot(v1.v, v2.v) AS dot_prod
FROM go_vecs v1
JOIN go_vecs v2 ON v1.id = 1 AND v2.id = 2;

-- 4. Execute SQL inside Go WASM via postgres.spi_exec (including nested WASM calls)
SELECT go_spi_query('SELECT id, v::text AS vec, go_reverse_upper(''nested'') AS nested FROM go_vecs ORDER BY id');

-- 5. Verify the registered WASM package in plv8.packages, plv8.modules, and pgtle.modules
SELECT p.name, p.version, p.entry_point, m.path, octet_length(m.bytecode) AS wasm_bytes, m.is_trusted
FROM plv8.packages p
JOIN plv8.modules m ON m.package_name = p.name AND m.package_version = p.version
WHERE p.name = 'go_wasm_ext';
```

---

## 4. Importing Go/TinyGo WASM Modules Directly in `LANGUAGE plv8`

When `pgtle.install_wasm_extension()` (or `pgwasm-pack`) registers your `.wasm` binary, it stores the module in `plv8.packages` / `plv8.modules` (`entry_point = 'index.wasm'`, `path = 'index.wasm'`), `pgtle.modules`, and `public.plv8_wasm_modules` under the `tle:<extension_name>` (or `plv8:<extension_name>`) specifier. You can import any Go, TinyGo, or Rust WebAssembly module directly inside a JavaScript `LANGUAGE plv8` stored procedure using ES module `import` or CommonJS `plv8.require()`:

```sql
CREATE OR REPLACE FUNCTION plv8_call_go_wasm(a int, b int)
RETURNS int LANGUAGE plv8 AS $$
  import wasm, { memory } from 'tle:go_wasm_ext';
  return wasm.add_i32(a, b);
$$;

SELECT plv8_call_go_wasm(40, 60);
-- Returns: 100
```

When `tle:go_wasm_ext` is imported in `plv8`, the engine automatically attaches the WASI Preview 1 and instance-bound `postgres` (`spi_exec`, `elog_notice`, `elog_error`) host import namespaces and runs `_initialize()` before returning the module exports.
