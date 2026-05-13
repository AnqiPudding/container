#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${DATA_DIR:-/data}/notebooks"
cd "${DATA_DIR:-/data}"

exec jupyter lab \
  --ip=0.0.0.0 \
  --port="${JUPYTER_PORT:-8888}" \
  --no-browser \
  --allow-root \
  --ServerApp.root_dir="${DATA_DIR:-/data}" \
  --ServerApp.token="${JUPYTER_TOKEN:-modal-comfyui}" \
  --ServerApp.allow_origin="*"
