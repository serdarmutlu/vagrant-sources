# Patroni HA Lab — Vagrant + VirtualBox + Rocky Linux 9

etcd (3) + PostgreSQL/Patroni (3) + HAProxy (1) topolojisini tek komutla ayağa
kaldırır. Her servis kendi VM'inde çalışır.

```
                    ┌──────────────┐
   uygulama ───────▶│   haproxy    │  :5000 → leader (write)
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

## Gereksinimler

- Vagrant ≥ 2.4, VirtualBox ≥ 7.0
- ~10 GB boş RAM (3×1024 + 3×2048 + 512)
- VirtualBox host-only ağında `192.168.56.0/24` izinli olmalı
  (`/etc/vbox/networks.conf` → `* 192.168.56.0/21`)

## Kullanım

```bash
vagrant up                 # sırayla etcd → pg → haproxy
vagrant status
```

Ayarların tamamı `config.yaml` içinde: box, PostgreSQL major sürümü, Patroni ve
etcd sürümleri, node sayıları, IP aralığı, RAM/CPU, şifreler. Vagrantfile bu
dosyayı okuyup `.generated/` altına ortak env ve hosts fragment'ı üretir.

## Doğrulama

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

Host'tan bağlantı:

```bash
psql "host=192.168.56.30 port=5000 user=postgres dbname=postgres"   # write
psql "host=192.168.56.30 port=5001 user=postgres dbname=postgres"   # read
```

## Prometheus

`config.yaml` içindeki `node_exporter.roles` listesindeki node'lara node_exporter
kurulur (varsayılan: sadece `pg`). `vagrant up` her çalıştığında hazır bir scrape
config üretilir:

```
.generated/prometheus-scrape.yml
```

İçeriğini mevcut `prometheus.yml`'ınızın `scrape_configs:` bloğuna ekleyip
Prometheus'u reload edin. Üç job gelir:

| Job | Port | Kaynak |
|---|---|---|
| `<cluster>-node` | 9100 | node_exporter — CPU, bellek, disk, systemd unit durumları |
| `<cluster>-postgres` | 9187 | postgres_exporter — `pg_stat_statements`, bloat, lock, replikasyon |
| `<cluster>-patroni` | 8008 | Patroni REST `/metrics` — `patroni_primary`, `patroni_xlog_*` |

```bash
curl -s 192.168.56.21:9100/metrics | head
curl -s 192.168.56.21:9187/metrics | grep ^pg_stat_statements
curl -s 192.168.56.21:8008/metrics | grep ^patroni_primary
```

### Metrik proxy

`haproxy.metrics_proxy.enabled: true` iken pg node'larının exporter portları
HAProxy üzerinden yayınlanır. Dışarıya tek bir adres açılır; etcd ve PostgreSQL
node'ları host-only ağında kapalı kalır.

| Hedef | Proxy portu | Arka uç |
|---|---|---|
| node_exporter | 19101 / 19102 / 19103 | pg1-3 : 9100 |
| postgres_exporter | 19181 / 19182 / 19183 | pg1-3 : 9187 |
| Patroni `/metrics` | 19201 / 19202 / 19203 | pg1-3 : 8008 |

Port haritası `base + node sırası`. `.generated/prometheus-scrape.yml` bu
haritaya göre üretilir, `instance` etiketi yine `pg1`/`pg2`/`pg3` olarak gelir.
Bir node düştüğünde HAProxy 503 döndüğü için Prometheus `up=0` görür, yani
semantik bozulmaz.

Patroni listener'ları sadece `GET /metrics` geçirir:

```
http-request deny unless { method GET } { path /metrics }
```

Bu olmadan REST API'nin `POST /switchover`, `POST /restart` uçları da dışarıya
açılmış olurdu.

Dikkat edilmesi gereken tek nokta: HAProxy düşerse üç node'un metriği birden
kaybolur. Tek bir proxy üzerinden gittiği için bunu ayrı bir alert ile takip
etmek isteyebilirsiniz (`up{job="<cluster>-patroni"} == 0` hepsi aynı anda).

Proxy'yi kapatırsanız (`enabled: false`) scrape config hedefleri otomatik olarak
node'ların kendi IP'lerine ve gerçek portlarına döner.

### pg_stat_statements

`shared_preload_libraries` ve `pg_stat_statements.*` parametreleri bootstrap
şablonunda tanımlı; eklenti `postgres_exporter.sh` tarafından leader üzerinde
`CREATE EXTENSION IF NOT EXISTS` ile kuruluyor ve fiziksel replikasyonla
standby'lara geçiyor.

Cluster zaten ayaktaysa GUC'lar DCS'e sonradan eklenmeli:

```bash
vagrant ssh pg1 -c "patronictl edit-config --force \
  -s 'postgresql.parameters.pg_stat_statements.max=10000' \
  -s 'postgresql.parameters.pg_stat_statements.track=top'"
