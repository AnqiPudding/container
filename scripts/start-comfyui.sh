#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
COMFYUI_DIR="${RUNTIME_COMFYUI_DIR:-/tmp/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"
COMFYUI_REPO_URL="${COMFYUI_REPO_URL:-https://github.com/comfyanonymous/ComfyUI.git}"
COMFYUI_SESSION_PREFIX="${COMFYUI_SESSION_PREFIX:-/tmp/comfyui-manager-session}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
INSTALL_CUSTOM_NODE_REQUIREMENTS_ON_BOOT="${INSTALL_CUSTOM_NODE_REQUIREMENTS_ON_BOOT:-0}"
CUSTOM_NODE_STAGING_DIR="${CUSTOM_NODE_STAGING_DIR:-${DATA_DIR}/custom_nodes_pending}"
RUNTIME_REQUIREMENTS_MARKER_DIR="${RUNTIME_REQUIREMENTS_MARKER_DIR:-/tmp/comfyui-custom-node-requirements}"

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

  rsync -a --delete "${IMAGE_COMFYUI_DIR}/custom_nodes/" "${COMFYUI_DIR}/custom_nodes/"
  if [ -d "${CUSTOM_NODE_STAGING_DIR}" ]; then
    echo "Applying pending custom nodes from ${CUSTOM_NODE_STAGING_DIR}."
    rsync -a "${CUSTOM_NODE_STAGING_DIR}/" "${COMFYUI_DIR}/custom_nodes/"
    install_custom_node_requirements "pending custom nodes"
  fi

  for name in models input output user; do
    mkdir -p "${DATA_DIR}/${name}"
    if [ -d "${COMFYUI_DIR}/${name}" ] && [ ! -L "${COMFYUI_DIR}/${name}" ]; then
      rsync -a --ignore-existing "${COMFYUI_DIR}/${name}/" "${DATA_DIR}/${name}/"
      rm -rf "${COMFYUI_DIR:?}/${name}"
    fi
    ln -sfn "${DATA_DIR}/${name}" "${COMFYUI_DIR}/${name}"
  done

  if [ -L "${DATA_DIR}/custom_nodes" ]; then
    rm -f "${DATA_DIR}/custom_nodes"
  fi

  if [ -d "${DATA_DIR}/user/default/workflows" ] && [ ! -L "${DATA_DIR}/user/default/workflows" ]; then
    mkdir -p "${DATA_DIR}/workflows"
    rsync -a "${DATA_DIR}/user/default/workflows/" "${DATA_DIR}/workflows/"
    rm -rf "${DATA_DIR}/user/default/workflows"
  fi

  mkdir -p "${DATA_DIR}/workflows" "${COMFYUI_DIR}/user/default"
  ln -sfn "${DATA_DIR}/workflows" "${DATA_DIR}/user/default/workflows"

  rm -rf "${COMFYUI_DIR}/custom_nodes/.ipynb_checkpoints" "${COMFYUI_DIR}/custom_nodes/custom_nodes"

  if [ "${INSTALL_CUSTOM_NODE_REQUIREMENTS_ON_BOOT}" = "1" ]; then
    for req in "${COMFYUI_DIR}"/custom_nodes/*/requirements.txt; do
      if [ -f "${req}" ]; then
        echo "Installing custom node requirements: ${req}"
        pip install --no-warn-conflicts -r "${req}"
      fi
    done
  fi

  repair_manager_reboot_endpoint
  repair_diversityboost_video_hook

  pip install "transformers<5"
  pip install --no-warn-conflicts "decorator>=5.1.0"
}

stage_runtime_custom_nodes() {
  if [ ! -d "${COMFYUI_DIR}/custom_nodes" ]; then
    return 0
  fi

  echo "Saving current custom nodes to ${CUSTOM_NODE_STAGING_DIR}."
  mkdir -p "${CUSTOM_NODE_STAGING_DIR}"
  rsync -a --delete \
    --exclude "__pycache__/" \
    --exclude "*.pyc" \
    --exclude ".ipynb_checkpoints/" \
    "${COMFYUI_DIR}/custom_nodes/" "${CUSTOM_NODE_STAGING_DIR}/"
}

install_custom_node_requirements() {
  local reason="${1:-custom node changes}"

  if [ ! -d "${COMFYUI_DIR}/custom_nodes" ]; then
    return 0
  fi

  python - "${COMFYUI_DIR}/custom_nodes" "${RUNTIME_REQUIREMENTS_MARKER_DIR}" "${reason}" <<'PY'
from pathlib import Path
import hashlib
import subprocess
import sys

root = Path(sys.argv[1])
marker_dir = Path(sys.argv[2])
reason = sys.argv[3]
marker_dir.mkdir(parents=True, exist_ok=True)

requirements = sorted(root.glob("*/requirements.txt"), key=lambda p: p.as_posix().lower())
if not requirements:
    print(f"No custom node requirements found for {reason}.")
    raise SystemExit(0)

print(f"Checking custom node requirements for {reason}.")
failed = []
for req in requirements:
    digest = hashlib.sha256(req.read_bytes()).hexdigest()
    marker = marker_dir / f"{digest}.ok"
    if marker.exists():
        continue

    print(f"Installing custom node requirements: {req}")
    code = subprocess.call([sys.executable, "-m", "pip", "install", "--no-warn-conflicts", "-r", str(req)])
    if code == 0:
        marker.touch()
    else:
        failed.append(f"{req} (exit {code})")

if failed:
    print("WARNING: Some custom node requirements failed to install:", file=sys.stderr)
    for item in failed:
        print(f"  - {item}", file=sys.stderr)
PY
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
  python - "${COMFYUI_DIR}/custom_nodes" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = next((p for p in root.glob("*/core.py") if "diversityboost" in p.parent.name.lower()), None)
if path is None:
    raise SystemExit(0)

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
    stage_runtime_custom_nodes
    install_custom_node_requirements "ComfyUI-Manager restart"
    echo "ComfyUI-Manager requested a reboot; restarting ComfyUI in this container."
  else
    echo "ComfyUI exited with code ${exit_code}; restarting in this container."
  fi
  sleep 2
done
