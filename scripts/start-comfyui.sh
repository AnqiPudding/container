#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
COMFYUI_DIR="${RUNTIME_COMFYUI_DIR:-/data/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"
COMFYUI_REPO_URL="${COMFYUI_REPO_URL:-https://github.com/comfyanonymous/ComfyUI.git}"
COMFYUI_SESSION_PREFIX="${COMFYUI_SESSION_PREFIX:-/tmp/comfyui-manager-session}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

child_pid=""
stop_requested=0

stop_comfyui() {
  stop_requested=1
  if [ -n "${child_pid}" ] && kill -0 "${child_pid}" 2>/dev/null; then
    kill "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
  fi
}

trap 'stop_comfyui; exit 0' INT TERM

mkdir -p "${DATA_DIR}"

initialize_comfyui() {
  if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
    mkdir -p "${COMFYUI_DIR}"
    rsync -a "${IMAGE_COMFYUI_DIR}/" "${COMFYUI_DIR}/"
  fi

  if [ ! -d "${COMFYUI_DIR}/.git" ]; then
    echo "Runtime ComfyUI checkout is missing git metadata; repairing it for ComfyUI-Manager updates."
    tmp_repo="$(mktemp -d)"
    git clone "${COMFYUI_REPO_URL}" "${tmp_repo}"
    rsync -a --delete \
      --exclude "/custom_nodes/" \
      --exclude "/input/" \
      --exclude "/models/" \
      --exclude "/output/" \
      --exclude "/user/" \
      "${tmp_repo}/" "${COMFYUI_DIR}/"
    rm -rf "${tmp_repo}"
  fi

  git config --global --add safe.directory "${COMFYUI_DIR}" || true
  if git -C "${COMFYUI_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "${COMFYUI_DIR}" remote get-url origin >/dev/null 2>&1; then
      git -C "${COMFYUI_DIR}" remote set-url origin "${COMFYUI_REPO_URL}" || true
    else
      git -C "${COMFYUI_DIR}" remote add origin "${COMFYUI_REPO_URL}" || true
    fi

    git -C "${COMFYUI_DIR}" fetch origin --tags --prune || true
    current_branch="$(git -C "${COMFYUI_DIR}" branch --show-current || true)"
    if [ -n "${current_branch}" ] && ! git -C "${COMFYUI_DIR}" rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
      if git -C "${COMFYUI_DIR}" show-ref --verify --quiet "refs/remotes/origin/${current_branch}"; then
        git -C "${COMFYUI_DIR}" branch --set-upstream-to="origin/${current_branch}" "${current_branch}" || true
      fi
    fi
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

  rm -rf "${COMFYUI_DIR}/custom_nodes/.ipynb_checkpoints" "${COMFYUI_DIR}/custom_nodes/custom_nodes"

  for req in "${COMFYUI_DIR}"/custom_nodes/*/requirements.txt; do
    if [ -f "${req}" ]; then
      echo "Installing custom node requirements: ${req}"
      pip install --no-warn-conflicts -r "${req}"
    fi
  done

  repair_manager_reboot_endpoint
  repair_diversityboost_video_hook

  pip install "transformers<5"
  pip install --no-warn-conflicts "decorator>=5.1.0"
}

repair_manager_reboot_endpoint() {
  local manager_server="${COMFYUI_DIR}/custom_nodes/comfyui-manager/glob/manager_server.py"

  if [ ! -f "${manager_server}" ]; then
    return 0
  fi

  python - "${manager_server}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old = '''    try:
        sys.stdout.close_log()
    except Exception:
        pass

    if '__COMFY_CLI_SESSION__' in os.environ:
        with open(os.path.join(os.environ['__COMFY_CLI_SESSION__'] + '.reboot'), 'w'):
            pass

        print("\\nRestarting...\\n\\n")  # This printing should not be logging - that will be ugly
        exit(0)
'''

new = '''    if '__COMFY_CLI_SESSION__' in os.environ:
        with open(os.path.join(os.environ['__COMFY_CLI_SESSION__'] + '.reboot'), 'w'):
            pass

        print("\\nRestarting...\\n\\n")  # This printing should not be logging - that will be ugly
        threading.Timer(0.2, lambda: os._exit(0)).start()
        return web.json_response({"status": "restarting"})

    try:
        sys.stdout.close_log()
    except Exception:
        pass
'''

if old in text:
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"Patched ComfyUI-Manager reboot endpoint for Modal: {path}")
PY
}

repair_diversityboost_video_hook() {
  local core_file="${COMFYUI_DIR}/custom_nodes/comfyui-diversityboost/core.py"

  if [ ! -f "${core_file}" ]; then
    return 0
  fi

  python - "${core_file}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old = "coeffs = torch.randn(B, n_modes, device=device, dtype=torch.float32)"
new = "coeffs = torch.randn(raw_pred.shape[0], n_modes, device=device, dtype=torch.float32)"

if old in text:
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"Patched DiversityBoost video batch handling: {path}")
PY
}

initialize_comfyui

while [ "${stop_requested}" -eq 0 ]; do
  rm -f "${COMFYUI_SESSION_PREFIX}.reboot"
  echo "Starting ComfyUI on port ${COMFYUI_PORT}."
  (
    export __COMFY_CLI_SESSION__="${COMFYUI_SESSION_PREFIX}"
    cd "${COMFYUI_DIR}"
    exec python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}"
  ) &
  child_pid="$!"

  set +e
  wait "${child_pid}"
  exit_code="$?"
  set -e
  child_pid=""

  if [ "${stop_requested}" -ne 0 ]; then
    break
  fi

  if [ -f "${COMFYUI_SESSION_PREFIX}.reboot" ]; then
    echo "ComfyUI-Manager requested a reboot; restarting ComfyUI in this container."
  else
    echo "ComfyUI exited with code ${exit_code}; restarting in this container."
  fi
  sleep 2
done
