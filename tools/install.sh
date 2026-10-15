#!/usr/bin/env bash
# Standalone installer for pg_tle out-of-database CLI tools:
#   - tle-pack
#   - pgwasm-pack (and pgwasm_pack.py)
#   - pg_tle_manage_local_extension.sh
#
# Works on any Linux/macOS environment with Python 3.8+ (does NOT require pip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR=""
PYTHON_SITE=""
UNINSTALL=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or uninstall pg_tle standalone CLI tools (tle-pack, pgwasm-pack, pg_tle_manage_local_extension.sh).

Options:
  --prefix <dir>        Installation prefix (default: \$HOME/.local -> $PREFIX)
  --bindir <dir>        Explicit binary directory (default: <prefix>/bin)
  --python-site <dir>   Also install the 'pgtle_tools' Python package into <dir>
  --uninstall           Remove installed binaries (and Python package if --python-site is given)
  -h, --help            Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --bindir)
      BINDIR="$2"
      shift 2
      ;;
    --python-site)
      PYTHON_SITE="$2"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$BINDIR" ]; then
  BINDIR="$PREFIX/bin"
fi

if [ "$UNINSTALL" -eq 1 ]; then
  rm -f "$BINDIR/tle-pack" "$BINDIR/pgwasm-pack" "$BINDIR/pgwasm_pack.py" "$BINDIR/pg_tle_manage_local_extension.sh"
  if [ -n "$PYTHON_SITE" ]; then
    rm -rf "$PYTHON_SITE/pgtle_tools" "$PYTHON_SITE"/pgtle_tools-*.dist-info
  fi
  echo "Uninstalled pg_tle CLI tools from $BINDIR"
  exit 0
fi

mkdir -p "$BINDIR"

# Locate source scripts (supports running from pg_tle/tools/ or from extracted standalone tarball)
if [ -f "$SCRIPT_DIR/tle-pack" ]; then
  SRC_TLE_PACK="$SCRIPT_DIR/tle-pack"
  SRC_PGWASM_PACK="$SCRIPT_DIR/pgwasm_pack.py"
  SRC_MANAGE_SH="$SCRIPT_DIR/pg_tle_manage_local_extension/pg_tle_manage_local_extension.sh"
elif [ -f "$SCRIPT_DIR/bin/tle-pack" ]; then
  SRC_TLE_PACK="$SCRIPT_DIR/bin/tle-pack"
  SRC_PGWASM_PACK="$SCRIPT_DIR/bin/pgwasm_pack.py"
  SRC_MANAGE_SH="$SCRIPT_DIR/bin/pg_tle_manage_local_extension.sh"
else
  echo "ERROR: Could not locate tle-pack in $SCRIPT_DIR" >&2
  exit 1
fi

install -m 0755 "$SRC_TLE_PACK" "$BINDIR/tle-pack"
install -m 0755 "$SRC_PGWASM_PACK" "$BINDIR/pgwasm-pack"
install -m 0755 "$SRC_PGWASM_PACK" "$BINDIR/pgwasm_pack.py"
if [ -f "$SRC_MANAGE_SH" ]; then
  install -m 0755 "$SRC_MANAGE_SH" "$BINDIR/pg_tle_manage_local_extension.sh"
fi

if [ -n "$PYTHON_SITE" ]; then
  mkdir -p "$PYTHON_SITE"
  rm -rf "$PYTHON_SITE/pgtle_tools" "$PYTHON_SITE"/pgtle_tools-*.dist-info
  if ls "$SCRIPT_DIR"/dist/pgtle_tools-*.whl >/dev/null 2>&1; then
    WHL_FILE="$(ls "$SCRIPT_DIR"/dist/pgtle_tools-*.whl | head -n 1)"
    python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$WHL_FILE" "$PYTHON_SITE"
  elif [ -d "$SCRIPT_DIR/pgtle_tools" ]; then
    cp -r "$SCRIPT_DIR/pgtle_tools" "$PYTHON_SITE/pgtle_tools"
  fi
  echo "Installed Python package 'pgtle_tools' into $PYTHON_SITE"
fi

echo "Installed standalone pg_tle CLI tools into $BINDIR:"
echo "  - $BINDIR/tle-pack"
echo "  - $BINDIR/pgwasm-pack"
echo "  - $BINDIR/pgwasm_pack.py"
if [ -f "$BINDIR/pg_tle_manage_local_extension.sh" ]; then
  echo "  - $BINDIR/pg_tle_manage_local_extension.sh"
fi
