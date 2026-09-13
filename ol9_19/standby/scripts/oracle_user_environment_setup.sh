. /vagrant_config/install.env

echo "******************************************************************************"
echo "Create environment scripts." `date`
echo "******************************************************************************"
mkdir -p /home/oracle/scripts

cat > /home/oracle/scripts/setEnv.sh <<EOF
# Oracle Settings
export TMP=/tmp
export TMPDIR=\$TMP

export ORACLE_HOSTNAME=${STANDBY_HOSTNAME}
export ORACLE_UNQNAME=${STANDBY_DB_UNQNAME}
export ORACLE_BASE=${ORACLE_BASE}
export ORA_INVENTORY=${ORA_INVENTORY}
export DB_HOME=\$ORACLE_BASE/${DB_HOME_EXT}
export ORACLE_HOME=\$DB_HOME
export ORACLE_SID=${STANDBY_ORACLE_SID}
export ORACLE_TERM=xterm
export BASE_PATH=/usr/sbin:\$PATH
export PATH=\$ORACLE_HOME/bin:\$BASE_PATH

export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
export CLASSPATH=\$ORACLE_HOME/JRE:\$ORACLE_HOME/jlib:\$ORACLE_HOME/rdbms/jlib

alias db_env='. /home/oracle/scripts/db_env'
EOF

cat >> /home/oracle/.bash_profile <<EOF
. /home/oracle/scripts/setEnv.sh
EOF

cat > /home/oracle/scripts/db_env <<EOF
export ORACLE_SID=${STANDBY_ORACLE_SID}
export ORACLE_HOME=\$DB_HOME
export PATH=\$ORACLE_HOME/bin:\$BASE_PATH

export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
export CLASSPATH=\$ORACLE_HOME/JRE:\$ORACLE_HOME/jlib:\$ORACLE_HOME/rdbms/jlib
EOF

echo "******************************************************************************"
echo "Create directories." `date`
echo "******************************************************************************"
. /home/oracle/scripts/setEnv.sh
mkdir -p ${DB_HOME}
mkdir -p ${ORACLE_BASE}/admin/${STANDBY_DB_UNQNAME}/adump
mkdir -p ${STANDBY_ORADATA}
mkdir -p ${STANDBY_FRA}

echo "******************************************************************************"
echo "Passwordless SSH from the standby to the RAC nodes (oracle)." `date`
echo "******************************************************************************"
. /vagrant/scripts/ssh_functions.sh

mkdir -p ~/.ssh
chmod 700 ~/.ssh
rm -f ~/.ssh/id_rsa ~/.ssh/id_rsa.pub ~/.ssh/known_hosts
ssh-keygen -t rsa -q -N "" -f ~/.ssh/id_rsa
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# No ssh-keyscan here on purpose - see the note in ssh_functions.sh.
write_ssh_config

echo "${ORACLE_PASSWORD}" > /tmp/temp2.txt
chmod 600 /tmp/temp2.txt

wait_for_ssh ${NODE1_HOSTNAME}
wait_for_ssh ${NODE2_HOSTNAME}

install_ssh_key oracle ${NODE1_HOSTNAME} /tmp/temp2.txt
install_ssh_key oracle ${NODE2_HOSTNAME} /tmp/temp2.txt

require_ssh oracle ${NODE1_HOSTNAME}
require_ssh oracle ${NODE2_HOSTNAME}

ssh oracle@${NODE1_HOSTNAME} date
ssh oracle@${NODE2_HOSTNAME} date

echo "******************************************************************************"
echo "Unzip the patch bundle." `date`
echo "******************************************************************************"
cd ${SOFTWARE_DIR}
unzip -oq /vagrant_software/${PATCH_FILE}
