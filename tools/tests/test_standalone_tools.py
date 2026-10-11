#!/usr/bin/env python3
"""Automated test suite for pg_tle standalone out-of-database CLI tools and distribution packages."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

TOOLS_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import build_dist  # noqa: E402
import pgtle_tools  # noqa: E402
from pgtle_tools import pgwasm_pack  # noqa: E402
from pgtle_tools import tle_pack  # noqa: E402

# Minimal valid WebAssembly binary exporting:
#   - memory "memory" (kind 2, index 0)
#   - func "add_i32" (i32, i32) -> i32
#   - func "mul_i64" (i64, i64) -> i64
#   - func "alloc" (i32) -> i32 (internal allocator, should be filtered out of SQL UDFs)
SAMPLE_WASM_BYTES = bytes.fromhex(
    "0061736d01000000"
    "011203"
    "60027f7f017f"      # type 0: (i32, i32) -> i32
    "60027e7e017e"      # type 1: (i64, i64) -> i64
    "60017f017f"        # type 2: (i32) -> i32
    "030403000102"      # func section: 3 funcs with types 0, 1, 2
    "0503010001"        # memory section: 1 memory, min 1 page
    "072604"            # export section: 4 exports
    "066d656d6f72790200"        # "memory" (mem 0)
    "076164645f6933320000"      # "add_i32" (func 0)
    "076d756c5f6936340001"      # "mul_i64" (func 1)
    "05616c6c6f630002"          # "alloc" (func 2)
    "0a1603"            # code section: 3 bodies
    "0700200020016a0b"  # add_i32: local.get 0, local.get 1, i32.add
    "0700200020017e0b"  # mul_i64: local.get 0, local.get 1, i64.mul
    "040041000b"        # alloc: i32.const 0
)

SAMPLE_WASM_BINDGEN_GLUE = """\
let wasm;
let cachedUint8ArrayMemory0 = null;

export function greet_user(name) {
    const url = import.meta.url;
    const meta = import.meta;
    return "Hello, " + name;
}

export function checked_divide(a, b) {
    return (a / b) | 0;
}

function __wbg_get_imports() {
    return { wbg: {} };
}

function __wbg_finalize_init(instance) {
    wasm = instance.exports;
}

export { __wbg_finalize_init as initSync };
export default __wbg_finalize_init;
"""

SAMPLE_RUST_LIB_RS = """\
use wasm_bindgen::prelude::*;

fn is_double_quote(c: char) -> bool {
    c == '"'
}

// #[wasm_bindgen]
// pub fn commented_out_fn(x: i32) -> i32 { x }

/*
#[wasm_bindgen]
pub fn block_commented_fn(y: i64) -> i64 { y }
*/

#[wasm_bindgen]
pub fn greet_user(name: &str) -> String {
    format!("Hello, {}!", name)
}

#[wasm_bindgen]
#[allow(unused_mut)]
pub fn checked_divide(#[allow(unused)] mut a: i32, b: i32) -> Result<i32, Box<dyn std::error::Error>> {
    Ok(a / b)
}

#[wasm_bindgen]
pub const fn transform_bytes(payload: &'static [u8], flag: Option<bool>) -> Vec<u8> {
    let _ = flag;
    Vec::new()
}

