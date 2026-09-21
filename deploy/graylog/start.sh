#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root/deploy/graylog"

force_trust=false
pull=false
for arg in "$@"; do
  case "$arg" in
    --force-trust) force_trust=true ;;
    --pull) pull=true ;;
    *) echo "Usage: $0 [--force-trust] [--pull]" >&2; exit 2 ;;
  esac
done

command -v openssl >/dev/null || { echo "openssl is required." >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

[[ -f .env ]] || { echo "Missing deploy/graylog/.env. Run deploy/home-lab/setup-env.sh first." >&2; exit 1; }

# Plain string replacement via Python, not sed -- values here can contain
# arbitrary passwords, and sed's replacement text treats characters like &
# specially, which would silently corrupt .env for some generated secrets.
set_env() {
  local key="$1" value="$2"
  KEY="$key" VALUE="$value" python3 - <<'PY'
from pathlib import Path
import os

path = Path(".env")
key = os.environ["KEY"]
value = os.environ["VALUE"]
lines = path.read_text().splitlines()
replacement = f"{key}={value}"
found = False
for index, line in enumerate(lines):
    if line.startswith(f"{key}="):
        lines[index] = replacement
        found = True
        break
if not found:
    lines.append(replacement)
path.write_text("\n".join(lines) + "\n")
PY
}

hosts_line="$(sed -nE 's/^GRAYLOG_ELASTICSEARCH_HOSTS=(.*)$/\1/p' .env)"
if [[ -z "$hosts_line" ]]; then
  echo "GRAYLOG_ELASTICSEARCH_HOSTS is not set in deploy/graylog/.env." >&2
  exit 1
fi

scheme="${hosts_line%%://*}"
rest="${hosts_line#*://}"
if [[ "$rest" == *@* ]]; then
  userinfo="${rest%%@*}"
  hostport="${rest#*@}"
else
  userinfo=""
  hostport="$rest"
fi
# Only the first host is used if a comma-separated list was configured.
hostport="$(printf '%s' "$hostport" | cut -d, -f1)"
host="${hostport%%:*}"
port="${hostport#*:}"

# Graylog's self-managed OpenSearch mode has no "skip TLS verification"
# option (unlike CoPilot's OPENSEARCH_SSL_VERIFY=false). The official image's
# own entrypoint (docker-entrypoint.sh, setupCertificates()) handles trust:
# it imports every *.crt file under a mounted /certificates directory into a
# fresh copy of the container's own JVM truststore on every start, no
# GRAYLOG_SERVER_JAVA_OPTS wrangling required -- that env var has a history
# of being unreliable in this image and is NOT used here.
mkdir -p certificates
if [[ ! -f certificates/wazuh-indexer.crt || "$force_trust" == true ]]; then
  echo "Fetching TLS certificate presented by $hostport ..."
  openssl s_client -connect "$hostport" -servername "$host" -showcerts </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > certificates/wazuh-indexer.crt

  if [[ ! -s certificates/wazuh-indexer.crt ]]; then
    echo "Failed to fetch a certificate from $hostport. Is the Wazuh Indexer reachable and listening there?" >&2
    exit 1
  fi
  echo "Wrote deploy/graylog/certificates/wazuh-indexer.crt"
else
  echo "Reusing existing deploy/graylog/certificates/wazuh-indexer.crt (rerun with --force-trust to refetch, e.g. after the Wazuh Indexer's certificate rotates)."
fi

# Trust is only half of TLS validation -- Java also checks that the host you
# connected to matches the certificate's SAN/CN, even for a certificate it
# already trusts. Wazuh's certs are issued to a role name (e.g.
# "wazuh.indexer"), not an IP, so connecting via IP fails with "Hostname ...
# not verified" even though the cert itself is fine. Read the name the
# certificate actually claims, switch GRAYLOG_ELASTICSEARCH_HOSTS to use it,
# and map it to the real IP via Docker's extra_hosts so it still resolves.
# This runs every time, not just when a certificate was just fetched --
# certificates/ is a bind mount, so it survives `docker compose down -v`,
# and skipping this check whenever the file already existed left .env
# permanently unfixed on a rerun.
cert_hostname="$(openssl x509 -in certificates/wazuh-indexer.crt -noout -ext subjectAltName 2>/dev/null \
  | grep -oE 'DNS:[^, ]+' | head -1 | cut -d: -f2)"
if [[ -z "$cert_hostname" ]]; then
  cert_hostname="$(openssl x509 -in certificates/wazuh-indexer.crt -noout -subject -nameopt multiline 2>/dev/null \
    | sed -n 's/^ *commonName *= *//p')"
fi

if [[ -n "$cert_hostname" && "$cert_hostname" != "$host" ]]; then
  new_hostport="${cert_hostname}:${port}"
  if [[ -n "$userinfo" ]]; then
    new_hosts_line="${scheme}://${userinfo}@${new_hostport}"
  else
    new_hosts_line="${scheme}://${new_hostport}"
  fi
  set_env GRAYLOG_ELASTICSEARCH_HOSTS "$new_hosts_line"
  set_env GRAYLOG_WAZUH_INDEXER_HOSTNAME "$cert_hostname"
  set_env GRAYLOG_WAZUH_INDEXER_IP "$host"
  echo "Rewrote GRAYLOG_ELASTICSEARCH_HOSTS to connect via '$cert_hostname' (the"
  echo "certificate's own name) instead of '$host', mapped to $host via"
  echo "extra_hosts in docker-compose.yml. This avoids a 'Hostname not"
  echo "verified' error that trusting the certificate alone does not fix."
elif [[ -z "$cert_hostname" ]]; then
  echo "Warning: could not read a hostname from the fetched certificate;" >&2
  echo "leaving GRAYLOG_ELASTICSEARCH_HOSTS as-is. If Graylog logs a" >&2
  echo "'Hostname ... not verified' error, connect via the certificate's" >&2
  echo "CN/SAN manually -- see README Section 5.1." >&2
fi

compose=(docker compose --env-file .env -f docker-compose.yml)
if [[ "$pull" == true ]]; then
  "${compose[@]}" pull
fi
"${compose[@]}" up -d
"${compose[@]}" ps
