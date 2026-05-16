import os
import subprocess

import modal


IMAGE_NAME = os.environ.get("COMFYUI_IMAGE", "anqipudding/modal_comfyui:latest")
GPU_TYPE = os.environ.get("MODAL_GPU", "A10")

app = modal.App("modal-comfyui")
image = (
    modal.Image.from_registry(IMAGE_NAME, force_build=True)
    .add_local_dir("scripts", "/opt/comfyui-scripts", copy=True)
)
data = modal.Volume.from_name("modal-comfyui-data", create_if_missing=True)


@app.function(
    image=image,
    gpu=GPU_TYPE,
    volumes={"/data": data},
    timeout=24 * 60 * 60,
    max_containers=1,
    scaledown_window=2 * 60,
)
@modal.concurrent(max_inputs=100)
@modal.web_server(8188, startup_timeout=900, label="comfyui")
def comfyui():
    subprocess.Popen(["bash", "/opt/comfyui-scripts/start-comfyui.sh"])


@app.function(
    image=image,
    volumes={"/data": data},
    timeout=24 * 60 * 60,
    max_containers=1,
    scaledown_window=2 * 60,
)
@modal.concurrent(max_inputs=100)
@modal.web_server(8888, startup_timeout=180, label="jupyter")
def jupyter():
    subprocess.Popen(["bash", "/opt/comfyui-scripts/start-jupyter.sh"])
