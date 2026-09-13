# Oracle 19c RAC + Data Guard Lab (Oracle Linux 9)

*[Türkçe sürüm için: README.tr.md](README.tr.md)*

Vagrant/VirtualBox build that creates a complete Oracle 19c lab from scratch:

* a **2-node Real Application Clusters (RAC)** primary database on ASM,
* a **single-instance physical standby** kept in sync by **Data Guard** (broker managed),
* a small **DNS server** providing SCAN name resolution for the cluster.

Everything is provisioned unattended by shell scripts — silent Grid Infrastructure and
Database installs, RU patching, `dbca`, an RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE
DATABASE`, and a `dgmgrl` broker configuration.

---

## What gets built

| VM | Vagrant dir | Hostname | Public IP | Private IP | RAM | CPU | Role |
|----|-------------|----------|-----------|------------|-----|-----|------|
| `ol9_19_dns`  | `dns/`     | `ol9-19-dns`  | 192.168.56.100 | – | 1 GB | 2 | dnsmasq, resolves SCAN + all lab hosts |
| `ol9_19_rac2` | `node2/`   | `ol9-19-rac2` | 192.168.56.102 | 192.168.1.102 | 8 GB | 4 | RAC node 2 (`cdbrac2`, `+ASM2`) |
| `ol9_19_rac1` | `node1/`   | `ol9-19-rac1` | 192.168.56.101 | 192.168.1.101 | 8 GB | 4 | RAC node 1 (`cdbrac1`, `+ASM1`) — drives the cluster install |
| `ol9_19_sb`   | `standby/` | `ol9-19-sb`   | 192.168.56.108 | – | 4 GB | 2 | Physical standby (`cdbsb`), filesystem storage |

Total host footprint: **~21 GB RAM** and **~300 GB disk** if all four VMs run at once.

### Database topology

```
        cdbrac (RAC, ASM, ARCHIVELOG + FORCE LOGGING + FLASHBACK)
        ├── cdbrac1  @ ol9-19-rac1
        └── cdbrac2  @ ol9-19-rac2
                 │  redo transport (broker config: dg_cdbrac)
                 ▼
        cdbsb (physical standby, single instance, /u01 filesystem)
