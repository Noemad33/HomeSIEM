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

function Set-EnvValue([string]$Name, [string]$Value) {
    $lines = @(Get-Content ".env")
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
    Set-Content -Path ".env" -Value $lines
}

$envLines = Get-Content ".env"
$hostsLine = ($envLines | Where-Object { $_ -match "^GRAYLOG_ELASTICSEARCH_HOSTS=" }) -replace "^GRAYLOG_ELASTICSEARCH_HOSTS=", ""
if (-not $hostsLine) {
    throw "GRAYLOG_ELASTICSEARCH_HOSTS is not set in deploy\graylog\.env."
}

$scheme, $rest = $hostsLine -split "://", 2
if ($rest -match "@") {
    $userinfo, $rest = $rest -split "@", 2
} else {
    $userinfo = ""
}
# Only the first host is used if a comma-separated list was configured.
$hostPort = ($rest -split ",")[0]
$targetHost, $targetPortText = $hostPort -split ":", 2
$targetPort = if ($targetPortText) { [int]$targetPortText } else { 9200 }

# Graylog's self-managed OpenSearch mode has no "skip TLS verification"
# option (unlike CoPilot's OPENSEARCH_SSL_VERIFY=false). The official image's
# own entrypoint (docker-entrypoint.sh, setupCertificates()) handles trust:
# it imports every *.crt file under a mounted /certificates directory into a
# fresh copy of the container's own JVM truststore on every start, no
# GRAYLOG_SERVER_JAVA_OPTS wrangling required -- that env var has a history
# of being unreliable in this image and is NOT used here.
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

    # Trust is only half of TLS validation -- Java also checks that the host
    # you connected to matches the certificate's SAN/CN, even for a
    # certificate it already trusts. Wazuh's certs are issued to a role name
    # (e.g. "wazuh.indexer"), not an IP, so connecting via IP fails with
    # "Hostname ... not verified" even though the cert itself is fine.
    # GetNameInfo returns the SAN DNS entry (falling back to CN), the same
    # thing Java's hostname verifier checks.
    $certHostname = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)

    if ($certHostname -and $certHostname -ne $targetHost) {
        $newHostPort = "${certHostname}:${targetPort}"
        $newHostsLine = if ($userinfo) { "${scheme}://${userinfo}@${newHostPort}" } else { "${scheme}://${newHostPort}" }
        Set-EnvValue "GRAYLOG_ELASTICSEARCH_HOSTS" $newHostsLine
        Set-EnvValue "GRAYLOG_WAZUH_INDEXER_HOSTNAME" $certHostname
        Set-EnvValue "GRAYLOG_WAZUH_INDEXER_IP" $targetHost
        Write-Host "Rewrote GRAYLOG_ELASTICSEARCH_HOSTS to connect via '$certHostname' (the"
        Write-Host "certificate's own name) instead of '$targetHost', mapped to $targetHost via"
        Write-Host "extra_hosts in docker-compose.yml. This avoids a 'Hostname not"
        Write-Host "verified' error that trusting the certificate alone does not fix."
    } elseif (-not $certHostname) {
        Write-Warning "Could not read a hostname from the fetched certificate; leaving GRAYLOG_ELASTICSEARCH_HOSTS as-is. If Graylog logs a 'Hostname ... not verified' error, connect via the certificate's CN/SAN manually -- see README Section 5.1."
    }
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
