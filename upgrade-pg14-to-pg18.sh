#!/bin/bash
#
# PostgreSQL 14 → 18.1 Migration Script for Entando Kubernetes Deployment
#
# This script performs a full logical backup (pg_dumpall) from the running PG 14
# container, recreates the PVC with a fresh PG 18.1 instance, and restores the data.
#
# IMPORTANT: This causes downtime. The database will be unavailable during migration.
#
# Prerequisites:
#   - kubectl installed
#   - The new image (entando/entando-postgres-rocky:18.1) must be accessible from the cluster
#   - Sufficient local disk space for the dump file
#
# Usage:
#   chmod +x upgrade-pg14-to-pg18.sh
#   ./upgrade-pg14-to-pg18.sh
#   ./upgrade-pg14-to-pg18.sh --kubeconfig /path/to/kubeconfig --context my-context
#

set -euo pipefail

# ============================================================================
# KUBECTL SETTINGS — override via CLI args or environment variables
# ============================================================================
KUBECONFIG_FILE="${KUBECONFIG:-}"
KUBECONTEXT="${KUBECONTEXT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
        --context)    KUBECONTEXT="$2"; shift 2 ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

KUBECTL="kubectl"
[ -n "$KUBECONFIG_FILE" ] && KUBECTL="$KUBECTL --kubeconfig $KUBECONFIG_FILE"
[ -n "$KUBECONTEXT" ]     && KUBECTL="$KUBECTL --context $KUBECONTEXT"

# ============================================================================
# CONFIGURATION — adjust these if your deployment differs
# ============================================================================
NAMESPACE="entando"
DEPLOYMENT="default-postgresql-dbms-in-namespace-deployment"
CONTAINER="db-container"
PVC_NAME="default-postgresql-dbms-in-namespace-db-pvc"
NEW_IMAGE="entando/entando-postgres-rocky:18.1"
BACKUP_FILE="pg14_backup_$(date +%Y%m%d_%H%M%S).sql"

# Derived from the deployment env vars
DB_NAME="default_postgresql_dbms_in_namespace_db"
DB_USER="default_postgresql_dbms_in_namespace_db_user"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
log() { echo "[$(date '+%H:%M:%S')] $*"; }

fail() { echo "[ERROR] $*" >&2; exit 1; }

# Prints a snapshot of all databases, schemas and table counts
# Usage: db_snapshot <pod_name> <pg_bin_path>
db_snapshot() {
    local pod="$1"
    local pg_bin="$2"
    log "--- Database snapshot ---"
    $KUBECTL exec -n "$NAMESPACE" "$pod" -c "$CONTAINER" -- \
        "$pg_bin/psql" -U postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" \
        2>/dev/null | while IFS= read -r dbname; do
        [ -z "$dbname" ] && continue
        log "  Database: $dbname"
        $KUBECTL exec -n "$NAMESPACE" "$pod" -c "$CONTAINER" -- \
            "$pg_bin/psql" -U postgres -d "$dbname" -t -A -c \
            "SELECT table_schema, count(*) FROM information_schema.tables \
             WHERE table_schema NOT IN ('information_schema', 'pg_catalog') \
             GROUP BY table_schema ORDER BY table_schema;" \
            2>/dev/null | while IFS='|' read -r schema count; do
            [ -z "$schema" ] && continue
            log "    schema: $schema  tables: $count"
        done
    done
    log "--- End snapshot ---"
}

