$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
$env:NO_COLOR = "1"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Frontend = Join-Path $PSScriptRoot "frontend"
$Backend = Join-Path $PSScriptRoot "backend"

Push-Location $Frontend
try {
    if (-not (Test-Path "node_modules")) {
        npm.cmd install
    }
    npm.cmd run build
}
finally {
    Pop-Location
}

Push-Location $Root
try {
    python -m pip install -r (Join-Path $Backend "requirements.txt")
    python -m uvicorn control_web.backend.server:app --host 127.0.0.1 --port 8787
}
finally {
    Pop-Location
}
