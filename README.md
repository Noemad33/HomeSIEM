# HomeSIEM

HomeSIEM is a home-lab security monitoring and response deployment built
around Wazuh, Graylog, and SOCFortress CoPilot.

- Wazuh collects endpoint telemetry and stores security events.
- Graylog receives UDM and network-device syslog.
- CoPilot provides investigation, enrichment, cases, dashboards, and response.

This runbook is intentionally linear. Follow it from top to bottom on the
Debian 12 VM.

## Architecture

```
Wazuh agents ----------------------> Wazuh Manager + Indexer (OpenSearch)
                                          |
                                          +--> CoPilot (copilot-mcp)
                                          +--> Grafana (OpenSearch data source)

UDM / network devices --> Graylog --> CoPilot
                              |
                              +--> writes into the SAME OpenSearch cluster as
                                   the Wazuh Indexer above (self-managed
                                   OpenSearch, no Graylog Data Node) so
                                   gl-events* is visible to CoPilot's
                                   Wazuh-Indexer connector; confirm via
                                   Graylog System > Indices / _cat/indices

InfluxDB --> Grafana (time-series store; deployed but not yet fed by
             anything in this stack -- see Section 10.1)

CoPilot --> optional Velociraptor (DFIR), Shuffle (SOAR), VirusTotal (enrichment)
```

Wazuh, Graylog, and CoPilot are separate Compose projects on the same VM.
This avoids coupling their certificate and upgrade lifecycles. Storage is an
exception: Graylog is deliberately pointed at the Wazuh Indexer's OpenSearch
cluster (see `GRAYLOG_ELASTICSEARCH_HOSTS` below) rather than running its own
Data Node, because CoPilot's automatic alert ingestion queries `gl-events*`
through the Wazuh-Indexer connector -- if Graylog wrote to a separate
cluster, those events would never reach CoPilot's Incident Management.

Grafana and InfluxDB currently run as additional services inside the root
`docker-compose.yml` (the CoPilot project), rather than as their own Compose
project. This couples their lifecycle to CoPilot's for now; moving them to a
dedicated `deploy/monitoring/` project later would match the pattern used
for Graylog, but isn't required for them to function.

## 1. Prepare the VM

Use a dedicated Debian 12 VM with at least:

- 4 vCPU
- 16 GB RAM
- 250 GB SSD
- Stable private LAN address or DNS name
- Docker Engine and the Docker Compose plugin

Use the VM's private IP or DNS name when services communicate across Compose
projects. Do not use `localhost`, `127.0.0.1`, or another project's container
name.

Reserve these host ports:

| Service | Host port | Purpose |
| --- | ---: | --- |
| Wazuh | `1514` | Agent/syslog |
| Wazuh | `1515` | Agent enrollment |
| Wazuh | `1516` | Cluster communication |
| Wazuh | `55000` | Manager API |
| Wazuh | `9200` | Indexer/OpenSearch |
| Wazuh | `443` | Wazuh dashboard |
| Graylog | `9000` | Web UI/API -- **collides with CoPilot MinIO's `9000` in the base `docker-compose.yml`.** Only safe because the home-lab override always strips MinIO's host publish; never run `docker compose up` on the CoPilot project without `-f deploy/home-lab/docker-compose.override.yml` |
| Graylog | `2514/udp` | UDM syslog |
| Graylog | `2515/tcp` | UDM syslog |
| Graylog | `5555/tcp` | Wazuh Fluent Bit input (not mapped by default; see 8.4) |
| CoPilot | `8443` | HTTPS frontend |
| CoPilot | `5000` | Backend API (Graylog webhooks, Talon) -- bound to `BACKEND_BIND_IP` (default `127.0.0.1`, loopback only), not published on all interfaces |
| Grafana      | `3000`  | Dashboards (OpenSearch + InfluxDB)                 |
| InfluxDB     | `8086`  | Time-series API (deployed, currently unused)       |
| Velociraptor | `8000`  | Agent/frontend (not yet deployed)                  |
| Velociraptor | `8889`  | Web GUI (not yet deployed)                         |
| Velociraptor | `8001`  | API, consumed by copilot-mcp (not yet deployed)    |
| Shuffle      | `3443`  | Web UI (not yet deployed)                          |
| Talon        | `3100`  | HTTP API/chat (not yet deployed; systemd service, not Docker) |
| Talon (OneCLI vault) | `10254`, `10255` | Credential vault REST API/gateway, if used (not yet deployed) |

This repository pins Graylog to `7.1.9`, the current stable release used by
this deployment. Graylog 7.1 requires MongoDB 7.x, which is why this stack
uses `mongo:7.0`.

