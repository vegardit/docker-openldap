#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# run.sh sources this file after config-migration.sh. It only defines functions;
# run.sh decides when to call them and starts or stops the temporary slapd process.
# The caller provides `log` and `run_as_openldap`; config-migration.sh provides the
# shared version-marker helpers used by the PPM migration lifecycle.
#
# Intended order:
#   ppm_configure
#   ppm_detect_migration                  # persisted configuration only
#   ppm_prepare_reconciliation
#   ppm_reconcile                         # temporary ldapi slapd is running
#   ppm_commit_migration                  # surrounding configuration succeeded

function ppm_export_config() {
  # cn=config can load service-controlled modules while slapcat opens it. Inspect
  # it with the same identity as slapd so a persisted module never crosses back
  # into the root entrypoint's privilege boundary.
  run_as_openldap /usr/sbin/slapcat -n 0 -o ldif-wrap=no
}

function ppm_require_configured() {
  if [[ ${ppm_configured:-false} != true ]]; then
    log ERROR "ppm_configure must run before other PPM lifecycle functions."
    return 1
  fi
}

function ppm_pqchecker_rule_to_config() {
  local rule=$1
  local upper lower digit special forbidden
  # PPM needs an explicit class alphabet. Printable ASCII punctuation keeps the
  # legacy special-character rule independent of the container locale.
  local special_chars="!\"#\$%&'()*+,-./:;<=>?@[\\]^_\`{|}~"

  # pqChecker's broadcast mode has no PPM equivalent and must not be silently
  # weakened to a local-only check.
  if [[ $rule == 1\|* ]]; then
    return 1
  fi
  rule=${rule#0|}
  if [[ ! $rule =~ ^([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([^[:space:]]*)$ ]]; then
    return 1
  fi

  upper=$((10#${BASH_REMATCH[1]}))
  lower=$((10#${BASH_REMATCH[2]}))
  digit=$((10#${BASH_REMATCH[3]}))
  special=$((10#${BASH_REMATCH[4]}))
  forbidden=${BASH_REMATCH[5]}

  # pqChecker's minimum counts are mandatory. Disable PPM's separate quality-point
  # check so it does not require more than the translated class counts.
  printf 'minQuality 0\n'
  printf 'class-upperCase %s %d 0 0\n' ABCDEFGHIJKLMNOPQRSTUVWXYZ "$upper"
  printf 'class-lowerCase %s %d 0 0\n' abcdefghijklmnopqrstuvwxyz "$lower"
  printf 'class-digit %s %d 0 0\n' 0123456789 "$digit"
  printf 'class-special %s %d 0 0\n' "$special_chars" "$special"
  if [[ -n $forbidden ]]; then
    printf 'forbiddenChars %s\n' "$forbidden"
  fi
}

function ppm_prepare_policy_changes() {
  local ppm_arg_base64=$1
  local ppm_arg_plain=$2
  local replace_existing=$3

  # The caller searches only pwdPolicyChecker entries, so normal starts do not
  # read the whole directory. Keep each DN as ldapsearch encoded it so change
  # records also work with non-ASCII DNs.
  # Pass plain text through the environment because awk -v interprets backslash
  # escapes, while native PPM configuration must be compared byte-for-byte.
  PPM_ARG_PLAIN=$ppm_arg_plain awk \
    -v ppm_arg_base64="$ppm_arg_base64" \
    -v replace_existing="$replace_existing" '
      BEGIN { RS = ""; FS = "\n"; ORS = ""; ppm_arg_plain = ENVIRON["PPM_ARG_PLAIN"] }
      {
        dn = ""
        is_policy = 0
        has_use = 0
        has_arg = 0
        arg_matches = 0
        for (i = 1; i <= NF; i++) {
          line = tolower($i)
          if (line ~ /^dn::? /) dn = $i
          if (line == "objectclass: pwdpolicychecker") is_policy = 1
          if (line ~ /^pwdusecheckmodule: /) has_use = 1
          # Empty octet strings are valid LDIF and have no space after the
          # delimiter. This attribute is SINGLE-VALUE, so an existing empty value
          # must use replace; migrations that only fill missing attributes must
          # leave it unchanged.
          if (line ~ /^pwdcheckmodulearg::( |$)/) {
            has_arg = 1
            arg_value = substr($i, index($i, "::") + 2)
            sub(/^ +/, "", arg_value)
            if (arg_value == ppm_arg_base64) arg_matches = 1
          } else if (line ~ /^pwdcheckmodulearg:( |$)/) {
            has_arg = 1
            # ldapsearch can emit safe single-line binary values without base64.
            # Treat this form as equal too, so matching values are not rewritten.
            arg_value = substr($i, index($i, ":") + 1)
            sub(/^ +/, "", arg_value)
            if (arg_value == ppm_arg_plain) arg_matches = 1
          }
        }

        change_use = is_policy && !has_use
        change_arg = is_policy && (!has_arg || (replace_existing == "true" && !arg_matches))
        if (dn == "" || (!change_use && !change_arg)) next

        print dn "\nchangetype: modify\n"
        # Check only whether the attribute exists. An explicit FALSE disables PPM
        # for this policy and must remain unchanged.
        if (change_use) print "add: pwdUseCheckModule\npwdUseCheckModule: TRUE\n"
        if (change_use && change_arg) print "-\n"
        if (change_arg) {
          # Normal starts replace an existing value when it differs. During
          # migration from an empty legacy rule, this branch is reached only when
          # the native PPM argument is missing.
          if (has_arg) print "replace: pwdCheckModuleArg\n"
          else print "add: pwdCheckModuleArg\n"
          print "pwdCheckModuleArg:: " ppm_arg_base64 "\n"
        }
        print "\n"
      }
    '
}

function ppm_ldapmodify_logged() {
  local status

  # ldapmodify can print one result per policy. Stream those lines so a large
  # reconciliation does not duplicate the full client output in a Bash variable.
  # The identical branches are intentional: using the pipeline as an if condition
  # prevents errexit from skipping PIPESTATUS, regardless of the caller's pipefail
  # setting. Only the LDAP client's status controls success, as before.
  if ldapmodify -Q -Y EXTERNAL -H ldapi:/// 2>&1 | log INFO; then
    status=${PIPESTATUS[0]}
  else
    status=${PIPESTATUS[0]}
  fi
  return "$status"
}

function ppm_normalize_ordered_config_value() {
  local value=$1
  local -a fields=()

  if [[ $value =~ ^\{[0-9]+\}(.*)$ ]]; then
    value=${BASH_REMATCH[1]}
  fi

  # OpenLDAP rewrites ordered configuration values when it stores them: it adds
  # {N} indexes and may insert extra spaces. These image-owned rules contain no
  # whitespace inside quoted data, so folding whitespace changes only formatting.
  # Callers still compare the complete value, so a similar but weaker user rule
  # cannot match.
  read -r -a fields <<<"$value"
  printf '%s\n' "${fields[*]}"
}

function ppm_config_has_value() {
  local config=$1
  local attribute=$2
  local expected=$3
  local expected_index=${4:-}
  local index
  local line
  local value

  while IFS= read -r line; do
    [[ $line == "$attribute: "* ]] || continue
    value=${line#"$attribute: "}
    if [[ $value =~ ^\{([0-9]+)\}(.*)$ ]]; then
      index=${BASH_REMATCH[1]}
    else
      index=""
    fi
    # Limits need only semantic equality. ACL callers also provide the required
    # ordinal because an identical rule behind a terminating ACL is ineffective.
    [[ -z $expected_index || $index == "$expected_index" ]] || continue
    if [[ $(ppm_normalize_ordered_config_value "$value") == "$expected" ]]; then
      return 0
    fi
  done <<<"$config"

  return 1
}

function ppm_prepend_access_rule() {
  local config=$1
  local expected=$2
  local line
  local match_count=0
  local stored_value=""
  local value

  while IFS= read -r line; do
    [[ $line == 'olcAccess: '* ]] || continue
    value=${line#'olcAccess: '}
    if [[ $(ppm_normalize_ordered_config_value "$value") == "$expected" ]]; then
      stored_value=$value
      ((match_count += 1))
    fi
  done <<<"$config"

  if ((match_count > 1)); then
    # Identical operator and image rules have no ownership marker. Refuse an
    # ambiguous cleanup instead of guessing which duplicate may be removed.
    log ERROR "Multiple matching Debian PPM maintenance ACLs were found; remove duplicates before restarting."
    return 1
  fi
  [[ $stored_value == \{0\}* ]] && return 0

  # An exact operator-supplied rule is semantically equivalent to the image rule,
  # but it is unusable behind a catch-all ACL. Move only that exact value; all
  # unrelated rules retain their relative order. Delete and add belong to one LDAP
  # Modify request so a failed move cannot leave the permission absent.
  if ! {
    cat <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
EOF
    if [[ -n $stored_value ]]; then
      printf 'delete: olcAccess\nolcAccess: %s\n-\n' "$stored_value"
    fi
    cat <<EOF
add: olcAccess
olcAccess: {0}$expected
EOF
  } | ppm_ldapmodify_logged; then
    log ERROR "Cannot place the local Debian PPM maintenance ACL before custom ACLs."
    return 1
  fi
}

function ppm_cleanup_owned_limit() {
  local marker=$1
  local expected=$2
  local limits_config
  local limit_line
  local limit_value=""
  local normalized
  local match_count=0

  [[ -e $marker || -L $marker ]] || return 0
  # Keep the ownership marker beside cn=config because it authorizes deleting an
  # olcLimits value. mkdir and rmdir do not follow a directory symlink; an
  # unexpected marker type is not trusted as permission to change cn=config.
  if [[ -L $marker || ! -d $marker ]]; then
    log ERROR "Temporary PPM limit marker [$marker] is not a directory."
    return 1
  fi

  if ! limits_config=$(ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcLimits); then
    log ERROR "Cannot inspect MDB limits while cleaning up Debian PPM reconciliation."
    return 1
  fi

  # The marker records that this image created one exact rule. If more than one
  # match exists, we cannot know which copy belongs to the operator, so stop.
  while IFS= read -r limit_line; do
    [[ $limit_line == 'olcLimits: '* ]] || continue
    normalized=$(ppm_normalize_ordered_config_value "${limit_line#olcLimits: }")
    [[ $normalized == "$expected" ]] || continue
    match_count=$((match_count + 1))
    limit_value=${limit_line#olcLimits: }
  done <<<"$limits_config"
  if ((match_count > 1)); then
    log ERROR "Multiple limits match the image-owned temporary PPM rule; refusing automatic cleanup."
    return 1
  fi

  if [[ -n $limit_value ]]; then
    # Delete OpenLDAP's exact stored value, including its current {N} index. Other
    # ordered limits may have shifted that index since the interrupted start.
    if ! {
      cat <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
delete: olcLimits
olcLimits: $limit_value
EOF
    } | ppm_ldapmodify_logged; then
      log ERROR "Cannot remove the temporary local limit used for Debian PPM reconciliation."
      return 1
    fi
  fi

  # Remove the ownership marker only after cn=config no longer contains the rule.
  # If this fails, the next start checks again before doing any policy work.
  if ! rmdir -- "$marker"; then
    log ERROR "Cannot remove temporary PPM limit marker [$marker]."
    return 1
  fi
}

function ppm_reconcile_policy_entries() (
  local database_suffix=$1
  local mdb_config=$2
  local ppm_limits=$3
  local ppm_limits_marker=$4
  local ppm_spool_directory=/var/tmp/docker-openldap-ppm
  local ppm_policy_entries_file="$ppm_spool_directory/policy-entries.ldif"
  local ppm_policy_changes_file="$ppm_spool_directory/policy-changes.ldif"
  local ppm_spool_state
  local ppm_search_status=0

  # This helper deliberately runs in a subshell. Its EXIT trap then cleans only
  # these spool files without replacing a trap owned by run.sh. The entrypoint
  # serializes reconciliation, so fixed names are safe and make crash recovery
  # unambiguous. A hard kill can still bypass EXIT, so the files are also removed
  # before the next run.
  if [[ -L $ppm_spool_directory ||
        ( -e $ppm_spool_directory && ! -d $ppm_spool_directory ) ]]; then
    log ERROR "Debian PPM spool path [$ppm_spool_directory] is not a directory."
    return 1
  fi
  if [[ ! -d $ppm_spool_directory ]] &&
      ! mkdir -m 700 -- "$ppm_spool_directory"; then
    log ERROR "Cannot create Debian PPM spool directory [$ppm_spool_directory]."
    return 1
  fi
  if ! ppm_spool_state=$(stat -c '%u:%g:%a' -- "$ppm_spool_directory") ||
      [[ $ppm_spool_state != 0:0:700 ]]; then
    # Root writes fixed filenames below this directory. Refuse a writable or
    # service-owned directory rather than following a replacement supplied by slapd.
    log ERROR "Debian PPM spool directory [$ppm_spool_directory] must be root-owned with mode 700."
    return 1
  fi
  if ! rm -f -- "$ppm_policy_entries_file" "$ppm_policy_changes_file"; then
    log ERROR "Cannot clean stale Debian PPM spool files."
    return 1
  fi

  umask 077
  if ! : >"$ppm_policy_entries_file" || ! : >"$ppm_policy_changes_file"; then
    log ERROR "Cannot create Debian PPM spool files."
    return 1
  fi
  trap 'if ! rm -f -- "$ppm_policy_entries_file" "$ppm_policy_changes_file"; then
          log WARN "Cannot remove Debian PPM spool files."
        fi' EXIT

  # Spool the complete search before preparing any writes. Redirecting directly
  # into ldapmodify would apply a prefix of the directory if ldapsearch later
  # reports a size, time, or transport failure.
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b "$database_suffix" -s sub '(objectClass=pwdPolicyChecker)' \
      objectClass pwdUseCheckModule pwdCheckModuleArg \
      >"$ppm_policy_entries_file" || ppm_search_status=$?

  if ((ppm_search_status == 3 || ppm_search_status == 4)); then
    # Most directories fit under their normal limits, so avoid two persistent
    # cn=config writes on every restart. Retry only for LDAP timeLimitExceeded
    # or sizeLimitExceeded; the second redirection discards the partial first LDIF.
    if ppm_config_has_value "$mdb_config" olcLimits "$ppm_limits"; then
      # The matching rule belongs to the operator because no ownership marker
      # exists. If it did not make this search unlimited, adding a duplicate at
      # {0} would create state that cleanup could not safely distinguish.
      log ERROR "Password policy search exceeded a limit although an identical operator-owned olcLimits rule already exists."
      return 1
    fi

    # Record ownership beside cn=config before changing it. A crash after either
    # step leaves enough state for the next start to remove only this rule, and
    # mkdir cannot follow a marker symlink supplied in the config volume.
    if ! mkdir -m 700 -- "$ppm_limits_marker"; then
      log ERROR "Cannot create temporary PPM limit marker [$ppm_limits_marker]."
      return 1
    fi
    if ! {
      cat <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcLimits
olcLimits: {0}$ppm_limits
EOF
    } | ppm_ldapmodify_logged; then
      # Keep the marker because a client failure does not prove that slapd
      # rejected the write. The next start resolves either outcome safely.
      log ERROR "Cannot install the local limit required to reconcile Debian PPM policies."
      return 1
    fi

    ppm_search_status=0
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
        -b "$database_suffix" -s sub '(objectClass=pwdPolicyChecker)' \
        objectClass pwdUseCheckModule pwdCheckModuleArg \
        >"$ppm_policy_entries_file" || ppm_search_status=$?

    # The override is needed only while reading policies. Remove it before any
    # later failure can leave unnecessary unlimited access for public slapd.
    ppm_cleanup_owned_limit "$ppm_limits_marker" "$ppm_limits" || return
  fi

  if (( ppm_search_status != 0 )); then
    # The suffix can be configured before its base entry exists. Treat LDAP
    # result 32 as an empty policy set, as the old slapcat path did. Other errors
    # stop startup. Truncate because even a no-such-object response may have
    # emitted partial LDIF before returning its final status.
    if (( ppm_search_status != 32 )); then
      log ERROR "Cannot read password policies for Debian PPM reconciliation."
      return 1
    fi
    if ! : >"$ppm_policy_entries_file"; then
      log ERROR "Cannot discard the empty-suffix Debian PPM search result."
      return 1
    fi
  fi

  # Keep both the source LDIF and generated modifications on disk. The AWK parser
  # still compares complete records, while Bash memory stays independent of the
  # number of policies and ldapmodify reads only after preparation succeeds.
  if ! ppm_prepare_policy_changes \
      "$ppm_arg_base64" "$ppm_arg_plain" "$ppm_replace_existing" \
      <"$ppm_policy_entries_file" >"$ppm_policy_changes_file"; then
    log ERROR "Cannot prepare password policy updates for Debian PPM."
    return 1
  fi

  if [[ -s $ppm_policy_changes_file ]]; then
    log INFO "Reconciling Debian PPM policy attributes from $ppm_config_source..."
    if ! ppm_ldapmodify_logged <"$ppm_policy_changes_file"; then
      log ERROR "Cannot reconcile Debian PPM policy attributes."
      return 1
    fi
  fi
)

function ppm_read_check_module() {
  local config_ldif
  local check_module
  local status=0

  # Capture slapcat before parsing its output, so failures are detected even if the
  # caller did not enable pipefail. Parse complete records because another database
  # can have its own ppolicy overlay and module without changing the image-managed
  # MDB overlay.
  config_ldif=$(ppm_export_config) || return
  check_module=$(awk '
      BEGIN {
        RS = ""
        FS = "\n"
        target_suffix = ",olcdatabase={1}mdb,cn=config"
      }
      {
        dn = ""
        is_ppolicy = 0
        module = ""
        for (i = 1; i <= NF; i++) {
          line = $i
          lower = tolower(line)
          if (lower ~ /^dn: /) dn = substr(lower, 5)
          if (lower == "objectclass: olcppolicyconfig") is_ppolicy = 1
          if (lower ~ /^olcppolicycheckmodule: /) {
            module = substr(line, index(line, ":") + 2)
          }
        }

        if (!is_ppolicy || length(dn) < length(target_suffix) ||
            substr(dn, length(dn) - length(target_suffix) + 1) != target_suffix) next

        target_count++
        target_module = module
      }
      END {
        # Selecting the first target would make migration depend on slapcat order.
        if (target_count > 1) exit 42
        if (target_count == 1) print target_module
      }
    ' <<<"$config_ldif") || status=$?

  # Reserve a distinct status for the supported parser-level ambiguity. Normal
  # awk failures retain their own status and must not be reported as topology errors.
  if ((status == 42)); then
    # Keep diagnostics out of stdout because callers capture the module path.
    log ERROR "Multiple ppolicy overlays were found under olcDatabase={1}mdb; automatic PPM migration requires one managed overlay." >&2
    return 1
  fi
  ((status == 0)) || return "$status"
  printf '%s\n' "$check_module"
}

function ppm_read_managed_database_consumer_state() {
  local config_ldif
  local consumer_state
  local status=0

  # PPM owns policy entries only below the image-managed MDB. A different
  # database may run its own syncrepl consumer without transferring ownership of
  # these policies to that database's provider, so inspect the complete target
  # record instead of treating any olcSyncrepl value as a server-wide role.
  config_ldif=$(ppm_export_config) || return
  consumer_state=$(awk '
      BEGIN {
        RS = ""
        FS = "\n"
        target_dn = "olcdatabase={1}mdb,cn=config"
      }
      {
        dn = ""
        has_syncrepl = 0
        for (i = 1; i <= NF; i++) {
          lower = tolower($i)
          if (lower ~ /^dn: /) dn = substr(lower, 5)
          if (lower ~ /^olcsyncrepl:/) has_syncrepl = 1
        }

        if (dn != target_dn) next
        target_count++
        if (has_syncrepl) target_is_consumer = 1
      }
      END {
        # Missing or duplicate target records mean the image can no longer prove
        # who owns its policy data. Fail closed instead of risking a local write
        # to a replicated suffix.
        if (target_count != 1) exit 42
        print target_is_consumer ? "true" : "false"
      }
    ' <<<"$config_ldif") || status=$?

  if ((status == 42)); then
    # Keep diagnostics out of stdout because callers capture the boolean value.
    log ERROR "Expected exactly one olcDatabase={1}mdb record while determining PPM policy ownership." >&2
    return 1
  fi
  ((status == 0)) || return "$status"
  printf '%s\n' "$consumer_state"
}

#################################################################
# Public lifecycle functions
#################################################################

function ppm_configure() {
  local translated_config

  # Prefix shared variables with ppm_ because this file runs in run.sh's shell.
  # Reset every value so a repeated call cannot retain a partial failed parse.
  declare -g ppm_configured=false
  declare -g ppm_legacy_migration=false
  declare -g ppm_write_migrated_config_version=false
  declare -g ppm_module_migration_operation=""
  declare -g ppm_arg_base64=""
  declare -g ppm_arg_plain=""
  declare -g ppm_config_source=""
  declare -g ppm_config_explicit=false
  declare -g ppm_reconcile_policies=false
  declare -g ppm_replace_existing=true
  declare -g ppm_reconciliation_prepared=false

  # Check whether the variable exists, not whether it contains text. An explicit
  # empty value must disable the nonempty legacy default and leave policies unchanged.
  if [[ -v LDAP_PPOLICY_PPM_CONFIG ]]; then
    ppm_config_explicit=true
    if [[ -n $LDAP_PPOLICY_PPM_CONFIG ]]; then
      # pwdCheckModuleArg is binary LDAP syntax, but the public setting stays as
      # readable PPM text; base64 is only the LDIF transport representation.
      ppm_arg_plain=$LDAP_PPOLICY_PPM_CONFIG
      # run.sh calls this function from an explicit failure guard, which disables
      # inherited errexit inside the function. Check the transport encoding here.
      if ! ppm_arg_base64=$(printf '%s' "$ppm_arg_plain" | base64 -w 0); then
        log ERROR "Cannot encode LDAP_PPOLICY_PPM_CONFIG for pwdCheckModuleArg."
        return 1
      fi
      ppm_config_source=LDAP_PPOLICY_PPM_CONFIG
    fi
  elif [[ -n ${LDAP_PPOLICY_PQCHECKER_RULE:-} ]]; then
    if ! translated_config=$(ppm_pqchecker_rule_to_config "$LDAP_PPOLICY_PQCHECKER_RULE"); then
      log ERROR "Invalid LDAP_PPOLICY_PQCHECKER_RULE [$LDAP_PPOLICY_PQCHECKER_RULE]. Use [0|UULLDDSS<forbidden>] or [UULLDDSS<forbidden>]; broadcast mode [1|] is not supported."
      return 1
    fi
    # Command substitution removes trailing newlines. Add back the translator's
    # single final newline so persisted compatibility values remain unchanged.
    ppm_arg_plain=$translated_config$'\n'
    if ! ppm_arg_base64=$(printf '%s' "$ppm_arg_plain" | base64 -w 0); then
      log ERROR "Cannot encode the translated LDAP_PPOLICY_PQCHECKER_RULE for pwdCheckModuleArg."
      return 1
    fi
    ppm_config_source=LDAP_PPOLICY_PQCHECKER_RULE
  fi

  ppm_configured=true
}

function ppm_detect_migration() {
  local initialized_file=$1
  local config_version=$2
  local last_version
  local check_module

  ppm_require_configured || return

  ppm_legacy_migration=false
  ppm_write_migrated_config_version=false
  ppm_module_migration_operation=""

  # Fresh initialization writes the current marker after all bootstrap LDIFs
  # succeed. Only existing volumes need migration checks.
  [[ -e $initialized_file ]] || return 0
  last_version=$(read_config_version_marker "$initialized_file") || return
  [[ $last_version == 1 ]] && last_version=2.5

  if ! check_module=$(ppm_read_check_module); then
    log ERROR "Cannot inspect the configured password check module."
    return 1
  fi

  # OpenLDAP 2.5 needs the check-module attribute. Current volumes migrate only
  # when their persisted state still references the retired pqChecker binary.
  if [[ $last_version == 2.5 ||
        ( $last_version == "$config_version" &&
          $check_module == /usr/lib/ldap/pqchecker.so ) ]]; then
    log BOX "Migrating password quality checking to Debian PPM..."

    # pqChecker read the image-managed rule from pqparams.dat, so image-created
    # policies have no pwdCheckModuleArg to translate. This flag distinguishes
    # that missing legacy state from an explicit native opt-out, which must leave
    # any custom policy attributes unchanged.
    if [[ -z $check_module ||
          $check_module == /usr/lib/ldap/pqchecker.so ||
          $check_module == /usr/lib/ldap/ppm.so ]]; then
      ppm_legacy_migration=true
    fi

    case "$check_module" in
      "") ppm_module_migration_operation=add ;;
      /usr/lib/ldap/pqchecker.so) ppm_module_migration_operation=replace ;;
      /usr/lib/ldap/ppm.so) log INFO "Password policy overlay already uses Debian PPM" ;;
      *) log WARN "Preserving custom password check module [$check_module]" ;;
    esac

    # A current marker already records the right version. Path-only repair must
    # not rewrite it; only a real version upgrade is committed after all work
    # succeeds.
    if [[ $last_version != "$config_version" ]]; then
      ppm_write_migrated_config_version=true
    fi
  elif [[ $last_version != "$config_version" ]]; then
    # Use the compatibility symlink only for migrations that this image can
    # translate. Otherwise PPM could read pqChecker values as PPM configuration
    # even though startup reports that it skipped the unknown migration.
    if [[ $check_module == /usr/lib/ldap/pqchecker.so ]]; then
      log ERROR "Unknown configuration version [$last_version] still references the retired pqChecker module; refusing to start with incompatible PPM rules."
      return 1
    fi
    log WARN "Unknown configuration version: $last_version (expected: $config_version)"
    log WARN "Skipping migrations - manual intervention may be required"
  else
    log INFO "Configuration is up to date (version: $config_version)"
  fi
}

function ppm_prepare_reconciliation() {
  local check_module
  local managed_database_consumer
  local translated_config

  ppm_require_configured || return

  ppm_reconcile_policies=false
  ppm_replace_existing=true
  ppm_reconciliation_prepared=false

  if ! managed_database_consumer=$(ppm_read_managed_database_consumer_state); then
    log ERROR "Cannot determine whether the managed MDB is a replication consumer."
    return 1
  fi

  # Replicated directory data belongs to the provider. Consumers may still need
  # their local cn=config module path migrated, but must not write policy values.
  if [[ $managed_database_consumer == true ]]; then
    ppm_reconciliation_prepared=true
    return 0
  fi

  if ! check_module=$(ppm_read_check_module); then
    log ERROR "Cannot inspect the configured password check module."
    return 1
  fi

  # If another module is configured, leave its policy attributes unchanged. The
  # old pqchecker.so path is the exception: it loads PPM and marks an unfinished
  # migration.
  if [[ $check_module != /usr/lib/ldap/ppm.so &&
        ! ( $ppm_legacy_migration == true &&
            ( -z $check_module || $check_module == /usr/lib/ldap/pqchecker.so ) ) ]]; then
    ppm_reconciliation_prepared=true
    return 0
  fi

  if [[ -z $ppm_arg_base64 && $ppm_config_explicit == false &&
        -z ${LDAP_PPOLICY_PQCHECKER_RULE:-} && $ppm_legacy_migration == true ]]; then
    # An empty legacy setting normally disables updates. During migration, add only
    # missing attributes so PPM never starts without rules. An empty native
    # setting still wins.
    translated_config=$(ppm_pqchecker_rule_to_config '0|01010101') || return
    ppm_arg_plain=$translated_config$'\n'
    # This lifecycle function is also called from an explicit failure guard, so
    # encode failures must be propagated without relying on errexit.
    if ! ppm_arg_base64=$(printf '%s' "$ppm_arg_plain" | base64 -w 0); then
      log ERROR "Cannot encode the legacy pqChecker migration defaults for pwdCheckModuleArg."
      return 1
    fi
    ppm_config_source='legacy pqChecker migration defaults'
    ppm_replace_existing=false
  fi

  [[ -z $ppm_arg_base64 ]] || ppm_reconcile_policies=true
  ppm_reconciliation_prepared=true
}

function ppm_reconcile() {
  local ppm_search_acl
  local ppm_write_acl
  local ppm_peercred_dn
  local ppm_limits
  local ppm_limits_marker
  local mdb_access_config
  local mdb_config
  local suffix_line
  local suffix_ldif
  local database_suffix
  local ppolicy_dn
  local ppolicy_search

  ppm_require_configured || return
  if [[ ${ppm_reconciliation_prepared:-false} != true ]]; then
    log ERROR "ppm_prepare_reconciliation must run before ppm_reconcile."
    return 1
  fi

  # Keep policy reconciliation on the temporary ldapi-only slapd instead of
  # editing the stopped database with slapmodify. The online path applies normal
  # schema and overlay validation and records provider changes with its replication
  # metadata; an offline path would make the entrypoint responsible for those
  # replication and database-ownership details.
  ppm_peercred_dn='gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth'
  # A TLS client certificate can map to the same SASL EXTERNAL DN. Requiring the
  # local socket limits these maintenance permissions to root inside the container.
  # Use the clause order and quoting that OpenLDAP returns. It accepts other forms
  # but does not keep them, so matching the returned form prevents duplicate rules
  # on restart.
  ppm_search_acl="to attrs=entry,objectClass by dn.exact=\"$ppm_peercred_dn\" sockurl.exact=\"ldapi:///\" write by * break"
  ppm_write_acl="to filter=\"(objectClass=pwdPolicyChecker)\" attrs=pwdUseCheckModule,pwdCheckModuleArg by dn.exact=\"$ppm_peercred_dn\" sockurl.exact=\"ldapi:///\" write by * break"
  ppm_limits="dn.exact=\"$ppm_peercred_dn\" size.soft=unlimited size.hard=unlimited time.soft=unlimited time.hard=unlimited"
  ppm_limits_marker=/etc/ldap/slapd.d/.ppm-reconciliation-limit

  # An interrupted start can leave an image-owned rule behind. Clean it before
  # deciding whether this start needs a new override; without the marker, an
  # identical operator-owned rule is deliberately preserved.
  ppm_cleanup_owned_limit "$ppm_limits_marker" "$ppm_limits" || return

  if [[ $ppm_reconcile_policies == true ]]; then
    if ! mdb_config=$(ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
        -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcAccess olcLimits); then
      log ERROR "Cannot inspect MDB ACLs and limits required to reconcile Debian PPM policies."
      return 1
    fi

    # LDAP discovery needs entry and objectClass access from the suffix down.
    # Because this first matching ACL stops evaluation for local root, use write
    # instead of read so it does not remove existing entry add, delete, rename, or
    # objectClass operations. Other image-granted writes remain limited to the two
    # PPM attributes. Keep both rules permanently because reconciliation runs on
    # every writer start. Existing catch-all rules mean these rules must stay first;
    # the position check avoids rewriting correctly ordered ACLs on every restart.
    if ! ppm_config_has_value "$mdb_config" olcAccess "$ppm_search_acl" 0 ||
        ! ppm_config_has_value "$mdb_config" olcAccess "$ppm_write_acl" 1; then
      # Build the prefix back-to-front because each {0} insertion pushes the
      # previous first rule to {1}. Refresh after moving the write rule: OpenLDAP
      # renumbers ordered values, and deletion must use the ordinal it returned.
      # Each move is atomic; a failure between them leaves both rules present,
      # and the next start re-enters this repair branch.
      ppm_prepend_access_rule "$mdb_config" "$ppm_write_acl" || return
      if ! mdb_access_config=$(ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
          -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcAccess); then
        log ERROR "Cannot refresh MDB ACLs while repairing Debian PPM maintenance access."
        return 1
      fi
      ppm_prepend_access_rule "$mdb_access_config" "$ppm_search_acl" || return
    fi

    if ! suffix_ldif=$(ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
        -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcSuffix); then
      log ERROR "Cannot read the MDB suffix needed for Debian PPM reconciliation."
      return 1
    fi
    suffix_line=$(awk '/^olcSuffix::? / && suffix == "" { suffix = $0 } END { print suffix }' \
      <<<"$suffix_ldif")
    if [[ $suffix_line == 'olcSuffix:: '* ]]; then
      # ldapsearch retains LDIF base64 for non-ASCII DNs. Decode only the search
      # base while preserving returned entry DNs in their original LDIF form.
      if ! database_suffix=$(printf '%s' "${suffix_line#olcSuffix:: }" | base64 -d); then
        log ERROR "Cannot decode the MDB suffix needed for Debian PPM reconciliation."
        return 1
      fi
    elif [[ $suffix_line == 'olcSuffix: '* ]]; then
      database_suffix=${suffix_line#olcSuffix: }
    else
      log ERROR "Cannot find the MDB suffix needed for Debian PPM reconciliation."
      return 1
    fi

    # Use the indexed objectClass search so normal starts read only policy entries.
    # The helper spools the complete result before applying changes; slapcat would
    # export every entry and direct streaming could apply an incomplete search.
    ppm_reconcile_policy_entries \
      "$database_suffix" "$mdb_config" "$ppm_limits" "$ppm_limits_marker" || return
  fi

  if [[ -n $ppm_module_migration_operation ]]; then
    # Consume the whole search result: early termination can SIGPIPE ldapsearch
    # under pipefail and turn a valid overlay DN into a failed migration.
    if ! ppolicy_search=$(ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
        -b 'olcDatabase={1}mdb,cn=config' '(objectClass=olcPPolicyConfig)' dn 2>/dev/null); then
      log ERROR "Cannot find the ppolicy overlay required for password policy migration."
      return 1
    fi
    ppolicy_dn=$(awk '/^dn: / && dn == "" { dn = substr($0, 5) } END { print dn }' \
      <<<"$ppolicy_search")
    if [[ -z $ppolicy_dn ]]; then
      # Absence is a supported configuration, not unfinished work. Do not create
      # an operator-managed overlay; there is no module attribute to migrate.
      log INFO "No managed ppolicy overlay is configured; no password policy module migration is required."
      ppm_module_migration_operation=""
    else
      log INFO "Configuring the password policy overlay to use Debian PPM..."
      # Keep pqchecker.so until all policy updates succeed. If a later step fails,
      # the old path tells the next start to retry.
      if ! {
        cat <<EOF
dn: $ppolicy_dn
changetype: modify
$ppm_module_migration_operation: olcPPolicyCheckModule
olcPPolicyCheckModule: /usr/lib/ldap/ppm.so
EOF
      } | ppm_ldapmodify_logged; then
        log ERROR "Failed to apply password policy overlay migration"
        return 1
      fi
      log INFO "Successfully migrated password policy overlay configuration"
      ppm_module_migration_operation=""
    fi
  fi

}

function ppm_commit_migration() {
  local initialized_file=$1
  local config_version=$2

  ppm_require_configured || return
  [[ $ppm_write_migrated_config_version == true ]] || return 0

  # The marker suppresses future retries, so every module operation must either
  # be applied or explicitly discharged as a supported no-op before publication.
  if [[ -n $ppm_module_migration_operation ]]; then
    log ERROR "Cannot commit configuration migration while password policy module migration remains pending."
    return 1
  fi

  # The caller invokes this only after all surrounding configuration succeeds;
  # writing earlier would make a partial migration look complete on retry.
  publish_config_version_marker "$initialized_file" "$config_version" || return
  ppm_write_migrated_config_version=false
  log INFO "Configuration migration completed"
}
