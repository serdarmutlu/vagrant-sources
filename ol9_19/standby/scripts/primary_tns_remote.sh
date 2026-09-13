# Runs on a RAC node. Adds the Data Guard TNS aliases and a static
# <db_unique_name>_DGMGRL listener entry, so the broker can always reach
# an instance that is down or in nomount.
. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh

if [ "`hostname -s`" = "${NODE2_HOSTNAME}" ]; then
  THIS_SID=${NODE2_ORACLE_SID}
  THIS_VIP=${NODE2_FQ_VIPNAME}
  ASM_SID=+ASM2
else
  THIS_SID=${NODE1_ORACLE_SID}
  THIS_VIP=${NODE1_FQ_VIPNAME}
  ASM_SID=+ASM1
fi

echo "******************************************************************************"
echo "TNS entries on `hostname -s`." `date`
echo "******************************************************************************"
TNS_FILE=${ORACLE_HOME}/network/admin/tnsnames.ora
mkdir -p ${ORACLE_HOME}/network/admin
touch ${TNS_FILE}

if ! grep -qi "^${PRIMARY_DB_UNQNAME} *=" ${TNS_FILE}; then
cat >> ${TNS_FILE} <<EOF

${PRIMARY_DB_UNQNAME} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${FQ_SCAN_NAME})(PORT = ${SCAN_PORT}))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = ${PRIMARY_DB_UNQNAME}))
  )
EOF
fi

if ! grep -qi "^${STANDBY_DB_UNQNAME} *=" ${TNS_FILE}; then
cat >> ${TNS_FILE} <<EOF

${STANDBY_DB_UNQNAME} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_FQ_HOSTNAME})(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = ${STANDBY_DB_UNQNAME}))
  )
EOF
fi

echo "******************************************************************************"
echo "Static _DGMGRL entry in the Grid listener on `hostname -s`." `date`
echo "******************************************************************************"
LSNR_FILE=${GRID_HOME}/network/admin/listener.ora
touch ${LSNR_FILE}

if ! grep -q "${PRIMARY_DB_UNQNAME}_DGMGRL" ${LSNR_FILE}; then
cat >> ${LSNR_FILE} <<EOF

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNQNAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${THIS_SID})
    )
  )
EOF
  export ORACLE_SID=${ASM_SID}
  export ORACLE_HOME=${GRID_HOME}
  export PATH=${GRID_HOME}/bin:${BASE_PATH}
  lsnrctl reload LISTENER
fi