vagrant ssh pg1 -c "patronictl restart pgcluster --force"   # .max restart ister
```

`pgexporter` rolü `pg_monitor` üyesidir; `pg_stat_statements` view'ında diğer
kullanıcıların sorgularını görmek için bu yeterlidir. Sorgu metnini metriklere
eklemek isterseniz servis dosyasına `--collector.stat_statements.include_query`
ekleyin — kardinaliteyi ciddi şekilde artırır.

Prometheus başka bir makinedeyse `192.168.56.0/24` host-only ağına erişemez;
VirtualBox host'undan reverse proxy ya da bridged adaptör gerekir.

HAProxy stats: <http://192.168.56.30:7000/>

### Host'tan erişim

Host-only adaptör iki yönlü çalışır, yani `192.168.56.30` doğrudan host'tan
erişilebilir; ekstra bir şey gerekmez. Buna ek olarak `config.yaml` içindeki
`haproxy.forward_ports: true` ile 5000/5001/7000 portları host'un
`127.0.0.1`'ine de yönlendirilir:

```bash
psql "host=127.0.0.1 port=5000 user=postgres dbname=postgres"
```

VirtualBox arayüzünden elle eklenen NAT kuralları kalıcı olmaz: Vagrant her
`up`/`reload` işleminde "Clearing any previously set network interfaces" adımıyla
ağ yapılandırmasını kendi tanımından yeniden kurar. Kural bu yüzden Vagrantfile'da
durmalı.

Host portu başka bir servis tarafından kullanılıyorsa `forward_offset` verin
(`10` → 5010/5011/7010).

### Ağdaki diğer makinelerden erişim

İki yol var:

**NAT yönlendirmesini tüm arayüzlere açmak.** `forward_host_ip: "0.0.0.0"` yapıp
`vagrant reload haproxy`. İstemciler host'un LAN IP'sine bağlanır. Windows'ta
güvenlik duvarı kuralı gerekir:

```powershell
New-NetFirewallRule -DisplayName "Patroni HAProxy" -Direction Inbound `
  -Protocol TCP -LocalPort 5000,5001,7000 -Action Allow -Profile Private
```

**Bridged adaptör (önerilen).** HAProxy VM'i router'dan kendi IP'sini alır, host
aradan çıkar:

```yaml
haproxy:
  bridge:
    enabled: true
    interface: "Intel(R) Wi-Fi 6 AX201"   # `VBoxManage list bridgedifs` ile bakın
    ip: "192.168.1.30"                    # DHCP havuzunun DIŞINDA bir adres
```

`vagrant reload haproxy` sonrası istemciler doğrudan `192.168.1.30:5000`'e
bağlanır. Host kapalıyken de çalışır, güvenlik duvarı kuralı gerekmez ve
`pg_stat_activity.client_addr` gerçek istemciyi gösterir. `interface` boş
bırakılırsa Vagrant açılışta hangi adaptörün köprüleneceğini sorar; `ip` boş
bırakılırsa router DHCP verir (adres değişebilir).

Kablosuz bağlantılarda bazı sürücüler bridged moda izin vermez; o durumda birinci
yönteme dönün.

## Test senaryoları

```bash
# Planlı switchover
vagrant ssh pg1 -c "patronictl switchover --leader pg1 --candidate pg2 --force"

# Failover (leader'ı sert kapat)
vagrant halt pg1 -f
vagrant ssh pg2 -c "patronictl list"

# Eski leader'ı geri al → pg_rewind ile replica olarak döner
vagrant up pg1
vagrant ssh pg1 -c "journalctl -u patroni -n 50 --no-pager"

# etcd quorum kaybı (2/3 düşür → cluster read-only'ye geçer)
vagrant halt etcd2 etcd3

# Parametre değişikliği (tüm cluster'a dağıtılır)
vagrant ssh pg1 -c "patronictl edit-config -s 'max_connections=300'"
vagrant ssh pg1 -c "patronictl restart pgcluster --force"

# Senkron replikasyon
vagrant ssh pg1 -c "patronictl edit-config -s 'synchronous_mode=true'"
```

