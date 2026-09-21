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
        +--> Wazuh agents / syslog --> Wazuh manager + indexer (OpenSearch)
        |                                  |
        |                                  +--> CoPilot connector (search,
        |                                  |    inventory, SCA, vulns)
        |                                  |
        |                                  +--> Graylog (writes gl-events*
        |                                       into this SAME cluster)
        |                                              |
        +--> Graylog (UDM/network syslog) -------------+--> CoPilot Incident
                                                              Management alerts

CoPilot --> Velociraptor (collection and response)
        --> Shuffle (notifications and automation)
        --> Grafana + InfluxDB (metrics and dashboards)
        --> Talon (optional AI investigations)
```

**Graylog is not optional if you want alerts to reach CoPilot's Incident
Management automatically.** CoPilot's only automated Wazuh-alert-ingestion
path polls Graylog's `gl-events*` indices through the Wazuh-Indexer
connector -- there is no separate scheduler that pulls alerts directly from
the Wazuh Indexer. Wazuh plus CoPilot alone gives you agent inventory,
live search, SCA, and vulnerability data, but Incident Management stays
empty until Graylog is deployed, pointed at the same OpenSearch cluster as
the Wazuh Indexer (see root `README.md` Section 5.1), and an alert-provisioning
item (e.g. `WAZUH SYSLOG LEVEL ALERT`) is enabled. Add Velociraptor before
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
`openssl rand -hex 48`. This deployment does not run Graylog's own Data
Node -- `deploy/home-lab/setup-env.sh`/`.ps1` set `GRAYLOG_ELASTICSEARCH_HOSTS`
to point Graylog directly at the Wazuh Indexer's OpenSearch cluster, because
CoPilot's automatic alert ingestion reads Graylog's `gl-events*` indices
through the Wazuh-Indexer connector. **Confirmed working with the Wazuh
Indexer admin credentials** on a security-enabled cluster. The minimum
OpenSearch Security privileges for a narrower role aren't documented
anywhere, so that's still untested -- treat the admin account as the
known-good baseline. See the root `README.md` Section 5.1 for more detail.

TLS trust is the other half of this and always needs fixing: the Wazuh
Indexer's self-signed certificate isn't trusted by Graylog's Java HTTP
client by default, which shows up as `VersionProbe` retrying forever with a
`certificate_unknown` error. Start the Graylog project with the wrapper that
handles this automatically -- do not run `docker compose up` directly
against `deploy/graylog/docker-compose.yml` on a fresh checkout, the
`certificates` directory it mounts will be empty:

```bash
bash deploy/graylog/start.sh
docker compose --env-file deploy/graylog/.env \
  -f deploy/graylog/docker-compose.yml logs --tail=200
```

See root `README.md` Section 5.2 for what the wrapper does.

Without a Data Node to bootstrap, there is no temporary initialization
password. Graylog starts directly with the final password configured by
`GRAYLOG_ROOT_PASSWORD_SHA2` in `deploy/graylog/.env`. Open Graylog at
`GRAYLOG_HTTP_EXTERNAL_URI` and log in as `admin` with that password. If
Graylog does not become healthy, check the logs above for OpenSearch
connection/authentication errors before anything else -- that is the most
likely first-run failure with this setup.

Open **System > Inputs** in Graylog and launch
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
password` line, extracts its `plain='...'` value, and saves only the password to
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

Graylog is covered in Section 2 above -- it is required for automatic alert
ingestion into Incident Management, not optional. Once it's running, use
Graylog streams and event definitions for UDM and AdGuard-derived events,
configure the Graylog connector in CoPilot, and enable the built-in
`WAZUH SYSLOG LEVEL ALERT` provisioning item (Log Management > Graylog
Management > Alert Provisioning) for Wazuh. Validate one event definition
end to end before creating broad alert rules.

### Velociraptor

Deploy Velociraptor 0.7.x, enroll only lab endpoints first, and create the
read-only API configuration mounted at `data/copilot-mcp/api.config.yaml`.
Configure the Velociraptor connector and prove artifact collection works.
Keep quarantine and other disruptive actions manual until the workflow has
been tested against a disposable endpoint. `setup-env` writes a guessed
`VELOCIRAPTOR_URL` and a random `VELOCIRAPTOR_API_HEADER_VALUE` into `.env`
before Velociraptor exists to confirm against -- revisit both once it's
running. See root `README.md` Section 10.2 for the full walkthrough.

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

Talon is the agentic SOC analyst -- a separate service
([taylorwalton/talon](https://github.com/taylorwalton/talon)) that
auto-investigates alerts and writes reports back into CoPilot. Deploy it
last, after Wazuh search, Graylog alert ingestion, and Velociraptor
collection are all reliable, since Talon depends on all three through its
own MCP connectors. It is a much heavier deployment than the others (18
steps, its own OneCLI credential vault, a systemd service, an ongoing
Anthropic API cost) -- see root `README.md` Section 10.4 for the
HomeSIEM-specific values to use at each step, and Talon's own README for the
full guide. Keep AI-triggered investigations disabled until you have
reviewed the prompt/data boundaries and notification routes.

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