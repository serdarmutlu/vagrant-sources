echo "******************************************************************************"
echo "Standby Setup Start." `date`
echo "******************************************************************************"

. /vagrant_config/install.env

sh /vagrant_scripts/prepare_u01_disk.sh

sh /vagrant_scripts/install_os_packages.sh

echo "******************************************************************************"
echo "Set root and oracle password and change ownership of /u01." `date`
echo "******************************************************************************"
echo -e "${ROOT_PASSWORD}\n${ROOT_PASSWORD}" | passwd
echo -e "${ORACLE_PASSWORD}\n${ORACLE_PASSWORD}" | passwd oracle
mkdir -p ${SOFTWARE_DIR}
chown -R oracle:oinstall /u01
chmod -R 775 /u01
usermod -aG vagrant oracle

sh /vagrant_scripts/configure_hosts_base.sh

cat > /etc/resolv.conf <<EOF
search ${DOMAIN_NAME}
nameserver ${DNS_PUBLIC_IP}
EOF

# Stop NetworkManager altering the /etc/resolv.conf contents.
sed -i -e "s|\[main\]|\[main\]\ndns=none|g" /etc/NetworkManager/NetworkManager.conf
systemctl restart NetworkManager.service

sh /vagrant_scripts/configure_chrony.sh

echo "******************************************************************************"
echo "Set Hostname." `date`
echo "******************************************************************************"
hostnamectl set-hostname ${STANDBY_HOSTNAME}

echo "******************************************************************************"
echo "Register the standby host on DNS/RAC nodes (safety net for an existing cluster)." `date`
echo "******************************************************************************"
echo "${ROOT_PASSWORD}" > /tmp/temp1.txt
chmod 600 /tmp/temp1.txt
for H in ${DNS_PUBLIC_IP} ${NODE1_PUBLIC_IP} ${NODE2_PUBLIC_IP}; do
  sshpass -f /tmp/temp1.txt ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${H} \
    "grep -q ' ${STANDBY_HOSTNAME}\$' /etc/hosts || echo '${STANDBY_PUBLIC_IP}  ${STANDBY_FQ_HOSTNAME}  ${STANDBY_HOSTNAME}' >> /etc/hosts"
done
sshpass -f /tmp/temp1.txt ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${DNS_PUBLIC_IP} "systemctl restart dnsmasq"

echo "******************************************************************************"
echo "Relax sshd connection penalties on the RAC nodes." `date`
echo "******************************************************************************"
# OpenSSH 9.9 turns PerSourcePenalties on by default. A build that opens many
# short-lived connections in a burst gets its source IP throttled, and the
# symptom is "kex_exchange_identification: Connection closed by remote host".
# This is a lab, so switch it off if the sshd on the node is new enough to
# have the option. Older sshd versions are left untouched.
for H in ${NODE1_PUBLIC_IP} ${NODE2_PUBLIC_IP}; do
  sshpass -f /tmp/temp1.txt ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${H} \
    "sshd -T 2>/dev/null | grep -qi '^persourcepenalties' && { grep -qi '^PerSourcePenalties' /etc/ssh/sshd_config || echo 'PerSourcePenalties no' >> /etc/ssh/sshd_config; systemctl reload sshd; echo 'PerSourcePenalties disabled on '\`hostname -s\`; } || echo 'sshd has no PerSourcePenalties option on '\`hostname -s\`"
done

su - oracle -c 'sh /vagrant/scripts/oracle_user_environment_setup.sh'
. /home/oracle/scripts/setEnv.sh

su - oracle -c 'sh /vagrant/scripts/oracle_db_software_installation.sh'

echo "******************************************************************************"
echo "Run DB root scripts." `date`
echo "******************************************************************************"
sh ${ORA_INVENTORY}/orainstRoot.sh
sh ${ORACLE_HOME}/root.sh

su - oracle -c 'sh /vagrant/scripts/oracle_software_patch_ojvm.sh'

echo "******************************************************************************"
echo "Prepare the RAC primary for Data Guard." `date`
echo "******************************************************************************"
su - oracle -c 'sh /vagrant/scripts/oracle_prepare_primary.sh'

echo "******************************************************************************"
echo "Create the physical standby." `date`
echo "******************************************************************************"
su - oracle -c 'sh /vagrant/scripts/oracle_create_standby.sh'

echo "******************************************************************************"
echo "Configure the Data Guard broker." `date`
echo "******************************************************************************"
su - oracle -c 'sh /vagrant/scripts/oracle_configure_dataguard.sh'

echo "******************************************************************************"
echo "Enable auto-start of the standby." `date`
echo "******************************************************************************"
sed -i "/^${STANDBY_ORACLE_SID}:/d" /etc/oratab
echo "${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N" >> /etc/oratab

cat > /etc/systemd/system/oracle-standby.service <<EOF
[Unit]
Description=Oracle physical standby ${STANDBY_ORACLE_SID}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=oracle
Group=oinstall
Environment=ORACLE_HOME=${ORACLE_HOME}
Environment=ORACLE_SID=${STANDBY_ORACLE_SID}
ExecStart=/bin/bash -c '${ORACLE_HOME}/bin/lsnrctl start; echo -e "startup mount;\nexit;" | ${ORACLE_HOME}/bin/sqlplus -S / as sysdba'
ExecStop=/bin/bash -c 'echo -e "shutdown immediate;\nexit;" | ${ORACLE_HOME}/bin/sqlplus -S / as sysdba; ${ORACLE_HOME}/bin/lsnrctl stop'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable oracle-standby.service

rm -f /tmp/temp1.txt /tmp/temp2.txt

echo "******************************************************************************"
echo "Standby Setup End." `date`
echo "******************************************************************************"
