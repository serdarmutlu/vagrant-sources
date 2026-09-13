#!/usr/bin/env bash
set -euo pipefail
source /vagrant/.generated/cluster.env

log() { printf '\033[1;36m[node_exporter:%s]\033[0m %s\n' "$(hostname -s)" "$*"; }

VER="${NODE_EXPORTER_VERSION}"
PORT="${NODE_EXPORTER_PORT}"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  NE_ARCH="amd64" ;;
  aarch64) NE_ARCH="arm64" ;;
  *) echo "desteklenmeyen mimari: ${ARCH}" >&2; exit 1 ;;
esac

# --- binary ----------------------------------------------------------------
if ! /usr/local/bin/node_exporter --version 2>&1 | grep -q "version ${VER}"; then
  log "node_exporter ${VER} indiriliyor (${NE_ARCH})"
  TARBALL="node_exporter-${VER}.linux-${NE_ARCH}.tar.gz"
  curl -fsSL -o "/tmp/${TARBALL}" \
    "https://github.com/prometheus/node_exporter/releases/download/v${VER}/${TARBALL}"
  tar xzf "/tmp/${TARBALL}" -C /tmp
  install -m 0755 "/tmp/node_exporter-${VER}.linux-${NE_ARCH}/node_exporter" /usr/local/bin/node_exporter
  rm -rf "/tmp/${TARBALL}" "/tmp/node_exporter-${VER}.linux-${NE_ARCH}"
else
  log "node_exporter zaten kurulu"
fi

# --- kullanici / textfile collector dizini ---------------------------------
getent passwd node_exporter >/dev/null || \
  useradd --system --no-create-home --shell /sbin/nologin node_exporter
mkdir -p /var/lib/node_exporter/textfile_collector
chown -R node_exporter:node_exporter /var/lib/node_exporter

# --- systemd ---------------------------------------------------------------
cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=:${PORT} \\
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \\
  --collector.systemd \\
  --collector.processes \\
  --collector.filesystem.mount-points-exclude='^/(dev|proc|sys|run/credentials/.+|var/lib/docker/.+|var/lib/containers/storage/.+)(\$|/)' \\
  --no-collector.wifi \\
  --no-collector.infiniband \\
  --no-collector.nfs \\
  --no-collector.nfsd
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/node_exporter
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

# --- firewall --------------------------------------------------------------
firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
firewall-cmd --reload >/dev/null

systemctl daemon-reload
systemctl enable node_exporter >/dev/null
systemctl restart node_exporter

sleep 2
if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" | head -1 >/dev/null; then
  log "hazir -> http://${NODE_IP}:${PORT}/metrics"
else
  log "UYARI: metrics endpoint cevap vermedi -> journalctl -u node_exporter -n 50"
fi