wait_for_pod_ready() {
    local timeout=300
    local interval=5
    local elapsed=0
    log "Waiting for pod to become ready (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local ready
        ready=$($KUBECTL get pods -n "$NAMESPACE" -l "entando.org/deployment=$( echo "$DEPLOYMENT" | sed 's/-deployment$//' )" \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        if [ "$ready" = "true" ]; then
            log "Pod is ready."
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    fail "Timed out waiting for pod to become ready"
}

get_pod_name() {
    $KUBECTL get pods -n "$NAMESPACE" \
        -l "entando.org/deployment=$(echo "$DEPLOYMENT" | sed 's/-deployment$//')" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
log "=== PostgreSQL 14 → 18.1 Migration ==="
log ""
log "Namespace:   $NAMESPACE"
log "Deployment:  $DEPLOYMENT"
log "PVC:         $PVC_NAME"
log "New image:   $NEW_IMAGE"
log "Backup file: $BACKUP_FILE"
log ""

# Verify kubectl connectivity and show context
CURRENT_CONTEXT=$($KUBECTL config current-context 2>/dev/null || echo "unknown")
log "Kube context: $CURRENT_CONTEXT"
[ -n "$KUBECONFIG_FILE" ] && log "Kubeconfig:  $KUBECONFIG_FILE"
log ""

# Verify deployment exists and is running
$KUBECTL get deployment "$DEPLOYMENT" -n "$NAMESPACE" > /dev/null 2>&1 \
    || fail "Deployment '$DEPLOYMENT' not found in namespace '$NAMESPACE'"

POD_NAME=$(get_pod_name)
[ -n "$POD_NAME" ] || fail "No running pod found for deployment"
log "Current pod: $POD_NAME"

# Verify current image is PG 14
CURRENT_IMAGE=$($KUBECTL get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
log "Current image: $CURRENT_IMAGE"

echo ""
echo "============================================================"
echo "  WARNING: This will cause database downtime!"
echo "  A full backup will be taken before any destructive action."
echo "============================================================"
echo ""
read -r -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { log "Aborted."; exit 0; }

# ============================================================================
# STEP 1: BACKUP (pg_dumpall from the running PG 14 container)
# ============================================================================
log ""
log "=== STEP 1/6: Backing up all databases with pg_dumpall ==="

log ""
log "State BEFORE migration (PG 14):"
db_snapshot "$POD_NAME" "/usr/pgsql-14/bin"
log ""

$KUBECTL exec -n "$NAMESPACE" "$POD_NAME" -c "$CONTAINER" -- \
    /usr/pgsql-14/bin/pg_dumpall -U postgres --clean --if-exists \
    > "$BACKUP_FILE"

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log "Backup complete: $BACKUP_FILE ($BACKUP_SIZE)"

# Sanity check: backup must not be empty
[ -s "$BACKUP_FILE" ] || fail "Backup file is empty — aborting"

# Verify backup contains expected database
grep -q "CREATE DATABASE.*${DB_NAME}" "$BACKUP_FILE" \
    || log "WARNING: Database '${DB_NAME}' not found in dump — it may be empty or use a different name"

# ============================================================================
# STEP 2: SCALE DOWN
# ============================================================================
log ""
log "=== STEP 2/6: Scaling down deployment ==="

$KUBECTL scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
$KUBECTL rollout status deployment "$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s
log "Deployment scaled to 0"

# ============================================================================
# STEP 3: DELETE AND RECREATE PVC
# ============================================================================
log ""
log "=== STEP 3/6: Recreating PVC ==="

# Capture current PVC spec before deletion
STORAGE_CLASS=$($KUBECTL get pvc "$PVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
STORAGE_SIZE=$($KUBECTL get pvc "$PVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.resources.requests.storage}')
ACCESS_MODES=$($KUBECTL get pvc "$PVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.accessModes[0]}')

log "Current PVC: storageClass=$STORAGE_CLASS, size=$STORAGE_SIZE, accessMode=$ACCESS_MODES"

# Delete old PVC
$KUBECTL delete pvc "$PVC_NAME" -n "$NAMESPACE" --wait=true
log "Old PVC deleted"

# Recreate PVC with same specs
STORAGE_CLASS_FIELD=""
if [ -n "$STORAGE_CLASS" ]; then
    STORAGE_CLASS_FIELD="storageClassName: $STORAGE_CLASS"
fi

$KUBECTL apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  ${STORAGE_CLASS_FIELD}
  accessModes:
    - ${ACCESS_MODES}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF

log "New PVC created"

# ============================================================================
# STEP 4: UPDATE IMAGE AND SCALE UP
# ============================================================================
log ""
log "=== STEP 4/6: Updating image to PG 18.1 and scaling up ==="

$KUBECTL set image deployment/"$DEPLOYMENT" -n "$NAMESPACE" \
    "$CONTAINER=$NEW_IMAGE"

$KUBECTL scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1

log "Waiting for PG 18.1 pod to initialize..."
sleep 10
wait_for_pod_ready

NEW_POD=$(get_pod_name)
log "New pod running: $NEW_POD"

# ============================================================================
# STEP 5: RESTORE
# ============================================================================
log ""
log "=== STEP 5/6: Restoring backup into PG 18.1 ==="

# The entrypoint already created the database and user from env vars.
# pg_dumpall --clean --if-exists will drop and recreate objects.
# We pipe through kubectl exec. Some DROP errors are expected (roles/DBs
# created by entrypoint) so we don't use -e for this step.

$KUBECTL exec -i -n "$NAMESPACE" "$NEW_POD" -c "$CONTAINER" -- \
    /usr/pgsql-18/bin/psql -U postgres -f - < "$BACKUP_FILE" \
    2>&1 | grep -i "error" | grep -vi "does not exist, skipping" || true

log "Restore complete"

# ============================================================================
# STEP 6: VERIFY
# ============================================================================
log ""
log "=== STEP 6/6: Verification ==="

# Check PG version
PG_VERSION=$($KUBECTL exec -n "$NAMESPACE" "$NEW_POD" -c "$CONTAINER" -- \
    /usr/pgsql-18/bin/psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1)
log "PostgreSQL version: $PG_VERSION"

# Check database exists
DB_EXISTS=$($KUBECTL exec -n "$NAMESPACE" "$NEW_POD" -c "$CONTAINER" -- \
    /usr/pgsql-18/bin/psql -U postgres -t -c \
    "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" 2>/dev/null | tr -d '[:space:]')

if [ "$DB_EXISTS" = "1" ]; then
    log "Database '${DB_NAME}' exists — OK"
else
    log "WARNING: Database '${DB_NAME}' not found after restore!"
fi

# Check user exists
USER_EXISTS=$($KUBECTL exec -n "$NAMESPACE" "$NEW_POD" -c "$CONTAINER" -- \
    /usr/pgsql-18/bin/psql -U postgres -t -c \
    "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}';" 2>/dev/null | tr -d '[:space:]')

if [ "$USER_EXISTS" = "1" ]; then
    log "User '${DB_USER}' exists — OK"
else
    log "WARNING: User '${DB_USER}' not found after restore!"
fi

log ""
log "State AFTER migration (PG 18.1):"
db_snapshot "$NEW_POD" "/usr/pgsql-18/bin"

log ""
log "=== Migration complete ==="
log ""
log "Backup file kept at: $(pwd)/$BACKUP_FILE"
log "You can delete it once you've verified everything works."
log ""
log "If something went wrong, you can restore from the backup file"
log "by scaling down, recreating the PVC, starting with the OLD image,"
log "and running:"
log "  kubectl exec -i ... -- /usr/pgsql-14/bin/psql -U postgres -f - < $BACKUP_FILE"