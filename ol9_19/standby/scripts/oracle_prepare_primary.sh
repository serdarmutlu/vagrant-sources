. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh
. /vagrant/scripts/ssh_functions.sh

require_ssh oracle ${NODE1_HOSTNAME}
require_ssh oracle ${NODE2_HOSTNAME}

echo "******************************************************************************"
echo "Configure TNS and static listener entries on both RAC nodes." `date`
echo "******************************************************************************"
scp ${SSH_OPTS} /vagrant/scripts/primary_tns_remote.sh oracle@${NODE1_HOSTNAME}:/tmp/ || exit 1
scp ${SSH_OPTS} /vagrant/scripts/primary_tns_remote.sh oracle@${NODE2_HOSTNAME}:/tmp/ || exit 1
ssh ${SSH_OPTS} oracle@${NODE1_HOSTNAME} "sh /tmp/primary_tns_remote.sh" || exit 1
ssh ${SSH_OPTS} oracle@${NODE2_HOSTNAME} "sh /tmp/primary_tns_remote.sh" || exit 1

echo "******************************************************************************"
echo "Prepare the primary database." `date`
echo "******************************************************************************"
scp ${SSH_OPTS} /vagrant/scripts/primary_prepare_remote.sh oracle@${NODE1_HOSTNAME}:/tmp/ || exit 1
ssh ${SSH_OPTS} oracle@${NODE1_HOSTNAME} "sh /tmp/primary_prepare_remote.sh" || exit 1

echo "******************************************************************************"
echo "Fetch the password file from the primary." `date`
echo "******************************************************************************"
scp ${SSH_OPTS} oracle@${NODE1_HOSTNAME}:/tmp/orapw${PRIMARY_DB_UNQNAME} \
    ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}

if [ ! -s ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID} ]; then
  echo "******************************************************************************"
  echo "FATAL: the password file was not copied from the primary."
  echo "Without it the RMAN auxiliary connection fails with ORA-01017."
  echo "******************************************************************************"
  exit 1
fi

chmod 640 ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}
ls -l ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}
