FROM python:3.13-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    COMFYUI_DIR=/workspace/ComfyUI \
    DATA_DIR=/data \
    PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu130

WORKDIR /workspace

RUN apt-get update && apt-get install -y --no-install-recommends \
    aria2 \
    build-essential \
    ca-certificates \
    cmake \
    ffmpeg \
    git \
    libgl1 \
    libglib2.0-0 \
    libgomp1 \
    libsm6 \
    libxext6 \
    libxrender1 \
    rsync \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}"

WORKDIR ${COMFYUI_DIR}

RUN python - <<'PY'
import sys

if sys.version_info[:2] != (3, 13):
    raise SystemExit(f"Expected Python 3.13, got {sys.version}")
PY

RUN python -m pip install --upgrade pip setuptools wheel \
    && pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url "${PYTORCH_INDEX_URL}" \
    && python - <<'PY'
import torch

if torch.version.cuda != "13.0":
    raise SystemExit(f"Expected PyTorch CUDA 13.0, got {torch.version.cuda}")
PY

RUN pip install -r requirements.txt \
    && pip install jupyterlab ipywidgets

COPY comfyui-manager/ ${COMFYUI_DIR}/custom_nodes/comfyui-manager/
COPY ComfyUI-Civitai-Downloader/ ${COMFYUI_DIR}/custom_nodes/ComfyUI-Civitai-Downloader/

RUN if [ -f custom_nodes/comfyui-manager/requirements.txt ]; then pip install -r custom_nodes/comfyui-manager/requirements.txt; fi \
    && if [ -f custom_nodes/ComfyUI-Civitai-Downloader/requirements.txt ]; then pip install -r custom_nodes/ComfyUI-Civitai-Downloader/requirements.txt; fi \
    && for file in custom-node-list.json extension-node-map.json model-list.json alter-list.json github-stats.json; do \
        wget -q -O "custom_nodes/comfyui-manager/${file}" "https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main/${file}"; \
    done \
    && find custom_nodes -type d -name "__pycache__" -prune -exec rm -rf {} +

COPY scripts/ /opt/comfyui-scripts/
RUN chmod +x /opt/comfyui-scripts/*.sh

EXPOSE 8188 8888

CMD ["/opt/comfyui-scripts/start-comfyui.sh"]
