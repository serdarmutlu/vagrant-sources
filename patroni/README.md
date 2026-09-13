# Patroni HA Lab — Vagrant + VirtualBox + Rocky Linux 9

*[Türkçe sürüm için: README.tr.md](README.tr.md)*

Brings up an etcd (3) + PostgreSQL/Patroni (3) + HAProxy (1) topology with a single
command. Each service runs in its own VM.

```
                    ┌──────────────┐
   application ────▶│   haproxy    │  :5000 → leader (write)
                    │ .56.30       │  :5001 → replica (read)
                    └──────┬───────┘  :7000 → stats
                           │
        ┌──────────┬───────┴───────┬──────────┐
      pg1 .21    pg2 .22         pg3 .23
        └──────────┴───────┬───────┴──────────┘
                           │ DCS
        ┌──────────┬───────┴───────┬──────────┐
     etcd1 .11   etcd2 .12      etcd3 .13
```

## Requirements

- Vagrant ≥ 2.4, VirtualBox ≥ 7.0
- ~10 GB free RAM (3×1024 + 3×2048 + 512)
- `192.168.56.0/24` must be allowed on the VirtualBox host-only network
  (`/etc/vbox/networks.conf` → `* 192.168.56.0/21`)

## Usage

```bash
vagrant up                 # in order: etcd → pg → haproxy
vagrant status
```

Every setting lives in `config.yaml`: box, PostgreSQL major version, Patroni and etcd
versions, node counts, IP range, RAM/CPU, passwords. The Vagrantfile reads that file and
generates a shared env file and a hosts fragment under `.generated/`.

## Verification

```bash
vagrant ssh pg1 -c "patronictl list"
```

```
+ Cluster: pgcluster -------+---------+-----------+----+-----------+
| Member | Host             | Role    | State     | TL | Lag in MB |
+--------+------------------+---------+-----------+----+-----------+
| pg1    | 192.168.56.21    | Leader  | running   |  1 |           |
| pg2    | 192.168.56.22    | Replica | streaming |  1 |         0 |
| pg3    | 192.168.56.23    | Replica | streaming |  1 |         0 |
+--------+------------------+---------+-----------+----+-----------+
```

Connecting from the host:

```bash
psql "host=192.168.56.30 port=5000 user=postgres dbname=postgres"   # write
psql "host=192.168.56.30 port=5001 user=postgres dbname=postgres"   # read
```

## Prometheus

node_exporter is installed on the nodes listed in `node_exporter.roles` in `config.yaml`
(default: `pg` only). Every `vagrant up` regenerates a ready-to-use scrape config:

```
.generated/prometheus-scrape.yml
```

Paste its contents into the `scrape_configs:` block of your existing `prometheus.yml` and
reload Prometheus. Three jobs are produced:

| Job | Port | Source |
|---|---|---|
| `<cluster>-node` | 9100 | node_exporter — CPU, memory, disk, systemd unit states |
| `<cluster>-postgres` | 9187 | postgres_exporter — `pg_stat_statements`, bloat, locks, replication |
| `<cluster>-patroni` | 8008 | Patroni REST `/metrics` — `patroni_primary`, `patroni_xlog_*` |

```bash
curl -s 192.168.56.21:9100/metrics | head
curl -s 192.168.56.21:9187/metrics | grep ^pg_stat_statements
curl -s 192.168.56.21:8008/metrics | grep ^patroni_primary
```

### Metrics proxy

With `haproxy.metrics_proxy.enabled: true`, the exporter ports of the pg nodes are
published through HAProxy. Only one address is exposed to the outside; the etcd and
PostgreSQL nodes stay closed on the host-only network.

| Target | Proxy port | Backend |
|---|---|---|
| node_exporter | 19101 / 19102 / 19103 | pg1-3 : 9100 |
| postgres_exporter | 19181 / 19182 / 19183 | pg1-3 : 9187 |
| Patroni `/metrics` | 19201 / 19202 / 19203 | pg1-3 : 8008 |

The port map is `base + node index`. `.generated/prometheus-scrape.yml` is generated from
that map, and the `instance` label still comes through as `pg1`/`pg2`/`pg3`. When a node
goes down HAProxy returns 503, so Prometheus sees `up=0` — the semantics are preserved.

