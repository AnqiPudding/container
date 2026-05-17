# Comfy Deploy Control

Windows desktop control app for the Modal ComfyUI image pipeline.

## What it does

- asks for DockerHub username/token and GitHub repo settings
- configures `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` GitHub Actions secrets
- watches Modal volume custom-node changes
- syncs runtime custom nodes into `custom_nodes_runtime`
- commits and pushes the latest node bundle
- cancels stale GitHub Actions image builds
- starts a fresh Docker image build
- optionally deletes old DockerHub `sha-*` tags
- redeploys Modal with the selected GPU after the image build succeeds
- streams live Modal app logs and ComfyUI stderr logs

## Requirements

- Windows
- .NET 8 Desktop Runtime or SDK
- GitHub CLI (`gh`) authenticated with repo/workflow access
- Modal CLI authenticated to the target workspace

## Build

```powershell
dotnet build .\desktop\ComfyDeployControl\ComfyDeployControl.csproj -c Release
```

## Run

```powershell
.\desktop\ComfyDeployControl\bin\Release\net8.0-windows\ComfyDeployControl.exe
```

The DockerHub token is stored in the current Windows user's app settings file so the app can configure GitHub secrets and prune tags. Use a DockerHub access token with only the permissions this workflow needs.
