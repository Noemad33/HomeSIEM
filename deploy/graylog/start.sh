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

[[ -f .env ]] || { echo "Missing deploy/graylog/.env. Run deploy/home-lab/setup-env.sh first." >&2; exit 1; }

hosts_line="$(sed -nE 's/^GRAYLOG_ELASTICSEARCH_HOSTS=(.*)$/\1/p' .env)"
if [[ -z "$hosts_line" ]]; then
  echo "GRAYLOG_ELASTICSEARCH_HOSTS is not set in deploy/graylog/.env." >&2
  exit 1
fi

# Strip scheme and any embedded credentials, keep host:port. Only the first
# host is used if a comma-separated list was configured.
hostport="$(printf '%s' "$hosts_line" | sed -E 's#^[a-zA-Z]+://##; s#.*@##' | cut -d, -f1)"
host="${hostport%%:*}"

# Graylog's self-managed OpenSearch mode has no "skip TLS verification"
# option (unlike CoPilot's OPENSEARCH_SSL_VERIFY=false). The official image's
# own entrypoint (docker-entrypoint.sh, setupCertificates()) handles this
# properly: it imports every *.crt file under a mounted /certificates
# directory into a fresh copy of the container's own JVM truststore on every
# start, no GRAYLOG_SERVER_JAVA_OPTS wrangling required -- that env var has a
# history of being unreliable in this image and is NOT used here. We only
# need to drop the certificate file in place; docker-compose.yml mounts
# ./certificates into /certificates.
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

compose=(docker compose --env-file .env -f docker-compose.yml)
if [[ "$pull" == true ]]; then
  "${compose[@]}" pull
fi
"${compose[@]}" up -d
"${compose[@]}" ps
