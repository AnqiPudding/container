#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/data}"
CUSTOM_NODE_STAGING_DIR="${CUSTOM_NODE_STAGING_DIR:-${DATA_DIR}/custom_nodes_pending}"
RUNTIME_OVERLAY_STAGING_DIR="${RUNTIME_OVERLAY_STAGING_DIR:-${DATA_DIR}/comfyui_overlay_pending}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-AnqiPudding/container}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
BAKE_STATUS_FILE="${BAKE_STATUS_FILE:-${DATA_DIR}/bake-status.log}"
BAKE_COMMIT_PREFIX="${BAKE_COMMIT_PREFIX:-Bake Modal ComfyUI runtime changes}"

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "${token}" ]; then
  echo "GITHUB_TOKEN/GH_TOKEN is not available; skipping GitHub bake push." | tee -a "${BAKE_STATUS_FILE}"
  exit 0
fi

stamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(stamp)] $*" | tee -a "${BAKE_STATUS_FILE}"
}

repo_dir="$(mktemp -d)"
trap 'rm -rf "${repo_dir}"' EXIT

log "Snapshotting ComfyUI runtime before bake."
bash /opt/comfyui-scripts/snapshot-comfyui-state.sh

log "Cloning ${GITHUB_REPOSITORY}@${GITHUB_BRANCH}."
git clone --depth=1 --branch "${GITHUB_BRANCH}" "https://x-access-token:${token}@github.com/${GITHUB_REPOSITORY}.git" "${repo_dir}"

git -C "${repo_dir}" config user.name "${GIT_AUTHOR_NAME:-Modal ComfyUI Bake}"
git -C "${repo_dir}" config user.email "${GIT_AUTHOR_EMAIL:-modal-comfyui-bake@users.noreply.github.com}"

mkdir -p "${repo_dir}/custom_nodes_runtime" "${repo_dir}/comfyui_runtime_overlay"

if [ -d "${CUSTOM_NODE_STAGING_DIR}" ]; then
  log "Syncing custom nodes into GitHub working tree."
  rsync -a --delete \
    --exclude ".git/" \
    --exclude "__pycache__/" \
    --exclude "*.pyc" \
    --exclude ".ipynb_checkpoints/" \
    "${CUSTOM_NODE_STAGING_DIR}/" "${repo_dir}/custom_nodes_runtime/"
fi

if [ -d "${RUNTIME_OVERLAY_STAGING_DIR}" ]; then
  log "Syncing ComfyUI runtime overlay into GitHub working tree."
  rsync -a --delete \
    --exclude ".git/" \
    --exclude "__pycache__/" \
    --exclude "*.pyc" \
    --exclude ".ipynb_checkpoints/" \
    "${RUNTIME_OVERLAY_STAGING_DIR}/" "${repo_dir}/comfyui_runtime_overlay/"
  touch "${repo_dir}/comfyui_runtime_overlay/.gitkeep"
fi

git -C "${repo_dir}" add custom_nodes_runtime comfyui_runtime_overlay

if git -C "${repo_dir}" diff --cached --quiet; then
  log "No bake changes to commit."
  exit 0
fi

message="${BAKE_COMMIT_PREFIX} ($(stamp))"
git -C "${repo_dir}" commit -m "${message}"
log "Pushing bake commit to GitHub. GitHub Actions will build and push Docker Hub image."
git -C "${repo_dir}" push origin "${GITHUB_BRANCH}"
log "Bake commit pushed."
