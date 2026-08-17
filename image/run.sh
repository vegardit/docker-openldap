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
# Load entrypoint modules
#################################################################
# Keep domain implementations definition-only while run.sh owns lifecycle ordering
# around initialization, migrations, reconciliation, and the final service start.
# backup.sh provides run_as_openldap, which PPM and offline SSF reconciliation use.
# shellcheck disable=SC1091  # Not following: /opt/backup.sh is copied into the image
source /opt/backup.sh
# shellcheck disable=SC1091  # Not following: /opt/ppm.sh is copied into the image
source /opt/ppm.sh
# shellcheck disable=SC1091  # Not following: /opt/tls.sh is copied into the image
source /opt/tls.sh


# This phase mutates normalized TLS variables and the final listener selection,
# so it must remain before initialization and before the first temporary slapd.
tls_prepare || exit 1


#################################################################
# Configure LDAP server on initial container launch or after version upgrade
#################################################################
function ldif() {
  log INFO "---------------------------------------"
  local action=$1 && shift
  local file=${!#}
  log INFO "Executing [ldap$action $file]..."
  local tmpfile
  tmpfile=$(mktemp --suffix=.ldif /tmp/ldif.XXXXXX)
  (
    # Interpolated LDIFs can contain resolved passwords. Keep cleanup in an EXIT
    # trap so interpolation errors and LDAP client failures cannot leave that
    # temporary copy behind. The subshell contains the trap to this invocation.
    trap 'rm -f "$tmpfile"' EXIT
    interpolate <"$file" >"$tmpfile"
    "ldap$action" -H ldapi:/// "${@:1:${#}-1}" -f "$tmpfile" 2>&1 | log INFO
  )
}

# This helper owns only the local daemon used before the final service exec.
# Its start/stop lifecycle must not acquire the production network listeners.
function prestart_slapd() {
  local cmd="${1:-}"
  local -r RUNDIR="/run/slapd"
  # /run/slapd must remain service-writable for its socket. Keep root's default
  # log and PID state in a sibling directory the service cannot modify; explicit
  # path overrides remain trusted operator input.
  local -r INIT_STATE_DIR="/run/slapd-init"
  local -r LOGFILE="${SLAPD_LOG_FILE:-$INIT_STATE_DIR/slapd.log}"
  local -r PIDFILE="${SLAPD_INIT_PIDFILE:-$INIT_STATE_DIR/slapd.pid}"
  # Initialization and migration run before policy and TLS setup is complete.
  # Keep the temporary daemon private; only the final slapd process opens LDAP
  # and LDAPS network listeners.
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
      install -d -o root -g root -m 0700 "$INIT_STATE_DIR"

      # truncate previous log
      : > "$LOGFILE"

      # Run in foreground (because of -d ...) and capture logs; background with &
      /usr/sbin/slapd \
        "${dbg_opts[@]}" \
        -h "ldapi:///" \
        -u openldap \
        -g openldap \
        -F /etc/ldap/slapd.d \
        > "$LOGFILE" 2>&1 &
      local pid=$!
      echo "$pid" > "$PIDFILE"

      # Wait up to 10s for readiness via ldapi:///. Adding GSSAPI changes Cyrus
      # SASL's automatic mechanism selection, so pin the local peer-credential
      # mechanism: readiness must not require a Kerberos ticket or mistake failed
      # authentication for an unavailable server.
      for _ in {1..20}; do
        if ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
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

      # Wait up to 10s for it to exit (ldapi should drop when slapd is gone).
      # Use the same explicit mechanism as readiness: a failed automatic GSSAPI
      # bind while slapd is alive must not be interpreted as a stopped server.
      for _ in {1..20}; do
        if ! ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
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

function publish_config_version_marker() {
  local marker_file=$1
  local version=$2
  local temporary_file

  # The marker's parent belongs to openldap, so it cannot provide root-owned
  # integrity. Keep every filesystem open under the service identity instead of
  # letting a service-selected link cross back into the root entrypoint.
  if ! temporary_file=$(run_as_openldap mktemp -- "${marker_file}.tmp.XXXXXX"); then
    log ERROR "Cannot create a temporary configuration version marker beside [$marker_file]."
    return 1
  fi

  # A sibling temporary file guarantees a same-filesystem atomic rename. -T
  # replaces a destination symlink itself instead of following it.
  if printf '%s\n' "$version" | run_as_openldap tee -- "$temporary_file" >/dev/null &&
      run_as_openldap mv -fT -- "$temporary_file" "$marker_file"; then
    return 0
  fi

  log ERROR "Cannot publish configuration version marker [$marker_file]."
  if ! run_as_openldap rm -f -- "$temporary_file"; then
    log WARN "Cannot remove incomplete configuration version marker [$temporary_file]."
  fi
  return 1
}

initialized_file=/etc/ldap/slapd.d/initialized
config_version="2.6"
ppm_configure || exit 1

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

  # This switch controls capability discovery only. MDB ACLs must keep anonymous
  # `auth` access so slapd can verify credentials during a normal bind.
  # Default only when unset; an explicit empty value must fail validation rather
  # than silently selecting the anonymous-access policy.
  # shellcheck disable=SC2034  # Referenced in init_frontend.ldif.
  case "${LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE-true}" in
    true) LDAP_INIT_ROOT_DSE_ACCESS='by * read' ;;
    # The final deny stops unmatched anonymous requests from falling through the
    # frontend ACL chain to a later/default read rule.
    false) LDAP_INIT_ROOT_DSE_ACCESS='by users read by * none' ;;
    *) log ERROR "LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE must be true|false"; exit 1 ;;
  esac

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

  # Schemas are local cn=config state on every node, including consumers. Reject
  # a mistaken file mount before schema or LDAP changes make the volumes unsafe
  # to retry with a corrected mount.
  if [[ -e /opt/ldifs/custom-schema && ! -d /opt/ldifs/custom-schema ]]; then
    log ERROR "[/opt/ldifs/custom-schema] must be a directory"
    exit 1
  fi

  # Consumers never read custom directory data. On writers, validate its mount
  # at the same early boundary as the schema directory.
  if [[ $replication_role != consumer && -e /opt/ldifs/custom && ! -d /opt/ldifs/custom ]]; then
    log ERROR "[/opt/ldifs/custom] must be a directory"
    exit 1
  fi

  # Reserve backup intent after validation but before RFC2307bis replacement or
  # LDAP writes. A marker failure must not strand otherwise retryable volumes
  # after initialization has already made non-idempotent changes.
  mark_initial_ldap_backup_pending "$replication_role" || exit 1

  if [[ ${LDAP_INIT_RFC2307BIS_SCHEMA:-} == 1 ]]; then
    log INFO "Replacing NIS (RFC2307) schema with RFC2307bis schema..."

    log INFO "Exporting initial slapd config..."
    # cn=config can load service-controlled modules while slapcat opens it. Match
    # slapd's identity so a persisted module cannot execute inside the root entrypoint.
    initial_sldapd_config=$(run_as_openldap /usr/sbin/slapcat -n0)

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

  # A seeded or operator-provided configuration can already require more SSF than
  # ldapi's implicit allowance. Repair it while stopped; otherwise even the
  # readiness query needed to reach online initialization can be rejected.
  tls_reconcile_security || exit 1
  prestart_slapd start

  ldif add    -Y EXTERNAL /opt/ldifs/schema_sudo.ldif
  ldif add    -Y EXTERNAL /opt/ldifs/schema_ldapPublicKey.ldif

  if [[ -d /opt/ldifs/custom-schema ]]; then
    (
      # INIT_SH_FILE is sourced into this shell and may alter pathname
      # expansion. Keep the public file-selection contract stable and contain
      # these overrides in a subshell.
      unset GLOBIGNORE
      set +f
      shopt -u dotglob failglob nocaseglob
      # Keep the locale override local to this loader's bytewise glob ordering.
      # shellcheck disable=SC2030
      export LC_ALL=C
      shopt -s nullglob

      # cn=config is not replicated, so every node must install compatible
      # schemas locally before database configuration and directory data load.
      for schema_ldif in /opt/ldifs/custom-schema/*.ldif; do
        # Volume projections may expose regular files through symlinks. Accept
        # those while excluding directories and special files.
        [[ -f $schema_ldif ]] || continue
        # Mounted schema LDIFs are trusted operator configuration. Parsing them
        # would not create a security boundary because SASL EXTERNAL already has
        # authority over cn=config. ldapadd also lets slapd assign omitted {N}
        # schema indexes instead of making the image rewrite caller-owned LDIF.
        # The shared helper resolves placeholders. Keep failures fatal because
        # later schemas may depend on this one and initialization is not atomic.
        ldif add -Y EXTERNAL "$schema_ldif"
      done
    )
  fi

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

    if [[ -d /opt/ldifs/custom ]]; then
      (
        # INIT_SH_FILE is sourced into this shell and may alter pathname
        # expansion. Reset every setting that can disable the glob or widen it
        # to hidden or case-insensitive names so the documented selection stays
        # stable; the subshell keeps these overrides local to this loader.
        unset GLOBIGNORE
        set +f
        shopt -u dotglob failglob nocaseglob
        # Reset the locale locally again; no state should leak between loaders.
        # shellcheck disable=SC2031
        export LC_ALL=C
        shopt -s nullglob

        # Custom records run after image-owned data so they can refer to or
        # explicitly modify it. Consumers skip this entire branch because
        # syncrepl must remain the sole owner of their replicated suffix.
        for custom_ldif in /opt/ldifs/custom/*.ldif; do
          # Volume projections can expose regular files through symlinks; -f
          # accepts those while excluding directories and special files.
          [[ -f $custom_ldif ]] || continue
          # -a gives records without changetype add semantics while explicit
          # RFC 2849 change records retain their declared operation.
          # Do not continue after an error: later files may depend on this one,
          # and the initialized marker must remain unwritten after partial work.
          ldif modify -a -x \
            -D "$LDAP_INIT_ROOT_USER_DN" \
            -w "$LDAP_INIT_ROOT_USER_PW" \
            "$custom_ldif"
        done
      )
    fi
  fi

  log INFO "---------------------------------------"

  publish_config_version_marker "$initialized_file" "$config_version" || exit 1
  rm -f /tmp/*.ldif

  prestart_slapd stop

else
  # System is already initialized - check for migrations
  ppm_detect_migration "$initialized_file" "$config_version" || exit 1
fi

# Read the final persisted role after migrations; both initial and periodic
# backups must make decisions from the configuration slapd will actually use.
load_ldap_backup_state || exit 1
# Reclaim only previously initialized backup state. This remains best-effort so
# disabling the daily scheduler cannot make LDAP depend on its backup destination.
recover_interrupted_ldap_backup "${LDAP_BACKUP_FILE:-}"

# PPM classifies only olcDatabase={1}mdb. Reusing the broader backup flag here
# would let an unrelated custom consumer suppress updates to image-managed data.
ppm_prepare_reconciliation || exit 1

# Bootstrap inputs may be omitted after initialization, but the built-in
# consumer persists this absolute CA path in cn=config. Check it before slapd
# turns a missing runtime mount into an unrelated readiness timeout.
# Avoid grep -q here: its early exit can SIGPIPE slapcat, and pipefail would then
# hide a real match by making the condition fail.
# Inspect cn=config as the service user because its module references are also
# service-controlled and must not cross back into the root entrypoint.
if [[ ! -s /etc/ldap/certs/ca.crt ]] &&
    run_as_openldap /usr/sbin/slapcat -n 0 -o ldif-wrap=no |
      grep -F 'olcSyncrepl:' |
      grep -F 'tls_cacert=/etc/ldap/certs/ca.crt' >/dev/null; then
  log ERROR "Persisted syncrepl requires /etc/ldap/certs/ca.crt; provide LDAP_TLS_CA_FILE on every start"
  exit 1
fi

# Initial LDIFs or a persisted administrator policy may have changed update_ssf
# since the earlier preflight. Re-run the idempotent stopped-server reconciliation
# so every subsequent online write has the local strength it requires.
tls_reconcile_security || exit 1

# PPM and TLS attribute reconciliation both require the local-only pre-start
# server. Keep them in one daemon lifetime so migration never opens public LDAP.
prestart_slapd start
ppm_reconcile || exit 1

# tls_reconcile deliberately does not own slapd lifecycle; keeping this call here
# makes its ldapi-only precondition and its order after PPM visible to reviewers.
tls_reconcile || exit 1

ppm_commit_migration "$initialized_file" "$config_version" || exit 1

# The first export waits until initialization and TLS reconciliation are complete
# so it describes the same PPM and TLS state that the final server will use.
create_initial_ldap_backup

prestart_slapd stop


#################################################################
# Configure background task for LDAP backup
#################################################################
configure_ldap_backup || exit 1


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
