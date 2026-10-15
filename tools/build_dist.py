#!/usr/bin/env python3
"""build_dist.py: Builds standalone distributable packages for pg_tle out-of-database CLI tools.

Produces in `pg_tle/tools/dist/`:
  1. `pgtle_tools-<version>-py3-none-any.whl` (PEP 427 standard Python wheel, installable via `pip`/`pipx`/`uv` or `zipfile`)
  2. `pgtle_tools-<version>.tar.gz` (PEP 517 / PEP 625 Python source distribution)
  3. `tle-pack.pyz` (PEP 441 single-file executable Python zipapp for `tle-pack`)
  4. `pgwasm-pack.pyz` (PEP 441 single-file executable Python zipapp for `pgwasm-pack`)
  5. `pgtle-tools-standalone-<version>.tar.gz` (Self-contained release archive with `bin/`, `pgtle_tools/`, `install.sh`, `README.md`, `LICENSE`)
"""

from __future__ import annotations

import base64
import hashlib
import io
import os
import pathlib
import shutil
import stat
import sys
import tarfile
import tempfile
import zipapp
import zipfile
from typing import Any, Optional

TOOLS_DIR = pathlib.Path(__file__).resolve().parent
DIST_DIR = TOOLS_DIR / "dist"
PKG_DIR = TOOLS_DIR / "pgtle_tools"

sys.path.insert(0, str(TOOLS_DIR))
import pgtle_tools  # noqa: E402

VERSION = pgtle_tools.__version__


def make_executable(path: pathlib.Path) -> None:
  mode = path.stat().st_mode
  path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def sync_standalone_scripts() -> None:
  """Ensures top-level `tle-pack`, `pgwasm_pack.py`, and `pgwasm-pack` match `pgtle_tools/`."""
  tle_src = (PKG_DIR / "tle_pack.py").read_text(encoding="utf-8")
  wasm_src = (PKG_DIR / "pgwasm_pack.py").read_text(encoding="utf-8")

  top_tle = TOOLS_DIR / "tle-pack"
  top_wasm_py = TOOLS_DIR / "pgwasm_pack.py"
  top_wasm_bin = TOOLS_DIR / "pgwasm-pack"

  top_tle.write_text(tle_src, encoding="utf-8")
  top_wasm_py.write_text(wasm_src, encoding="utf-8")
  top_wasm_bin.write_text(wasm_src, encoding="utf-8")

  for p in (
      top_tle,
      top_wasm_py,
      top_wasm_bin,
      PKG_DIR / "tle_pack.py",
      PKG_DIR / "pgwasm_pack.py",
      TOOLS_DIR / "install.sh",
      TOOLS_DIR / "pg_tle_manage_local_extension" / "pg_tle_manage_local_extension.sh",
  ):
    if p.is_file():
      make_executable(p)


def build_wheel_and_sdist(
    dist_dir: pathlib.Path, use_setuptools: bool = False
) -> tuple[pathlib.Path, pathlib.Path]:
  """Builds PEP 427 `.whl` and PEP 517 `.tar.gz` sdist."""
  if use_setuptools:
    import setuptools.build_meta as bm

    orig_cwd = os.getcwd()
    try:
      os.chdir(TOOLS_DIR)
      whl_name = bm.build_wheel(str(dist_dir))
      sdist_name = bm.build_sdist(str(dist_dir))
    finally:
      os.chdir(orig_cwd)
      for leftover in ("build", "pgtle_tools.egg-info"):
        shutil.rmtree(TOOLS_DIR / leftover, ignore_errors=True)
    return dist_dir / whl_name, dist_dir / sdist_name
  return _build_wheel_and_sdist_stdlib(dist_dir)


def _record_hash(data: bytes) -> str:
  digest = hashlib.sha256(data).digest()
  b64 = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
  return f"sha256={b64}"


def _core_metadata_bytes() -> bytes:
  return (
      "Metadata-Version: 2.1\n"
      "Name: pgtle-tools\n"
      f"Version: {VERSION}\n"
      "Summary: Standalone out-of-database CLI packaging & bundling tools (tle-pack and pgwasm-pack) for PostgreSQL pg_tle JS/npm modules and Rust/Go/TinyGo WebAssembly extensions.\n"
      "License: Apache-2.0\n"
      "Requires-Python: >=3.8\n"
      "Description-Content-Type: text/markdown\n\n"
      + (TOOLS_DIR / "README.md").read_text(encoding="utf-8")
  ).encode("utf-8")


