from __future__ import annotations

import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

import requests
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel


ROOT = Path(os.environ.get("COMFY_CONTROL_REPO", Path(__file__).resolve().parents[2])).resolve()
FRONTEND_DIST = ROOT / "control_web" / "frontend" / "dist"
RUNTIME_DIR = ROOT / "custom_nodes_runtime"
OVERLAY_DIR = ROOT / "comfyui_runtime_overlay"
MODAL_APP = os.environ.get("COMFY_CONTROL_MODAL_APP", "modal-comfyui")
MODAL_VOLUME = os.environ.get("COMFY_CONTROL_MODAL_VOLUME", "modal-comfyui-data")
IMAGE_NAME = os.environ.get("COMFY_CONTROL_IMAGE", "anqipudding/modal_comfyui:latest")
WD14_REPO = "https://github.com/pythongosssss/ComfyUI-WD14-Tagger.git"
MODAL_GITHUB_SECRET = "comfyui-github"

app = FastAPI(title="Comfy Launch Control")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

events: list[str] = []
task_lock = threading.Lock()
active_bake: threading.Thread | None = None
bake_generation = 0
build_state: dict[str, Any] = {
    "id": None,
    "status": "idle",
    "conclusion": "",
    "url": "",
    "progress": 0,
}
control_state: dict[str, Any] = {"status": "idle", "message": "Ready"}


class BakeRequest(BaseModel):
    deploy: bool = False


def event(message: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    line = f"[{stamp}] {message}"
    events.append(line)
    del events[:-80]
    print(line, flush=True)


def run(args: list[str], *, check: bool = True, timeout: int | None = None, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        cwd=ROOT,
        input=input_text,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=timeout,
        env={**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1", "NO_COLOR": "1"},
    )
    if check and proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or f"{args[0]} exited with {proc.returncode}").strip())
    return proc


def capture(args: list[str], *, timeout: int | None = None) -> tuple[int, str]:
    proc = run(args, check=False, timeout=timeout)
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def github_ok() -> bool:
    return capture(["gh", "auth", "status"], timeout=20)[0] == 0


def modal_ok() -> bool:
    return capture(["modal", "profile", "current"], timeout=20)[0] == 0


def docker_secrets_ok() -> bool:
    code, out = capture(["gh", "secret", "list", "--repo", "AnqiPudding/container", "--json", "name"], timeout=30)
    if code != 0:
        return False
    try:
        names = {item["name"] for item in json.loads(out)}
    except Exception:
        return False
    return {"DOCKERHUB_USERNAME", "DOCKERHUB_TOKEN"}.issubset(names)


def repo_info() -> tuple[str, str]:
    code, out = capture(["gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef"], timeout=30)
    if code == 0:
        try:
            data = json.loads(out)
            repo = str(data.get("nameWithOwner") or "").strip()
            default_branch = (data.get("defaultBranchRef") or {}).get("name") or "main"
            if repo:
                branch = capture(["git", "branch", "--show-current"], timeout=15)[1].strip() or default_branch
                return repo, branch
        except Exception:
            pass
    return "AnqiPudding/container", "main"


def modal_secret_names() -> set[str]:
    code, out = capture(["modal", "secret", "list", "--json"], timeout=30)
    if code != 0:
        return set()
    try:
        rows = json.loads(out)
    except Exception:
        return set()
    return {str(item.get("name") or item.get("Name") or "") for item in rows}


def modal_github_secret_ok() -> bool:
    return MODAL_GITHUB_SECRET in modal_secret_names()


def ensure_modal_github_secret() -> None:
    if modal_github_secret_ok():
        return

    event(f"Creating Modal secret {MODAL_GITHUB_SECRET} in the active Modal workspace.")
    token_code, token = capture(["gh", "auth", "token"], timeout=30)
    if token_code != 0 or not token.strip():
        raise RuntimeError("GitHub CLI is not authenticated. Run `gh auth login`, then try again.")

    repo, branch = repo_info()
    payload = {
        "GITHUB_TOKEN": token.strip(),
        "GITHUB_REPOSITORY": repo,
        "GITHUB_BRANCH": branch,
    }
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".json", delete=False) as handle:
        json.dump(payload, handle)
        secret_file = handle.name

    try:
        run(
            ["modal", "secret", "create", MODAL_GITHUB_SECRET, "--from-json", secret_file, "--force"],
            timeout=60,
        )
    finally:
        Path(secret_file).unlink(missing_ok=True)

    event(f"Modal secret {MODAL_GITHUB_SECRET} is ready for {repo}@{branch}.")


