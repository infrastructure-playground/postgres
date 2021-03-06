#!/usr/bin/env bash
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(< "${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

if [ "${1:0:1}" = '-' ]; then
    set -- postgres "$@"
fi

# allow the container to be started with `--user`
if [ "$1" = 'postgres' ] && [ "$(id -u)" = '0' ]; then
    mkdir -p "$PGDATA"
    chown -R postgres "$PGDATA"
    chmod 700 "$PGDATA"

    mkdir -p /var/run/postgresql
    chown -R postgres /var/run/postgresql
    chmod 775 /var/run/postgresql

    # Create the transaction log directory before initdb is run (below) so the directory is owned by the correct user
    if [ "$POSTGRES_INITDB_XLOGDIR" ]; then
        mkdir -p "$POSTGRES_INITDB_XLOGDIR"
        chown -R postgres "$POSTGRES_INITDB_XLOGDIR"
        chmod 700 "$POSTGRES_INITDB_XLOGDIR"
    fi

    exec gosu postgres "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'postgres' ]; then
    mkdir -p "$PGDATA"
    chown -R "$(id -u)" "$PGDATA" 2>/dev/null || :
    chmod 700 "$PGDATA" 2>/dev/null || :

    # look specifically for PG_VERSION, as it is expected in the DB dir
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        file_env 'POSTGRES_INITDB_ARGS'
        file_env 'POSTGRES_PASSWORD'
        file_env 'POSTGRES_USER' 'postgres'
        file_env 'POSTGRES_DB' "$POSTGRES_USER"
        file_env 'REPLICATE_FROM'
        file_env 'COPY_FROM'

        if [ "x$REPLICATE_FROM" == "x" ]; then
            if [ "x$COPY_FROM" == "x" ]; then
                if [ "$POSTGRES_INITDB_XLOGDIR" ]; then
                export POSTGRES_INITDB_ARGS="$POSTGRES_INITDB_ARGS --xlogdir $POSTGRES_INITDB_XLOGDIR"
                fi
                eval "initdb --username=postgres $POSTGRES_INITDB_ARGS"
            else
                export PGPASSWORD=${POSTGRES_PASSWORD}
                until ping -c 1 -W 1 ${COPY_FROM}
                do
                    echo "Waiting for master to ping..."
                    sleep 1s
                done
                until pg_basebackup -h ${COPY_FROM} -D ${PGDATA} -U ${POSTGRES_USER} -vP -w -x
                do
                    echo "Waiting for master to connect..."
                    sleep 1s
                done
            fi
        else
            export PGPASSWORD=${POSTGRES_PASSWORD}
            until ping -c 1 -W 1 ${REPLICATE_FROM}
            do
                echo "Waiting for master to ping..."
                sleep 1s
            done
            until pg_basebackup -h ${REPLICATE_FROM} -D ${PGDATA} -U ${POSTGRES_USER} -vP -w
            do
                echo "Waiting for master to connect..."
                sleep 1s
            done
        fi

        # check password first so we can output the warning before postgres
        # messes it up
        if [ "$POSTGRES_PASSWORD" ]; then
            pass="PASSWORD '$POSTGRES_PASSWORD'"
            authMethod=md5
        else
            # The - option suppresses leading tabs but *not* spaces. :)
            cat >&2 <<-'EOWARN'
                ****************************************************
                WARNING: No password has been set for the database.
                         This will allow anyone with access to the
                         Postgres port to access your database. In
                         Docker's default configuration, this is
                         effectively any other container on the same
                         system.
                         Use "-e POSTGRES_PASSWORD=password" to set
                         it in "docker run".
                ****************************************************
            EOWARN

            pass=
            authMethod=trust
        fi

        {
            echo
            echo "host all all all $authMethod"
        } >> "$PGDATA/pg_hba.conf"


        if [ "x$REPLICATE_FROM" == "x" ] && [ "x$COPY_FROM" == "x" ]; then
            { echo; echo "host replication all 0.0.0.0/0 $authMethod"; } | tee -a "$PGDATA/pg_hba.conf"  > /dev/null
            { echo; echo "host all all 0.0.0.0/0 $authMethod"; } | tee -a "$PGDATA/pg_hba.conf" > /dev/null
            # internal start of server in order to allow set-up using psql-client
            # does not listen on external TCP/IP and waits until start finishes
            PGUSER="${PGUSER:-postgres}" \
            pg_ctl -D "$PGDATA" \
                -o "-c listen_addresses='localhost'" \
                -w start
            psql=( psql -v ON_ERROR_STOP=1 )

            if [ "$POSTGRES_DB" != 'postgres' ]; then
                "${psql[@]}" --username postgres <<-EOSQL
                    CREATE DATABASE "$POSTGRES_DB" ;
                EOSQL
                echo
            fi

            if [ "$POSTGRES_USER" = 'postgres' ]; then
                op='ALTER'
            else
                op='CREATE'
            fi
            "${psql[@]}" --username postgres <<-EOSQL
                $op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
            EOSQL
            echo
        fi

        psql+=( --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" )

        echo
        for f in /docker-entrypoint-initdb.d/*; do
            case "$f" in
                *.sh)     echo "$0: running $f"; . "$f" ;;
                *.sql)    echo "$0: running $f"; "${psql[@]}" -f "$f"; echo ;;
                *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
                *)        echo "$0: ignoring $f" ;;
            esac
            echo
        done

    if [ "x$REPLICATE_FROM" == "x" ] && [ "x$COPY_FROM" == "x" ]; then
        PGUSER="${PGUSER:-postgres}" \
        pg_ctl -D "$PGDATA" -m fast -w stop
    fi

        echo
        echo 'PostgreSQL init process complete; ready for start up.'
        echo
    fi
fi

exec "$@"