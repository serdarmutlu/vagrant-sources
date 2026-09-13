. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh
. /vagrant/scripts/ssh_functions.sh

export ORACLE_SID=${STANDBY_ORACLE_SID}

require_ssh oracle ${NODE1_HOSTNAME}

echo "******************************************************************************"
echo "Verify the standby is mounted before touching the broker." `date`
echo "******************************************************************************"
ROLE=`sqlplus -S -L / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF TRIMSPOOL ON
SELECT TRIM(database_role) FROM v$database;
EXIT;
SQL`

if ! echo "${ROLE}" | grep -q "PHYSICAL STANDBY"; then
  echo "******************************************************************************"
  echo "FATAL: the standby is not mounted as a physical standby."
  echo "The RMAN duplicate did not complete - check /tmp/duplicate_standby.log."
  echo "******************************************************************************"
  exit 1
fi

echo "******************************************************************************"
echo "Start the broker on the primary." `date`
echo "******************************************************************************"
ssh ${SSH_OPTS} oracle@${NODE1_HOSTNAME} ". /home/oracle/scripts/setEnv.sh; export ORACLE_SID=${NODE1_ORACLE_SID}; \
  echo \"ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH SID='*';\" | sqlplus -S / as sysdba"

echo "******************************************************************************"
echo "Start the broker on the standby." `date`
echo "******************************************************************************"
# The duplicate inherits the primary's spfile, and on a RAC primary the broker
# files live in ASM. The standby has no ASM, so they must be re-pointed at the
# local filesystem or dg_broker_start fails with ORA-16604.
sqlplus -S / as sysdba <<SQL
ALTER SYSTEM SET dg_broker_config_file1='${ORACLE_HOME}/dbs/dr1${STANDBY_DB_UNQNAME}.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_config_file2='${ORACLE_HOME}/dbs/dr2${STANDBY_DB_UNQNAME}.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH;
EXIT;
SQL

sleep 30

DGB=`sqlplus -S -L / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF TRIMSPOOL ON
SELECT TRIM(value) FROM v$parameter WHERE name = 'dg_broker_start';
EXIT;
SQL`

if ! echo "${DGB}" | grep -qi "TRUE"; then
  echo "******************************************************************************"
  echo "FATAL: dg_broker_start is not TRUE on the standby - the broker cannot start."
  echo "Check dg_broker_config_file1/2; ORA-16604 means they point somewhere the"
  echo "standby cannot reach (typically an inherited ASM path)."
  echo "******************************************************************************"
  exit 1
fi

echo "******************************************************************************"
echo "Create the broker configuration." `date`
echo "******************************************************************************"
dgmgrl sys/${SYS_PASSWORD}@${PRIMARY_DB_UNQNAME} <<EOF
CREATE CONFIGURATION '${DG_CONFIG_NAME}' AS PRIMARY DATABASE IS '${PRIMARY_DB_UNQNAME}' CONNECT IDENTIFIER IS ${PRIMARY_DB_UNQNAME};
ADD DATABASE '${STANDBY_DB_UNQNAME}' AS CONNECT IDENTIFIER IS ${STANDBY_DB_UNQNAME};
ENABLE CONFIGURATION;
EXIT;
EOF

echo "Waiting for the broker to settle and apply to start..."
sleep 90

echo "******************************************************************************"
echo "Data Guard configuration." `date`
echo "******************************************************************************"
dgmgrl sys/${SYS_PASSWORD}@${PRIMARY_DB_UNQNAME} <<EOF
SHOW CONFIGURATION VERBOSE;
SHOW DATABASE '${PRIMARY_DB_UNQNAME}';
SHOW DATABASE '${STANDBY_DB_UNQNAME}';
VALIDATE DATABASE '${STANDBY_DB_UNQNAME}';
EXIT;
EOF

echo "******************************************************************************"
echo "Force a log switch on the primary and check the gap." `date`
echo "******************************************************************************"
ssh ${SSH_OPTS} oracle@${NODE1_HOSTNAME} ". /home/oracle/scripts/setEnv.sh; export ORACLE_SID=${NODE1_ORACLE_SID}; \
  echo 'ALTER SYSTEM ARCHIVE LOG CURRENT;' | sqlplus -S / as sysdba"

sleep 30

sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200
COLUMN name FORMAT A12
SELECT name, db_unique_name, database_role, open_mode, protection_mode FROM v$database;
SELECT process, status, thread#, sequence# FROM v$managed_standby WHERE process LIKE 'MRP%' OR process LIKE 'RFS%';
SELECT thread#, MAX(sequence#) AS applied FROM v$archived_log WHERE applied = 'YES' GROUP BY thread# ORDER BY thread#;
EXIT;
SQL
