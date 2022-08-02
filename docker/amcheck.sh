#!/bin/bash

for DBNAME in $(psql -q -A -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
    echo "Database: ${DBNAME}"
    psql -f /tmp/amcheck.sql -v 'ON_ERROR_STOP=1' ${DBNAME} && EXIT_STATUS=$? || EXIT_STATUS=$?
    if [ "${EXIT_STATUS}" -ne 0 ]; then
        echo "amcheck failed on DB: ${DBNAME}" >&2
        exit 125
    fi
done
