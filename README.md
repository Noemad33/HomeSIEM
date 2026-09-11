# HomeSIEM

HomeSIEM is a home-lab security monitoring and response deployment built
around Wazuh, Graylog, and SOCFortress CoPilot.

- Wazuh collects endpoint telemetry and stores security events.
- Graylog receives UDM and network-device syslog.
- CoPilot provides investigation, enrichment, cases, dashboards, and response.

This runbook is intentionally linear. Follow it from top to bottom on the
Debian 12 VM.

## Architecture

```text
Wazuh agents ----------------------> Wazuh Manager + Indexer
                                          |
                                          +--> CoPilot

UDM / network devices --> Graylog --> CoPilot

CoPilot --> optional Velociraptor, Shuffle, enrichment, and dashboards
```

Wazuh, Graylog, and CoPilot are separate Compose projects on the same VM.
This avoids coupling their certificate, storage, and upgrade lifecycles.

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
6. Save and launch the input.

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

### Verify the input

After saving an input, confirm it is **Running** in **System > Inputs**. Send a
test syslog message from another Linux host if available:

```bash
logger --server VM_IP --udp --port 2514 "HomeSIEM Graylog test"
```

In Graylog, open **Search** and select the input or search for
`HomeSIEM Graylog test`. Confirm fields such as `source`, `message`, and
`gl2_source_input` are present before creating streams.

### Create streams

Open **Streams > Create stream** and create these streams:

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
7. Use the Graylog credentials and URL from `.env`.
8. Create a `HOME` customer code.
9. Associate the test agent with `HOME`.

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

Add these only after Wazuh, Graylog, and CoPilot are stable:

- Velociraptor for read-only endpoint collection, then controlled response
- Shuffle for notifications and approval-gated automation
- VirusTotal for enrichment
- Grafana and InfluxDB for infrastructure dashboards

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
