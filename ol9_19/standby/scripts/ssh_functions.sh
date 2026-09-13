# Shared SSH helpers for the standby build.
#
# Background: OpenSSH 9.9 enables PerSourcePenalties by default. Connections
# that close without authenticating (exactly what ssh-keyscan does) earn the
# source IP a penalty, and after a burst of them sshd drops new connections at
# the TCP level with "kex_exchange_identification: Connection closed by remote
# host". The RAC nodes end up on 9.9 after a dnf update, so the old
# ssh-keyscan-everything approach locks the standby out.
#
# So: no keyscan at all. Host key checking is turned off in ~/.ssh/config
# instead, and every connection attempt is retried with a back-off.

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"

write_ssh_config() {
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  cat > ~/.ssh/config <<EOF
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 15
EOF
  chmod 600 ~/.ssh/config
}

# wait_for_ssh <host> - waits until the sshd on <host> answers at all.
# Clears any penalty left over from an earlier failed run.
wait_for_ssh() {
  WFS_HOST=$1
  WFS_TRIES=${2:-20}
  WFS_I=1
  while [ ${WFS_I} -le ${WFS_TRIES} ]; do
    if ssh ${SSH_OPTS} -o BatchMode=yes -o PreferredAuthentications=none \
         nobodyuser@${WFS_HOST} true 2>&1 | grep -q "Permission denied"; then
      echo "sshd on ${WFS_HOST} is answering."
      return 0
    fi
    echo "sshd on ${WFS_HOST} not answering (attempt ${WFS_I}/${WFS_TRIES}); waiting 30s."
    sleep 30
    WFS_I=`expr ${WFS_I} + 1`
  done
  echo "ERROR: sshd on ${WFS_HOST} never became reachable."
  return 1
}

# install_ssh_key <user> <host> <passwordfile>
install_ssh_key() {
  ISK_USER=$1
  ISK_HOST=$2
  ISK_PWFILE=$3
  ISK_I=1
  while [ ${ISK_I} -le 8 ]; do
    if ssh ${SSH_OPTS} -o BatchMode=yes ${ISK_USER}@${ISK_HOST} true 2>/dev/null; then
      echo "Passwordless SSH to ${ISK_USER}@${ISK_HOST} is working."
      return 0
    fi
    sshpass -f ${ISK_PWFILE} ssh-copy-id ${SSH_OPTS} ${ISK_USER}@${ISK_HOST} >/dev/null 2>&1
    if ssh ${SSH_OPTS} -o BatchMode=yes ${ISK_USER}@${ISK_HOST} true 2>/dev/null; then
      echo "Key installed for ${ISK_USER}@${ISK_HOST}."
      return 0
    fi
    echo "Attempt ${ISK_I}/8 for ${ISK_USER}@${ISK_HOST} failed; sshd may be throttling. Waiting 45s."
    sleep 45
    ISK_I=`expr ${ISK_I} + 1`
  done
  echo "ERROR: could not establish passwordless SSH to ${ISK_USER}@${ISK_HOST}."
  return 1
}

# require_ssh <user> <host> - abort the build early rather than cascading.
require_ssh() {
  if ! ssh ${SSH_OPTS} -o BatchMode=yes $1@$2 true 2>/dev/null; then
    echo "******************************************************************************"
    echo "FATAL: no passwordless SSH from the standby to $1@$2."
    echo "Nothing further can run. Fix SSH, then re-run:"
    echo "  sudo su - oracle -c 'sh /vagrant/scripts/resume_dataguard.sh'"
    echo "******************************************************************************"
    exit 1
  fi
}