```

* Container database `cdbrac` with one PDB `pdb1`, `AL32UTF8`, OMF on `+DATA` / `+RECO`.
* SCAN: `ol9-19-scan.localdomain` → 192.168.56.105-107, port 1521.
* Cluster name `ol9-19-cluster`, Grid home `/u01/app/19.0.0/grid`, DB home
  `/u01/app/oracle/product/19.0.0/dbhome_1`.
* ASM disk groups: `CRS` (3 × 2 GB, normal redundancy), `DATA` (40 GB), `RECO` (20 GB).

### Forwarded ports (host → guest)

| Service | rac1 | rac2 | standby |
|---------|------|------|---------|
| Listener 1521 | 1521 | 1522 | 1523 |
| EM Express 5500 | 5501 | 5502 | 5503 |

---

## Repository layout

```
ol9_19/
├── config/
│   ├── vagrant.yml     VM sizing, IPs, box name, shared-disk image paths
│   └── install.env     single source of truth: hostnames, IPs, ORACLE_* paths,
│                       passwords, software/patch file names
├── software/           put the Oracle installation ZIPs here (not in git)
├── shared_scripts/     scripts used by more than one VM
│   ├── prepare_u01_disk.sh        partitions/formats/mounts /u01
│   ├── install_os_packages.sh     preinstall RPM, extra packages, firewall + SELinux off
│   ├── configure_hosts_base.sh    /etc/hosts: public, private, VIP, standby
│   ├── configure_hosts_scan.sh    /etc/hosts: the three SCAN addresses (DNS VM only)
│   ├── configure_chrony.sh        time sync (mandatory for CRS)
│   ├── configure_shared_disks.sh  partitions shared disks + udev rules → /dev/oracleasm/*
│   └── oracle_software_patch.sh   opatchauto for the OJVM RU
├── dns/                Vagrantfile + dnsmasq setup
├── node1/              Vagrantfile + the scripts that install GI, DB and create the RAC DB
├── node2/              Vagrantfile + OS/oracle-user preparation only
└── standby/            Vagrantfile + DB install, RMAN duplicate, Data Guard broker
```

---

## Prerequisites

* **VirtualBox** and **Vagrant** on the host.
* The Vagrant box `oraclebase/oracle-9` (downloaded automatically on first `vagrant up`).
* Oracle installation media, downloaded from Oracle and copied into `software/`:

| File | What it is |
|------|------------|
| `LINUX.X64_193000_grid_home.zip` | 19.3 Grid Infrastructure home |
| `LINUX.X64_193000_db_home.zip` | 19.3 Database home |
| `p6880880_190000_Linux-x86-64.zip` | latest OPatch |
| `p36866740_190000_Linux-x86-64.zip` | 19.25 combined GI + OJVM RU |

  The patch bundle is selected in `config/install.env`. Blocks for 19.19 → 19.31 are
  present; exactly one must be uncommented, and `PATCH_PATH1` (GI/DB RU) and
  `PATCH_PATH2` (OJVM RU) must match it.

* A directory for the shared ASM disk images, matching `config/vagrant.yml`:

  ```bash
  mkdir -p ~/oracle/shared-disk/ol9_19_rac
  ```

  Edit the `asm_*_disk_*` paths in `config/vagrant.yml` if you keep them elsewhere.
  The `.vdi` files are created on first boot and are shared (`--mtype shareable`)
  between the two RAC nodes.

---

## Build order

The order matters: `node1` installs Grid Infrastructure on **both** nodes over SSH, so
node 2 has to be running first. The standby talks to a finished cluster.

```bash
cd dns      && vagrant up
cd ../node2 && vagrant up
cd ../node1 && vagrant up      # long: GI + DB install, RU patching, dbca
cd ../standby && vagrant up    # DB install, RMAN duplicate, broker setup
```

Expect the whole build to take a couple of hours; `node1` alone is the bulk of it.
The standby is optional — the RAC cluster is fully usable without it.

### What each `vagrant up` does

**dns** — sets the root password, writes `/etc/hosts` (all lab hosts plus the three SCAN
addresses), disables `firewalld`, installs and configures `dnsmasq` on `eth1` with a
systemd restart-on-failure override.

**node2** — mounts `/u01`, installs `oracle-database-preinstall-19c` and the extra
packages, sets passwords, points `resolv.conf` at the DNS VM, enables chrony, partitions
the shared disks and creates the udev rules, sets the hostname, creates the `oracle`
environment scripts (`setEnv.sh`, `grid_env`, `db_env`) and generates SSH keys.

**node1** — everything node2 does, then:
1. passwordless SSH both ways, for `root` and `oracle`,
2. unzips the Grid home, installs `cvuqdisk` on both nodes,
3. silent `gridSetup.sh -applyRU` software-only install, `root.sh` on both nodes,
4. `gridSetup.sh -executeConfigTools` to configure the cluster, then creates the `DATA`
   and `RECO` disk groups,
5. silent `runInstaller -applyRU` for the DB home on both nodes, `root.sh`,
6. `opatchauto` for the OJVM RU,
7. `dbca` creates the RAC container database `cdbrac` with PDB `pdb1`, saves the PDB
   state, and prints `crsctl stat res -t` / `srvctl status database`.

**standby** — OS prep (no shared disks, no Grid), then:
1. registers itself in `/etc/hosts` on the DNS VM and both RAC nodes,
2. disables OpenSSH `PerSourcePenalties` on the RAC nodes (9.9+ throttles the burst of
   connections this build makes),
3. silent DB software-only install at the same RU as the primary, plus the OJVM RU,
4. `oracle_prepare_primary.sh` — over SSH, puts the primary into ARCHIVELOG, enables
   force logging and flashback, sets `standby_file_management`, `log_archive_config` and
   ASM-resident broker config files, adds standby redo logs per thread, and copies the
   password file out of ASM,
5. `oracle_create_standby.sh` — static listener + TNS entries, an auxiliary nomount
   instance, then `RMAN DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE`,
6. `oracle_configure_dataguard.sh` — starts the broker on both sides, `CREATE
   CONFIGURATION dg_cdbrac`, `ADD DATABASE cdbsb`, `ENABLE CONFIGURATION`, then validates
   and checks apply after a log switch,
7. installs an `oracle-standby.service` unit so the standby listener + mounted instance
   come back automatically after a reboot.

---

## Credentials (lab defaults, in `config/install.env`)

| Account | Password |
|---------|----------|
| `root` | `R00tPasswd1` |
| `oracle` | `OraPasswd1` |
| `SYS` / `SYSTEM` / ASM | `SysPassword1` |
| PDB admin | `PdbPassword1` |

These are plain text on purpose — this is a disposable lab. `firewalld` is disabled and
SELinux is set to permissive on every VM. Do not reuse any of this outside a private
sandbox.

---

## Using the lab

```bash
cd node1 && vagrant ssh
sudo su - oracle

grid_env                       # switch to the Grid environment (+ASM1)
crsctl stat res -t
srvctl status database -d cdbrac

db_env                         # switch to the DB environment (cdbrac1)
sqlplus / as sysdba
```

From the host, via the forwarded listener port:

```bash
sqlplus system/SysPassword1@//localhost:1521/pdb1
```

Data Guard status, from the standby VM:

```bash
cd standby && vagrant ssh
sudo su - oracle
dgmgrl sys/SysPassword1@cdbrac
DGMGRL> SHOW CONFIGURATION VERBOSE;
DGMGRL> VALIDATE DATABASE 'cdbsb';
```

---

## Recovering from a failed standby build

The Data Guard part is the most fragile step (SSH throttling, a failed RMAN duplicate,
broker files inherited from ASM). Two repair scripts are provided and can be re-run
without rebuilding the VM:

```bash
# Full retry: rebuild SSH, clean the failed duplicate, prepare the primary,
# duplicate again, configure the broker.
sudo su - oracle -c 'sh /vagrant/scripts/resume_dataguard.sh'

# Narrow fix: the duplicate worked but the broker did not start because
# dg_broker_config_file1/2 still point into ASM (ORA-16604 / ORA-16525).
sudo su - oracle -c 'sh /vagrant/scripts/fix_broker_config.sh'
```

The RMAN duplicate log is at `/tmp/duplicate_standby.log` on the standby.

---

## Tearing down

```bash
cd standby && vagrant destroy -f
cd ../node1 && vagrant destroy -f
cd ../node2 && vagrant destroy -f
cd ../dns   && vagrant destroy -f
rm -f ~/oracle/shared-disk/ol9_19_rac/*.vdi
rm -f node1/*.vdi node2/*.vdi standby/*.vdi
```

The shared ASM disks are **not** removed by `vagrant destroy` — delete them by hand
before rebuilding, otherwise the new cluster finds an old ASM header on them.

---

## Customising

Almost everything is data, not code:

* `config/vagrant.yml` — memory, CPUs, IP addresses, disk sizes and image locations.
* `config/install.env` — hostnames, domain, SCAN name, cluster name, SIDs, DB and PDB
  names, passwords, patch level, Oracle home paths.

Change a value there and it propagates to every script, because each script sources
`/vagrant_config/install.env` as its first line. Note that the IPs in `vagrant.yml` and
`install.env` are kept in sync manually — change both.
