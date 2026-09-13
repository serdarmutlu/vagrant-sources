#!/usr/bin/env bash
set -euo pipefail
source /vagrant/.generated/cluster.env

log() { printf '\033[1;34m[common:%s]\033[0m %s\n' "$(hostname -s)" "$*"; }

# --- SELinux ---------------------------------------------------------------
if [[ "${SELINUX_MODE}" == "permissive" ]]; then
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  log "SELinux permissive"
fi

# --- /etc/hosts ------------------------------------------------------------
sed -i '/# BEGIN patroni-lab/,/# END patroni-lab/d' /etc/hosts
{
  echo "# BEGIN patroni-lab"
  cat /vagrant/.generated/hosts.fragment
  echo "# END patroni-lab"
} >> /etc/hosts
log "/etc/hosts guncellendi"

# vagrant box'lari 127.0.1.1 -> hostname satiri birakabiliyor, temizle
sed -i "/^127\.0\.1\.1.*$(hostname -s)/d" /etc/hosts

# --- temel paketler --------------------------------------------------------
log "temel paketler kuruluyor"
dnf install -y -q chrony curl tar jq gettext bash-completion \
                  policycoreutils-python-utils >/dev/null

systemctl enable --now chronyd >/dev/null 2>&1 || true

# --- kernel/sysctl ---------------------------------------------------------
cat > /etc/sysctl.d/90-patroni.conf <<'EOF'
vm.swappiness = 1
vm.overcommit_memory = 2
vm.overcommit_ratio = 90
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
sysctl --system >/dev/null

# --- firewalld -------------------------------------------------------------
systemctl enable --now firewalld >/dev/null 2>&1 || true
for port in ${FIREWALL_PORTS}; do
  firewall-cmd --permanent --add-port="${port}" >/dev/null
done
firewall-cmd --reload >/dev/null
log "firewall portlari acildi: ${FIREWALL_PORTS}"

log "hazir (rol=${NODE_ROLE}, ip=${NODE_IP})"
