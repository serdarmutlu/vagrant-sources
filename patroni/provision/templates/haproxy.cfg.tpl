global
    maxconn 1000
    log     127.0.0.1 local0
    stats   socket /var/lib/haproxy/stats mode 660 level admin

defaults
    log     global
    mode    tcp
    retries 2
    timeout client  30m
    timeout connect 4s
    timeout server  30m
    timeout check   5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /
    stats refresh 5s
    stats show-node

# --- yazma trafigi: her zaman leader ---------------------------------------
listen primary
    bind *:5000
    option httpchk OPTIONS /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
${BACKEND_LINES}

# --- okuma trafigi: replica'lar --------------------------------------------
listen replicas
    bind *:5001
    balance roundrobin
    option httpchk OPTIONS /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
${BACKEND_LINES}

# --- metrik proxy: pg node'larinin exporter portlari ------------------------
# Her node icin ayri listener; Prometheus'ta instance etiketi scrape config'ten
# geldigi icin pg1/pg2/pg3 dogru gorunur. Node dustugunde 503 doner -> up=0.
${METRICS_LISTENERS}
