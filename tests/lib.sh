# shellcheck shell=bash
# Shared helpers for the entando-postgres container tests.
# Sourced by tests/smoke-test.sh and tests/cross-arch-restore.sh.

PG_BIN="/usr/pgsql-18/bin"
PGDATA_DIR="/var/lib/pgsql/data/userdata"

# Under QEMU emulation (arm64 on an amd64 runner) initdb and startup are slow
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-300}"

APP_USER="smoke_user"
APP_PASS="smoke_pw"
APP_DB="smoke_db"
ADMIN_PASS="smoke_admin_pw"

# Every container/volume created by a run carries this label, so cleanup works
# even though start_db/new_volume run in $(...) subshells.
RUN_LABEL="pgsmoke.run=$$-$RANDOM"
_FAILURES=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; echo "::error::$*"; _FAILURES=$((_FAILURES + 1)); }
skip() { echo "  SKIP  $*"; }

cleanup() {
  local ids
  ids="$(docker ps -aq --filter "label=$RUN_LABEL")"
  [ -n "$ids" ] && docker rm -f $ids &>/dev/null
  ids="$(docker volume ls -q --filter "label=$RUN_LABEL")"
  [ -n "$ids" ] && docker volume rm -f $ids &>/dev/null
  return 0
}
trap cleanup EXIT

# Platform -> kernel arch as reported by "uname -m"
uname_arch_of() {
  case "${1#*/}" in
    amd64*) echo "x86_64" ;;
    arm64*) echo "aarch64" ;;
    *) echo "unknown" ;;
  esac
}

new_volume() {
  local v="pgsmoke-$RANDOM$RANDOM"
  docker volume create --label "$RUN_LABEL" "$v" >/dev/null
  echo "$v"
}

# start_db <image> <platform> <volume> [extra docker run args...]
# Prints the container name.
# The volume is mounted on /var/lib/pgsql (owned by postgres in the image, so a
# new named volume inherits that ownership), as entando-bundle-cli does.
# Mounting /var/lib/pgsql/data instead gives a root-owned directory on plain
# Docker; on Kubernetes the pod fsGroup takes care of it.
start_db() {
  local image="$1" platform="$2" volume="$3"; shift 3
  local c="pgsmoke-$RANDOM$RANDOM"
  docker run -d --name "$c" --platform "$platform" --label "$RUN_LABEL" \
    -v "$volume:/var/lib/pgsql" \
    -e POSTGRESQL_USER="$APP_USER" \
    -e POSTGRESQL_PASSWORD="$APP_PASS" \
    -e POSTGRESQL_DATABASE="$APP_DB" \
    -e POSTGRESQL_ADMIN_PASSWORD="$ADMIN_PASS" \
    "$@" "$image" >/dev/null
  echo "$c"
}

# Waits until the entrypoint finished the initialization and the real server
# accepts connections (the entrypoint runs a temporary server during init,
# so pg_isready alone is not enough).
# Returns 0 when ready, 1 on timeout, 2 if the container exited.
wait_ready() {
  local c="$1" i
  for ((i = 0; i < SMOKE_TIMEOUT; i++)); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then
      return 2
    fi
    if docker exec "$c" test -f "$PGDATA_DIR/initialized" 2>/dev/null \
      && docker exec "$c" /usr/libexec/check-container &>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# psql over TCP as the given user: psql_as <container> <user> <password> <db> <sql>
psql_as() {
  docker exec -e PGPASSWORD="$3" "$1" "$PG_BIN/psql" -h 127.0.0.1 -U "$2" -d "$4" \
    -v ON_ERROR_STOP=1 -qtAc "$5"
}

# psql from a separate client container over the Docker network, i.e. as an
# application would connect: psql_remote <container> <user> <password> <db> <sql>
# (connections from inside the container itself use initdb's "trust" rule for
# 127.0.0.1, so they can't be used to test authentication)
psql_remote() {
  local ip image platform
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1")"
  image="$(docker inspect -f '{{.Config.Image}}' "$1")"
  platform="$(docker inspect -f '{{.Platform}}' "$1")"
  docker run --rm --label "$RUN_LABEL" --platform "${platform:-linux}/$(docker image inspect -f '{{.Architecture}}' "$image")" \
    -e PGPASSWORD="$3" -e PGCONNECT_TIMEOUT=30 --entrypoint "$PG_BIN/psql" "$image" \
    -h "$ip" -U "$2" -d "$4" -v ON_ERROR_STOP=1 -qtAc "$5"
}

stop_db() {
  docker stop -t 60 "$1" &>/dev/null || true
}

# Human readable reason for a wait_ready failure code
not_ready_reason() {
  case "$1" in
    2) echo "container exited" ;;
    *) echo "not ready within ${SMOKE_TIMEOUT}s" ;;
  esac
}

show_logs() {
  echo "----- container logs ($1) -----"
  docker logs "$1" 2>&1 | tail -n 40
  echo "-------------------------------"
}

finish() {
  if [ "$_FAILURES" -gt 0 ]; then
    log "RESULT: $_FAILURES check(s) failed"
    exit 1
  fi
  log "RESULT: all checks passed"
}
