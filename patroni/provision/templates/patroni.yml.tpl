scope: ${CLUSTER_NAME}
namespace: /service/
name: ${NODE_NAME}

log:
  level: INFO
  dir: /var/log/patroni
  file_num: 7
  file_size: 26214400

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: ${PATRONI_REST_PASSWORD}

etcd3:
  hosts: ${ETCD_ENDPOINTS}
  protocol: http

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    master_start_timeout: 300
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        superuser_reserved_connections: 5
        shared_buffers: 512MB
        effective_cache_size: 1536MB
        work_mem: 8MB
        maintenance_work_mem: 128MB
        wal_level: replica
        hot_standby: "on"
        wal_log_hints: "on"
        wal_keep_size: 1GB
        max_wal_senders: 10
        max_replication_slots: 10
        max_worker_processes: 8
        wal_compression: "on"
        checkpoint_completion_target: 0.9
        min_wal_size: 512MB
        max_wal_size: 2GB
        random_page_cost: 1.1
        archive_mode: "on"
        archive_command: "/bin/true"
        password_encryption: scram-sha-256
        log_destination: stderr
        logging_collector: "on"
        log_directory: log
        log_filename: postgresql-%a.log
        log_line_prefix: "%m [%p] %q%u@%d "
        log_checkpoints: "on"
        log_connections: "on"
        log_lock_waits: "on"
        log_min_duration_statement: 1000
        log_autovacuum_min_duration: 0
        track_io_timing: "on"
        shared_preload_libraries: "pg_stat_statements"
        pg_stat_statements.max: 10000
        pg_stat_statements.track: top
        pg_stat_statements.track_utility: "off"
        pg_stat_statements.save: "on"

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  pg_hba:
    - local   all             all                                     peer
    - host    all             all             127.0.0.1/32            scram-sha-256
    - host    all             all             ${NETWORK_PREFIX}.0/24  scram-sha-256
    - host    replication     replicator      127.0.0.1/32            scram-sha-256
    - host    replication     replicator      ${NETWORK_PREFIX}.0/24  scram-sha-256

  post_bootstrap: /bin/true

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: ${PGDATA}
  bin_dir: ${PGBIN}
  config_dir: ${PGDATA}
  pgpass: /var/lib/pgsql/.pgpass_patroni
  use_unix_socket: true
  authentication:
    superuser:
      username: postgres
      password: ${SUPERUSER_PASSWORD}
    replication:
      username: replicator
      password: ${REPLICATION_PASSWORD}
    rewind:
      username: rewind_user
      password: ${REWIND_PASSWORD}
  parameters:
    unix_socket_directories: /var/run/postgresql,/tmp
  create_replica_methods:
    - basebackup
  # Liste formu: bayraklar cippak string, argumanlilar tek anahtarli map.
  # Dict formunda "verbose: true" -> "--verbose=True" uretilir ve
  # pg_basebackup bunu reddeder.
  basebackup:
    - max-rate: "100M"
    - checkpoint: "fast"

watchdog:
  mode: automatic
  device: /dev/watchdog
  safety_margin: 5

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
