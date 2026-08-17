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
#   tls_reconcile_security   # slapd is stopped; makes local maintenance reachable
#   tls_reconcile            # temporary ldapi-only slapd is running; sets TLS attributes

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

# shellcheck disable=SC2034  # run.sh consumes SLAPD_EXTRA_URLS when starting final slapd.
function tls_prepare() {
  SLAPD_EXTRA_URLS=""

  case "${LDAP_TLS_ENABLED:-}" in
    true|false) ;;
    auto) [[ -f $LDAP_TLS_CERT_FILE && -f $LDAP_TLS_KEY_FILE ]] && LDAP_TLS_ENABLED=true || LDAP_TLS_ENABLED=false ;;
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

    if [[ ! -f ${LDAP_TLS_KEY_FILE:-} ]]; then
      log ERROR "TLS requested but LDAP_TLS_KEY_FILE [${LDAP_TLS_KEY_FILE:-}] not accessible"
      return 1
    fi
    if [[ ! -f ${LDAP_TLS_CERT_FILE:-} ]]; then
      log ERROR "TLS requested but LDAP_TLS_CERT_FILE [${LDAP_TLS_CERT_FILE:-}] not accessible"
      return 1
    fi

    log INFO "Installing TLS certificates..."
    # These checks are explicit because a caller may legitimately guard the whole
    # function with `||`, which disables inherited errexit inside a Bash function.
    if ! install -d -o openldap -g openldap -m 0755 /etc/ldap/certs ||
        ! install -o openldap -g openldap -m 0600 "$LDAP_TLS_KEY_FILE" /etc/ldap/certs/server.key ||
        ! install -o openldap -g openldap -m 0644 "$LDAP_TLS_CERT_FILE" /etc/ldap/certs/server.crt; then
      log ERROR "Failed to install the TLS certificate or private key"
      return 1
    fi
    if [[ -f ${LDAP_TLS_CA_FILE:-} ]]; then
      if ! install -o openldap -g openldap -m 0644 "$LDAP_TLS_CA_FILE" /etc/ldap/certs/ca.crt; then
        log ERROR "Failed to install the TLS CA certificate"
        return 1
      fi
    fi
  fi
}

# Reconcile the security policy while slapd is stopped. A persisted overall ssf
# can reject even the readiness query, so no online repair is guaranteed to run.
function tls_reconcile_security() (
  local security_ldif=""
  local managed_tls_ssf=""
  local security_ldif_has_changes=false
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
  local -a security_factors=()
  local -a preserved_security_values=()

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

  if [[ $raise_local_ssf != true && $rewrite_security != true ]]; then
    log INFO "SSF configuration already keeps local maintenance reachable"
    return 0
  fi

  if ! security_ldif=$(mktemp --suffix=.ldif /tmp/tls-security.XXXXXX); then
    log ERROR "Failed to create the offline SSF reconciliation file"
    return 1
  fi
  # Preserve the function's real status even if cleanup fails. The subshell keeps
  # this EXIT trap local and makes every generated file cleanup path identical.
  trap 'status=$?; rm -f -- "$security_ldif" || log WARN "Cannot remove [$security_ldif]"; exit "$status"' EXIT

  if ! printf '%s\n' 'dn: cn=config' 'changetype: modify' >"$security_ldif"; then
    log ERROR "Failed to write the offline SSF reconciliation file"
    return 1
  fi

  if [[ $raise_local_ssf == true ]]; then
    if ! printf '%s\n' \
        'replace: olcLocalSSF' \
        "olcLocalSSF: $required_local_ssf" >>"$security_ldif"; then
      log ERROR "Failed to write the local SSF reconciliation"
      return 1
    fi
    security_ldif_has_changes=true
  fi

  if [[ $rewrite_security == true ]]; then
    if ! {
      if [[ $security_ldif_has_changes == true ]]; then
        printf '%s\n' '-'
      fi
      printf '%s\n' 'replace: olcSecurity'
      for security_value in "${preserved_security_values[@]}"; do
        printf 'olcSecurity: %s\n' "$security_value"
      done
      if [[ -n $managed_tls_ssf ]]; then
        printf 'olcSecurity: ssf=%s\n' "$managed_tls_ssf"
      fi
      # With no preserved or managed values, an empty replace removes the
      # attribute. This branch exists only when an overall factor was present.
    } >>"$security_ldif"; then
      log ERROR "Failed to write the overall SSF reconciliation"
      return 1
    fi
  fi

  # A dry run catches an invalid generated modify before touching the live files.
  # The real write uses the slapd identity so any files it creates retain the
  # ownership expected by the final daemon.
  if ! tls_config_tool_logged /usr/sbin/slapmodify \
      -F /etc/ldap/slapd.d -n 0 -u <"$security_ldif"; then
    log ERROR "Offline SSF reconciliation validation failed"
    return 1
  fi
  if ! tls_config_tool_logged /usr/sbin/slapmodify \
      -F /etc/ldap/slapd.d -n 0 <"$security_ldif"; then
    log ERROR "Offline SSF reconciliation failed"
    return 1
  fi
  if ! tls_config_tool_logged /usr/sbin/slaptest \
      -F /etc/ldap/slapd.d -u; then
    log ERROR "cn=config validation failed after SSF reconciliation"
    return 1
  fi
)

