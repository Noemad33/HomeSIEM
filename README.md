# HomeSIEM

HomeSIEM is a home-lab security monitoring and response deployment built
around Wazuh and SOCFortress CoPilot. Wazuh collects and stores endpoint and
network telemetry. CoPilot provides investigation, enrichment, case
management, dashboards, and response workflows.

This repository is intended to be cloned to a server, configured with a local
`.env` file, and deployed with Docker Compose.

## Architecture

HomeSIEM uses two Compose projects:

```text
Home endpoints and network devices
        |
        +--> Wazuh agents and syslog
        |         |
        |         +--> Wazuh Manager API
        |         +--> Wazuh Indexer / OpenSearch
        |
        +--> Graylog syslog collector

Graylog --> CoPilot alert ingestion

CoPilot --> Wazuh Manager and Indexer
        --> optional Velociraptor collection and response
        --> optional Shuffle automation and notifications
        --> optional VirusTotal enrichment
        --> optional Grafana and InfluxDB dashboards
```

Wazuh is deployed using its official Docker project. CoPilot is deployed from
this repository. Keeping Wazuh separate preserves its certificate-generation,
indexer bootstrap, upgrade, and recovery procedures.

## Deployment status

The supported first deployment is:

1. Wazuh single-node deployment
2. One Windows or Linux Wazuh agent
3. CoPilot connected to Wazuh
4. One harmless alert and case workflow
5. Optional response and automation tools

Do not enable automated containment until collection and alert handling have
been tested on a disposable endpoint.

## Quick start order

Run the deployment in this order:

1. Deploy Wazuh and enroll one test agent.
2. Clone this repository.
3. Run `bash deploy/home-lab/setup-env.sh` to create both `.env` files and
  generate their secrets.
4. Start and initialize Graylog, then create its syslog inputs and streams.
5. Configure the UDM to send syslog to Graylog and verify that logs arrive.
6. Start CoPilot with
  `bash deploy/home-lab/setup.sh --pull --capture-admin-password`.
7. Configure and test the Wazuh and Graylog connectors in CoPilot.

The detailed sections below follow these same tasks. The environment wrapper
must run before Graylog or CoPilot because it creates both
`deploy/graylog/.env` and the main `.env`.

## Requirements

The initial server should have:

- Linux VM or dedicated Linux server
- Docker Engine and the Docker Compose plugin
- 4 vCPU
- 16 GB RAM
- 250 GB SSD minimum
- Stable LAN address
- Private access through a VPN or authenticated reverse proxy

Increase storage for long endpoint retention, file collection, and network
telemetry. Do not expose Wazuh, OpenSearch, MySQL, MinIO, Velociraptor, or
Shuffle administration ports to the public internet.

## 1. Deploy Wazuh

Install the official Wazuh Docker deployment on the target server. Use the
single-node profile and follow Wazuh's certificate-generation instructions.
Pin the Wazuh version used for the test deployment.

Record these values after Wazuh starts:

- Wazuh Manager API URL, normally HTTPS port `55000`
- Wazuh Indexer URL, normally HTTPS port `9200`
- Wazuh Manager API username and password
- Wazuh Indexer username and password
- Wazuh dashboard URL

Enroll one Windows or Linux endpoint and verify that it is online. Confirm
that the endpoint generates at least one recent alert before configuring
CoPilot.

For network devices, send syslog to Graylog. Graylog provides the input,
pipeline, stream, and event-definition layer for network telemetry. Wazuh
remains the endpoint SIEM and OpenSearch-backed event store.

## 2. Deploy Graylog

Complete the repository cloning and `.env` setup steps before starting this
section. The environment wrapper creates the Graylog environment file used
below.

Graylog runs as a separate Compose project because it has its own MongoDB,
Data Node, storage, initialization, and upgrade lifecycle.

From the repository root:

The `setup-env.sh` command in step 4 already created
`deploy/graylog/.env`. Do not copy the Graylog template again.

Edit `deploy/graylog/.env` and set both secrets. Choose and record the Graylog
administrator password before starting the containers. Graylog does not
generate a recoverable first-run password in this deployment; the password is
provided by you as a SHA-256 hash.

Generate the password hash:

```bash
printf '%s' 'CHOOSE_A_GRAYLOG_ADMIN_PASSWORD' | sha256sum
```

