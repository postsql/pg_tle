#!/usr/bin/env python3
"""pgwasm-pack (pgwasm_pack.py): Streamlined Rust #[wasm_bindgen] -> pl/v8-wasm bundler and SQL generator.

Supports two workflows:
  1. Full Crate Build (--crate-dir):
     Runs `cargo build --target wasm32-unknown-unknown --release` and
     `wasm-bindgen --target web --no-typescript`, transforms the ES module glue
     into a synchronous two-phase PLV8 factory, parses `#[wasm_bindgen] pub fn`
     signatures from `src/lib.rs`, and emits a self-contained SQL bundle.

  2. Pre-built Glue + WASM (--wasm and --js / --glue-js):
     Transforms an existing `wasm-bindgen` `.js` glue file and `_bg.wasm` binary
     into a self-contained SQL bundle (either registering in `public.plv8_wasm_modules`
     or calling `pgtle.install_wasm_extension()` when `--as-extension` is passed).
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

__version__ = "1.6.0"

RUST_TO_PG_TYPE: Dict[str, str] = {
    "i8": "smallint",
    "i16": "smallint",
    "i32": "integer",
    "i64": "bigint",
    "isize": "integer",
    "u8": "smallint",
    "u16": "integer",
    "u32": "bigint",
    "u64": "bigint",
    "usize": "bigint",
    "f32": "real",
    "f64": "double precision",
    "bool": "boolean",
    "&str": "text",
    "str": "text",
    "String": "text",
    "&String": "text",
    "&[u8]": "bytea",
    "Vec<u8>": "bytea",
    "&Vec<u8>": "bytea",
    "JsValue": "jsonb",
    "()": "void",
}


def sql_dollar_quote(text: str, tag_hint: str = "plv8_wasm_glue") -> str:
  """Wraps `text` in a collision-free PostgreSQL dollar-quoted literal."""
  tag = tag_hint
  counter = 0
  while f"${tag}$" in text:
    counter += 1
    tag = f"{tag_hint}_{counter}"
  return f"${tag}${text}${tag}$"


def sql_literal(val: Optional[str]) -> str:
  """Escapes a string as a standard SQL single-quoted literal or NULL."""
  if val is None:
    return "NULL"
  return "'" + str(val).replace("'", "''") + "'"


def _split_top_level_comma(text: str) -> List[str]:
  """Splits `text` by commas at nesting depth 0 (`<...>`, `(...)`, `[...]`)."""
  parts: List[str] = []
  cur: List[str] = []
  depth = 0
  for ch in text:
    if ch in "<([":
      depth += 1
    elif ch in ">)]" and depth > 0:
      depth -= 1
    elif ch == "," and depth == 0:
      parts.append("".join(cur).strip())
      cur = []
      continue
    cur.append(ch)
  tail = "".join(cur).strip()
  if tail:
    parts.append(tail)
  return parts


def map_rust_type(rust_ty: str) -> str:
  """Maps a Rust parameter or return type to its PostgreSQL SQL type."""
  rust_ty = rust_ty.strip()
  if not rust_ty:
    return "void"
  # Unwrap Result<T, E> and Option<T> (including nested generic error types)
  while True:
    m_gen = re.match(r"^(?:[\w:]+::)?(Result|Option)<\s*(.+)\s*>$", rust_ty, re.DOTALL)
    if m_gen:
      wrapper_kind = m_gen.group(1)
      inner = m_gen.group(2).strip()
      top_args = _split_top_level_comma(inner)
      if wrapper_kind == "Result" and len(top_args) >= 1:
        rust_ty = top_args[0].strip()
        continue
      if wrapper_kind == "Option" and len(top_args) == 1:
        rust_ty = top_args[0].strip()
        continue
    break
  # Normalize lifetime annotations and reference spacing (`&'a str` -> `&str`, `& [u8]` -> `&[u8]`)
  rust_ty = re.sub(r"&\s*'[A-Za-z0-9_]+\s+", "&", rust_ty)
  rust_ty = re.sub(r"&\s*mut\s+", "&", rust_ty)
  rust_ty = re.sub(r"&\s+", "&", rust_ty)
  rust_ty = re.sub(r"\s+", " ", rust_ty)
  if rust_ty in RUST_TO_PG_TYPE:
    return RUST_TO_PG_TYPE[rust_ty]
  raise ValueError(f"Unsupported Rust type for automatic SQL mapping: {rust_ty!r}")


def strip_rust_comments(rs_source: str) -> str:
  """Strips `//` line comments and `/* ... */` block comments outside string/char literals."""
  comment_re = re.compile(
      r'r(?P<raw_hashes>#*)"[\s\S]*?"(?P=raw_hashes)'
      r'|"(?:\\.|[^"\\])*"'
      r"|'(?:\\.|[^'\\\n])'"
      r"|(?P<comment>//[^\n]*|/\*[\s\S]*?\*/)"
  )
  return comment_re.sub(
      lambda m: "" if m.group("comment") is not None else m.group(0),
      rs_source,
  )


def parse_rust_exports(rs_source: str) -> List[Tuple[str, List[Tuple[str, str]], str]]:
  """Extracts `#[wasm_bindgen] pub fn name(args...) -> ret` signatures."""
  cleaned_source = strip_rust_comments(rs_source)
  pattern = re.compile(
      r"#\[wasm_bindgen[^\]]*\]\s*(?:#\[[^\]]*\]\s*)*pub(?:\s*\([^)]*\))?\s+(?:const\s+)?(?:unsafe\s+)?(?:extern\s+\"[^\"]*\"\s+)?fn\s+([A-Za-z0-9_]+)\s*\(((?:[^()]|\([^()]*\))*)\)\s*(?:->\s*([^{]+))?\s*\{",
      re.MULTILINE | re.DOTALL,
  )
  functions: List[Tuple[str, List[Tuple[str, str]], str]] = []
  for match in pattern.finditer(cleaned_source):
    fn_name = match.group(1).strip()
    raw_args = match.group(2).strip()
    raw_ret = (match.group(3) or "").strip()

    args: List[Tuple[str, str]] = []
    if raw_args:
      for part in _split_top_level_comma(raw_args):
        part = re.sub(r"^(?:#\[[^\]]*\]\s*)+", "", part).strip()
        if not part or ":" not in part:
          continue
        arg_name, arg_ty = [x.strip() for x in part.split(":", 1)]
        if arg_name.startswith("mut "):
          arg_name = arg_name[4:].strip()
        args.append((arg_name, map_rust_type(arg_ty)))

    ret_pg = map_rust_type(raw_ret) if raw_ret else "void"
    functions.append((fn_name, args, ret_pg))
  return functions


def _resolve_workspace_version(crate_dir: pathlib.Path) -> Optional[str]:
  """Searches ancestor `Cargo.toml` files for `[workspace.package].version`."""
  for parent in crate_dir.resolve().parents:
    ws_toml = parent / "Cargo.toml"
    if not ws_toml.is_file():
      continue
    raw = ws_toml.read_text(encoding="utf-8")
    try:
      import tomllib  # Python 3.11+

      data = tomllib.loads(raw)
      ws_ver = data.get("workspace", {}).get("package", {}).get("version")
      if isinstance(ws_ver, str) and ws_ver:
        return ws_ver
    except Exception:
      m_ws = re.search(
          r'\[workspace\.package\][^\[]*?^\s*version\s*=\s*"([^"]+)"',
          raw,
          re.MULTILINE | re.DOTALL,
      )
      if m_ws:
        return m_ws.group(1)
  return None


def infer_crate_metadata(
    crate_dir: pathlib.Path,
) -> Tuple[Optional[str], Optional[str], Optional[str]]:
  """Reads Cargo.toml in `crate_dir` and returns `(package_name, lib_name, version)`."""
  cargo_toml = crate_dir / "Cargo.toml"
  if not cargo_toml.is_file():
    return None, None, None
  raw_toml = cargo_toml.read_text(encoding="utf-8")
  try:
    import tomllib  # Python 3.11+

    data = tomllib.loads(raw_toml)
    pkg = data.get("package", {})
    lib = data.get("lib", {})
    raw_pkg_name = pkg.get("name")
    pkg_name = raw_pkg_name if isinstance(raw_pkg_name, str) else None
    raw_lib_name = lib.get("name")
    lib_name = (
        raw_lib_name
        if isinstance(raw_lib_name, str)
        else (pkg_name.replace("-", "_") if pkg_name else None)
    )
    raw_ver = pkg.get("version")
    if isinstance(raw_ver, str):
      version: Optional[str] = raw_ver
    elif isinstance(raw_ver, dict) and raw_ver.get("workspace"):
      version = _resolve_workspace_version(crate_dir)
    else:
      version = None
    return pkg_name, lib_name, version
  except Exception:
    pkg_sec = re.search(r"\[package\]([^\[]*)", raw_toml, re.DOTALL)
    pkg_body = pkg_sec.group(1) if pkg_sec else raw_toml
    lib_sec = re.search(r"\[lib\]([^\[]*)", raw_toml, re.DOTALL)
    lib_body = lib_sec.group(1) if lib_sec else ""
    pkg_name_m = re.search(r'(?m)^\s*name\s*=\s*"([^"]+)"', pkg_body)
    lib_name_m = re.search(r'(?m)^\s*name\s*=\s*"([^"]+)"', lib_body)
    ver_m = re.search(r'(?m)^\s*version\s*=\s*"([^"]+)"', pkg_body)
    pkg_name = pkg_name_m.group(1) if pkg_name_m else None
    lib_name = (
        lib_name_m.group(1)
        if lib_name_m
        else (pkg_name.replace("-", "_") if pkg_name else None)
    )
    if ver_m:
      version = ver_m.group(1)
    elif re.search(r"(?m)^\s*version\.workspace\s*=\s*true", pkg_body):
      version = _resolve_workspace_version(crate_dir)
    else:
      version = None
    return pkg_name, lib_name, version


def locate_compiled_wasm(
    crate_dir: pathlib.Path,
    candidate_stems: List[str],
) -> pathlib.Path:
  """Finds `<stem>.wasm` across `$CARGO_TARGET_DIR`, `<crate_dir>/target`, or workspace `<root>/target`."""
  search_release_dirs: List[pathlib.Path] = []
  env_target = os.environ.get("CARGO_TARGET_DIR")
  if env_target:
    search_release_dirs.append(
        pathlib.Path(env_target).resolve() / "wasm32-unknown-unknown" / "release"
    )
  search_release_dirs.append(crate_dir / "target" / "wasm32-unknown-unknown" / "release")
  for parent in crate_dir.resolve().parents:
    if (parent / "Cargo.toml").is_file():
      cand_dir = parent / "target" / "wasm32-unknown-unknown" / "release"
      if cand_dir not in search_release_dirs:
        search_release_dirs.append(cand_dir)

  for rel_dir in search_release_dirs:
    for stem in candidate_stems:
      cand = rel_dir / f"{stem}.wasm"
      if cand.is_file():
        return cand

  checked_dirs = ", ".join(str(d) for d in search_release_dirs)
  raise FileNotFoundError(
      f"Could not find compiled WASM artifact in [{checked_dirs}] (checked stems: {candidate_stems})"
  )


def transform_wasm_bindgen_glue(raw_js: str, exported_fn_names: List[str]) -> str:
  """Transforms `wasm-bindgen --target web` ES module glue into a synchronous PLV8 factory body."""
  if "__wbg_get_imports:" in raw_js and "__wbg_set_wasm:" in raw_js:
    return raw_js

  js = raw_js
  discovered_exports = set(exported_fn_names)
  for m in re.finditer(r"^\s*export\s+function\s+([A-Za-z0-9_$]+)", js, flags=re.MULTILINE):
    discovered_exports.add(m.group(1))
  for m in re.finditer(r"^\s*export\s*\{([^}]*)\}\s*;?\s*$", js, flags=re.MULTILINE):
    for item in m.group(1).split(","):
      parts = [p.strip() for p in item.strip().split(" as ") if p.strip()]
      if parts:
        local_name = parts[0]
        export_alias = parts[-1]
        if export_alias not in ("default", "initSync", "__wbg_init"):
          discovered_exports.add(local_name)

  # Remove `export default ...` and `export { ... }` lines
  js = re.sub(r"^\s*export\s+default\s+[^;]+;\s*$", "", js, flags=re.MULTILINE)
  js = re.sub(r"^\s*export\s*\{[^}]*\}\s*;?\s*$", "", js, flags=re.MULTILINE)

  # Replace `import.meta.url` / `import.meta` inside unused __wbg_init so V8 `new Function(...)`
  # does not fail with `SyntaxError: Cannot use 'import.meta' outside a module`
  js = js.replace("import.meta.url", '""')
  js = re.sub(r"\bimport\.meta\b", "({})", js)

  # Convert `export function foo` / `export class Foo` / `export const ...` to local declarations
  js = re.sub(
      r"^(\s*)export\s+(function|class|const|let|var)\s+",
      r"\1\2 ",
      js,
      flags=re.MULTILINE,
  )

  exports_entries = [
      f"{name}: (typeof {name} !== 'undefined') ? {name} : function() {{ return wasm[{name!r}].apply(wasm, arguments); }}"
      for name in sorted(discovered_exports)
  ]
  exports_map = ", ".join(exports_entries)

  footer = f"""
