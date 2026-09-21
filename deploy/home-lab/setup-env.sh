#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

force=false
if [[ "${1:-}" == "--force" ]]; then
  force=true
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

command -v openssl >/dev/null || { echo "openssl is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

main_env=".env"
graylog_env="deploy/graylog/.env"
if [[ -e "$main_env" || -e "$graylog_env" ]]; then
  if [[ "$force" != true ]]; then
    echo "An environment file already exists." >&2
    echo "Review it and rerun with --force only if you intend to replace it." >&2
    exit 1
  fi
  timestamp="$(date +%Y%m%d-%H%M%S)"
  [[ -e "$main_env" ]] && cp -p "$main_env" "$main_env.bak.$timestamp"
  [[ -e "$graylog_env" ]] && cp -p "$graylog_env" "$graylog_env.bak.$timestamp"
fi

cp .env.example "$main_env"
cp deploy/graylog/.env.example "$graylog_env"
chmod 600 "$main_env" "$graylog_env"

set_env() {
  local file="$1" key="$2" value="$3"
  KEY="$key" VALUE="$value" TARGET="$file" python3 - <<'PY'
from pathlib import Path
import os

path = Path(os.environ["TARGET"])
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

random_hex() { openssl rand -hex "$1"; }
random_b64() { openssl rand -base64 "$1" | tr -d '\n'; }
fernet_key() {
  python3 - <<'PY'
import base64
import os
print(base64.urlsafe_b64encode(os.urandom(32)).decode())
PY
}

read -r -p "CoPilot hostname or private IP [localhost]: " copilot_host
copilot_host="${copilot_host:-localhost}"
read -r -p "Wazuh Indexer URL [https://wazuh-server:9200]: " wazuh_indexer_url
wazuh_indexer_url="${wazuh_indexer_url:-https://wazuh-server:9200}"
read -r -p "Wazuh Indexer username [admin]: " wazuh_indexer_user
wazuh_indexer_user="${wazuh_indexer_user:-admin}"
read -r -s -p "Wazuh Indexer password: " wazuh_indexer_password; echo
read -r -p "Wazuh Manager URL [https://wazuh-server:55000]: " wazuh_manager_url
wazuh_manager_url="${wazuh_manager_url:-https://wazuh-server:55000}"
read -r -p "Wazuh Manager username [wazuh-wui]: " wazuh_manager_user
wazuh_manager_user="${wazuh_manager_user:-wazuh-wui}"
read -r -s -p "Wazuh Manager password: " wazuh_manager_password; echo

read -r -p "Graylog URL [http://graylog.home.lan:9000]: " graylog_url
graylog_url="${graylog_url:-http://graylog.home.lan:9000}"
read -r -s -p "Graylog admin password: " graylog_password; echo
read -r -p "Graylog external URL [${graylog_url}/]: " graylog_external_uri
graylog_external_uri="${graylog_external_uri:-${graylog_url%/}/}"
read -r -s -p "OpenAI API key (optional, press Enter to skip): " openai_key; echo

jwt_secret="$(random_b64 32)"
sso_secret="$(random_b64 32)"
totp_key="$(fernet_key)"
mysql_root_password="$(random_hex 24)"
mysql_password="$(random_hex 24)"
minio_password="$(random_hex 24)"
webhook_secret="$(random_hex 32)"
opensearch_token="$(random_hex 32)"
mysql_token="$(random_hex 32)"
wazuh_token="$(random_hex 32)"
velociraptor_token="$(random_hex 32)"
graylog_password_hash="$(printf '%s' "$graylog_password" | sha256sum | awk '{print $1}')"
graylog_password_secret="$(random_hex 48)"

# Graylog runs against the same OpenSearch cluster as the Wazuh Indexer
# (self-managed OpenSearch, no Data Node) so gl-events* is visible to
# CoPilot's Wazuh-Indexer connector. Reuses the Wazuh Indexer credentials
# above as a starting point -- see deploy/graylog/.env.example for the
# privilege caveat.
wazuh_indexer_scheme="${wazuh_indexer_url%%://*}"
wazuh_indexer_hostport="${wazuh_indexer_url#*://}"
graylog_elasticsearch_hosts="${wazuh_indexer_scheme}://${wazuh_indexer_user}:${wazuh_indexer_password}@${wazuh_indexer_hostport}"

set_env "$main_env" SERVER_HOST "$copilot_host"
read -r -p "CoPilot HTTPS port [8443]: " copilot_port
copilot_port="${copilot_port:-8443}"
set_env "$main_env" COPILOT_URL "https://$copilot_host:$copilot_port"
set_env "$main_env" JWT_SECRET "$jwt_secret"
set_env "$main_env" SSO_STATE_SECRET "$sso_secret"
set_env "$main_env" TOTP_ENCRYPTION_KEY "$totp_key"
set_env "$main_env" MYSQL_ROOT_PASSWORD "$mysql_root_password"
set_env "$main_env" MYSQL_PASSWORD "$mysql_password"
set_env "$main_env" MINIO_ROOT_PASSWORD "$minio_password"
set_env "$main_env" WAZUH_INDEXER_URL "$wazuh_indexer_url"
set_env "$main_env" WAZUH_INDEXER_USERNAME "$wazuh_indexer_user"
set_env "$main_env" WAZUH_INDEXER_PASSWORD "$wazuh_indexer_password"
set_env "$main_env" OPENSEARCH_URL "$wazuh_indexer_url"
set_env "$main_env" OPENSEARCH_USERNAME "$wazuh_indexer_user"
set_env "$main_env" OPENSEARCH_PASSWORD "$wazuh_indexer_password"
set_env "$main_env" WAZUH_MANAGER_URL "$wazuh_manager_url"
set_env "$main_env" WAZUH_MANAGER_USERNAME "$wazuh_manager_user"
set_env "$main_env" WAZUH_MANAGER_PASSWORD "$wazuh_manager_password"
set_env "$main_env" WAZUH_PROD_URL "$wazuh_manager_url"
set_env "$main_env" WAZUH_PROD_USERNAME "$wazuh_manager_user"
set_env "$main_env" WAZUH_PROD_PASSWORD "$wazuh_manager_password"
set_env "$main_env" GRAYLOG_URL "$graylog_url"
set_env "$main_env" GRAYLOG_USERNAME admin
set_env "$main_env" GRAYLOG_PASSWORD "$graylog_password"
set_env "$main_env" GRAYLOG_NETWORK_URL "$graylog_url"
set_env "$main_env" GRAYLOG_NETWORK_USERNAME admin
set_env "$main_env" GRAYLOG_NETWORK_PASSWORD "$graylog_password"
set_env "$main_env" GRAYLOG_API_HEADER_VALUE "$webhook_secret"
set_env "$main_env" MCP_OPENSEARCH_AUTH_TOKEN "$opensearch_token"
set_env "$main_env" MCP_MYSQL_AUTH_TOKEN "$mysql_token"
set_env "$main_env" MCP_WAZUH_AUTH_TOKEN "$wazuh_token"
set_env "$main_env" MCP_VELOCIRAPTOR_AUTH_TOKEN "$velociraptor_token"
set_env "$main_env" MCP_VELOCIRAPTOR_SERVER_ENABLED false
set_env "$main_env" OPENAI_API_KEY "$openai_key"
set_env "$main_env" OPENSEARCH_SSL_VERIFY false
set_env "$main_env" WAZUH_PROD_SSL_VERIFY false

set_env "$graylog_env" GRAYLOG_PASSWORD_SECRET "$graylog_password_secret"
set_env "$graylog_env" GRAYLOG_VERSION 7.1.9
set_env "$graylog_env" GRAYLOG_ELASTICSEARCH_HOSTS "$graylog_elasticsearch_hosts"
set_env "$graylog_env" GRAYLOG_ROOT_PASSWORD_SHA2 "$graylog_password_hash"
set_env "$graylog_env" GRAYLOG_HTTP_EXTERNAL_URI "$graylog_external_uri"
set_env "$graylog_env" GRAYLOG_SYSLOG_UDP_PORT 2514
set_env "$graylog_env" GRAYLOG_SYSLOG_TCP_PORT 2515

echo
echo "Created $main_env and $graylog_env with generated secrets."
echo "The Graylog admin password was not written to either file. Store it in your password manager."
echo "Graylog points at the Wazuh Indexer's OpenSearch cluster (GRAYLOG_ELASTICSEARCH_HOSTS in"
echo "deploy/graylog/.env) instead of running its own Data Node -- confirm that connection works"
echo "before relying on Graylog alerts reaching CoPilot. Start Graylog first, then run:"
echo "  bash deploy/home-lab/setup.sh --pull --capture-admin-password"
