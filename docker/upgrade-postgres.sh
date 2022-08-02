#!/bin/bash

#
# Move PostgreSQL data files from /var/lib/postgresql to /var/lib/postgresql/data if required.
# Upgrade PostgreSQL major version if it is not matching the docker container's $PG_MAJOR.
#

# Sanity checks
if [ -z "$PG_MAJOR" ]; then
    echo "ERROR: environment variable PG_MAJOR must be defined" >&2
    exit 1
fi
if [ $(id -u) != 0 ]; then
    echo "ERROR: this script must be run as root" >&2
    exit 1
fi

# Find PostgreSQL data directory in the docker volume
if [ -f /var/lib/postgresql/data/PG_VERSION ]; then
    existing_pgdata=/var/lib/postgresql/data
elif [ -f /var/lib/postgresql/PG_VERSION ]; then
    echo "Moving existing PostgreSQL data to /var/lib/postgresql/data directory"
    mkdir -p /var/lib/postgresql/data \
    && cd /var/lib/postgresql \
    && ls -a |grep -vE '^(data|.|..)$' |xargs mv -t data \
    && chmod 0700 /var/lib/postgresql/data
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to move existing PostgreSQL data to /var/lib/postgresql/data directory" >&2
        exit 1
    fi
    existing_pgdata=/var/lib/postgresql/data
fi

echo "Setting /var/lib/postgresql ownership to postgres user"
cd /var/lib/postgresql \
&& chown -R postgres:postgres /var/lib/postgresql
if [ $? -ne 0 ]; then
    echo "ERROR: failed to set /var/lib/postgresql ownership to postgres user" >&2
    exit 1
fi

# Check if PostgreSQL major version in the docker volume is different 
# from the docker container PostgreSQL major version, then PostgreSQL 
# upgrade is required
if [ "$existing_pgdata" != "" ]; then
    existing_pg_major=$(cat $existing_pgdata/PG_VERSION)
    if [ "$existing_pg_major" != $PG_MAJOR ]; then
        echo "PostgreSQL version in the docker volume is $existing_pg_major, PostgreSQL version in the docker container is $PG_MAJOR - PostgreSQL database upgrade is required"
        upgrade_required=1
    fi
fi

# Upgrade PostgreSQL database in the docker volume
if [ "$upgrade_required" == "1" ]; then
    echo "Installing PostgreSQL $existing_pg_major and extensions"
    apt-get update \
    && apt-get install --no-install-recommends -y \
        sudo \
        postgresql-$existing_pg_major \
        "timescaledb-[0-9\.]+-postgresql-$existing_pg_major" \
        "postgresql-$existing_pg_major-postgis-[0-9\.]+"
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to install the required version of PostgreSQL or extensions" >&2
        exit 1
    fi

    echo "Starting the old PostgreSQL $existing_pg_major server"
    sudo -u postgres /usr/lib/postgresql/$existing_pg_major/bin/pg_ctl -D $existing_pgdata start
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to start the old PostgreSQL $existing_pg_major server" >&2
        exit 1
    fi

    # Upgrade PostgreSQL extensions in all databases
    for db in $(psql -U postgres -t -c 'SELECT datname FROM pg_database'); do 
        echo "Upgrading PostgreSQL extensions in database '$db'"
        psql -U postgres -d $db -c "ALTER EXTENSION postgis UPDATE; SELECT postgis_extensions_upgrade()" || true
        psql -U postgres -d $db -X -c "ALTER EXTENSION timescaledb UPDATE" || true
    done

    echo "Stopping the old PostgreSQL server"
    sudo -u postgres /usr/lib/postgresql/$existing_pg_major/bin/pg_ctl -D $existing_pgdata stop
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to stop the old PostgreSQL $existing_pg_major server" >&2
        exit 1
    fi

    echo "Enabling data checksums in the old PostgreSQL database"
    sudo -u postgres /usr/lib/postgresql/$existing_pg_major/bin/pg_checksums -D $existing_pgdata --enable --progress
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to enable data checksums in the old PostgreSQL database" >&2
        exit 1
    fi

    echo "Creating the new PostgreSQL database directory under a temporary name"
    new_pgdata_tmp=$(mktemp -d /var/lib/postgresql/data.XXXXXX)
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to create the new PostgreSQL database directory $new_pgdata_tmp" >&2
        exit 1
    fi
    chown postgres:postgres $new_pgdata_tmp

    echo "Initializing the new PostgreSQL $PG_MAJOR database"
    sudo -u postgres /usr/lib/postgresql/$PG_MAJOR/bin/initdb --encoding=UTF8 --data-checksums $new_pgdata_tmp
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to initialize the new PostgreSQL $PG_MAJOR database" >&2
        exit 1
    fi
    echo "shared_preload_libraries = 'timescaledb'" >> $new_pgdata_tmp/postgresql.conf 

    echo "Checking if the old PostgreSQL $existing_pg_major data can be migrated to the new PostgreSQL $PG_MAJOR database"
    sudo -u postgres /usr/lib/postgresql/$PG_MAJOR/bin/pg_upgrade \
        --check \
        -U postgres \
        -b /usr/lib/postgresql/$existing_pg_major/bin \
        -B /usr/lib/postgresql/$PG_MAJOR/bin \
        -d $existing_pgdata \
        -D $new_pgdata_tmp
    if [ $? -ne 0 ]; then
        echo "ERROR: PostgreSQL data migration check failed - please upgrade manually" >&2
        exit 1
    fi

    echo "Migrating the old PostgreSQL $existing_pg_major data to the new PostgreSQL $PG_MAJOR database"
    sudo -u postgres /usr/lib/postgresql/$PG_MAJOR/bin/pg_upgrade \
        -U postgres \
        -b /usr/lib/postgresql/$existing_pg_major/bin \
        -B /usr/lib/postgresql/$PG_MAJOR/bin \
        -d $existing_pgdata \
        -D $new_pgdata_tmp
    if [ $? -ne 0 ]; then
        echo "ERROR: PostgreSQL data migration failed - please upgrade manually" >&2
        exit 1
    fi

    echo "Replacing the old PostgreSQL data with the new data in /var/lib/postgresql/data directory"
    rm -rf $existing_pgdata
    mv $new_pgdata_tmp /var/lib/postgresql/data
fi

# Run PostgreSQL post-init scripts to install extensions and create users
if [ "$existing_pgdata" != "" ]; then
    # Install sudo if it was not installed
    if [ "$upgrade_required" != "1" ]; then
        echo "Installing sudo"
        apt update \
        && apt install --no-install-recommends -y sudo 
        if [ $? -ne 0 ]; then
            echo "ERROR: failed to install sudo" >&2
            exit 1
        fi
    fi

    echo "Starting PostgreSQL $PG_MAJOR server"
    sudo -u postgres /usr/lib/postgresql/$PG_MAJOR/bin/pg_ctl -D /var/lib/postgresql/data start
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to start PostgreSQL $PG_MAJOR server" >&2
        exit 1
    fi

    /usr/local/bin/docker-entrypoint-initdb.sh

    echo "Stopping PostgreSQL $PG_MAJOR server"
    sudo -u postgres /usr/lib/postgresql/$PG_MAJOR/bin/pg_ctl -D /var/lib/postgresql/data stop
    if [ $? -ne 0 ]; then
        echo "ERROR: failed to stop PostgreSQL $PG_MAJOR server" >&2
        exit 1
    fi
fi
