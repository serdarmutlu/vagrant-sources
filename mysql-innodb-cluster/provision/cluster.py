# -*- coding: utf-8 -*-
"""InnoDB Cluster'i idempotent kurar / onarir.

Calistirma (myrouter uzerinde, router.sh tarafindan):
    mysqlsh --no-wizard --py -f /opt/mysql-lab/cluster.py

Durumlar:
  1. Calisan grup var          -> eksik node'lari ekle, kopanlari rejoin et
  2. Metadata var, grup kapali -> reboot_cluster_from_complete_outage
  3. Hicbir sey yok            -> ilk node'da create_cluster, digerlerini clone ile ekle
Ardindan uygulama veritabani/kullanicisi ve (aciksa) mysqld_exporter kullanicisi
primary'de olusturulur; Group Replication ile tum node'lara gider.
"""
import os
import time

E = os.environ
ADMIN = E['CLUSTER_ADMIN_USER']
PW = E['CLUSTER_ADMIN_PASSWORD']
NAME = E['CLUSTER_NAME']
NODES = [n.strip() for n in E['DB_NODES'].split(',') if n.strip()]
APP_DB = E.get('APP_DB', '')
APP_USER = E.get('APP_USER', '')
APP_PW = E.get('APP_PASSWORD', '')
EXP_USER = E.get('EXPORTER_USER', '')
EXP_PW = E.get('EXPORTER_PASSWORD', '')
PORT = 3306


def log(msg):
    print('[cluster] ' + msg)


def conn(host):
    return {'scheme': 'mysql', 'user': ADMIN, 'password': PW, 'host': host, 'port': PORT}


def sql_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


def scalar(query):
    return shell.get_session().run_sql(query).fetch_one()[0]


def wait_for(host, timeout=600):
    start = time.time()
    while True:
        try:
            s = mysql.get_classic_session(conn(host))
            s.close()
            log(host + ' erisilebilir')
            return
        except Exception as e:  # noqa: BLE001
            if time.time() - start > timeout:
                raise RuntimeError('%s %ds icinde erisilemedi: %s' % (host, timeout, e))
            log('%s bekleniyor: %s' % (host, str(e).splitlines()[0]))
            time.sleep(5)


def online_members(host):
    shell.connect(conn(host))
    return int(scalar("SELECT COUNT(*) FROM performance_schema.replication_group_members "
                      "WHERE MEMBER_STATE = 'ONLINE'"))


def has_metadata(host):
    shell.connect(conn(host))
    return int(scalar("SELECT COUNT(*) FROM information_schema.schemata "
                      "WHERE schema_name = 'mysql_innodb_cluster_metadata'")) > 0


def get_or_create():
    # 1) calisan grup
    for h in NODES:
        try:
            if online_members(h) > 0:
                log('calisan cluster bulundu (%s uzerinden)' % h)
                return dba.get_cluster(NAME)
        except Exception as e:  # noqa: BLE001
            log('%s kontrol edilemedi: %s' % (h, e))

    # 2) metadata var ama grup kapali (tum node'lar kapanip acilmis)
    meta_nodes = []
    for h in NODES:
        try:
            if has_metadata(h):
                meta_nodes.append(h)
        except Exception as e:  # noqa: BLE001
            log('%s kontrol edilemedi: %s' % (h, e))
    if meta_nodes:
        for h in meta_nodes:
            try:
                shell.connect(conn(h))
                log('complete outage -> reboot_cluster_from_complete_outage (%s)' % h)
                return dba.reboot_cluster_from_complete_outage(NAME)
            except Exception as e:  # noqa: BLE001
                log('%s uzerinden reboot basarisiz: %s' % (h, e))
        raise RuntimeError('Cluster metadata var ama reboot edilemedi. En guncel GTID setine sahip '
                           'node uzerinde elle deneyin: ic reboot <node>')

    # 3) yeni cluster
    seed = NODES[0]
    shell.connect(conn(seed))
    log('yeni cluster olusturuluyor: %s (seed: %s)' % (NAME, seed))
    return dba.create_cluster(NAME)


def ensure_members(c):
    topo = c.status()['defaultReplicaSet']['topology']
    keys = list(topo.keys())
    for h in NODES:
        key = '%s:%d' % (h, PORT)
        if key not in keys:
            log(key + ' ekleniyor (recoveryMethod=clone)')
            c.add_instance(conn(h), {'recoveryMethod': 'clone'})
            continue
        st = topo[key]['status']
        if st not in ('ONLINE', 'RECOVERING'):
            log('%s durum=%s -> rejoin' % (key, st))
            try:
                c.rejoin_instance(conn(h))
            except Exception as e:  # noqa: BLE001
                log('%s rejoin basarisiz: %s' % (key, e))


def ensure_app(c):
    if not (APP_DB and APP_USER):
        return
    primary = c.status()['defaultReplicaSet']['primary'].split(':')[0]
    shell.connect(conn(primary))
    s = shell.get_session()
    log('uygulama db/kullanici (%s uzerinde): %s / %s' % (primary, APP_DB, APP_USER))
    s.run_sql('CREATE DATABASE IF NOT EXISTS `%s`' % APP_DB.replace('`', ''))
    s.run_sql("CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED BY %s" % (sql_str(APP_USER), sql_str(APP_PW)))
    s.run_sql("ALTER USER %s@'%%' IDENTIFIED BY %s" % (sql_str(APP_USER), sql_str(APP_PW)))
    s.run_sql("GRANT ALL PRIVILEGES ON `%s`.* TO %s@'%%'" % (APP_DB.replace('`', ''), sql_str(APP_USER)))


def ensure_exporter_user(c):
    if not (EXP_USER and EXP_PW):
        return
    primary = c.status()['defaultReplicaSet']['primary'].split(':')[0]
    shell.connect(conn(primary))
    s = shell.get_session()
    log('mysqld_exporter kullanicisi (%s uzerinde): %s' % (primary, EXP_USER))
    # exporter her node'da 127.0.0.1 uzerinden baglanir
    for host in ('localhost', '127.0.0.1'):
        acct = "%s@%s" % (sql_str(EXP_USER), sql_str(host))
        s.run_sql("CREATE USER IF NOT EXISTS %s IDENTIFIED BY %s WITH MAX_USER_CONNECTIONS 3"
                  % (acct, sql_str(EXP_PW)))
        s.run_sql("ALTER USER %s IDENTIFIED BY %s" % (acct, sql_str(EXP_PW)))
        s.run_sql("GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO %s" % acct)


def main():
    for h in NODES:
        wait_for(h)
    c = get_or_create()
    ensure_members(c)
    ensure_app(c)
    ensure_exporter_user(c)
    print(dba.get_cluster(NAME).status())


try:
    main()
except Exception as e:  # noqa: BLE001
    log('HATA: %s' % e)
    raise
