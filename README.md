# PostgreSQL 18.1 SQL Database Server container image
This container image includes PostgreSQL 18.1 SQL database server for general usage. Users can choose between RHEL(ubi9) and Rocky based images.

## Quick Start
* Clone or download this repository
* Go inside of directory,  `cd entando-postgres`
* Run this command `docker build -f Dockerfile.rocky9 -t (image:tag) .`
* Run this command `docker build -f Dockerfile.ubi9 -t (image:tag) .`

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
