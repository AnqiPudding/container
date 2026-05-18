#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/data}"
BAKE_PID_FILE="${BAKE_PID_FILE:-${DATA_DIR}/bake-to-github.pid}"
BAKE_STATUS_FILE="${BAKE_STATUS_FILE:-${DATA_DIR}/bake-status.log}"
reason="${1:-runtime change}"

mkdir -p "${DATA_DIR}"

if [ -f "${BAKE_PID_FILE}" ]; then
  old_pid="$(cat "${BAKE_PID_FILE}" 2>/dev/null || true)"
  if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Replacing in-progress bake ${old_pid}: ${reason}" | tee -a "${BAKE_STATUS_FILE}"
    kill "${old_pid}" 2>/dev/null || true
  fi
fi

(
  bash /opt/comfyui-scripts/bake-to-github.sh
) >>"${BAKE_STATUS_FILE}" 2>&1 &

new_pid="$!"
echo "${new_pid}" > "${BAKE_PID_FILE}"
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Started bake ${new_pid}: ${reason}" | tee -a "${BAKE_STATUS_FILE}"
