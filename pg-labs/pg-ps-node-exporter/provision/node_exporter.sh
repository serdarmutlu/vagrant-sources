#!/usr/bin/env bash
set -euo pipefail

PORT="${NODE_EXPORTER_PORT:-9100}"

# Disabled: do nothing on a clean VM, or remove a previous installation
# (so that "vagrant provision" after switching the flag off gives a node without node_exporter)
if [ "${NODE_EXPORTER_ENABLED:-false}" != "true" ]; then
  if [ -f /etc/systemd/system/node_exporter.service ] || [ -x /usr/local/bin/node_exporter ]; then
    systemctl disable --now node_exporter 2>/dev/null || true
    rm -f /etc/systemd/system/node_exporter.service /usr/local/bin/node_exporter
    systemctl daemon-reload
    firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 source address=${SUBNET} port port=${PORT} protocol=tcp accept" 2>/dev/null || true
    firewall-cmd --reload
    echo "node_exporter disabled: previous installation removed"
  else
    echo "node_exporter disabled, skipping"
  fi
  exit 0
fi

VER="${NODE_EXPORTER_VERSION}"
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# Install / upgrade the binary only when the version differs
if ! /usr/local/bin/node_exporter --version 2>&1 | head -1 | grep -q "version ${VER} "; then
  TARBALL="node_exporter-${VER}.linux-${ARCH}.tar.gz"
  BASE="https://github.com/prometheus/node_exporter/releases/download/v${VER}"
  TMP="$(mktemp -d)"
  curl -fsSL -o "${TMP}/${TARBALL}" "${BASE}/${TARBALL}"
  curl -fsSL -o "${TMP}/sha256sums.txt" "${BASE}/sha256sums.txt"
  (cd "${TMP}" && grep " ${TARBALL}\$" sha256sums.txt | sha256sum -c -)
  tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
  install -m 0755 "${TMP}/node_exporter-${VER}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter
  restorecon /usr/local/bin/node_exporter 2>/dev/null || true
  rm -rf "${TMP}"
fi

id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin node_exporter
install -d -o node_exporter -g node_exporter -m 0755 /var/lib/node_exporter/textfile-collector

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=:${PORT} \\
  --collector.textfile.directory=/var/lib/node_exporter/textfile-collector
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

# Firewall: only the lab subnet may scrape
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${SUBNET} port port=${PORT} protocol=tcp accept"
firewall-cmd --reload

for i in $(seq 1 15); do
  curl -fs "http://127.0.0.1:${PORT}/metrics" >/dev/null && { echo "node_exporter ${VER} up on :${PORT}"; exit 0; }
  sleep 1
done
echo "node_exporter did not come up, check: journalctl -u node_exporter" >&2
exit 1