Graylog does not run its own Data Node or OpenSearch heap in this deployment
-- it connects to the Wazuh Indexer's existing OpenSearch cluster via
`GRAYLOG_ELASTICSEARCH_HOSTS` (see Section 5). Graylog's ingest adds to the
load already carried by that cluster, so size the Wazuh Indexer's own
OpenSearch heap (set on the Wazuh side, not in this repo) with Graylog's
expected volume in mind, not just Wazuh's.

Restrict these ports to the LAN or VPN. Do not expose service administration
ports directly to the public internet.

## 2. Deploy Wazuh

Install Wazuh using its official single-node Docker deployment. Generate the
Wazuh certificates with the official helper and pin the Wazuh version used for
the test deployment.

After Wazuh starts, record:

- Indexer URL, normally `https://VM_IP:9200`
- Manager API URL, normally `https://VM_IP:55000`
- Indexer username and password
- Manager API username and password
- Wazuh dashboard URL

Enroll one Windows or Linux agent. Do not continue until the agent is online
and producing a recent test alert.

Verify the services from the VM:

```bash
curl -k https://VM_IP:9200
curl -k https://VM_IP:55000
sudo ss -lntup | grep -E '1514|1515|1516|55000|9200'
```

## 3. Clone HomeSIEM

```bash
git clone https://github.com/Noemad33/HomeSIEM.git
cd HomeSIEM
docker version
docker compose version
```

## 4. Generate both environment files

Run this before starting Graylog or CoPilot:

```bash
bash deploy/home-lab/setup-env.sh
```

The wrapper creates:

```text
.env
deploy/graylog/.env
```

It generates internal database, JWT, Fernet, MCP, webhook, Graylog, Grafana,
and InfluxDB secrets, and derives `GRAYLOG_ELASTICSEARCH_HOSTS` (Section 5.1)
from the Wazuh Indexer values below. It prompts for Wazuh URLs and
credentials, the final Graylog admin password, the Graylog URL, the CoPilot
hostname, and the CoPilot HTTPS port -- plus Velociraptor and Talon URLs
(Sections 10.2 and 10.4), which are safe to leave at their same-VM defaults
if you haven't deployed those yet and revisit with `--force` later.

After it runs, every value needed for Wazuh, Graylog, CoPilot, Grafana, and
InfluxDB is filled in -- nothing left to hand-edit for those. The only
`.env` values still at their `REPLACE_*` placeholder afterward are optional
third-party integrations this runbook doesn't cover (Shuffle, Sublime,
VirusTotal, Resend, Portainer); leave them alone unless you're specifically
setting one of those up.

Use these answers when all services run on one VM with address `192.168.1.50`:

```text
CoPilot hostname or private IP: 192.168.1.50
CoPilot HTTPS port: 8443
Wazuh Indexer URL: https://192.168.1.50:9200
Wazuh Indexer username: admin
Wazuh Indexer password: <Wazuh indexer password>
Wazuh Manager URL: https://192.168.1.50:55000
Wazuh Manager username: wazuh-wui
Wazuh Manager password: <Wazuh Manager API password>
Graylog URL: http://192.168.1.50:9000
Graylog admin password: <password selected for Graylog>
Graylog external URL: http://192.168.1.50:9000/
OpenAI API key: <press Enter to skip if unused>
Velociraptor URL: <press Enter to accept the same-VM default if not deployed yet>
Talon URL: <press Enter to accept the same-VM default if not deployed yet>
```

The important generated or derived values are:

```dotenv
SERVER_HOST=192.168.1.50
COPILOT_URL=https://192.168.1.50:8443
WAZUH_INDEXER_URL=https://192.168.1.50:9200
OPENSEARCH_URL=https://192.168.1.50:9200
WAZUH_MANAGER_URL=https://192.168.1.50:55000
WAZUH_PROD_URL=https://192.168.1.50:55000
GRAYLOG_URL=http://192.168.1.50:9000
```

(`deploy/graylog/.env`'s `GRAYLOG_ELASTICSEARCH_HOSTS` is derived from the
Wazuh Indexer values above -- see Section 5.1. Grafana/InfluxDB credentials
and Velociraptor/Talon URLs are generated too, but have no VM-address-specific
form worth listing here.)

The wrapper stores only the SHA-256 hash of the final Graylog password in
`deploy/graylog/.env`. Keep the plaintext password in a password manager.
The wrapper does not overwrite existing files. To replace them, use:

```bash
bash deploy/home-lab/setup-env.sh --force
```

