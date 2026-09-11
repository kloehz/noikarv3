# Noikar v3

Noikar v3 is a Godot 4.7 project that uses a private Noray submodule.
Fresh clones need access to both GitHub repositories; the Noray repository is private.

## Access first

Use an authorized GitHub account for both repositories:

- `kloehz/noikarv3`
- `kloehz/noikar-noray`

Submodule metadata only tells Git where to fetch from. It cannot bypass GitHub permissions; unauthorized access may appear as a `404`.

## Fresh clone

```bash
git clone --recurse-submodules https://github.com/kloehz/noikarv3.git
cd noikarv3
```

## Existing clean clone

WARNING: Preserve local changes first. If `noikar-noray` is an existing folder not managed as a submodule, move the entire folder to a safe backup location outside this checkout before initializing. Keep its private configuration, including `.env`. Do not delete or force-overwrite local content.

```bash
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive
```

## Expected submodule state

`git submodule status noikar-noray` should show `noikar-noray` checked out at the commit recorded by this repository.

The checkout does not import private configuration from this PC.

## Running the project

Open `project.godot` with Godot 4.7, or use the launcher:

```bash
./play.sh          # client
./play.sh server   # headless server
./play.sh local    # isolated local PostgreSQL/backend/Noray/server/client manual session
```

`./play.sh local` wraps `tests/manual/profile_room_scaling.py --human` and passes the launcher's detected Godot binary. Override Godot with `GODOT_BIN=/absolute/path/to/Godot ./play.sh local`.

Playing against the hosted VPS does not require starting a local Noray server.

For local Noray development, refer to `noikar-noray/README.md`. Private `.env` configuration is not transferred automatically.
