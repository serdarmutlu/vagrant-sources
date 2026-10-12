# PostgreSQL Primary + Standby - node_exporter'li

Rocky Linux 9 / VirtualBox / PostgreSQL 17 (PGDG), 1 primary + 1 hot standby (streaming replication).
Tek ayar noktasi: `config.yaml`. Ortam degiskeni gerekmez; komutlari bu klasorde calistirin.

| Node       | Rol     | IP        | VM adi                  |
|------------|---------|-----------|-------------------------|
| pg-primary | primary | 192.168.56.11  | pgrepl-ne-pg-primary |
| pg-standby | standby | 192.168.56.12  | pgrepl-ne-pg-standby |

## Kurulum

```
vagrant up
vagrant ssh pg-primary
vagrant ssh pg-standby
```

Sira: primary (initdb, replikasyon, `replicator` rolu, slot) -> standby (`pg_basebackup`, `standby.signal`), ardindan node_exporter.
Her iki node'a `system_stats_17` paketi kurulur; `CREATE EXTENSION system_stats` elle yapilir
(primary'de calistirin, standby'a WAL ile gelir).

## Dogrulama

```
vagrant ssh pg-primary -c "sudo -u postgres psql -x -c 'SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication'"
vagrant ssh pg-standby -c "sudo -u postgres psql -c 'SELECT pg_is_in_recovery()'"
vagrant ssh pg-standby -c "rpm -q system_stats_17"
```

## node_exporter

Port `9100`, sadece lab subnet'inden erisilir (firewalld). Binary sha256 ile dogrulanir, systemd servisi
olarak ayri kullanici ile calisir. Textfile collector: `/var/lib/node_exporter/textfile-collector`.

```
vagrant ssh pg-primary -c "curl -s localhost:9100/metrics | head -3"
```

Prometheus:

```yaml
- job_name: pg-ne
  static_configs:
    - targets: ['192.168.56.11:9100', '192.168.56.12:9100']
```

Bu klasorde node_exporter'i kapatmak icin `config.yaml` -> `monitoring.node_exporter.enabled: false`
yapip `vagrant provision --provision-with node_exporter` calistirin (onceki kurulum kaldirilir).
