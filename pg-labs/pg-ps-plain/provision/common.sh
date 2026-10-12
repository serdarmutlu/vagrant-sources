#!/usr/bin/env bash
set -euo pipefail

# /etc/hosts entries for all nodes
IFS=',' read -ra ENTRIES <<< "$HOSTS"
for e in "${ENTRIES[@]}"; do
  name="${e%%=*}"; ip="${e##*=}"
  sed -i "/[[:space:]]${name}\$/d" /etc/hosts
  echo "${ip} ${name}" >> /etc/hosts
done

# SELinux permissive (lab shortcut)
setenforce 0 || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

# PGDG repo + PostgreSQL packages
if ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
  dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm"
fi
dnf -qy module disable postgresql || true
dnf install -y "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}" "postgresql${PG_VERSION}-contrib"

# system_stats extension (files only; CREATE EXTENSION is done manually per database)
if [ "${SYSTEM_STATS:-false}" = "true" ]; then
  dnf install -y "system_stats_${PG_VERSION}"
  rpm -ql "system_stats_${PG_VERSION}" | grep -q 'system_stats\.control' \
    || { echo "system_stats_${PG_VERSION}: control file not found in package" >&2; exit 1; }
fi

# PGDG does not put its bin dir on PATH
cat > /etc/profile.d/pgsql.sh <<EOF
export PATH=/usr/pgsql-${PG_VERSION}/bin:\$PATH
EOF

# Firewall: PostgreSQL port only from the lab subnet
dnf install -y firewalld
systemctl enable --now firewalld
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${SUBNET} port port=${PG_PORT} protocol=tcp accept"
firewall-cmd --reload
