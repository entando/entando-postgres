# PostgreSQL 18.1 SQL Database Server container image
This container image includes PostgreSQL 18.1 SQL database server for general usage. Users can choose between RHEL(ubi9) and Rocky based images.

## Quick Start
* Clone or download this repository
* Go inside of directory,  `cd entando-postgres`
* Run this command `docker build -f Dockerfile.rocky9 -t (image:tag) .`
* Run this command `docker build -f Dockerfile.ubi9 -t (image:tag) .`

The Dockerfiles are architecture-agnostic: PostgreSQL is installed by name from the PGDG repository, so the
same definition builds on `linux/amd64` and `linux/arm64`. To build for a specific platform (or several):

```
docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.ubi9 -t (image:tag) .
```

The PostgreSQL version is controlled by the `PG_MAJOR` / `PG_VERSION` build args (default `18` / `18.1`).
The PGDG main repository only keeps the latest minor release, so packages are installed from the PGDG archive
(`https://yum-archive.postgresql.org`), where every minor stays available for both architectures. The source is set by
`PG_REPO_BASE` / `PG_REPO_DIST`; e.g. to build the latest minor from the main repository:

```
docker build -f Dockerfile.ubi9 \
  --build-arg PG_VERSION=<latest-minor> \
  --build-arg PG_REPO_BASE=https://download.postgresql.org/pub/repos/yum \
  --build-arg PG_REPO_DIST=rhel-9 \
  -t (image:tag) .
```

The build fails explicitly if the requested version is not available.

## Environment variables and volumes
The image recognizes the following environment variables.

```
POSTGRESQL_ADMIN_PASSWORD: The password of the postgres user
POSTGRESQL_USER:           Standard user account to be created
POSTGRESQL_PASSWORD:       Password for the user account
POSTGRESQL_DATABASE:       Database for the user account (automatically created)
```

You can also set the following mount points by passing the `-v /host/dir:/container/dir:Z` flag to Docker.

* `/var/lib/pgsql/data`
PostgreSQL database directory

## Tests
Container smoke tests live in `tests/` and run in CI for every image and every platform before publication:

```
# one image on one platform (non-native platforms need QEMU/binfmt)
tests/smoke-test.sh <image> linux/amd64

# supported cross-architecture migration path: pg_dumpall on one platform, restore on another
tests/cross-arch-restore.sh <srcImage> linux/amd64 <dstImage> linux/arm64
```
