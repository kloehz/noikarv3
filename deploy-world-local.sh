#!/usr/bin/env bash
## Local build + direct deploy of the dedicated server runtime to the VPS.
## Skips the CI round-trip: exports the Linux server preset with the local
## Godot install (warm .godot cache makes this fast) and rsyncs the artifact
## straight into the same releases/ + current-symlink layout the CI uses.
##
## Usage:
##   ./deploy-world-local.sh            # export, deploy, verify
##   ./deploy-world-local.sh --smoke    # also boot the binary on the VPS
##
## Overrides (env): VPS_HOST, VPS_USER, VPS_DEPLOY_PATH, GODOT_BIN

set -euo pipefail

VPS_HOST="${VPS_HOST:-72.60.58.24}"
VPS_USER="${VPS_USER:-root}"
VPS_DEPLOY_PATH="${VPS_DEPLOY_PATH:-/root/noikar}"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
RELEASE_VERSION="${RELEASE_VERSION:-$(git rev-parse --short HEAD)-local-$(date +%Y%m%d%H%M%S)}"
SMOKE="${1:-}"

cd "$(dirname "$0")"

echo "[1/4] Exporting dedicated server (Linux)…"
"$GODOT_BIN" --headless --path . --export-release "Dedicated Server (Linux)" build/world/noikar-server.x86_64
test -x build/world/noikar-server.x86_64
test -f build/world/noikar-server.pck
du -sh build/world/noikar-server.pck

echo "[2/4] Uploading release ${RELEASE_VERSION}..."
ssh "$VPS_USER@$VPS_HOST" "mkdir -p '$VPS_DEPLOY_PATH/world/releases/$RELEASE_VERSION'"
rsync -az --delete build/world/ "$VPS_USER@$VPS_HOST:$VPS_DEPLOY_PATH/world/releases/$RELEASE_VERSION/"

echo "[3/4] Switching current symlink…"
ssh "$VPS_USER@$VPS_HOST" "set -euo pipefail
  world_dir='$VPS_DEPLOY_PATH/world'
  release_path=\"\$world_dir/releases/$RELEASE_VERSION\"
  ln -sfn \"\$release_path\" \"\$world_dir/current.next\"
  mv -Tf \"\$world_dir/current.next\" \"\$world_dir/current\"
  test -x \"\$world_dir/current/noikar-server.x86_64\"
  test -f \"\$world_dir/current/noikar-server.pck\"
  \"\$world_dir/current/noikar-server.x86_64\" --version"

if [ "$SMOKE" = "--smoke" ]; then
  echo "[4/4] Boot smoke test (10s)…"
  ssh "$VPS_USER@$VPS_HOST" "cd '$VPS_DEPLOY_PATH/world/current' && timeout 10 ./noikar-server.x86_64 2>&1 | head -30 || true"
else
  echo "[4/4] Skipped boot smoke test (pass --smoke to run it)."
fi

echo "DEPLOYED: $VPS_USER@$VPS_HOST:$VPS_DEPLOY_PATH/world/current -> releases/$RELEASE_VERSION"