Timestamped backups are created before replacement. Never commit `.env`,
`deploy/graylog/.env`, or `data/copilot-admin-password.txt`.

On Windows PowerShell, use:

```powershell
.\deploy\home-lab\setup-env.ps1
```

## 5. Start and initialize Graylog

### 5.1 Point Graylog at the Wazuh Indexer's OpenSearch cluster

This deployment does not run Graylog's own Data Node. Graylog connects
directly to the same OpenSearch cluster as the Wazuh Indexer, because
CoPilot's automatic alert ingestion reads Graylog's `gl-events*` indices
through the Wazuh-Indexer connector -- a separate cluster would never be
visible to it. `deploy/home-lab/setup-env.sh`/`.ps1` derive
`GRAYLOG_ELASTICSEARCH_HOSTS` in `deploy/graylog/.env` from the Wazuh Indexer
URL/credentials you already entered, in the form
`scheme://user:pass@host:port`.

**This is unproven on a security-enabled OpenSearch cluster.** Neither
Graylog's nor SOCFortress's documentation specifies the minimum OpenSearch
Security privileges a Graylog user needs. Start by reusing the Wazuh Indexer
admin credentials (the default `setup-env` produces) to confirm the
connection works end to end, then create and test a narrower role before
treating this as production-ready. Expect to troubleshoot this step; if
Graylog fails to start or logs OpenSearch authentication/authorization
errors, check that the embedded user has index-create and index-write
privileges, not just read/search.

**TLS trust is the other half of this, and it always needs fixing.** The
Wazuh Indexer's certificate is self-signed, and unlike CoPilot's Python
client (`OPENSEARCH_SSL_VERIFY=false`), Graylog's Java HTTP client has no
"skip verification" setting -- it rejects an untrusted certificate outright,
which shows up as `VersionProbe ... Indexer is not available` retrying
forever with a `certificate_unknown` error in the logs. Section 5.2's start
script handles this automatically; you should not need to touch Java
truststores by hand.

### 5.2 Start Graylog

```bash
bash deploy/graylog/start.sh
```

On Windows PowerShell:

```powershell
.\deploy\graylog\start.ps1
```

This does three things: fetches the certificate the Wazuh Indexer actually
presents on first run (via a plain TCP/TLS handshake, no filesystem access to
the Wazuh host needed), builds a Java truststore containing it using the
Graylog image's own bundled `keytool` (no local Java required), then starts
Graylog with `GRAYLOG_SERVER_JAVA_OPTS` pointed at that truststore. The
fetched certificate is trusted directly (not chained to a root CA) -- the
same practical trust level as `SSL_VERIFY=false` elsewhere in this stack,
just implemented as an explicit, inspectable pin instead of a blanket skip.
The result is cached at `deploy/graylog/graylog-truststore.jks`; rerun with
`--force-trust` / `-ForceTrust` if the Wazuh Indexer's certificate ever
rotates. Do not run `docker compose up` directly against
`deploy/graylog/docker-compose.yml` on a fresh checkout -- that file won't
exist yet, and Docker will bind-mount an empty directory in its place instead
of failing loudly.

Check all Graylog services:

```bash
docker compose \
  --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml \
  ps

docker compose \
  --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml \
  logs --tail=200
```

Without a Data Node to bootstrap, there is no temporary initialization
password to capture. Graylog starts directly with the final administrator
password configured by `GRAYLOG_ROOT_PASSWORD_SHA2` in
`deploy/graylog/.env`.

Open `http://VM_IP:9000` and log in as `admin` with that password. If Graylog
does not become healthy, check the logs above for OpenSearch connection
errors before anything else -- most first-run failures here are
`GRAYLOG_ELASTICSEARCH_HOSTS` reachability or OpenSearch Security privilege
problems, not a Graylog-specific issue. If the containers restart
unexpectedly, inspect the complete first-start logs before removing volumes.

### Create the Syslog inputs

In the Graylog web interface, open **System > Inputs**.

For UDP:

1. Select **Syslog UDP** from the input type list.
2. Select **Launch new input**.
3. Set the title to `HomeSIEM Syslog UDP`.
4. Set **Bind address** to `0.0.0.0`.
5. Set **Port** to `1514`.
6. Save the input. Graylog may show it as **Setup mode**; this is expected.
7. Click **Setup** for the input to open the routing wizard.
8. Choose **Create new stream** if `UDM Firewall` does not exist.
9. Name the stream `UDM Firewall` and create it.
9. In the stream wizard, use the following choices:
   - **Description:** `UDM firewall and security events`.
   - **Remove matches from Default Stream:** checked.
   - **Create a new pipeline for this stream:** checked.
   - **Index Set:** use **Default index set** for this first test.