return {{
  __wbg_get_imports: (typeof __wbg_get_imports === 'function')
    ? __wbg_get_imports
    : function() {{ return {{}}; }},
  __wbg_set_wasm: function(exportsObj, instanceObj) {{
    if (typeof __wbg_finalize_init === 'function' && instanceObj) {{
      __wbg_finalize_init(instanceObj);
    }} else {{
      wasm = exportsObj;
      if (typeof cachedDataViewMemory0 !== 'undefined') cachedDataViewMemory0 = null;
      if (typeof cachedUint8ArrayMemory0 !== 'undefined') cachedUint8ArrayMemory0 = null;
      if (typeof cachedInt32Memory0 !== 'undefined') cachedInt32Memory0 = null;
      if (typeof cachedUint8Memory0 !== 'undefined') cachedUint8Memory0 = null;
      if (typeof wasm.__wbindgen_start === 'function') {{
        wasm.__wbindgen_start();
      }}
    }}
  }},
  exports: {{ {exports_map} }}
}};
"""
  return js + "\n" + footer


convert_js_glue = transform_wasm_bindgen_glue


def generate_sql_bundle(
    module_name: str,
    version: str,
    wasm_bytes: bytes,
    transformed_glue_js: str,
    functions: List[Tuple[str, List[Tuple[str, str]], str]],
    as_extension: bool = False,
    create_extension: bool = False,
) -> str:
  wasm_hex = wasm_bytes.hex()
  if as_extension or create_extension:
    manifest_funcs = []
    for fn_name, args, ret_pg in functions:
      manifest_funcs.append({
          "name": fn_name,
          "export": fn_name,
          "args": [{"name": a_name, "type": a_ty} for a_name, a_ty in args],
          "returns": ret_pg,
          "volatility": "VOLATILE" if "spi" in fn_name else "IMMUTABLE",
      })
    manifest = {
        "glue_js": transformed_glue_js.strip(),
        "functions": manifest_funcs,
    }
    manifest_json = json.dumps(manifest, indent=2)
    manifest_dq = sql_dollar_quote(manifest_json, "wasm_manifest")
    ext_lines = [
        f"-- Auto-generated by pgwasm_pack.py (pg_tle extension mode) for: {module_name}@{version}",
        "CREATE EXTENSION IF NOT EXISTS pg_tle;",
        "CREATE EXTENSION IF NOT EXISTS plv8;",
        "SELECT pgtle.install_wasm_extension(",
        f"  {sql_literal(module_name)},",
        f"  {sql_literal(version)},",
        f"  {sql_literal(f'Rust wasm-bindgen extension {module_name}')},",
        f"  pg_catalog.decode('{wasm_hex}', 'hex'),",
        f"  {manifest_dq}::jsonb,",
        "  NULL",
        ");",
        "",
    ]
    if create_extension:
      ext_lines.append(f'CREATE EXTENSION IF NOT EXISTS "{module_name}";')
      ext_lines.append("")
    return "\n".join(ext_lines)

  glue_dq = sql_dollar_quote(transformed_glue_js.strip(), "plv8_wasm_glue")
  mod_lit = sql_literal(module_name)
  ver_lit = sql_literal(version)
  lines = [
      f"-- Auto-generated by pgwasm_pack.py for module: {module_name}",
      "CREATE EXTENSION IF NOT EXISTS pg_tle;",
      "CREATE EXTENSION IF NOT EXISTS plv8;",
      "SELECT pgtle.bootstrap_wasm_engine();",
      "INSERT INTO public.plv8_wasm_modules (module_name, wasm_bytecode, glue_js)",
      "VALUES (",
      f"  {mod_lit},",
      f"  decode('{wasm_hex}', 'hex'),",
      f"  {glue_dq}",
      ")",
      "ON CONFLICT (module_name) DO UPDATE",
      "SET wasm_bytecode = EXCLUDED.wasm_bytecode,",
      "    glue_js = EXCLUDED.glue_js,",
      "    installed_at = clock_timestamp();",
      "",
      "DO $plv8_wasm_cat$",
      "BEGIN",
      "  IF pg_catalog.to_regclass('pgtle.modules') IS NOT NULL THEN",
      "    INSERT INTO pgtle.modules (module_name, version, source_code, bytecode, dependencies, is_trusted)",
      f"    SELECT {mod_lit}, {ver_lit}, COALESCE(w.glue_js, ''), w.wasm_bytecode, NULL, true",
      "    FROM public.plv8_wasm_modules w",
      f"    WHERE w.module_name = {mod_lit}",
      "    ON CONFLICT (module_name, version) DO UPDATE",
      "    SET source_code = EXCLUDED.source_code,",
      "        bytecode = EXCLUDED.bytecode,",
      "        dependencies = EXCLUDED.dependencies,",
      "        is_trusted = EXCLUDED.is_trusted;",
      "  END IF;",
      "  IF pg_catalog.to_regclass('plv8.packages') IS NOT NULL",
      "     AND pg_catalog.to_regclass('plv8.modules') IS NOT NULL THEN",
      "    INSERT INTO plv8.packages (name, version, entry_point, dependencies)",
      f"    VALUES ({mod_lit}, {ver_lit}, 'index.wasm', '{{}}'::jsonb)",
      "    ON CONFLICT (name, version) DO UPDATE",
      "    SET entry_point = EXCLUDED.entry_point,",
      "        updated_at = NOW();",
      "    INSERT INTO plv8.modules (path, package_name, package_version, source, bytecode, requires, is_trusted)",
      f"    SELECT 'index.wasm', {mod_lit}, {ver_lit}, NULLIF(w.glue_js, ''), w.wasm_bytecode, NULL, true",
      "    FROM public.plv8_wasm_modules w",
      f"    WHERE w.module_name = {mod_lit}",
      "    ON CONFLICT (package_name, package_version, path) WHERE package_name IS NOT NULL DO UPDATE",
      "    SET source = EXCLUDED.source,",
      "        bytecode = EXCLUDED.bytecode,",
      "        is_trusted = true,",
      "        updated_at = NOW();",
      "  END IF;",
      "END;",
      "$plv8_wasm_cat$;",
      "",
  ]

  for fn_name, args, ret_pg in functions:
    arg_sig = ", ".join(f"{a_name} {a_ty}" for a_name, a_ty in args)
    fn_cfg = json.dumps({"module": module_name, "export": fn_name}, indent=2)
    lines.extend([
        f"CREATE OR REPLACE FUNCTION public.{fn_name}({arg_sig})",
        f"RETURNS {ret_pg}",
        'LANGUAGE "pl/v8-wasm" STRICT AS $$',
        fn_cfg,
        "$$;",
        "",
    ])
  return "\n".join(lines)


def sync_wasm_bindgen_version(crate_dir: pathlib.Path) -> None:
  """Ensures the crate's wasm-bindgen version matches the installed wasm-bindgen CLI."""
  if not shutil.which("wasm-bindgen"):
    return
  res = subprocess.run(
      ["wasm-bindgen", "--version"],
      capture_output=True,
      text=True,
      check=False,
  )
  parts = res.stdout.strip().split()
  if res.returncode == 0 and len(parts) >= 2:
    cli_version = parts[1].strip()
    subprocess.run(
        ["cargo", "update", "-p", "wasm-bindgen", "--precise", cli_version],
        cwd=crate_dir,
        capture_output=True,
        check=False,
    )


