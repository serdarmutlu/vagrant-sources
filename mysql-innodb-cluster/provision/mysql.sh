#!/usr/bin/env bash
# MySQL node'u: kurulum, my.cnf, initialize, root sifresi, clusteradmin kullanicisi.
# Cluster'in kendisi myrouter provision'inda (cluster.py) kurulur.
set -euo pipefail
log() { echo "[mysql:${NODE_NAME}] $*"; }

: "${NODE_NAME:?}" "${SERVER_ID:?}" "${MYSQL_ROOT_PASSWORD:?}" "${LAB_SUBNET:?}"
: "${CLUSTER_ADMIN_USER:?}" "${CLUSTER_ADMIN_PASSWORD:?}"
BUFFER_POOL="${INNODB_BUFFER_POOL_SIZE:-512M}"
SOCK=/var/lib/mysql/mysql.sock

# --- paketler -----------------------------------------------------------------
log "mysql-community-server + mysql-shell kuruluyor"
dnf -y -q install mysql-community-server mysql-shell
log "$(mysqld --version)"

# --- firewalld: MySQL portlari sadece lab subnet'inden -------------------------
# 3306 classic + GR (MYSQL communication stack), 33060 X protocol, 33061 XCom
for p in 3306 33060 33061; do
  rule="rule family=ipv4 source address=${LAB_SUBNET} port port=${p} protocol=tcp accept"
  firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1 \
    || firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null
done
# Host port yonlendirme: VirtualBox NAT uzerinden gelen trafik (kaynak: NAT gateway)
if [ -n "${NAT_GATEWAY:-}" ]; then
  rule="rule family=ipv4 source address=${NAT_GATEWAY} port port=3306 protocol=tcp accept"
  firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1 \
    || firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null
fi
firewall-cmd --reload >/dev/null

# --- my.cnf -------------------------------------------------------------------
# GR icin gereken statik ayarlar burada; geri kalanini AdminAPI SET PERSIST ile yazar.
tmp="$(mktemp)"
cat > "$tmp" <<EOF
# vagrant provision tarafindan yonetilir
[mysqld]
datadir=/var/lib/mysql
socket=${SOCK}
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid

server_id=${SERVER_ID}
report_host=${NODE_NAME}
bind_address=0.0.0.0
mysqlx_bind_address=0.0.0.0

gtid_mode=ON
enforce_gtid_consistency=ON
# GR sadece InnoDB ile calisir
disabled_storage_engines=MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY

innodb_buffer_pool_size=${BUFFER_POOL}

[client]
socket=${SOCK}
EOF
cnf_changed=0
if ! cmp -s "$tmp" /etc/my.cnf; then
  install -m 0644 "$tmp" /etc/my.cnf
  cnf_changed=1
fi
rm -f "$tmp"

# --- initialize ---------------------------------------------------------------
# RPM'in mysqld_pre_systemd'si rastgele gecici root sifresi uretir; onun yerine
# --initialize-insecure ile baslatip sifreyi hemen ayarliyoruz.
if [ ! -d /var/lib/mysql/mysql ]; then
  log "datadir initialize ediliyor"
  install -d -o mysql -g mysql -m 0751 /var/lib/mysql
  [ -f /var/log/mysqld.log ] || install -m 0640 -o mysql -g mysql /dev/null /var/log/mysqld.log
  mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql
  cnf_changed=0
fi

systemctl enable mysqld >/dev/null 2>&1
if [ "$cnf_changed" = 1 ] && systemctl is-active -q mysqld; then
  log "my.cnf degisti -> restart"
  systemctl restart mysqld
else
  systemctl start mysqld
fi

for _ in $(seq 1 90); do
  mysqladmin --no-defaults -S "$SOCK" ping >/dev/null 2>&1 && break
  sleep 2
done
mysqladmin --no-defaults -S "$SOCK" ping >/dev/null 2>&1 || { log "HATA: mysqld ayaga kalkmadi"; tail -50 /var/log/mysqld.log; exit 1; }

# --- root sifresi -------------------------------------------------------------
if mysql --no-defaults -S "$SOCK" -uroot -e 'SELECT 1' >/dev/null 2>&1; then
  log "root sifresi ayarlaniyor"
  mysql --no-defaults -S "$SOCK" -uroot <<SQL
SET SESSION sql_log_bin = 0;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
SQL
fi
( umask 077
  cat > /root/.my.cnf <<EOF
[client]
user=root
password="${MYSQL_ROOT_PASSWORD}"
socket=${SOCK}
EOF
)
msql() { mysql --defaults-extra-file=/root/.my.cnf "$@"; }

# --- clusteradmin -------------------------------------------------------------
# sql_log_bin=0: bu node'larda cluster disi GTID (errant transaction) olusmasin.
in_group="$(msql -Nse "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE IN ('ONLINE','RECOVERING')" 2>/dev/null || echo 0)"
read_only="$(msql -Nse 'SELECT @@global.super_read_only')"

if [ "$in_group" != 0 ]; then
  log "node zaten cluster uyesi; kullanici adimi atlandi"
elif [ "$read_only" = 1 ]; then
  log "super_read_only=1 (eski uye?); kullanici adimi atlandi. Gerekirse: ic rejoin ${NODE_NAME}"
else
  log "${CLUSTER_ADMIN_USER} kullanicisi"
  msql <<SQL
SET SESSION sql_log_bin = 0;
CREATE USER IF NOT EXISTS '${CLUSTER_ADMIN_USER}'@'%' IDENTIFIED BY '${CLUSTER_ADMIN_PASSWORD}';
ALTER USER '${CLUSTER_ADMIN_USER}'@'%' IDENTIFIED BY '${CLUSTER_ADMIN_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${CLUSTER_ADMIN_USER}'@'%' WITH GRANT OPTION;
SET SESSION sql_log_bin = 1;
SQL

  log "AdminAPI uygunluk kontrolu"
  printf '%s\n' "$CLUSTER_ADMIN_PASSWORD" \
    | mysqlsh --no-wizard --passwords-from-stdin \
        --uri "${CLUSTER_ADMIN_USER}@${NODE_NAME}:3306" \
        --py -e "dba.check_instance_configuration()" \
    || log "uyari: check_instance_configuration hata dondu (cluster.py yine de deneyecek)"
fi

log "tamam - cluster myrouter provision'inda kurulacak"