10. Click **Next**. On the **Launch** tab, review the stream and input, then
  click **Launch** or **Finish**.
11. On the **Diagnosis** tab, confirm Graylog reports no input, stream, or
  processing errors. If it offers a test or message check, run it.
12. Return to **System > Inputs**, click **Start** or **Resume**, and confirm its state is
  **Running**.

For TCP, repeat the process with **Syslog TCP**, title
`HomeSIEM Syslog TCP`, bind address `0.0.0.0`, and container port `1514`.
Create the TCP input only if a device needs TCP; UDP is the simplest UDM
starting point.

The container port is `1514`, but Docker maps it to these VM host ports:

```text
UDM UDP -> VM_IP:2514 -> Graylog container:1514/udp
UDM TCP -> VM_IP:2515 -> Graylog container:1514/tcp
```

Do not enter `2514` or `2515` in the Graylog input dialog. Those are host
ports used by devices outside the container.

### Verify the input and stream

Setup mode means the input has been created but its stream/routing setup is
not complete. The screenshot's **Default index set selected** warning is an
advisory, not a failure. A dedicated index set is useful for long-term
retention, but the Default index set is appropriate for this first test.
Do not troubleshoot Docker ports until the wizard is finished.
Send a test syslog message from another Linux host if available:

```bash
logger --server VM_IP --udp --port 2514 "HomeSIEM Graylog test"
```

From the Graylog VM itself, use loopback instead:

```bash
logger --server 127.0.0.1 --udp --port 2514 "HomeSIEM Graylog test"
```

If `logger` is unavailable, use netcat:

```bash
printf '<134>HomeSIEM Graylog test\n' | nc -u -w1 127.0.0.1 2514
```

In Graylog, open **Search** and search for `HomeSIEM Graylog test`. Confirm
fields such as `source`, `message`, and `gl2_source_input` are present. Open
the `UDM Firewall` stream and confirm the message appears there as well.

### Create streams

Open **Streams > Create stream** and create these additional streams after the
UDP path works:

- `UDM Firewall`
- `AdGuard DNS`
- `Network Security`

Initially route messages using stable fields visible in the received event,
such as `source`, `facility`, or `gl2_source_input`. For example, route UDM
messages by the UDM hostname or by the input ID. Do not build rules against a
field until you have confirmed that field exists in Search.

Create event definitions only after each stream contains real messages. Start
with repeated firewall blocks, administrator logins, configuration changes,
port scans, and unusual outbound activity.

### Graylog version warning

If Graylog reports that version `6.2` is outdated, the running stack was
started from an older checkout or its environment file lacks the version
setting. Pull the current repository and confirm that
`deploy/graylog/.env` contains:

```dotenv
GRAYLOG_VERSION=7.1.9
```

For an existing deployment, back up MongoDB and the Wazuh Indexer's
OpenSearch data before upgrading (Graylog itself is stateless aside from
`graylog-data`; its events live on the Wazuh Indexer cluster). Do not run
`down -v`; that deletes the Graylog and MongoDB volumes. Pull and recreate
the Graylog services:

```bash
bash deploy/graylog/start.sh --pull
```

Check the resulting images and logs:

```bash
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml images
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml logs --tail=200
```

## 6. Configure the UDM

In UniFi Network, configure remote syslog:

- Destination: `VM_IP`
- Port: `2514` for UDP or `2515` for TCP
- Categories: firewall, system, administrator, VPN, and security

Verify messages arrive in Graylog before creating broad event definitions.
Start with alerts for repeated blocks, administrative logins, configuration
changes, port scans, and unusual outbound activity.

AdGuard is a later step. Its detailed query log is not assumed to be native
syslog; use an API-to-syslog collector or exporter and forward selected events
only after storage and retention are measured.

## 7. Validate and start CoPilot

Validate the merged CoPilot Compose model:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml \
  config
```

Start CoPilot and capture its first-run administrator password:

```bash
bash deploy/home-lab/setup.sh --pull --capture-admin-password
```

The script saves the first-run password to:

```text
data/copilot-admin-password.txt
```

That file is ignored by Git and is not overwritten. If the database already
exists, no new password is emitted; use the existing account or the supported
account-recovery process.

The backend log formats the generated credential as `plain='...'`. The setup
wrapper extracts only that plaintext value rather than saving the surrounding
length and hash fields. Change the password immediately after first login and
rotate the generated credential if it was exposed in logs or terminal output.

On Windows PowerShell:

```powershell
.\deploy\home-lab\setup.ps1 -Pull -CaptureAdminPassword
```

Check the services:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml \
  ps
```

