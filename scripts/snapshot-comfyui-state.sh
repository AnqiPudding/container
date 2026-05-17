#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="${RUNTIME_COMFYUI_DIR:-/tmp/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"
CUSTOM_NODE_STAGING_DIR="${CUSTOM_NODE_STAGING_DIR:-${DATA_DIR}/custom_nodes_pending}"
RUNTIME_OVERLAY_STAGING_DIR="${RUNTIME_OVERLAY_STAGING_DIR:-${DATA_DIR}/comfyui_overlay_pending}"
CUSTOM_NODE_SETTLE_ATTEMPTS="${CUSTOM_NODE_SETTLE_ATTEMPTS:-10}"
CUSTOM_NODE_SETTLE_SECONDS="${CUSTOM_NODE_SETTLE_SECONDS:-2}"

custom_nodes_fingerprint() {
  if [ ! -d "${COMFYUI_DIR}/custom_nodes" ]; then
    echo "missing"
    return 0
  fi

  find "${COMFYUI_DIR}/custom_nodes" -xdev \
    -path "*/__pycache__" -prune -o \
    -path "*/.git" -prune -o \
    -type f -printf "%P %s %T@\n" 2>/dev/null | sort | sha256sum | awk '{print $1}'
}

wait_for_custom_nodes_to_settle() {
  local previous=""
  local current=""
  local attempt=1

  while [ "${attempt}" -le "${CUSTOM_NODE_SETTLE_ATTEMPTS}" ]; do
    current="$(custom_nodes_fingerprint)"
    if [ -n "${previous}" ] && [ "${current}" = "${previous}" ]; then
      echo "Custom node files are stable."
      return 0
    fi

    previous="${current}"
    echo "Waiting for custom node file changes to settle (${attempt}/${CUSTOM_NODE_SETTLE_ATTEMPTS})."
    sleep "${CUSTOM_NODE_SETTLE_SECONDS}"
    attempt=$((attempt + 1))
  done

  echo "Custom node files did not fully settle; continuing with latest snapshot."
}

remove_incomplete_custom_node_dirs() {
  local custom_nodes_dir="${COMFYUI_DIR}/custom_nodes"

  if [ ! -d "${custom_nodes_dir}" ]; then
    return 0
  fi

  python - "${custom_nodes_dir}" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
for child in sorted(root.iterdir(), key=lambda p: p.name.lower()):
    if not child.is_dir():
        continue
    if child.name in {".disabled", "__pycache__"}:
        continue
    if (child / "__init__.py").exists():
        continue

    print(f"Removing incomplete custom node directory with no __init__.py: {child}")
    shutil.rmtree(child)
PY
}

if [ ! -d "${COMFYUI_DIR}/custom_nodes" ]; then
  echo "No runtime custom_nodes directory found at ${COMFYUI_DIR}/custom_nodes."
  exit 0
fi

wait_for_custom_nodes_to_settle
remove_incomplete_custom_node_dirs
mkdir -p "${CUSTOM_NODE_STAGING_DIR}"
rsync -a --delete \
  --exclude "__pycache__/" \
  --exclude "*.pyc" \
  --exclude ".ipynb_checkpoints/" \
  "${COMFYUI_DIR}/custom_nodes/" "${CUSTOM_NODE_STAGING_DIR}/"

echo "Saved runtime custom nodes to ${CUSTOM_NODE_STAGING_DIR}."

mkdir -p "${RUNTIME_OVERLAY_STAGING_DIR}"
rsync -a --delete \
  --exclude "/.git/" \
  --exclude "/custom_nodes/" \
  --exclude "/models/" \
  --exclude "/input/" \
  --exclude "/output/" \
  --exclude "/temp/" \
  --exclude "/notebooks/" \
  --exclude "/user/default/workflows/" \
  --exclude "__pycache__/" \
  --exclude "*.pyc" \
  --exclude ".ipynb_checkpoints/" \
  "${COMFYUI_DIR}/" "${RUNTIME_OVERLAY_STAGING_DIR}/"

echo "Saved runtime ComfyUI overlay to ${RUNTIME_OVERLAY_STAGING_DIR}."
