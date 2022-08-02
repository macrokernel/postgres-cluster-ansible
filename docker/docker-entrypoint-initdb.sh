#!/bin/bash

env

psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password )

# Templating only works when the script is executed as root
if [[ $(id -u) == 0 ]] && [[ -d "$POSTGRESQL_INITSCRIPTS_DIR" ]] && [[ -n $(find "$POSTGRESQL_INITSCRIPTS_DIR/" -type f -regex ".*\.\(j2\)") ]]; then
    echo "Templating DB initialization scripts from $POSTGRESQL_INITSCRIPTS_DIR"
    find "$POSTGRESQL_INITSCRIPTS_DIR/" -type f -regex ".*\.\(j2\)" | sort | while read -r f; do
        templated=$(basename $f |sed 's|\.j2$||')
        cp $f /tmp/$templated
        for e in $(env); do
            k=$(echo "$e" |cut -d '=' -f1)
            v=$(echo "$e" |cut -d '=' -f2)
            sed -e "s|{{ $k }}|$v|g" -i /tmp/$templated
        done
        mv /tmp/$templated $POSTGRESQL_INITSCRIPTS_DIR
    done
fi

if [[ -d "$POSTGRESQL_INITSCRIPTS_DIR" ]] && [[ -n $(find "$POSTGRESQL_INITSCRIPTS_DIR/" -type f -regex ".*\.\(sh\|sql\|sql.gz\)") ]]; then
    echo "Loading DB initialization scripts from $POSTGRESQL_INITSCRIPTS_DIR"
    find "$POSTGRESQL_INITSCRIPTS_DIR/" -type f -regex ".*\.\(sh\|sql\|sql.gz\)" | sort | while read -r f; do
        case "$f" in
        *.sh)
            if [[ -x "$f" ]]; then
                echo "Executing $f"
                "$f"
            else
                echo "Sourcing $f"
                . "$f"
            fi
            ;;
        *.sql)
            echo "Executing $f"
            "${psql[@]}" < "$f"
            ;;
        *.sql.gz)
            echo "Executing $f"
            gunzip -c "$f" | "${psql[@]}"
            ;;
        *) echo "Ignoring $f" ;;
        esac
    done
fi
