# Comfy Launch Control

Browser control surface for the Modal ComfyUI deployment.

## Local run

```powershell
.\control_web\run_local.ps1
```

Open `http://127.0.0.1:8787`.

The app checks GitHub CLI auth, Modal CLI auth, and Docker Hub GitHub secrets before enabling deployment controls. It does not stream ComfyUI logs into the UI; it only shows control-task progress.

## Bake flow

1. Modal deploys one warm GPU workspace container for Jupyter.
2. ComfyUI starts inside that Jupyter GPU workspace and is served at the workspace root. JupyterLab stays available at `/jupyter/`.
3. Custom-node installs and editable ComfyUI runtime changes stay usable in the live workspace container.
4. On ComfyUI-Manager restart, manual bake, or detected runtime change, the Modal container snapshots runtime state.
5. The Modal container pushes the pending state to GitHub:
   - `custom_nodes_runtime/` for custom nodes.
   - `comfyui_runtime_overlay/` for non-model ComfyUI edits such as YAML/config files.
6. Python packages installed at runtime, such as SageAttention, are written to `.modal-runtime-requirements.txt` and installed during the next Docker image build.
7. GitHub Actions builds and pushes the next Docker image. The workflow cancels older builds when a newer trigger arrives.
8. Redeploying Modal pulls the newest finished image; restarting ComfyUI inside the workspace does not pull a new image.

Models, input, output, temp files, notebooks, ComfyUI git metadata, and workflow files under `user/default/workflows` are excluded from the image bake.
