#!/usr/bin/env bash
set -euo pipefail
source /vagrant/.generated/cluster.env

log() { printf '\033[1;35m[haproxy:%s]\033[0m %s\n' "$(hostname -s)" "$*"; }

dnf install -y -q haproxy >/dev/null
log "haproxy kuruldu"

# pg backend satirlarini uret
BACKEND_LINES=""
for entry in ${PG_NODE_LIST//,/ }; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  BACKEND_LINES+="    server ${name} ${ip}:5432 maxconn 100 check port 8008"$'\n'
done
export BACKEND_LINES

# --- metrik proxy listener'lari --------------------------------------------
METRICS_LISTENERS=""
METRICS_PORTS=""

if [[ "${METRICS_PROXY:-false}" == "true" ]]; then
  add_listener() {                       # $1=ad $2=bind $3=hedef $4=mod
    local name="$1" bind="$2" target="$3" extra="${4:-}"
    METRICS_LISTENERS+="listen ${name}"$'\n'
    METRICS_LISTENERS+="    bind *:${bind}"$'\n'
    METRICS_LISTENERS+="    mode http"$'\n'
    METRICS_LISTENERS+="    timeout client 30s"$'\n'
    METRICS_LISTENERS+="    timeout server 30s"$'\n'
    [[ -n "${extra}" ]] && METRICS_LISTENERS+="${extra}"$'\n'
    METRICS_LISTENERS+="    option httpchk GET /metrics"$'\n'
    METRICS_LISTENERS+="    server target ${target} check inter 10s fall 3 rise 2"$'\n'
    METRICS_LISTENERS+=$'\n'
    METRICS_PORTS+="${bind}/tcp "
  }

  idx=0
  for entry in ${PG_NODE_LIST//,/ }; do
    idx=$((idx + 1))
    name="${entry%%:*}"
    ip="${entry##*:}"

    if [[ "${NODE_EXPORTER_ENABLED}" == "true" ]]; then
      add_listener "metrics-node-${name}" \
        "$((METRICS_PROXY_NODE_BASE + idx))" "${ip}:${NODE_EXPORTER_PORT}"
    fi

    if [[ "${POSTGRES_EXPORTER_ENABLED}" == "true" ]]; then
      add_listener "metrics-postgres-${name}" \
        "$((METRICS_PROXY_POSTGRES_BASE + idx))" "${ip}:${POSTGRES_EXPORTER_PORT}"
    fi

    # Patroni REST'in tamami degil, sadece GET /metrics disariya acilir.
    # Aksi halde switchover/restart gibi POST uclari da erisilebilir olurdu.
    add_listener "metrics-patroni-${name}" \
      "$((METRICS_PROXY_PATRONI_BASE + idx))" "${ip}:8008" \
      "    http-request deny unless { method GET } { path /metrics }"
  done

  log "metrik proxy portlari: ${METRICS_PORTS}"
  for p in ${METRICS_PORTS}; do
    firewall-cmd --permanent --add-port="${p}" >/dev/null
  done
  firewall-cmd --reload >/dev/null
fi

export METRICS_LISTENERS

envsubst < /vagrant/provision/templates/haproxy.cfg.tpl > /etc/haproxy/haproxy.cfg

# SELinux enforcing ise haproxy'nin keyfi porta baglanmasina izin ver
setsebool -P haproxy_connect_any 1 2>/dev/null || true

systemctl enable --now haproxy >/dev/null
systemctl restart haproxy

log "hazir -> primary :5000  replicas :5001  stats http://${NODE_IP}:7000/"
[[ -n "${METRICS_PORTS}" ]] && log "metrik proxy -> ${METRICS_PORTS}"
