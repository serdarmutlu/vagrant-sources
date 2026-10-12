# PostgreSQL Primary + Standby - plain (node_exporter yok)

Rocky Linux 9 / VirtualBox / PostgreSQL 17 (PGDG), 1 primary + 1 hot standby (streaming replication).
Tek ayar noktasi: `config.yaml`. Ortam degiskeni gerekmez; komutlari bu klasorde calistirin.

| Node       | Rol     | IP        | VM adi                  |
|------------|---------|-----------|-------------------------|
| pg-primary | primary | 192.168.56.21  | pgrepl-plain-pg-primary |
| pg-standby | standby | 192.168.56.22  | pgrepl-plain-pg-standby |

## Kurulum

```
vagrant up
vagrant ssh pg-primary
vagrant ssh pg-standby
```

Sira: primary (initdb, replikasyon, `replicator` rolu, slot) -> standby (`pg_basebackup`, `standby.signal`).
Her iki node'a `system_stats_17` paketi kurulur; `CREATE EXTENSION system_stats` elle yapilir
(primary'de calistirin, standby'a WAL ile gelir).

## Dogrulama

```
vagrant ssh pg-primary -c "sudo -u postgres psql -x -c 'SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication'"
vagrant ssh pg-standby -c "sudo -u postgres psql -c 'SELECT pg_is_in_recovery()'"
vagrant ssh pg-standby -c "rpm -q system_stats_17"
```

## Not

Bu klasorde node_exporter yoktur (script ve ayar bilerek eklenmedi). Diger klasor
`pg-ps-node-exporter` ayri IP araligi (.11/.12) ve ayri VM adlariyla kullandigi icin ikisi ayni anda calisabilir.
