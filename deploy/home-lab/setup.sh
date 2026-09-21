#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env, set the secrets and Wazuh values, then run this script again." >&2
  exit 1
fi

compose=(docker compose -f docker-compose.yml -f deploy/home-lab/docker-compose.override.yml)

# Grafana (UID 472) and InfluxDB (UID 1000) drop root inside their containers
# and need to own their data dirs before first start. Without this, Docker
# auto-creates these as root-owned on first `up -d` and both containers
# crash-loop on a permission error. Safe to rerun.
mkdir -p data/grafana-data data/influxdb-data data/influxdb-config
if command -v sudo >/dev/null 2>&1; then
  sudo chown -R 472:472 data/grafana-data
  sudo chown -R 1000:1000 data/influxdb-data data/influxdb-config
else
  chown -R 472:472 data/grafana-data
  chown -R 1000:1000 data/influxdb-data data/influxdb-config
fi

if [[ "${1:-}" == "--pull" ]]; then
  "${compose[@]}" pull
fi

"${compose[@]}" config --quiet
"${compose[@]}" up -d

if [[ "${1:-}" == "--capture-admin-password" || "${2:-}" == "--capture-admin-password" ]]; then
  password_file="data/copilot-admin-password.txt"
  if [[ -f "$password_file" ]]; then
    echo "Saved admin password already exists at $password_file. It was not overwritten."
  else
    echo "Waiting for the first-run admin password in backend logs..."
    deadline=$((SECONDS + 120))
    password=""
    while (( SECONDS < deadline )) && [[ -z "$password" ]]; do
      password=$("${compose[@]}" logs --no-color --since 10m copilot-backend 2>&1 |
        sed -nE "s/.*plain='([^']+)'.*/\1/p" | tail -n 1)
      [[ -n "$password" ]] || sleep 3
    done
    if [[ -n "$password" ]]; then
      umask 077
      printf '%s' "$password" > "$password_file"
      echo "Saved the first-run CoPilot admin password to $password_file"
      echo "Protect this file and change the password after first login."
    else
      echo "No first-run password was emitted. The CoPilot database may already be initialized."
      echo "Open https://localhost and use the existing administrator account."
    fi
  fi
fi

"${compose[@]}" ps