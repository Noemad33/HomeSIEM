param(
    [switch]$ForceTrust,
    [switch]$Pull
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$GraylogDir = Join-Path $RepoRoot "deploy\graylog"
Set-Location $GraylogDir

if (-not (Test-Path ".env")) {
    throw "Missing deploy\graylog\.env. Run deploy\home-lab\setup-env.ps1 first."
}

$envLines = Get-Content ".env"
$hostsLine = ($envLines | Where-Object { $_ -match "^GRAYLOG_ELASTICSEARCH_HOSTS=" }) -replace "^GRAYLOG_ELASTICSEARCH_HOSTS=", ""
if (-not $hostsLine) {
    throw "GRAYLOG_ELASTICSEARCH_HOSTS is not set in deploy\graylog\.env."
}

# Strip scheme and any embedded credentials, keep host:port. Only the first
# host is used if a comma-separated list was configured.
$hostPort = ($hostsLine -replace "^[a-zA-Z]+://", "" -replace ".*@", "") -split "," | Select-Object -First 1
$targetHost, $targetPortText = $hostPort -split ":", 2
$targetPort = if ($targetPortText) { [int]$targetPortText } else { 9200 }

# Graylog's self-managed OpenSearch mode has no "skip TLS verification"
# option (unlike CoPilot's OPENSEARCH_SSL_VERIFY=false). The official image's
# own entrypoint (docker-entrypoint.sh, setupCertificates()) handles this
# properly: it imports every *.crt file under a mounted /certificates
# directory into a fresh copy of the container's own JVM truststore on every
# start, no GRAYLOG_SERVER_JAVA_OPTS wrangling required -- that env var has a
# history of being unreliable in this image and is NOT used here. We only
# need to drop the certificate file in place; docker-compose.yml mounts
# ./certificates into /certificates.
$certDir = Join-Path $GraylogDir "certificates"
if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Force -Path $certDir | Out-Null }
$certPath = Join-Path $certDir "wazuh-indexer.crt"

if ((-not (Test-Path $certPath)) -or $ForceTrust) {
    Write-Host "Fetching TLS certificate presented by ${targetHost}:${targetPort} ..."
    $tcpClient = New-Object System.Net.Sockets.TcpClient($targetHost, $targetPort)
    $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, ({ $true }))
    $sslStream.AuthenticateAsClient($targetHost)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
    $sslStream.Close()
    $tcpClient.Close()

    $pem = "-----BEGIN CERTIFICATE-----`n" +
        [Convert]::ToBase64String($cert.RawData, "InsertLineBreaks") +
        "`n-----END CERTIFICATE-----"
    Set-Content -Path $certPath -Value $pem -NoNewline
    Write-Host "Wrote deploy\graylog\certificates\wazuh-indexer.crt"
} else {
    Write-Host "Reusing existing deploy\graylog\certificates\wazuh-indexer.crt (rerun with -ForceTrust to refetch, e.g. after the Wazuh Indexer's certificate rotates)."
}

if ($Pull) {
    & docker compose --env-file .env -f docker-compose.yml pull
    if ($LASTEXITCODE -ne 0) { throw "Docker image pull failed." }
}
& docker compose --env-file .env -f docker-compose.yml up -d
if ($LASTEXITCODE -ne 0) { throw "Graylog startup failed." }
& docker compose --env-file .env -f docker-compose.yml ps