## Yeniden provisioning

```bash
vagrant provision pg2                      # tüm adımlar
vagrant provision pg2 --provision-with patroni
vagrant destroy -f && vagrant up           # sıfırdan
```

`etcd.sh` mevcut `member/` dizinini görürse `initial-cluster-state: existing`
ile yazar, böylece tekrar provision cluster'ı bozmaz.

## Lab kısayolları vs. production farkları

Bilinçli olarak basitleştirilen noktalar:

| Konu | Burada | Production'da |
|---|---|---|
| SELinux | `permissive` (`config.yaml`) | `enforcing` + policy |
| etcd | düz HTTP, auth yok | mTLS + RBAC |
| Patroni REST | HTTP, sadece unsafe metodlarda auth | TLS + client cert |
| `archive_command` | `/bin/true` | pgBackRest / WAL-G |
| PGDATA | root diskte | ayrı LVM/disk |
| Şifreler | `config.yaml` düz metin | Vault / env |
| `synchronous_mode` | kapalı | veri kaybı toleransına göre açık |

## Sorun giderme

```bash
vagrant ssh etcd1 -c "sudo systemctl status etcd; sudo journalctl -u etcd -n 50 --no-pager"
vagrant ssh etcd1 -c "etcdctl endpoint status --write-out=table"
vagrant ssh pg1   -c "sudo tail -100 /var/log/patroni/patroni.log"
vagrant ssh pg1   -c "curl -s localhost:8008/patroni | jq"
vagrant ssh pg1   -c "sudo tail -50 /var/lib/pgsql/17/data/log/postgresql-*.log"
```

> Patroni `log.dir: /var/log/patroni` ile yapılandırıldığı için stderr'e
> yazmaz; `journalctl -u patroni` yalnızca "Started" satırını gösterir.
> Gerçek log **`/var/log/patroni/patroni.log`** içindedir. journald'de görmek
> isterseniz `patroni.yml`'daki `log:` bloğunu kaldırın.

Sık karşılaşılanlar:

- **`vagrant up` private_network hatası** → VirtualBox 7 sadece
  `192.168.56.0/21` aralığına izin verir; `/etc/vbox/networks.conf` kontrol edin.
- **Patroni başlıyor ama leader seçilmiyor** → etcd quorum yok. `etcdctl
  endpoint health` ile 2/3 üye ayakta mı bakın.
- **`/dev/watchdog` permission denied** → `modprobe softdog` sonrası udev
  kuralı uygulanmamış olabilir; `patroni.yml` içinde `watchdog.mode: off`
  yapıp geçebilirsiniz.
- **`nothing provides perl(IPC::Run)`** → CRB deposu kapalı ve dnf `libpq-devel`'i
  PGDG'deki `postgresqlXX-devel` ile karşılamaya çalışıyor. `patroni.sh` artık
  CRB'yi açıyor ve `libpq-devel`/`gcc` kurmuyor; eski sürümdeyseniz güncelleyin.
- **`vagrant up` tekrar çalıştırınca "Machine already provisioned"** → provisioning
  hata verse de Vagrant makineyi işaretliyor. `vagrant up --provision` ya da
  tek tek `vagrant provision pg1` kullanın.
- **`AttributeError: 'bool' object has no attribute 'read'`** → `basebackup`
  dict formunda boolean değer var (ör. `verbose: true`). Patroni her değeri
  `shlex.split()`'ten geçirdiği için string olmayan değerler patlar. Bayrak
  seçenekleri liste formunda çıplak eleman olarak verilmeli.
- **Replica `creating replica` durumunda takılı** → `basebackup` sırasında
  firewall 5432'yi kapatıyor olabilir.

## Dosya yapısı

```
.
├── Vagrantfile               # topolojiyi config.yaml'dan üretir
├── config.yaml               # tek ayar noktası
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
└── .generated/               # vagrant tarafından üretilir (git'e koymayın)
```
