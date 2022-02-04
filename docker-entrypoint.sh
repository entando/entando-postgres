#!/bin/sh

PGCTL="/usr/pgsql-14/bin/pg_ctl"

if [ -f "$PGDATA/initialized" ]; then
  echo "Database already initialized" 1>&2
else
  # REQUIRED VARS CHECK
  [[ -z "${POSTGRESQL_DATABASE}" || "${POSTGRESQL_DATABASE}" == *'"'* ]] && {
    echo "POSTGRESQL_DATABASE is invalid or missing" 1>&2
    exit 1
  }

  [[ -z "${POSTGRESQL_USER}" || "${POSTGRESQL_USER}" == *'"'* ]] && {
    echo "POSTGRESQL_USER is invalid or missing" 1>&2
    exit 1
  }

  [[ -z "${POSTGRESQL_PASSWORD}" || "${POSTGRESQL_PASSWORD}" == *'"'* ]] && {
    echo "POSTGRESQL_PASSWORD is invalid or missing" 1>&2
    exit 1
  }

  [[ "${POSTGRESQL_ADMIN_PASSWORD}" == *"'"* ]] && {
    echo "POSTGRESQL_ADMIN_PASSWORD is invalid" 1>&2
    exit 1
  }

  # Before PostgreSQL can function correctly, the database cluster must be initialized:
  [ ! -d "$PGDATA" ] && /usr/pgsql-14/bin/initdb -D "$PGDATA"

  # internal start of server in order to allow set-up using psql-client
  # does not listen on external TCP/IP and waits until start finishes
  $PGCTL -D "$PGDATA" -o "-c listen_addresses='*'" -w start

  # CONFIGURATION CHANGES
  sed -i -e 's/logging_collector = on/logging_collector = off/g' -e "s/listen_address.*/listen_addresses='*'/g" "$PGDATA/postgresql.conf"
  echo "host all  all    0.0.0.0/0  md5" >> "$PGDATA/pg_hba.conf" && \
  echo "listen_addresses='*'" >> "$PGDATA/postgresql.conf"
  $PGCTL reload

  # CREATE USER OR ROLE
  psql -d postgres -c "CREATE USER \"${POSTGRESQL_USER}\" WITH PASSWORD '${POSTGRESQL_PASSWORD}';" 

  # CREATE DATABASE
  echo "Creating database: ${POSTGRESQL_DATABASE}"

  psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE \"${POSTGRESQL_DATABASE}\" OWNER '${POSTGRESQL_USER}';"
  if [ -n "$POSTGRESQL_ADMIN_PASSWORD" ]; then
    psql -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER postgres WITH ENCRYPTED PASSWORD '${POSTGRESQL_ADMIN_PASSWORD}';"
  fi

  # STOP SERVER
  $PGCTL -D "$PGDATA" -m fast -w stop
fi

touch "$PGDATA/initialized"

#..
exec "$@"
