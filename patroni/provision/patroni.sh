#!/usr/bin/env bash
set -euo pipefail
source /vagrant/.generated/cluster.env

log() { printf '\033[1;32m[patroni:%s]\033[0m %s\n' "$(hostname -s)" "$*"; }

PGBIN="/usr/pgsql-${PG_MAJOR}/bin"
PGDATA="/var/lib/pgsql/${PG_MAJOR}/data"

# CRB (CodeReady Builder) Rocky 9'da varsayilan kapali; PGDG paketlerinin bir
# kismi (ornegin postgresqlXX-devel -> perl-IPC-Run) buradan besleniyor.
dnf install -y -q dnf-plugins-core >/dev/null
dnf config-manager --set-enabled crb >/dev/null 2>&1 || true

# --- PostgreSQL (PGDG) -----------------------------------------------------
if ! rpm -q "postgresql${PG_MAJOR}-server" >/dev/null 2>&1; then
  log "PGDG deposu + PostgreSQL ${PG_MAJOR}"
  dnf install -y -q \
    "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" >/dev/null
  dnf -qy module disable postgresql >/dev/null 2>&1 || true
  dnf install -y -q "postgresql${PG_MAJOR}-server" "postgresql${PG_MAJOR}-contrib" >/dev/null
fi

# psycopg3 binary wheel kendi libpq'sunu tasir; libpq-devel/gcc GEREKMIYOR.
# libpq-devel istenirse dnf onu PGDG'deki postgresqlXX-devel ile karsilamaya
# calisir ve "nothing provides perl(IPC::Run)" hatasi verir.
dnf install -y -q python3 python3-pip >/dev/null

# Stock servisi kapat - cluster'i Patroni yonetecek
systemctl disable --now "postgresql-${PG_MAJOR}" >/dev/null 2>&1 || true

# --- Patroni (venv) --------------------------------------------------------
if [[ ! -x /opt/patroni/bin/patroni ]] || \
   ! /opt/patroni/bin/patroni --version 2>/dev/null | grep -q "${PATRONI_VERSION}"; then
  log "Patroni ${PATRONI_VERSION} kuruluyor"
  python3 -m venv /opt/patroni
  /opt/patroni/bin/pip install -q --upgrade pip wheel setuptools
  /opt/patroni/bin/pip install -q "patroni[etcd3,psycopg3]==${PATRONI_VERSION}"
else
  log "Patroni zaten kurulu"
fi

# --- dizinler --------------------------------------------------------------
mkdir -p /etc/patroni /var/log/patroni "${PGDATA}" /var/lib/pgsql/archive
chown -R postgres:postgres /var/lib/pgsql /var/log/patroni
chmod 0700 "${PGDATA}"

# --- watchdog (softdog) ----------------------------------------------------
echo softdog > /etc/modules-load.d/softdog.conf
modprobe softdog 2>/dev/null || true
cat > /etc/udev/rules.d/61-watchdog.rules <<'EOF'
KERNEL=="watchdog", OWNER="postgres", GROUP="postgres", MODE="0600"
EOF
chown postgres:postgres /dev/watchdog 2>/dev/null || true

# --- patroni.yml -----------------------------------------------------------
export NODE_NAME NODE_IP CLUSTER_NAME PG_MAJOR PGDATA PGBIN \
       ETCD_ENDPOINTS NETWORK_PREFIX \
       SUPERUSER_PASSWORD REPLICATION_PASSWORD REWIND_PASSWORD PATRONI_REST_PASSWORD

envsubst < /vagrant/provision/templates/patroni.yml.tpl > /etc/patroni/patroni.yml
chown postgres:postgres /etc/patroni/patroni.yml
chmod 0600 /etc/patroni/patroni.yml

# --- systemd ---------------------------------------------------------------
cat > /etc/systemd/system/patroni.service <<'EOF'
[Unit]
Description=Patroni PostgreSQL HA
Documentation=https://patroni.readthedocs.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/opt/patroni/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
KillSignal=SIGINT
TimeoutSec=120
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- kolaylik ayarlari -----------------------------------------------------
cat > /usr/local/bin/patronictl <<'EOF'
#!/bin/bash
exec /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml "$@"
EOF
chmod 0755 /usr/local/bin/patronictl

cat > /etc/profile.d/pgpatroni.sh <<EOF
export PATH=${PGBIN}:\$PATH
export PGDATA=${PGDATA}
export PATRONICTL_CONFIG_FILE=/etc/patroni/patroni.yml
EOF

# --- etcd quorum'unu bekle -------------------------------------------------
log "etcd cluster bekleniyor..."
for _ in $(seq 1 60); do
  for ep in ${ETCD_ENDPOINTS//,/ }; do
    if curl -fsS --max-time 2 "http://${ep}/health" 2>/dev/null | grep -q '"health":"true"'; then
      log "etcd saglikli: ${ep}"
      READY=1; break 2
    fi
  done
  sleep 3
done
[[ "${READY:-0}" == "1" ]] || { echo "etcd quorum olusmadi" >&2; exit 1; }

# --- baslat ----------------------------------------------------------------
systemctl daemon-reload
systemctl enable patroni >/dev/null
systemctl restart patroni

log "Patroni bekleniyor (REST 8008)..."
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "http://127.0.0.1:8008/health" >/dev/null 2>&1; then
    ROLE=$(curl -fsS http://127.0.0.1:8008/patroni | python3 -c 'import sys,json;print(json.load(sys.stdin)["role"])' 2>/dev/null || echo "?")
    log "ayakta - rol: ${ROLE}"
    exit 0
  fi
  sleep 3
done

log "UYARI: Patroni 180sn icinde hazir olmadi -> journalctl -u patroni -n 100"
