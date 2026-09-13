# Runs on RAC node1 as oracle. Puts the primary into a Data Guard ready state.
. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh
export ORACLE_SID=${NODE1_ORACLE_SID}

echo "******************************************************************************"
echo "Primary state before changes." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200
COLUMN name FORMAT A12
COLUMN db_unique_name FORMAT A15
SELECT name, db_unique_name, log_mode, force_logging, flashback_on, open_mode FROM v$database;
EXIT;
SQL

LOG_MODE=`sqlplus -S -L / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF TRIMSPOOL ON
SELECT TRIM(log_mode) FROM v$database;
EXIT;
SQL`

if echo "${LOG_MODE}" | grep -q "NOARCHIVELOG"; then
  echo "******************************************************************************"
  echo "Enable archivelog mode (requires a full database restart)." `date`
  echo "******************************************************************************"
  srvctl stop database -d ${PRIMARY_DB_UNQNAME}
  sqlplus -S / as sysdba <<'SQL'
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
EXIT;
SQL
  srvctl start database -d ${PRIMARY_DB_UNQNAME}
else
  echo "Database is already in ARCHIVELOG mode."
fi

echo "******************************************************************************"
echo "Force logging, flashback and Data Guard parameters." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<SQL
WHENEVER SQLERROR CONTINUE
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE FLASHBACK ON;
ALTER SYSTEM SET standby_file_management='AUTO' SCOPE=BOTH SID='*';
ALTER SYSTEM SET log_archive_config='dg_config=(${PRIMARY_DB_UNQNAME},${STANDBY_DB_UNQNAME})' SCOPE=BOTH SID='*';
-- The broker config files must live on shared storage for a RAC primary,
-- otherwise each instance keeps its own copy and the config falls apart.
ALTER SYSTEM SET dg_broker_config_file1='+DATA/${PRIMARY_DB_UNQNAME}/dr1${PRIMARY_DB_UNQNAME}.dat' SCOPE=BOTH SID='*';
ALTER SYSTEM SET dg_broker_config_file2='+RECO/${PRIMARY_DB_UNQNAME}/dr2${PRIMARY_DB_UNQNAME}.dat' SCOPE=BOTH SID='*';
EXIT;
SQL

# NOTE: log_archive_dest_2 is deliberately NOT set by hand. If it is set with a
# SERVICE attribute before the standby is added, the broker throws ORA-16698.
# The broker will create the destination itself when the configuration is enabled.

echo "******************************************************************************"
echo "Add standby redo logs (one more group per thread than the online logs)." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<'SQL'
SET SERVEROUTPUT ON
DECLARE
  l_count  PLS_INTEGER;
  l_size   NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM v$standby_log;
  IF l_count > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Standby redo logs already present: ' || l_count);
    RETURN;
  END IF;

  SELECT MAX(bytes) INTO l_size FROM v$log;

  FOR t IN (SELECT thread#, COUNT(*) AS groups FROM v$log GROUP BY thread# ORDER BY thread#) LOOP
    FOR i IN 1 .. t.groups + 1 LOOP
      EXECUTE IMMEDIATE 'ALTER DATABASE ADD STANDBY LOGFILE THREAD ' || t.thread# ||
                        ' SIZE ' || l_size;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Thread ' || t.thread# || ': added ' || (t.groups + 1) || ' standby groups.');
  END LOOP;
END;
/

SET LINESIZE 200
SELECT thread#, group#, bytes/1024/1024 AS mb, status FROM v$standby_log ORDER BY thread#, group#;
EXIT;
SQL

echo "******************************************************************************"
echo "Copy the password file out of ASM." `date`
echo "******************************************************************************"
PW_FILE=`srvctl config database -d ${PRIMARY_DB_UNQNAME} | grep -i "^Password file:" | awk '{print $3}'`
echo "Primary password file: ${PW_FILE}"

(
  export ORACLE_SID=+ASM1
  export ORACLE_HOME=${GRID_HOME}
  export PATH=${GRID_HOME}/bin:${BASE_PATH}
  rm -f /tmp/orapw${PRIMARY_DB_UNQNAME}
  asmcmd pwcopy ${PW_FILE} /tmp/orapw${PRIMARY_DB_UNQNAME} -f || \
  asmcmd cp ${PW_FILE} /tmp/orapw${PRIMARY_DB_UNQNAME}
)
chmod 640 /tmp/orapw${PRIMARY_DB_UNQNAME}
ls -l /tmp/orapw${PRIMARY_DB_UNQNAME}

echo "******************************************************************************"
echo "Primary state after changes." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200
COLUMN name FORMAT A12
COLUMN db_unique_name FORMAT A15
SELECT name, db_unique_name, log_mode, force_logging, flashback_on, open_mode FROM v$database;
EXIT;
SQL
