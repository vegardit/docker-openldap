#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# shellcheck disable=SC1091  # Not following: /opt/bash-init.sh was not specified as input
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
if [[ -f ${INIT_SH_FILE:-} ]]; then
  log INFO "Loading [$INIT_SH_FILE]..."

  # shellcheck disable=SC1090  # ShellCheck can't follow non-constant source
  source "$INIT_SH_FILE"
fi


# display slapd build info
slapd -VVV 2>&1 | log INFO || true


# Limit maximum number of open file descriptors otherwise slapd consumes two
# orders of magnitude more of RAM, see https://github.com/docker/docker/issues/8231
ulimit -n "$LDAP_NOFILE_LIMIT"


#################################################################
# Adjust UID/GID and file permissions based on env var config
#################################################################
if [[ -n ${LDAP_OPENLDAP_UID:-} ]]; then
   effective_uid=$(id -u openldap)
   if [[ $LDAP_OPENLDAP_UID != "$effective_uid" ]]; then
      log INFO "Changing UID of openldap user from $effective_uid to $LDAP_OPENLDAP_UID..."
      usermod -o -u "$LDAP_OPENLDAP_UID" openldap
   fi
fi
if [[ -n ${LDAP_OPENLDAP_GID:-} ]]; then
   effective_gid=$(id -g openldap)
   if [[ $LDAP_OPENLDAP_GID != "$effective_gid" ]]; then
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
function ldif() {
  log INFO "---------------------------------------"
  local action=$1 && shift
  local file=${!#}
  log INFO "Executing [ldap$action $file]..."
  # shellcheck disable=SC2094  # Make sure not to read and write the same file in the same pipeline
  local tmpfile
  tmpfile=$(mktemp --suffix=.ldif /tmp/ldif.XXXXXX)
  interpolate <"$file" >"$tmpfile"
  "ldap$action" -H ldapi:/// "${@:1:${#}-1}" -f "$tmpfile" 2>&1 | log INFO
  rm -f "$tmpfile"
}

if [ ! -e /etc/ldap/slapd.d/initialized ]; then
  log INFO "======================================="
  log INFO "Applying initial configuration"
  log INFO "======================================="
  function substr_before() {
    # shellcheck disable=SC2295  # Expansions inside ${..} need to be quoted separately, otherwise they match as patterns
    echo "${1%%${2}*}"
  }

  function str_replace() {
    IFS= read -r -d $'\0' str
    echo "${str/$1/$2}"
  }

  # interpolate variable placeholders in env vars starting with "LDAP_INIT_"
  for name in ${!LDAP_INIT_*}; do
    declare "${name}=$(echo "${!name}" | interpolate)"
  done

  # pre-populate folders in case they are empty
  for folder in "/var/lib/ldap" "/etc/ldap/slapd.d"; do
    if [[ $folder -ef "${folder}_orig" ]]; then
      continue
    fi
    if [[ -z $(ls $folder) ]]; then
      log INFO "Initializing [$folder]..."
      cp -r --preserve=all ${folder}_orig/. $folder
    fi
  done

  if [[ -z ${LDAP_INIT_ROOT_USER_DN:-} ]]; then
    log ERROR "LDAP_INIT_ROOT_USER_DN variable is not set!"
    exit 1
  fi

  if [[ -z ${LDAP_INIT_ROOT_USER_PW:-} ]]; then
    log ERROR "LDAP_INIT_ROOT_USER_PW variable is not set!"
    exit 1
  fi

  # shellcheck disable=SC2034  # LDAP_INIT_ROOT_USER_PW_HASHED appears unused
  LDAP_INIT_ROOT_USER_PW_HASHED=$(slappasswd -s "${LDAP_INIT_ROOT_USER_PW}")
  # LDAP_INIT_ROOT_USER_PW_HASHED is referenced in /opt/ldifs/init_mdb_acls.ldif

  if [[ ${LDAP_INIT_RFC2307BIS_SCHEMA:-} == 1 ]]; then
    log INFO "Replacing NIS (RFC2307) schema with RFC2307bis schema..."

    log INFO "Exporting initial slapd config..."
    initial_sldapd_config=$(slapcat -n0)

    log INFO "Delete initial slapd config..."
    find /etc/ldap/slapd.d/ -type f -delete

    log INFO "Create modified sldapd config file..."
    {
       # create ldif file where "{2}nis,cn=schema,cn=config" schema is replaced by "{2}rfc2307bis,cn=schema,cn=config"
       # 1. add all schema entries before "dn: cn={2}nis,cn=schema,cn=config" from initial config to new config file
       echo "${initial_sldapd_config%%dn: cn=\{2\}nis,cn=schema,cn=config*}"
       # 2. add "dn: cn={2}rfc2307bis,cn=schema,cn=config" entry
       sed 's/rfc2307bis/{2}rfc2307bis/g' /opt/ldifs/schema_rfc2307bis02.ldif
       echo # add empty new line
       # 3. add entry "dn: cn={3}inetorgperson,cn=schema,cn=config" and following entries from initial config to new config file
       echo "dn: cn={3}inetorgperson,cn=schema,cn=config${initial_sldapd_config#*dn: cn=\{3\}inetorgperson,cn=schema,cn=config}"
    } >/tmp/config.ldif

    log INFO "Register modified slapd config with RFC2307bis schema..."
    slapadd -F /etc/ldap/slapd.d -n 0 -l /tmp/config.ldif | log INFO
    chown openldap:openldap -R /etc/ldap/slapd.d
  fi

  /etc/init.d/slapd start 2>&1 | log INFO
  # await ldap server start
  for _ in {1..8}; do
    if ldapwhoami -H ldapi:/// | log INFO; then
      break
    fi
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

  if [[ ${LDAP_INIT_ALLOW_CONFIG_ACCESS:-false} == true ]]; then
    ldif modify -Y EXTERNAL /opt/ldifs/init_config_admin_access.ldif
  fi

  # calculate LDAP_INIT_ORG_COMPUTED_ATTRS variable, referenced in init_org_tree.ldif
  if [[ -z ${LDAP_INIT_ORG_ATTR_O:-} ]] && [[ ${LDAP_INIT_ORG_DN:-} =~ [oO]=([^,]*) ]]; then
    # derive 'o:' from LDAP_INIT_ORG_DN if LDAP_INIT_ORG_ATTR_O is unset and "O=..." is present
    # e.g. LDAP_INIT_ORG_DN="O=example.com"               -> "o: example.com"
    # e.g. LDAP_INIT_ORG_DN="O=Example,DC=example,DC=com" -> "o: Example"
    LDAP_INIT_ORG_ATTR_O=${BASH_REMATCH[1]}
  fi
  if [[ $LDAP_INIT_ORG_DN =~ [dD][cC]=([^,]*) ]]; then
    LDAP_INIT_ORG_ATTR_DC=${BASH_REMATCH[1]}
    # derive 'o:' from LDAP_INIT_ORG_DN if LDAP_INIT_ORG_ATTR_O is unset and "DC=..." is present
    if [[ -z ${LDAP_INIT_ORG_ATTR_O:-} ]]; then
      # e.g. LDAP_INIT_ORG_DN="DC=example,DC=com" -> "o: example.com"
      LDAP_INIT_ORG_ATTR_O=$(echo "$LDAP_INIT_ORG_DN" | grep -ioP 'DC=\K[^,]+' | paste -sd '.')
    fi
    # shellcheck disable=SC2034  # LDAP_INIT_ORG_COMPUTED_ATTRS appears unused
    LDAP_INIT_ORG_COMPUTED_ATTRS="objectClass: dcObject
o: $LDAP_INIT_ORG_ATTR_O
dc: $LDAP_INIT_ORG_ATTR_DC"
  elif [[ -n ${LDAP_INIT_ORG_ATTR_O:-} ]]; then
    # shellcheck disable=SC2034  # LDAP_INIT_ORG_COMPUTED_ATTRS appears unused
    LDAP_INIT_ORG_COMPUTED_ATTRS="o: $LDAP_INIT_ORG_ATTR_O"
  else
    log ERROR "Unable to derive required 'o' attribute of objectClass 'organization' from LDAP_INIT_ORG_DN='$LDAP_INIT_ORG_DN'"
    exit 1
  fi

  ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_tree.ldif
  ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_ppolicy.ldif
  ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_entries.ldif

  log INFO "---------------------------------------"

  echo "1" >/etc/ldap/slapd.d/initialized
  rm -f /tmp/*.ldif

  log INFO "Creating LDAP backup at [$LDAP_BACKUP_FILE]..."
  slapcat -n 1 -l "$LDAP_BACKUP_FILE" || true

  /etc/init.d/slapd stop | log INFO
  sleep 3
fi

echo "$LDAP_PPOLICY_PQCHECKER_RULE" >/etc/ldap/pqchecker/pqparams.dat


#################################################################
# TLS configuration
#################################################################

case "${LDAP_TLS_ENABLED:-}" in
  true|false) ;;
  auto) [[ -f $LDAP_TLS_CERT_FILE && -f $LDAP_TLS_KEY_FILE ]] && LDAP_TLS_ENABLED=true || LDAP_TLS_ENABLED=false ;;
  *) log ERROR "LDAP_TLS_ENABLED must be auto|true|false"; exit 1 ;;
esac

SLAPD_EXTRA_URLS=""

if [[ $LDAP_TLS_ENABLED == true ]]; then
  log INFO "======================================="
  log INFO "Enabling TLS support..."
  log INFO "======================================="

  if ! [[ "$LDAP_TLS_SSF" =~ ^[0-9]+$ ]] || (( LDAP_TLS_SSF < 0 || LDAP_TLS_SSF > 256 )); then
    log ERROR "LDAP_TLS_SSF must be an integer between 0 and 256 (got '$LDAP_TLS_SSF')"
    exit 1
  fi

  case "${LDAP_LDAPS_ENABLED:-}" in
    true|false) log INFO "LDAPS enabled (port 636): $LDAP_LDAPS_ENABLED";;
    *) log ERROR "LDAP_LDAPS_ENABLED must be true|false"; exit 1 ;;
  esac

  case "${LDAP_TLS_VERIFY_CLIENT:-}" in
    never|allow|try|demand) log INFO "TLS_VERIFY_CLIENT: $LDAP_TLS_VERIFY_CLIENT";;
    *) log ERROR "LDAP_LDAPS_ENABLED must be true|false"; exit 1 ;;
  esac


  if [[ ! -f ${LDAP_TLS_KEY_FILE:-} ]]; then
    log ERROR "TLS requested but LDAP_TLS_KEY_FILE [${LDAP_TLS_KEY_FILE:-}] not accessible"
    exit 1
  fi
  if [[ ! -f ${LDAP_TLS_CERT_FILE:-} ]]; then
    log ERROR "TLS requested but LDAP_TLS_CERT_FILE [${LDAP_TLS_CERT_FILE:-}] not accessible"
    exit 1
  fi

  install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
  install -o openldap -g openldap -m 0600 "$LDAP_TLS_KEY_FILE" /etc/ldap/certs/server.key
  install -o openldap -g openldap -m 0644 "$LDAP_TLS_CERT_FILE" /etc/ldap/certs/server.crt

  if [[ -f ${LDAP_TLS_CA_FILE:-} ]]; then
    install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
    install -o openldap -g openldap -m 0644 "$LDAP_TLS_CA_FILE" /etc/ldap/certs/ca.crt
  fi

  # configure TLS key material
  cat >/tmp/tls.ldif <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/certs/server.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/certs/server.key
EOF
  if [[ -f /etc/ldap/certs/ca.crt ]]; then
    cat >>/tmp/tls.ldif <<EOF
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/certs/ca.crt
EOF
  fi

  # client-cert policy
  cat >>/tmp/tls.ldif <<EOF
-
replace: olcTLSVerifyClient
olcTLSVerifyClient: ${LDAP_TLS_VERIFY_CLIENT:-try}
EOF

  # Minimum Security Strength Factor enforcement
  if [[ $LDAP_TLS_SSF == 0 ]]; then
    cat >>/tmp/tls.ldif <<EOF
-
replace: olcSecurity
olcSecurity: ssf=$LDAP_TLS_SSF
EOF
  fi

  # ldaps:// listener
  if [[ $LDAP_LDAPS_ENABLED == true ]]; then
    SLAPD_EXTRA_URLS=" ldaps:///"
  fi

else
  log INFO "======================================="
  log INFO "Ensuring TLS support is disabled..."
  log INFO "======================================="
  cat >/tmp/tls.ldif <<EOF
dn: cn=config
changetype: modify
delete: olcTLSCertificateFile
-
delete: olcTLSCertificateKeyFile
-
delete: olcTLSCACertificateFile
-
delete: olcTLSVerifyClient
-
delete: olcSecurity
EOF

fi

# apply TLS configuration
/etc/init.d/slapd start 2>&1 | log INFO
# await ldap server start
for _ in {1..8}; do
  if ldapwhoami -H ldapi:/// | log INFO; then
    break
  fi
  sleep 1
done
if [[ ${LDAP_TLS_ENABLED} == true ]]; then
  ldif modify -Y EXTERNAL /tmp/tls.ldif
else
  ldif modify -c -Y EXTERNAL /tmp/tls.ldif || true  # ignore "ldap_modify: No such attribute (16)"
fi

rm -f /tmp/tls.ldif

/etc/init.d/slapd stop | log INFO
sleep 3

#################################################################
# Configure background task for LDAP backup
#################################################################
if [[ -n ${LDAP_BACKUP_TIME:-} ]]; then

  if [[ -z ${LDAP_BACKUP_FILE:-} ]]; then
    log ERROR "LDAP_BACKUP_FILE variable is not set!"
    exit 1
  fi

  log INFO "======================================="
  log INFO "Configuring LDAP backup task to run daily: time=[${LDAP_BACKUP_TIME}] file=[$LDAP_BACKUP_FILE]..."
  log INFO "======================================="
  if [[ ! $LDAP_BACKUP_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    log ERROR "The configured value [$LDAP_BACKUP_TIME] for LDAP_BACKUP_TIME is not in the expected 24-hour format [hh:mm]!"
    exit 1
  fi

  # testing if LDAP_BACKUP_FILE is writeable
  touch "$LDAP_BACKUP_FILE"

  function backup_ldap() {
    while true; do
      while [[ ${LDAP_BACKUP_TIME} != "$(date +%H:%M)" ]]; do
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
log INFO "***************************************"
log INFO "* Starting OpenLDAP: slapd..."
log INFO "***************************************"

# build an array of “-d <level>” for each level in LDAP_LOG_LEVELS
log_opts=()
for lvl in ${LDAP_LOG_LEVELS:-}; do
  log_opts+=("-d" "$lvl")
done

exec /usr/sbin/slapd \
  "${log_opts[@]}" \
  -h "ldap:/// ldapi:///$SLAPD_EXTRA_URLS" \
  -u openldap \
  -g openldap \
  -F /etc/ldap/slapd.d 2>&1 | log INFO
