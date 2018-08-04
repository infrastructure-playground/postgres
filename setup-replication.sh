#!/bin/bash

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

file_env 'POSTGRES_INITDB_ARGS'
file_env 'POSTGRES_PASSWORD'
file_env 'POSTGRES_USER' 'postgres'
file_env 'POSTGRES_DB' "$POSTGRES_USER"
file_env 'REPLICATE_FROM'

echo "===SETUP RELICATION===="
echo "$REPLICATE_FROM"

if [ "x$REPLICATE_FROM" == "x" ]; then

cat >> ${PGDATA}/postgresql.conf <<EOF
wal_level = hot_standby
max_wal_senders = $PG_MAX_WAL_SENDERS
wal_keep_segments = $PG_WAL_KEEP_SEGMENTS
hot_standby = on
max_connections = 300
shared_buffers = $[$(free|awk '/^Mem:/{print $2}') / 4]kB
work_mem = 24MB
log_statement = 'all'
max_worker_processes = 35
max_parallel_workers_per_gather = 30
log_duration = on
log_line_prefix = '{"Time":[%t], Host:%h} '
EOF

## To log only queries at least one second
# log_statement = 'none'
# log_min_duration_statement = 1000

else

cat > ${PGDATA}/recovery.conf <<EOF
standby_mode = on
primary_conninfo = 'host=${REPLICATE_FROM} port=5432 user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}'
trigger_file = '/tmp/touch_me_to_promote_to_me_master'
EOF
chown postgres ${PGDATA}/recovery.conf
chmod 600 ${PGDATA}/recovery.conf

fi