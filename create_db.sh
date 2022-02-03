#!/usr/bin/env bash
set -e

POSTGRES="psql --username ${POSTGRES_USER}"

echo "Creating database: ${POSTGRES_DATABASE}"

$POSTGRES <<EOSQL
CREATE DATABASE ${POSTGRES_DATABASE} OWNER ${POSTGRES_USER};
EOSQL