#[wasm_bindgen]
pub fn spi_fetch_count() -> Result<i64, String> {
    Ok(42)
}
"""


class TestStandaloneTools(unittest.TestCase):
  """End-to-end unit and integration tests for pgtle_tools, tle-pack, and pgwasm-pack."""

  @classmethod
  def setUpClass(cls) -> None:
    build_dist.sync_standalone_scripts()
    dist_dir = TOOLS_DIR / "dist"
    expected = (
        dist_dir / f"pgtle_tools-{pgtle_tools.__version__}-py3-none-any.whl",
        dist_dir / f"pgtle_tools-{pgtle_tools.__version__}.tar.gz",
        dist_dir / "tle-pack.pyz",
        dist_dir / "pgwasm-pack.pyz",
        dist_dir / f"pgtle-tools-standalone-{pgtle_tools.__version__}.tar.gz",
    )
    if not all(p.is_file() for p in expected):
      build_dist.main()

  def test_no_hardcoded_local_paths_and_script_parity(self) -> None:
    top_tle = (TOOLS_DIR / "tle-pack").read_text(encoding="utf-8")
    mod_tle = (TOOLS_DIR / "pgtle_tools" / "tle_pack.py").read_text(encoding="utf-8")
    top_wasm_py = (TOOLS_DIR / "pgwasm_pack.py").read_text(encoding="utf-8")
    top_wasm_bin = (TOOLS_DIR / "pgwasm-pack").read_text(encoding="utf-8")
    mod_wasm = (TOOLS_DIR / "pgtle_tools" / "pgwasm_pack.py").read_text(encoding="utf-8")

    self.assertEqual(top_tle, mod_tle)
    self.assertEqual(top_wasm_py, mod_wasm)
    self.assertEqual(top_wasm_bin, mod_wasm)

    for content in (top_tle, top_wasm_py):
      self.assertNotIn("/usr/local/google/home/", content)
      self.assertNotIn("hannuk", content)

  def test_resolve_default_psql_bin(self) -> None:
    orig_env = os.environ.get("TLE_PACK_PSQL")
    try:
      os.environ["TLE_PACK_PSQL"] = "/custom/path/to/psql"
      self.assertEqual(tle_pack.resolve_default_psql_bin(), "/custom/path/to/psql")
      del os.environ["TLE_PACK_PSQL"]
      resolved = tle_pack.resolve_default_psql_bin()
      self.assertTrue(resolved.endswith("psql"))
      self.assertNotIn("/usr/local/google/home/", resolved)
    finally:
      if orig_env is not None:
        os.environ["TLE_PACK_PSQL"] = orig_env
      else:
        os.environ.pop("TLE_PACK_PSQL", None)

  def test_tle_pack_js_package_and_comment_safety(self) -> None:
    with tempfile.TemporaryDirectory() as tmp:
      pkg_dir = pathlib.Path(tmp) / "analytics_pkg"
      (pkg_dir / "lib").mkdir(parents=True)
      (pkg_dir / "package.json").write_text(
          json.dumps({
              "name": "@pgtle/analytics-kit",
              "version": "2.1.0",
              "description": "Analytics JS kit",
              "exports": {".": {"import": "./index.mjs"}},
              "pgtle": {
                  "requires": ["plv8"],
                  "functions": [
                      {
                          "name": "js_score",
                          "export": "computeScore",
                          "args": [{"name": "val", "type": "int4"}],
                          "returns": "int4",
                      }
                  ],
              },
          }),
          encoding="utf-8",
      )
      # Include:
      # - commented-out imports that do NOT exist on disk
      # - `export function` followed by a comment containing `from './does_not_exist_either.js'`
      # - a string literal containing `/*.js` before a valid `import` followed by a block comment
      # - a string literal containing `require('./fake.js')`
      # - a dollar-quote tag collision string
      (pkg_dir / "index.mjs").write_text(
          "// import { nope } from './does_not_exist.js';\n"
          "/* require('./also_missing.js') */\n"
          "export function helperBeforeImport(a, b) {\n"
          "  // derived from './does_not_exist_either.js'\n"
          "  return a + b;\n"
          "}\n"
          "const globPattern = '/*.js';\n"
          "const hintMsg = \"Do not call require('./fake_in_string.js') or import './fake2.js'\";\n"
          "import { scale } from './lib/math.js';\n"
          "/* trailing block comment */\n"
          "export function computeScore(x) {\n"
          "  const tag = '$tle_mod_2$';\n"
          "  return scale(x, 3);\n"
          "}\n",
          encoding="utf-8",
      )
      (pkg_dir / "lib" / "math.js").write_text(
          "export function scale(a, b) { return a * b; }\n",
          encoding="utf-8",
      )

      out_sql = pathlib.Path(tmp) / "analytics.sql"
      rc = tle_pack.main([
          "js",
          str(pkg_dir),
          "--as-extension",
          "--compile-bytecode",
          "-o",
          str(out_sql),
      ])
      self.assertEqual(rc, 0)
      sql = out_sql.read_text(encoding="utf-8")
      self.assertIn("Package: pgtle_analytics_kit@2.1.0", sql)
      self.assertIn("'pgtle_analytics_kit/lib/math'", sql)
      self.assertIn("from 'tle:pgtle_analytics_kit/lib/math@2.1.0'", sql)
      self.assertIn("$tle_mod_2_1$", sql)  # Collision-free dollar quote tag
      self.assertIn('CREATE OR REPLACE FUNCTION "js_score"("val" int4)', sql)
      self.assertIn('CREATE EXTENSION IF NOT EXISTS "pgtle_analytics_kit";', sql)

  def test_tle_pack_js_edge_cases(self) -> None:
    with tempfile.TemporaryDirectory() as tmp:
      tmp_path = pathlib.Path(tmp)

      # 1. Circular dependency detection
      circ_dir = tmp_path / "circ"
      circ_dir.mkdir()
      (circ_dir / "a.js").write_text("import './b.js';\n", encoding="utf-8")
      (circ_dir / "b.js").write_text("import './a.js';\n", encoding="utf-8")
      with self.assertRaises(ValueError) as ctx:
        tle_pack.collect_js_module_graph(circ_dir / "a.js", None, None)
      self.assertIn("Circular module dependency", str(ctx.exception))

      # 2. Escaping package root detection
      esc_dir = tmp_path / "esc" / "sub"
      esc_dir.mkdir(parents=True)
      (esc_dir / "index.js").write_text("import '../../outside.js';\n", encoding="utf-8")
      with self.assertRaises(ValueError) as ctx2:
        tle_pack.collect_js_module_graph(esc_dir, None, None)
      self.assertIn("escapes package root", str(ctx2.exception))

      # 3. Missing psql binary when --compile-bytecode and --dsn are passed
      valid_js = tmp_path / "single.js"
      valid_js.write_text("export const x = 1;\n", encoding="utf-8")
      with self.assertRaises(FileNotFoundError) as ctx3:
        tle_pack.main([
            "js",
            str(valid_js),
            "--compile-bytecode",
            "--dsn",
            "postgresql://localhost/postgres",
            "--psql-bin",
            "/nonexistent/psql_binary_xyz",
        ])
      self.assertIn("not found", str(ctx3.exception))

      # 4. --create-extension without --as-extension in JS mode still registers extension
      create_ext_sql = tmp_path / "single_create_ext.sql"
      rc_ce = tle_pack.main([
          "--create-extension",
          "-o",
          str(create_ext_sql),
          str(valid_js),
      ])
      self.assertEqual(rc_ce, 0)
      ce_sql_text = create_ext_sql.read_text(encoding="utf-8")
      self.assertIn("PERFORM pgtle.install_extension(", ce_sql_text)
      self.assertIn('CREATE EXTENSION IF NOT EXISTS "single";', ce_sql_text)

  def test_tle_pack_wasm_introspection_and_glue_js(self) -> None:
    info = tle_pack.introspect_wasm_binary(SAMPLE_WASM_BYTES)
    self.assertTrue(info["has_memory"])
    fn_names = [f["name"] for f in info["functions"]]
    self.assertEqual(fn_names, ["add_i32", "mul_i64"])  # 'alloc' is filtered out
    self.assertEqual(info["functions"][0]["returns"], "int4")
    self.assertEqual(info["functions"][1]["returns"], "int8")

    # Invalid magic header & truncated section edge cases
    with self.assertRaises(ValueError):
      tle_pack.introspect_wasm_binary(b"not_a_wasm_file")
    with self.assertRaises(ValueError):
      tle_pack.introspect_wasm_binary(tle_pack.WASM_MAGIC + b"\x01\x7f\x00")

    with tempfile.TemporaryDirectory() as tmp:
      tmp_path = pathlib.Path(tmp)
      wasm_file = tmp_path / "demo_bg.wasm"
      glue_file = tmp_path / "demo.js"
      manifest_file = tmp_path / "manifest.json"
      out_sql = tmp_path / "demo.sql"

      wasm_file.write_bytes(SAMPLE_WASM_BYTES)
      glue_file.write_text(SAMPLE_WASM_BINDGEN_GLUE, encoding="utf-8")
      manifest_file.write_text(
          json.dumps({
              "functions": [
                  {"name": "sql_add_i32", "export": "add_i32"},
              ]
          }),
          encoding="utf-8",
      )

      # Also verify option flags before positional input and automatic `_bg` stem stripping
      rc = tle_pack.main([
          "--version",
          "1.2.0",
          "--manifest",
          str(manifest_file),
          "--auto-discover-exports",
          "--function-prefix",
          "auto_",
          "--glue-js",
          str(glue_file),
          "--create-extension",
          "-o",
          str(out_sql),
          str(wasm_file),
      ])
      self.assertEqual(rc, 0)
      sql = out_sql.read_text(encoding="utf-8")
      self.assertIn("SELECT pgtle.install_wasm_extension(", sql)
      self.assertIn("'demo'", sql)  # `_bg` suffix stripped automatically
      self.assertIn('"sql_add_i32"', sql)
      self.assertIn('"auto_mul_i64"', sql)
      self.assertIn("__wbg_set_wasm", sql)
      self.assertIn("typeof add_i32 !== 'undefined'", sql)
      self.assertNotIn("import.meta.url", sql)
      self.assertIn('CREATE EXTENSION IF NOT EXISTS "demo";', sql)

  def test_pgwasm_pack_rust_parsing_and_prebuilt_mode(self) -> None:
    exports = pgwasm_pack.parse_rust_exports(SAMPLE_RUST_LIB_RS)
    self.assertEqual(
        exports,
        [
            ("greet_user", [("name", "text")], "text"),
            ("checked_divide", [("a", "integer"), ("b", "integer")], "integer"),
            ("transform_bytes", [("payload", "bytea"), ("flag", "boolean")], "bytea"),
            ("spi_fetch_count", [], "bigint"),
        ],
    )
    with self.assertRaises(ValueError):
      pgwasm_pack.map_rust_type("HashMap<String, i32>")

    with tempfile.TemporaryDirectory() as tmp:
      tmp_path = pathlib.Path(tmp)
      wasm_file = tmp_path / "sample_udf_bg.wasm"
      js_file = tmp_path / "sample_udf.js"
      rs_file = tmp_path / "lib.rs"
      out_sql = tmp_path / "sample_udf.sql"
      out_ext_sql = tmp_path / "sample_udf_ext.sql"

      wasm_file.write_bytes(SAMPLE_WASM_BYTES)
      # Include a '$plv8_wasm_glue$' literal to verify collision-free dollar quoting
      js_file.write_text(
          SAMPLE_WASM_BINDGEN_GLUE + "\nconst collision = '$plv8_wasm_glue$';\n",
          encoding="utf-8",
      )
      rs_file.write_text(SAMPLE_RUST_LIB_RS, encoding="utf-8")

      # 1. Direct plv8_wasm_modules SQL bundle
      rc1 = pgwasm_pack.main([
          "--wasm",
          str(wasm_file),
          "--js",
          str(js_file),
          "--src",
          str(rs_file),
          "--module-name",
          "sample_udf",
          "--out-sql",
          str(out_sql),
      ])
      self.assertEqual(rc1, 0)
      sql1 = out_sql.read_text(encoding="utf-8")
      self.assertIn("INSERT INTO public.plv8_wasm_modules", sql1)
      self.assertIn("$plv8_wasm_glue_1$", sql1)
      self.assertIn("CREATE OR REPLACE FUNCTION public.greet_user(name text)", sql1)
      self.assertIn("CREATE OR REPLACE FUNCTION public.transform_bytes(payload bytea, flag boolean)", sql1)

      # 2. pg_tle extension mode (--create-extension implying --as-extension)
      rc2 = pgwasm_pack.main([
          "--wasm",
          str(wasm_file),
          "--glue-js",
          str(js_file),
          "--src",
          str(rs_file),
          "--create-extension",
          "-o",
          str(out_ext_sql),
      ])
      self.assertEqual(rc2, 0)
      sql2 = out_ext_sql.read_text(encoding="utf-8")
      self.assertIn("SELECT pgtle.install_wasm_extension(", sql2)
      self.assertIn("'sample_udf'", sql2)
      self.assertIn('"volatility": "VOLATILE"', sql2)  # for spi_fetch_count
      self.assertIn('CREATE EXTENSION IF NOT EXISTS "sample_udf";', sql2)

  def test_pgwasm_pack_crate_dir_workflow_with_mock_toolchain(self) -> None:
    with tempfile.TemporaryDirectory() as tmp:
      tmp_path = pathlib.Path(tmp)
      # Test a multi-crate Cargo workspace with `version.workspace = true`
      # where `target/` is placed at `<workspace_root>/target/` rather than `<crate_dir>/target/`
      ws_root = tmp_path / "workspace"
      crate_dir = ws_root / "crates" / "my-hyphen-crate"
      (crate_dir / "src").mkdir(parents=True)
      (ws_root / "Cargo.toml").write_text(
          '[workspace]\nmembers = ["crates/my-hyphen-crate"]\n\n[workspace.package]\nversion = "0.4.2"\nedition = "2021"\n',
          encoding="utf-8",
      )
      (crate_dir / "Cargo.toml").write_text(
          '[package]\nname = "my-hyphen-crate"\nversion.workspace = true\nedition.workspace = true\n',
          encoding="utf-8",
      )
      (crate_dir / "src" / "lib.rs").write_text(SAMPLE_RUST_LIB_RS, encoding="utf-8")

      # Create mock `cargo` and `wasm-bindgen` binaries in a temporary bin dir
      mock_bin = tmp_path / "mock_bin"
      mock_bin.mkdir()
      wasm_hex = SAMPLE_WASM_BYTES.hex()
      ws_target_rel = ws_root / "target" / "wasm32-unknown-unknown" / "release"

      mock_cargo = mock_bin / "cargo"
      mock_cargo.write_text(
          "#!/usr/bin/env python3\n"
          "import os, pathlib, sys\n"
          "if 'update' in sys.argv:\n"
          "    sys.exit(1)  # Simulate offline environment where `cargo update` fails\n"
          "if 'build' in sys.argv:\n"
          f"    rel = pathlib.Path(os.environ.get('CARGO_TARGET_DIR', {str(ws_root / 'target')!r})) / 'wasm32-unknown-unknown' / 'release'\n"
          "    rel.mkdir(parents=True, exist_ok=True)\n"
          f"    (rel / 'my_hyphen_crate.wasm').write_bytes(bytes.fromhex('{wasm_hex}'))\n",
          encoding="utf-8",
      )
      mock_cargo.chmod(0o755)

      mock_wbg = mock_bin / "wasm-bindgen"
      mock_wbg.write_text(
          "#!/usr/bin/env python3\n"
          "import pathlib, sys\n"
          "if '--version' in sys.argv:\n"
          "    print('wasm-bindgen 0.2.100')\n"
          "    sys.exit(0)\n"
          "out_idx = sys.argv.index('--out-dir') + 1\n"
          "out_dir = pathlib.Path(sys.argv[out_idx])\n"
          "wasm_in = pathlib.Path(sys.argv[-1])\n"
          "stem = wasm_in.stem\n"
          "out_dir.mkdir(parents=True, exist_ok=True)\n"
          "(out_dir / f'{stem}_bg.wasm').write_bytes(wasm_in.read_bytes())\n"
          "(out_dir / f'{stem}.js').write_text("
          + repr(SAMPLE_WASM_BINDGEN_GLUE)
          + ", encoding='utf-8')\n",
          encoding="utf-8",
      )
      mock_wbg.chmod(0o755)

      out_sql = tmp_path / "crate_out.sql"
      orig_path = os.environ.get("PATH", "")
      try:
        os.environ["PATH"] = f"{mock_bin}:{orig_path}"
        rc = pgwasm_pack.main([
            "--crate-dir",
            str(crate_dir),
            "--module-name",
            "custom_ws_mod",
            "--as-extension",
            "-o",
            str(out_sql),
        ])
        self.assertEqual(rc, 0)
        self.assertTrue((ws_target_rel / "my_hyphen_crate.wasm").is_file())
      finally:
        os.environ["PATH"] = orig_path

      sql = out_sql.read_text(encoding="utf-8")
      self.assertIn("'custom_ws_mod'", sql)
      self.assertIn("'0.4.2'", sql)  # Inherited from workspace Cargo.toml!
      self.assertIn('"greet_user"', sql)

  def test_standalone_dist_artifacts_zipapps_wheel_and_installer(self) -> None:
    dist_dir = TOOLS_DIR / "dist"
    whl_path = dist_dir / f"pgtle_tools-{pgtle_tools.__version__}-py3-none-any.whl"
    sdist_path = dist_dir / f"pgtle_tools-{pgtle_tools.__version__}.tar.gz"
    tle_pyz = dist_dir / "tle-pack.pyz"
    wasm_pyz = dist_dir / "pgwasm-pack.pyz"
    bundle_path = dist_dir / f"pgtle-tools-standalone-{pgtle_tools.__version__}.tar.gz"

    for artifact in (whl_path, sdist_path, tle_pyz, wasm_pyz, bundle_path):
      self.assertTrue(artifact.is_file(), f"Missing artifact: {artifact}")
      self.assertGreater(artifact.stat().st_size, 0)

    with tempfile.TemporaryDirectory() as tmp:
      tmp_path = pathlib.Path(tmp)
      wasm_file = tmp_path / "test_mod.wasm"
      wasm_file.write_bytes(SAMPLE_WASM_BYTES)

      # 1. Verify single-file scripts copied to an isolated folder with no pgtle_tools package
      iso_bin = tmp_path / "iso_bin"
      iso_bin.mkdir()
      shutil.copy2(TOOLS_DIR / "tle-pack", iso_bin / "tle-pack")
      shutil.copy2(TOOLS_DIR / "pgwasm_pack.py", iso_bin / "pgwasm_pack.py")

      res_tle = subprocess.run(
          [str(iso_bin / "tle-pack"), "--version"],
          cwd=tmp_path,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn(f"tle-pack {pgtle_tools.__version__}", res_tle.stdout)

      res_wasm = subprocess.run(
          [str(iso_bin / "pgwasm_pack.py"), "--version"],
          cwd=tmp_path,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn(f"pgwasm-pack {pgtle_tools.__version__}", res_wasm.stdout)

      # 2. Verify PEP 441 .pyz zipapps executed from an isolated directory
      res_pyz_tle = subprocess.run(
          [str(tle_pyz), "wasm", str(wasm_file), "--name", "pyz_ext"],
          cwd=tmp_path,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn("SELECT pgtle.install_wasm_extension(", res_pyz_tle.stdout)
      self.assertIn("'pyz_ext'", res_pyz_tle.stdout)

      res_pyz_wasm = subprocess.run(
          [str(wasm_pyz), "-V"],
          cwd=tmp_path,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn(pgtle_tools.__version__, res_pyz_wasm.stdout)

      # 3. Verify PEP 427 Wheel extraction & module execution in isolated PYTHONPATH
      site_dir = tmp_path / "site_packages"
      with zipfile.ZipFile(whl_path, "r") as zf:
        zf.extractall(site_dir)
      entry_pts = (
          site_dir
          / f"pgtle_tools-{pgtle_tools.__version__}.dist-info"
          / "entry_points.txt"
      ).read_text(encoding="utf-8")
      self.assertIn("tle-pack = pgtle_tools.tle_pack:main", entry_pts)
      self.assertIn("pgwasm-pack = pgtle_tools.pgwasm_pack:main", entry_pts)

      env = dict(os.environ)
      env["PYTHONPATH"] = str(site_dir)
      res_mod = subprocess.run(
          [sys.executable, "-m", "pgtle_tools", "tle-pack", "wasm", str(wasm_file)],
          cwd=tmp_path,
          env=env,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn("SELECT pgtle.install_wasm_extension(", res_mod.stdout)

      # 4. Verify standalone release tarball + install.sh (--prefix and --uninstall)
      extract_dir = tmp_path / "extracted_bundle"
      with tarfile.open(bundle_path, "r:gz") as tf:
        try:
          tf.extractall(extract_dir, filter="data")
        except TypeError:
          tf.extractall(extract_dir)
      bundle_root = extract_dir / f"pgtle-tools-{pgtle_tools.__version__}"
      install_prefix = tmp_path / "prefix"
      install_site = tmp_path / "prefix_site"

      subprocess.run(
          [
              str(bundle_root / "install.sh"),
              "--prefix",
              str(install_prefix),
              "--python-site",
              str(install_site),
          ],
          cwd=bundle_root,
          check=True,
          capture_output=True,
      )
      for installed_bin in (
          "tle-pack",
          "pgwasm-pack",
          "pgwasm_pack.py",
          "pg_tle_manage_local_extension.sh",
      ):
        bin_path = install_prefix / "bin" / installed_bin
        self.assertTrue(bin_path.is_file(), f"Missing installed binary {bin_path}")
        self.assertTrue(os.access(bin_path, os.X_OK))

      # Verify pg_tle_manage_local_extension.sh -V and --version
      res_manage_ver = subprocess.run(
          [str(install_prefix / "bin" / "pg_tle_manage_local_extension.sh"), "-V"],
          cwd=tmp_path,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn("pg_tle_manage_local_extension.sh", res_manage_ver.stdout)

      res_installed = subprocess.run(
          [str(install_prefix / "bin" / "tle-pack"), "wasm", str(wasm_file)],
          cwd=tmp_path,
          capture_output=True,
          text=True,
          check=True,
      )
      self.assertIn("SELECT pgtle.install_wasm_extension(", res_installed.stdout)

      subprocess.run(
          [
              str(bundle_root / "install.sh"),
              "--prefix",
              str(install_prefix),
              "--python-site",
              str(install_site),
              "--uninstall",
          ],
          cwd=bundle_root,
          check=True,
          capture_output=True,
      )
      self.assertFalse((install_prefix / "bin" / "tle-pack").exists())
      self.assertFalse((install_site / "pgtle_tools").exists())

      # 5. Verify sdist archive completeness (PKG-INFO, MANIFEST.in, pg_tle_manage_local_extension.sh)
      #    and rebuilding dist from inside the extracted sdist
      sdist_extract = tmp_path / "extracted_sdist"
      with tarfile.open(sdist_path, "r:gz") as tf:
        sdist_members = set(tf.getnames())
        try:
          tf.extractall(sdist_extract, filter="data")
        except TypeError:
          tf.extractall(sdist_extract)
      sdist_root_name = f"pgtle_tools-{pgtle_tools.__version__}"
      self.assertIn(f"{sdist_root_name}/PKG-INFO", sdist_members)
      self.assertIn(f"{sdist_root_name}/MANIFEST.in", sdist_members)
      self.assertIn(
          f"{sdist_root_name}/pg_tle_manage_local_extension/pg_tle_manage_local_extension.sh",
          sdist_members,
      )
      sdist_root = sdist_extract / sdist_root_name
      subprocess.run(
          [sys.executable, "./build_dist.py"],
          cwd=sdist_root,
          check=True,
          capture_output=True,
      )
      sdist_install_prefix = tmp_path / "sdist_prefix"
      subprocess.run(
          [str(sdist_root / "install.sh"), "--prefix", str(sdist_install_prefix)],
          cwd=sdist_root,
          check=True,
          capture_output=True,
      )
      self.assertTrue(
          (sdist_install_prefix / "bin" / "pg_tle_manage_local_extension.sh").is_file()
      )

      # 6. Verify PEP 517 in-tree build backend hooks and setuptools.build_meta compatibility
      pep517_out = tmp_path / "pep517_out"
      pep517_out.mkdir()
      self.assertEqual(build_dist.get_requires_for_build_wheel(), [])
      self.assertEqual(build_dist.get_requires_for_build_sdist(), [])
      meta_dir_name = build_dist.prepare_metadata_for_build_wheel(str(pep517_out))
      self.assertTrue((pep517_out / meta_dir_name / "METADATA").is_file())
      whl_name = build_dist.build_wheel(str(pep517_out))
      sdist_name = build_dist.build_sdist(str(pep517_out))
      self.assertTrue((pep517_out / whl_name).is_file())
      self.assertTrue((pep517_out / sdist_name).is_file())

      try:
        import setuptools.build_meta  # noqa: F401

        st_out = tmp_path / "setuptools_out"
        st_out.mkdir()
        st_whl, st_sdist = build_dist.build_wheel_and_sdist(st_out, use_setuptools=True)
        self.assertTrue(st_whl.is_file())
        self.assertTrue(st_sdist.is_file())
      except ImportError:
        pass

      # 7. Verify live `pip install` on both the .whl and the .tar.gz sdist if `pip` is available
      pip_bin = shutil.which("pip") or shutil.which("pip3")
      if not pip_bin:
        cand_pip = pathlib.Path(
            "/usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/pip"
        )
        if cand_pip.is_file() and os.access(cand_pip, os.X_OK):
          pip_bin = str(cand_pip)
      if pip_bin:
        for idx, pkg_artifact in enumerate((whl_path, sdist_path)):
          pip_target = tmp_path / f"pip_target_{idx}"
          subprocess.run(
              [
                  pip_bin,
                  "install",
                  "--no-deps",
                  "--no-build-isolation",
                  "--target",
                  str(pip_target),
                  str(pkg_artifact),
              ],
              check=True,
              capture_output=True,
          )
          pip_env = dict(os.environ)
          pip_env["PYTHONPATH"] = str(pip_target)
          for script_name in ("tle-pack", "pgwasm-pack", "pgwasm_pack"):
            script_path = pip_target / "bin" / script_name
            self.assertTrue(script_path.is_file(), f"Missing pip script: {script_path}")
            res_pip_bin = subprocess.run(
                [str(script_path), "--version"],
                env=pip_env,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn(pgtle_tools.__version__, res_pip_bin.stdout)

  def test_end_to_end_postgres_execution_if_available(self) -> None:
    pg_config_bin: str | None = None
    candidates = [
        os.environ.get("PG_CONFIG", ""),
        str(TOOLS_DIR.parent.parent / "pg_install" / "bin" / "pg_config"),
        shutil.which("pg_config") or "",
    ]
    for cand in candidates:
      if cand and pathlib.Path(cand).is_file() and os.access(cand, os.X_OK):
        pg_config_bin = cand
        break
    if not pg_config_bin:
      self.skipTest("pg_config not available for live PostgreSQL verification")

    bindir = pathlib.Path(
        subprocess.run(
            [pg_config_bin, "--bindir"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    sharedir = pathlib.Path(
        subprocess.run(
            [pg_config_bin, "--sharedir"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    if not (sharedir / "extension" / "pg_tle.control").is_file() or not (
        sharedir / "extension" / "plv8.control"
    ).is_file():
      self.skipTest("pg_tle / plv8 extensions not installed in pg_config sharedir")

    tle_pyz = TOOLS_DIR / "dist" / "tle-pack.pyz"
    wasm_pyz = TOOLS_DIR / "dist" / "pgwasm-pack.pyz"

    with tempfile.TemporaryDirectory() as tmp:
      tmp_path = pathlib.Path(tmp)
      pgdata = tmp_path / "pgdata"
      server_log = tmp_path / "server.log"
      port = 55489

      subprocess.run(
          [str(bindir / "initdb"), "-D", str(pgdata), "--no-instructions"],
          check=True,
          capture_output=True,
      )
      with (pgdata / "postgresql.conf").open("a", encoding="utf-8") as cf:
        cf.write(
            "\nshared_preload_libraries = 'pg_tle,plv8-4.0.0-ALPHA'\n"
            "listen_addresses = ''\n"
            f"unix_socket_directories = '{tmp_path}'\n"
            f"port = {port}\n"
            "log_min_messages = warning\n"
        )

      subprocess.run(
          [str(bindir / "pg_ctl"), "-D", str(pgdata), "-l", str(server_log), "start"],
          check=True,
          capture_output=True,
      )
      try:
        dsn = f"host={tmp_path} port={port} dbname=postgres"
        env = dict(os.environ)
        env["PG_CONFIG"] = pg_config_bin
        env.pop("TLE_PACK_PSQL", None)

        # 1. Test tle-pack.pyz js with offline --compile-bytecode via auto-resolved psql
        js_pkg = tmp_path / "js_pkg"
        js_pkg.mkdir()
        (js_pkg / "package.json").write_text(
            json.dumps({
                "name": "e2e_js_pkg",
                "version": "1.0.0",
                "main": "index.js",
                "pgtle": {
                    "functions": [
                        {
                            "name": "e2e_js_triple",
                            "export": "triple",
                            "args": [{"name": "x", "type": "int4"}],
                            "returns": "int4",
                        }
                    ]
                },
            }),
            encoding="utf-8",
        )
        (js_pkg / "index.js").write_text(
            "export function triple(x) { return x * 3; }\n",
            encoding="utf-8",
        )
        js_sql = tmp_path / "e2e_js.sql"
        subprocess.run(
            [
                str(tle_pyz),
                "js",
                str(js_pkg),
                "--as-extension",
                "--compile-bytecode",
                "--dsn",
                dsn,
                "-o",
                str(js_sql),
            ],
            env=env,
            check=True,
            capture_output=True,
        )

        # 2. Test tle-pack.pyz wasm with BOTH --glue-js and --auto-discover-exports
        #    (verifying raw WASM exports `add_i32`/`mul_i64` coexist with JS glue without ReferenceError!)
        wasm_file = tmp_path / "e2e_raw.wasm"
        wasm_file.write_bytes(SAMPLE_WASM_BYTES)
        wbg_js = tmp_path / "e2e_wbg.js"
        wbg_js.write_text(SAMPLE_WASM_BINDGEN_GLUE, encoding="utf-8")
        wasm_sql = tmp_path / "e2e_raw_wasm.sql"
        subprocess.run(
            [
                str(tle_pyz),
                "wasm",
                str(wasm_file),
                "--name",
                "e2e_raw_wasm",
                "--glue-js",
                str(wbg_js),
                "--auto-discover-exports",
                "--create-extension",
                "-o",
                str(wasm_sql),
            ],
            env=env,
            check=True,
            capture_output=True,
        )

        # 3. Test pgwasm-pack.pyz --wasm / --js / --src
        wbg_rs = tmp_path / "e2e_wbg.rs"
        wbg_sql = tmp_path / "e2e_wbg.sql"
        wbg_rs.write_text(
            "#[wasm_bindgen]\npub fn checked_divide(a: i32, b: i32) -> Result<i32, Box<dyn std::error::Error>> { Ok(a / b) }\n",
            encoding="utf-8",
        )
        subprocess.run(
            [
                str(wasm_pyz),
                "--wasm",
                str(wasm_file),
                "--js",
                str(wbg_js),
                "--src",
                str(wbg_rs),
                "--module-name",
                "e2e_wbg_ext",
                "--create-extension",
                "-o",
                str(wbg_sql),
            ],
            env=env,
            check=True,
            capture_output=True,
        )

        # Execute all 3 SQL bundles and verify UDF execution in PostgreSQL
        psql_bin = str(bindir / "psql")
        for sql_file in (js_sql, wasm_sql, wbg_sql):
          subprocess.run(
              [psql_bin, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", dsn, "-f", str(sql_file)],
              check=True,
              capture_output=True,
          )

        verify_res = subprocess.run(
            [
                psql_bin,
                "-X",
                "-q",
                "-t",
                "-A",
                "-v",
                "ON_ERROR_STOP=1",
                "-d",
                dsn,
                "-c",
                "SELECT e2e_js_triple(14), add_i32(20, 22), mul_i64(6, 7), checked_divide(84, 2);",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(verify_res.stdout.strip(), "42|42|42|42")

        # 4. If Go compiler is available, compile a real Go wasip1 `.wasm` reactor binary,
        #    package it with tle-pack.pyz wasm, and execute it inside PostgreSQL!
        go_bin = shutil.which("go")
        if go_bin:
          go_dir = tmp_path / "go_wasm_proj"
          go_dir.mkdir()
          (go_dir / "go.mod").write_text("module gowasm_e2e\ngo 1.24\n", encoding="utf-8")
          (go_dir / "main.go").write_text(
              "package main\n"
              "//go:wasmexport go_fibonacci\n"
              "func goFibonacci(n int64) int64 {\n"
              "    if n <= 1 { return n }\n"
              "    var a, b int64 = 0, 1\n"
              "    for i := int64(2); i <= n; i++ { a, b = b, a+b }\n"
              "    return b\n"
              "}\n"
              "func main() {}\n",
              encoding="utf-8",
          )
          go_wasm = go_dir / "gowasm_e2e.wasm"
          go_env = dict(os.environ)
          go_env["GOOS"] = "wasip1"
          go_env["GOARCH"] = "wasm"
          go_env["GOCACHE"] = str(tmp_path / "gocache")
          subprocess.run(
              [go_bin, "build", "-buildmode=c-shared", "-ldflags=-s -w", "-o", str(go_wasm), "main.go"],
              cwd=go_dir,
              env=go_env,
              check=True,
              capture_output=True,
          )
          go_sql = tmp_path / "gowasm_e2e.sql"
          subprocess.run(
              [
                  str(tle_pyz),
                  "wasm",
                  str(go_wasm),
                  "--name",
                  "gowasm_e2e",
                  "--create-extension",
                  "-o",
                  str(go_sql),
              ],
              env=env,
              check=True,
              capture_output=True,
          )
          subprocess.run(
              [psql_bin, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", dsn, "-f", str(go_sql)],
              check=True,
              capture_output=True,
          )
          go_res = subprocess.run(
              [
                  psql_bin,
                  "-X",
                  "-q",
                  "-t",
                  "-A",
                  "-v",
                  "ON_ERROR_STOP=1",
                  "-d",
                  dsn,
                  "-c",
                  "SELECT go_fibonacci(10);",
              ],
              check=True,
              capture_output=True,
              text=True,
          )
          self.assertEqual(go_res.stdout.strip(), "55")

        # 5. Verify pg_tle_manage_local_extension.sh --action list against live PostgreSQL
        manage_sh = (
            TOOLS_DIR
            / "pg_tle_manage_local_extension"
            / "pg_tle_manage_local_extension.sh"
        )
        manage_res = subprocess.run(
            [str(manage_sh), "--action", "list", "--connection", dsn],
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("e2e_js_pkg", manage_res.stdout)
        self.assertIn("e2e_raw_wasm", manage_res.stdout)
        self.assertIn("e2e_wbg_ext", manage_res.stdout)
      finally:
        subprocess.run(
            [str(bindir / "pg_ctl"), "-D", str(pgdata), "stop", "-m", "immediate"],
            check=False,
            capture_output=True,
        )

      log_text = server_log.read_text(encoding="utf-8")
      for bad_marker in (
          "cache reference leak",
          "buffer refcount leak",
          "ResourceOwner",
          "TRAP:",
          "PANIC:",
      ):
        self.assertNotIn(bad_marker, log_text)


if __name__ == "__main__":
  unittest.main()
