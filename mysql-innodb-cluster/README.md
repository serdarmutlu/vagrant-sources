# MySQL 8.4 LTS InnoDB Cluster – Vagrant lab

Rocky Linux 9 / VirtualBox / MySQL 8.4 LTS (resmi MySQL yum reposu).
Tek ayar noktası `config.yaml`. Ortam değişkeni gerekmez; komutları bu klasörde çalıştırın.

| Node     | Rol                                     | IP            | VM adı         |
|----------|-----------------------------------------|---------------|----------------|
| mysql1   | Group Replication üyesi (ilk primary)   | 192.168.56.41 | mylab-mysql1   |
| mysql2   | Group Replication üyesi                 | 192.168.56.42 | mylab-mysql2   |
| mysql3   | Group Replication üyesi                 | 192.168.56.43 | mylab-mysql3   |
| myrouter | MySQL Router + MySQL Shell              | 192.168.56.40 | mylab-myrouter |

Kaynak: 3 × 2 GB + 1 GB RAM. İzleme: node_exporter (hepsi, :9100), mysqld_exporter (db node'ları, :9104).

## HA kurgusu

- **Group Replication, single-primary:** 3 üye, çoğunluk (2/3) ayakta olduğu sürece grup yazılabilir kalır.
  Primary düşerse kalan üyeler otomatik yeni primary seçer (saniyeler içinde).
- **MySQL Router:** Uygulama tek adrese bağlanır, Router metadata'dan topolojiyi izler ve trafiği yönlendirir.
- **MySQL Shell AdminAPI:** Cluster kurulumu, node ekleme (clone ile), switchover, rejoin ve tam kapanış sonrası
  reboot işlemleri bunun üzerinden yapılır.

| Router portu | Ne işe yarar |
|--------------|--------------|
| 6446 | Okuma/yazma, her zaman primary'ye gider |
| 6447 | Salt okuma, secondary'lere round-robin |
| 6450 | Okuma/yazma ayrımı: tek bağlantıda okumaları secondary'ye, yazmaları primary'ye yollar |
| 6448 / 6449 | X protocol, RW / RO |

## Kurulum

```
vagrant up
```

Sıra: `mysql1 → mysql2 → mysql3 → myrouter`.
DB node'larına MySQL kurulur, root şifresi ve `clusteradmin` kullanıcısı oluşturulur. Bu aşamada henüz cluster yoktur.
Cluster, `myrouter` provision'ında kurulur (`provision/cluster.py`):
`mysql1` üzerinde `dba.create_cluster()`, ardından `mysql2` ve `mysql3` **clone** ile eklenir.
Sonra uygulama veritabanı ve kullanıcısı (`appdb` / `appuser`) primary'de oluşturulur ve Router bootstrap edilir.

Provision script'leri idempotent çalışır. `vagrant provision myrouter` eksik node'ları ekler, kopmuş node'ları geri alır.
Tüm node'lar kapalıysa cluster'ı reboot eder.

## Doğrulama

```
vagrant ssh myrouter -c "ic status"
vagrant ssh myrouter -c "mysql -h127.0.0.1 -P6446 -uappuser -pAppPass123! -e 'SELECT @@hostname'"
vagrant ssh myrouter -c "mysql -h127.0.0.1 -P6447 -uappuser -pAppPass123! -e 'SELECT @@hostname'"
```

Host'tan (veya DBMind'dan) bağlantı:

```
jdbc:mysql://192.168.56.40:6446/appdb      # RW
jdbc:mysql://192.168.56.40:6447/appdb      # RO
```

`clusteradmin` (tüm yetkiler) ile doğrudan node'lara da bağlanabilirsiniz: `192.168.56.41-43:3306`.

## `ic` yardımcı komutu

Tüm node'larda `/usr/local/bin/ic` vardır (kendini sudo ile yükseltir):

```
ic status                 # cluster.status()
ic extended               # ayrıntılı durum
ic switchover mysql2      # planlı primary değişimi
ic rejoin mysql3          # kopan node'u geri al
ic reboot                 # tüm node'lar kapandıktan sonra
ic routers                # kayıtlı router'lar
ic sql "SELECT * FROM performance_schema.replication_group_members"
ic shell                  # mysqlsh (Python modu)
```

## HA testleri

**1. Primary çökmesi (otomatik failover)**

```
vagrant ssh myrouter -c "ic status"                    # primary hangisi?
vagrant halt mysql1                                    # primary'yi kapat
vagrant ssh myrouter -c "ic status"                    # yeni primary seçildi, mysql1 (MISSING)
vagrant ssh myrouter -c "mysql -h127.0.0.1 -P6446 -uappuser -pAppPass123! -e 'SELECT @@hostname'"
vagrant up mysql1                                      # geri açılınca gruba kendisi katılır
```

Sadece mysqld süreci öldürülürse (`sudo systemctl kill -s SIGKILL mysqld`) systemd onu yeniden başlatır ve
node gruba otomatik döner.

**2. Planlı switchover**

```
vagrant ssh myrouter -c "ic switchover mysql2"
```

**3. Çoğunluk kaybı**

