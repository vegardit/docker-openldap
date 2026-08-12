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
      # usermod -g requires the target group to already exist.
      log INFO "Changing GID of openldap group from $effective_gid to $LDAP_OPENLDAP_GID..."
      groupmod -o -g "$LDAP_OPENLDAP_GID" openldap
   fi
fi
chown -R openldap:openldap /etc/ldap
chown -R openldap:openldap /var/lib/ldap
chown -R openldap:openldap /var/lib/ldap_orig || true
mkdir -p /run/slapd
chown -R openldap:openldap /run/slapd

#################################################################
# Install TLS certificates if needed (must be before any slapd starts)
#################################################################
case "${LDAP_TLS_ENABLED:-}" in
  true|false) ;;
  auto) [[ -f $LDAP_TLS_CERT_FILE && -f $LDAP_TLS_KEY_FILE ]] && LDAP_TLS_ENABLED=true || LDAP_TLS_ENABLED=false ;;
  *) log ERROR "LDAP_TLS_ENABLED must be auto|true|false"; exit 1 ;;
esac

if [[ $LDAP_TLS_ENABLED == true ]]; then
  # Bash treats leading-zero arithmetic as octal and does not detect overflow.
  # Accept zero padding, but capture at most three digits after it so conversion
  # is bounded; normalize once so every later use has canonical decimal syntax.
  if ! [[ $LDAP_TLS_SSF =~ ^0*([0-9]{1,3})$ ]] ||
      (( 10#${BASH_REMATCH[1]} > 256 )); then
    log ERROR "LDAP_TLS_SSF must be an integer between 0 and 256 (got '$LDAP_TLS_SSF')"
    exit 1
  fi
  LDAP_TLS_SSF=$((10#${BASH_REMATCH[1]}))

  case "${LDAP_LDAPS_ENABLED:-}" in
    true|false) log INFO "LDAPS enabled (port 636): $LDAP_LDAPS_ENABLED";;
    *) log ERROR "LDAP_LDAPS_ENABLED must be true|false"; exit 1 ;;
  esac

  case "${LDAP_TLS_VERIFY_CLIENT:-}" in
    never|allow|try|demand) log INFO "TLS_VERIFY_CLIENT: $LDAP_TLS_VERIFY_CLIENT";;
    *) log ERROR "LDAP_TLS_VERIFY_CLIENT must be never|allow|try|demand"; exit 1 ;;
  esac

  if [[ ! -f ${LDAP_TLS_KEY_FILE:-} ]]; then
    log ERROR "TLS requested but LDAP_TLS_KEY_FILE [${LDAP_TLS_KEY_FILE:-}] not accessible"
    exit 1
  fi
  if [[ ! -f ${LDAP_TLS_CERT_FILE:-} ]]; then
    log ERROR "TLS requested but LDAP_TLS_CERT_FILE [${LDAP_TLS_CERT_FILE:-}] not accessible"
    exit 1
  fi

  log INFO "Installing TLS certificates..."
  install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
  install -o openldap -g openldap -m 0600 "$LDAP_TLS_KEY_FILE" /etc/ldap/certs/server.key
  install -o openldap -g openldap -m 0644 "$LDAP_TLS_CERT_FILE" /etc/ldap/certs/server.crt
  if [[ -f ${LDAP_TLS_CA_FILE:-} ]]; then
    install -o openldap -g openldap -m 0644 "$LDAP_TLS_CA_FILE" /etc/ldap/certs/ca.crt
  fi
fi


#################################################################
# Configure LDAP server on initial container launch or after version upgrade
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

