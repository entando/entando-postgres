#!/bin/bash
#
# Smoke test of one entando-postgres image on one platform.
#
# Usage:
#   tests/smoke-test.sh <image> <platform>
#   e.g. tests/smoke-test.sh entando/entando-postgres-ubi:1.0.0-arm64 linux/arm64
#
# Non-native platforms (e.g. linux/arm64 on an amd64 host) need QEMU/binfmt.
#
# Environment:
#   SMOKE_TIMEOUT         seconds to wait for the database to be ready (default 300)
#   SMOKE_ARBITRARY_UID   "true" to also test an OpenShift-style arbitrary UID.
#                         Off by default: the entrypoint does not support it yet
#                         (see PLAN/ESB-1340, finding #6).

set -uo pipefail

. "$(dirname "$0")/lib.sh"

IMAGE="${1:?image required}"
PLATFORM="${2:?platform required}"
EXPECTED_ARCH="$(uname_arch_of "$PLATFORM")"

log "Smoke testing \"$IMAGE\" on \"$PLATFORM\""

# --- 1. Image metadata --------------------------------------------------------
img_arch="$(docker image inspect -f '{{.Architecture}}' "$IMAGE" 2>/dev/null)"
if [ "$img_arch" = "${PLATFORM#*/}" ] || [ "linux/$img_arch" = "$PLATFORM" ]; then
  pass "image architecture is $img_arch"
else
  fail "image architecture is \"$img_arch\", expected \"${PLATFORM#*/}\""
fi

# --- 2. Binaries --------------------------------------------------------------
run_arch="$(docker run --rm --platform "$PLATFORM" --entrypoint uname "$IMAGE" -m 2>&1)"
[ "$run_arch" = "$EXPECTED_ARCH" ] \
  && pass "runs as $run_arch" \
  || fail "uname -m reports \"$run_arch\", expected \"$EXPECTED_ARCH\""

pg_version="$(docker run --rm --platform "$PLATFORM" --entrypoint "$PG_BIN/postgres" "$IMAGE" --version 2>&1)"
[[ "$pg_version" == "postgres (PostgreSQL) 18."* ]] \
  && pass "$pg_version" \
  || fail "unexpected postgres --version output: $pg_version"

# --- 3. First start: initialization ------------------------------------------
VOL="$(new_volume)"
C1="$(start_db "$IMAGE" "$PLATFORM" "$VOL")"
wait_ready "$C1"; rc=$?
if [ $rc -eq 0 ]; then
  pass "first start: initialized and ready (check-container ok)"
else
  fail "first start: $(not_ready_reason $rc)"
  show_logs "$C1"
  finish
fi

# --- 4. Users, database, data -------------------------------------------------
r="$(psql_remote "$C1" "$APP_USER" "$APP_PASS" "$APP_DB" "select current_user || '@' || current_database()" 2>&1)"
[ "$r" = "$APP_USER@$APP_DB" ] \
  && pass "app user can log in to its database from another container" \
  || fail "app user login: $r"

r="$(psql_remote "$C1" "$APP_USER" "wrong-password" "$APP_DB" "select 1" 2>&1)"
[[ "$r" == *"password authentication failed"* ]] \
  && pass "wrong password is rejected" \
  || fail "wrong password not rejected: $r"

r="$(psql_remote "$C1" postgres "$ADMIN_PASS" postgres "select 'admin-ok'" 2>&1)"
[ "$r" = "admin-ok" ] \
  && pass "admin password works" \
  || fail "admin login: $r"

r="$(psql_as "$C1" "$APP_USER" "$APP_PASS" "$APP_DB" \
  "create table smoke(id int primary key, txt text);
   insert into smoke values (1, 'àèìòù-€');
   select txt from smoke where id = 1" 2>&1)"
[ "$r" = "àèìòù-€" ] \
  && pass "write/read of UTF-8 data" \
  || fail "write/read: $r"

r="$(psql_as "$C1" postgres "$ADMIN_PASS" "$APP_DB" \
  "select pg_encoding_to_char(encoding) || ' ' || datcollate from pg_database where datname = current_database()" 2>&1)"
[[ "$r" == "UTF8 en_US.utf8"* || "$r" == "UTF8 en_US.UTF-8"* ]] \
  && pass "database encoding/collation: $r" \
  || fail "unexpected encoding/collation: $r"

r="$(psql_as "$C1" postgres "$ADMIN_PASS" "$APP_DB" \
  "create extension if not exists pg_trgm; select similarity('entando', 'entando')" 2>&1)"
[ "$r" = "1" ] \
  && pass "contrib extension pg_trgm works" \
  || fail "contrib extension: $r"

# --- 5. Restart on the existing volume ----------------------------------------
stop_db "$C1"
C2="$(start_db "$IMAGE" "$PLATFORM" "$VOL")"
wait_ready "$C2"; rc=$?
if [ $rc -eq 0 ]; then
  pass "restart on existing data: ready"
  docker logs "$C2" 2>&1 | grep -q "Database already initialized" \
    && pass "restart skipped re-initialization" \
    || fail "restart did not detect the existing database"
  r="$(psql_as "$C2" "$APP_USER" "$APP_PASS" "$APP_DB" "select txt from smoke where id = 1" 2>&1)"
  [ "$r" = "àèìòù-€" ] \
    && pass "data persisted across restart" \
    || fail "data after restart: $r"
else
  fail "restart on existing data: $(not_ready_reason $rc)"
  show_logs "$C2"
fi
stop_db "$C2"

# --- 6. Arbitrary UID (OpenShift restricted SCC) ------------------------------
if [ "${SMOKE_ARBITRARY_UID:-false}" = "true" ]; then
  C3="$(start_db "$IMAGE" "$PLATFORM" "$(new_volume)" --user 1000700000:0)"
  wait_ready "$C3"; rc=$?
  if [ $rc -eq 0 ]; then
    pass "arbitrary UID 1000700000:0: ready"
  else
    fail "arbitrary UID 1000700000:0: $(not_ready_reason $rc)"
    show_logs "$C3"
  fi
else
  skip "arbitrary UID (known issue, enable with SMOKE_ARBITRARY_UID=true)"
fi

finish
