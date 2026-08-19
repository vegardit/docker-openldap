#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# run.sh sources this file after service-user normalization. Sourcing is
# definition-only: run.sh remains responsible for every slapd start and stop.
# The caller provides `log`, `run_as_openldap`, and the online `ldif` helper.
#
# Intended order and outputs:
#   tls_prepare              # normalizes LDAP_TLS_*, installs files, selects listeners
#   tls_reconcile_stopped_config # slapd is stopped; repairs startup-blocking state
#   tls_reconcile_enabled    # temporary ldapi-only slapd is running; enables TLS

function tls_config_tool_logged() {
  local status

  # Do not let the logging pipeline or the caller's pipefail setting decide whether
  # an offline configuration tool succeeded. Both branches capture the tool status
  # before another command can replace PIPESTATUS.
  if run_as_openldap "$@" 2>&1 | log INFO; then
    status=${PIPESTATUS[0]}
  else
    status=${PIPESTATUS[0]}
  fi
  return "$status"
}

function tls_normalize_config_integer() {
  local value=$1
  local label=$2

  # slapcat reads a service-owned configuration and root consumes this result.
  # Canonicalize before any arithmetic and bound the significant width so even a
  # malicious module cannot turn Bash's arithmetic parser into command execution.
  if [[ $value =~ ^0+$ ]]; then
    printf '0\n'
  elif [[ $value =~ ^0*([1-9][0-9]*)$ ]] && (( ${#BASH_REMATCH[1]} <= 10 )); then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    log ERROR "cn=config returned an invalid or out-of-range $label value" >&2
    return 1
  fi
}

function tls_decimal_is_less() {
  local left=$1
  local right=$2

  # Width comparison handles the large cases without arithmetic. Equal-width
  # values are bounded to ten digits by tls_normalize_config_integer and therefore
  # fit safely in Bash's signed arithmetic on the image's supported platforms.
  if (( ${#left} < ${#right} )); then
    return 0
  fi
  if (( ${#left} > ${#right} )); then
    return 1
  fi
  (( 10#$left < 10#$right ))
}

function tls_ldif_has_managed_syncrepl_ca() {
  local encoded_value
  local line
  local syncrepl_value
  local managed_ca_found=false

  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      "olcSyncrepl: "*)
        syncrepl_value=${line#olcSyncrepl: }
        ;;
      "olcSyncrepl:: "*)
        encoded_value=${line#olcSyncrepl:: }
        if ! syncrepl_value=$(printf '%s' "$encoded_value" |
            /usr/bin/base64 --decode 2>/dev/null); then
          # An uninspectable syncrepl value must not turn a required CA into an
          # apparent no-match. The caller converts this parser status into a
          # startup error without logging service-controlled attribute content.
          return 2
        fi
        ;;
      olcSyncrepl:*)
        # slapcat normally emits plain or base64 values. Fail closed if that
        # contract changes instead of silently skipping a persisted consumer.
        return 2
        ;;
      *) continue ;;
    esac

    if [[ $syncrepl_value == *"tls_cacert=/etc/ldap/certs/ca.crt"* ]]; then
      # Read the complete stream even after a match so slapcat cannot receive
      # SIGPIPE and make pipefail replace a positive result with a pipeline error.
      managed_ca_found=true
    fi
  done

  [[ $managed_ca_found == true ]]
}

function tls_stopped_config_requires_current_ca() {
  local -a pipeline_status=()

  # Decode and inspect LDIF with the service identity. cn=config may load
  # service-controlled modules, and root does not need either their output or the
  # decoded syncrepl credentials to decide whether the managed CA path is present.
  if run_as_openldap /usr/sbin/slapcat \
      -F /etc/ldap/slapd.d -n 0 -o ldif-wrap=no |
      run_as_openldap /bin/bash -c \
        'source /opt/tls.sh; tls_ldif_has_managed_syncrepl_ca'; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi

  if (( pipeline_status[0] != 0 || pipeline_status[1] > 1 )); then
    log ERROR "Failed to inspect persisted syncrepl TLS configuration"
    return 2
  fi
  return "${pipeline_status[1]}"
}

function tls_source_is_readable_file() {
  local source=${1:-}

  # TLS paths may be below directories writable by the service. Perform both the
  # check and the later open with service authority so replacing a path with a
  # link cannot make the root entrypoint disclose a root-only file. Links to
  # regular files which openldap can already read remain supported.
  run_as_openldap /usr/bin/test -f "$source" &&
    run_as_openldap /usr/bin/test -r "$source"
}

function tls_path_is_service_immutable() {
  local path=${1:-}
  local path_component
  local current_path=""
  local component_owner_uid
  local openldap_uid
  local -a path_components=()

  [[ $path == /* ]] || return 1
  openldap_uid=$(/usr/bin/id -u openldap) || return 1
  IFS=/ read -r -a path_components <<<"$path"

  # Validate from the trust anchor down. Once a parent is known not to be
  # service-writable, openldap cannot replace its child while the remaining path
  # is inspected or before root acts on the final entry. Reject all links because a
  # separately validated target would not make a service-controlled link stable.
  # Ownership is control too because an owner can chmod a non-writable component.
  # Requiring root ownership would still be too strict: a safe read-only mount may
  # belong to a mapped host UID which openldap cannot impersonate.
  run_as_openldap /usr/bin/test -w / && return 1
  for path_component in "${path_components[@]}"; do
    [[ -n $path_component ]] || continue
    current_path+="/$path_component"

    [[ ! -L $current_path ]] || return 1
    # Classification is intentionally quiet; tls_prepare owns source-specific
    # diagnostics after trying both accepted source classes.
    component_owner_uid=$(/usr/bin/stat -c %u -- "$current_path" 2>/dev/null) || return 1
    [[ $component_owner_uid != "$openldap_uid" ]] || return 1
    if [[ $current_path == "$path" ]]; then
      break
    fi
    [[ -d $current_path ]] || return 1

    # Write access is a deliberately conservative rejection signal. Sticky-bit
    # and execute rules can make some writable directories safe in practice, but
    # reproducing every rename rule here would make this boundary harder to audit.
    run_as_openldap /usr/bin/test -w "$current_path" && return 1
  done

  [[ $current_path == "$path" ]] || return 1
  ! run_as_openldap /usr/bin/test -w "$path"
}

function tls_source_is_trusted_root_file() {
  local source=${1:-}

  tls_path_is_service_immutable "$source" &&
    [[ -f $source && -r $source ]]
}

function tls_source_is_usable_file() {
  tls_source_is_readable_file "$1" ||
    tls_source_is_trusted_root_file "$1"
}

function tls_install_source() {
  local source=$1
  local destination=$2
  local mode=$3
  local temporary_file=""

  if tls_source_is_readable_file "$source"; then
    run_as_openldap /usr/bin/install -m "$mode" -- "$source" "$destination"
    return
  fi
  tls_source_is_trusted_root_file "$source" || return 1

  # A sibling keeps publication on one filesystem and lets -T replace a destination
  # link itself. mktemp also keeps key content at 0600 until its final mode is set.
  if ! temporary_file=$(run_as_openldap /usr/bin/mktemp -- "${destination}.tmp.XXXXXX"); then
    return 1
  fi

  # The redirection is intentionally evaluated by the root entrypoint after the
  # path walk above. Only the already-open input crosses the privilege boundary;
  # tee, chmod, and the destination rename all retain service authority.
  if run_as_openldap /usr/bin/tee -- "$temporary_file" <"$source" >/dev/null &&
      run_as_openldap /usr/bin/chmod "$mode" -- "$temporary_file" &&
      run_as_openldap /usr/bin/mv -fT -- "$temporary_file" "$destination"; then
    return 0
  fi

  if ! run_as_openldap /usr/bin/rm -f -- "$temporary_file"; then
    log WARN "Cannot remove temporary TLS file [$temporary_file]"
  fi
  return 1
}

function tls_source_is_proven_absent_by_service() {
  local source=${1:-}
  local source_component
  local current_path=""
  local -a source_components=()

  [[ $source == /* ]] || return 1
  IFS=/ read -r -a source_components <<<"$source"

  # A direct failed lookup cannot distinguish ENOENT from an unsearchable parent.
  # Walk from / so a missing component is accepted only after openldap proved its
  # parent searchable. Existing dangling links and blocked ancestors therefore
  # remain errors without giving the root entrypoint an existence oracle.
  for source_component in "${source_components[@]}"; do
    [[ -n $source_component ]] || continue
    current_path+="/$source_component"

    if run_as_openldap /usr/bin/test -e "$current_path"; then
      if [[ $current_path != "$source" ]] &&
          { ! run_as_openldap /usr/bin/test -d "$current_path" ||
            ! run_as_openldap /usr/bin/test -x "$current_path"; }; then
        return 1
      fi
    elif run_as_openldap /usr/bin/test -L "$current_path"; then
      return 1
    else
      return 0
    fi
  done
  return 1
}

function tls_source_is_proven_absent() {
  local source=${1:-}
  local source_parent

  tls_source_is_proven_absent_by_service "$source" && return 0
  [[ $source == /* ]] || return 1
  source_parent=${source%/*}
  [[ -n $source_parent ]] || source_parent=/

  # Root may inspect the configured leaf only after the same path walk used for
  # protected files proves that openldap cannot retarget its parent. This supports
  # an absent optional CA below a 0700 secret directory without turning a
  # service-controlled link into a root existence oracle.
  tls_path_is_service_immutable "$source_parent" &&
    [[ -d $source_parent && ! -e $source && ! -L $source ]]
}

# Keep this synchronized with Dockerfile's public default. Equality is the only
# distinction between optional auto-discovery and an explicitly required path.
tls_default_ca_file=/run/secrets/ldap/ca.crt

# shellcheck disable=SC2034  # run.sh consumes SLAPD_EXTRA_URLS when starting final slapd.
function tls_prepare() {
  local tls_ca_source=${LDAP_TLS_CA_FILE:-$tls_default_ca_file}
  local tls_cert_is_usable=false
  local tls_key_is_usable=false

  SLAPD_EXTRA_URLS=""
  # run.sh uses this current-start signal instead of trusting a managed CA copy
  # left by an earlier invocation. It proves only that a nonempty current source
  # was staged below; OpenLDAP remains responsible for parsing and trusting it.
  TLS_CA_READY_THIS_START=false

  case "${LDAP_TLS_ENABLED:-}" in
    true|false) ;;
    auto)
      if tls_source_is_usable_file "${LDAP_TLS_CERT_FILE:-}"; then
        tls_cert_is_usable=true
      fi
      if tls_source_is_usable_file "${LDAP_TLS_KEY_FILE:-}"; then
        tls_key_is_usable=true
      fi
      if [[ $tls_cert_is_usable == true && $tls_key_is_usable == true ]]; then
        LDAP_TLS_ENABLED=true
      else
        LDAP_TLS_ENABLED=false
        # Do not probe a rejected path with unrestricted root authority merely to
        # improve diagnostics. The absence proof warns only when the configured
        # path cannot be dismissed without crossing the same trust boundary.
        if [[ $tls_cert_is_usable == false ]] &&
            ! tls_source_is_proven_absent "${LDAP_TLS_CERT_FILE:-}"; then
          log WARN "TLS auto-detection cannot safely use the configured certificate or private key source; disabling TLS"
        elif [[ $tls_key_is_usable == false ]] &&
            ! tls_source_is_proven_absent "${LDAP_TLS_KEY_FILE:-}"; then
          log WARN "TLS auto-detection cannot safely use the configured certificate or private key source; disabling TLS"
        fi
      fi
      ;;
    *) log ERROR "LDAP_TLS_ENABLED must be auto|true|false"; return 1 ;;
  esac

  if [[ $LDAP_TLS_ENABLED == true ]]; then
    # Bash treats leading-zero arithmetic as octal and does not detect overflow.
    # Accept zero padding, but capture at most three digits after it so conversion
    # is bounded; normalize once so every later use has canonical decimal syntax.
    if ! [[ $LDAP_TLS_SSF =~ ^0*([0-9]{1,3})$ ]] ||
        (( 10#${BASH_REMATCH[1]} > 256 )); then
      log ERROR "LDAP_TLS_SSF must be an integer between 0 and 256 (got '$LDAP_TLS_SSF')"
      return 1
    fi
    LDAP_TLS_SSF=$((10#${BASH_REMATCH[1]}))

    case "${LDAP_LDAPS_ENABLED:-}" in
      true|false) log INFO "LDAPS enabled (port 636): $LDAP_LDAPS_ENABLED";;
      *) log ERROR "LDAP_LDAPS_ENABLED must be true|false"; return 1 ;;
    esac
    if [[ $LDAP_LDAPS_ENABLED == true ]]; then
      SLAPD_EXTRA_URLS=" ldaps:///"
    fi

    case "${LDAP_TLS_VERIFY_CLIENT:-}" in
      never|allow|try|demand) log INFO "TLS_VERIFY_CLIENT: $LDAP_TLS_VERIFY_CLIENT";;
      *) log ERROR "LDAP_TLS_VERIFY_CLIENT must be never|allow|try|demand"; return 1 ;;
    esac

    # These checks provide source-specific diagnostics. tls_install_source repeats
    # classification at the open boundary so no caller can rely on stale validation.
    if ! tls_source_is_usable_file "${LDAP_TLS_KEY_FILE:-}"; then
      log ERROR "LDAP_TLS_KEY_FILE must name a service-readable or protected root-readable regular file [${LDAP_TLS_KEY_FILE:-}]"
      return 1
    fi
    if ! tls_source_is_usable_file "${LDAP_TLS_CERT_FILE:-}"; then
      log ERROR "LDAP_TLS_CERT_FILE must name a service-readable or protected root-readable regular file [${LDAP_TLS_CERT_FILE:-}]"
      return 1
    fi

    log INFO "Installing TLS certificates..."
    # These checks are explicit because a caller may legitimately guard the whole
    # function with `||`, which disables inherited errexit inside a Bash function.
    # Keep destination opens under the same authority too: /etc/ldap is service-
    # owned before this phase, so a replaced destination path must not let root
    # write outside the managed certificate directory.
    if ! run_as_openldap /usr/bin/install -d -m 0755 -- /etc/ldap/certs ||
        ! tls_install_source "$LDAP_TLS_KEY_FILE" /etc/ldap/certs/server.key 0600 ||
        ! tls_install_source "$LDAP_TLS_CERT_FILE" /etc/ldap/certs/server.crt 0644; then
      log ERROR "Failed to install the TLS certificate or private key"
      return 1
    fi
  fi

  # The CA is peer trust for both inbound client certificates and persisted
  # outbound syncrepl. Stage a usable current source even when server TLS is off;
  # run.sh makes it mandatory only when persisted outbound configuration needs it.
  if tls_source_is_usable_file "$tls_ca_source"; then
    # Keep directory creation in this independent branch because disabled inbound
    # TLS intentionally skips the server-certificate installation above.
    if ! run_as_openldap /usr/bin/install -d -m 0755 -- /etc/ldap/certs ||
        ! tls_install_source "$tls_ca_source" /etc/ldap/certs/ca.crt 0644; then
      log ERROR "Failed to install the TLS CA certificate"
      return 1
    fi
    if run_as_openldap /usr/bin/test -s /etc/ldap/certs/ca.crt; then
      TLS_CA_READY_THIS_START=true
    fi
  elif [[ $LDAP_TLS_ENABLED == true ]]; then
    # The default location is an auto-discovery convention and may be absent. A
    # different value was selected explicitly, while the default is optional only
    # when its absence can be proven without a service-retargetable lookup.
    if [[ $tls_ca_source != "$tls_default_ca_file" ]] ||
        ! tls_source_is_proven_absent "$tls_ca_source"; then
      log ERROR "LDAP_TLS_CA_FILE must name a service-readable or protected root-readable regular file [$tls_ca_source]"
      return 1
    fi
  fi
}

# Reconcile startup-blocking TLS state while slapd is stopped. Persisted SSF or
# certificate paths can prevent even the temporary maintenance daemon from running.
function tls_reconcile_stopped_config() (
  local config_ldif=""
  local config_ldif_fd
  local rebuilt_config_directory=""
  local staged_global_config=""
  local original_global_config=""
  local managed_tls_ssf=""
  local config_has_changes=false
  local config_output
  local line
  local in_global_config=false
  local global_config_count=0
  local local_ssf=""
  local local_ssf_count=0
  local overall_ssf_count=0
  local current_overall_ssf=""
  local security_value
  local security_factor
  local factor_name
  local factor_value
  local normalized_factor_value
  local preserved_value
  local current_local_ssf
  local required_local_ssf=0
  local raise_local_ssf=false
  local rewrite_security=false
  local remove_all_tls_attributes=false
  local remove_tls_ca_attribute=false
  local tls_attribute
  local -a security_factors=()
  local -a preserved_security_values=()
  local -a managed_tls_attributes=(
    olcTLSCertificateFile
    olcTLSCertificateKeyFile
    olcTLSCACertificateFile
    olcTLSVerifyClient
  )
  local -A present_tls_attributes=()

  if [[ $LDAP_TLS_ENABLED == true && $LDAP_TLS_SSF != 0 ]]; then
    managed_tls_ssf=$LDAP_TLS_SSF
    required_local_ssf=$managed_tls_ssf
  fi

  # Run slapcat with the service identity because cn=config may load modules from
  # its service-owned tree. Root validates the captured text before interpreting
  # any numeric value or re-emitting any administrator-owned factor.
  if ! config_output=$(run_as_openldap /usr/sbin/slapcat \
      -F /etc/ldap/slapd.d -n 0 -o ldif-wrap=no); then
    log ERROR "Failed to inspect the stopped cn=config security policy"
    return 1
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -z $line ]]; then
      in_global_config=false
      continue
    fi

    case "$line" in
      "dn: cn=config")
        ((global_config_count += 1))
        if (( global_config_count > 1 )); then
          log ERROR "cn=config export returned more than one global configuration entry"
          return 1
        fi
        in_global_config=true
        continue
        ;;
      dn:* )
        in_global_config=false
        continue
        ;;
    esac

    [[ $in_global_config == true ]] || continue
    case "$line" in
      "olcLocalSSF: "*)
        ((local_ssf_count += 1))
        if (( local_ssf_count > 1 )); then
          log ERROR "cn=config returned more than one olcLocalSSF value"
          return 1
        fi
        if ! local_ssf=$(tls_normalize_config_integer \
            "${line#olcLocalSSF: }" olcLocalSSF); then
          return 1
        fi
        ;;
      olcLocalSSF:*)
        # An integer has a plain ASCII LDIF representation. Reject base64 or URL
        # forms rather than decoding service-controlled data in the root process.
        log ERROR "cn=config returned an invalid olcLocalSSF representation"
        return 1
        ;;
      "olcSecurity: "*)
        security_value=${line#olcSecurity: }
        if ! read -r -a security_factors <<<"$security_value" ||
            (( ${#security_factors[@]} == 0 )); then
          log ERROR "cn=config returned an empty olcSecurity value"
          return 1
        fi
        preserved_value=""
        for security_factor in "${security_factors[@]}"; do
          if ! [[ $security_factor =~ ^([[:alpha:]_][[:alnum:]_]*)=([0-9]+)$ ]]; then
            log ERROR "cn=config returned an invalid olcSecurity factor"
            return 1
          fi
          factor_name=${BASH_REMATCH[1]}
          factor_value=${BASH_REMATCH[2]}
          case "${factor_name,,}" in
            ssf)
              if ! normalized_factor_value=$(tls_normalize_config_integer \
                  "$factor_value" 'olcSecurity ssf'); then
                return 1
              fi
              ((overall_ssf_count += 1))
              current_overall_ssf=$normalized_factor_value
              # LDAP_TLS_SSF owns only the overall factor. It is re-emitted below;
              # every narrower administrator-owned factor stays byte-for-byte.
              continue
              ;;
            update_ssf|transport|update_transport)
              if ! normalized_factor_value=$(tls_normalize_config_integer \
                  "$factor_value" "olcSecurity $factor_name"); then
                return 1
              fi
              # olcLocalSSF supplies ldapi's overall and underlying-transport SSF.
              # These independent floors can gate the readiness search, later
              # updates, or both, so local maintenance must satisfy their maximum.
              # TLS/SASL-specific factors are preserved but cannot be satisfied by
              # olcLocalSSF; such policies may still reject this ldapi maintenance path.
              if tls_decimal_is_less "$required_local_ssf" "$normalized_factor_value"; then
                required_local_ssf=$normalized_factor_value
              fi
              # Do not continue after this branch: these factors are administrator-
              # owned. After sizing local maintenance, preserve their original
              # spelling and value in olcSecurity.
              ;;
          esac
          if [[ -n $preserved_value ]]; then
            preserved_value+=" "
          fi
          preserved_value+="$security_factor"
        done
        if [[ -n $preserved_value ]]; then
          preserved_security_values+=("$preserved_value")
        fi
        ;;
      olcSecurity:*)
        log ERROR "cn=config returned an invalid olcSecurity representation"
        return 1
        ;;
      olcTLSCertificateFile:*|olcTLSCertificateKeyFile:*|olcTLSCACertificateFile:*|olcTLSVerifyClient:*)
        # Only presence matters here. The entrypoint owns these global attributes,
        # so disabling them does not require trusting or decoding their current values.
        present_tls_attributes["${line%%:*}"]=true
        ;;
    esac
  done <<<"$config_output"

  if (( global_config_count != 1 )); then
    log ERROR "cn=config export did not contain exactly one global configuration entry"
    return 1
  fi

  # Never lower an explicit local allowance: it may be administrator-owned. The
  # implicit value is 71, so write an explicit value only when the required floor
  # exceeds what the stopped configuration already provides.
  current_local_ssf=${local_ssf:-71}
  if tls_decimal_is_less "$current_local_ssf" "$required_local_ssf"; then
    raise_local_ssf=true
  fi

  if [[ -n $managed_tls_ssf ]]; then
    if (( overall_ssf_count != 1 )) || [[ $current_overall_ssf != "$managed_tls_ssf" ]]; then
      rewrite_security=true
    fi
  elif (( overall_ssf_count > 0 )); then
    rewrite_security=true
  fi

  if [[ $LDAP_TLS_ENABLED != true ]]; then
    for tls_attribute in "${managed_tls_attributes[@]}"; do
      if [[ ${present_tls_attributes[$tls_attribute]:-} == true ]]; then
        remove_all_tls_attributes=true
        break
      fi
    done
  elif [[ ${present_tls_attributes[olcTLSCACertificateFile]:-} == true &&
          ${TLS_CA_READY_THIS_START:-false} != true ]]; then
    # The default CA is optional. A managed file can survive a same-container
    # restart, so only this invocation's staging result may retain its persisted
    # path. Outbound syncrepl has a separate current-CA check before this point.
    remove_tls_ca_attribute=true
  fi

  if [[ $raise_local_ssf == true || $rewrite_security == true ||
        $remove_all_tls_attributes == true || $remove_tls_ca_attribute == true ]]; then
    config_has_changes=true
  fi

  if [[ $config_has_changes != true ]]; then
    log INFO "Stopped TLS configuration already permits pre-start maintenance"
    return 0
  fi

  if ! config_ldif=$(mktemp --suffix=.ldif /tmp/tls-config.XXXXXX); then
    log ERROR "Failed to create the stopped TLS configuration export"
    return 1
  fi
  if ! rebuilt_config_directory=$(run_as_openldap /usr/bin/mktemp -d /tmp/tls-config.XXXXXX); then
    rm -f -- "$config_ldif" || true
    log ERROR "Failed to create the stopped TLS configuration workspace"
    return 1
  fi
  # Every cleanup target is an exact path returned by mktemp. The subshell keeps
  # this trap local, and preserving the incoming status prevents cleanup from
  # turning a failed reconciliation into a successful startup.
  trap 'status=$?
    if [[ -n $staged_global_config ]] && ! run_as_openldap /usr/bin/rm -f -- "$staged_global_config"; then
      log WARN "Cannot remove [$staged_global_config]"
    fi
    if [[ -n $original_global_config ]] && ! run_as_openldap /usr/bin/rm -f -- "$original_global_config"; then
      log WARN "Cannot remove [$original_global_config]"
    fi
    if ! rm -f -- "$config_ldif"; then
      log WARN "Cannot remove [$config_ldif]"
    fi
    if ! run_as_openldap /usr/bin/rm -rf -- "$rebuilt_config_directory"; then
      log WARN "Cannot remove [$rebuilt_config_directory]"
    fi
    exit "$status"' EXIT

  # slapmodify can persist part of a TLS-attribute deletion and still return an
  # error. Rebuild a complete service-owned snapshot instead, validate it in
  # isolation, and publish only the global entry that this function manages. Keep
  # one output descriptor for the loop so large configurations do not reopen the
  # same file for every retained line.
  in_global_config=false
  if ! exec {config_ldif_fd}>"$config_ldif"; then
    log ERROR "Failed to open the stopped TLS configuration export"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      "") in_global_config=false ;;
      "dn: cn=config")
        in_global_config=true
        if ! printf '%s\n' "$line" >&"$config_ldif_fd"; then
          log ERROR "Failed to write the stopped TLS configuration export"
          return 1
        fi
        if [[ $raise_local_ssf == true ]] &&
            ! printf 'olcLocalSSF: %s\n' "$required_local_ssf" >&"$config_ldif_fd"; then
          log ERROR "Failed to write the local SSF reconciliation"
          return 1
        fi
        if [[ $rewrite_security == true ]]; then
          for security_value in "${preserved_security_values[@]}"; do
            if ! printf 'olcSecurity: %s\n' "$security_value" >&"$config_ldif_fd"; then
              log ERROR "Failed to write the overall SSF reconciliation"
              return 1
            fi
          done
          if [[ -n $managed_tls_ssf ]] &&
              ! printf 'olcSecurity: ssf=%s\n' "$managed_tls_ssf" >&"$config_ldif_fd"; then
            log ERROR "Failed to write the overall SSF reconciliation"
            return 1
          fi
        fi
        continue
        ;;
      dn:*) in_global_config=false ;;
    esac

    if [[ $in_global_config == true ]]; then
      if [[ $raise_local_ssf == true && $line == olcLocalSSF:* ]] ||
          [[ $rewrite_security == true && $line == olcSecurity:* ]]; then
        continue
      fi
      case "$line" in
        olcTLSCertificateFile:*|olcTLSCertificateKeyFile:*|olcTLSCACertificateFile:*|olcTLSVerifyClient:*)
          tls_attribute=${line%%:*}
          if [[ $remove_all_tls_attributes == true ]] ||
              [[ $remove_tls_ca_attribute == true && $tls_attribute == olcTLSCACertificateFile ]]; then
            continue
          fi
          ;;
      esac
    fi
    if ! printf '%s\n' "$line" >&"$config_ldif_fd"; then
      log ERROR "Failed to write the stopped TLS configuration export"
      return 1
    fi
  done <<<"$config_output"
  if ! exec {config_ldif_fd}>&-; then
    log ERROR "Failed to close the stopped TLS configuration export"
    return 1
  fi

  # Keep the generated LDIF root-owned. The root shell opens it before the file
  # descriptor crosses into slapadd, so service-controlled code cannot retarget a
  # privileged pathname between validation and import.
  if ! tls_config_tool_logged /usr/sbin/slapadd \
      -F "$rebuilt_config_directory" -n 0 <"$config_ldif"; then
    log ERROR "Stopped TLS configuration rebuild failed"
    return 1
  fi
  if ! tls_config_tool_logged /usr/sbin/slaptest \
      -F "$rebuilt_config_directory" -u; then
    log ERROR "Stopped TLS configuration validation failed"
    return 1
  fi

  # Stage both the replacement and a rollback copy in the mounted configuration
  # directory. The final same-filesystem rename replaces a destination link itself
  # and never exposes a partially written global entry.
  if ! staged_global_config=$(run_as_openldap /usr/bin/mktemp -- \
      /etc/ldap/slapd.d/.cn=config.ldif.XXXXXX) ||
      ! original_global_config=$(run_as_openldap /usr/bin/mktemp -- \
        /etc/ldap/slapd.d/.cn=config.ldif.backup.XXXXXX) ||
      ! run_as_openldap /usr/bin/install -m 0600 -- \
        "$rebuilt_config_directory/cn=config.ldif" "$staged_global_config" ||
      ! run_as_openldap /usr/bin/install -m 0600 -- \
        /etc/ldap/slapd.d/cn=config.ldif "$original_global_config"; then
    log ERROR "Failed to stage the stopped TLS configuration"
    return 1
  fi
  if ! run_as_openldap /usr/bin/mv -fT -- \
      "$staged_global_config" /etc/ldap/slapd.d/cn=config.ldif; then
    log ERROR "Failed to publish the stopped TLS configuration"
    return 1
  fi

  if ! tls_config_tool_logged /usr/sbin/slaptest -F /etc/ldap/slapd.d -u; then
    log ERROR "Published cn=config failed validation; restoring the previous global entry"
    if ! run_as_openldap /usr/bin/mv -fT -- \
        "$original_global_config" /etc/ldap/slapd.d/cn=config.ldif; then
      log ERROR "Cannot restore cn=config; the previous global entry remains at [$original_global_config]"
      # Preserve the rollback copy for manual recovery when automatic restoration fails.
      original_global_config=""
    fi
    return 1
  fi
)

# Enabling certificate settings stays online so slapd performs its normal attribute
# validation. Disabled and stale-CA state is already removed before prestart.
function tls_reconcile_enabled() (
  local tls_ldif=""

  # This is an assertion of the lifecycle contract in run.sh, not a fallback for
  # disabled TLS: the temporary daemon may be unable to start before such a fallback.
  if [[ $LDAP_TLS_ENABLED != true ]]; then
    log ERROR "Online TLS reconciliation requires LDAP_TLS_ENABLED=true"
    return 1
  fi

  if ! tls_ldif=$(mktemp --suffix=.ldif /tmp/tls.XXXXXX); then
    log ERROR "Failed to create the TLS reconciliation file"
    return 1
  fi
  trap 'status=$?; rm -f -- "$tls_ldif" || log WARN "Cannot remove [$tls_ldif]"; exit "$status"' EXIT

  log BOX "Enabling TLS support..."

  if ! cat >"$tls_ldif" <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/certs/server.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/certs/server.key
EOF
  then
    log ERROR "Failed to write the TLS certificate reconciliation"
    return 1
  fi
  if [[ ${TLS_CA_READY_THIS_START:-false} == true ]]; then
    # Never probe the service-controlled destination as root. The current-start
    # signal already proves that the managed file was staged and is nonempty.
    if ! cat >>"$tls_ldif" <<EOF
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/certs/ca.crt
EOF
    then
      log ERROR "Failed to write the TLS CA reconciliation"
      return 1
    fi
  fi

  if ! cat >>"$tls_ldif" <<EOF
-
replace: olcTLSVerifyClient
olcTLSVerifyClient: ${LDAP_TLS_VERIFY_CLIENT:-try}
EOF
  then
    log ERROR "Failed to write the TLS client-verification reconciliation"
    return 1
  fi

  if ! ldif modify -Y EXTERNAL "$tls_ldif"; then
    log ERROR "Failed to reconcile the TLS attributes"
    return 1
  fi
)