The Patroni listeners only pass `GET /metrics`:

```
http-request deny unless { method GET } { path /metrics }
```

Without this, the REST API's `POST /switchover` and `POST /restart` endpoints would be
exposed as well.

The one thing to watch: if HAProxy goes down, the metrics of all three nodes disappear at
once. Since everything goes through a single proxy, you may want a separate alert for it
(`up{job="<cluster>-patroni"} == 0` for all of them simultaneously).

If you turn the proxy off (`enabled: false`), the scrape config targets automatically fall
back to the nodes' own IPs and real ports.

### pg_stat_statements

`shared_preload_libraries` and the `pg_stat_statements.*` parameters are defined in the
bootstrap template; the extension itself is created on the leader by
`postgres_exporter.sh` with `CREATE EXTENSION IF NOT EXISTS` and reaches the standbys
through physical replication.

If the cluster is already running, the GUCs have to be added to the DCS afterwards:

```bash
vagrant ssh pg1 -c "patronictl edit-config --force \
  -s 'postgresql.parameters.pg_stat_statements.max=10000' \
  -s 'postgresql.parameters.pg_stat_statements.track=top'"
vagrant ssh pg1 -c "patronictl restart pgcluster --force"   # .max requires a restart
```

The `pgexporter` role is a member of `pg_monitor`, which is enough to see other users'
queries in the `pg_stat_statements` view. If you want the query text in the metrics as
well, add `--collector.stat_statements.include_query` to the service file — it increases
cardinality significantly.

If Prometheus runs on another machine it cannot reach the `192.168.56.0/24` host-only
network; you need a reverse proxy on the VirtualBox host, or a bridged adapter.

HAProxy stats: <http://192.168.56.30:7000/>

### Access from the host

The host-only adapter works both ways, so `192.168.56.30` is directly reachable from the
host with no extra setup. On top of that, `haproxy.forward_ports: true` in `config.yaml`
also forwards ports 5000/5001/7000 to the host's `127.0.0.1`:

```bash
psql "host=127.0.0.1 port=5000 user=postgres dbname=postgres"
```

NAT rules added by hand through the VirtualBox GUI do not survive: on every `up`/`reload`
Vagrant rebuilds the network configuration from its own definition in the "Clearing any
previously set network interfaces" step. That is why the rule has to live in the
Vagrantfile.

If the host port is already taken by another service, set `forward_offset`
(`10` → 5010/5011/7010).

### Access from other machines on the network

There are two ways:

**Open the NAT forwarding on all interfaces.** Set `forward_host_ip: "0.0.0.0"` and run
`vagrant reload haproxy`. Clients then connect to the host's LAN IP. On Windows a firewall
rule is required:

```powershell
New-NetFirewallRule -DisplayName "Patroni HAProxy" -Direction Inbound `
  -Protocol TCP -LocalPort 5000,5001,7000 -Action Allow -Profile Private
```

**Bridged adapter (recommended).** The HAProxy VM gets its own IP from the router and the
host is out of the path:

```yaml
haproxy:
  bridge:
    enabled: true
    interface: "Intel(R) Wi-Fi 6 AX201"   # check with `VBoxManage list bridgedifs`
    ip: "192.168.1.30"                    # an address OUTSIDE the DHCP pool
```

After `vagrant reload haproxy`, clients connect straight to `192.168.1.30:5000`. It keeps
working while the host is off, needs no firewall rule, and `pg_stat_activity.client_addr`
shows the real client. If `interface` is left empty, Vagrant asks at boot which adapter to
bridge; if `ip` is left empty, the router hands out DHCP (the address can change).

Some wireless drivers do not allow bridged mode; in that case fall back to the first
method.

## Test scenarios

```bash
# Planned switchover
vagrant ssh pg1 -c "patronictl switchover --leader pg1 --candidate pg2 --force"

# Failover (hard-stop the leader)
vagrant halt pg1 -f
vagrant ssh pg2 -c "patronictl list"

# Bring the old leader back → it rejoins as a replica via pg_rewind
vagrant up pg1
vagrant ssh pg1 -c "journalctl -u patroni -n 50 --no-pager"

# Loss of etcd quorum (take down 2 of 3 → the cluster goes read-only)
vagrant halt etcd2 etcd3

