param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $RepoRoot

$mainEnv = Join-Path $RepoRoot ".env"
$graylogEnv = Join-Path $RepoRoot "deploy\graylog\.env"
if ((Test-Path $mainEnv) -or (Test-Path $graylogEnv)) {
    if (-not $Force) {
        throw "An environment file already exists. Review it and rerun with -Force only if you intend to replace it."
    }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if (Test-Path $mainEnv) { Copy-Item $mainEnv "$mainEnv.bak.$timestamp" }
    if (Test-Path $graylogEnv) { Copy-Item $graylogEnv "$graylogEnv.bak.$timestamp" }
}

Copy-Item .env.example $mainEnv -Force
Copy-Item deploy\graylog\.env.example $graylogEnv -Force

function Set-EnvValue([string]$Path, [string]$Name, [string]$Value) {
    $lines = @(Get-Content $Path)
    $replacement = "$Name=$Value"
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith("$Name=")) {
            $lines[$i] = $replacement
            $found = $true
            break
        }
    }
    if (-not $found) { $lines += $replacement }
    Set-Content -Path $Path -Value $lines
}

function New-RandomBase64([int]$Bytes = 32) {
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    [Convert]::ToBase64String($buffer)
}

function New-RandomHex([int]$Bytes = 32) {
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    ($buffer | ForEach-Object { $_.ToString("x2") }) -join ""
}

function New-FernetKey {
    $buffer = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    [Convert]::ToBase64String($buffer).Replace('+', '-').Replace('/', '_')
}

