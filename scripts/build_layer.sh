#!/usr/bin/env bash
# Build the psycopg2 Lambda layer zip (build/psycopg2-layer.zip).
#
# The wheel is downloaded for the Lambda runtime platform explicitly
# (manylinux x86_64, Python 3.12), so the script works from any machine —
# including an ARM Mac, where a plain `pip install` would fetch the wrong
# wheel and the import would fail on Lambda.
#
# Requires: python3, pip, zip. Run from the repo root, or anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
LAYER_DIR="$BUILD_DIR/layer"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v zip >/dev/null || { echo "zip is required" >&2; exit 1; }

rm -rf "$LAYER_DIR" "$BUILD_DIR/psycopg2-layer.zip"
mkdir -p "$LAYER_DIR/python"

python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet \
  --platform manylinux2014_x86_64 \
  --python-version 3.12 \
  --only-binary=:all: \
  --target "$LAYER_DIR/python" \
  -r "$ROOT/src/lambda/requirements.txt"

(cd "$LAYER_DIR" && zip -qr "$BUILD_DIR/psycopg2-layer.zip" python)

echo "Built $BUILD_DIR/psycopg2-layer.zip"
ls -la "$BUILD_DIR/psycopg2-layer.zip"