def build_arg_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
      prog="pgwasm-pack",
      description="Build and package a Rust #[wasm_bindgen] crate for pl/v8-wasm",
  )
  parser.add_argument(
      "-V",
      "--tool-version",
      action="version",
      version=f"%(prog)s {__version__}",
      help="Print the pgwasm-pack tool version and exit.",
  )
  parser.add_argument("--crate-dir", help="Path to the Rust crate directory")
  parser.add_argument(
      "--wasm",
      help="Path to pre-built _bg.wasm file (when not using --crate-dir)",
  )
  parser.add_argument(
      "--js",
      "--glue-js",
      dest="js",
      help="Path to pre-built wasm-bindgen .js file (when not using --crate-dir)",
  )
  parser.add_argument(
      "--src",
      help="Optional path to src/lib.rs for signature extraction with --wasm/--js",
  )
  parser.add_argument(
      "--manifest",
      "-m",
      help="Optional path to manifest.json for function extraction with --wasm/--js",
  )
  parser.add_argument(
      "--module-name",
      "--name",
      "-n",
      dest="module_name",
      help="Module/extension name (default: inferred from Cargo.toml, manifest, or WASM stem)",
  )
  parser.add_argument(
      "--version",
      "-v",
      help="Extension version (default: inferred from Cargo.toml/manifest or 1.0.0)",
  )
  parser.add_argument(
      "--as-extension",
      action="store_true",
      help="Emit pgtle.install_wasm_extension() bundle",
  )
  parser.add_argument(
      "--create-extension",
      action="store_true",
      help="Append CREATE EXTENSION IF NOT EXISTS <name>; when --as-extension is enabled",
  )
  parser.add_argument(
      "--out-sql",
      "--output",
      "--out",
      "-o",
      dest="out_sql",
      help="Output SQL file path (defaults to stdout if omitted or '-')",
  )
  return parser