Open CoPilot at:

```text
https://VM_IP:8443
```

A self-signed certificate warning is expected during the initial test.

## 8. Configure CoPilot

After login:

1. Change the generated administrator password.
2. Enable two-factor authentication.
3. Create a separate analyst account.
4. Configure and test the Wazuh Manager connector.
5. Configure and test the Wazuh Indexer connector.
6. Configure and test the Graylog connector.
7. Create a `HOME` customer code.
8. Associate the test agent with `HOME`.

### 8.1 Configure Wazuh Manager

Open **Connectors** from the CoPilot navigation. Find **Wazuh-Manager** and
open its configuration form. Use the Wazuh Manager API values from `.env`:

```text
Connector URL: https://VM_IP:55000
Username:      WAZUH_MANAGER_USERNAME
Password:      WAZUH_MANAGER_PASSWORD
```

For example:

```text
Connector URL: https://192.168.1.50:55000
Username:      wazuh-wui
Password:      <Wazuh Manager API password>
```

Save the connector, then select its **Verify** or **Test connection** action.
A successful verification should authenticate to the Manager API and allow
CoPilot to retrieve agent inventory. If it fails, check that port `55000` is
reachable from the CoPilot container and that these are Wazuh API credentials,
not Wazuh dashboard or Indexer credentials.

### 8.2 Configure Wazuh Indexer

In **Connectors**, find **Wazuh-Indexer** and open its configuration form.
Use the Wazuh Indexer/OpenSearch credentials, not the Manager API password:

```text
Connector URL: https://VM_IP:9200
Username:      WAZUH_INDEXER_USERNAME
Password:      WAZUH_INDEXER_PASSWORD
```

For example:

```text
Connector URL: https://192.168.1.50:9200
Username:      admin
Password:      <Wazuh Indexer password>
```

Save and verify the connector. A successful verification should allow CoPilot
to query cluster health and search Wazuh event indices. If verification fails,
check port `9200`, the Indexer password, and the self-signed TLS setting. For
the initial self-signed test, keep this in the CoPilot `.env`:

```dotenv
OPENSEARCH_SSL_VERIFY=false
```

Enable verification later when the Indexer certificate is trusted by the VM.

### 8.3 Configure Graylog

In **Connectors**, find **Graylog** and open its configuration form. Use the
Graylog URL and final Graylog administrator credentials:

```text
Connector URL: http://VM_IP:9000
Username:      admin
Password:      <final Graylog administrator password>
```

For example:

```text
Connector URL: http://192.168.1.50:9000
Username:      admin
Password:      <Graylog password selected during setup>
```

Save and verify the connector. A successful verification should allow CoPilot
to read Graylog health and management data. The Graylog API/header secret is
separate from the connector password: keep `GRAYLOG_API_HEADER_VALUE` in
`.env` for CoPilot webhook and alert-injection routes. It is not entered as
the Graylog login password.

After verification, open CoPilot's Graylog management view and confirm that
the `UDM Firewall` stream and running Syslog input are visible. Confirm that
the Graylog test event can be searched before creating a case.

Keep Graylog and CoPilot on a private network. Do not expose connector
credentials or `.env` to the browser, Git, or support logs.

### 8.4 Enable Wazuh alert provisioning

Incident Management stays empty until this step, even if Wazuh detections
are firing correctly -- see Section 5.1 and the architecture note above for
why. In CoPilot, open **Log Management > Graylog Management**, find **Alert
Provisioning**, and enable the pre-built **`WAZUH SYSLOG LEVEL ALERT`** item.

This creates a Graylog Event Definition with the query
`syslog_level:ALERT AND syslog_type:wazuh AND NOT (rule_group1:office365 OR
rule_group1:vulnerability-detector)`. Two prerequisites must already be true
for it to match anything:

- The `SOCFORTRESS_WAZUH_CONTENT_PACK` has been provisioned into Graylog
  (**Log Management > Graylog Management**, or the content-pack provisioning
  API). It creates the pipeline rules that set `syslog_level`/`syslog_type`,
  and a `WAZUH EVENTS FLUENT BIT - TCP` input on port `5555` -- a different
  input than the UDM Syslog UDP/TCP input from Section 5. That port is not
  yet mapped in `deploy/graylog/docker-compose.yml`; add a
  `"${GRAYLOG_WAZUH_FLUENTBIT_PORT:-5555}:5555/tcp"` entry if you use this
  path, and configure Wazuh's own Fluent Bit output to forward to it.
