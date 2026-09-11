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
$graylogSecret = New-RandomHex 48
$sha256 = [Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($graylogPassword))
$graylogHash = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""

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
    OPENSEARCH_SSL_VERIFY = "false"; WAZUH_PROD_SSL_VERIFY = "false"
}
foreach ($entry in $mainValues.GetEnumerator()) { Set-EnvValue $mainEnv $entry.Key $entry.Value }
Set-EnvValue $graylogEnv "GRAYLOG_PASSWORD_SECRET" $graylogSecret
Set-EnvValue $graylogEnv "GRAYLOG_VERSION" "7.1.9"
Set-EnvValue $graylogEnv "GRAYLOG_ROOT_PASSWORD_SHA2" $graylogHash
Set-EnvValue $graylogEnv "GRAYLOG_HTTP_EXTERNAL_URI" $graylogExternalUri
Set-EnvValue $graylogEnv "GRAYLOG_SYSLOG_UDP_PORT" "2514"
Set-EnvValue $graylogEnv "GRAYLOG_SYSLOG_TCP_PORT" "2515"

Write-Host "Created .env and deploy\graylog\.env with generated secrets."
Write-Host "The Graylog admin password was not written to either file. Store it in your password manager."
Write-Host "Start Graylog first, initialize its Data Node, then run setup.ps1."