Set `GRAYLOG_HTTP_EXTERNAL_URI` to the private URL users will open. Start the
stack:

```bash
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml up -d
```

Check the startup logs for readiness and errors:

```bash
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml logs --tail=200
```

Open the Graylog URL and log in as `admin` using the password whose SHA-256
hash was placed in `GRAYLOG_ROOT_PASSWORD_SHA2`. Complete the Graylog Data Node
initialization in the web interface before creating inputs. Save the password
in your password manager; do not expect `docker logs` to print it.

### Create Graylog inputs

In Graylog, create a **Syslog UDP** input on port `1514` and, if needed, a
second **Syslog TCP** input on port `1514`. The container listens internally
on `1514`; the default host mappings are UDP `2514` and TCP `2515` because
Wazuh commonly owns host ports `1514-1516`. Create streams for at least
`udm`, `adguard`, and `network-security`.

Add event definitions for repeated blocks, administrative logins, firewall
configuration changes, port scans, and unusual outbound activity. Start with
alerts only; do not automate containment yet.

### Configure the UDM

In UniFi Network, configure remote syslog to the HomeSIEM server's private IP:

- Host: HomeSIEM server address
- Port: `2514` for UDP, or `2515` for TCP
- Protocol: UDP initially, TCP if supported and preferred
- Categories: firewall, system, administrator, VPN, and security events

Confirm messages arrive in Graylog before building event definitions.

### AdGuard Home

AdGuard Home is not assumed to emit its full DNS query log as native syslog.
Use Graylog for AdGuard events after adding a small API-to-syslog collector or
exporter. Start with AdGuard metrics in Grafana, then forward selected events
such as blocked malicious domains, repeated DNS failures, and unusual clients
into a Graylog stream. Do not forward every DNS query until storage and
retention have been measured.

## 3. Clone HomeSIEM

On the target server:

```bash
git clone https://github.com/Noemad33/HomeSIEM.git
cd HomeSIEM
docker version
docker compose version
```

## 4. Create `.env`

Create both local environment files with the guided wrapper. They are ignored
by Git and must never be committed:

```bash
bash deploy/home-lab/setup-env.sh
```

The wrapper copies `.env.example` and `deploy/graylog/.env.example`, generates
CoPilot, database, MCP, and webhook secrets, and prompts for the Wazuh and
Graylog connection values. It asks for the Graylog administrator password but
writes only its SHA-256 hash to `deploy/graylog/.env`; keep the plaintext
password in your password manager. It does not overwrite existing files.

To intentionally replace existing environment files, use `--force`. The
wrapper creates timestamped backups before replacing them:

```bash
bash deploy/home-lab/setup-env.sh --force
```

On Windows PowerShell, use:

```powershell
.\deploy\home-lab\setup-env.ps1
```

Review the generated `.env` and `deploy/graylog/.env` before starting any
containers. Optional API keys such as OpenAI are prompted for and may be left
blank.

### URL answers on a single Debian VM

When Wazuh, Graylog, and CoPilot run in separate Compose projects on the same
Debian 12 VM, answer the wrapper's URL prompts with the VM's private LAN IP or
DNS hostname. Do not use `localhost`, `127.0.0.1`, or another Compose
project's container name.

For example, if the VM is `192.168.1.50`, use:

```text
CoPilot hostname or private IP: 192.168.1.50
Wazuh Indexer URL: https://192.168.1.50:9200
Wazuh Indexer username: admin
Wazuh Indexer password: <Wazuh indexer password>
Wazuh Manager URL: https://192.168.1.50:55000
Wazuh Manager username: wazuh-wui
Wazuh Manager password: <Wazuh Manager API password>
Graylog URL: http://192.168.1.50:9000
Graylog admin password: <Graylog password chosen during setup>
Graylog external URL: http://192.168.1.50:9000/
```

The resulting cross-service values should be equivalent to:

```dotenv
SERVER_HOST=192.168.1.50
COPILOT_URL=https://192.168.1.50
WAZUH_INDEXER_URL=https://192.168.1.50:9200
OPENSEARCH_URL=https://192.168.1.50:9200
WAZUH_MANAGER_URL=https://192.168.1.50:55000
WAZUH_PROD_URL=https://192.168.1.50:55000
GRAYLOG_URL=http://192.168.1.50:9000
GRAYLOG_NETWORK_URL=http://192.168.1.50:9000
```

