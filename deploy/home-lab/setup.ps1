param(
    [switch]$Pull,
    [switch]$CaptureAdminPassword
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\.." )).Path
Set-Location $RepoRoot

$ComposeArgs = @(
    "compose",
    "-f", "docker-compose.yml",
    "-f", "deploy/home-lab/docker-compose.override.yml"
)

if (-not (Test-Path ".env")) {
    throw "Missing .env. Copy .env.example to .env, set the secrets and Wazuh values, then run this script again."
}

# Grafana/InfluxDB need their data dirs to exist before first start. Docker
# Desktop's bind-mount layer does its own UID translation, so no chown
# equivalent is needed here the way setup.sh needs one on Linux.
foreach ($dir in @("data\grafana-data", "data\influxdb-data", "data\influxdb-config")) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

if ($Pull) {
    & docker @ComposeArgs pull
    if ($LASTEXITCODE -ne 0) { throw "Docker image pull failed." }
}

& docker @ComposeArgs config --quiet
if ($LASTEXITCODE -ne 0) { throw "Compose validation failed." }

& docker @ComposeArgs up -d
if ($LASTEXITCODE -ne 0) { throw "CoPilot startup failed." }

$PasswordFile = Join-Path $RepoRoot "data\copilot-admin-password.txt"
if ($CaptureAdminPassword) {
    if (Test-Path $PasswordFile) {
        Write-Host "Saved admin password already exists at $PasswordFile. It was not overwritten."
    } else {
        Write-Host "Waiting for the first-run admin password in backend logs..."
        $deadline = (Get-Date).AddMinutes(2)
        $password = $null
        while ((Get-Date) -lt $deadline -and -not $password) {
            $logs = & docker @ComposeArgs logs --no-color --since 10m copilot-backend 2>&1
            $match = $logs | Select-String -Pattern "plain='([^']+)'" | Select-Object -Last 1
            if ($match) { $password = $match.Matches[0].Groups[1].Value.Trim() }
            if (-not $password) { Start-Sleep -Seconds 3 }
        }
        if ($password) {
            Set-Content -Path $PasswordFile -Value $password -NoNewline
            & icacls $PasswordFile /inheritance:r /grant:r "$env:USERNAME:(R,W)" | Out-Null
            Write-Host "Saved the first-run CoPilot admin password to $PasswordFile"
            Write-Host "Protect this file and change the password after first login."
        } else {
            Write-Host "No first-run password was emitted. The CoPilot database may already be initialized."
            Write-Host "Open https://localhost and use the existing administrator account."
        }
    }
}

& docker @ComposeArgs ps