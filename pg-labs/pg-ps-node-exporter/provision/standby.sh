#!/usr/bin/env bash
set -euo pipefail
cd /var/lib/pgsql

PGBIN="/usr/pgsql-${PG_VERSION}/bin"
PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
SERVICE="postgresql-${PG_VERSION}"
PGPASS="/var/lib/pgsql/.pgpass"

# Password file for pg_basebackup and walreceiver (keeps the password out of conninfo)
echo "${PRIMARY_IP}:${PG_PORT}:*:${REPL_USER}:${REPL_PASSWORD}" > "${PGPASS}"
chown postgres:postgres "${PGPASS}"
chmod 600 "${PGPASS}"

# Wait for primary
ok=0
for i in $(seq 1 60); do
  if "${PGBIN}/pg_isready" -q -h "${PRIMARY_IP}" -p "${PG_PORT}"; then ok=1; break; fi
  sleep 2
done
[ "${ok}" = "1" ] || { echo "primary ${PRIMARY_IP}:${PG_PORT} not reachable" >&2; exit 1; }

# Initial clone (only when there is no cluster yet)
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  systemctl stop "${SERVICE}" 2>/dev/null || true
  rm -rf "${PGDATA}"
  install -d -o postgres -g postgres -m 700 "${PGDATA}"
  sudo -u postgres env PGPASSFILE="${PGPASS}" "${PGBIN}/pg_basebackup" \
    -h "${PRIMARY_IP}" -p "${PG_PORT}" -U "${REPL_USER}" -w \
    -D "${PGDATA}" -X stream -S "${REPL_SLOT}" -c fast -P
  touch "${PGDATA}/standby.signal"
  chown postgres:postgres "${PGDATA}/standby.signal"
fi

cat > "${PGDATA}/conf.d/20-standby.conf" <<EOF
primary_conninfo = 'host=${PRIMARY_IP} port=${PG_PORT} user=${REPL_USER} application_name=${STANDBY_APP_NAME} passfile=${PGPASS}'
primary_slot_name = '${REPL_SLOT}'
EOF
chown postgres:postgres "${PGDATA}/conf.d/20-standby.conf"

systemctl enable --now "${SERVICE}"

# Wait for streaming
st=""
for i in $(seq 1 30); do
  st=$(sudo -u postgres "${PGBIN}/psql" -X -Atc "SELECT status FROM pg_stat_wal_receiver" postgres 2>/dev/null || true)
  [ "${st}" = "streaming" ] && break
  sleep 2
done
echo "standby ready: $(hostname) (wal receiver: ${st:-unknown})"