# Parameter change (distributed across the whole cluster)
vagrant ssh pg1 -c "patronictl edit-config -s 'max_connections=300'"
vagrant ssh pg1 -c "patronictl restart pgcluster --force"

# Synchronous replication
vagrant ssh pg1 -c "patronictl edit-config -s 'synchronous_mode=true'"
```

## Re-provisioning

```bash
vagrant provision pg2                      # all steps
vagrant provision pg2 --provision-with patroni
vagrant destroy -f && vagrant up           # from scratch
```

If `etcd.sh` finds an existing `member/` directory it writes
`initial-cluster-state: existing`, so re-provisioning does not break the cluster.

## Lab shortcuts vs. production

Points that are deliberately simplified:

| Topic | Here | In production |
|---|---|---|
| SELinux | `permissive` (`config.yaml`) | `enforcing` + policy |
| etcd | plain HTTP, no auth | mTLS + RBAC |
| Patroni REST | HTTP, auth only on unsafe methods | TLS + client cert |
| `archive_command` | `/bin/true` | pgBackRest / WAL-G |
| PGDATA | on the root disk | separate LVM/disk |
| Passwords | plain text in `config.yaml` | Vault / env |
| `synchronous_mode` | off | on, depending on data-loss tolerance |

## Troubleshooting

```bash
vagrant ssh etcd1 -c "sudo systemctl status etcd; sudo journalctl -u etcd -n 50 --no-pager"
vagrant ssh etcd1 -c "etcdctl endpoint status --write-out=table"
vagrant ssh pg1   -c "sudo tail -100 /var/log/patroni/patroni.log"
vagrant ssh pg1   -c "curl -s localhost:8008/patroni | jq"
vagrant ssh pg1   -c "sudo tail -50 /var/lib/pgsql/17/data/log/postgresql-*.log"
```

> Because Patroni is configured with `log.dir: /var/log/patroni` it does not write to
> stderr; `journalctl -u patroni` only shows the "Started" line. The real log is in
> **`/var/log/patroni/patroni.log`**. If you want it in journald, remove the `log:` block
> from `patroni.yml`.

Common problems:

- **`vagrant up` fails on private_network** → VirtualBox 7 only allows the
  `192.168.56.0/21` range; check `/etc/vbox/networks.conf`.
- **Patroni starts but no leader is elected** → no etcd quorum. Check with `etcdctl
  endpoint health` whether 2 of 3 members are up.
- **`/dev/watchdog` permission denied** → the udev rule may not have been applied after
  `modprobe softdog`; you can work around it with `watchdog.mode: off` in `patroni.yml`.
- **`nothing provides perl(IPC::Run)`** → the CRB repository is disabled and dnf is trying
  to satisfy `libpq-devel` with `postgresqlXX-devel` from PGDG. `patroni.sh` now enables
  CRB and does not install `libpq-devel`/`gcc`; update if you are on an older version.
- **"Machine already provisioned" when re-running `vagrant up`** → Vagrant marks the
  machine even if provisioning failed. Use `vagrant up --provision`, or
  `vagrant provision pg1` per node.
- **`AttributeError: 'bool' object has no attribute 'read'`** → there is a boolean value in
  the dict form of `basebackup` (e.g. `verbose: true`). Patroni passes every value through
  `shlex.split()`, so non-string values blow up. Flag-style options must be given as bare
  elements in list form.
- **A replica is stuck in `creating replica`** → the firewall may be blocking 5432 during
  `basebackup`.

## File layout

```
.
├── Vagrantfile               # builds the topology from config.yaml
├── config.yaml               # the single place to configure everything
├── provision/
│   ├── common.sh             # hosts, SELinux, sysctl, firewalld, chrony
│   ├── etcd.sh               # etcd binary + config + systemd
│   ├── patroni.sh            # PGDG, venv, patroni.yml, watchdog, systemd
│   ├── haproxy.sh            # haproxy + config
│   ├── node_exporter.sh      # prometheus node_exporter
│   ├── postgres_exporter.sh  # postgres_exporter + pg_stat_statements
│   └── templates/
│       ├── patroni.yml.tpl
│       └── haproxy.cfg.tpl
└── .generated/               # produced by vagrant (do not commit)
```
