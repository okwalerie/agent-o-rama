#!/bin/bash
# Build an agent-o-rama release from this checkout and make it the UI that
# waler's `rama-aor` quadlet runs. Called by .github/workflows/deploy-waler.yml
# on the repo-scoped self-hosted runner (user `core`); safe to run by hand too.
#
# Layout (see okwalerie/rama-waler): rama-aor mounts $RELEASES at
# /opt/aor-releases and runs /opt/aor-releases/current/aor. `current` is a
# relative symlink, so flipping it and restarting rama-aor is the whole deploy.
# Agent modules are NOT redeployed; they embed the library and need a rebuild +
# `rama-ctl update` of their own.
set -euo pipefail

RAMA=/mnt/service-data/rama
RELEASES=$RAMA/aor-releases
BUILD_IMAGE=localhost/aor-build:21
KEEP=5
UI=http://127.0.0.1:1974/

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)

# The runner is a system service running as core; reach core's user manager.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

name="$(cat "$SRC/VERSION")-$(git -C "$SRC" rev-parse --short=10 HEAD)"
incoming=.incoming-$name
echo "deploy: building $name"

podman build --tag "$BUILD_IMAGE" "$HERE"
mkdir -p "$RAMA/build/m2" "$RAMA/build/npm" "$RELEASES"

# Unzip inside the container so the release gets the shared (:z) SELinux label
# rama-aor can read. _JAVA_OPTIONS overrides project.clj's -Xms6g/-Xmx6g (it is
# applied after command-line flags) so lein's JVMs fit next to Rama.
podman run --rm \
  -v "$SRC:/src:z" \
  -v "$RAMA/build/m2:/root/.m2:z" \
  -v "$RAMA/build/npm:/root/.npm:z" \
  -v "$RELEASES:/releases:z" \
  -e _JAVA_OPTIONS='-Xms256m -Xmx3g' \
  -e INCOMING="$incoming" \
  -w /src "$BUILD_IMAGE" \
  bash -euo pipefail -c '
    scripts/build-release.sh
    rm -rf "/releases/$INCOMING"
    unzip -q agent-o-rama-*.zip -d "/releases/$INCOMING"
    mkdir -p "/releases/$INCOMING/logs"'

prev=$(readlink "$RELEASES/current" || true)
rm -rf "${RELEASES:?}/$name"
mv "$RELEASES/$incoming" "$RELEASES/$name"

activate() {
  ln -sfn "$1" "$RELEASES/.current.tmp"
  mv -T "$RELEASES/.current.tmp" "$RELEASES/current"
  systemctl --user restart rama-aor.service
}

healthy() { # the UI JVM waits for the conductor, then needs ~1 min to boot
  for _ in $(seq 1 60); do
    curl -fsS --max-time 5 -o /dev/null "$UI" 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

echo "deploy: activating $name (previous: ${prev:-none})"
activate "$name"
if ! healthy; then
  journalctl --user -u rama-aor.service -n 80 --no-pager || true
  if [[ -n "$prev" && "$prev" != "$name" ]]; then
    echo "deploy: $name failed health check; rolling back to $prev" >&2
    activate "$prev"
    healthy || echo "deploy: rollback to $prev is not healthy either" >&2
  fi
  exit 1
fi

printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$name" "$(git -C "$SRC" rev-parse HEAD)" "${GITHUB_RUN_ID:-manual}" \
  >> "$RELEASES/deploys.log"
echo "deploy: $name is live"

# Keep the newest $KEEP releases, plus whatever current and prev point at.
ls -1t "$RELEASES" | grep -v -x -e current -e deploys.log -e "$name" -e "${prev:-current}" \
  | tail -n +"$KEEP" | while read -r old; do
    echo "deploy: pruning $old"
    rm -rf "${RELEASES:?}/$old"
  done || true
