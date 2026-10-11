#!/usr/bin/env python3
"""tle-pack: CLI Bundler & Packaging Tool for pg_tle JS Modules and WASM Extensions.

Usage examples:
  # 1. Pack an npm / ES / CommonJS package directory or entry file into pgtle.install_module() calls:
  tle-pack js ./my_pkg -o my_pkg.sql --compile-bytecode --as-extension

  # 2. Pack a .wasm binary into a pgtle.install_wasm_extension() SQL script (auto-introspecting exports
  #    from the WebAssembly Type/Function/Export sections or merging with a manifest JSON):
  tle-pack wasm ./suite.wasm --name wasm_suite --version 1.0.0 --manifest ./manifest.json -o wasm_suite.sql
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import posixpath
import re
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

__version__ = "1.6.0"

WASM_MAGIC = b"\x00asm\x01\x00\x00\x00"

WASM_VALTYPE_TO_PG: Dict[int, str] = {
    0x7F: "int4",    # i32
    0x7E: "int8",    # i64
    0x7D: "float4",  # f32
    0x7C: "float8",  # f64
}

# Regex matching JS comments and string/template literals (ignored during import rewriting)
# or ES static imports/re-exports, dynamic import(), and CommonJS require().
# Captures the module specifier in group 'spec'.
IMPORT_SPEC_RE = re.compile(
    r"""(?x)
    (?P<comment>//[^\n]*|/\*[\s\S]*?\*/)
    |
    (?:
        \bimport\s+(?:[A-Za-z0-9_$*,\s{}]*?\bfrom\s+)?
      | \bexport\s+(?:\*(?:\s+as\s+[A-Za-z_$][A-Za-z0-9_$]*)?|\{[A-Za-z0-9_$,\s]*\})\s+from\s+
      | \b(?:import|require)\s*\(\s*
    )
    (?P<quote>['"])(?P<spec>[^'"\n]+)(?P=quote)
    |
    (?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)
    """
)


def resolve_default_psql_bin() -> str:
  """Resolves the default `psql` binary path in an environment-agnostic manner."""
  env_psql = os.environ.get("TLE_PACK_PSQL")
  if env_psql:
    return env_psql
  env_pg_config = os.environ.get("PG_CONFIG")
  if env_pg_config:
    try:
      res = subprocess.run(
          [env_pg_config, "--bindir"],
          capture_output=True,
          text=True,
          check=True,
      )
      candidate = pathlib.Path(res.stdout.strip()) / "psql"
      if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    except Exception:
      pass
  which_psql = shutil.which("psql")
  if which_psql:
    return which_psql
  which_pg_config = shutil.which("pg_config")
  if which_pg_config:
    try:
      res = subprocess.run(
          [which_pg_config, "--bindir"],
          capture_output=True,
          text=True,
          check=True,
      )
      candidate = pathlib.Path(res.stdout.strip()) / "psql"
      if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    except Exception:
      pass
  return "psql"


def normalize_pkg_name(raw_name: str) -> str:
  """Normalizes an npm package name (e.g. `@pgtle/analytics-kit` -> `pgtle_analytics_kit`)."""
  name = raw_name.strip()
  if name.startswith("@"):
    name = name[1:]
  name = name.replace("/", "_").replace("-", "_")
  return name


def sql_dollar_quote(text: str, tag_hint: str = "tle_src") -> str:
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
  return "'" + val.replace("'", "''") + "'"


def normalize_posix_relpath(base_file: str, rel_spec: str) -> str:
  """Resolves a relative specifier (`./foo`, `../bar`) against `base_file`."""
  base_dir = posixpath.dirname(base_file)
  joined = posixpath.normpath(posixpath.join(base_dir, rel_spec))
  if joined.startswith("../") or joined == "..":
    raise ValueError(
        f"Relative import '{rel_spec}' in '{base_file}' escapes package root"
    )
  return joined


def resolve_local_js_file(root_dir: pathlib.Path, rel_path: str) -> Optional[pathlib.Path]:
  """Resolves a relative module path to an actual file on disk (.js, .mjs, .cjs, /index.js)."""
  candidates = [
      root_dir / rel_path,
      root_dir / f"{rel_path}.js",
      root_dir / f"{rel_path}.mjs",
      root_dir / f"{rel_path}.cjs",
      root_dir / rel_path / "index.js",
      root_dir / rel_path / "index.mjs",
  ]
  for cand in candidates:
    if cand.is_file():
      return cand.resolve()
  return None


def file_to_module_key(
    pkg_name: str,
    root_dir: pathlib.Path,
    file_path: pathlib.Path,
    entry_file: pathlib.Path,
) -> str:
  """Maps a file inside `root_dir` to its canonical `pgtle.modules` name."""
  if file_path.resolve() == entry_file.resolve():
    return pkg_name
  rel = file_path.resolve().relative_to(root_dir.resolve()).as_posix()
  for ext in (".mjs", ".cjs", ".js"):
    if rel.endswith(ext):
      rel = rel[: -len(ext)]
      break
  if rel.endswith("/index"):
    rel = rel[: -len("/index")]
  return f"{pkg_name}/{rel}"


class JSModuleNode:
  """Represents a single JS module in the package dependency graph."""

  def __init__(
      self,
      module_name: str,
      version: str,
      file_path: pathlib.Path,
      source_code: str,
      dependencies: List[str],
  ) -> None:
    self.module_name = module_name
    self.version = version
    self.file_path = file_path
    self.source_code = source_code
    self.dependencies = dependencies
    self.bytecode_hex: Optional[str] = None

  @property
  def name(self) -> str:
    return self.module_name

  @property
  def source(self) -> str:
    return self.source_code

  @property
  def requires(self) -> List[str]:
    return self.dependencies


def collect_js_module_graph(
    input_path: pathlib.Path,
    pkg_name_override: Optional[str] = None,
    version_override: Optional[str] = None,
) -> Tuple[str, str, str, List[JSModuleNode], Dict[str, Any]]:
  """Collects and topologically sorts all JS modules in a file or package directory."""
  pkg_meta: Dict[str, Any] = {}
  if input_path.is_dir():
    root_dir = input_path.resolve()
    pkg_json = root_dir / "package.json"
    if pkg_json.is_file():
      pkg_meta = json.loads(pkg_json.read_text(encoding="utf-8"))
    raw_pkg_name = pkg_name_override or pkg_meta.get("name") or root_dir.name
    pkg_name = normalize_pkg_name(raw_pkg_name)
    version = version_override or pkg_meta.get("version") or "1.0.0"
    description = pkg_meta.get("description") or f"Bundled JS package {pkg_name}"
    entry_rel = (
        pkg_meta.get("module")
        or pkg_meta.get("main")
        or "index.js"
    )
    if isinstance(pkg_meta.get("exports"), str):
      entry_rel = pkg_meta["exports"]
    elif isinstance(pkg_meta.get("exports"), dict):
      dot_exp = pkg_meta["exports"].get(".")
      if isinstance(dot_exp, str):
        entry_rel = dot_exp
      elif isinstance(dot_exp, dict):
        entry_rel = dot_exp.get("import") or dot_exp.get("default") or entry_rel
    entry_file = resolve_local_js_file(root_dir, entry_rel.lstrip("./"))
    if entry_file is None:
      raise FileNotFoundError(
          f"Could not locate entry file '{entry_rel}' in {root_dir}"
      )
  elif input_path.is_file():
    entry_file = input_path.resolve()
    root_dir = entry_file.parent
    raw_pkg_name = pkg_name_override or entry_file.stem
    pkg_name = normalize_pkg_name(raw_pkg_name)
    version = version_override or "1.0.0"
    description = f"Bundled JS module {pkg_name}"
  else:
    raise FileNotFoundError(f"Input path does not exist: {input_path}")

  visited_files: Dict[pathlib.Path, JSModuleNode] = {}
  visiting: Set[pathlib.Path] = set()
  ordered_nodes: List[JSModuleNode] = []

  def dfs(cur_file: pathlib.Path) -> JSModuleNode:
    cur_file = cur_file.resolve()
    if cur_file in visited_files:
      return visited_files[cur_file]
    if cur_file in visiting:
      raise ValueError(f"Circular module dependency detected at {cur_file}")
    visiting.add(cur_file)

    raw_source = cur_file.read_text(encoding="utf-8")
    cur_rel_posix = cur_file.relative_to(root_dir).as_posix()
    mod_name = file_to_module_key(pkg_name, root_dir, cur_file, entry_file)
    deps: List[str] = []

    def rewrite_spec(match: re.Match[str]) -> str:
      if match.group("comment") is not None or match.group("string") is not None:
        return match.group(0)
      full = match.group(0)
      quote = match.group("quote")
      spec = match.group("spec")

      if spec.startswith("./") or spec.startswith("../"):
        target_rel = normalize_posix_relpath(cur_rel_posix, spec)
        target_file = resolve_local_js_file(root_dir, target_rel)
        if target_file is None:
          raise FileNotFoundError(
              f"Unresolved relative import '{spec}' in {cur_file}"
          )
        child_node = dfs(target_file)
        dep_spec = child_node.module_name
        if dep_spec not in deps:
          deps.append(dep_spec)
        rewritten = f"tle:{child_node.module_name}@{child_node.version}"
        prefix = full[: match.start("spec") - match.start(0)]
        return f"{prefix}{rewritten}{quote}"
      else:
        clean_dep = spec
        for pfx in ("plv8-pkg:", "plv8:", "pljs-pkg:", "pljs:", "pgtle:", "tle://", "tle:"):
          if clean_dep.startswith(pfx):
            clean_dep = clean_dep[len(pfx) :]
            break
        clean_dep = clean_dep.lstrip("/")
        if clean_dep not in deps:
          deps.append(clean_dep)
        # Also include the version-stripped module/package identifier in requires
        # so engines that match requires entries without semver ranges (e.g. pljs)
        # permit the resolved package version.
        at_search = 1 if clean_dep.startswith("@") else 0
        slash_pos = clean_dep.find("/", at_search)
        if slash_pos != -1 and clean_dep.startswith("@"):
          slash_pos = clean_dep.find("/", slash_pos + 1)
        head = clean_dep if slash_pos == -1 else clean_dep[:slash_pos]
        tail = "" if slash_pos == -1 else clean_dep[slash_pos + 1 :]
        at_pos = head.find("@", at_search)
        bare_dep = clean_dep
        if at_pos != -1:
          bare_pkg = head[:at_pos]
          bare_dep = f"{bare_pkg}/{tail}" if tail else bare_pkg
        elif tail and "@" in tail:
          tail_at = tail.rfind("@")
          if tail_at > 0:
            bare_dep = f"{head}/{tail[:tail_at]}"
        if bare_dep and bare_dep not in deps:
          deps.append(bare_dep)
        pkg_deps = (
            pkg_meta.get("dependencies")
            if isinstance(pkg_meta, dict) and isinstance(pkg_meta.get("dependencies"), dict)
            else {}
        )
        if bare_dep in pkg_deps and pkg_deps[bare_dep]:
          ver_spec = f"{bare_dep}@{pkg_deps[bare_dep]}"
          if ver_spec not in deps:
            deps.append(ver_spec)
        return full

    rewritten_source = IMPORT_SPEC_RE.sub(rewrite_spec, raw_source)
    node = JSModuleNode(
        module_name=mod_name,
        version=version,
        file_path=cur_file,
        source_code=rewritten_source,
        dependencies=deps,
    )
    visiting.remove(cur_file)
    visited_files[cur_file] = node
    ordered_nodes.append(node)
    return node

  dfs(entry_file)
  return pkg_name, version, description, ordered_nodes, pkg_meta


def compile_bytecode_via_psql(
    nodes: List[JSModuleNode],
    engine: str,
    dsn: str,
    psql_bin: str,
) -> None:
  """Pre-compiles JS modules into QuickJS (`pljs`) or V8 (`plv8`) bytecode via PostgreSQL."""
  if engine not in ("plv8", "pljs"):
    raise ValueError(f"Unsupported bytecode engine: {engine}")

  if not pathlib.Path(psql_bin).is_file() and not shutil.which(psql_bin):
    raise FileNotFoundError(
        f"PostgreSQL client binary '{psql_bin}' not found. "
        "Ensure 'psql' is on PATH or pass --psql-bin / TLE_PACK_PSQL."
    )

  helper_fn = f"__tle_pack_compile_{engine}_bc"
  ext_name = engine

  for node in nodes:
    pkg_part, _, sub_part = node.module_name.partition("/")
    pkg_rel_path = sub_part if sub_part else "index.js"
    canonical_name = (
        f"plv8:{pkg_part}@{node.version}/{pkg_rel_path}"
        if engine == "plv8"
        else f"pljs-pkg:{pkg_part}@{node.version}/{pkg_rel_path}"
    )
    src_lit = sql_dollar_quote(node.source_code, "bc_src")
    mod_lit = sql_literal(canonical_name)
    sql = f"""
CREATE EXTENSION IF NOT EXISTS {ext_name};
CREATE OR REPLACE FUNCTION pg_temp.{helper_fn}(src text, modname text)
RETURNS bytea LANGUAGE {ext_name} AS $fn$
  return {ext_name}.compile_bytecode(src, modname);
$fn$;
SELECT encode(pg_temp.{helper_fn}({src_lit}, {mod_lit}), 'hex');
"""
    cmd = [psql_bin, "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"]
    if dsn:
      cmd.extend(["-d", dsn])
    res = subprocess.run(
        cmd,
        input=sql,
        text=True,
        capture_output=True,
        check=False,
    )
    if res.returncode != 0:
      raise RuntimeError(
          f"Bytecode compilation failed for {node.module_name} via {engine}:\n"
          f"{res.stderr.strip()}"
      )
    lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]
    if not lines:
      raise RuntimeError(
          f"Empty bytecode output from {engine} for {node.module_name}"
      )
    node.bytecode_hex = lines[-1]


# ==============================================================================
# Pure-Python WebAssembly Binary Section Parser (Zero External Dependencies)
# ==============================================================================

def read_uleb128(data: bytes, offset: int) -> Tuple[int, int]:
  """Reads an unsigned LEB128 integer from `data` starting at `offset`."""
  result = 0
  shift = 0
  while True:
    if offset >= len(data):
      raise ValueError("Unexpected EOF while decoding ULEB128 in WASM binary")
    byte = data[offset]
    offset += 1
    result |= (byte & 0x7F) << shift
    if (byte & 0x80) == 0:
      break
    shift += 7
  return result, offset


def read_wasm_name(data: bytes, offset: int) -> Tuple[str, int]:
  """Reads a UTF-8 length-prefixed name from `data` starting at `offset`."""
  length, offset = read_uleb128(data, offset)
  end = offset + length
  if end > len(data):
    raise ValueError("Unexpected EOF while reading UTF-8 name in WASM binary")
  return data[offset:end].decode("utf-8", errors="replace"), end


def skip_wasm_limits(data: bytes, offset: int) -> int:
  """Skips a WebAssembly `limits` structure (`flags: u8, min: u32, [max: u32]`)."""
  flags, offset = read_uleb128(data, offset)
  _, offset = read_uleb128(data, offset)
  if flags & 0x01:
    _, offset = read_uleb128(data, offset)
  return offset


def introspect_wasm_binary(wasm_bytes: bytes) -> Dict[str, Any]:
  """Parses a `.wasm` binary's Type (1), Import (2), Function (3), and Export (7) sections.

  Returns a dictionary containing:
    - `functions`: list of `{name, export, args, returns, volatility}` for exported WASM functions
    - `exports`: raw list of `{name, kind, index}`
    - `has_memory`: bool indicating if linear memory is exported
    - `sha256`: hex digest of the `.wasm` payload
  """
  if len(wasm_bytes) < 8 or wasm_bytes[:8] != WASM_MAGIC:
    raise ValueError(
        "Invalid WebAssembly binary: missing \\x00asm\\x01\\x00\\x00\\x00 magic header"
    )

  offset = 8
  func_types: List[Tuple[List[int], List[int]]] = []
  imported_func_type_indices: List[int] = []
  defined_func_type_indices: List[int] = []
  exports: List[Dict[str, Any]] = []

  while offset < len(wasm_bytes):
    sec_id = wasm_bytes[offset]
    offset += 1
    sec_len, offset = read_uleb128(wasm_bytes, offset)
    sec_end = offset + sec_len
    if sec_end > len(wasm_bytes):
      raise ValueError(f"Malformed WASM section {sec_id}: exceeds binary size")

    p = offset
    if sec_id == 1:  # Type section
      num_types, p = read_uleb128(wasm_bytes, p)
      for _ in range(num_types):
        form = wasm_bytes[p]
        p += 1
        if form != 0x60:
          raise ValueError(f"Unsupported WASM functype form: 0x{form:02x}")
        num_params, p = read_uleb128(wasm_bytes, p)
        params = list(wasm_bytes[p : p + num_params])
        p += num_params
        num_results, p = read_uleb128(wasm_bytes, p)
        results = list(wasm_bytes[p : p + num_results])
        p += num_results
        func_types.append((params, results))

    elif sec_id == 2:  # Import section
      num_imports, p = read_uleb128(wasm_bytes, p)
      for _ in range(num_imports):
        _, p = read_wasm_name(wasm_bytes, p)  # module name
        _, p = read_wasm_name(wasm_bytes, p)  # field name
        kind = wasm_bytes[p]
        p += 1
        if kind == 0x00:  # func import
          type_idx, p = read_uleb128(wasm_bytes, p)
          imported_func_type_indices.append(type_idx)
        elif kind == 0x01:  # table import
          p += 1  # elemtype
          p = skip_wasm_limits(wasm_bytes, p)
        elif kind == 0x02:  # mem import
          p = skip_wasm_limits(wasm_bytes, p)
        elif kind == 0x03:  # global import
          p += 2  # valtype + mutability
        elif kind == 0x04:  # tag import (exception handling proposal)
          p += 1  # attribute byte (0x00)
          _, p = read_uleb128(wasm_bytes, p)
        else:
          break

    elif sec_id == 3:  # Function section
      num_funcs, p = read_uleb128(wasm_bytes, p)
      for _ in range(num_funcs):
        type_idx, p = read_uleb128(wasm_bytes, p)
        defined_func_type_indices.append(type_idx)

    elif sec_id == 7:  # Export section
      num_exports, p = read_uleb128(wasm_bytes, p)
      for _ in range(num_exports):
        exp_name, p = read_wasm_name(wasm_bytes, p)
        kind = wasm_bytes[p]
        p += 1
        idx, p = read_uleb128(wasm_bytes, p)
        exports.append({"name": exp_name, "kind": kind, "index": idx})

    offset = sec_end

  all_func_type_indices = imported_func_type_indices + defined_func_type_indices
  inferred_functions: List[Dict[str, Any]] = []
  has_memory = False

  internal_exports = {
      "_initialize",
      "_start",
      "_cgo_dummy_export",
      "alloc",
      "dealloc",
      "malloc",
      "free",
      "calloc",
      "realloc",
      "stackSave",
      "stackRestore",
      "stackAlloc",
      "fminimum",
      "fminimumf",
      "fmaximum",
      "fmaximumf",
      "rust_eh_personality",
  }

  for exp in exports:
    if exp["kind"] == 0x02:
      has_memory = True
    elif exp["kind"] == 0x00:  # Function export
      fn_idx = exp["index"]
      exp_name = exp["name"]
      if (
          exp_name.startswith("__")
          or exp_name.startswith("asyncify_")
          or exp_name.startswith("_dyn_")
          or exp_name.startswith("wasm_bindgen__")
          or exp_name in internal_exports
          or "." in exp_name
      ):
        continue
      if fn_idx >= len(all_func_type_indices):
        continue
      type_idx = all_func_type_indices[fn_idx]
      if type_idx >= len(func_types):
        continue
      params, results = func_types[type_idx]
      pg_args = [
          {"name": f"arg{i + 1}", "type": WASM_VALTYPE_TO_PG.get(vt, "int4")}
          for i, vt in enumerate(params)
      ]
      if not results:
        pg_ret = "void"
      else:
        pg_ret = WASM_VALTYPE_TO_PG.get(results[0], "int4")
      inferred_functions.append({
          "name": exp_name,
          "export": exp_name,
          "args": pg_args,
          "returns": pg_ret,
          "volatility": "IMMUTABLE",
      })

  return {
      "functions": inferred_functions,
      "exports": exports,
      "has_memory": has_memory,
      "sha256": hashlib.sha256(wasm_bytes).hexdigest(),
  }


def merge_wasm_manifest(
    introspected: Dict[str, Any],
    user_manifest: Optional[Dict[str, Any]],
    auto_discover_unlisted: bool,
    fn_prefix: str,
) -> Dict[str, Any]:
  """Merges user-supplied WASM manifest with binary-introspected export signatures."""
  if user_manifest is None:
    funcs = []
    for f in introspected["functions"]:
      f_copy = dict(f)
      if fn_prefix and not f_copy["name"].startswith(fn_prefix):
        f_copy["name"] = f"{fn_prefix}{f_copy['name']}"
      funcs.append(f_copy)
    return {"types": [], "functions": funcs}

  inferred_by_export = {f["export"]: f for f in introspected["functions"]}
  merged_types = list(user_manifest.get("types", []))
  used_exports: Set[str] = set()

  for t in merged_types:
    for key in ("input_export", "input_func", "input", "output_export", "output_func", "output"):
      if t.get(key):
        used_exports.add(t[key])
    for op in t.get("operators", []):
      op_exp = op.get("export") or op.get("wasm_export") or op.get("name") or op.get("sql_name")
      if op_exp:
        used_exports.add(op_exp)

  for op in user_manifest.get("operators", []):
    op_exp = op.get("func") or op.get("function") or op.get("name") or op.get("sql_name")
    if op_exp:
      used_exports.add(op_exp)

  merged_funcs: List[Dict[str, Any]] = []
  for f in user_manifest.get("functions", []):
    f_copy = dict(f)
    exp_name = (
        f_copy.get("export")
        or f_copy.get("wasm_export")
        or f_copy.get("name")
        or f_copy.get("sql_name")
    )
    used_exports.add(exp_name)
    # If `args` or `returns` were omitted in the manifest, auto-fill from binary introspection!
    if exp_name in inferred_by_export:
      inf = inferred_by_export[exp_name]
      if "args" not in f_copy:
        f_copy["args"] = inf["args"]
      if "returns" not in f_copy and "result" not in f_copy:
        f_copy["returns"] = inf["returns"]
    merged_funcs.append(f_copy)

  if auto_discover_unlisted:
    for inf in introspected["functions"]:
      if inf["export"] not in used_exports:
        f_copy = dict(inf)
        if fn_prefix and not f_copy["name"].startswith(fn_prefix):
          f_copy["name"] = f"{fn_prefix}{f_copy['name']}"
        merged_funcs.append(f_copy)

  res: Dict[str, Any] = {
      "types": merged_types,
      "functions": merged_funcs,
  }
  if "operators" in user_manifest:
    res["operators"] = list(user_manifest["operators"])
  if "glue_js" in user_manifest:
    res["glue_js"] = user_manifest["glue_js"]
  return res


# ==============================================================================
# SQL Artifact Generators
# ==============================================================================

def _build_js_engine_catalog_sync_sql(
    pkg_name: str,
    version: str,
    nodes: List[JSModuleNode],
    ext_language: str,
    pkg_meta: Dict[str, Any],
    is_trusted: bool = True,
) -> str:
  """Builds a DO block that syncs a JS package into plv8/pljs catalogs (with self-contained fallback)."""
  raw_deps = (
      pkg_meta.get("dependencies", {})
      if isinstance(pkg_meta, dict) and isinstance(pkg_meta.get("dependencies"), dict)
      else {}
  )
  deps_json_lit = f"{sql_literal(json.dumps(raw_deps, sort_keys=True))}::jsonb"
  pkg_lit = sql_literal(pkg_name)
  ver_lit = sql_literal(version)
  trusted_lit = "true" if is_trusted else "false"

  lines: List[str] = [
      "DO $tle_pkg_cat$",
      "BEGIN",
  ]
  for eng in ("plv8", "pljs"):
    if ext_language == eng:
      if eng == "plv8":
        bc_expr_from_m = (
            "CASE WHEN m.bytecode IS NOT NULL AND pg_catalog.octet_length(m.bytecode) >= 8 "
            "AND pg_catalog.substr(m.bytecode, 1, 8) = 'PLV8BC01'::bytea THEN m.bytecode ELSE NULL END"
        )
      else:
        bc_expr_from_m = (
            "CASE WHEN m.bytecode IS NOT NULL AND (pg_catalog.octet_length(m.bytecode) < 8 "
            "OR pg_catalog.substr(m.bytecode, 1, 8) <> 'PLV8BC01'::bytea) THEN m.bytecode ELSE NULL END"
        )
    else:
      bc_expr_from_m = "NULL::bytea"

    lines.extend([
        f"  IF pg_catalog.to_regclass('{eng}.packages') IS NOT NULL",
        f"     AND pg_catalog.to_regclass('{eng}.modules') IS NOT NULL THEN",
        f"    INSERT INTO {eng}.packages (name, version, entry_point, dependencies)",
        f"    VALUES ({pkg_lit}, {ver_lit}, 'index.js', {deps_json_lit})",
        "    ON CONFLICT (name, version) DO UPDATE",
        "    SET entry_point = EXCLUDED.entry_point,",
        "        dependencies = EXCLUDED.dependencies,",
        "        updated_at = NOW();",
    ])
    for idx, node in enumerate(nodes, start=1):
      rel_path = (
          "index.js"
          if node.module_name == pkg_name
          else node.module_name[len(pkg_name) + 1 :]
      )
      mod_lit = sql_literal(node.module_name)
      node_ver_lit = sql_literal(node.version)
      src_fallback_dq = sql_dollar_quote(node.source_code, f"tle_cat_src_{idx}")
      if node.bytecode_hex and ext_language == eng:
        bc_col = f"COALESCE({bc_expr_from_m}, pg_catalog.decode('{node.bytecode_hex}', 'hex'))"
      else:
        bc_col = bc_expr_from_m
      if node.dependencies:
        dep_items = ", ".join(sql_literal(d) for d in node.dependencies)
        deps_fallback = f"ARRAY[{dep_items}]::text[]"
      else:
        deps_fallback = "NULL::text[]"

      rel_paths = [rel_path]
      if rel_path != "index.js" and not rel_path.endswith((".js", ".mjs", ".cjs")):
        rel_paths.append(f"{rel_path}.js")

      for rp in rel_paths:
        rel_lit = sql_literal(rp)
        lines.extend([
            f"    INSERT INTO {eng}.modules (path, package_name, package_version, source, bytecode, requires, is_trusted)",
            f"    SELECT {rel_lit}, {pkg_lit}, COALESCE(m.version, {node_ver_lit}), COALESCE(m.source_code, {src_fallback_dq}), {bc_col}, COALESCE(m.dependencies, {deps_fallback}), COALESCE(m.is_trusted, {trusted_lit})",
            "    FROM (SELECT 1) AS _tle_one",
            f"    LEFT JOIN pgtle.modules m ON m.module_name = {mod_lit} AND m.version = {node_ver_lit}",
            "    ON CONFLICT (package_name, package_version, path) WHERE package_name IS NOT NULL DO UPDATE",
            "    SET source = EXCLUDED.source,",
            "        bytecode = EXCLUDED.bytecode,",
            "        requires = EXCLUDED.requires,",
            "        is_trusted = EXCLUDED.is_trusted,",
            "        updated_at = NOW();",
        ])
    lines.append("  END IF;")
  lines.extend([
      "END;",
      "$tle_pkg_cat$;",
  ])
  return "\n".join(lines)


def generate_js_bundle_sql(
    pkg_name: str,
    version: str,
    description: str,
    nodes: List[JSModuleNode],
    is_trusted: bool,
    as_extension: bool,
    create_extension: bool,
    compile_bytecode: bool,
    ext_language: str,
    pkg_meta: Dict[str, Any],
) -> str:
  """Generates a reproducible SQL installation script for a JS package."""
  mod_names_summary = ", ".join(n.module_name for n in nodes)
  out: List[str] = [
      "-- =============================================================================",
      "-- Generated by tle-pack (JavaScript / npm mode)",
      f"-- Package: {pkg_name}@{version}",
      f"-- Modules ({len(nodes)}): {mod_names_summary}",
      "-- =============================================================================",
      "",
      "CREATE EXTENSION IF NOT EXISTS pg_tle;",
      "DO $tle_engine_init$",
      "BEGIN",
      f"  IF pg_catalog.to_regclass('{ext_language}.packages') IS NULL",
      f"     AND EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions WHERE name = {sql_literal(ext_language)}) THEN",
      f"    CREATE EXTENSION IF NOT EXISTS {ext_language};",
      "  END IF;",
      "END;",
      "$tle_engine_init$;",
      "",
      "BEGIN;",
      "",
  ]

  use_inline_bc_helper = compile_bytecode and any(n.bytecode_hex is None for n in nodes)
  if use_inline_bc_helper:
    out.append(
        "CREATE OR REPLACE FUNCTION pg_temp._tle_pack_compile_bc(src text, rname text)\n"
        f"RETURNS bytea LANGUAGE {ext_language} IMMUTABLE STRICT AS $_tle_bc_$\n"
        f"  return {ext_language}.compile_bytecode(src, rname);\n"
        "$_tle_bc_$;"
    )
    out.append("")

  for idx, node in enumerate(nodes, start=1):
    src_dq = sql_dollar_quote(node.source_code, f"tle_mod_{idx}")
    pkg_rel_path = (
        "index.js"
        if node.module_name == pkg_name
        else node.module_name[len(pkg_name) + 1 :]
    )
    if node.bytecode_hex:
      bc_expr = f"decode('{node.bytecode_hex}', 'hex')"
    elif compile_bytecode:
      rname = (
          f"plv8:{pkg_name}@{node.version}/{pkg_rel_path}"
          if ext_language == "plv8"
          else f"pljs-pkg:{pkg_name}@{node.version}/{pkg_rel_path}"
      )
      bc_expr = f"pg_temp._tle_pack_compile_bc({src_dq}, {sql_literal(rname)})"
    else:
      bc_expr = "NULL"

    if node.dependencies:
      dep_items = ", ".join(sql_literal(d) for d in node.dependencies)
      deps_expr = f"ARRAY[{dep_items}]::text[]"
    else:
      deps_expr = "NULL"

    trusted_expr = "true" if is_trusted else "false"
    out.append(
        f"-- [{idx}/{len(nodes)}] Module: {node.module_name}@{node.version}"
    )
    out.append(
        "SELECT pgtle.install_module(\n"
        f"  {sql_literal(node.module_name)},\n"
        f"  {sql_literal(node.version)},\n"
        f"  {src_dq},\n"
        f"  {bc_expr},\n"
        f"  {deps_expr},\n"
        f"  {trusted_expr}\n"
        ");"
    )
    out.append("")

  catalog_sync_sql = _build_js_engine_catalog_sync_sql(
      pkg_name=pkg_name,
      version=version,
      nodes=nodes,
      ext_language=ext_language,
      pkg_meta=pkg_meta,
      is_trusted=is_trusted,
  )
  out.append(catalog_sync_sql)
  out.append("")

  # Optional: also register a pg_tle extension that exposes SQL wrapper functions
  # declared in package.json -> "pgtle": {"functions": [...]}
  pgtle_cfg = pkg_meta.get("pgtle", {}) if isinstance(pkg_meta, dict) else {}
  exported_sql_funcs = pgtle_cfg.get("functions", [])
  entry_node = next((n for n in nodes if n.module_name == pkg_name), nodes[-1] if nodes else None)
  entry_is_cjs = False
  if entry_node is not None:
    if entry_node.file_path.suffix == ".cjs":
      entry_is_cjs = True
    elif entry_node.file_path.suffix != ".mjs":
      stripped_src = IMPORT_SPEC_RE.sub(
          lambda m: "" if (m.group("comment") or m.group("string")) else m.group(0),
          entry_node.source_code,
      )
      if not re.search(r"\bexport\b", stripped_src) and re.search(
          r"\b(?:module\.exports|exports|require\s*\()\b", stripped_src
      ):
        entry_is_cjs = True
  if as_extension or create_extension or exported_sql_funcs:
    ext_stmts: List[str] = [catalog_sync_sql]
    for fn_spec in exported_sql_funcs:
      sql_fn_name = fn_spec.get("name") or fn_spec.get("sql_name")
      fn_schema = fn_spec.get("schema")
      if fn_schema:
        qual_fn_name = f'"{fn_schema}"."{sql_fn_name}"'
      elif "." in str(sql_fn_name):
        s_part, f_part = str(sql_fn_name).split(".", 1)
        qual_fn_name = f'"{s_part.strip(chr(34))}"."{f_part.strip(chr(34))}"'
      else:
        qual_fn_name = f'"{sql_fn_name}"'
      js_export = fn_spec.get("export") or fn_spec.get("js_export") or sql_fn_name
      ret_type = fn_spec.get("returns", "text")
      volatility = fn_spec.get("volatility", "IMMUTABLE")
      strict_kw = " STRICT" if fn_spec.get("strict", True) else ""
      lang = fn_spec.get("language", ext_language)
      # Support both [{"name": "label", "type": "text"}, ...] and ["label text", "int4", ...]
      call_args: List[str] = []
      named_args: List[str] = []
      for i, arg_decl in enumerate(fn_spec.get("args", [])):
        if isinstance(arg_decl, dict):
          arg_name = arg_decl.get("name") or f"a{i}"
          arg_type = arg_decl.get("type") or "text"
          named_args.append(f'"{arg_name}" {arg_type}')
          call_args.append(arg_name)
        else:
          parts = str(arg_decl).strip().split()
          if len(parts) >= 2:
            arg_name = parts[0].strip('"')
            named_args.append(str(arg_decl))
          else:
            arg_name = f"a{i}"
            named_args.append(f"{arg_name} {arg_decl}")
          call_args.append(arg_name)
      named_sig = ", ".join(named_args)
      js_call_args = ", ".join(call_args)
      if js_export == "default":
        import_stmt = f"import __tle_default_fn from 'tle:{pkg_name}@{version}';"
        call_stmt = f"return __tle_default_fn({js_call_args});"
      elif entry_is_cjs:
        import_stmt = f"import __tle_cjs_mod from 'tle:{pkg_name}@{version}';"
        call_stmt = f"return __tle_cjs_mod.{js_export}({js_call_args});"
      else:
        import_stmt = f"import {{ {js_export} }} from 'tle:{pkg_name}@{version}';"
        call_stmt = f"return {js_export}({js_call_args});"
      ext_stmts.append(
          f"CREATE OR REPLACE FUNCTION {qual_fn_name}({named_sig})\n"
          f'RETURNS {ret_type} LANGUAGE "{lang}" {volatility}{strict_kw}\n'
          f"AS $fn${import_stmt}\n"
          f"{call_stmt}$fn$;"
      )
    ext_sql_body = "\n\n".join(ext_stmts) if ext_stmts else "-- Module-only TLE package"
    ext_dq = sql_dollar_quote(ext_sql_body, "tle_ext_sql")
    reqs = pgtle_cfg.get("requires") or pgtle_cfg.get("languages") or [ext_language]
    reqs_expr = (
        "ARRAY[" + ", ".join(sql_literal(r) for r in reqs) + "]::text[]"
        if reqs
        else "ARRAY[]::text[]"
    )
    out.append(f"-- Register TLE extension '{pkg_name}' version '{version}'")
    out.append(
        "DO $tle_reg$\n"
        "BEGIN\n"
        f"  IF EXISTS (SELECT 1 FROM pgtle.available_extensions() WHERE name = {sql_literal(pkg_name)}) THEN\n"
        f"    PERFORM pgtle.uninstall_extension({sql_literal(pkg_name)});\n"
        "  END IF;\n"
        "  PERFORM pgtle.install_extension(\n"
        f"    {sql_literal(pkg_name)},\n"
        f"    {sql_literal(version)},\n"
        f"    {sql_literal(description)},\n"
        f"    {ext_dq},\n"
        f"    {reqs_expr}\n"
        "  );\n"
        "END;\n"
        "$tle_reg$;"
    )
    out.append("")

  out.append("COMMIT;")
  if as_extension or create_extension:
    out.append("")
    out.append(f'CREATE EXTENSION IF NOT EXISTS "{pkg_name}";')
  out.append("")
  return "\n".join(out)


def generate_wasm_bundle_sql(
    ext_name: str,
    version: str,
    description: str,
    wasm_bytes: bytes,
    manifest: Dict[str, Any],
    introspected: Dict[str, Any],
    create_extension: bool,
) -> str:
  """Generates a reproducible SQL installation script calling `pgtle.install_wasm_extension()`."""
  wasm_hex = wasm_bytes.hex()
  manifest_json = json.dumps(manifest, indent=2, sort_keys=True)
  manifest_dq = sql_dollar_quote(manifest_json, "wasm_manifest")

  out: List[str] = [
      "-- =============================================================================",
      f"-- Generated by tle-pack (WASM Mode) for extension: {ext_name}@{version}",
      f"-- WASM Size: {len(wasm_bytes)} bytes | SHA-256: {introspected['sha256']}",
      f"-- Exported Memory: {introspected['has_memory']} | SQL Functions: {len(manifest.get('functions', []))} | Custom Types: {len(manifest.get('types', []))}",
      "-- =============================================================================",
      "",
      "CREATE EXTENSION IF NOT EXISTS pg_tle;",
      "CREATE EXTENSION IF NOT EXISTS plv8;",
      "",
      "SELECT pgtle.install_wasm_extension(",
      f"  {sql_literal(ext_name)},",
      f"  {sql_literal(version)},",
      f"  {sql_literal(description)},",
      f"  pg_catalog.decode('{wasm_hex}', 'hex'),",
      f"  {manifest_dq}::jsonb,",
      "  NULL",
      ");",
      "",
  ]
  if create_extension:
    out.append(f'CREATE EXTENSION IF NOT EXISTS "{ext_name}";')
    out.append("")
  return "\n".join(out)


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

  js = re.sub(r"^\s*export\s+default\s+[^;]+;\s*$", "", js, flags=re.MULTILINE)
  js = re.sub(r"^\s*export\s*\{[^}]*\}\s*;?\s*$", "", js, flags=re.MULTILINE)
  js = js.replace("import.meta.url", '""')
  js = re.sub(r"\bimport\.meta\b", "({})", js)
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


# ==============================================================================
# CLI Entrypoint
# ==============================================================================

def _infer_js_engine(
    explicit_engine: Optional[str],
    pkg_meta: Dict[str, Any],
) -> str:
  if explicit_engine in ("plv8", "pljs"):
    return explicit_engine
  pgtle_cfg = pkg_meta.get("pgtle", {}) if isinstance(pkg_meta, dict) else {}
  if not isinstance(pgtle_cfg, dict):
    return "plv8"
  cfg_lang = pgtle_cfg.get("language") or pgtle_cfg.get("engine")
  if cfg_lang in ("plv8", "pljs"):
    return str(cfg_lang)
  req_list = pgtle_cfg.get("requires")
  if isinstance(req_list, list):
    if "pljs" in req_list and "plv8" not in req_list:
      return "pljs"
    if "plv8" in req_list and "pljs" not in req_list:
      return "plv8"
  fn_specs = pgtle_cfg.get("functions")
  if isinstance(fn_specs, list) and fn_specs:
    fn_langs = {
        str(fn.get("language"))
        for fn in fn_specs
        if isinstance(fn, dict) and fn.get("language")
    }
    if fn_langs == {"pljs"}:
      return "pljs"
  return "plv8"


def pack_js_target(args: argparse.Namespace) -> str:
  input_path = pathlib.Path(args.input)
  pkg_name, version, description, nodes, pkg_meta = collect_js_module_graph(
      input_path=input_path,
      pkg_name_override=args.name,
      version_override=args.version,
  )
  if args.description:
    description = args.description

  engine = _infer_js_engine(getattr(args, "engine", None), pkg_meta)

  if args.compile_bytecode and args.dsn:
    compile_bytecode_via_psql(
        nodes=nodes,
        engine=engine,
        dsn=args.dsn,
        psql_bin=args.psql_bin,
    )

  return generate_js_bundle_sql(
      pkg_name=pkg_name,
      version=version,
      description=description,
      nodes=nodes,
      is_trusted=not args.untrusted,
      as_extension=args.as_extension,
      create_extension=args.create_extension,
      compile_bytecode=args.compile_bytecode,
      ext_language=engine,
      pkg_meta=pkg_meta,
  )


def pack_wasm_target(args: argparse.Namespace) -> str:
  wasm_path = pathlib.Path(args.input)
  if not wasm_path.is_file():
    raise FileNotFoundError(f"WASM file not found: {wasm_path}")
  wasm_bytes = wasm_path.read_bytes()
  introspected = introspect_wasm_binary(wasm_bytes)

  user_manifest: Optional[Dict[str, Any]] = None
  if args.manifest:
    manifest_path = pathlib.Path(args.manifest)
    user_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
  else:
    # Auto-detect sibling `<stem>.manifest.json` if present and --ignore-sibling-manifest not set
    sibling = wasm_path.with_suffix(".manifest.json")
    if sibling.is_file() and not args.ignore_sibling_manifest:
      user_manifest = json.loads(sibling.read_text(encoding="utf-8"))

  wasm_stem = wasm_path.stem
  if wasm_stem.endswith("_bg") and len(wasm_stem) > 3:
    wasm_stem = wasm_stem[:-3]
  ext_name = (
      args.name
      or (user_manifest.get("name") if user_manifest else None)
      or wasm_stem.replace("-", "_")
  )
  version = (
      args.version
      or (user_manifest.get("version") if user_manifest else None)
      or "1.0.0"
  )
  description = (
      args.description
      or (user_manifest.get("description") if user_manifest else None)
      or f"WebAssembly extension {ext_name} packaged by tle-pack"
  )

  merged_manifest = merge_wasm_manifest(
      introspected=introspected,
      user_manifest=user_manifest,
      auto_discover_unlisted=args.auto_discover_exports,
      fn_prefix=args.function_prefix or "",
  )

  if getattr(args, "glue_js", None):
    glue_path = pathlib.Path(args.glue_js)
    raw_glue = glue_path.read_text(encoding="utf-8")
    exp_names = [
        f.get("export") or f.get("wasm_export") or f.get("name")
        for f in merged_manifest.get("functions", [])
        if f.get("export") or f.get("wasm_export") or f.get("name")
    ]
    merged_manifest["glue_js"] = transform_wasm_bindgen_glue(raw_glue, exp_names)

  return generate_wasm_bundle_sql(
      ext_name=ext_name,
      version=version,
      description=description,
      wasm_bytes=wasm_bytes,
      manifest=merged_manifest,
      introspected=introspected,
      create_extension=args.create_extension or args.as_extension,
  )


def build_arg_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
      prog="tle-pack",
      description=(
          "Bundle npm/JS packages or .wasm binaries into reproducible pg_tle SQL scripts."
      ),
  )
  parser.add_argument(
      "-V",
      "--tool-version",
      action="version",
      version=f"%(prog)s {__version__}",
      help="Print the tle-pack tool version and exit.",
  )
  parser.add_argument(
      "mode",
      nargs="?",
      default="auto",
      help="Packaging mode: 'js', 'wasm', or 'auto' (inferred from input path).",
  )
  parser.add_argument(
      "input",
      nargs="?",
      help="Path to an npm package directory, .js/.mjs entry file, or .wasm binary.",
  )
  parser.add_argument(
      "--wasm",
      dest="wasm_input",
      help="Path to .wasm binary (optional flag alias for positional input in wasm mode).",
  )
  parser.add_argument(
      "--glue-js",
      "--js",
      dest="glue_js",
      help="Optional path to wasm-bindgen JS glue file to bundle with the WASM binary.",
  )
  parser.add_argument(
      "-o",
      "--output",
      "--out",
      dest="output",
      help="Output .sql file path (defaults to stdout).",
  )
  parser.add_argument(
      "-n",
      "--name",
      help="Override module or extension name.",
  )
  parser.add_argument(
      "-v",
      "--version",
      help="Override module or extension version (default: package.json or 1.0.0).",
  )
  parser.add_argument(
      "-d",
      "--description",
      help="Override extension description.",
  )
  parser.add_argument(
      "--compile-bytecode",
      action="store_true",
      help="Pre-compile JS modules into V8 CodeCache (PLV8BC01) or QuickJS bytecode.",
  )
  parser.add_argument(
      "--engine",
      "--language",
      dest="engine",
      choices=["plv8", "pljs"],
      default=None,
      help=(
          "Target JS engine for bytecode compilation or wrapper functions "
          "(default: inferred from package.json pgtle config or plv8)."
      ),
  )
  parser.add_argument(
      "--dsn",
      default=os.environ.get("TLE_PACK_DSN", ""),
      help="Optional PostgreSQL connection string for offline --compile-bytecode via psql.",
  )
  parser.add_argument(
      "--psql-bin",
      default=resolve_default_psql_bin(),
      help="Path to psql binary for --compile-bytecode with --dsn (default: $TLE_PACK_PSQL or psql on PATH).",
  )
  parser.add_argument(
      "--untrusted",
      action="store_true",
      help="Install JS modules with is_trusted = false (requires superuser at runtime).",
  )
  parser.add_argument(
      "--as-extension",
      action="store_true",
      help="Also register a pg_tle extension via pgtle.install_extension() and CREATE EXTENSION.",
  )
  parser.add_argument(
      "-m",
      "--manifest",
      help="Path to JSON manifest for WASM custom types, buffers, and function overrides.",
  )
  parser.add_argument(
      "--ignore-sibling-manifest",
      action="store_true",
      help="Ignore <stem>.manifest.json when packing a .wasm binary in zero-manifest mode.",
  )
  parser.add_argument(
      "--auto-discover-exports",
      action="store_true",
      help="Merge auto-introspected WASM exports even when a manifest is provided.",
  )
  parser.add_argument(
      "--function-prefix",
      default="",
      help="Optional prefix for auto-discovered SQL function names in WASM mode.",
  )
  parser.add_argument(
      "--create-extension",
      action="store_true",
      help="Append CREATE EXTENSION IF NOT EXISTS <name>; to the generated SQL script.",
  )
  return parser


def main(argv: Optional[List[str]] = None) -> int:
  # Support both `tle-pack <input> [flags]`, `tle-pack [flags] <input>`,
  # and `tle-pack <js|wasm> <input> [flags]`
  raw_args = list(sys.argv[1:] if argv is None else argv)
  if raw_args in (["--version"], ["-V"], ["--tool-version"]):
    print(f"tle-pack {__version__}")
    return 0

  parser = build_arg_parser()
  args = parser.parse_args(raw_args)

  if args.mode not in ("auto", "js", "wasm"):
    if args.input is not None:
      parser.error(
          f"argument mode: invalid choice: {args.mode!r} (choose from 'auto', 'js', 'wasm')"
      )
    args.input = args.mode
    args.mode = "auto"

  if not args.input and getattr(args, "wasm_input", None):
    args.input = args.wasm_input
  if not args.input:
    parser.error("the following arguments are required: input (or --wasm)")

  in_path = pathlib.Path(args.input)
  mode = args.mode
  if mode == "auto":
    if in_path.suffix == ".wasm" or getattr(args, "wasm_input", None):
      mode = "wasm"
    else:
      mode = "js"

  if mode == "wasm":
    sql_out = pack_wasm_target(args)
  else:
    sql_out = pack_js_target(args)

  if args.output and args.output != "-":
    out_path = pathlib.Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(sql_out, encoding="utf-8")
  else:
    sys.stdout.write(sql_out)

  return 0


if __name__ == "__main__":
  sys.exit(main())
