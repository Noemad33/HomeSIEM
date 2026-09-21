# HomeSIEM

HomeSIEM is a home-lab security monitoring and response deployment built
around Wazuh, Graylog, and SOCFortress CoPilot.

- Wazuh collects endpoint telemetry and stores security events.
- Graylog receives UDM and network-device syslog.
- CoPilot provides investigation, enrichment, cases, dashboards, and response.

This runbook is intentionally linear. Follow it from top to bottom on the
Debian 12 VM.

## Architecture

\`\`\`
Wazuh agents ----------------------> Wazuh Manager + Indexer (OpenSearch)
                                          |
                                          +--> CoPilot (copilot-mcp)
                                          +--> Grafana (OpenSearch data source)

UDM / network devices --> Graylog --> CoPilot
                              |
                              +--> its own OpenSearch/Elasticsearch backend
                                   (confirm via Graylog System > Indices;
                                    not currently the same cluster as the
                                    Wazuh Indexer above -- verified via
                                    _cat/indices)

InfluxDB --> Grafana (time-series store; deployed but not yet fed by
             anything in this stack -- see Section 10.1)

CoPilot --> optional Velociraptor (DFIR), Shuffle (SOAR), VirusTotal (enrichment)
\`\`\`

Wazuh, Graylog, and CoPilot are separate Compose projects on the same VM.
This avoids coupling their certificate, storage, and upgrade lifecycles.

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
| Graylog | `9000` | Web UI/API |
| Graylog | `2514/udp` | UDM syslog |
| Graylog | `2515/tcp` | UDM syslog |
| CoPilot | `8443` | HTTPS frontend |
| Grafana      | `3000`  | Dashboards (OpenSearch + InfluxDB)                 |
| InfluxDB     | `8086`  | Time-series API (deployed, currently unused)       |
| Velociraptor | `8000`  | Agent/frontend (not yet deployed)                  |
| Velociraptor | `8889`  | Web GUI (not yet deployed)                         |
| Velociraptor | `8001`  | API, consumed by copilot-mcp (not yet deployed)    |
| Shuffle      | `3443`  | Web UI (not yet deployed)                          |

This repository pins Graylog and Graylog Data Node to `7.1.9`, the current
stable release used by this deployment. Keep both Graylog images on the same
version. Graylog 7.1 requires MongoDB 7.x, which is why this stack uses
`mongo:7.0`.

The Data Node OpenSearch heap defaults to `8g` in
`deploy/graylog/.env`. Graylog may display a warning recommending half of the
VM's RAM, but that generic recommendation is not a target for this home stack.
Leave headroom for Wazuh, Graylog, MongoDB, Docker, and Debian. Increase the
heap to `16g` only after monitoring actual memory pressure and ingest volume;
do not jump directly to `62g`.

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

It generates internal database, JWT, Fernet, MCP, webhook, and Graylog secrets.
It prompts for Wazuh URLs and credentials, the final Graylog admin password,
the Graylog URL, the CoPilot hostname, and the CoPilot HTTPS port.

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
```

The important generated values are:

```dotenv
SERVER_HOST=192.168.1.50
COPILOT_URL=https://192.168.1.50:8443
WAZUH_INDEXER_URL=https://192.168.1.50:9200
OPENSEARCH_URL=https://192.168.1.50:9200
WAZUH_MANAGER_URL=https://192.168.1.50:55000
WAZUH_PROD_URL=https://192.168.1.50:55000
GRAYLOG_URL=http://192.168.1.50:9000
```

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

Start Graylog before CoPilot:

```bash
docker compose \
  --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml \
  up -d
```

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

On the first Graylog startup, the Graylog/Data Node bootstrap process may emit
a temporary initialization password in the logs. Capture it before the
bootstrap restart because it is needed to initialize certificates and the
Data Node:

```bash
docker compose \
  --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml \
  logs -f graylog graylog-datanode
```

Search the output for the initial password/bootstrap message and store it in
your password manager. Do not commit it or paste it into support logs. After
the Data Node and certificate bootstrap completes, Graylog restarts and uses
the final password configured by `GRAYLOG_ROOT_PASSWORD_SHA2` in
`deploy/graylog/.env`.

Open `http://VM_IP:9000` and log in as `admin` with that final password.
Complete Data Node initialization in the Graylog UI before continuing. If the
containers restart before you capture the bootstrap password, inspect the
complete first-start logs before removing volumes.

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

For an existing deployment, back up Graylog and MongoDB before upgrading. Do
not run `down -v`; that deletes the Data Node, Graylog, and MongoDB volumes.
Pull and recreate the Graylog services:

```bash
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml pull
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml up -d
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

\`\`\`
mkdir -p data/grafana-data data/influxdb-data data/influxdb-config
sudo chown -R 472:472 data/grafana-data      # grafana image runs as UID 472
sudo chown -R 1000:1000 data/influxdb-data data/influxdb-config
\`\`\`

Add to `.env` (see also `.env.example`):

\`\`\`
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<set a real password>
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=<8+ chars>
INFLUXDB_ORG=socfortress
INFLUXDB_BUCKET=copilot
INFLUXDB_ADMIN_TOKEN=<long random token>
\`\`\`

`grafana` and `influxdb` services are defined in `docker-compose.yml`
alongside the CoPilot services and join the same default network, so
Grafana can reach `copilot-mcp` and any other container by name.

Grafana needs the OpenSearch plugin, since it isn't bundled:

\`\`\`yaml
    grafana:
        image: grafana/grafana:latest
        environment:
            - GF_PLUGINS_PREINSTALL_SYNC=grafana-opensearch-datasource
            - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
            - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
\`\`\`

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

\`\`\`
mkdir -p ~/velociraptor && cd ~/velociraptor
curl -o compose.yaml https://raw.githubusercontent.com/Velocidex/velociraptor/master/Docker/compose.yaml
curl -o .env https://raw.githubusercontent.com/Velocidex/velociraptor/master/Docker/.env
# edit .env: VELOCIRAPTOR_HOSTNAME, VELOCIRAPTOR_INITIAL_ADMIN_PASSWORD
docker compose up -d
\`\`\`

To connect it to CoPilot: `copilot-mcp` in this repo's `docker-compose.yml`
already mounts `./data/copilot-mcp/api.config.yaml` as its Velociraptor
config (`VELOCIRAPTOR_API_KEY` env var). That file is a Velociraptor **API
client config**, generated after exposing the API port (default 8001,
bound to localhost only until `server.config.yaml`'s `API:` block is set to
`bind_address: 0.0.0.0`) and running:

\`\`\`
velociraptor --config server.config.yaml config api_client_config \
  --name mcp-service-account > api.config.yaml
cp api.config.yaml <this repo>/data/copilot-mcp/api.config.yaml
docker compose restart copilot-mcp
\`\`\`

### 10.3 Shuffle (planned, not yet deployed)

Shuffle bundles its own OpenSearch, backend, frontend, and Orborus worker
containers, so it also runs as its own project:

\`\`\`
git clone https://github.com/Shuffle/Shuffle ~/shuffle
cd ~/shuffle
sudo chown -R 1000:1000 shuffle-database
docker compose up -d
\`\`\`

GUI defaults to port 3443. Wire it in via a Graylog alert webhook or a
Wazuh active-response script pointed at a Shuffle workflow trigger.

Give every additional stack a dedicated host-port plan before starting it.
Docker host ports are global across all Compose projects on the VM.
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
