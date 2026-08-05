# Noikar VPS Deployment

The production VPS runs three services:

- PostgreSQL and the Go authentication API from this repository's `backend/` directory.
- Noray from the separate `noikar-noray` repository.

Noray also requires the Godot dedicated-server runtime. It is not a persistent
service: Noray starts a headless exported binary from `${NOIKAR_VPS_PATH}/world`
for each hosted room. The client itself is not deployed to the VPS.

## GitHub Configuration

Configure these repository secrets in `kloehz/noikarv3`:

- `VPS_HOST`
- `VPS_USER`
- `VPS_SSH_PRIVATE_KEY`
- `VPS_KNOWN_HOSTS`
- `NOIKAR_BACKEND_ENV_B64`

Configure the repository variable `NOIKAR_VPS_PATH` with an absolute path, for
example `/opt/noikar`.

The current Hostinger VPS is configured as `72.60.58.24`, user `root`, with
deployment path `/root/noikar`. Those values and the host key are already set
in this repository. The remaining SSH private key must be authorized on the
VPS before Actions can connect.

The SSH key must be restricted to deployment access. `VPS_KNOWN_HOSTS` must be
the pinned `known_hosts` entry for the VPS, not a value fetched during deploy.

## One-Time Backend Setup

GitHub Actions installs `${NOIKAR_VPS_PATH}/backend/.env` from the
base64-encoded `NOIKAR_BACKEND_ENV_B64` secret before each deploy. It must
define `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_URL`,
`JWT_SECRET`, and `PROVISIONER_CREDENTIAL`. This secret is never written to
the repository or exposed in workflow logs.

Set `DATABASE_URL` to the Compose service hostname, for example:

```text
postgres://noikar:<password>@db:5432/noikar?sslmode=disable
```

The backend binds to `127.0.0.1:8090` (8080 is used by an unrelated service on
the VPS). Configure the VPS reverse proxy to serve
it over HTTPS, then set the exported client's `noikar/auth/api_url` to that
public URL.

## Deploys

Pushing backend changes to `main` runs tests, syncs the backend source with
`rsync`, rebuilds the Compose stack, and waits for `/api/v1/health`.

Pushing dedicated-server source changes exports a Linux dedicated-server build
in CI and syncs only that artifact to `${NOIKAR_VPS_PATH}/world/releases`. It
then atomically switches `${NOIKAR_VPS_PATH}/world/current` to the new release,
so rooms already running retain their previous runtime. The server export
excludes `res://assets/models/**` and `res://MODELS_TEST/**`: combat/AI data
lives in `CharacterSpec` resources (`common/resources/specs/`), so the headless
runtime never loads actor scenes or meshes and the `.pck` stays around 7 MB.

## Local world-runtime deploy (fast iteration)

`./deploy-world-local.sh` exports the same Linux preset with the local Godot
install and rsyncs the artifact straight to the VPS using the same
releases/current-symlink layout as CI. It finishes in about a minute thanks to
the warm local `.godot` import cache, making it the fastest way to iterate on
runtime changes before pushing. Pass `--smoke` to also boot the binary on the
VPS for a few seconds. `VPS_HOST`, `VPS_USER`, `VPS_DEPLOY_PATH`, and
`GODOT_BIN` can be overridden through the environment. CI remains the official
pipeline for anything merged to `main`.

Noray is deployed independently from `noikar-noray` because it has its own
source repository and release cadence. Its published Docker image does not
include the Godot dedicated-server binary that it launches for each room.
Run Noray directly on the VPS with Node.js, and configure
`GODOT_EXECUTABLE_PATH` to `${NOIKAR_VPS_PATH}/world/current/noikar-server.x86_64`,
`GODOT_PROJECT_PATH` to `${NOIKAR_VPS_PATH}/world/current`,
`NOIKAR_BACKEND_URL` to `http://127.0.0.1:8090`, and
`NOIKAR_PROVISIONER_CREDENTIAL` to the same value as the backend environment.
