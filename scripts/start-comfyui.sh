#!/usr/bin/env bash
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"

mkdir -p "${DATA_DIR}/models" "${DATA_DIR}/input" "${DATA_DIR}/output" "${DATA_DIR}/user"

rm -rf "${COMFYUI_DIR}/models" "${COMFYUI_DIR}/input" "${COMFYUI_DIR}/output" "${COMFYUI_DIR}/user"
ln -s "${DATA_DIR}/models" "${COMFYUI_DIR}/models"
ln -s "${DATA_DIR}/input" "${COMFYUI_DIR}/input"
ln -s "${DATA_DIR}/output" "${COMFYUI_DIR}/output"
ln -s "${DATA_DIR}/user" "${COMFYUI_DIR}/user"

cd "${COMFYUI_DIR}"
exec python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT:-8188}"
