. /vagrant_config/install.env
. /home/oracle/scripts/setEnv.sh

# The primary applies the OJVM RU with opatchauto after the DB home install.
# There is no database in this home yet and no GI, so a plain opatch apply is
# enough here - and it keeps both homes on exactly the same patch level.
echo "******************************************************************************"
echo "Apply OJVM RU (${PATCH_PATH2}) to the standby DB home." `date`
echo "******************************************************************************"
export PATH=${ORACLE_HOME}/OPatch:${PATH}

cd ${SOFTWARE_DIR}
if [ ! -d ${PATCH_PATH2} ]; then
  unzip -oq /vagrant_software/${PATCH_FILE}
fi

cd ${PATCH_PATH2}
${ORACLE_HOME}/OPatch/opatch apply -silent -oh ${ORACLE_HOME}

echo "******************************************************************************"
echo "Patch inventory of the standby home." `date`
echo "******************************************************************************"
${ORACLE_HOME}/OPatch/opatch lspatches -oh ${ORACLE_HOME}
