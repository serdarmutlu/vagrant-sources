#!/usr/bin/env bash
# myrouter: mysql-shell + mysql-router kurulumu, cluster olusturma (cluster.py), Router bootstrap
set -euo pipefail
log() { echo "[router:$(hostname -s)] $*"; }

set -a; . /etc/mysql-lab/lab.env; set +a
: "${CLUSTER_ADMIN_USER:?}" "${CLUSTER_ADMIN_PASSWORD:?}" "${DB_NODES:?}"
FIRST_DB="${DB_NODES%%,*}"

# --- paketler -----------------------------------------------------------------
log "mysql-shell, mysql-router-community, mysql-community-client kuruluyor"
dnf -y -q install mysql-shell mysql-router-community mysql-community-client

# Router portlari: 6446 RW, 6447 RO, 6448/6449 X protocol RW/RO, 6450 RW-split
firewall-cmd --permanent --add-port=6446-6450/tcp >/dev/null
firewall-cmd --reload >/dev/null

# --- cluster ------------------------------------------------------------------
log "InnoDB Cluster kuruluyor / kontrol ediliyor"
mysqlsh --no-wizard --py -f /opt/mysql-lab/cluster.py

# --- Router bootstrap ---------------------------------------------------------
# Zaten bootstrap edilmisse tekrar etme. Zorlamak icin: ROUTER_FORCE_BOOTSTRAP=1
CONF=/etc/mysqlrouter/mysqlrouter.conf
if [ "${ROUTER_FORCE_BOOTSTRAP:-0}" = 1 ] || ! grep -q '^\[metadata_cache' "$CONF" 2>/dev/null; then
  log "mysqlrouter --bootstrap (${CLUSTER_ADMIN_USER}@${FIRST_DB}:3306)"
  systemctl stop mysqlrouter >/dev/null 2>&1 || true
  printf '%s\n' "$CLUSTER_ADMIN_PASSWORD" \
    | mysqlrouter --bootstrap "${CLUSTER_ADMIN_USER}@${FIRST_DB}:3306" \
        --user=mysqlrouter --conf-bind-address=0.0.0.0 --force
else
  log "Router zaten bootstrap edilmis"
fi
systemctl enable mysqlrouter >/dev/null 2>&1
systemctl restart mysqlrouter

for _ in $(seq 1 30); do
  (exec 3<>/dev/tcp/127.0.0.1/6446) 2>/dev/null && break
  sleep 1
done

# --- hizli test ---------------------------------------------------------------
if [ -n "${APP_USER:-}" ]; then
  rw="$(mysql --no-defaults -h127.0.0.1 -P6446 -u"$APP_USER" -p"$APP_PASSWORD" -Nse 'SELECT @@hostname' 2>/dev/null || echo '?')"
  ro="$(mysql --no-defaults -h127.0.0.1 -P6447 -u"$APP_USER" -p"$APP_PASSWORD" -Nse 'SELECT @@hostname' 2>/dev/null || echo '?')"
  log "6446 (RW) -> ${rw}   6447 (RO) -> ${ro}"
fi

log "tamam. Durum: vagrant ssh $(hostname -s) -c 'ic status'"
