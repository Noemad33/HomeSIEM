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

graylog_version="$(sed -nE 's/^GRAYLOG_VERSION=(.*)$/\1/p' .env)"
graylog_version="${graylog_version:-7.1.9}"

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
# option (unlike CoPilot's OPENSEARCH_SSL_VERIFY=false) -- it uses a real
# Java truststore. Trust the certificate the indexer actually presents
# directly, rather than hunting for a separate root CA file on the Wazuh
# host; this is the same practical trust level as SSL_VERIFY=false, just
# implemented as an explicit, inspectable pin instead of a blanket skip.
if [[ ! -f graylog-truststore.jks || "$force_trust" == true ]]; then
  echo "Fetching TLS certificate presented by $hostport ..."
  openssl s_client -connect "$hostport" -servername "$host" -showcerts </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > wazuh-indexer-ca.pem

  if [[ ! -s wazuh-indexer-ca.pem ]]; then
    echo "Failed to fetch a certificate from $hostport. Is the Wazuh Indexer reachable and listening there?" >&2
    exit 1
  fi

  echo "Building Graylog truststore (uses the Graylog image's own JVM/keytool, no local Java needed) ..."
  rm -f graylog-truststore.jks
  docker run --rm -v "$(pwd):/certs" "graylog/graylog:${graylog_version}" \
    keytool -importcert -noprompt \
      -keystore /certs/graylog-truststore.jks \
      -storepass changeit \
      -alias wazuh-indexer \
      -file /certs/wazuh-indexer-ca.pem
  echo "Wrote deploy/graylog/graylog-truststore.jks"
else
  echo "Reusing existing deploy/graylog/graylog-truststore.jks (rerun with --force-trust to rebuild, e.g. after the Wazuh Indexer's certificate rotates)."
fi

compose=(docker compose --env-file .env -f docker-compose.yml)
if [[ "$pull" == true ]]; then
  "${compose[@]}" pull
fi
"${compose[@]}" up -d
"${compose[@]}" ps