function Read-Secret([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$copilotHost = Read-Host "CoPilot hostname or private IP [localhost]"
if (-not $copilotHost) { $copilotHost = "localhost" }
$copilotPort = Read-Host "CoPilot HTTPS port [8443]"
if (-not $copilotPort) { $copilotPort = "8443" }
$indexerUrl = Read-Host "Wazuh Indexer URL [https://wazuh-server:9200]"
if (-not $indexerUrl) { $indexerUrl = "https://wazuh-server:9200" }
$indexerUser = Read-Host "Wazuh Indexer username [admin]"
if (-not $indexerUser) { $indexerUser = "admin" }
$indexerPassword = Read-Secret "Wazuh Indexer password"
$managerUrl = Read-Host "Wazuh Manager URL [https://wazuh-server:55000]"
if (-not $managerUrl) { $managerUrl = "https://wazuh-server:55000" }
$managerUser = Read-Host "Wazuh Manager username [wazuh-wui]"
if (-not $managerUser) { $managerUser = "wazuh-wui" }
$managerPassword = Read-Secret "Wazuh Manager password"
$graylogUrl = Read-Host "Graylog URL [http://graylog.home.lan:9000]"
if (-not $graylogUrl) { $graylogUrl = "http://graylog.home.lan:9000" }
$graylogPassword = Read-Secret "Graylog admin password"
$graylogExternalUri = Read-Host "Graylog external URL [$($graylogUrl.TrimEnd('/'))/]"
if (-not $graylogExternalUri) { $graylogExternalUri = "$($graylogUrl.TrimEnd('/'))/" }
$openAiKey = Read-Secret "OpenAI API key (press Enter to skip)"

# Velociraptor and Talon are typically deployed AFTER this first pass -- accept
# the defaults below if you haven't stood them up yet, then rerun with -Force
# once they're ready. Both run on the CoPilot VM's LAN address in the
# single-VM home-lab topology, never localhost or a container name.
$velociraptorUrl = Read-Host "Velociraptor URL (leave default if not deployed yet) [https://${copilotHost}:8000]"
if (-not $velociraptorUrl) { $velociraptorUrl = "https://${copilotHost}:8000" }
$talonUrl = Read-Host "Talon URL (leave default if not deployed yet) [http://${copilotHost}:3100]"
if (-not $talonUrl) { $talonUrl = "http://${copilotHost}:3100" }

$jwt = New-RandomBase64
$sso = New-RandomBase64
$totp = New-FernetKey
$mysqlRoot = New-RandomHex 24
$mysqlPassword = New-RandomHex 24
$minioPassword = New-RandomHex 24
$webhook = New-RandomHex 32
$openSearchToken = New-RandomHex 32
$mysqlToken = New-RandomHex 32
$wazuhToken = New-RandomHex 32
$veloToken = New-RandomHex 32
$veloHeaderSecret = New-RandomHex 32
$talonApiKey = New-RandomHex 32
$grafanaAdminPassword = New-RandomHex 16
$grafanaHeaderSecret = New-RandomHex 32
$influxdbPassword = New-RandomHex 16
$influxdbAdminToken = New-RandomHex 32
$graylogSecret = New-RandomHex 48
$sha256 = [Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($graylogPassword))
$graylogHash = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""

# Graylog runs against the same OpenSearch cluster as the Wazuh Indexer
# (self-managed OpenSearch, no Data Node) so gl-events* is visible to
# CoPilot's Wazuh-Indexer connector. Reuses the Wazuh Indexer credentials
# above as a starting point -- see deploy/graylog/.env.example for the
# privilege caveat.
$indexerScheme, $indexerHostPort = $indexerUrl -split "://", 2
$graylogElasticsearchHosts = "$indexerScheme`://$indexerUser`:$indexerPassword@$indexerHostPort"

$mainValues = @{
    SERVER_HOST = $copilotHost; COPILOT_URL = "https://$copilotHost`:$copilotPort"; JWT_SECRET = $jwt; SSO_STATE_SECRET = $sso; TOTP_ENCRYPTION_KEY = $totp
    MYSQL_ROOT_PASSWORD = $mysqlRoot; MYSQL_PASSWORD = $mysqlPassword; MINIO_ROOT_PASSWORD = $minioPassword
    WAZUH_INDEXER_URL = $indexerUrl; WAZUH_INDEXER_USERNAME = $indexerUser; WAZUH_INDEXER_PASSWORD = $indexerPassword
    OPENSEARCH_URL = $indexerUrl; OPENSEARCH_USERNAME = $indexerUser; OPENSEARCH_PASSWORD = $indexerPassword
    WAZUH_MANAGER_URL = $managerUrl; WAZUH_MANAGER_USERNAME = $managerUser; WAZUH_MANAGER_PASSWORD = $managerPassword
    WAZUH_PROD_URL = $managerUrl; WAZUH_PROD_USERNAME = $managerUser; WAZUH_PROD_PASSWORD = $managerPassword
    GRAYLOG_URL = $graylogUrl; GRAYLOG_USERNAME = "admin"; GRAYLOG_PASSWORD = $graylogPassword
    GRAYLOG_NETWORK_URL = $graylogUrl; GRAYLOG_NETWORK_USERNAME = "admin"; GRAYLOG_NETWORK_PASSWORD = $graylogPassword
    GRAYLOG_API_HEADER_VALUE = $webhook; MCP_OPENSEARCH_AUTH_TOKEN = $openSearchToken; MCP_MYSQL_AUTH_TOKEN = $mysqlToken
    MCP_WAZUH_AUTH_TOKEN = $wazuhToken; MCP_VELOCIRAPTOR_AUTH_TOKEN = $veloToken; MCP_VELOCIRAPTOR_SERVER_ENABLED = "false"; OPENAI_API_KEY = $openAiKey
    VELOCIRAPTOR_URL = $velociraptorUrl; VELOCIRAPTOR_API_HEADER_VALUE = $veloHeaderSecret
    # TALON_API_KEY here must be copied into Talon's OWN .env as HTTP_API_KEY --
    # the two projects name the same shared secret differently. See README 10.4.
    TALON_URL = $talonUrl; TALON_API_KEY = $talonApiKey
    # Grafana/InfluxDB start automatically with the main CoPilot stack.
    # GRAFANA_ADMIN_*/INFLUXDB_* bootstrap the containers; GRAFANA_URL/
    # USERNAME/PASSWORD and INFLUXDB_URL/API_KEY/ORG_AND_BUCKET are the
    # matching staging values for CoPilot's own Grafana/InfluxDB connectors.
    GRAFANA_ADMIN_PASSWORD = $grafanaAdminPassword; GRAFANA_API_HEADER_VALUE = $grafanaHeaderSecret
    GRAFANA_URL = "http://${copilotHost}:3000"; GRAFANA_USERNAME = "admin"; GRAFANA_PASSWORD = $grafanaAdminPassword
    INFLUXDB_PASSWORD = $influxdbPassword; INFLUXDB_ADMIN_TOKEN = $influxdbAdminToken
    INFLUXDB_URL = "http://${copilotHost}:8086"; INFLUXDB_API_KEY = $influxdbAdminToken; INFLUXDB_ORG_AND_BUCKET = "socfortress,copilot"
    OPENSEARCH_SSL_VERIFY = "false"; WAZUH_PROD_SSL_VERIFY = "false"
}
foreach ($entry in $mainValues.GetEnumerator()) { Set-EnvValue $mainEnv $entry.Key $entry.Value }
Set-EnvValue $graylogEnv "GRAYLOG_PASSWORD_SECRET" $graylogSecret
Set-EnvValue $graylogEnv "GRAYLOG_VERSION" "7.1.9"
Set-EnvValue $graylogEnv "GRAYLOG_ELASTICSEARCH_HOSTS" $graylogElasticsearchHosts
Set-EnvValue $graylogEnv "GRAYLOG_ROOT_PASSWORD_SHA2" $graylogHash
Set-EnvValue $graylogEnv "GRAYLOG_HTTP_EXTERNAL_URI" $graylogExternalUri
Set-EnvValue $graylogEnv "GRAYLOG_SYSLOG_UDP_PORT" "2514"
Set-EnvValue $graylogEnv "GRAYLOG_SYSLOG_TCP_PORT" "2515"

Write-Host "Created .env and deploy\graylog\.env with generated secrets."
Write-Host "The Graylog admin password was not written to either file. Store it in your password manager."
Write-Host "Graylog points at the Wazuh Indexer's OpenSearch cluster (GRAYLOG_ELASTICSEARCH_HOSTS in"
Write-Host "deploy\graylog\.env) instead of running its own Data Node -- confirm that connection works"
Write-Host "before relying on Graylog alerts reaching CoPilot. Start Graylog first, then run setup.ps1."
Write-Host ""
Write-Host "Velociraptor and Talon URLs/secrets were written using defaults if you"
Write-Host "haven't deployed them yet (README Sections 10.2 and 10.4). Rerun this"
Write-Host "script with -Force once they're up to capture their real values, or"
Write-Host "edit .env directly for VELOCIRAPTOR_URL, TALON_URL, and TALON_API_KEY."
Write-Host "TALON_API_KEY must be copied into Talon's own .env as HTTP_API_KEY."
Write-Host ""
Write-Host "Grafana and InfluxDB credentials were generated and written to .env --"
Write-Host "nothing left to fill in for them; they start with the rest of the stack."
Write-Host ""
Write-Host "Everything above is now filled in. The only .env values still at their"
Write-Host "REPLACE_* placeholder are optional third-party integrations this runbook"
Write-Host "doesn't cover (Shuffle, Sublime, VirusTotal, Resend, Portainer) -- leave"
Write-Host "them alone unless you're specifically setting one of those up."