- Wazuh agents need a `CUSTOMER_CODE` resolvable from
  `${source.agent_labels_customer}` -- associate agents with a customer code
  (Section 4) before expecting this alert to populate correctly.

You do **not** need to add a Graylog **Alerts > Notifications** entry for
this alert. CoPilot polls `gl-events*` on a schedule instead of Graylog
pushing to it via webhook; a Notification is only required for the separate
threshold/aggregation alert pattern (custom alerts you build yourself, not
this pre-built one). Adding one here is optional, for your own visibility
(e.g. an email ping), not required for the alert to reach CoPilot.

## 9. Test the monitoring loop

1. Confirm the Wazuh agent is online.
2. Confirm UDM events are visible in Graylog.
3. Trigger a harmless Wazuh test detection.
4. Confirm the alert appears in Wazuh.
5. Confirm the alert appears in CoPilot.
6. Open the alert and create a case.
7. Add notes and evidence.
8. Confirm the audit trail.

Do not enable automated isolation, quarantine, process termination, or account
actions until this loop is reliable.

## 10. Add optional services

Add these only after Wazuh, Graylog, and CoPilot are stable.

### 10.1 Grafana + InfluxDB (done)

Data directories:

```
mkdir -p data/grafana-data data/influxdb-data data/influxdb-config
sudo chown -R 472:472 data/grafana-data      # grafana image runs as UID 472
sudo chown -R 1000:1000 data/influxdb-data data/influxdb-config
```

Add to `.env` (see also `.env.example`):

```
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<set a real password>
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=<8+ chars>
INFLUXDB_ORG=socfortress
INFLUXDB_BUCKET=copilot
INFLUXDB_ADMIN_TOKEN=<long random token>
```

`grafana` and `influxdb` services are defined in `docker-compose.yml`
alongside the CoPilot services and join the same default network, so
Grafana can reach `copilot-mcp` and any other container by name.

Grafana needs the OpenSearch plugin, since it isn't bundled:

```yaml
    grafana:
        image: grafana/grafana:latest
        environment:
            - GF_PLUGINS_PREINSTALL_SYNC=grafana-opensearch-datasource
            - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
            - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
```

`GF_INSTALL_PLUGINS` is deprecated in favor of `GF_PLUGINS_PREINSTALL_SYNC`.
Double-check the plugin ID is exactly `grafana-opensearch-datasource` --
a typo here fails silently with a 404 from the plugin catalog and the whole
container exits.

**Configuring the OpenSearch data source in Grafana** (Connections > Data
sources > Add data source > OpenSearch):

- URL: same value as `OPENSEARCH_URL` / `WAZUH_INDEXER_URL` in `.env`
- Auth: Basic auth, using the Wazuh **indexer** credentials (not the Wazuh
  Manager API credentials -- these are two separate services)
- Index name: `wazuh-alerts-4.x-*`
- **Pattern: "No pattern"** -- if a date-rotation pattern (Daily, etc.) is
  selected, Grafana treats the Index name field as a date-format string and
  substitutes any recognized token letters in it (`wazuh-alerts-4.x-*`
  contains several: `a`, `h`, `l`, `s`, `w`, `x`), producing a garbled index
  name and a `no handler found for uri [...]/_field_caps` error. The literal
  wildcard with no pattern is simpler and works fine for this cluster size.
- Time field: `@timestamp`

Verified indices on the Wazuh indexer (`_cat/indices?v`): only
`wazuh-*` and OpenSearch system indices are present -- no Graylog data on
this cluster. Confirm Graylog's actual backend via its **System > Indices**
page before adding a second OpenSearch data source for it.

**InfluxDB data source:** Query Language `Flux`, URL `http://influxdb:8086`,
Organization/Token/Bucket from the `.env` values above.

**Status of InfluxDB:** connected in Grafana, but nothing currently writes
to it. It's a time-series metrics store, not a log store -- Wazuh agent
logs, Unifi syslog, and AdGuard logs all belong in OpenSearch (via the
Wazuh indexer and/or Graylog), not InfluxDB. InfluxDB only becomes useful
here if a feeder (Telegraf, or a scheduled script computing rates from
OpenSearch) is added later for derived metrics/trend graphs. Not required
for the current data sources.

### 10.2 Velociraptor (planned, not yet deployed)

Velociraptor manages its own certs/datastore on first run and ships its own
Compose file, so it runs as a separate project rather than a service block
in this repo's `docker-compose.yml`:

```
mkdir -p ~/velociraptor && cd ~/velociraptor
curl -o compose.yaml https://raw.githubusercontent.com/Velocidex/velociraptor/master/Docker/compose.yaml
curl -o .env https://raw.githubusercontent.com/Velocidex/velociraptor/master/Docker/.env
# edit .env: VELOCIRAPTOR_HOSTNAME, VELOCIRAPTOR_INITIAL_ADMIN_PASSWORD
docker compose up -d
```

To connect it to CoPilot: `copilot-mcp` in this repo's `docker-compose.yml`
already mounts `./data/copilot-mcp/api.config.yaml` as its Velociraptor
config (`VELOCIRAPTOR_API_KEY` env var). That file is a Velociraptor **API
client config**, generated after exposing the API port (default 8001,
bound to localhost only until `server.config.yaml`'s `API:` block is set to
`bind_address: 0.0.0.0`) and running:

```
velociraptor --config server.config.yaml config api_client_config \
  --name mcp-service-account > api.config.yaml
cp api.config.yaml <this repo>/data/copilot-mcp/api.config.yaml
docker compose restart copilot-mcp
```

The home-lab `setup-env` wrapper sets `MCP_VELOCIRAPTOR_SERVER_ENABLED=false`
in `.env` by default, since there is nothing to connect to until the steps
above are done. Once a real `api.config.yaml` is in place, set it to `true`
in `.env` and restart `copilot-mcp` (the flag above only applies to that
service) to pick up the change.

`setup-env` also writes two more Velociraptor values you should revisit once
the server is actually running, since it only has a guessed default the
first time it runs (before Velociraptor exists to confirm against):

- `VELOCIRAPTOR_URL` -- defaults to `https://<copilot-host>:8000`, assuming
  Velociraptor runs on the same VM as CoPilot. Update it if Velociraptor
  ends up on a different host or port. Like the Wazuh/Graylog values in
  Section 8, the backend does not read this env var directly for the
  connector itself -- it is a staging value you copy into the **Connector
  URL** field when configuring Velociraptor in CoPilot's Connectors view
  below.
- `VELOCIRAPTOR_API_HEADER_VALUE` -- an auto-generated webhook secret CoPilot
  expects on **inbound** requests from Velociraptor (e.g. server-side event
  hooks calling back into CoPilot). This has no effect until you also
  configure Velociraptor's own server-side webhook/notification config to
  send this same value as a header -- that configuration lives on the
  Velociraptor server, not in this repo.

Then configure the Velociraptor connector in CoPilot's **Connectors** view
and verify it. A successful verification should list Velociraptor artifacts;
if it fails, confirm the API port (default `8001`) is reachable from the
`copilot-mcp` container and that `api.config.yaml` was generated for the
same Velociraptor server referenced by `MCP_VELOCIRAPTOR_URL`.

### 10.3 Shuffle (planned, not yet deployed)

Shuffle bundles its own OpenSearch, backend, frontend, and Orborus worker
containers, so it also runs as its own project:

```
git clone https://github.com/Shuffle/Shuffle ~/shuffle
cd ~/shuffle
sudo chown -R 1000:1000 shuffle-database
docker compose up -d
```

GUI defaults to port 3443. Wire it in via a Graylog alert webhook or a
Wazuh active-response script pointed at a Shuffle workflow trigger.

Give every additional stack a dedicated host-port plan before starting it.
Docker host ports are global across all Compose projects on the VM.

### 10.4 Talon (planned, not yet deployed)

