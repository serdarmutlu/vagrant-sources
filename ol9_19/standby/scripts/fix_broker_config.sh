# One-off repair: the RMAN duplicate inherited the primary's ASM-based
# dg_broker_config_file1/2 (+DATA / +RECO). The standby has no ASM, so
# dg_broker_start fails with ORA-16604 and ADD DATABASE fails with ORA-16525.
#
# Point the broker files at the local filesystem, start the broker, and add
# the standby to the existing configuration.
#
#   sudo su - oracle -c 'sh /vagrant/scripts/fix_broker_config.sh'

. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh

export ORACLE_SID=${STANDBY_ORACLE_SID}

echo "******************************************************************************"
echo "Current broker file settings on the standby." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200
COLUMN value FORMAT A60
SELECT name, value FROM v$parameter WHERE name LIKE 'dg_broker%';
EXIT;
SQL

echo "******************************************************************************"
echo "Move the broker files to the local filesystem and start the broker." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<SQL
ALTER SYSTEM SET dg_broker_config_file1='${ORACLE_HOME}/dbs/dr1${STANDBY_DB_UNQNAME}.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_config_file2='${ORACLE_HOME}/dbs/dr2${STANDBY_DB_UNQNAME}.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH;
EXIT;
SQL

echo "Waiting for DMON to come up on the standby..."
sleep 30

sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200
COLUMN value FORMAT A60
SELECT name, value FROM v$parameter WHERE name LIKE 'dg_broker%';
EXIT;
SQL

echo "******************************************************************************"
echo "Add the standby to the existing broker configuration." `date`
echo "******************************************************************************"
dgmgrl sys/${SYS_PASSWORD}@${PRIMARY_DB_UNQNAME} <<EOF
ADD DATABASE '${STANDBY_DB_UNQNAME}' AS CONNECT IDENTIFIER IS ${STANDBY_DB_UNQNAME};
ENABLE CONFIGURATION;
EXIT;
EOF

echo "Waiting for redo transport and apply to start..."
sleep 90

echo "******************************************************************************"
echo "Data Guard configuration." `date`
echo "******************************************************************************"
dgmgrl sys/${SYS_PASSWORD}@${PRIMARY_DB_UNQNAME} <<EOF
SHOW CONFIGURATION;
SHOW DATABASE '${STANDBY_DB_UNQNAME}';
VALIDATE DATABASE '${STANDBY_DB_UNQNAME}';
EXIT;
EOF

echo "******************************************************************************"
echo "Force a log switch on the primary and check apply." `date`
echo "******************************************************************************"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null oracle@${NODE1_HOSTNAME} \
  ". /home/oracle/scripts/setEnv.sh; export ORACLE_SID=${NODE1_ORACLE_SID}; \
   echo 'ALTER SYSTEM ARCHIVE LOG CURRENT;' | sqlplus -S / as sysdba"

sleep 45

sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200
COLUMN name FORMAT A12
SELECT name, db_unique_name, database_role, open_mode, protection_mode FROM v$database;
SELECT process, status, thread#, sequence# FROM v$managed_standby WHERE process LIKE 'MRP%' OR process LIKE 'RFS%';
SELECT thread#, MAX(sequence#) AS applied FROM v$archived_log WHERE applied = 'YES' GROUP BY thread# ORDER BY thread#;
EXIT;
SQL
