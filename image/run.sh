#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

source /opt/bash-init.sh

#################################################
# print header
#################################################
cat <<'EOF'
   ___                   _     ____    _    ____
  / _ \ _ __   ___ _ __ | |   |  _ \  / \  |  _ \
 | | | | '_ \ / _ \ '_ \| |   | | | |/ _ \ | |_) |
 | |_| | |_) |  __/ | | | |___| |_| / ___ \|  __/
  \___/| .__/ \___|_| |_|_____|____/_/   \_\_|
       |_|

EOF

cat /opt/build_info
echo

log INFO "Timezone is $(date +"%Z %z")"


#################################################
# load custom init script if specified
#################################################
if [[ -f $INIT_SH_FILE ]]; then
   log INFO "Loading [$INIT_SH_FILE]..."
   source "$INIT_SH_FILE"
fi


# display slapd build info
slapd -VVV 2>&1 | log INFO || true


# Limit maximum number of open file descriptors otherwise slapd consumes two
# orders of magnitude more of RAM, see https://github.com/docker/docker/issues/8231
ulimit -n $LDAP_NOFILE_LIMIT


#################################################################
# Adjust UID/GID and file permissions based on env var config
#################################################################
if [ -n "${LDAP_OPENLDAP_UID:-}" ]; then
   effective_uid=$(id -u openldap)
   if [ "$LDAP_OPENLDAP_UID" != "$effective_uid" ]; then
      log INFO "Changing UID of openldap user from $effective_uid to $LDAP_OPENLDAP_UID..."
      usermod -o -u "$LDAP_OPENLDAP_UID" openldap
   fi
