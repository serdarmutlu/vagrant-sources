#!/usr/bin/env bash
# Prometheus exporter'lari: node_exporter (tum node'lar), mysqld_exporter (db node'lari).
# config.yaml'da enabled: false yapilan exporter kaldirilir (servis, binary, kullanici, firewall kurali).
# Binary'ler GitHub release'inden indirilir ve sha256sums.txt ile dogrulanir.
set -euo pipefail
log() { echo "[monitoring:$(hostname -s)] $*"; }

: "${LAB_SUBNET:?}"
IS_DB_NODE="${IS_DB_NODE:-0}"
NE_ENABLED="${NODE_EXPORTER_ENABLED:-false}"
NE_VERSION="${NODE_EXPORTER_VERSION:-}"
NE_PORT="${NODE_EXPORTER_PORT:-9100}"
ME_ENABLED="${MYSQLD_EXPORTER_ENABLED:-false}"
ME_VERSION="${MYSQLD_EXPORTER_VERSION:-}"
ME_PORT="${MYSQLD_EXPORTER_PORT:-9104}"
ME_USER="${EXPORTER_USER:-exporter}"
ME_PASSWORD="${EXPORTER_PASSWORD:-}"
# Sadece db node'larinda
[ "$IS_DB_NODE" = 1 ] || ME_ENABLED=false

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) log "HATA: desteklenmeyen mimari $(uname -m)"; exit 1 ;;
esac

rule_for() { echo "rule family=ipv4 source address=${LAB_SUBNET} port port=$1 protocol=tcp accept"; }

fw_open() {
  local r; r="$(rule_for "$1")"
  firewall-cmd --permanent --query-rich-rule="$r" >/dev/null 2>&1 \
    || firewall-cmd --permanent --add-rich-rule="$r" >/dev/null
  firewall-cmd --reload >/dev/null
}

fw_close_all() {  # bu exporter'a ait tum kurallar (port degismis olabilir)
  local name="$1" r
  while read -r r; do
    [ -n "$r" ] || continue
    firewall-cmd --permanent --remove-rich-rule="$r" >/dev/null || true
  done < <(firewall-cmd --permanent --list-rich-rules | grep -F "port=\"$2\"" || true)
  firewall-cmd --reload >/dev/null
  log "$name firewall kurali kaldirildi (port $2)"
}

# install_binary <ad> <surum>
install_binary() {
  local name="$1" ver="$2" bin="/usr/local/bin/$1"
  if [ -x "$bin" ] && "$bin" --version 2>&1 | grep -q "version ${ver} "; then
    log "$name $ver zaten kurulu"
    return
  fi
  local file="${name}-${ver}.linux-${ARCH}.tar.gz"
  local base="https://github.com/prometheus/${name}/releases/download/v${ver}"
  local tmp; tmp="$(mktemp -d)"
  log "$name $ver indiriliyor ($ARCH)"
  curl -fsSL --retry 3 -o "$tmp/$file" "$base/$file"
  curl -fsSL --retry 3 -o "$tmp/sha256sums.txt" "$base/sha256sums.txt"
  ( cd "$tmp" && grep " ${file}\$" sha256sums.txt | sha256sum -c --quiet - ) \
    || { log "HATA: $file sha256 dogrulamasi basarisiz"; rm -rf "$tmp"; exit 1; }
  tar -xzf "$tmp/$file" -C "$tmp"
  install -m 0755 "$tmp/${name}-${ver}.linux-${ARCH}/${name}" "$bin"
  rm -rf "$tmp"
  log "$("$bin" --version 2>&1 | head -1)"
}

ensure_user() {
  id "$1" >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin "$1"
}

# remove_exporter <ad> <port> <ekstra yollar...>
remove_exporter() {
  local name="$1" port="$2"; shift 2
  if [ -f "/etc/systemd/system/${name}.service" ] || [ -x "/usr/local/bin/${name}" ]; then
    log "$name kaldiriliyor"
    systemctl disable --now "${name}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${name}.service" "/usr/local/bin/${name}"
    rm -rf "$@"
    systemctl daemon-reload
    userdel "$name" >/dev/null 2>&1 || true
    fw_close_all "$name" "$port"
  fi
}