def _dist_info_payloads() -> list[tuple[str, bytes]]:
  metadata = _core_metadata_bytes()
  wheel_meta = (
      "Wheel-Version: 1.0\n"
      "Generator: pgtle-tools-build_dist\n"
      "Root-Is-Purelib: true\n"
      "Tag: py3-none-any\n"
  ).encode("utf-8")
  entry_points = (
      "[console_scripts]\n"
      "tle-pack = pgtle_tools.tle_pack:main\n"
      "pgwasm-pack = pgtle_tools.pgwasm_pack:main\n"
      "pgwasm_pack = pgtle_tools.pgwasm_pack:main\n"
  ).encode("utf-8")
  top_level = b"pgtle_tools\n"
  license_bytes = (TOOLS_DIR / "LICENSE").read_bytes()
  return [
      ("METADATA", metadata),
      ("WHEEL", wheel_meta),
      ("entry_points.txt", entry_points),
      ("top_level.txt", top_level),
      ("licenses/LICENSE", license_bytes),
  ]


def _build_wheel_stdlib(dist_dir: pathlib.Path) -> pathlib.Path:
  """Deterministic zero-dependency PEP 427 wheel builder."""
  dist_dir.mkdir(parents=True, exist_ok=True)
  whl_path = dist_dir / f"pgtle_tools-{VERSION}-py3-none-any.whl"
  dist_info = f"pgtle_tools-{VERSION}.dist-info"
  records: list[tuple[str, str, int]] = []

  with zipfile.ZipFile(whl_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for py_file in sorted(PKG_DIR.glob("*.py")):
      arcname = f"pgtle_tools/{py_file.name}"
      data = py_file.read_bytes()
      zf.writestr(arcname, data)
      records.append((arcname, _record_hash(data), len(data)))

    for rel_name, payload in _dist_info_payloads():
      name = f"{dist_info}/{rel_name}"
      zf.writestr(name, payload)
      records.append((name, _record_hash(payload), len(payload)))

    record_lines = [f"{r[0]},{r[1]},{r[2]}" for r in records]
    record_lines.append(f"{dist_info}/RECORD,,")
    zf.writestr(f"{dist_info}/RECORD", ("\n".join(record_lines) + "\n").encode("utf-8"))

  return whl_path


def _build_sdist_stdlib(dist_dir: pathlib.Path) -> pathlib.Path:
  """Deterministic zero-dependency PEP 517 / PEP 625 sdist builder."""
  dist_dir.mkdir(parents=True, exist_ok=True)
  sdist_path = dist_dir / f"pgtle_tools-{VERSION}.tar.gz"
  root_prefix = f"pgtle_tools-{VERSION}"
  pkg_info_bytes = _core_metadata_bytes()

  with tarfile.open(sdist_path, "w:gz") as tf:
    ti = tarfile.TarInfo(name=f"{root_prefix}/PKG-INFO")
    ti.size = len(pkg_info_bytes)
    ti.mode = 0o644
    tf.addfile(ti, io.BytesIO(pkg_info_bytes))

    for rel in (
        "pyproject.toml",
        "MANIFEST.in",
        "setup.py",
        "Makefile",
        "build_dist.py",
        "install.sh",
        "README.md",
        "LICENSE",
        "tle-pack",
        "pgwasm_pack.py",
        "pgwasm-pack",
        "pgtle_tools/__init__.py",
        "pgtle_tools/__main__.py",
        "pgtle_tools/tle_pack.py",
        "pgtle_tools/pgwasm_pack.py",
        "pg_tle_manage_local_extension/pg_tle_manage_local_extension.sh",
        "pg_tle_manage_local_extension/README.md",
        "tests/test_standalone_tools.py",
    ):
      full = TOOLS_DIR / rel
      if full.is_file():
        tf.add(full, arcname=f"{root_prefix}/{rel}")

  return sdist_path


def _build_wheel_and_sdist_stdlib(dist_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
  """Deterministic zero-dependency PEP 427 wheel and PEP 517 sdist builder."""
  return _build_wheel_stdlib(dist_dir), _build_sdist_stdlib(dist_dir)


# ==============================================================================
# PEP 517 / PEP 660 Zero-Dependency In-Tree Build Backend Hooks
# ==============================================================================

def get_requires_for_build_wheel(config_settings: Optional[dict[str, Any]] = None) -> list[str]:
  return []


def get_requires_for_build_sdist(config_settings: Optional[dict[str, Any]] = None) -> list[str]:
  return []


def get_requires_for_build_editable(config_settings: Optional[dict[str, Any]] = None) -> list[str]:
  return []


def prepare_metadata_for_build_wheel(
    metadata_directory: str,
    config_settings: Optional[dict[str, Any]] = None,
) -> str:
  dist_info_name = f"pgtle_tools-{VERSION}.dist-info"
  dist_info_dir = pathlib.Path(metadata_directory) / dist_info_name
  dist_info_dir.mkdir(parents=True, exist_ok=True)
  records: list[tuple[str, str, int]] = []
  for rel_name, payload in _dist_info_payloads():
    dest = dist_info_dir / rel_name
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(payload)
    records.append((f"{dist_info_name}/{rel_name}", _record_hash(payload), len(payload)))
  record_lines = [f"{r[0]},{r[1]},{r[2]}" for r in records]
  record_lines.append(f"{dist_info_name}/RECORD,,")
  (dist_info_dir / "RECORD").write_text("\n".join(record_lines) + "\n", encoding="utf-8")
  return dist_info_name


def build_wheel(
    wheel_directory: str,
    config_settings: Optional[dict[str, Any]] = None,
    metadata_directory: Optional[str] = None,
) -> str:
  whl_path = _build_wheel_stdlib(pathlib.Path(wheel_directory))
  return whl_path.name


def build_editable(
    wheel_directory: str,
    config_settings: Optional[dict[str, Any]] = None,
    metadata_directory: Optional[str] = None,
) -> str:
  return build_wheel(wheel_directory, config_settings, metadata_directory)


def build_sdist(
    sdist_directory: str,
    config_settings: Optional[dict[str, Any]] = None,
) -> str:
  sdist_path = _build_sdist_stdlib(pathlib.Path(sdist_directory))
  return sdist_path.name


def build_zipapps(dist_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
  """Builds single-file executable `.pyz` archives (PEP 441) for `tle-pack` and `pgwasm-pack`."""
  tle_pyz = dist_dir / "tle-pack.pyz"
  wasm_pyz = dist_dir / "pgwasm-pack.pyz"

  with tempfile.TemporaryDirectory() as tmp:
    stage = pathlib.Path(tmp) / "stage"
    stage_pkg = stage / "pgtle_tools"
    stage_pkg.mkdir(parents=True)
    for py_file in PKG_DIR.glob("*.py"):
      shutil.copy2(py_file, stage_pkg / py_file.name)

    zipapp.create_archive(
        stage,
        target=tle_pyz,
        interpreter="/usr/bin/env python3",
        main="pgtle_tools.tle_pack:main",
        compressed=True,
    )
    zipapp.create_archive(
        stage,
        target=wasm_pyz,
        interpreter="/usr/bin/env python3",
        main="pgtle_tools.pgwasm_pack:main",
        compressed=True,
    )

  make_executable(tle_pyz)
  make_executable(wasm_pyz)
  return tle_pyz, wasm_pyz


def build_standalone_tarball(
    dist_dir: pathlib.Path,
    whl_path: pathlib.Path,
    tle_pyz: pathlib.Path,
    wasm_pyz: pathlib.Path,
) -> pathlib.Path:
  """Builds a portable standalone `.tar.gz` bundle containing `bin/`, `pgtle_tools/`, `install.sh`, and docs."""
  bundle_path = dist_dir / f"pgtle-tools-standalone-{VERSION}.tar.gz"
  prefix = f"pgtle-tools-{VERSION}"

  with tarfile.open(bundle_path, "w:gz") as tf:
    tf.add(TOOLS_DIR / "tle-pack", arcname=f"{prefix}/bin/tle-pack")
    tf.add(TOOLS_DIR / "pgwasm-pack", arcname=f"{prefix}/bin/pgwasm-pack")
    tf.add(TOOLS_DIR / "pgwasm_pack.py", arcname=f"{prefix}/bin/pgwasm_pack.py")
    manage_sh = (
        TOOLS_DIR
        / "pg_tle_manage_local_extension"
        / "pg_tle_manage_local_extension.sh"
    )
    if manage_sh.is_file():
      tf.add(manage_sh, arcname=f"{prefix}/bin/pg_tle_manage_local_extension.sh")

    for py_file in sorted(PKG_DIR.glob("*.py")):
      tf.add(py_file, arcname=f"{prefix}/pgtle_tools/{py_file.name}")

    for top_file in ("install.sh", "pyproject.toml", "setup.py", "README.md", "LICENSE"):
      tf.add(TOOLS_DIR / top_file, arcname=f"{prefix}/{top_file}")

    tf.add(whl_path, arcname=f"{prefix}/dist/{whl_path.name}")
    tf.add(tle_pyz, arcname=f"{prefix}/dist/{tle_pyz.name}")
    tf.add(wasm_pyz, arcname=f"{prefix}/dist/{wasm_pyz.name}")

  return bundle_path


def main() -> int:
  sync_standalone_scripts()
  DIST_DIR.mkdir(parents=True, exist_ok=True)
  for old in DIST_DIR.iterdir():
    if old.is_file():
      old.unlink()

  whl_path, sdist_path = build_wheel_and_sdist(DIST_DIR)
  tle_pyz, wasm_pyz = build_zipapps(DIST_DIR)
  bundle_path = build_standalone_tarball(DIST_DIR, whl_path, tle_pyz, wasm_pyz)

  print(f"Built standalone distribution packages in {DIST_DIR}:")
  for artifact in (whl_path, sdist_path, tle_pyz, wasm_pyz, bundle_path):
    print(f"  - {artifact.name} ({artifact.stat().st_size} bytes)")
  return 0


if __name__ == "__main__":
  sys.exit(main())