def workspace_name() -> str:
    script = (
        "$profiles = modal profile list --json | ConvertFrom-Json; "
        "$active = $profiles | Where-Object { $_.active } | Select-Object -First 1; "
        "if ($active) { $active.workspace }"
    )
    code, out = capture(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], timeout=30)
    return out.splitlines()[-1].strip() if code == 0 and out.strip() else ""


def endpoints() -> dict[str, str]:
    ws = workspace_name()
    if not ws:
        return {"comfyui": "", "jupyter": "", "control": ""}
    jupyter = f"https://{ws}--jupyter.modal.run"
    return {
        "comfyui": f"{jupyter}/",
        "jupyter": f"{jupyter}/jupyter/lab?token=modal-comfyui",
        "control": f"https://{ws}--control.modal.run",
    }


def app_deployed() -> bool:
    code, out = capture(["modal", "app", "list"], timeout=30)
    return code == 0 and MODAL_APP in out and "deployed" in out


def running_containers() -> list[str]:
    code, out = capture(["modal", "container", "list"], timeout=30)
    if code != 0:
        return []
    return sorted(set(re.findall(r"\b(?:ta|tc)-[A-Za-z0-9_-]+\b", out)))


def list_volume_nodes(path: str) -> list[str]:
    code, out = capture(["modal", "volume", "ls", MODAL_VOLUME, path], timeout=60)
    if code != 0:
        return []
    skip = {
        ".gitkeep",
        "README.md",
        "manifest.json",
        "example_node.py.example",
        "comfyui-manager",
        "ComfyUI-Civitai-Downloader",
    }
    nodes = set()
    for line in out.splitlines():
        line = line.strip().replace("\\", "/")
        prefix = path.strip("/") + "/"
        if not line.startswith(prefix):
            continue
        name = line[len(prefix) :].split("/")[0]
        if name and name not in skip:
            nodes.add(name)
    return sorted(nodes, key=str.lower)


def list_baked_nodes() -> list[str]:
    if not RUNTIME_DIR.exists():
        return []
    skip = {".git", "__pycache__", ".gitkeep", "README.md", "manifest.json", "example_node.py.example"}
    return sorted(
        [p.name for p in RUNTIME_DIR.iterdir() if p.name not in skip],
        key=str.lower,
    )


def latest_build() -> dict[str, Any]:
    code, out = capture(
        [
            "gh",
            "run",
            "list",
            "--repo",
            "AnqiPudding/container",
            "--workflow",
            "Build Docker image",
            "--limit",
            "1",
            "--json",
            "databaseId,status,conclusion,url",
        ],
        timeout=30,
    )
    if code != 0:
        return build_state
    try:
        rows = json.loads(out)
    except Exception:
        return build_state
    if not rows:
        return build_state
    row = rows[0]
    status = row.get("status") or "unknown"
    conclusion = row.get("conclusion") or ""
    progress = 100 if status == "completed" and conclusion == "success" else 70 if status == "in_progress" else 20 if status == "queued" else 0
    build_state.update(
        {
            "id": row.get("databaseId"),
            "status": status,
            "conclusion": conclusion,
            "url": row.get("url") or "",
            "progress": progress,
        }
    )
    return build_state


@app.get("/api/status")
def status() -> dict[str, Any]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
        futures = {
            "build": pool.submit(latest_build),
            "endpoints": pool.submit(endpoints),
            "pending": pool.submit(list_volume_nodes, "/custom_nodes_pending"),
            "baked": pool.submit(list_baked_nodes),
            "github": pool.submit(github_ok),
            "modal": pool.submit(modal_ok),
            "docker": pool.submit(docker_secrets_ok),
            "modalSecret": pool.submit(modal_github_secret_ok),
            "deployed": pool.submit(app_deployed),
            "containers": pool.submit(running_containers),
        }

        def value(name: str, fallback: Any) -> Any:
            try:
                return futures[name].result()
            except Exception:
                return fallback

        pending = value("pending", [])
        baked = value("baked", [])
        containers = value("containers", [])

    return {
        "modalApp": MODAL_APP,
        "image": IMAGE_NAME,
        "gpu": os.environ.get("MODAL_GPU", "A10"),
        "build": value("build", build_state),
        "endpoints": value("endpoints", {"comfyui": "", "jupyter": "", "control": ""}),
        "nodes": {
            "baked": baked,
            "pending": pending,
            "runtime": pending,
        },
        "auth": {
            "github": value("github", False),
            "modal": value("modal", False),
            "dockerSecrets": value("docker", False),
            "modalGithubSecret": value("modalSecret", False),
        },
        "app": {
            "deployed": value("deployed", False),
            "live": bool(containers),
            "task": control_state,
        },
        "events": events,
    }