function slapd() {
  local cmd="${1:-}"
  local -r RUNDIR="/run/slapd"
  local -r LOGFILE="${SLAPD_LOG_FILE:-/tmp/slapd.log}"
  local -r PIDFILE="${SLAPD_INIT_PIDFILE:-$RUNDIR/.init.pid}"
  local -r URLS="ldap:/// ldapi:///${SLAPD_EXTRA_URLS:-}"
  local -a dbg_opts=()

  # Debug levels for init runs (independent from final exec)
  # e.g. export SLAPD_INIT_LOG_LEVELS="stats config sync"
  for lvl in ${SLAPD_INIT_LOG_LEVELS:-stats config}; do
    dbg_opts+=(-d "$lvl")
  done

  case "$cmd" in
    start)
      log INFO "Starting slapd for init/migration..."
      mkdir -p "$RUNDIR"
      chown openldap:openldap "$RUNDIR"
      chmod 770 "$RUNDIR"

      # truncate previous log
      : > "$LOGFILE"

      # Run in foreground (because of -d ...) and capture logs; background with &
      /usr/sbin/slapd \
        "${dbg_opts[@]}" \
        -h "$URLS" \
        -u openldap \
        -g openldap \
        -F /etc/ldap/slapd.d \
        > "$LOGFILE" 2>&1 &
      local pid=$!
      echo "$pid" > "$PIDFILE"

      # Wait up to 10s for readiness via ldapi:///
      for _ in {1..20}; do
        if ldapwhoami -H ldapi:/// >/dev/null 2>&1; then
          log INFO "slapd started (pid $pid)"
          return 0
        fi
        sleep 0.5
      done

      log ERROR "Timeout waiting for slapd to become ready"
      # Show immediate diagnostics
      tail -n 80 "$LOGFILE" | log ERROR
      return 1
      ;;

    stop)
      log INFO "Stopping slapd..."
      local pid=""
      if [[ -r "$PIDFILE" ]]; then
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
      fi

      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      else
        # Fallback: scan /proc for a foreground slapd we started
        for p in /proc/[0-9]*; do
          if [[ -r "$p/comm" ]] && [[ "$(cat "$p/comm")" == "slapd" ]]; then
            pid="${p##*/}"
            kill "$pid" 2>/dev/null || true
          fi
        done
      fi

      # Wait up to 10s for it to exit (ldapi should drop when slapd is gone)
      for _ in {1..20}; do
        if ! ldapwhoami -H ldapi:/// >/dev/null 2>&1; then
          log INFO "slapd stopped"
          rm -f "$PIDFILE"
          return 0
        fi
        sleep 0.5
      done

      log WARN "Graceful stop timed out — dumping last log lines before forcing kill:"
      tail -n 120 "$LOGFILE" | log WARN

      # Force kill any remaining slapd processes
      for p in /proc/[0-9]*; do
        if [[ -r "$p/comm" ]] && [[ "$(cat "$p/comm")" == "slapd" ]]; then
          kill -9 "${p##*/}" 2>/dev/null || true
        fi
      done
      rm -f "$PIDFILE"
      log INFO "slapd forced to stop"
      ;;

    *)
      log ERROR "Usage: slapd {start|stop}"
      return 2
      ;;
  esac
}

initialized_file=/etc/ldap/slapd.d/initialized
config_version="2.6"
if [ ! -e "$initialized_file" ]; then
  log BOX "Applying initial configuration..."
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

  # ext filesystems create lost+found at the root of a fresh volume. It is
  # filesystem metadata, so ignore only that directory when deciding to seed.
  for folder in "/var/lib/ldap" "/etc/ldap/slapd.d"; do
    if [[ $folder -ef "${folder}_orig" ]]; then
      continue
    fi
    if [[ -z $(find "$folder" -mindepth 1 -maxdepth 1 ! \( -type d -name lost+found \) -print -quit) ]]; then
      log INFO "Initializing [$folder]..."
      cp -r --preserve=all ${folder}_orig/. $folder
    fi
  done

  # Report a broken or skipped config seed directly; otherwise slapd exposes it
  # only as an opaque readiness timeout several steps later.
  if [[ ! -f /etc/ldap/slapd.d/cn=config.ldif ]]; then
    log ERROR "Cannot initialize: [/etc/ldap/slapd.d/cn=config.ldif] is missing after configuration seeding."
    exit 1
  fi

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

  if [[ -z ${LDAP_INIT_ORG_DN:-} ]]; then
    log ERROR "LDAP_INIT_ORG_DN variable is not set!"
    exit 1
  fi

  # Validate derived organization attributes before non-idempotent schema and
  # LDAP changes so a bad DN leaves initialization retryable.
  if [[ -z ${LDAP_INIT_ORG_ATTR_O:-} ]] && [[ $LDAP_INIT_ORG_DN =~ [oO]=([^,]*) ]]; then
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
    # shellcheck disable=SC2034  # Referenced in /opt/ldifs/init_org_tree.ldif.
    LDAP_INIT_ORG_COMPUTED_ATTRS="objectClass: dcObject
