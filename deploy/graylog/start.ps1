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
$graylogVersion = ($envLines | Where-Object { $_ -match "^GRAYLOG_VERSION=" }) -replace "^GRAYLOG_VERSION=", ""
if (-not $graylogVersion) { $graylogVersion = "7.1.9" }

$hostsLine = ($envLines | Where-Object { $_ -match "^GRAYLOG_ELASTICSEARCH_HOSTS=" }) -replace "^GRAYLOG_ELASTICSEARCH_HOSTS=", ""
if (-not $hostsLine) {
    throw "GRAYLOG_ELASTICSEARCH_HOSTS is not set in deploy\graylog\.env."
}

# Strip scheme and any embedded credentials, keep host:port. Only the first
# host is used if a comma-separated list was configured.
$hostPort = ($hostsLine -replace "^[a-zA-Z]+://", "" -replace ".*@", "") -split "," | Select-Object -First 1
$targetHost, $targetPortText = $hostPort -split ":", 2
$targetPort = if ($targetPortText) { [int]$targetPortText } else { 9200 }

$trustStorePath = Join-Path $GraylogDir "graylog-truststore.jks"
$certPath = Join-Path $GraylogDir "wazuh-indexer-ca.pem"

# Graylog's self-managed OpenSearch mode has no "skip TLS verification"
# option (unlike CoPilot's OPENSEARCH_SSL_VERIFY=false) -- it uses a real
# Java truststore. Trust the certificate the indexer actually presents
# directly, rather than hunting for a separate root CA file on the Wazuh
# host; this is the same practical trust level as SSL_VERIFY=false, just
# implemented as an explicit, inspectable pin instead of a blanket skip.
if ((-not (Test-Path $trustStorePath)) -or $ForceTrust) {
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

    Write-Host "Building Graylog truststore (uses the Graylog image's own JVM/keytool, no local Java needed) ..."
    if (Test-Path $trustStorePath) { Remove-Item $trustStorePath -Force }
    & docker run --rm -v "${GraylogDir}:/certs" "graylog/graylog:${graylogVersion}" `
        keytool -importcert -noprompt `
            -keystore /certs/graylog-truststore.jks `
            -storepass changeit `
            -alias wazuh-indexer `
            -file /certs/wazuh-indexer-ca.pem
    if ($LASTEXITCODE -ne 0) { throw "keytool failed to build the truststore." }
    Write-Host "Wrote deploy\graylog\graylog-truststore.jks"
} else {
    Write-Host "Reusing existing deploy\graylog\graylog-truststore.jks (rerun with -ForceTrust to rebuild, e.g. after the Wazuh Indexer's certificate rotates)."
}

if ($Pull) {
    & docker compose --env-file .env -f docker-compose.yml pull
    if ($LASTEXITCODE -ne 0) { throw "Docker image pull failed." }
}
& docker compose --env-file .env -f docker-compose.yml up -d
if ($LASTEXITCODE -ne 0) { throw "Graylog startup failed." }
& docker compose --env-file .env -f docker-compose.yml ps