@app.post("/api/refresh")
def refresh() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/comfy/start")
def start_comfy() -> dict[str, str]:
    start_control_job("start", start_comfy_worker)
    return {"status": "started"}


@app.post("/api/comfy/scale-down")
def scale_down() -> dict[str, Any]:
    ids = running_containers()
    for container_id in ids:
        event(f"Stopping container {container_id}.")
        run(["modal", "container", "stop", container_id, "--yes"], check=False, timeout=60)
    return {"stopped": ids}


@app.post("/api/nodes/install-wd14")
def install_wd14() -> dict[str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        clone_dir = Path(tmp) / "ComfyUI-WD14-Tagger"
        event("Cloning ComfyUI-WD14-Tagger from pythongosssss.")
        run(["git", "clone", "--depth=1", WD14_REPO, str(clone_dir)], timeout=120)
        shutil.rmtree(clone_dir / ".git", ignore_errors=True)
        target = RUNTIME_DIR / "ComfyUI-WD14-Tagger"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(clone_dir, target)
        shutil.rmtree(target / ".git", ignore_errors=True)
        event("Uploading WD14 Tagger to Modal pending custom nodes.")
        run(["modal", "volume", "rm", MODAL_VOLUME, "/custom_nodes_pending/comfyui-wd14-tagger", "--recursive"], check=False, timeout=60)
        run(["modal", "volume", "put", MODAL_VOLUME, str(target), "/custom_nodes_pending/", "--force"], timeout=180)
        run(["modal", "volume", "rm", MODAL_VOLUME, "/custom_nodes_pending/ComfyUI-WD14-Tagger/.git", "--recursive"], check=False, timeout=60)
    return {"status": "ok"}


@app.post("/api/image/bake")
def bake(req: BakeRequest) -> dict[str, str]:
    start_background_bake(req.deploy)
    return {"status": "started"}


@app.post("/api/image/deploy")
def deploy_latest() -> dict[str, str]:
    start_control_job("deploy", deploy_worker)
    return {"status": "started"}


def start_control_job(name: str, target: Any) -> None:
    control_state.update({"status": name, "message": "Working"})
    threading.Thread(target=control_worker, args=(name, target), daemon=True).start()


def control_worker(name: str, target: Any) -> None:
    try:
        target()
        control_state.update({"status": "idle", "message": "Ready"})
    except Exception as exc:
        control_state.update({"status": "failed", "message": str(exc)})
        event(f"ERROR: {exc}")


def start_comfy_worker() -> None:
    if not app_deployed():
        event("Deploying Modal GPU workspace before opening ComfyUI.")
        ensure_modal_github_secret()
        run(["modal", "deploy", "modal_app.py"], timeout=300)
    event("ComfyUI is served from the warm Jupyter GPU workspace.")


def deploy_worker() -> None:
    event("Deploying latest Docker image to Modal.")
    ensure_modal_github_secret()
    run(["modal", "deploy", "modal_app.py"], timeout=420)
    event("Modal app deployed with latest image.")


def start_background_bake(deploy_after: bool) -> None:
    global active_bake, bake_generation
    with task_lock:
        bake_generation += 1
        generation = bake_generation
        cancel_active_github_build()
        active_bake = threading.Thread(target=bake_worker, args=(deploy_after, generation), daemon=True)
        active_bake.start()


class CancelledBake(RuntimeError):
    pass


def ensure_latest(generation: int) -> None:
    if generation != bake_generation:
        raise CancelledBake()


def cancel_active_github_build() -> None:
    row = latest_build()
    if row.get("id") and row.get("status") in {"queued", "in_progress", "waiting"}:
        event(f"Cancelling superseded build {row['id']}.")
        run(["gh", "run", "cancel", str(row["id"]), "--repo", "AnqiPudding/container"], check=False, timeout=60)


def bake_worker(deploy_after: bool, generation: int) -> None:
    try:
        build_state.update({"status": "triggering", "conclusion": "", "progress": 8})
        ensure_latest(generation)
        trigger_container_bake()
        event("Container bake trigger sent. GitHub Actions will start after the container pushes its bake commit.")
        build_state.update({"status": "triggered", "conclusion": "", "progress": 20})
        if deploy_after:
            event("Deploy-after-build is now handled manually after the GitHub build reports success.")
    except CancelledBake:
        event("Older bake trigger was replaced by a newer one.")
    except Exception as exc:
        build_state.update({"status": "failed", "conclusion": "failure", "progress": 100})
        event(f"ERROR: {exc}")


def snapshot_running_container() -> None:
    ids = running_containers()
    if not ids:
        event("No running container found; using existing pending/custom node volume snapshot.")
        return
    event(f"Snapshotting runtime custom nodes from {ids[0]}.")
    run(["modal", "container", "exec", ids[0], "--", "bash", "/opt/comfyui-scripts/snapshot-comfyui-state.sh"], timeout=180)


def trigger_container_bake() -> None:
    ids = running_containers()
    if not ids:
        raise RuntimeError("No running Modal container found. Open/start ComfyUI first, then bake the live runtime.")
    event(f"Triggering GitHub bake from Modal container {ids[0]}.")
    run(["modal", "container", "exec", ids[0], "--", "bash", "/opt/comfyui-scripts/trigger-bake-to-github.sh", "manual web bake"], timeout=120)


def sync_pending_nodes_to_repo() -> None:
    pending = list_volume_nodes("/custom_nodes_pending")
    if not pending:
        event("No pending custom node changes found.")
        return
    RUNTIME_DIR.mkdir(exist_ok=True)
    event(f"Syncing {len(pending)} pending custom node entries into the repo.")
    for node in pending:
        run(["modal", "volume", "get", MODAL_VOLUME, f"/custom_nodes_pending/{node}", str(RUNTIME_DIR), "--force"], timeout=180)


def sync_pending_overlay_to_repo() -> None:
    code, out = capture(["modal", "volume", "ls", MODAL_VOLUME, "/comfyui_overlay_pending"], timeout=60)
    if code != 0 or not out.strip():
        event("No pending ComfyUI overlay changes found.")
        return

    event("Syncing pending ComfyUI overlay into the repo.")
    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        run(["modal", "volume", "get", MODAL_VOLUME, "/comfyui_overlay_pending", str(tmp_dir), "--force"], timeout=240)
        candidates = [tmp_dir / "comfyui_overlay_pending", tmp_dir]
        source = next((path for path in candidates if path.exists() and any(path.iterdir())), tmp_dir)
        if OVERLAY_DIR.exists():
            shutil.rmtree(OVERLAY_DIR)
        shutil.copytree(source, OVERLAY_DIR, ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc", ".ipynb_checkpoints"))
        (OVERLAY_DIR / ".gitkeep").touch()


def commit_and_push_runtime() -> None:
    run(["git", "add", "custom_nodes_runtime", "comfyui_runtime_overlay", "scripts"], timeout=60)
    diff = run(["git", "diff", "--cached", "--quiet"], check=False, timeout=60)
    if diff.returncode == 0:
        event("No repo changes to commit before build.")
        return
    run(["git", "commit", "-m", "Bake ComfyUI runtime changes"], timeout=120)
    run(["git", "push", "origin", "main"], timeout=180)
    event("Pushed runtime changes to GitHub.")


def trigger_or_find_build() -> int:
    event("Starting GitHub image build.")
    run(["gh", "workflow", "run", "Build Docker image", "--repo", "AnqiPudding/container", "--ref", "main"], timeout=60)
    time.sleep(6)
    row = latest_build()
    run_id = row.get("id")
    if not run_id:
        raise RuntimeError("Could not find the GitHub Actions build run.")
    return int(run_id)


def wait_for_build(run_id: int, generation: int) -> None:
    while True:
        ensure_latest(generation)
        code, out = capture(["gh", "run", "view", str(run_id), "--repo", "AnqiPudding/container", "--json", "status,conclusion,url"], timeout=60)
        if code != 0:
            raise RuntimeError(out)
        row = json.loads(out)
        status = row.get("status") or "unknown"
        conclusion = row.get("conclusion") or ""
        progress = 100 if status == "completed" else 72 if status == "in_progress" else 28
        build_state.update({"id": run_id, "status": status, "conclusion": conclusion, "url": row.get("url") or "", "progress": progress})
        event(f"Build {run_id}: {status} {conclusion}".strip())
        if status == "completed":
            if conclusion != "success":
                raise RuntimeError(f"Build {run_id} finished with {conclusion}.")
            return
        time.sleep(15)


if FRONTEND_DIST.exists():
    app.mount("/", StaticFiles(directory=FRONTEND_DIST, html=True), name="frontend")
