#!/usr/bin/env bash
set -euo pipefail
cd /var/lib/pgsql

PGBIN="/usr/pgsql-${PG_VERSION}/bin"
PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
SERVICE="postgresql-${PG_VERSION}"

# initdb (checksums on: needed/useful for pg_rewind later)
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  PGSETUP_INITDB_OPTIONS="--data-checksums" "${PGBIN}/postgresql-${PG_VERSION}-setup" initdb
fi

# Drop-in config directory
grep -q "^include_dir" "${PGDATA}/postgresql.conf" || echo "include_dir = 'conf.d'" >> "${PGDATA}/postgresql.conf"
install -d -o postgres -g postgres -m 700 "${PGDATA}/conf.d"

cat > "${PGDATA}/conf.d/10-replication.conf" <<EOF
listen_addresses = '*'
port = ${PG_PORT}
password_encryption = 'scram-sha-256'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = '512MB'
wal_log_hints = on
hot_standby = on
hot_standby_feedback = on
EOF
if [ "${SYNC}" = "true" ]; then
  echo "synchronous_standby_names = 'FIRST 1 (${STANDBY_APP_NAME})'" >> "${PGDATA}/conf.d/10-replication.conf"
fi
chown postgres:postgres "${PGDATA}/conf.d/10-replication.conf"

# pg_hba.conf
if ! grep -q "# lab replication" "${PGDATA}/pg_hba.conf"; then
  cat >> "${PGDATA}/pg_hba.conf" <<EOF

# lab replication
host    replication     ${REPL_USER}    ${SUBNET}    scram-sha-256
host    all             all             ${SUBNET}    scram-sha-256
EOF
fi

systemctl enable "${SERVICE}"
systemctl restart "${SERVICE}"
for i in $(seq 1 30); do "${PGBIN}/pg_isready" -q -p "${PG_PORT}" && break; sleep 1; done

# synchronous_commit=local so provisioning never blocks while the standby is not yet attached
psql_pg() {
  sudo -u postgres env PGOPTIONS='-c synchronous_commit=local' "${PGBIN}/psql" -X -q -v ON_ERROR_STOP=1 -d postgres "$@"
}

psql_pg \
  -v repl_user="${REPL_USER}" -v repl_pw="${REPL_PASSWORD}" -v slot="${REPL_SLOT}" \
  -v pg_pw="${PG_PASSWORD}" \
  -v app_db="${APP_DB}" -v app_user="${APP_USER}" -v app_pw="${APP_PASSWORD}" <<'SQL'
SELECT format('ALTER ROLE postgres PASSWORD %L', :'pg_pw')
\gexec

SELECT format('CREATE ROLE %I LOGIN REPLICATION', :'repl_user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'repl_user')
\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'repl_user', :'repl_pw')
\gexec

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user')
\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'app_user', :'app_pw')
\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app_db')
\gexec

SELECT pg_create_physical_replication_slot(:'slot')
 WHERE NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = :'slot');
SQL

echo "primary ready: $(hostname) (slot=${REPL_SLOT})"