The VM firewall must allow CoPilot-to-Wazuh traffic on `9200` and `55000`,
CoPilot-to-Graylog traffic on `9000`, and UDM-to-Graylog syslog on `2514/udp`
or `2515/tcp`. Keep these ports restricted to the home LAN or VPN.

For an initial Wazuh test using its default self-signed certificates, leave
`OPENSEARCH_SSL_VERIFY=false` and `WAZUH_PROD_SSL_VERIFY=false`. Enable both
after installing certificates trusted by the CoPilot VM.

Before running the wrapper, test reachability from the VM:

```bash
curl -k https://192.168.1.50:9200
curl -k https://192.168.1.50:55000
curl http://192.168.1.50:9000
sudo ss -lntup | grep -E '1514|1515|1516|2514|2515|55000|9000|9200'
```

### Application secrets

If you prefer to populate the files manually, generate unique values for every
deployment:

```bash
openssl rand -base64 32
openssl rand -hex 32
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Use the first value for `JWT_SECRET`, the second for MCP and webhook tokens,
and the Fernet value for `TOTP_ENCRYPTION_KEY`. Keep the TOTP key unchanged
after users enroll in two-factor authentication.

Generate database and MinIO passwords with:

```bash
openssl rand -hex 24
```

Set unique values for:

- `JWT_SECRET`
- `SSO_STATE_SECRET`
- `TOTP_ENCRYPTION_KEY`
- `MYSQL_ROOT_PASSWORD`
- `MYSQL_PASSWORD`
- `MINIO_ROOT_PASSWORD`
- `GRAYLOG_API_HEADER_VALUE`
- `VELOCIRAPTOR_API_HEADER_VALUE`
- `GRAFANA_API_HEADER_VALUE`
- MCP authentication tokens

### Wazuh values

Set the CoPilot Wazuh and OpenSearch values to the real Wazuh server:

```dotenv
WAZUH_INDEXER_URL=https://wazuh-server.example.lan:9200
WAZUH_INDEXER_USERNAME=admin
WAZUH_INDEXER_PASSWORD=REPLACE_WITH_WAZUH_INDEXER_PASSWORD

OPENSEARCH_URL=https://wazuh-server.example.lan:9200
OPENSEARCH_USERNAME=admin
OPENSEARCH_PASSWORD=REPLACE_WITH_WAZUH_INDEXER_PASSWORD

WAZUH_MANAGER_URL=https://wazuh-server.example.lan:55000
WAZUH_MANAGER_USERNAME=wazuh-wui
WAZUH_MANAGER_PASSWORD=REPLACE_WITH_WAZUH_MANAGER_PASSWORD

WAZUH_PROD_URL=https://wazuh-server.example.lan:55000
WAZUH_PROD_USERNAME=wazuh-wui
WAZUH_PROD_PASSWORD=REPLACE_WITH_WAZUH_MANAGER_PASSWORD
```

Use `OPENSEARCH_SSL_VERIFY=true` and `WAZUH_PROD_SSL_VERIFY=true` when the
Wazuh certificates are signed by a trusted internal CA. Keep verification off
only for an initial self-signed test and only across a private network.

### Optional integrations

Leave optional integrations disabled or pointed at placeholders until the
corresponding service exists. Never use `admin`, `dummy`, or reusable example
tokens as production credentials.

For optional API keys, create them in the relevant service and set them only
in the local `.env`:

- `OPENAI_API_KEY`
- `VIRUSTOTAL_API_KEY`
- `SHUFFLER_API_KEY`
- `INFLUXDB_API_KEY`
- `TALON_API_KEY`
- `RESEND_API_KEY`

## 5. Start CoPilot

From the repository root, validate the merged Compose model:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml config
```

Pull images and start CoPilot:

```bash
bash deploy/home-lab/setup.sh --pull --capture-admin-password
```

The script validates Compose, starts the services, watches the backend logs
for the first-run administrator password, and saves it to:

```text
data/copilot-admin-password.txt
```

That file is ignored by Git and is not overwritten. Read it once with:

```bash
cat data/copilot-admin-password.txt
```

On Windows PowerShell, run:

```powershell
.\deploy\home-lab\setup.ps1 -Pull -CaptureAdminPassword
```

If the CoPilot database already exists, CoPilot will not emit a new password.
The setup script will report that condition and will not delete volumes or
reset the database. Use the existing administrator account or follow the
account-recovery procedure for the installed CoPilot release.

## 6. First login and connector setup

Open the HTTPS address for the server. For an initial local test, use:

```text
https://SERVER_IP
```

A certificate warning is expected when the frontend generates a self-signed
certificate.

After the first login:

1. Change the generated administrator password.
2. Enable two-factor authentication.
3. Create a separate analyst account.
4. Configure the Wazuh Manager connector.
5. Configure the Wazuh Indexer connector.
6. Configure the Graylog connector with the Graylog URL and credentials.
7. Set the Graylog webhook header to the same value as `GRAYLOG_API_HEADER_VALUE`.
8. Test all three connectors.
9. Create a customer code such as `HOME`.
10. Associate the test agent with that customer.

For the Graylog connector, use the private Graylog URL from
`GRAYLOG_URL`, the Graylog administrator credentials, and the API/header value
configured for CoPilot. Keep Graylog and CoPilot on a private network.

## 7. Test the complete monitoring loop

Use a controlled, harmless test:

1. Confirm the Wazuh agent is online.
2. Generate a benign test event.
3. Confirm the event appears in Wazuh.
4. Confirm the alert appears in CoPilot.
5. Open the alert and create a case.
6. Add investigation notes and evidence.
7. Confirm the audit trail.

Back up CoPilot and Wazuh before adding response actions.

## 8. Add optional services in stages

### Velociraptor

Deploy Velociraptor after Wazuh ingestion works. Generate a read-only API
client configuration and replace:

```text
data/copilot-mcp/api.config.yaml
```

Then set the real `VELOCIRAPTOR_URL`, enable
`MCP_VELOCIRAPTOR_SERVER_ENABLED=true`, configure the connector, and test
read-only artifact collection. Keep quarantine and process termination manual.

### Shuffle

Start with notification-only workflows. Add approval gates before account
changes, isolation, or containment actions.

### Graylog

Add Graylog when you need additional syslog pipelines, streams, or event
definitions. Avoid duplicating Wazuh ingestion until there is a clear reason.

### Grafana and InfluxDB

Use these for infrastructure and sensor dashboards. They do not replace the
Wazuh event store.

### VirusTotal and other enrichment

Configure enrichment API keys only after local alert flow works. Treat cloud
submission and data-sharing implications as part of the deployment decision.

## Operations

Check status:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml ps
```

View backend logs:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml logs --tail=200 copilot-backend
```

Upgrade one service group at a time:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml pull
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml up -d
```

Do not run `docker compose down -v` unless you intentionally want to destroy
the CoPilot database and other persistent volumes.

Back up:

- `.env`, stored securely outside Git
- `data/`
- the `mysql-data` Docker volume
- Wazuh certificates
- Wazuh Manager and Indexer data
- Velociraptor API configuration

## Troubleshooting

If CoPilot does not start:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/home-lab/docker-compose.override.yml logs --tail=200
```

If the backend reports `connector_url cannot be null`, verify that optional
connector URL variables exist in `.env`. The backend seeds connector rows at
startup and requires a non-null URL even for disabled integrations.

If Wazuh data is missing:

1. Check that the Wazuh agent is online.
2. Test the Wazuh Manager connector.
3. Test the Wazuh Indexer connector.
4. Confirm the server can resolve and reach both Wazuh endpoints.
5. Check TLS verification and credentials.

If the first-run password is unavailable, the database was likely initialized
already. Do not delete volumes as a first response. Use the existing account
or the supported account-recovery process.

## Repository safety

Never commit:

```text
.env
data/copilot-admin-password.txt
Wazuh private keys
Velociraptor private API configuration
Shuffle credentials
```

Before committing, review staged files:

```bash
git diff --cached --name-only
git diff --cached --check
```

## License and upstream

HomeSIEM uses SOCFortress CoPilot and other upstream open-source projects.
Review the license files included in this repository and the licenses of all
deployed services before redistribution.
