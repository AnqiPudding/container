# Modal ComfyUI Container

ComfyUI Docker image for Modal with these local custom nodes included:

- `comfyui-manager`
- `ComfyUI-Civitai-Downloader`

The GitHub Actions workflow builds and pushes this image to:

```text
anqipudding/modal_comfyui:latest
```

## GitHub setup

Add these repository secrets before the first Actions run:

- `DOCKERHUB_USERNAME`: Docker Hub username, usually `anqipudding`
- `DOCKERHUB_TOKEN`: Docker Hub access token with write permission for `anqipudding/modal_comfyui`

The workflow runs on pushes to `main` and can also be started manually from the Actions tab.

## Local Docker test

```bash
docker build -t anqipudding/modal_comfyui:local .
docker run --gpus all --rm -it \
  -p 8188:8188 \
  -p 8888:8888 \
  -v comfyui-data:/data \
  anqipudding/modal_comfyui:local
```

ComfyUI will be available at `http://localhost:8188`.

To run JupyterLab locally instead:

```bash
docker run --gpus all --rm -it \
  -p 8888:8888 \
  -v comfyui-data:/data \
  --entrypoint /opt/comfyui-scripts/start-jupyter.sh \
  anqipudding/modal_comfyui:local
```

The default Jupyter token is `modal-comfyui`. Override it with `-e JUPYTER_TOKEN=...`.

## Modal deployment

Install and authenticate Modal locally:

```bash
python -m pip install -r requirements.txt
modal setup
```

After GitHub Actions has pushed `anqipudding/modal_comfyui:latest`, deploy:

```bash
modal deploy modal_app.py
```

This creates two Modal web endpoints:

- `comfyui`: ComfyUI on port `8188`
- `jupyter`: JupyterLab on port `8888`; open `/lab?token=modal-comfyui`

Both endpoints use the same persistent Modal Volume named `modal-comfyui-data`, mounted at `/data`. The runtime ComfyUI checkout lives at `/data/ComfyUI`, so ComfyUI-Manager updates, custom nodes, models, inputs, outputs, user settings, and workflows survive container restarts.

You can change the Modal GPU without editing code:

```bash
MODAL_GPU=L40S modal deploy modal_app.py
```

The default GPU is `A10`.

## Windows control app

This repo includes a Windows desktop control app at `desktop/ComfyDeployControl`.

It can:

- watch the Modal `custom_nodes` volume for installed/uninstalled nodes
- sync detected nodes into `custom_nodes_runtime`
- cancel older Docker image builds before starting the newest one
- configure DockerHub secrets in GitHub Actions
- deploy/stop the Modal app with a selected GPU
- stream Modal app logs and ComfyUI stderr logs
- optionally prune old DockerHub `sha-*` image tags

Build it locally:

```powershell
dotnet build desktop\ComfyDeployControl\ComfyDeployControl.csproj -c Release
```

Run:

```powershell
desktop\ComfyDeployControl\bin\Release\net8.0-windows\ComfyDeployControl.exe
```

The app expects `gh` and `modal` to be installed and authenticated on Windows.
