# Oracle 19c RAC + Data Guard Laboratuvarı (Oracle Linux 9)

*[For the English version: README.md](README.md)*

Sıfırdan eksiksiz bir Oracle 19c laboratuvarı kuran Vagrant/VirtualBox yapılandırması:

* ASM üzerinde çalışan **2 düğümlü Real Application Clusters (RAC)** birincil veritabanı,
* **Data Guard** ile (broker yönetiminde) senkron tutulan **tek örnekli fiziksel yedek
  (physical standby)** veritabanı,
* kümenin SCAN adını çözümleyen küçük bir **DNS sunucusu**.

Kurulumun tamamı kabuk betikleriyle, elle müdahale olmadan yapılır: sessiz (silent) Grid
Infrastructure ve Database kurulumları, RU yamaları, `dbca`, `RMAN DUPLICATE ... FOR
STANDBY FROM ACTIVE DATABASE` ve `dgmgrl` ile broker yapılandırması.

> Bu dizindeki Vagrant betikleri, Tim Hall'ın (Oracle-Base)
> [oraclebase/vagrant](https://github.com/oraclebase/vagrant) çalışması baz alınarak
> hazırlanmıştır. Ayrıntı için [Kaynak ve teşekkür](#kaynak-ve-teşekkür) bölümüne bakın.

---

## Kurulan ortam

| Sanal makine | Vagrant dizini | Sunucu adı | Public IP | Private IP | RAM | CPU | Rolü |
|--------------|----------------|------------|-----------|------------|-----|-----|------|
| `ol9_19_dns`  | `dns/`     | `ol9-19-dns`  | 192.168.56.100 | – | 1 GB | 2 | dnsmasq; SCAN ve tüm lab sunucularını çözümler |
| `ol9_19_rac2` | `node2/`   | `ol9-19-rac2` | 192.168.56.102 | 192.168.1.102 | 8 GB | 4 | RAC düğüm 2 (`cdbrac2`, `+ASM2`) |
| `ol9_19_rac1` | `node1/`   | `ol9-19-rac1` | 192.168.56.101 | 192.168.1.101 | 8 GB | 4 | RAC düğüm 1 (`cdbrac1`, `+ASM1`) — küme kurulumunu yürüten düğüm |
| `ol9_19_sb`   | `standby/` | `ol9-19-sb`   | 192.168.56.108 | – | 4 GB | 2 | Fiziksel yedek (`cdbsb`), dosya sistemi depolama |

Dört makine aynı anda çalışırsa ana makinede yaklaşık **21 GB RAM** ve **~300 GB disk**
gerekir.

### Veritabanı topolojisi

```
        cdbrac (RAC, ASM, ARCHIVELOG + FORCE LOGGING + FLASHBACK)
        ├── cdbrac1  @ ol9-19-rac1
        └── cdbrac2  @ ol9-19-rac2
                 │  redo aktarımı (broker yapılandırması: dg_cdbrac)
                 ▼
        cdbsb (fiziksel yedek, tek örnek, /u01 dosya sistemi)
```

* `cdbrac` container veritabanı, içinde tek bir `pdb1` PDB'si, `AL32UTF8` karakter seti,
  `+DATA` / `+RECO` üzerinde OMF.
* SCAN: `ol9-19-scan.localdomain` → 192.168.56.105-107, port 1521.
* Küme adı `ol9-19-cluster`, Grid home `/u01/app/19.0.0/grid`, DB home
  `/u01/app/oracle/product/19.0.0/dbhome_1`.
* ASM disk grupları: `CRS` (3 × 2 GB, normal yedeklilik), `DATA` (40 GB), `RECO` (20 GB).

### Yönlendirilen portlar (ana makine → sanal makine)

| Servis | rac1 | rac2 | standby |
|--------|------|------|---------|
| Listener 1521 | 1521 | 1522 | 1523 |
| EM Express 5500 | 5501 | 5502 | 5503 |

---

## Dizin yapısı

```
ol9_19/
├── config/
│   ├── vagrant.yml     Sanal makine boyutları, IP'ler, box adı, paylaşımlı disk yolları
│   └── install.env     Tek doğruluk kaynağı: sunucu adları, IP'ler, ORACLE_* yolları,
│                       parolalar, kurulum ve yama dosyalarının adları
├── software/           Oracle kurulum ZIP dosyaları buraya konur (git'e dahil değildir)
├── shared_scripts/     Birden fazla makinede kullanılan betikler
│   ├── prepare_u01_disk.sh        /u01 diskini bölümler, biçimlendirir, bağlar
│   ├── install_os_packages.sh     preinstall RPM + ek paketler, firewall ve SELinux kapatma
│   ├── configure_hosts_base.sh    /etc/hosts: public, private, VIP, standby kayıtları
│   ├── configure_hosts_scan.sh    /etc/hosts: üç SCAN adresi (yalnız DNS makinesinde)
│   ├── configure_chrony.sh        Zaman senkronizasyonu (CRS için zorunlu)
│   ├── configure_shared_disks.sh  Paylaşımlı diskler + udev kuralları → /dev/oracleasm/*
│   └── oracle_software_patch.sh   OJVM RU için opatchauto
├── dns/                Vagrantfile + dnsmasq kurulumu
├── node1/              Vagrantfile + GI/DB kurulumu ve RAC veritabanını oluşturan betikler
├── node2/              Vagrantfile + yalnızca işletim sistemi ve oracle kullanıcısı hazırlığı
└── standby/            Vagrantfile + DB kurulumu, RMAN duplicate, Data Guard broker
```

---

## Ön koşullar

* Ana makinede **VirtualBox** ve **Vagrant**.
* `oraclebase/oracle-9` Vagrant box'ı (ilk `vagrant up` sırasında otomatik indirilir).
* Oracle'dan indirilip `software/` dizinine kopyalanması gereken kurulum dosyaları:

| Dosya | İçeriği |
|-------|---------|
| `LINUX.X64_193000_grid_home.zip` | 19.3 Grid Infrastructure home |
| `LINUX.X64_193000_db_home.zip` | 19.3 Database home |
| `p6880880_190000_Linux-x86-64.zip` | Güncel OPatch |
| `p36866740_190000_Linux-x86-64.zip` | 19.25 birleşik GI + OJVM RU |

  Hangi yama paketinin kullanılacağı `config/install.env` içinde belirlenir. 19.19 → 19.31
  arası bloklar hazır durumdadır; yalnızca biri açık olmalı ve `PATCH_PATH1` (GI/DB RU) ile
  `PATCH_PATH2` (OJVM RU) o sürümle uyumlu olmalıdır.

* Paylaşımlı ASM disk imajları için `config/vagrant.yml` ile uyumlu bir dizin:

  ```bash
  mkdir -p ~/oracle/shared-disk/ol9_19_rac
  ```

  Diskleri başka bir yerde tutacaksanız `config/vagrant.yml` içindeki `asm_*_disk_*`
  yollarını güncelleyin. `.vdi` dosyaları ilk açılışta oluşturulur ve iki RAC düğümü
  arasında paylaşılır (`--mtype shareable`).

---

## Kurulum sırası

Sıra önemlidir: `node1`, Grid Infrastructure'ı SSH üzerinden **her iki düğüme** birden
kurar; bu yüzden 2. düğüm önce ayakta olmalıdır. Yedek makine ise hazır bir kümeye bağlanır.

```bash
cd dns      && vagrant up
cd ../node2 && vagrant up
cd ../node1 && vagrant up      # uzun sürer: GI + DB kurulumu, RU yamaları, dbca
cd ../standby && vagrant up    # DB kurulumu, RMAN duplicate, broker yapılandırması
```

Tüm kurulum birkaç saat sürebilir; sürenin büyük kısmı `node1` adımına aittir. Yedek
makine isteğe bağlıdır; RAC kümesi onsuz da tam olarak çalışır.

### Her adımın yaptıkları

**dns** — root parolasını ayarlar, `/etc/hosts` dosyasını yazar (tüm lab sunucuları ve üç
SCAN adresi), `firewalld` servisini kapatır, `dnsmasq` paketini kurup `eth1` arayüzünde
yapılandırır ve systemd tarafında hata durumunda yeniden başlatma ayarı ekler.

**node2** — `/u01` diskini bağlar, `oracle-database-preinstall-19c` ve ek paketleri kurar,
parolaları belirler, `resolv.conf` dosyasını DNS makinesine yönlendirir, chrony'i etkinleştirir,
paylaşımlı diskleri bölümleyip udev kurallarını oluşturur, sunucu adını ayarlar, `oracle`
kullanıcısının ortam betiklerini (`setEnv.sh`, `grid_env`, `db_env`) oluşturur ve SSH
anahtarlarını üretir.

**node1** — node2'nin yaptıklarının tamamı, ardından:
1. `root` ve `oracle` kullanıcıları için çift yönlü parolasız SSH,
2. Grid home arşivinin açılması ve her iki düğüme `cvuqdisk` kurulumu,
3. sessiz `gridSetup.sh -applyRU` yazılım kurulumu ve her iki düğümde `root.sh`,
4. `gridSetup.sh -executeConfigTools` ile kümenin yapılandırılması, ardından `DATA` ve
   `RECO` disk gruplarının oluşturulması,
5. her iki düğümde sessiz `runInstaller -applyRU` ile DB home kurulumu ve `root.sh`,
6. OJVM RU için `opatchauto`,
7. `dbca` ile `cdbrac` RAC container veritabanının ve `pdb1` PDB'sinin oluşturulması,
   PDB durumunun kaydedilmesi ve `crsctl stat res -t` / `srvctl status database` çıktısı.

**standby** — işletim sistemi hazırlığı (paylaşımlı disk ve Grid yok), ardından:
1. kendisini DNS makinesinin ve her iki RAC düğümünün `/etc/hosts` dosyasına ekler,
2. RAC düğümlerinde OpenSSH `PerSourcePenalties` ayarını kapatır (9.9+ sürümleri bu
   kurulumun açtığı yoğun bağlantıları kısıtlıyor),
3. birincil ile aynı RU seviyesinde sessiz DB yazılım kurulumu ve ardından OJVM RU,
4. `oracle_prepare_primary.sh` — SSH üzerinden birincili ARCHIVELOG moduna alır, force
   logging ve flashback'i açar, `standby_file_management` ve `log_archive_config`
   parametrelerini ayarlar, broker yapılandırma dosyalarını ASM'ye taşır, her thread için
   standby redo log ekler ve parola dosyasını ASM'den kopyalar,
5. `oracle_create_standby.sh` — statik listener ve TNS kayıtları, nomount durumunda bir
   yardımcı (auxiliary) örnek, ardından `RMAN DUPLICATE TARGET DATABASE FOR STANDBY FROM
   ACTIVE DATABASE`,
6. `oracle_configure_dataguard.sh` — her iki tarafta broker'ı başlatır, `CREATE
   CONFIGURATION dg_cdbrac`, `ADD DATABASE cdbsb`, `ENABLE CONFIGURATION` komutlarını
   çalıştırır, doğrulama yapar ve bir log switch sonrası uygulamayı (apply) kontrol eder,
7. yeniden başlatmalardan sonra yedek listener'ın ve mount durumundaki örneğin kendiliğinden
   gelmesi için `oracle-standby.service` birimini kurar.

---

## Parolalar (laboratuvar varsayılanları, `config/install.env`)

| Hesap | Parola |
|-------|--------|
| `root` | `R00tPasswd1` |
| `oracle` | `OraPasswd1` |
| `SYS` / `SYSTEM` / ASM | `SysPassword1` |
| PDB yöneticisi | `PdbPassword1` |

Parolalar bilinçli olarak düz metin tutulmuştur; bu ortam tek kullanımlık bir laboratuvardır.
Tüm makinelerde `firewalld` kapalı ve SELinux permissive moddadır. Bu yapılandırmayı özel
bir test ortamının dışında kullanmayın.

---

## Laboratuvarın kullanımı

```bash
cd node1 && vagrant ssh
sudo su - oracle

grid_env                       # Grid ortamına geç (+ASM1)
crsctl stat res -t
srvctl status database -d cdbrac

db_env                         # Veritabanı ortamına geç (cdbrac1)
sqlplus / as sysdba
```

Ana makineden, yönlendirilen listener portu üzerinden:

```bash
sqlplus system/SysPassword1@//localhost:1521/pdb1
```

Yedek makineden Data Guard durumu:

```bash
cd standby && vagrant ssh
sudo su - oracle
dgmgrl sys/SysPassword1@cdbrac
DGMGRL> SHOW CONFIGURATION VERBOSE;
DGMGRL> VALIDATE DATABASE 'cdbsb';
```

---

## Başarısız yedek kurulumundan sonra toparlanma

En kırılgan adım Data Guard bölümüdür (SSH kısıtlaması, yarım kalan RMAN duplicate, ASM'den
devralınan broker dosyaları). Makineyi yeniden kurmadan çalıştırılabilecek iki onarım betiği
vardır:

```bash
# Tam tekrar: SSH'i yeniden kurar, yarım kalan duplicate'i temizler, birincili hazırlar,
# duplicate işlemini tekrarlar ve broker'ı yapılandırır.
sudo su - oracle -c 'sh /vagrant/scripts/resume_dataguard.sh'

# Dar kapsamlı onarım: duplicate başarılı olmuş ancak dg_broker_config_file1/2 hâlâ ASM'yi
# gösterdiği için broker başlamamışsa (ORA-16604 / ORA-16525).
sudo su - oracle -c 'sh /vagrant/scripts/fix_broker_config.sh'
```

RMAN duplicate günlüğü yedek makinede `/tmp/duplicate_standby.log` dosyasındadır.

---

## Ortamı kaldırma

```bash
cd standby && vagrant destroy -f
cd ../node1 && vagrant destroy -f
cd ../node2 && vagrant destroy -f
cd ../dns   && vagrant destroy -f
rm -f ~/oracle/shared-disk/ol9_19_rac/*.vdi
rm -f node1/*.vdi node2/*.vdi standby/*.vdi
```

Paylaşımlı ASM diskleri `vagrant destroy` ile **silinmez**. Yeniden kurulumdan önce elle
silin; aksi hâlde yeni küme bu disklerde eski ASM başlıklarını bulur.

---

## Özelleştirme

Neredeyse her şey koda değil, yapılandırmaya gömülüdür:

* `config/vagrant.yml` — bellek, CPU, IP adresleri, disk boyutları ve imaj konumları.
* `config/install.env` — sunucu adları, alan adı, SCAN adı, küme adı, SID'ler, veritabanı ve
  PDB adları, parolalar, yama seviyesi, Oracle home yolları.

Buradaki bir değeri değiştirmek tüm betiklere yansır; çünkü her betik ilk satırında
`/vagrant_config/install.env` dosyasını yükler. `vagrant.yml` ve `install.env` içindeki IP
adreslerinin elle senkron tutulduğunu unutmayın — ikisini birden güncelleyin.

---

## Kaynak ve teşekkür

Bu Vagrant yapılandırmaları, Tim Hall'ın (Oracle-Base) Vagrant deposundan yola çıkılarak
hazırlanmıştır:

* <https://github.com/oraclebase/vagrant>
* <https://oracle-base.com/articles/vm/vagrant-oracle-database-builds>

Genel yapı — `vagrant.yml` ve `install.env` dosyalarını barındıran `config/` dizini,
`shared_scripts/` ile makineye özel `scripts/` ayrımı, sessiz Grid Infrastructure /
Database kurulum akışı ve `oraclebase/oracle-9` box'ı — oradan gelmektedir. Bu
laboratuvar bunun üzerine 2 düğümlü RAC + Data Guard fiziksel yedek topolojisini, DNS
makinesini, RU/OJVM yamalarını ve yedek kurulum/onarım betiklerini ekler.

Bu çalışmayı yayımladığı ve sürdürdüğü için Tim Hall'a teşekkürler.
