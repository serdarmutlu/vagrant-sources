# Re-runs everything after the software installation, on a standby VM where
# "vagrant up" already installed the DB home but the Data Guard steps failed.
# Run as the oracle user:
#   sudo su - oracle -c 'sh /vagrant/scripts/resume_dataguard.sh'

. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh
. /vagrant/scripts/ssh_functions.sh

export ORACLE_SID=${STANDBY_ORACLE_SID}

echo "******************************************************************************"
echo "Resume: rebuild passwordless SSH to the RAC nodes." `date`
echo "******************************************************************************"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -q -N "" -f ~/.ssh/id_rsa
  cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
fi

# The stale known_hosts from the failed run is worthless now.
rm -f ~/.ssh/known_hosts
write_ssh_config

echo "${ORACLE_PASSWORD}" > /tmp/temp2.txt
chmod 600 /tmp/temp2.txt

wait_for_ssh ${NODE1_HOSTNAME} || exit 1
wait_for_ssh ${NODE2_HOSTNAME} || exit 1

install_ssh_key oracle ${NODE1_HOSTNAME} /tmp/temp2.txt || exit 1
install_ssh_key oracle ${NODE2_HOSTNAME} /tmp/temp2.txt || exit 1

require_ssh oracle ${NODE1_HOSTNAME}
require_ssh oracle ${NODE2_HOSTNAME}

echo "******************************************************************************"
echo "Resume: clean up leftovers from the failed duplicate." `date`
echo "******************************************************************************"
sqlplus -S / as sysdba <<SQL
SHUTDOWN ABORT;
EXIT;
SQL

rm -rf ${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}
rm -rf ${STANDBY_FRA}/${STANDBY_DB_UNQNAME_UPPER}
rm -f  ${ORACLE_HOME}/dbs/spfile${STANDBY_ORACLE_SID}.ora
rm -f  ${ORACLE_HOME}/dbs/lk${STANDBY_DB_UNQNAME_UPPER}
mkdir -p ${STANDBY_ORADATA}/${STANDBY_DB_UNQNAME_UPPER}
mkdir -p ${STANDBY_FRA}/${STANDBY_DB_UNQNAME_UPPER}

echo "******************************************************************************"
echo "Resume: prepare the primary." `date`
echo "******************************************************************************"
sh /vagrant/scripts/oracle_prepare_primary.sh || exit 1

echo "******************************************************************************"
echo "Resume: create the standby." `date`
echo "******************************************************************************"
sh /vagrant/scripts/oracle_create_standby.sh || exit 1

echo "******************************************************************************"
echo "Resume: configure the broker." `date`
echo "******************************************************************************"
sh /vagrant/scripts/oracle_configure_dataguard.sh || exit 1

echo "******************************************************************************"
echo "Resume complete." `date`
echo "******************************************************************************"
