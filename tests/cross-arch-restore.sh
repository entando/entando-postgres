#!/bin/bash
#
# Validates the supported cross-architecture migration path: a logical
# pg_dumpall taken on one platform is restored on another one.
# (Reusing the data directory itself across architectures is NOT supported.)
#
# Usage:
#   tests/cross-arch-restore.sh <srcImage> <srcPlatform> <dstImage> <dstPlatform>
#   e.g. tests/cross-arch-restore.sh \
#          entando/entando-postgres-ubi:1.0.0-amd64 linux/amd64 \
#          entando/entando-postgres-ubi:1.0.0-arm64 linux/arm64

set -uo pipefail

. "$(dirname "$0")/lib.sh"

SRC_IMAGE="${1:?source image required}"
SRC_PLATFORM="${2:?source platform required}"
DST_IMAGE="${3:?destination image required}"
DST_PLATFORM="${4:?destination platform required}"

DUMP_FILE="$(mktemp)"
trap 'rm -f "$DUMP_FILE"; cleanup' EXIT

log "Cross-arch restore: $SRC_PLATFORM ($SRC_IMAGE) -> $DST_PLATFORM ($DST_IMAGE)"

# --- Source: create data and dump it ------------------------------------------
SRC="$(start_db "$SRC_IMAGE" "$SRC_PLATFORM" "$(new_volume)")"
wait_ready "$SRC" || { fail "source not ready"; show_logs "$SRC"; finish; }

psql_as "$SRC" "$APP_USER" "$APP_PASS" "$APP_DB" \
  "create table items(id int primary key, name text not null);
   insert into items select g, 'item-' || g || '-àèì' from generate_series(1, 1000) g;
   create index items_name_idx on items(name);" >/dev/null \
  && pass "source: test data created" \
  || fail "source: unable to create test data"

src_sum="$(psql_as "$SRC" "$APP_USER" "$APP_PASS" "$APP_DB" \
  "select count(*) || ':' || md5(string_agg(name, ',' order by name)) from items")"

docker exec -e PGPASSWORD="$ADMIN_PASS" "$SRC" "$PG_BIN/pg_dumpall" -h 127.0.0.1 -U postgres > "$DUMP_FILE" \
  && pass "source: pg_dumpall ($(wc -c < "$DUMP_FILE") bytes)" \
  || fail "source: pg_dumpall failed"

# --- Destination: fresh instance, restore, compare ----------------------------
DST="$(start_db "$DST_IMAGE" "$DST_PLATFORM" "$(new_volume)")"
wait_ready "$DST" || { fail "destination not ready"; show_logs "$DST"; finish; }

# The fresh instance already has the app user/database and the postgres role:
# the "already exists" errors for those are expected, so ON_ERROR_STOP is off.
docker exec -i -e PGPASSWORD="$ADMIN_PASS" "$DST" "$PG_BIN/psql" -h 127.0.0.1 -U postgres -d postgres -q \
  < "$DUMP_FILE" > /dev/null 2>&1

dst_sum="$(psql_as "$DST" "$APP_USER" "$APP_PASS" "$APP_DB" \
  "select count(*) || ':' || md5(string_agg(name, ',' order by name)) from items" 2>&1)"
[ "$dst_sum" = "$src_sum" ] \
  && pass "destination: data identical after restore ($dst_sum)" \
  || fail "destination: data differs (source $src_sum, destination $dst_sum)"

r="$(psql_as "$DST" "$APP_USER" "$APP_PASS" "$APP_DB" \
  "set enable_seqscan = off; select count(*) from items where name = 'item-500-àèì'" 2>&1)"
[ "$r" = "1" ] \
  && pass "destination: index lookup works" \
  || fail "destination: index lookup returned: $r"

r="$(psql_as "$DST" postgres "$ADMIN_PASS" "$APP_DB" "select bt_index_check('items_name_idx')" 2>&1)"
if [[ "$r" == *"amcheck"* || "$r" == *"does not exist"* ]]; then
  psql_as "$DST" postgres "$ADMIN_PASS" "$APP_DB" "create extension if not exists amcheck" >/dev/null 2>&1
  r="$(psql_as "$DST" postgres "$ADMIN_PASS" "$APP_DB" "select bt_index_check('items_name_idx')" 2>&1)"
fi
[ -z "$r" ] \
  && pass "destination: amcheck finds the index consistent" \
  || fail "destination: amcheck: $r"

finish