restart_if_changed() {  # <unit> <changed 0/1>
  systemctl daemon-reload
  systemctl enable "$1" >/dev/null 2>&1
  if [ "$2" = 1 ]; then systemctl restart "$1"; else systemctl start "$1"; fi
}

write_if_changed() {  # <hedef> <mod> <owner:group>  (icerik stdin'den) -> echo 1/0
  local tmp; tmp="$(mktemp)"; cat > "$tmp"
  if cmp -s "$tmp" "$1"; then rm -f "$tmp"; echo 0; return; fi
  install -m "$2" -o "${3%%:*}" -g "${3##*:}" "$tmp" "$1"; rm -f "$tmp"; echo 1
}

command -v tar >/dev/null || dnf -y -q install tar

# ============================================================== node_exporter
if [ "$NE_ENABLED" = true ]; then
  install_binary node_exporter "$NE_VERSION"
  ensure_user node_exporter
  install -d -o node_exporter -g node_exporter -m 0755 /var/lib/node_exporter/textfile-collector

  changed=$(write_if_changed /etc/systemd/system/node_exporter.service 0644 root:root <<EOF
[Unit]
Description=Prometheus node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=:${NE_PORT} \\
  --collector.textfile.directory=/var/lib/node_exporter/textfile-collector \\
  --collector.systemd \\
  --collector.systemd.unit-include=(mysqld|mysqlrouter|mysqld_exporter|node_exporter)[.]service
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
)
  fw_open "$NE_PORT"
  restart_if_changed node_exporter.service "$changed"
  log "node_exporter :${NE_PORT} aktif"
else
  remove_exporter node_exporter "$NE_PORT" /var/lib/node_exporter
fi

# ============================================================== mysqld_exporter
if [ "$ME_ENABLED" = true ]; then
  : "${ME_PASSWORD:?EXPORTER_PASSWORD gerekli}"
  install_binary mysqld_exporter "$ME_VERSION"
  ensure_user mysqld_exporter
  install -d -o root -g mysqld_exporter -m 0750 /etc/mysqld_exporter

  cnf_changed=$(write_if_changed /etc/mysqld_exporter/my.cnf 0640 root:mysqld_exporter <<EOF
[client]
user=${ME_USER}
password="${ME_PASSWORD}"
host=127.0.0.1
port=3306
EOF
)

  # Group Replication ve InnoDB collector'lari; bu surumun tanimadigi bayrak atlanir
  # (bilinmeyen bayrakla exporter hic baslamaz).
  help="$(/usr/local/bin/mysqld_exporter --help 2>&1 || true)"
  flags=""
  for f in collect.perf_schema.replication_group_members \
           collect.perf_schema.replication_group_member_stats \
           collect.perf_schema.replication_applier_status_by_worker \
           collect.info_schema.innodb_metrics \
           collect.perf_schema.eventswaits \
           collect.perf_schema.tableiowaits \
           collect.perf_schema.indexiowaits \
           collect.binlog_size; do
    # kingpin bool bayraklari --[no-]collect.x seklinde listeler; duz metin aramasi yeterli
    if grep -qF -- "$f" <<< "$help"; then
      flags+=" \\"$'\n'"  --${f}"
    else
      log "uyari: --${f} bu surumde yok, atlandi"
    fi
  done

  unit_changed=$(write_if_changed /etc/systemd/system/mysqld_exporter.service 0644 root:root <<EOF
[Unit]
Description=Prometheus mysqld_exporter
Wants=network-online.target
After=network-online.target mysqld.service

[Service]
User=mysqld_exporter
Group=mysqld_exporter
ExecStart=/usr/local/bin/mysqld_exporter \\
  --config.my-cnf=/etc/mysqld_exporter/my.cnf \\
  --web.listen-address=:${ME_PORT}${flags}
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
)
  fw_open "$ME_PORT"
  changed=0; { [ "$cnf_changed" = 1 ] || [ "$unit_changed" = 1 ]; } && changed=1
  restart_if_changed mysqld_exporter.service "$changed"
  log "mysqld_exporter :${ME_PORT} aktif (MySQL kullanicisi '${ME_USER}' cluster.py tarafindan primary'de olusturulur)"
elif [ "$IS_DB_NODE" = 1 ]; then
  remove_exporter mysqld_exporter "$ME_PORT" /etc/mysqld_exporter
fi

log "tamam"
