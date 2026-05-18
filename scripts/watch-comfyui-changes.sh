#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="${RUNTIME_COMFYUI_DIR:-/tmp/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"
WATCH_INTERVAL_SECONDS="${WATCH_INTERVAL_SECONDS:-30}"
WATCH_SETTLE_SECONDS="${WATCH_SETTLE_SECONDS:-10}"
WATCH_BOOT_GRACE_SECONDS="${WATCH_BOOT_GRACE_SECONDS:-60}"

mkdir -p "${DATA_DIR}"

fingerprint() {
  {
    if [ -d "${COMFYUI_DIR}" ]; then
      find "${COMFYUI_DIR}" -xdev \
        -path "${COMFYUI_DIR}/.git" -prune -o \
        -path "${COMFYUI_DIR}/models" -prune -o \
        -path "${COMFYUI_DIR}/input" -prune -o \
        -path "${COMFYUI_DIR}/output" -prune -o \
        -path "${COMFYUI_DIR}/temp" -prune -o \
        -path "${COMFYUI_DIR}/notebooks" -prune -o \
        -path "${COMFYUI_DIR}/user/default/workflows" -prune -o \
        -path "*/__pycache__" -prune -o \
        -path "*/.ipynb_checkpoints" -prune -o \
        -type f -printf "file %P %s %T@\n" 2>/dev/null | sort
    fi
    python -m pip freeze --all 2>/dev/null | sed 's/^/pip /' | sort -f || true
  } | sha256sum | awk '{print $1}'
}

sleep "${WATCH_BOOT_GRACE_SECONDS}"
previous="$(fingerprint)"
echo "Started ComfyUI bake watcher with initial fingerprint ${previous}."

while true; do
  sleep "${WATCH_INTERVAL_SECONDS}"
  current="$(fingerprint)"
  if [ "${current}" = "${previous}" ]; then
    continue
  fi

  echo "ComfyUI/runtime package changes detected; waiting for files to settle."
  sleep "${WATCH_SETTLE_SECONDS}"
  settled="$(fingerprint)"
  if [ "${settled}" != "${current}" ]; then
    previous="${settled}"
    echo "Changes are still moving; waiting for the next stable pass."
    continue
  fi

  previous="${settled}"
  bash /opt/comfyui-scripts/trigger-bake-to-github.sh "automatic runtime watcher"
done