def main(argv: Optional[List[str]] = None) -> int:
  raw_args = list(sys.argv[1:] if argv is None else argv)
  if raw_args in (["--version"], ["-V"], ["--tool-version"]):
    print(f"pgwasm-pack {__version__}")
    return 0

  parser = build_arg_parser()
  args = parser.parse_args(raw_args)

  functions: List[Tuple[str, List[Tuple[str, str]], str]] = []
  inferred_name: Optional[str] = None
  inferred_version: Optional[str] = None

  if args.crate_dir:
    crate_dir = pathlib.Path(args.crate_dir).resolve()
    if not crate_dir.is_dir():
      raise FileNotFoundError(f"Crate directory not found: {crate_dir}")
    if not shutil.which("cargo"):
      raise RuntimeError("Required tool 'cargo' not found on PATH.")
    if not shutil.which("wasm-bindgen"):
      raise RuntimeError("Required tool 'wasm-bindgen' not found on PATH.")

    pkg_name, lib_name, cargo_ver = infer_crate_metadata(crate_dir)
    inferred_name = (pkg_name or crate_dir.name).replace("-", "_")
    inferred_version = cargo_ver

    module_name = args.module_name or inferred_name
    rs_path = crate_dir / "src" / "lib.rs"
    if rs_path.is_file():
      functions = parse_rust_exports(rs_path.read_text(encoding="utf-8"))
    sync_wasm_bindgen_version(crate_dir)
    subprocess.run(
        ["cargo", "build", "--target", "wasm32-unknown-unknown", "--release"],
        cwd=crate_dir,
        check=True,
    )
    candidate_stems: List[str] = []
    for raw_cand in (
        lib_name,
        inferred_name,
        pkg_name,
        pkg_name.replace("-", "_") if pkg_name else None,
        module_name,
        module_name.replace("-", "_"),
        crate_dir.name.replace("-", "_"),
    ):
      if raw_cand and raw_cand not in candidate_stems:
        candidate_stems.append(raw_cand)

    wasm_input = locate_compiled_wasm(crate_dir, candidate_stems)

    pkg_dir = crate_dir / "pkg"
    pkg_dir.mkdir(exist_ok=True)
    subprocess.run(
        [
            "wasm-bindgen",
            "--target",
            "web",
            "--no-typescript",
            "--out-dir",
            str(pkg_dir),
            str(wasm_input),
        ],
        cwd=crate_dir,
        check=True,
    )
    bg_wasm_path = pkg_dir / f"{wasm_input.stem}_bg.wasm"
    glue_js_path = pkg_dir / f"{wasm_input.stem}.js"
  elif args.wasm and args.js:
    bg_wasm_path = pathlib.Path(args.wasm).resolve()
    glue_js_path = pathlib.Path(args.js).resolve()
    if not bg_wasm_path.is_file():
      raise FileNotFoundError(f"WASM file not found: {bg_wasm_path}")
    if not glue_js_path.is_file():
      raise FileNotFoundError(f"JS glue file not found: {glue_js_path}")

    stem = bg_wasm_path.stem
    if stem.endswith("_bg"):
      stem = stem[:-3]
    inferred_name = stem.replace("-", "_")

    if args.src and pathlib.Path(args.src).is_file():
      functions = parse_rust_exports(pathlib.Path(args.src).read_text(encoding="utf-8"))
    elif args.manifest and pathlib.Path(args.manifest).is_file():
      mdata = json.loads(pathlib.Path(args.manifest).read_text(encoding="utf-8"))
      if mdata.get("name"):
        inferred_name = str(mdata["name"])
      if mdata.get("version"):
        inferred_version = str(mdata["version"])
      for f_entry in mdata.get("functions", []):
        fn_name = f_entry.get("name") or f_entry.get("sql_name") or f_entry.get("export")
        fn_args: List[Tuple[str, str]] = []
        for idx, a_entry in enumerate(f_entry.get("args", [])):
          if isinstance(a_entry, dict):
            fn_args.append((a_entry.get("name") or f"arg{idx+1}", a_entry.get("type", "int4")))
          else:
            fn_args.append((f"arg{idx+1}", str(a_entry)))
        ret_pg = f_entry.get("returns") or f_entry.get("result") or "int4"
        functions.append((fn_name, fn_args, ret_pg))
  else:
    parser.error("Must specify either --crate-dir or both --wasm and --js")

  module_name = args.module_name or inferred_name or "wasm_module"
  version = args.version or inferred_version or "1.0.0"

  exported_names = [fn[0] for fn in functions]
  wasm_bytes = bg_wasm_path.read_bytes()
  raw_glue = glue_js_path.read_text(encoding="utf-8")
  transformed_glue = transform_wasm_bindgen_glue(raw_glue, exported_names)

  sql_bundle = generate_sql_bundle(
      module_name,
      version,
      wasm_bytes,
      transformed_glue,
      functions,
      as_extension=args.as_extension,
      create_extension=args.create_extension,
  )
  if args.out_sql and args.out_sql != "-":
    out_path = pathlib.Path(args.out_sql).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(sql_bundle, encoding="utf-8")
    print(
        f"Generated SQL bundle: {out_path} ({len(wasm_bytes)} bytes WASM, {len(functions)} SQL UDFs)"
    )
  else:
    sys.stdout.write(sql_bundle)
  return 0


if __name__ == "__main__":
  sys.exit(main())
