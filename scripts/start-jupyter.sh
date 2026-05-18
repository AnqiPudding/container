#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "${DATA_DIR:-/data}/notebooks"
cd "${DATA_DIR:-/data}"

comfyui_pid=""
jupyter_pid=""

stop_workspace() {
  if [ -n "${comfyui_pid}" ] && kill -0 "${comfyui_pid}" 2>/dev/null; then
    kill "${comfyui_pid}" 2>/dev/null || true
    wait "${comfyui_pid}" 2>/dev/null || true
  fi
  if [ -n "${jupyter_pid}" ] && kill -0 "${jupyter_pid}" 2>/dev/null; then
    kill "${jupyter_pid}" 2>/dev/null || true
    wait "${jupyter_pid}" 2>/dev/null || true
  fi
}

trap 'stop_workspace; exit 0' INT TERM

echo "Starting ComfyUI inside the Jupyter GPU workspace."
bash /opt/comfyui-scripts/start-comfyui.sh &
comfyui_pid="$!"

echo "Starting JupyterLab inside the same GPU workspace."
jupyter lab \
  --ip=0.0.0.0 \
  --port="${JUPYTER_PORT:-8889}" \
  --no-browser \
  --allow-root \
  --ServerApp.root_dir="${DATA_DIR:-/data}" \
  --ServerApp.base_url="/jupyter/" \
  --ServerApp.token="${JUPYTER_TOKEN:-modal-comfyui}" \
  --ServerApp.allow_origin="*" &
jupyter_pid="$!"

echo "Serving ComfyUI and JupyterLab through the Modal workspace proxy."
python /opt/comfyui-scripts/workspace-proxy.py --port "${WORKSPACE_PROXY_PORT:-8888}"