fi
if [ -n "${LDAP_OPENLDAP_GID:-}" ]; then
   effective_gid=$(id -g openldap)
   if [ "$LDAP_OPENLDAP_GID" != "$effective_gid" ]; then
      log INFO "Changing GID of openldap user from $effective_gid to $LDAP_OPENLDAP_GID..."
      usermod -o -g "$LDAP_OPENLDAP_GID" openldap
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

   function substr_before() {
      echo "${1%%$2*}"
   }

   function str_replace() {
      IFS= read -r -d $'\0' str
      echo "${str/$1/$2}"
   }

   function ldif() {
      log INFO "--------------------------------------------"
      local action=$1 && shift
      local file=${!#}
      log INFO "Loading [$file]..."
      interpolate < $file > /tmp/$(basename $file)
      ldap$action -H ldapi:/// "${@:1:${#}-1}" -f /tmp/$(basename $file)
   }

   # interpolate variable placeholders in env vars starting with "LDAP_INIT_"
   for name in ${!LDAP_INIT_*}; do
      declare "${name}=$(echo "${!name}" | interpolate)"
   done

   # pre-populate folders in case they are empty
   for folder in "/var/lib/ldap" "/etc/ldap/slapd.d"; do
      if [ "$folder" -ef "${folder}_orig" ]; then
         continue
      fi
      if [ -z "$(ls $folder)" ]; then
         log INFO "Initializing [$folder]..."
         cp -r --preserve=all ${folder}_orig/. $folder
      fi
   done

   if [ -z "${LDAP_INIT_ROOT_USER_PW:-}" ]; then
     log ERROR "LDAP_INIT_ROOT_USER_PW variable is not set!"
     exit 1
   fi

   # LDAP_INIT_ROOT_USER_PW_HASHED is used in /opt/ldifs/init_mdb_acls.ldif
   LDAP_INIT_ROOT_USER_PW_HASHED=$(slappasswd -s "${LDAP_INIT_ROOT_USER_PW}")

   if [ "${LDAP_INIT_RFC2307BIS_SCHEMA:-}" == "1" ]; then
      log INFO "Replacing NIS (RFC2307) schema with RFC2307bis schema..."

      log INFO "Exporting initial slapd config..."
      initial_sldapd_config=$(slapcat -n0)

      log INFO "Delete initial slapd config..."
      find /etc/ldap/slapd.d/ -type f -delete

      log INFO "Create modified sldapd config file..."
      # create ldif file where "{2}nis,cn=schema,cn=config" schema is replaced by "{2}rfc2307bis,cn=schema,cn=config"
      # 1. add all schema entries before "dn: cn={2}nis,cn=schema,cn=config" from initial config to new config file
      echo "${initial_sldapd_config%%dn: cn=\{2\}nis,cn=schema,cn=config*}" > /tmp/config.ldif
      # 2. add "dn: cn={2}rfc2307bis,cn=schema,cn=config" entry
      sed 's/rfc2307bis/{2}rfc2307bis/g' /opt/ldifs/schema_rfc2307bis02.ldif >> /tmp/config.ldif
      echo >> /tmp/config.ldif # add empty new line
      # 3. add entry "dn: cn={3}inetorgperson,cn=schema,cn=config" and following entries from initial config to new config file
      echo "dn: cn={3}inetorgperson,cn=schema,cn=config${initial_sldapd_config#*dn: cn=\{3\}inetorgperson,cn=schema,cn=config}" >> /tmp/config.ldif

      log INFO "Register modified slapd config with RFC2307bis schema..."
      slapadd -F /etc/ldap/slapd.d -n 0 -l /tmp/config.ldif
      chown openldap:openldap -R /etc/ldap/slapd.d
   fi

   /etc/init.d/slapd start
   # await ldap server start
   for i in {1..8}; do
     ldapwhoami -H ldapi:/// && break
     sleep 1
   done

   ldif add    -Y EXTERNAL /opt/ldifs/schema_sudo.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/schema_ldapPublicKey.ldif

   ldif modify -Y EXTERNAL /opt/ldifs/init_frontend.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/init_module_memberof.ldif
   ldif modify -Y EXTERNAL /opt/ldifs/init_mdb.ldif
   ldif modify -Y EXTERNAL /opt/ldifs/init_mdb_acls.ldif
   ldif modify -Y EXTERNAL /opt/ldifs/init_mdb_indexes.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/init_module_unique.ldif
   ldif add    -Y EXTERNAL /opt/ldifs/init_module_ppolicy.ldif

   if [ "${LDAP_INIT_ALLOW_CONFIG_ACCESS:-false}" == "true" ]; then
     ldif modify -Y EXTERNAL /opt/ldifs/init_config_admin_access.ldif
   fi

   LDAP_INIT_ORG_DN_ATTR=$(substr_before $LDAP_INIT_ORG_DN "," | str_replace "=" ": ") # referenced by init_org_tree.ldif
   ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_tree.ldif
   ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_ppolicy.ldif
   ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_entries.ldif

   log INFO "--------------------------------------------"

   echo "1" > /etc/ldap/slapd.d/initialized
   rm -f /tmp/*.ldif

   log INFO "Creating periodic LDAP backup at [$LDAP_BACKUP_FILE]..."
   slapcat -n 1 -l $LDAP_BACKUP_FILE || true

   /etc/init.d/slapd stop
   sleep 3
fi

echo "$LDAP_PPOLICY_PQCHECKER_RULE" > /etc/ldap/pqchecker/pqparams.dat


#################################################################
# Configure background task for LDAP backup
#################################################################
if [ -n "${LDAP_BACKUP_TIME:-}" ]; then
   log INFO "--------------------------------------------"
   log INFO "Configuring LDAP backup task to run daily: time=[${LDAP_BACKUP_TIME}] file=[$LDAP_BACKUP_FILE]..."
   if [[ "$LDAP_BACKUP_TIME" != +([0-9][0-9]:[0-9][0-9]) ]]; then
      log ERROR "The configured value [$LDAP_BACKUP_TIME] for LDAP_BACKUP_TIME is not in the expected 24-hour format [hh:mm]!"
      exit 1
   fi

   # testing if LDAP_BACKUP_FILE is writeable
   touch "$LDAP_BACKUP_FILE"

   function backup_ldap() {
      while true; do
         while [ "$(date +%H:%M)" != "${LDAP_BACKUP_TIME}" ]; do
            sleep 10s
         done
         log INFO "Creating periodic LDAP backup at [$LDAP_BACKUP_FILE]..."
         slapcat -n 1 -l "$LDAP_BACKUP_FILE" || true
         sleep 23h
      done
   }

   backup_ldap &
fi


#################################################################
# Start LDAP service
#################################################################
log INFO "--------------------------------------------"
log INFO "Starting OpenLDAP: slapd..."

exec /usr/sbin/slapd \
   $(for logLevel in ${LDAP_LOG_LEVELS:-}; do echo -n "-d $logLevel "; done) \
   -h "ldap:/// ldapi:///" \
   -u openldap \
   -g openldap \
   -F /etc/ldap/slapd.d 2>&1 | log INFO
