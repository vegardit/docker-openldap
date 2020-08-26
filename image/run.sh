#!/usr/bin/env bash
#
# Copyright 2019-2020 by Vegard IT GmbH, Germany, https://vegardit.com
# SPDX-License-Identifier: Apache-2.0
#
# @author Sebastian Thomschke, Vegard IT GmbH
#
# https://github.com/vegardit/docker-openldap
#

set -e -u

##############################
# execute script with bash if loaded with other shell interpreter
##############################
if [ -z "${BASH_VERSINFO:-}" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

set -o pipefail

trap 'echo >&2 "$(date +%H:%M:%S) Error - exited with status $? at line $LINENO:"; pr -tn $0 | tail -n+$((LINENO - 3)) | head -n7' ERR

if [ "${DEBUG_RUN_SH:-}" == "1" ]; then
   set -x
fi

cat <<'EOF'
 _    __                          __   __________
| |  / /__  ____ _____ __________/ /  /  _/_  __/
| | / / _ \/ __ `/ __ `/ ___/ __  /   / /  / /
| |/ /  __/ /_/ / /_/ / /  / /_/ /  _/ /  / /
|___/\___/\__, /\__,_/_/   \__,_/  /___/ /_/
         /____/

EOF

cat /opt/build_info
echo

if [ -f "$INIT_SH_FILE" ]; then
   source "$INIT_SH_FILE"
fi


function log() {
   if [ -p /dev/stdin ]; then
      while read line; do
          echo "[$(date "+%Y-%m-%d %H:%M:%S") ${BASH_SOURCE}:${BASH_LINENO}] $line"
      done
   else
      echo "[$(date "+%Y-%m-%d %H:%M:%S") ${BASH_SOURCE}:${BASH_LINENO}] ${@}"
   fi
}


# display slapd build info
slapd -VVV 2>&1 | log || true


# Limit maximum number of open file descriptors otherwise slapd consumes two
# orders of magnitude more of RAM, see https://github.com/docker/docker/issues/8231
ulimit -n $LDAP_NOFILE_LIMIT


#################################################################
# Adjust UID/GID and file permissions based on env var config
#################################################################
if [ -n "${LDAP_OPENLDAP_UID:-}" ]; then
   effective_uid=$(id -u openldap)
   if [ "$LDAP_OPENLDAP_UID" != "$effective_uid" ]; then
      log "Changing UID of openldap user from $effective_uid to $LDAP_OPENLDAP_UID..."
      usermod -o -u "$LDAP_OPENLDAP_UID" openldap
   fi
fi
if [ -n "${LDAP_OPENLDAP_GID:-}" ]; then
   effective_gid=$(id -g openldap)
   if [ "$LDAP_OPENLDAP_GID" != "$effective_gid" ]; then
      log "Changing GID of openldap user from $effective_gid to $LDAP_OPENLDAP_GID..."
      usermod -o -u "$LDAP_OPENLDAP_GID" openldap
   fi
fi
chown -R openldap:openldap /etc/ldap
chown -R openldap:openldap /var/lib/ldap
chown -R openldap:openldap /var/lib/ldap_orig
chown -R openldap:openldap /var/run/slapd


#################################################################
# Configure LDAP server on initial container launch
#################################################################
if [ ! -e /etc/ldap/slapd.d/initialized ]; then

   function interpolate_vars() {
      # based on https://stackoverflow.com/a/40167919
      local line lineEscaped
      while IFS= read -r line || [ -n "$line" ]; do  # the `||` clause ensures that the last line is read even if it doesn't end with \n
         # escape all chars that could trigger an expansion
         IFS= read -r lineEscaped < <(echo "$line" | tr '`([$' '\1\2\3\4')
         # selectively re-enable ${ references
         lineEscaped=${lineEscaped//$'\4'{/\${}
         # escape back slashes to preserve them
         lineEscaped=${lineEscaped//\\/\\\\}
         # escape embedded double quotes to preserve them
         lineEscaped=${lineEscaped//\"/\\\"}
         eval "printf '%s\n' \"$lineEscaped\"" | tr '\1\2\3\4' '`([$'
      done
   }

   function substr_before() {
      echo "${1%%$2*}"
   }

   function str_replace() {
      IFS= read -r -d $'\0' str
      echo "${str/$1/$2}"
   }

   function ldif() {
      log "--------------------------------------------"
      local action=$1 && shift
      local file=${!#}
      log "Loading [$file]..."
      interpolate_vars < $file > /tmp/$(basename $file)
      ldap$action -H ldapi:/// "${@:1:${#}-1}" -f /tmp/$(basename $file)
   }

   # interpolate variable placeholders in env vars starting with "LDAP_INIT_"
   for name in ${!LDAP_INIT_*}; do
      declare "${name}=$(echo "${!name}" | interpolate_vars)"
   done

   # pre-populate folders in case they are empty
   for folder in "/var/lib/ldap" "/etc/ldap/slapd.d"; do
      if [ "$folder" -ef "${folder}_orig" ]; then
         continue
      fi
      if [ -z "$(ls $folder)" ]; then
         log "Initializing [$folder]..."
         cp -r --preserve=all ${folder}_orig/. $folder
      fi
   done

   LDAP_INIT_ROOT_USER_PW_HASHED=$(slappasswd -s "${LDAP_INIT_ROOT_USER_PW}")
   /etc/init.d/slapd start
   sleep 3

   if [ "${LDAP_INIT_RFC2307BIS_SCHEMA:-}" == "1" ]; then
      log "Replacing NIS (RFC2307) schema with RFC2307bis schema..."
      ldapdelete  -Y EXTERNAL cn={2}nis,cn=schema,cn=config
      ldif add    -Y EXTERNAL /opt/ldifs/schema_rfc2307bis02.ldif
   fi

   ldif add    -Y EXTERNAL /etc/ldap/schema/ppolicy.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/schema_sudo.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/schema_ldapPublicKey.ldif

   ldif modify -Y EXTERNAL /opt/ldifs/init_frontend.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/init_module_memberof.ldif
   ldif modify -Y EXTERNAL /opt/ldifs/init_mdb.ldif
   ldif modify -Y EXTERNAL /opt/ldifs/init_mdb_acls.ldif
   ldif modify -Y EXTERNAL /opt/ldifs/init_mdb_indexes.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/init_module_unique.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/init_module_ppolicy.ldif

   LDAP_INIT_ORG_DN_ATTR=$(substr_before $LDAP_INIT_ORG_DN "," | str_replace "=" ": ") # referenced by init_org_tree.ldif
   ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_tree.ldif
   ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_ppolicy.ldif
   ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_entries.ldif

   log "--------------------------------------------"

   echo "1" > /etc/ldap/slapd.d/initialized
   rm -f /tmp/*.ldif

   log "Creating periodic LDAP backup at [$LDAP_BACKUP_FILE]..."
   slapcat -n 1 -l $LDAP_BACKUP_FILE || true

   /etc/init.d/slapd stop
   sleep 3
fi

echo "$LDAP_PPOLICY_PQCHECKER_RULE" > /etc/ldap/pqchecker/pqparams.dat


#################################################################
# Configure background task for LDAP backup
#################################################################
if [ -n "${LDAP_BACKUP_TIME:-}" ]; then
   log "--------------------------------------------"
   log "Configuring LDAP backup task to run daily: time=[${LDAP_BACKUP_TIME}] file=[$LDAP_BACKUP_FILE]..."
   if [[ "$LDAP_BACKUP_TIME" != +([0-9][0-9]:[0-9][0-9]) ]]; then
      log "The configured value [$LDAP_BACKUP_TIME] for LDAP_BACKUP_TIME is not in the expected 24-hour format [hh:mm]!"
      exit 1
   fi

   # testing if LDAP_BACKUP_FILE is writeable
   touch "$LDAP_BACKUP_FILE"

   function backup_ldap() {
      while true; do
         while [ "$(date +%H:%M)" != "${LDAP_BACKUP_TIME}" ]; do
            sleep 10s
         done
         log "Creating periodic LDAP backup at [$LDAP_BACKUP_FILE]..."
         slapcat -n 1 -l "$LDAP_BACKUP_FILE" || true
         sleep 23h
      done
   }

   backup_ldap &
fi


#################################################################
# Start LDAP service
#################################################################
log "--------------------------------------------"
log "Starting OpenLDAP: slapd..."

#required for propagating SIGTERM from docker to service process
#https://unix.stackexchange.com/questions/146756/forward-sigterm-to-child-in-bash/444676#444676
function trap_handler() {
    local signal=$1
    if [ -n "${service_process_pid:-}" ]; then
        log "Sending [$signal] to PID [$service_process_pid] ..."
        kill -s $signal $service_process_pid 2>/dev/null
    else
        log "Received [$signal] before service started."
        sig_received_before_service_started=$signal
    fi
}

trap 'trap_handler TERM' SIGTERM SIGINT SIGHUP # https://github.com/openldap/openldap/search?q=SIGTERM
trap 'trap_handler QUIT' SIGQUIT
trap 'trap_handler USR1' SIGUSR1 # https://github.com/openldap/openldap/search?q=SIGUSR1
trap 'trap_handler USR2' SIGUSR2 # https://github.com/openldap/openldap/search?q=SIGUSR2

/usr/sbin/slapd \
   $(for logLevel in ${LDAP_LOG_LEVELS:-}; do echo -n "-d $logLevel "; done) \
   -h "ldap:/// ldapi:///" \
   -u openldap -g openldap \
   -F /etc/ldap/slapd.d 2>&1 | log &

service_process_pid=$(jobs -p | tail -1)
log "OpenLDAP PID: $service_process_pid"

if [ -n "${sig_received_before_service_started:-}" ]; then
   kill -s $sig_received_before_service_started $service_process_pid 2>/dev/null
fi

wait $service_process_pid
trap - TERM INT
wait $service_process_pid
exit_status=$?
exit $exit_status
