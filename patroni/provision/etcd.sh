#!/usr/bin/env bash
set -euo pipefail
source /vagrant/.generated/cluster.env

log() { printf '\033[1;33m[etcd:%s]\033[0m %s\n' "$(hostname -s)" "$*"; }

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  ETCD_ARCH="amd64" ;;
  aarch64) ETCD_ARCH="arm64" ;;
  *) echo "desteklenmeyen mimari: ${ARCH}" >&2; exit 1 ;;
esac

# --- binary ----------------------------------------------------------------
if ! /usr/local/bin/etcd --version 2>/dev/null | grep -q "${ETCD_VERSION#v}"; then
  log "etcd ${ETCD_VERSION} indiriliyor (${ETCD_ARCH})"
  TARBALL="etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz"
  curl -fsSL -o "/tmp/${TARBALL}" \
    "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${TARBALL}"
  tar xzf "/tmp/${TARBALL}" -C /tmp
  install -m 0755 "/tmp/etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}/etcd"    /usr/local/bin/etcd
  install -m 0755 "/tmp/etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}/etcdctl" /usr/local/bin/etcdctl
  rm -rf "/tmp/${TARBALL}" "/tmp/etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}"
else
  log "etcd zaten kurulu"
fi

# --- kullanici / dizinler --------------------------------------------------
getent passwd etcd >/dev/null || useradd --system --home-dir /var/lib/etcd --shell /sbin/nologin etcd
mkdir -p /var/lib/etcd /etc/etcd
chown -R etcd:etcd /var/lib/etcd
chmod 0700 /var/lib/etcd

# Var olan bir uyeye yeniden provision yapiliyorsa cluster state "existing"
CLUSTER_STATE="new"
[[ -d /var/lib/etcd/member ]] && CLUSTER_STATE="existing"

# --- config ----------------------------------------------------------------
cat > /etc/etcd/etcd.conf.yml <<EOF
name: ${NODE_NAME}
data-dir: /var/lib/etcd
initial-advertise-peer-urls: http://${NODE_IP}:2380
listen-peer-urls: http://${NODE_IP}:2380
listen-client-urls: http://${NODE_IP}:2379,http://127.0.0.1:2379
advertise-client-urls: http://${NODE_IP}:2379
initial-cluster: ${ETCD_INITIAL_CLUSTER}
initial-cluster-token: ${CLUSTER_NAME}-etcd
initial-cluster-state: ${CLUSTER_STATE}
enable-v2: false
auto-compaction-mode: periodic
auto-compaction-retention: "1"
quota-backend-bytes: 2147483648
heartbeat-interval: 250
election-timeout: 2500
snapshot-count: 10000
log-level: info
EOF
chown etcd:etcd /etc/etcd/etcd.conf.yml

# --- systemd ---------------------------------------------------------------
cat > /etc/systemd/system/etcd.service <<'EOF'
[Unit]
Description=etcd key-value store
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
Group=etcd
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=always
RestartSec=5
TimeoutStartSec=0
LimitNOFILE=65536
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/profile.d/etcdctl.sh <<EOF
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=${ETCD_ENDPOINTS}
EOF

systemctl daemon-reload
systemctl enable etcd >/dev/null
# Quorum olusana kadar notify gelmez -> bloklamadan baslat
systemctl restart --no-block etcd

log "etcd baslatildi (state=${CLUSTER_STATE}), quorum diger uyeler geldiginde olusacak"
