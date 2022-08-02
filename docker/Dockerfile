ARG DOCKER_BASE_IMAGE
FROM ${DOCKER_BASE_IMAGE}

MAINTAINER Sergey Syreskin <ssireskin@gmail.com>

ARG PG_MAJOR
ENV PG_MAJOR=${PG_MAJOR}
ARG POSTGIS_MAJOR
ENV POSTGIS_MAJOR=${POSTGIS_MAJOR}
ARG TSDB_MAJOR
ENV TSDB_MAJOR=${TSDB_MAJOR}
ARG WALG_VER
ENV WALG_VER=${WALG_VER}
ARG POSTGRES_SUPERUSER_USERNAME
ENV POSTGRES_SUPERUSER_USERNAME=${POSTGRES_SUPERUSER_USERNAME}

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -y ca-certificates curl gnupg lsb-release \
    && curl -s -L https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && curl -s -L https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add - \
    && echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" > /etc/apt/sources.list.d/timescaledb.list \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y postgresql-common \
    && sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf \
    && apt-get install --no-install-recommends -y \
        postgresql-$PG_MAJOR \
        postgresql-client-$PG_MAJOR \
        postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
        postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR-scripts \
        timescaledb-$TSDB_MAJOR-postgresql-$PG_MAJOR \
        timescaledb-tools \
        timescaledb-toolkit-postgresql-$PG_MAJOR \
    && apt-get install -y python3-pip python3-psycopg2 \
    && apt-get install -y vim net-tools iputils-ping procps \
    && pip install patroni[consul] python-consul \
    && rm -rf /var/lib/apt/lists/*

# Patroni post-init script which executes additional initialization scripts from $POSTGRESQL_INITSCRIPTS_DIR
ENV POSTGRESQL_INITSCRIPTS_DIR /docker-entrypoint-initdb.d
ENV POSTGRES_USER ${POSTGRES_SUPERUSER_USERNAME}
ENV POSTGRES_DB ${POSTGRES_SUPERUSER_USERNAME}
COPY ./docker-entrypoint-initdb.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint-initdb.sh

# PostGIS - https://github.com/postgis/docker-postgis
RUN mkdir -p $POSTGRESQL_INITSCRIPTS_DIR
COPY ./initdb-postgis.sh $POSTGRESQL_INITSCRIPTS_DIR/10_postgis.sh
COPY ./update-postgis.sh /usr/local/bin
RUN chmod +x /usr/local/bin/update-postgis.sh

# TimescaleDB - https://github.com/timescale/timescaledb-docker-ha
COPY initdb-timescale.sh $POSTGRESQL_INITSCRIPTS_DIR/20_timescaledb.sh

# WAL-G
RUN curl -L https://github.com/wal-g/wal-g/releases/download/v$WALG_VER/wal-g-pg-ubuntu-20.04-amd64.tar.gz > /tmp/walg.tar.gz \
    && tar -zxvf /tmp/walg.tar.gz \
    && mv wal-g-* /usr/local/bin/wal-g \
    && chmod +x /usr/local/bin/wal-g \
    && rm /tmp/walg.tar.gz

# Patroni
ENV TERM xterm
ENV PATH /usr/lib/postgresql/$PG_MAJOR/bin:$PATH
ENV PGDATA /var/lib/postgresql/data
ENV LANGUAGE "en_US.UTF-8"
ENV LANG "en_US.UTF-8"
ENV LC_ALL "en_US.UTF-8"
RUN localedef -v -c -i en_US -f UTF-8 en_US.UTF-8 || true

# PostgreSQL data major version upgrade script
COPY create-patroni-users.sql.j2 $POSTGRESQL_INITSCRIPTS_DIR/30_create-patroni-users.sql.j2
COPY upgrade-postgres.sh /usr/local/bin
RUN chmod +x /usr/local/bin/upgrade-postgres.sh

# Post-restore database index checking scripts
COPY amcheck.sql /tmp
COPY amcheck.sh /tmp
RUN chown postgres:postgres /tmp/amcheck.sql /tmp/amcheck.sh
RUN chmod +x /tmp/amcheck.sh

# Docker entrypoint
USER postgres
CMD ["/usr/local/bin/patroni", "/var/lib/postgresql/patroni.yml"]