# Certificate settings stay on the local-only daemon so slapd performs its normal
# online attribute validation. The SSF policy is already safe before this runs.
function tls_reconcile() (
  local tls_ldif=""
  local tls_ldif_has_changes=false
  local config_output
  local line
  local tls_attribute
  local -a managed_tls_attributes=(
    olcTLSCertificateFile
    olcTLSCertificateKeyFile
    olcTLSCACertificateFile
    olcTLSVerifyClient
  )
  local -A present_tls_attributes=()

  if ! tls_ldif=$(mktemp --suffix=.ldif /tmp/tls.XXXXXX); then
    log ERROR "Failed to create the TLS reconciliation file"
    return 1
  fi
  trap 'status=$?; rm -f -- "$tls_ldif" || log WARN "Cannot remove [$tls_ldif]"; exit "$status"' EXIT

  if [[ $LDAP_TLS_ENABLED == true ]]; then
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
    tls_ldif_has_changes=true
    if [[ -f /etc/ldap/certs/ca.crt ]]; then
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

  else
    log BOX "Ensuring TLS support is disabled..."
    if ! cat >"$tls_ldif" <<EOF
dn: cn=config
changetype: modify
EOF
    then
      log ERROR "Failed to create the TLS removal reconciliation"
      return 1
    fi

    # Deletions are added after reading live cn=config. Omitting attributes that
    # do not exist avoids OpenLDAP error 16 without a continue-on-error request
    # that could also hide a failure to remove another managed attribute.
  fi

  if ! config_output=$(ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'cn=config' -s base '(objectClass=*)' \
      "${managed_tls_attributes[@]}"); then
    log ERROR "Failed to read the current cn=config TLS attributes"
    return 1
  fi

  while IFS= read -r line; do
    case "$line" in
      olcTLSCertificateFile:*|olcTLSCertificateKeyFile:*|olcTLSCACertificateFile:*|olcTLSVerifyClient:*)
        # Only presence matters when disabling TLS; delete the complete attribute
        # without parsing certificate paths or client-policy values as root.
        tls_attribute=${line%%:*}
        present_tls_attributes["$tls_attribute"]=true
        ;;
    esac
  done <<<"$config_output"

  if [[ $LDAP_TLS_ENABLED != true ]]; then
    for tls_attribute in "${managed_tls_attributes[@]}"; do
      if [[ ${present_tls_attributes[$tls_attribute]:-} == true ]]; then
        if ! {
          if [[ $tls_ldif_has_changes == true ]]; then
            printf '%s\n' '-'
          fi
          printf 'delete: %s\n' "$tls_attribute"
        } >>"$tls_ldif"; then
          log ERROR "Failed to write the TLS attribute removal for [$tls_attribute]"
          return 1
        fi
        tls_ldif_has_changes=true
      fi
    done
  fi

  if [[ $tls_ldif_has_changes == true ]]; then
    if ! ldif modify -Y EXTERNAL "$tls_ldif"; then
      log ERROR "Failed to reconcile the TLS attributes"
      return 1
    fi
  else
    log INFO "TLS configuration already matches the requested disabled state"
  fi
)
