#!/usr/bin/env bash
# Tum node'lar: /etc/hosts, saat dilimi, SELinux, firewalld, MySQL yum reposu, lab.env
set -euo pipefail
log() { echo "[common:$(hostname -s)] $*"; }

: "${LAB_HOSTS:?}" "${LAB_SUBNET:?}" "${MYSQL_REPO_RPM:?}"
: "${CLUSTER_NAME:?}" "${CLUSTER_ADMIN_USER:?}" "${CLUSTER_ADMIN_PASSWORD:?}" "${DB_NODES:?}"
TIMEZONE="${TIMEZONE:-UTC}"

# --- /etc/hosts ---------------------------------------------------------------
# Vagrant hostname'i 127.0.x.x'e baglayabiliyor; Group Replication uyeleri birbirini
# bu isimle bulacagi icin hostname'in host-only IP'ye cozulmesi sart.
log "/etc/hosts yeniden yaziliyor"
{
  echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4"
  echo "::1         localhost localhost.localdomain localhost6 localhost6.localdomain6"
  IFS=',' read -ra entries <<< "$LAB_HOSTS"
  for e in "${entries[@]}"; do
    printf '%-15s %s\n' "${e%%=*}" "${e#*=}"
  done
} > /etc/hosts

# --- saat dilimi / SELinux ----------------------------------------------------
timedatectl set-timezone "$TIMEZONE" || log "uyari: timezone ayarlanamadi ($TIMEZONE)"

if command -v getenforce >/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
  log "SELinux -> permissive (lab)"
  setenforce 0
fi
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# --- temel paketler -----------------------------------------------------------
log "temel paketler"
dnf -y -q install firewalld chrony
systemctl enable --now firewalld chronyd

# --- MySQL resmi reposu -------------------------------------------------------
if ! rpm -qa | grep -q 'community-release'; then
  log "MySQL yum reposu: $MYSQL_REPO_RPM"
  dnf -y -q install "$MYSQL_REPO_RPM"
fi
# AppStream'deki mysql modulu varsa community paketleriyle karismasin
dnf -y -q module disable mysql >/dev/null 2>&1 || true

# --- ic komutu icin ortak ayarlar ---------------------------------------------
install -d -m 0700 /etc/mysql-lab
{
  printf 'CLUSTER_NAME=%q\n'           "$CLUSTER_NAME"
  printf 'CLUSTER_ADMIN_USER=%q\n'     "$CLUSTER_ADMIN_USER"
  printf 'CLUSTER_ADMIN_PASSWORD=%q\n' "$CLUSTER_ADMIN_PASSWORD"
  printf 'DB_NODES=%q\n'               "$DB_NODES"
} > /etc/mysql-lab/lab.env
chmod 0600 /etc/mysql-lab/lab.env

log "tamam"
