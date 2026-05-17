# Comfy Launch Control

Browser control surface for the Modal ComfyUI deployment.

## Local run

```powershell
.\control_web\run_local.ps1
```

Open `http://127.0.0.1:8787`.

The app checks GitHub CLI auth, Modal CLI auth, and Docker Hub GitHub secrets before enabling deployment controls. It does not stream ComfyUI logs into the UI; it only shows control-task progress.

## Bake flow

1. ComfyUI runs from the latest Docker image.
2. Custom-node installs and editable ComfyUI runtime changes stay usable in the live container.
3. On ComfyUI-Manager restart or a manual bake, runtime state is snapshotted to the Modal volume.
4. The web control app syncs pending state into:
   - `custom_nodes_runtime/` for custom nodes.
   - `comfyui_runtime_overlay/` for non-model ComfyUI edits such as YAML/config files.
5. GitHub Actions builds and pushes the next Docker image. The workflow cancels older builds when a newer trigger arrives.
6. Redeploying Modal pulls the newest finished image.

Models, input, output, temp files, notebooks, ComfyUI git metadata, and workflow files under `user/default/workflows` are excluded from the image bake.