İki node kapatılırsa kalan tek node azınlıkta kalır ve yazmaya kapanır. Bu davranış split-brain'i önler.
Node'lardan biri geri açılınca grup yeniden çoğunluğa ulaşır.

**4. Tam kapanış (`vagrant halt` → `vagrant up`)**

Hiçbir üye ayakta kalmadığında grup kendiliğinden başlamaz. Mevcut VM'ler için `vagrant up` provision çalıştırmaz:

```
vagrant up
vagrant ssh myrouter -c "ic reboot"
```

(Alternatif: `vagrant provision myrouter`.)

## İzleme (Prometheus exporter'ları)

| Exporter | Node'lar | Port | Not |
|---|---|---|---|
| node_exporter 1.13.1 | hepsi (db + router) | 9100 | systemd collector: `mysqld`, `mysqlrouter`, exporter servislerinin durumu |
| mysqld_exporter 0.21.0 | mysql1-3 | 9104 | Group Replication + InnoDB collector'ları açık |

- Binary'ler GitHub release'inden indirilir ve `sha256sums.txt` ile doğrulanır. Servisler ayrı sistem kullanıcısıyla,
  systemd hardening ile çalışır. Portlar sadece `192.168.56.0/24`'ten açıktır; host (192.168.56.1) doğrudan scrape edebilir.
- mysqld_exporter, her node'da `127.0.0.1:3306`'ya `exporter` kullanıcısıyla bağlanır
  (`PROCESS, REPLICATION CLIENT, SELECT`, en fazla 3 bağlantı). Kullanıcı `cluster.py` tarafından primary'de
  oluşturulur ve tüm node'lara replike olur. İlk kurulumda db node'ları router'dan önce ayağa kalktığı için
  exporter'lar birkaç dakika `mysql_up 0` döndürür. Router provision'ı bitince düzelir.
- Açılan collector'lar: `replication_group_members`, `replication_group_member_stats`,
  `replication_applier_status_by_worker`, `info_schema.innodb_metrics`, `perf_schema.eventswaits/tableiowaits/indexiowaits`,
  `binlog_size`. Kurulu sürümün `--help` çıktısında olmayan bayrak uyarıyla atlanır, böylece exporter
  bilinmeyen bayrak yüzünden başlamamazlık yapmaz.
- Her `vagrant` komutunda `.generated/prometheus-scrape.yml` üretilir. İçeriğini Prometheus'un `scrape_configs`
  bölümüne ekleyin. `node`, `role` ve `cluster` label'ları hazırdır.

Kontrol:

```
vagrant ssh mysql1 -c "curl -s localhost:9104/metrics | grep -E '^mysql_up|mysql_perf_schema_replication_group_member_info'"
vagrant ssh myrouter -c "curl -s localhost:9100/metrics | grep node_systemd_unit_state | grep active"
```

Açma/kapama: `config.yaml`'da `enabled` değerini değiştirip

```
vagrant provision --provision-with monitoring
```

Kapatılan exporter'ın servisi, binary'si, kullanıcısı ve firewall kuralı kaldırılır.

### Çalışan bir ortama eklemek

Cluster'ı önceki sürümle kurduysanız yeniden kurmanız gerekmez:

```
vagrant provision --provision-with monitoring          # 4 node'a exporter'lar
vagrant provision myrouter --provision-with router     # exporter MySQL kullanıcısı (cluster.py)
```

İkinci komut idempotent çalışır. Cluster ve Router zaten kurulu olduğu için sadece eksik kullanıcıyı ekler.

## Bilinmesi gerekenler

- **Primary key zorunlu:** Group Replication, primary key'i olmayan tablolarda DML'i reddeder.
  Test şemalarında her tabloya PK ekleyin.
- Sadece InnoDB kullanılabilir. MyISAM, MEMORY vb. `disabled_storage_engines` ile kapatıldı.
- SELinux permissive (lab). MySQL portları firewalld ile sadece `192.168.56.0/24`'ten açık, Router portları herkese açık.
- Şifreler `config.yaml`'da düz metin durur (lab). Şifrelerde `$ \` " \ '` kullanmayın.
- Script'ler Vagrantfile tarafından CRLF temizlenerek inline gönderilir; Windows host'ta git CRLF ile checkout etse
  bile sorun çıkmaz. `.gitattributes` de LF'yi zorlar.
- Router'ı yeniden bootstrap etmek için:
  `vagrant ssh myrouter -c "sudo rm /etc/mysqlrouter/mysqlrouter.conf"` ve ardından `vagrant provision myrouter --provision-with router`.

## Dosyalar

```
config.yaml              tek ayar noktası
Vagrantfile
provision/common.sh      /etc/hosts, timezone, SELinux, firewalld, MySQL reposu (tüm node'lar)
provision/mysql.sh       MySQL kurulum, my.cnf, initialize, root + clusteradmin (db node'ları)
provision/cluster.py     InnoDB Cluster kurulum/onarım (mysqlsh --py, myrouter'da çalışır)
provision/router.sh      mysql-shell + router kurulum, cluster.py, Router bootstrap
provision/exporters.sh   node_exporter + mysqld_exporter kurulum/kaldırma
.generated/              (vagrant üretir) prometheus-scrape.yml
provision/bin/ic         yardımcı komut
```
