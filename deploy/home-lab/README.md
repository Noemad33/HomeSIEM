# Home SIEM deployment

This profile deploys CoPilot as the analyst and response plane alongside a
separate Wazuh single-node deployment. Wazuh remains the source of truth for
endpoint telemetry and the OpenSearch-backed event store; CoPilot provides
case management, enrichment, dashboards, investigations, and response
workflows.

## Target layout

```text
home endpoints + network devices
        |
        +--> Wazuh agents / syslog --> Wazuh manager + indexer
        |                                  |
        |                                  +--> CoPilot connector
        |
        +--> optional Graylog ----------------> CoPilot alert ingestion

CoPilot --> Velociraptor (collection and response)
        --> Shuffle (notifications and automation)
        --> Grafana + InfluxDB (metrics and dashboards)
        --> Talon (optional AI investigations)
```

The recommended first deployment is Wazuh plus CoPilot. Add Graylog only when
you need its stream and event-definition workflow, and add Velociraptor before
enabling automated endpoint response.

## Deployment model

Use two Compose projects coordinated by this guide: the official Wazuh
single-node Compose project and this repository's CoPilot Compose project.
Wazuh has a certificate-generation and indexer bootstrap sequence that is
maintained by Wazuh and should not be copied into this repository. Keeping it
separate also lets you upgrade or recover the SIEM without taking the analyst
interface down. The setup wrappers below make the CoPilot side repeatable;
they never delete volumes or reset an existing database.

## Server prerequisites

- A dedicated Linux server or VM with Docker Engine and the Compose plugin.
- 4 vCPU, 16 GB RAM, and 250 GB SSD for a small lab. Increase storage for
  endpoint history and file collection.
- A stable LAN address and a private access path such as Tailscale or a VPN.
- Never publish Wazuh, OpenSearch, MySQL, MinIO, Velociraptor, or Shuffle
  administration ports to the public internet.

## 1. Deploy Wazuh

Use the official Wazuh Docker deployment and pin the version to the CoPilot
known-good baseline, currently Wazuh `4.14.2`. Generate the Wazuh certificates
with the official helper and deploy the single-node profile on the server.
Keep the manager API and indexer reachable from CoPilot on the private Docker
network or LAN only.

Enroll Windows and Linux agents from the Wazuh dashboard. For network devices,
send syslog to the Wazuh manager or to Graylog if Graylog is enabled. Confirm
that at least one endpoint is producing fresh alerts before continuing.

## 2. Start and initialize Graylog

Run the guided environment setup before this section. It creates both the
main `.env` and `deploy/graylog/.env`; do not copy the Graylog template again:

```bash
bash deploy/home-lab/setup-env.sh
```

Choose the final Graylog administrator password, save it in a password
manager, and put only its SHA-256 hash in `deploy/graylog/.env`:

```bash
printf '%s' 'CHOOSE_A_GRAYLOG_ADMIN_PASSWORD' | sha256sum
```

Set `GRAYLOG_PASSWORD_SECRET` to a separate value generated with
`openssl rand -hex 48`, then start the Graylog project:

```bash
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml up -d
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml ps
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml logs --tail=200
```

On first startup, Graylog/Data Node bootstrap may emit a temporary
initialization password in the logs. Capture it before the bootstrap restart;
it is needed for certificate and Data Node initialization:

```bash
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml logs -f graylog graylog-datanode
```

Store that temporary password securely and never commit or paste it into
support logs. After bootstrap completes, Graylog restarts and applies the
final password configured by `GRAYLOG_ROOT_PASSWORD_SHA2` in
`deploy/graylog/.env`. Open Graylog at `GRAYLOG_HTTP_EXTERNAL_URI` and log in
as `admin` with the final password. Complete Data Node initialization before
creating inputs. If the containers restart before the temporary password is
captured, inspect the full first-start logs before removing any volumes.

