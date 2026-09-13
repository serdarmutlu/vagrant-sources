#!/usr/bin/env bash
set -euo pipefail
source /vagrant/.generated/cluster.env

log() { printf '\033[1;35m[pg_exporter:%s]\033[0m %s\n' "$(hostname -s)" "$*"; }

VER="${POSTGRES_EXPORTER_VERSION}"
PORT="${POSTGRES_EXPORTER_PORT}"
PSQL="/usr/pgsql-${PG_MAJOR}/bin/psql"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  PE_ARCH="amd64" ;;
  aarch64) PE_ARCH="arm64" ;;
  *) echo "desteklenmeyen mimari: ${ARCH}" >&2; exit 1 ;;
esac

# --- binary ----------------------------------------------------------------
if ! /usr/local/bin/postgres_exporter --version 2>&1 | grep -q "version ${VER}"; then
  log "postgres_exporter ${VER} indiriliyor (${PE_ARCH})"
  TARBALL="postgres_exporter-${VER}.linux-${PE_ARCH}.tar.gz"
  curl -fsSL -o "/tmp/${TARBALL}" \
    "https://github.com/prometheus-community/postgres_exporter/releases/download/v${VER}/${TARBALL}"
  tar xzf "/tmp/${TARBALL}" -C /tmp
  install -m 0755 "/tmp/postgres_exporter-${VER}.linux-${PE_ARCH}/postgres_exporter" \
    /usr/local/bin/postgres_exporter
  rm -rf "/tmp/${TARBALL}" "/tmp/postgres_exporter-${VER}.linux-${PE_ARCH}"
else
  log "postgres_exporter zaten kurulu"
fi

getent passwd postgres_exporter >/dev/null || \
  useradd --system --no-create-home --shell /sbin/nologin postgres_exporter

# --- DDL'i leader uzerinde calistir ----------------------------------------
# Hangi node'un leader oldugunu Patroni REST'ten ogren; DDL idempotent oldugu
# icin uc node da ayni leader'a yazsa sorun olmaz.
LEADER_IP=""
for _ in $(seq 1 20); do
  LEADER_IP=$(curl -fsS --max-time 3 "http://127.0.0.1:8008/cluster" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    c = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in c.get('members', []):
    if m.get('role') in ('leader', 'master', 'primary'):
        print(m.get('host', ''))
        break
" || true)
  [[ -n "${LEADER_IP}" ]] && break
  sleep 3
done

if [[ -z "${LEADER_IP}" ]]; then
  echo "Patroni leader bulunamadi - once cluster'in ayakta oldugundan emin olun" >&2
  exit 1
fi
log "leader: ${LEADER_IP}"

export PGPASSWORD="${SUPERUSER_PASSWORD}"
"${PSQL}" -h "${LEADER_IP}" -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgexporter') THEN
    CREATE ROLE pgexporter LOGIN PASSWORD '${PGEXPORTER_PASSWORD}';
  ELSE
    ALTER ROLE pgexporter LOGIN PASSWORD '${PGEXPORTER_PASSWORD}';
  END IF;
END
\$\$;

-- pg_monitor, pg_stat_statements dahil tum istatistik view'larini okumaya yeter
GRANT pg_monitor TO pgexporter;
GRANT CONNECT ON DATABASE postgres TO pgexporter;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
unset PGPASSWORD
log "pgexporter rolu ve pg_stat_statements hazir"

# --- servis ----------------------------------------------------------------
install -d -m 0750 -o root -g postgres_exporter /etc/postgres_exporter
cat > /etc/postgres_exporter/postgres_exporter.env <<EOF
DATA_SOURCE_URI=127.0.0.1:5432/postgres?sslmode=disable
DATA_SOURCE_USER=pgexporter
DATA_SOURCE_PASS=${PGEXPORTER_PASSWORD}
EOF
chmod 0640 /etc/postgres_exporter/postgres_exporter.env
chown root:postgres_exporter /etc/postgres_exporter/postgres_exporter.env

cat > /etc/systemd/system/postgres_exporter.service <<EOF
[Unit]
Description=Prometheus PostgreSQL Exporter
Documentation=https://github.com/prometheus-community/postgres_exporter
After=network-online.target patroni.service
Wants=network-online.target

[Service]
Type=simple
User=postgres_exporter
Group=postgres_exporter
EnvironmentFile=/etc/postgres_exporter/postgres_exporter.env
ExecStart=/usr/local/bin/postgres_exporter \\
  --web.listen-address=:${PORT} \\
  --collector.stat_statements \\
  --collector.stat_statements.limit=200 \\
  --collector.stat_statements.query_length=200 \\
  --collector.stat_wal_receiver \\
  --collector.long_running_transactions \\
  --collector.process_idle \\
  --collector.postmaster \\
  --collector.database_wraparound
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectHome=yes
ProtectSystem=strict
PrivateTmp=true
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
firewall-cmd --reload >/dev/null

systemctl daemon-reload
systemctl enable postgres_exporter >/dev/null
systemctl restart postgres_exporter

sleep 3
if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" | grep -q '^pg_up'; then
  log "hazir -> http://${NODE_IP}:${PORT}/metrics"
else
  log "UYARI: metrics alinamadi -> journalctl -u postgres_exporter -n 50"
fi
