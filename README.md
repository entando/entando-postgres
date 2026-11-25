# entando-postgres

PostgreSQL container images used by the Entando platform, published as multi-architecture images
(`linux/amd64`, `linux/arm64`):

| Image | Base |
|---|---|
| `entando/entando-postgres-ubi`   | Red Hat UBI 9 minimal |
| `entando/entando-postgres-rocky` | Rocky Linux 9 |

Docker and Kubernetes pull the right architecture automatically.

The PostgreSQL version is set at build time (see [Building](#building)). To check the version of an image:

```
docker run --rm --entrypoint /usr/pgsql-18/bin/postgres entando/entando-postgres-ubi:<tag> --version
```

## Running

```
docker run -d --name entando-postgres -p 5432:5432 \
  -e POSTGRESQL_USER=app \
  -e POSTGRESQL_PASSWORD=change-me \
  -e POSTGRESQL_DATABASE=appdb \
  -e POSTGRESQL_ADMIN_PASSWORD=change-me-too \
  -v entando-pgdata:/var/lib/pgsql \
  entando/entando-postgres-ubi:<tag>
```

The first start initializes the database; the server is ready when `docker exec entando-postgres /usr/libexec/check-container`
succeeds. Then connect with any client, e.g. `psql -h localhost -U app appdb`.

## Configuration

### Environment variables

The variables are read **only on the first start**, when the database is initialized. Changing them later has no
effect: change users and passwords with SQL (`ALTER USER ...`) instead.

| Variable | Required | Description |
|---|---|---|
| `POSTGRESQL_USER` | yes | Application user to create |
| `POSTGRESQL_PASSWORD` | yes | Password of the application user |
| `POSTGRESQL_DATABASE` | yes | Database to create, owned by the application user |
| `POSTGRESQL_ADMIN_PASSWORD` | no | Password of the `postgres` superuser. Without it, the superuser can't log in remotely |

Values must not contain single (`'`) or double (`"`) quotes. A `"` (or a `'` in the admin password) is rejected at
startup, but a `'` in the user name or password lets the container start **without** the application user or database,
and since the database is then marked as initialized, it is not retried: start again from an empty volume.

### Image contract

| Item | Value |
|---|---|
| Port | `5432` |
| User | UID `26` (`postgres`), primary group `26`, also a member of group `0` (root) |
| Data directory (`PGDATA`) | `/var/lib/pgsql/data/userdata` |
| Encoding / locale | `UTF8` / `en_US.utf8` |
| Readiness probe | `/usr/libexec/check-container` |
| Liveness probe | `/usr/libexec/check-container --live` |
| Remote authentication | Password (`md5` rule), IPv4 clients only |

### Persistent data

- **Docker / Podman**: mount the volume on **`/var/lib/pgsql`**, as in the example above.
  - Don't mount `/var/lib/pgsql/data` on plain Docker: that directory doesn't exist in the image, so the volume is
    created owned by root and the initialization fails with "Permission denied".
  - A host directory must be writable by UID 26:
    ```
    mkdir pgdata && sudo chown 26:0 pgdata
    docker run ... -v "$PWD/pgdata:/var/lib/pgsql" entando/entando-postgres-ubi:<tag>
    ```
    On SELinux hosts add `:Z` to the volume (`-v "$PWD/pgdata:/var/lib/pgsql:Z"`).
- **Kubernetes / OpenShift**: the Entando operator mounts the volume on `/var/lib/pgsql/data`. That directory is
  writable only if the pod has a matching `fsGroup`: the operator sets `fsGroup: 26` when it runs with
  `ENTANDO_REQUIRES_FILESYSTEM_GROUP_OVERRIDE=true`.

## Upgrades and migrations

- **PostgreSQL 14 → 18 on Kubernetes**: use `upgrade-pg14-to-pg18.sh`. It takes a logical backup (`pg_dumpall`)
  and restores it into a fresh PostgreSQL 18 instance, **with downtime**. Check the configuration section at the top
  of the script (namespace, deployment, PVC, image) before running it.
- **Changing CPU architecture** (e.g. moving from amd64 to arm64 nodes): dump with `pg_dumpall` and restore into a
  new instance. **Don't** reuse the existing data volume on a different architecture. `tests/cross-arch-restore.sh`
  tests exactly this path.

## Known limitations

- **Random UIDs are not supported yet.** If the container runs with a UID other than 26 (e.g. OpenShift `restricted`
  SCC), the initialization fails.
- **Connections from inside the container skip the password check.** The default `trust` rules created by `initdb`
  are kept for the Unix socket and `127.0.0.1`; only remote connections require a password.

## Building

```
docker build -f Dockerfile.ubi9 -t <image:tag> .
docker build -f Dockerfile.rocky9 -t <image:tag> .
```

The Dockerfiles are architecture-agnostic: the same definition builds on `linux/amd64` and `linux/arm64`.
Building several platforms at once needs a buildx builder that supports them (on an amd64 host, QEMU for arm64):

```
docker run --privileged --rm tonistiigi/binfmt --install arm64   # once per host, only for emulation
docker buildx create --name multiarch --use
docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.ubi9 -t <image:tag> --push .
```

### Build arguments

| Argument | Default | Description |
|---|---|---|
| `PG_MAJOR` | `18` | PostgreSQL major version |
| `PG_VERSION` | `18.1` | Exact PostgreSQL version; the build fails if it isn't available |
| `PG_REPO_BASE` | `https://yum-archive.postgresql.org` | PGDG repository the packages come from |
| `PG_REPO_DIST` | `rhel-9.7` | Repository distribution directory |

The PGDG main repository only keeps the latest minor release, so by default packages come from the PGDG archive,
where every minor stays available for both architectures. To build the latest minor from the main repository
instead:

```
docker build -f Dockerfile.ubi9 \
  --build-arg PG_VERSION=<latest-minor> \
  --build-arg PG_REPO_BASE=https://download.postgresql.org/pub/repos/yum \
  --build-arg PG_REPO_DIST=rhel-9 \
  -t <image:tag> .
```

Changing `PG_MAJOR` also requires updating the `/usr/pgsql-18` paths in the Dockerfiles (`CMD`),
`docker-entrypoint.sh` and `check-container`.

## Testing

The smoke tests in `tests/` run in CI for every image and every platform, before publication:

```
# one image on one platform (non-native platforms need QEMU/binfmt)
tests/smoke-test.sh <image> linux/amd64

# cross-architecture migration: pg_dumpall on one platform, restore on another
tests/cross-arch-restore.sh <srcImage> linux/amd64 <dstImage> linux/arm64
```
