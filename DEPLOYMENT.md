# Noikar VPS Deployment

The production VPS runs three services:

- PostgreSQL and the Go authentication API from this repository's `backend/` directory.
- Noray from the separate `noikar-noray` repository.

Noray also requires the Godot dedicated-server runtime. It is not a persistent
service: Noray starts a headless exported binary from `${NOIKAR_VPS_PATH}/world`
for each hosted room. The client itself is not deployed to the VPS.

## GitHub Configuration

Configure these repository secrets in both repositories:

- `VPS_HOST`
- `VPS_USER`
- `VPS_SSH_PRIVATE_KEY`
- `VPS_KNOWN_HOSTS`

Configure the repository variable `NOIKAR_VPS_PATH` with an absolute path, for
example `/opt/noikar`.

The SSH key must be restricted to deployment access. `VPS_KNOWN_HOSTS` must be
the pinned `known_hosts` entry for the VPS, not a value fetched during deploy.

## One-Time Backend Setup

Create `${NOIKAR_VPS_PATH}/backend/.env` on the VPS. It is intentionally never
uploaded or deleted by GitHub Actions. It must define `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_URL`, `JWT_SECRET`, and
`PROVISIONER_CREDENTIAL`.

Set `DATABASE_URL` to the Compose service hostname, for example:

```text
postgres://noikar:<password>@db:5432/noikar?sslmode=disable
```

The backend binds to `127.0.0.1:8080`. Configure the VPS reverse proxy to serve
it over HTTPS, then set the exported client's `noikar/auth/api_url` to that
public URL.

## Deploys

Pushing backend changes to `main` runs tests, syncs the backend source with
`rsync`, rebuilds the Compose stack, and waits for `/api/v1/health`.

Pushing dedicated-server source changes exports a Linux dedicated-server build
in CI and syncs only that artifact to `${NOIKAR_VPS_PATH}/world/releases`. It
then atomically switches `${NOIKAR_VPS_PATH}/world/current` to the new release,
so rooms already running retain their previous runtime. Godot strips visual
resources from this export, so the VPS does not receive client meshes,
materials, textures, or audio assets.

Noray is deployed independently from `noikar-noray` because it has its own
source repository and release cadence.
