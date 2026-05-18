#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "${DATA_DIR:-/data}/notebooks"
cd "${DATA_DIR:-/data}"

comfyui_pid=""

stop_workspace() {
  if [ -n "${comfyui_pid}" ] && kill -0 "${comfyui_pid}" 2>/dev/null; then
    kill "${comfyui_pid}" 2>/dev/null || true
    wait "${comfyui_pid}" 2>/dev/null || true
  fi
}

trap 'stop_workspace; exit 0' INT TERM

echo "Starting ComfyUI inside the Jupyter GPU workspace."
/opt/comfyui-scripts/start-comfyui.sh &
comfyui_pid="$!"

exec jupyter lab \
  --ip=0.0.0.0 \
  --port="${JUPYTER_PORT:-8888}" \
  --no-browser \
  --allow-root \
  --ServerApp.root_dir="${DATA_DIR:-/data}" \
  --ServerApp.token="${JUPYTER_TOKEN:-modal-comfyui}" \
  --ServerApp.allow_origin="*" \
  --ServerProxy.servers='{"comfyui":{"command":["bash","-lc","true"],"port":8188,"absolute_url":false,"timeout":900,"launcher_entry":{"enabled":true,"title":"ComfyUI"}}}'
