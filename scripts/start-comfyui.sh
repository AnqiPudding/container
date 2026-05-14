#!/usr/bin/env bash
set -euo pipefail

IMAGE_COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
COMFYUI_DIR="${RUNTIME_COMFYUI_DIR:-/data/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"

mkdir -p "${DATA_DIR}"

if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
  mkdir -p "${COMFYUI_DIR}"
  rsync -a "${IMAGE_COMFYUI_DIR}/" "${COMFYUI_DIR}/"
fi

rsync -a --ignore-existing "${IMAGE_COMFYUI_DIR}/custom_nodes/" "${COMFYUI_DIR}/custom_nodes/"

for name in models input output user custom_nodes; do
  if [ -d "${DATA_DIR}/${name}" ] && [ ! -L "${DATA_DIR}/${name}" ]; then
    mkdir -p "${COMFYUI_DIR}/${name}"
    rsync -a --ignore-existing "${DATA_DIR}/${name}/" "${COMFYUI_DIR}/${name}/"
  fi
done

ln -sfn "${COMFYUI_DIR}/models" "${DATA_DIR}/models"
ln -sfn "${COMFYUI_DIR}/input" "${DATA_DIR}/input"
ln -sfn "${COMFYUI_DIR}/output" "${DATA_DIR}/output"
ln -sfn "${COMFYUI_DIR}/user" "${DATA_DIR}/user"
ln -sfn "${COMFYUI_DIR}/custom_nodes" "${DATA_DIR}/custom_nodes"

if [ -d "${DATA_DIR}/user/default/workflows" ] && [ ! -L "${DATA_DIR}/user/default/workflows" ]; then
  mkdir -p "${DATA_DIR}/workflows"
  rsync -a "${DATA_DIR}/user/default/workflows/" "${DATA_DIR}/workflows/"
  rm -rf "${DATA_DIR}/user/default/workflows"
fi

mkdir -p "${DATA_DIR}/workflows" "${COMFYUI_DIR}/user/default"
ln -sfn "${DATA_DIR}/workflows" "${DATA_DIR}/user/default/workflows"

cd "${COMFYUI_DIR}"
exec python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT:-8188}"