After Data Node initialization, open **System > Inputs** in Graylog and launch
a **Syslog UDP** input with title `HomeSIEM Syslog UDP`, bind address
`0.0.0.0`, and container port `1514`. If TCP is needed, launch a separate
**Syslog TCP** input with the same bind address and container port. Docker
maps these to host ports `2514/udp` and `2515/tcp`; enter `1514` in Graylog,
not the host ports.

New inputs may initially show **Setup mode**. Click **Setup**, choose
**Create new stream**, and name it `UDM Firewall`. On the Routing page:

- Description: `UDM firewall and security events`
- **Remove matches from Default Stream:** checked
- **Create a new pipeline for this stream:** checked
- **Index Set:** choose **Default index set** for the first test

The Default index set notice is advisory, not an error. A dedicated index set
can be created later when retention and rotation are planned. Click **Next**,
review the **Launch** page, then click **Launch** or **Finish**. Use the
**Diagnosis** page to confirm there are no input, stream, or processing errors.
Return to **System > Inputs**, click **Start** or **Resume**, and confirm the
input is **Running**.

In **Search**, verify that a test event contains `source`, `message`, and
`gl2_source_input`, then confirm it appears in the `UDM Firewall` stream.
Create the additional streams `AdGuard DNS` and `Network Security` only after
the first stream works. Use fields confirmed in Search for their rules. Create
event definitions only after real events are present.

## 3. Configure CoPilot

From the repository root on the target server, review the generated
environment files before starting CoPilot:

```bash
less .env
less deploy/graylog/.env
```

The wrapper already created both files, generated internal secrets, prompted
for Wazuh and Graylog values, and stored only the SHA-256 hash of the Graylog
administrator password in the Graylog environment file. It does not overwrite
existing environment files. Use `--force` only when you intend to replace
them; timestamped backups are created first.

When all three Compose projects run on the same Debian VM, answer the URL
prompts with the VM's private LAN IP or DNS hostname. For example:

```text
CoPilot: 192.168.1.50
Wazuh Indexer: https://192.168.1.50:9200
Wazuh Manager: https://192.168.1.50:55000
Graylog: http://192.168.1.50:9000
```

Do not use `localhost`, `127.0.0.1`, or container names from another Compose
project. Restrict ports `9200`, `55000`, `9000`, `2514`, and `2515` to the
LAN/VPN.

CoPilot publishes HTTPS on host port `8443` and the container still listens on
`443`. Use `https://VM_IP:8443` for the CoPilot browser URL. This avoids the
common collision with the Wazuh dashboard, which normally owns host port `443`.

On Windows PowerShell:

```powershell
.\deploy\home-lab\setup-env.ps1
```

Review both generated files, then validate CoPilot:

```bash
docker compose -f docker-compose.yml -f deploy/home-lab/docker-compose.override.yml config
```

For repeatable setup from PowerShell, use:

```powershell
.\deploy\home-lab\setup.ps1 -Pull -CaptureAdminPassword
```

On Linux, use:

```bash
bash deploy/home-lab/setup.sh --pull --capture-admin-password
```

The capture option watches the backend logs for the first-run `Admin user
password` line and saves only the password to
`data/copilot-admin-password.txt`. That file is ignored by Git and is never
overwritten. If the CoPilot database already exists, no password is emitted;
the wrapper reports that condition and you must use the existing administrator
account or follow the documented account-recovery procedure.

Before starting, set unique values in `.env` for:

- `JWT_SECRET`, `SSO_STATE_SECRET`, and `TOTP_ENCRYPTION_KEY`
- `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, and `MINIO_ROOT_PASSWORD`
- `WAZUH_INDEXER_URL`, `WAZUH_INDEXER_USERNAME`, and `WAZUH_INDEXER_PASSWORD`
- `WAZUH_MANAGER_URL`, `WAZUH_MANAGER_USERNAME`, and `WAZUH_MANAGER_PASSWORD`
- `SERVER_HOST` and `COPILOT_URL` for the private hostname users will access

Set `WAZUH_PROD_URL` and the matching `WAZUH_PROD_*` credentials as well; the
MCP service uses those values for manager operations. Set
`OPENSEARCH_URL` and the matching credentials to the Wazuh indexer. For a
trusted internal CA, set `OPENSEARCH_SSL_VERIFY=true` and
`WAZUH_PROD_SSL_VERIFY=true`; do not leave TLS verification disabled when the
services are not on the same trusted host/network.

The override removes host publishing for backend, MySQL, MinIO, and the file
analysis runner. CoPilot is accessed through its HTTPS frontend. If Graylog
must call CoPilot from another host, expose only backend port `5000` on the
private LAN and set a strong `GRAYLOG_API_HEADER_VALUE`.

## 4. Complete the first useful loop

1. Open CoPilot over the private HTTPS address and create the administrator.
2. Configure and verify the Wazuh Manager and Wazuh Indexer connectors.
3. Create one stable customer code, such as `HOME`, and associate the agents.
4. Verify an agent is online and that recent Wazuh events are searchable.
5. Trigger a harmless test detection, open the alert, and create a case.
6. Back up `data/`, the MySQL volume, and the Wazuh data before adding response.

## Optional integrations

### Graylog

Use the bundled Graylog project at `deploy/graylog`. Start it before CoPilot,
create its Syslog UDP/TCP inputs, and send UDM logs to the Graylog host. Use
Graylog streams and event definitions for UDM and AdGuard-derived events, then
configure the Graylog connector in CoPilot. Validate one event definition end
to end before creating broad alert rules.

### Velociraptor

Deploy Velociraptor 0.7.x, enroll only lab endpoints first, and create the
read-only API configuration mounted at `data/copilot-mcp/api.config.yaml`.
Configure the Velociraptor connector and prove artifact collection works.
Keep quarantine and other disruptive actions manual until the workflow has
been tested against a disposable endpoint.

### Shuffle

Use Shuffle for notifications and multi-step automation. Start with a
notification-only workflow that receives alert context from CoPilot. Add
containment or account actions only after you have an approval gate and an
audit trail.

### Grafana and InfluxDB

Use Grafana for dashboards and InfluxDB for infrastructure metrics. These are
observability complements, not replacements for the Wazuh event store. The
CoPilot known-good baseline is Grafana 12.3.3 and InfluxDB v2 API support.

### Talon

Talon is optional. Enable it only after Wazuh search and Velociraptor
collection are reliable. Keep AI-triggered investigations disabled until you
have reviewed the prompt/data boundaries and notification routes.

## Security and operations checklist

- Put the UI behind a VPN or an authenticated reverse proxy; do not port
  forward the stack directly from the home router.
- Enable CoPilot 2FA and use a separate non-admin analyst account.
- Use unique secrets and keep `.env`, Wazuh keys, Velociraptor API configs,
  and Shuffle credentials out of Git.
- Use alert severity thresholds and approval gates for response actions.
- Retain only the telemetry history you need, and test restore procedures.
- Pin image versions for production-like use; update one service at a time.
- Test with Atomic Red Team or another controlled benign simulation after each
  major rule or agent change.

## Upgrade and troubleshooting

```bash
docker compose -f docker-compose.yml -f deploy/home-lab/docker-compose.override.yml ps
docker compose -f docker-compose.yml -f deploy/home-lab/docker-compose.override.yml logs --tail=200 copilot-backend
docker compose -f docker-compose.yml -f deploy/home-lab/docker-compose.override.yml pull
docker compose -f docker-compose.yml -f deploy/home-lab/docker-compose.override.yml up -d
```

If no endpoint data appears, verify the Wazuh agent first, then the Wazuh
Manager connector, and finally the indexer connector. If alerts are missing
but events exist, inspect Graylog streams/event definitions when Graylog is in
use; CoPilot does not replace that alerting path.