Talon is the "agentic SOC analyst" piece: a separate service
([taylorwalton/talon](https://github.com/taylorwalton/talon)) that
auto-investigates every OPEN CoPilot alert end to end (SIEM raw event -> IOC
extraction -> threat-intel enrichment -> MITRE correlation -> a structured
report with severity and recommended actions written back into CoPilot), and
also powers the in-app analyst chat. It calls CoPilot's Wazuh/OpenSearch,
MySQL, Wazuh Manager, Velociraptor, and Shuffle connectors through its own
set of MCP servers, so deploy it last, after those are proven working.

**This is the heaviest deployment in this runbook** -- Talon's own guide is
18 steps: Node.js 20+, an OneCLI credential vault, a per-group mount
allowlist, a systemd service, and a Claude Code OAuth token (ongoing
Anthropic API usage/cost, not a one-time setup). It is not vendored into
this repo; follow Talon's own README as the source of truth:
<https://github.com/taylorwalton/talon#deployment-guide>. What follows here
is only the HomeSIEM-specific wiring that guide's generic placeholders don't
know about.

**Values to use when Talon's guide asks for connector credentials**
(steps 7, 9, 10, 11 of its Deployment Guide):

| Talon's guide asks for... | Use this HomeSIEM value |
| --- | --- |
| `siem/.env` `OPENSEARCH_HOSTS/USERNAME/PASSWORD` (step 7) | `WAZUH_INDEXER_URL`/`WAZUH_INDEXER_USERNAME`/`WAZUH_INDEXER_PASSWORD` from `.env` |
| `mysql/.env` `MYSQL_HOST/PORT/USER/PASS/DB` (step 8) | `copilot-mysql` (container name, only reachable if Talon runs in the same Docker network -- see networking note below), `MYSQL_USER`, `MYSQL_PASSWORD` from `.env`, database `copilot` |
| `copilot-mcp/.env` `COPILOT_URL/USERNAME/PASSWORD` (step 9) | `http://127.0.0.1:5000` if Talon runs on the same VM as CoPilot (backend port 5000 is bound to loopback by default -- see `BACKEND_BIND_IP` in `.env` -- and Docker's loopback-bound publish is reachable from any host process, including Talon's systemd service); `http://<VM_IP>:5000` only if Talon runs on a different host, after setting `BACKEND_BIND_IP` to that LAN IP and restarting `copilot-backend`. Either way, use a **dedicated non-admin CoPilot analyst account** created for Talon -- do not use the admin login here |
| `wazuh-mcp/.env` `WAZUH_PROD_URL/USERNAME/PASSWORD` (step 10) | `WAZUH_MANAGER_URL`/`WAZUH_MANAGER_USERNAME`/`WAZUH_MANAGER_PASSWORD` from `.env` |
| `velociraptor-mcp` `api.config.yaml` (step 11) | The same client config generated in Section 10.2 -- generate a second `--name talon` client config, do not reuse the `copilot-mcp` one |

For the Wazuh/Velociraptor rows above -- genuinely separate services, not
CoPilot's own Docker-published ports -- use the VM's LAN IP, matching the
rest of this runbook, not `host.docker.internal` (Talon's guide defaults to
this for same-host deployments, but whether it resolves depends on Talon's
own container networking, which this repo does not control) and not
`localhost`.

**Networking:** Talon runs as its own systemd service on the VM host
(outside this repo's `docker-compose.yml`), listening on `3100`. Step 8's
MySQL connection is the one exception to "use the LAN IP" above -- it only
works as `copilot-mysql` if Talon's containers join this repo's Docker
network; otherwise point it at the VM's LAN IP and CoPilot's published MySQL
port too. `deploy/home-lab/docker-compose.override.yml` removes MySQL's host
port publishing by default (`deploy/home-lab/README.md` Section 3) -- restore
it or add Talon to the `copilot` Docker network if you hit this.

**Wiring Talon back into CoPilot** (after Talon is verified with the `curl`
commands in its guide's step 18):

1. In `.env`, `TALON_URL` and `TALON_API_KEY` were written by `setup-env`
   with a guessed default (`http://<copilot-host>:3100` and a random
   secret). Confirm `TALON_URL` is correct now that Talon is actually
   running.
2. Copy that same `TALON_API_KEY` value into Talon's own `.env` as
   `HTTP_API_KEY` -- **the two projects name this identical shared secret
   differently.** A mismatch here is the most likely first-connection
   failure.
3. In CoPilot's **Connectors** view, find **Talon** and enter `TALON_URL` as
   the Connector URL and `TALON_API_KEY` as the API key, then verify. A
   successful verification calls Talon's unauthenticated `/health` endpoint.
4. Trigger a test investigation on a real alert (or via the chat UI) and
   confirm a report appears against that alert in CoPilot before enabling
   Talon's 15-minute scheduled sweep for every OPEN alert.

## Operations

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml \
  logs --tail=200
```

Do not run `docker compose down -v` unless you intend to destroy persistent
data. Back up `.env`, `data/`, the `mysql-data` volume, Wazuh data and keys,
Graylog volumes, and any Velociraptor API configuration.

If a port is unavailable:

```bash
sudo ss -lntup | grep -E '443|8443|9000|9200|1514|1515|1516|2514|2515|55000'
```

If the backend reports `connector_url cannot be null`, ensure optional
connector URLs exist in `.env`. The backend seeds connector rows at startup
and requires non-null URLs even for disabled integrations.

## Repository safety

Never commit:

```text
.env
deploy/graylog/.env
data/copilot-admin-password.txt
Wazuh private keys
Velociraptor private API configuration
Shuffle credentials
```

Before committing:

```bash
git diff --cached --name-only
git diff --cached --check
```