o: $LDAP_INIT_ORG_ATTR_O
dc: $LDAP_INIT_ORG_ATTR_DC"
  elif [[ -n ${LDAP_INIT_ORG_ATTR_O:-} ]]; then
    # shellcheck disable=SC2034  # Referenced in /opt/ldifs/init_org_tree.ldif.
    LDAP_INIT_ORG_COMPUTED_ATTRS="o: $LDAP_INIT_ORG_ATTR_O"
  else
    log ERROR "Unable to derive required 'o' attribute of objectClass 'organization' from LDAP_INIT_ORG_DN='$LDAP_INIT_ORG_DN'"
    exit 1
  fi

  replication_role=${LDAP_INIT_REPLICATION_ROLE:-}
  case "$replication_role" in
    '')
      if [[ -n ${LDAP_INIT_REPLICATION_PROVIDER_URI:-} || -n ${LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE:-} ]]; then
        log ERROR "LDAP_INIT_REPLICATION_ROLE must be set when replication options are configured"
        exit 1
      fi
      ;;
    provider|consumer)
      # Replication settings are initialization inputs. Keeping this validation
      # inside the first-run block lets an initialized node restart without the
      # secret file, while its persisted cn=config remains authoritative.
      if [[ $LDAP_TLS_ENABLED != true ]]; then
        log ERROR "Replication requires TLS certificate and key files"
        exit 1
      fi
      # Consumers need this CA to authenticate their provider. A provider only
      # needs it when its incoming TLS policy verifies client certificates.
      if [[ ! -s /etc/ldap/certs/ca.crt &&
            ( $replication_role == consumer || $LDAP_TLS_VERIFY_CLIENT != never ) ]]; then
        log ERROR "Replication requires an accessible LDAP_TLS_CA_FILE unless a provider sets LDAP_TLS_VERIFY_CLIENT=never"
        exit 1
      fi
      if [[ $replication_role == provider && $LDAP_LDAPS_ENABLED != true ]]; then
        log ERROR "A replication provider requires LDAP_LDAPS_ENABLED=true"
        exit 1
      fi
      if [[ $replication_role == provider && -n ${LDAP_INIT_REPLICATION_PROVIDER_URI:-} ]]; then
        log ERROR "LDAP_INIT_REPLICATION_PROVIDER_URI is only valid for a replication consumer"
        exit 1
      fi
      if [[ $replication_role == consumer ]]; then
        replication_provider_uri=${LDAP_INIT_REPLICATION_PROVIDER_URI:-}
        # Syncrepl uses simple bind. Restricting this bootstrap API to implicit
        # TLS ensures transport encryption is active before authentication.
        if [[ $replication_provider_uri != ldaps://?* || $replication_provider_uri == *[[:space:]]* ||
              $replication_provider_uri == *\"* || $replication_provider_uri == *\\* ]]; then
          log ERROR "LDAP_INIT_REPLICATION_PROVIDER_URI must be a single ldaps:// URI without whitespace, quotes, or backslashes"
          exit 1
        fi
      fi
      # Compose mounts a secret with this name at the conventional path. Resolve
      # the fallback only after a role is selected so it cannot enable or reject
      # replication on an otherwise ordinary server.
      replication_bind_password_file=${LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE:-/run/secrets/ldap-replication-password}
      if [[ ! -r $replication_bind_password_file ]]; then
        log ERROR "LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE [$replication_bind_password_file] must name a readable secret file"
        exit 1
      fi

      LDAP_INIT_REPLICATION_BIND_PASSWORD=$(<"$replication_bind_password_file")
      # Command substitution strips the LF from a Docker secret but leaves the
      # CR from a Windows CRLF terminator. Remove only that trailing CR; the
      # validation below still rejects embedded line breaks.
      LDAP_INIT_REPLICATION_BIND_PASSWORD=${LDAP_INIT_REPLICATION_BIND_PASSWORD%$'\r'}
      if [[ -z $LDAP_INIT_REPLICATION_BIND_PASSWORD ]]; then
        log ERROR "LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE must not be empty"
        exit 1
      fi
      # The consumer credential is persisted inside a quoted olcSyncrepl value.
      # Reject only characters that could escape that field or split the LDIF;
      # ordinary spaces and punctuation remain valid password characters.
      if [[ $LDAP_INIT_REPLICATION_BIND_PASSWORD == *$'\n'* ||
            $LDAP_INIT_REPLICATION_BIND_PASSWORD == *$'\r'* ||
            $LDAP_INIT_REPLICATION_BIND_PASSWORD == *\"* ||
            $LDAP_INIT_REPLICATION_BIND_PASSWORD == *\\* ]]; then
        log ERROR "The replication bind password must not contain line breaks, quotes, or backslashes"
        exit 1
      fi

      # These derived values are private template inputs; the public API keeps
      # the replication identity fixed so two nodes cannot silently disagree.
      # shellcheck disable=SC2034  # Referenced in replication LDIF templates.
      LDAP_INIT_REPLICATION_BIND_DN="uid=replicator,$LDAP_INIT_ORG_DN"
      if [[ $replication_role == provider ]]; then
        # Bash treats trailing newlines as file terminators when it reads the
        # secret above. Hash that normalized value too, and use stdin so the
        # plaintext password does not appear in the slappasswd process arguments.
        # shellcheck disable=SC2034  # Referenced in the provider account LDIF.
        LDAP_INIT_REPLICATION_BIND_PASSWORD_HASHED=$(printf '%s' "$LDAP_INIT_REPLICATION_BIND_PASSWORD" | slappasswd -T /dev/stdin)
      fi
      ;;
    *)
      log ERROR "LDAP_INIT_REPLICATION_ROLE must be provider|consumer"
      exit 1
      ;;
  esac

  if [[ ${LDAP_INIT_RFC2307BIS_SCHEMA:-} == 1 ]]; then
    log INFO "Replacing NIS (RFC2307) schema with RFC2307bis schema..."

    log INFO "Exporting initial slapd config..."
    initial_sldapd_config=$(slapcat -n0)

    log INFO "Delete initial slapd config..."
    find /etc/ldap/slapd.d/ -type f -delete

    log INFO "Create modified sldapd config..."
    # Build the LDIF in memory before slapadd starts: this removes the fixed /tmp
    # path and avoids Bash hiding a failed transform in a live pipeline.
    config_ldif=$(
       # Command substitutions clear errexit by default.
       set -e
       # Preserve the persisted schema indexes around the replaced {2} record.
       echo "${initial_sldapd_config%%dn: cn=\{2\}nis,cn=schema,cn=config*}"
       sed 's/rfc2307bis/{2}rfc2307bis/g' /opt/ldifs/schema_rfc2307bis02.ldif
       # End the replacement record before appending the retained suffix.
       echo
       echo "dn: cn={3}inetorgperson,cn=schema,cn=config${initial_sldapd_config#*dn: cn=\{3\}inetorgperson,cn=schema,cn=config}"
    )

    log INFO "Register modified slapd config with RFC2307bis schema..."
    # Command substitution strips trailing newlines; restore one for LDIF.
    printf '%s\n' "$config_ldif" |
       slapadd -F /etc/ldap/slapd.d -n 0 | log INFO
    chown openldap:openldap -R /etc/ldap/slapd.d
  fi

  slapd start

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

  if [[ $replication_role == provider ]]; then
    ldif add -Y EXTERNAL /opt/ldifs/init_replication_provider_config.ldif
  fi

  if [[ $replication_role == consumer ]]; then
    # A consumer must let syncrepl create the suffix and all children. Loading
    # the image's sample tree first would make the initial refresh collide with
    # entries that have the same DNs but no replication metadata.
    ldif modify -Y EXTERNAL /opt/ldifs/init_replication_consumer.ldif
  else
    ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_tree.ldif
    ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_ppolicy.ldif
    ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_org_entries.ldif
    if [[ $replication_role == provider ]]; then
      ldif add -x -D "$LDAP_INIT_ROOT_USER_DN" -w "$LDAP_INIT_ROOT_USER_PW" /opt/ldifs/init_replication_provider_account.ldif
    fi
  fi

  log INFO "---------------------------------------"

  echo "$config_version" >"$initialized_file"
  rm -f /tmp/*.ldif

  # Syncrepl starts asynchronously when the consumer config is committed, so
  # this point cannot guarantee a complete replica. Let scheduled backups run
  # after startup instead of publishing an empty or partial initial export.
  if [[ $replication_role != consumer ]]; then
    log INFO "Creating LDAP backup at [$LDAP_BACKUP_FILE]..."
    slapcat -n 1 -l "$LDAP_BACKUP_FILE" || true
  fi

  slapd stop

else
  # System is already initialized - check for migrations
  last_version=$(cat "$initialized_file")

  # Handle legacy format (just "1" means pre-versioning, treat as 2.5)
  if [[ "$last_version" == "1" ]]; then
    last_version="2.5"
  fi

  # Check if we need to migrate from 2.5 to 2.6
  if [[ "$last_version" == "2.5" ]]; then
    log BOX "Migrating config to OpenLDAP 2.6..."

    slapd start

    # Find the actual ppolicy overlay DN (it might have an index like {0}ppolicy)
    ppolicy_dn=$(ldapsearch -H ldapi:/// -Y EXTERNAL -b "olcDatabase={1}mdb,cn=config" "(objectClass=olcPPolicyConfig)" dn 2>/dev/null | grep "^dn:" | head -1 | sed 's/^dn: //')

    if [[ -z "$ppolicy_dn" ]]; then
      log WARN "ppolicy overlay not found in configuration, skipping password policy migration"
    else
      log INFO "Found ppolicy overlay at: $ppolicy_dn"

      # Check if ppolicy overlay already has the new configuration
      if ldapsearch -H ldapi:/// -Y EXTERNAL -b "$ppolicy_dn" -s base "(objectClass=*)" olcPPolicyCheckModule 2>/dev/null | grep -q "olcPPolicyCheckModule"; then
        log INFO "Password policy overlay already configured for 2.6, skipping migration"
      else
        # Check for legacy pwdCheckModule entries
        has_legacy_config=false
        if ldapsearch -H ldapi:/// -Y EXTERNAL -b "${LDAP_INIT_ORG_DN:-DC=example,DC=com}" "(pwdCheckModule=*)" pwdCheckModule 2>/dev/null | grep -q "pwdCheckModule"; then
          has_legacy_config=true
          log INFO "Found legacy pwdCheckModule configuration in password policy entries"
        fi

        # Add new overlay configuration
        log INFO "Adding OpenLDAP 2.6 password policy overlay configuration..."
        # This generated LDIF is consumed once. Stdin avoids giving root a fixed
        # pathname in /tmp that the openldap account can replace between starts.
        if {
          cat <<EOF
dn: $ppolicy_dn
changetype: modify
add: olcPPolicyCheckModule
olcPPolicyCheckModule: /usr/lib/ldap/pqchecker.so
EOF
        } | ldapmodify -H ldapi:/// -Y EXTERNAL 2>&1 | log INFO; then
          log INFO "Successfully migrated password policy overlay configuration"
          if [[ $has_legacy_config == true ]]; then
            log WARN "Legacy pwdCheckModule entries found in password policy entries."
            log WARN "These are now ignored in OpenLDAP 2.6 and can be removed manually if desired."
            log WARN "The password checking functionality is now handled by the overlay configuration."
          fi
        else
          log ERROR "Failed to apply password policy overlay migration"
          exit 1
        fi
      fi
    fi

    # Update version in initialized file
    echo "$config_version" > "$initialized_file"

    # Stop LDAP server after migrations
    slapd stop

    log INFO "Configuration migration completed"
  elif [[ "$last_version" != "$config_version" ]]; then
    log WARN "Unknown configuration version: $last_version (expected: $config_version)"
    log WARN "Skipping migrations - manual intervention may be required"
  else
    log INFO "Configuration is up to date (version: $config_version)"
  fi
fi

# Bootstrap variables disappear on normal restarts, so persisted olcSyncrepl is
# the authoritative indication that this database still has a consumer engine.
# Avoid grep -q: its early exit can SIGPIPE slapcat, and pipefail would then hide
# a real match by making the condition fail.
is_syncrepl_consumer=false
if slapcat -n 0 -o ldif-wrap=no | grep -F 'olcSyncrepl:' >/dev/null; then
  is_syncrepl_consumer=true
fi

# Bootstrap inputs may be omitted after initialization, but the built-in
# consumer persists this absolute CA path in cn=config. Check it before slapd
# turns a missing runtime mount into an unrelated readiness timeout.
# Avoid grep -q here: its early exit can SIGPIPE slapcat, and pipefail would then
# hide a real match by making the condition fail.
if [[ ! -s /etc/ldap/certs/ca.crt ]] &&
    slapcat -n 0 -o ldif-wrap=no |
      grep -F 'olcSyncrepl:' |
      grep -F 'tls_cacert=/etc/ldap/certs/ca.crt' >/dev/null; then
  log ERROR "Persisted syncrepl requires /etc/ldap/certs/ca.crt; provide LDAP_TLS_CA_FILE on every start"
  exit 1
fi

echo "$LDAP_PPOLICY_PQCHECKER_RULE" >/etc/ldap/pqchecker/pqparams.dat


#################################################################
# TLS configuration
#################################################################
SLAPD_EXTRA_URLS=""

if [[ $LDAP_TLS_ENABLED == true ]]; then
  log BOX "Enabling TLS support..."

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
  log BOX "Ensuring TLS support is disabled..."
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
slapd start
if [[ ${LDAP_TLS_ENABLED} == true ]]; then
  ldif modify -Y EXTERNAL /tmp/tls.ldif
else
  ldif modify -c -Y EXTERNAL /tmp/tls.ldif || true  # ignore "ldap_modify: No such attribute (16)"
fi

rm -f /tmp/tls.ldif

slapd stop


#################################################################
# Configure background task for LDAP backup
#################################################################
if [[ -n ${LDAP_BACKUP_TIME:-} ]]; then

  if [[ -z ${LDAP_BACKUP_FILE:-} ]]; then
    log ERROR "LDAP_BACKUP_FILE variable is not set!"
    exit 1
  fi

  log BOX "Configuring LDAP backup task to run daily: time=[${LDAP_BACKUP_TIME}] file=[$LDAP_BACKUP_FILE]..."
  if [[ ! $LDAP_BACKUP_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    log ERROR "The configured value [$LDAP_BACKUP_TIME] for LDAP_BACKUP_TIME is not in the expected 24-hour format [hh:mm]!"
    exit 1
  fi

  # Using the destination itself as the writeability probe would publish an
  # empty file before a new consumer has received its first replicated entry.
  # A temporary sibling exercises the same directory without resembling a backup.
  if [[ -e $LDAP_BACKUP_FILE || -L $LDAP_BACKUP_FILE ]]; then
    touch "$LDAP_BACKUP_FILE"
  else
    backup_write_probe=$(mktemp "$(dirname -- "$LDAP_BACKUP_FILE")/.ldap-backup-write-test.XXXXXX")
    rm -f "$backup_write_probe"
  fi

  function backup_ldap() {
    if [[ $is_syncrepl_consumer == true ]]; then
      log INFO "Waiting for the initial syncrepl refresh before enabling periodic LDAP backups..."
      # The worker starts immediately before the final slapd process. Wait for
      # its local socket so startup connection failures are not mistaken for an
      # incomplete syncrepl refresh.
      while ! ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; do
        sleep 1s
      done

      local backup_suffix
      local backup_suffix_ldif
      # Bootstrap variables may be omitted or changed on a normal restart, so
      # use the suffix that is authoritative in the persisted configuration.
      if ! backup_suffix_ldif=$(
        ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
          -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcSuffix |
          sed -n '/^olcSuffix: /p; /^olcSuffix:: /p'
      ); then
        log ERROR "Cannot determine the persisted MDB suffix required to verify the initial syncrepl refresh."
        return 1
      fi
      case "$backup_suffix_ldif" in
        'olcSuffix: '*) backup_suffix=${backup_suffix_ldif#olcSuffix: } ;;
        'olcSuffix:: '*)
          # LDIF base64-encodes values that are not safe ASCII. Decode that
          # representation so non-ASCII organization DNs remain valid search bases.
          if ! backup_suffix=$(printf '%s' "${backup_suffix_ldif#olcSuffix:: }" | base64 -d); then
            log ERROR "Cannot decode the persisted MDB suffix required to verify the initial syncrepl refresh."
            return 1
          fi
          ;;
        *)
          log ERROR "Cannot determine the persisted MDB suffix required to verify the initial syncrepl refresh."
          return 1
          ;;
      esac

      # Initial-refresh entries carry no synchronization cookie. OpenLDAP writes
      # contextCSN after the refresh completes, so its presence distinguishes a
      # coherent replica from an empty or partially populated database. Query
      # only the suffix entry; repeatedly exporting the database makes startup
      # cost grow with the number of entries already received.
      while true; do
        local refresh_state
        local refresh_status
        if refresh_state=$(
          ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
            -b "$backup_suffix" -s base '(contextCSN=*)' contextCSN 2>&1
        ); then
          if [[ $refresh_state == contextCSN:\ * || $refresh_state == *$'\ncontextCSN: '* ]]; then
            break
          fi
        else
          refresh_status=$?
          # LDAP result 32 means that syncrepl has not created the suffix entry
          # yet. Other errors are configuration failures, not a reason to wait
          # forever while silently disabling backups.
          if (( refresh_status != 32 )); then
            log ERROR "Cannot query syncrepl refresh state for [$backup_suffix]: $refresh_state"
            return 1
          fi
        fi
        sleep 10s
      done
      log INFO "Initial syncrepl refresh completed; enabling periodic LDAP backups."
    fi

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
log BOX "Starting OpenLDAP: slapd..."

# build an array of "-d <level>" for each level in LDAP_LOG_LEVELS
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
