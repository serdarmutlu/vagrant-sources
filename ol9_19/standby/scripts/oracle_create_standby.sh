. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh

export ORACLE_SID=${STANDBY_ORACLE_SID}

echo "******************************************************************************"
echo "Create listener.ora and tnsnames.ora." `date`
echo "******************************************************************************"
mkdir -p ${ORACLE_HOME}/network/admin

# The static entries matter: during the RMAN duplicate and during broker
# switchover/failover the instance is down, in nomount or in mount, so dynamic
# registration is not available.
cat > ${ORACLE_HOME}/network/admin/listener.ora <<EOF
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_FQ_HOSTNAME})(PORT = 1521))
    )
  )

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNQNAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNQNAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
  )

ADR_BASE_LISTENER = ${ORACLE_BASE}
EOF

cat > ${ORACLE_HOME}/network/admin/tnsnames.ora <<EOF
${PRIMARY_DB_UNQNAME} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${FQ_SCAN_NAME})(PORT = ${SCAN_PORT}))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = ${PRIMARY_DB_UNQNAME}))
  )

${STANDBY_DB_UNQNAME} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_FQ_HOSTNAME})(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = ${STANDBY_DB_UNQNAME}))
  )
EOF

lsnrctl start
sleep 5
lsnrctl status

echo "******************************************************************************"
echo "Create the auxiliary instance." `date`
echo "******************************************************************************"
mkdir -p ${ORACLE_BASE}/admin/${STANDBY_DB_UNQNAME}/adump
mkdir -p ${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}
mkdir -p ${STANDBY_FRA}
mkdir -p ${STANDBY_FRA}/${STANDBY_DB_UNQNAME_UPPER}

cat > ${ORACLE_HOME}/dbs/init${STANDBY_ORACLE_SID}.ora <<EOF
db_name=${DB_NAME}
db_unique_name=${STANDBY_DB_UNQNAME}
enable_pluggable_database=TRUE
audit_file_dest='${ORACLE_BASE}/admin/${STANDBY_DB_UNQNAME}/adump'
db_create_file_dest='${STANDBY_ORADATA}'
db_recovery_file_dest='${STANDBY_FRA}'
db_recovery_file_dest_size=${STANDBY_FRA_SIZE}
sga_target=1200M
pga_aggregate_target=400M
compatible=19.0.0
EOF

# Make the script re-runnable: drop any instance left from a failed attempt.
sqlplus -S / as sysdba <<EOF
SHUTDOWN ABORT;
EXIT;
EOF

sqlplus -S / as sysdba <<EOF
STARTUP NOMOUNT PFILE='${ORACLE_HOME}/dbs/init${STANDBY_ORACLE_SID}.ora';
EXIT;
EOF

echo "******************************************************************************"
echo "Check we can reach both databases over TNS." `date`
echo "******************************************************************************"
tnsping ${PRIMARY_DB_UNQNAME}
tnsping ${STANDBY_DB_UNQNAME}

if [ ! -s ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID} ]; then
  echo "******************************************************************************"
  echo "FATAL: ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID} is missing or empty."
  echo "The RMAN auxiliary connection would fail with ORA-01017. Stopping here."
  echo "******************************************************************************"
  exit 1
fi

echo "******************************************************************************"
echo "RMAN duplicate for standby from active database." `date`
echo "******************************************************************************"
cat > /tmp/duplicate_standby.rman <<EOF
run {
  allocate channel prmy1 type disk;
  allocate channel prmy2 type disk;
  allocate auxiliary channel stby1 type disk;

  duplicate target database for standby
  from active database
  dorecover
  using compressed backupset
  spfile
    set db_unique_name='${STANDBY_DB_UNQNAME}'
    set cluster_database='FALSE'
    set control_files='${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}/control01.ctl','${STANDBY_FRA}/${STANDBY_DB_UNQNAME_UPPER}/control02.ctl'
    set db_create_file_dest='${STANDBY_ORADATA}'
    set db_recovery_file_dest='${STANDBY_FRA}'
    set db_recovery_file_dest_size='${STANDBY_FRA_SIZE}'
    set db_file_name_convert='+DATA/${PRIMARY_DB_UNQNAME_UPPER}/','${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}/'
    set log_file_name_convert='+DATA/${PRIMARY_DB_UNQNAME_UPPER}/','${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}/','+RECO/${PRIMARY_DB_UNQNAME_UPPER}/','${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}/'
    set standby_file_management='AUTO'
    set fal_server='${PRIMARY_DB_UNQNAME}'
    set log_archive_config='dg_config=(${PRIMARY_DB_UNQNAME},${STANDBY_DB_UNQNAME})'
    set audit_file_dest='${ORACLE_BASE}/admin/${STANDBY_DB_UNQNAME}/adump'
    set dg_broker_config_file1='${ORACLE_HOME}/dbs/dr1${STANDBY_DB_UNQNAME}.dat'
    set dg_broker_config_file2='${ORACLE_HOME}/dbs/dr2${STANDBY_DB_UNQNAME}.dat'
    reset remote_listener
    reset cluster_database_instances
    reset local_listener
  nofilenamecheck;
}
EOF

cat /tmp/duplicate_standby.rman

rman target sys/${SYS_PASSWORD}@${PRIMARY_DB_UNQNAME} \
     auxiliary sys/${SYS_PASSWORD}@${STANDBY_DB_UNQNAME} \
     cmdfile=/tmp/duplicate_standby.rman log=/tmp/duplicate_standby.log

tail -30 /tmp/duplicate_standby.log

if grep -qE "RMAN-[0-9]+:|ORA-01017" /tmp/duplicate_standby.log; then
  echo "******************************************************************************"
  echo "FATAL: the RMAN duplicate reported errors. See /tmp/duplicate_standby.log."
  echo "******************************************************************************"
  exit 1
fi

echo "******************************************************************************"
echo "Make sure standby redo logs exist on the standby." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<'SQL'
SET SERVEROUTPUT ON
DECLARE
  l_count PLS_INTEGER;
  l_size  NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM v$standby_log;
  IF l_count > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Standby redo logs already present: ' || l_count);
    RETURN;
  END IF;

  SELECT MAX(bytes) INTO l_size FROM v$log;

  FOR t IN (SELECT thread#, COUNT(*) AS groups FROM v$log GROUP BY thread# ORDER BY thread#) LOOP
    FOR i IN 1 .. t.groups + 1 LOOP
      EXECUTE IMMEDIATE 'ALTER DATABASE ADD STANDBY LOGFILE THREAD ' || t.thread# || ' SIZE ' || l_size;
    END LOOP;
  END LOOP;
END;
/

SET LINESIZE 200
SELECT thread#, group#, bytes/1024/1024 AS mb FROM v$standby_log ORDER BY thread#, group#;
SELECT name, db_unique_name, database_role, open_mode FROM v$database;
EXIT;
SQL
