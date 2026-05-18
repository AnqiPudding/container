#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="${RUNTIME_COMFYUI_DIR:-/tmp/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"
CUSTOM_NODE_STAGING_DIR="${CUSTOM_NODE_STAGING_DIR:-${DATA_DIR}/custom_nodes_pending}"
RUNTIME_OVERLAY_STAGING_DIR="${RUNTIME_OVERLAY_STAGING_DIR:-${DATA_DIR}/comfyui_overlay_pending}"
BASE_REQUIREMENTS_FILE="${BASE_REQUIREMENTS_FILE:-/opt/comfyui-scripts/base-python-packages.txt}"
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

if [ -f "${BASE_REQUIREMENTS_FILE}" ]; then
  python - "${BASE_REQUIREMENTS_FILE}" "${RUNTIME_OVERLAY_STAGING_DIR}/.modal-runtime-requirements.txt" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

base_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

def package_name(line: str) -> str | None:
    line = line.strip()
    if not line or line.startswith("#") or line.startswith("-e "):
        return None
    match = re.match(r"^([A-Za-z0-9_.-]+)\s*(?:==| @ |===|>=|<=|~=|!=|>|<)", line)
    if match:
        return match.group(1).lower().replace("_", "-")
    return None

base = {}
for raw in base_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    name = package_name(raw)
    if name:
        base[name] = raw.strip()

freeze = subprocess.check_output([sys.executable, "-m", "pip", "freeze", "--all"], text=True)
changed = []
for raw in sorted(freeze.splitlines(), key=str.lower):
    name = package_name(raw)
    if not name:
        continue
    line = raw.strip()
    if base.get(name) != line:
        changed.append(line)

if changed:
    out_path.write_text("\n".join(changed) + "\n", encoding="utf-8")
    print(f"Saved runtime Python package delta to {out_path}.")
elif out_path.exists():
    out_path.unlink()
    print(f"Removed empty runtime Python package delta at {out_path}.")
else:
    print("No runtime Python package changes found.")
PY
else
  echo "Base Python package snapshot is missing; skipping runtime package delta."
fi
