#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# self-contained Debian PPM function regressions.
# This file is sourced by test-image.sh and intentionally shares its fixtures,
# helpers, and cleanup trap so scenario boundaries do not create extra Docker
# resources or alter lifecycle ordering.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_ppm_functions() {
# ==============================================================================
# PPM function-level regressions
# ==============================================================================

# Keep these checks after the shared definitions so the main test flow below stays
# in one continuous block.

# Module discovery must inspect the ppolicy overlay attached to the image-managed
# MDB database. An unrelated overlay must neither override a configured target nor
# make a missing target module look configured.
docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
  source /opt/ppm.sh
  log() { printf "%s\n" "$*" >&2; }
  # Bash uses dynamic local scope. Keep the fixture name distinct from the
  # helper-local config_ldif variables so the stub can still see its input.
  ppm_export_config() { printf "%s\n" "$slapcat_ldif"; }

  slapcat_ldif=$(cat <<\LDIF
dn: olcOverlay={0}ppolicy,olcDatabase={2}mdb,cn=config
objectClass: olcPPolicyConfig
olcPPolicyCheckModule: /usr/lib/ldap/unrelated.so

dn: olcOverlay={0}ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcPPolicyConfig
olcPPolicyCheckModule: /usr/lib/ldap/ppm.so
LDIF
  )
  selected_module=$(ppm_read_check_module)
  if [[ $selected_module != /usr/lib/ldap/ppm.so ]]; then
    printf "Unexpected managed PPM module: %s\n" "$selected_module" >&2
    exit 1
  fi

  slapcat_ldif=$(cat <<\LDIF
dn: olcOverlay={0}ppolicy,olcDatabase={2}mdb,cn=config
objectClass: olcPPolicyConfig
olcPPolicyCheckModule: /usr/lib/ldap/unrelated.so

dn: olcOverlay={0}ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcPPolicyConfig
LDIF
  )
  selected_module=$(ppm_read_check_module)
  if [[ -n $selected_module ]]; then
    printf "An unrelated overlay supplied the managed module: %s\n" "$selected_module" >&2
    exit 1
  fi

  # More than one target record would make path migration nondeterministic. The
  # helper must stop instead of selecting whichever record slapcat prints first.
  slapcat_ldif=$(cat <<\LDIF
dn: olcOverlay={0}ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcPPolicyConfig
olcPPolicyCheckModule: /usr/lib/ldap/ppm.so

dn: olcOverlay={1}ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcPPolicyConfig
olcPPolicyCheckModule: /usr/lib/ldap/other.so
LDIF
  )
  if ppm_read_check_module >/dev/null 2>&1; then
    echo "Ambiguous managed ppolicy overlays were accepted." >&2
    exit 1
  fi

  # Consumer ownership is a property of the managed MDB, not the whole server.
  # An unrelated consumer database must not suppress image-managed policy writes.
  slapcat_ldif=$(cat <<\LDIF
dn: olcDatabase={2}mdb,cn=config
objectClass: olcDatabaseConfig
olcSyncrepl: rid=002 provider=ldaps://unrelated

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
LDIF
  )
  managed_consumer=$(ppm_read_managed_database_consumer_state)
  if [[ $managed_consumer != false ]]; then
    printf "An unrelated syncrepl record changed managed ownership to: %s\n" "$managed_consumer" >&2
    exit 1
  fi

  slapcat_ldif=$(cat <<\LDIF
dn: olcDatabase={2}mdb,cn=config
objectClass: olcDatabaseConfig

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
olcSyncrepl: rid=001 provider=ldaps://provider
LDIF
  )
  managed_consumer=$(ppm_read_managed_database_consumer_state)
  if [[ $managed_consumer != true ]]; then
    printf "Managed syncrepl was not classified as a consumer: %s\n" "$managed_consumer" >&2
    exit 1
  fi

  # An unreadable cn=config must not default to writer ownership because that
  # could make reconciliation modify provider-owned policy entries.
  ppm_export_config() { return 19; }
  if ppm_read_managed_database_consumer_state >/dev/null 2>&1; then
    echo "A slapcat failure defaulted the managed MDB to writer ownership." >&2
    exit 1
  fi
'

# run.sh invokes PPM lifecycle functions through explicit failure guards. Bash
# disables inherited errexit in that context, so each base64 transport conversion
# must report its own failure instead of allowing startup to continue with no rule.
docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
  source /opt/ppm.sh
  log() { :; }
  base64() { return 1; }

  LDAP_PPOLICY_PPM_CONFIG="minQuality 0"
  if ppm_configure; then
    echo "Native PPM encoding failure was ignored." >&2
    exit 1
  fi

  unset LDAP_PPOLICY_PPM_CONFIG
  LDAP_PPOLICY_PQCHECKER_RULE="0|01010101"
  if ppm_configure; then
    echo "Legacy rule encoding failure was ignored." >&2
    exit 1
  fi

  LDAP_PPOLICY_PQCHECKER_RULE=
  ppm_configure
  ppm_legacy_migration=true
  ppm_read_managed_database_consumer_state() { printf "%s\n" false; }
  ppm_read_check_module() { printf "%s\n" /usr/lib/ldap/pqchecker.so; }
  if ppm_prepare_reconciliation; then
    echo "Migration-default encoding failure was ignored." >&2
    exit 1
  fi
'

# ldapsearch may emit a safe binary value as plain LDIF. A matching value must not
# be rewritten, or every unchanged restart creates new replication state.
plain_ppm_changes=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
  source /opt/ppm.sh
  ppm_arg=$1
  ppm_arg_base64=$(printf "%s" "$ppm_arg" | base64 -w 0)
  printf "dn: cn=Policy,dc=example,dc=com\nobjectClass: pwdPolicyChecker\npwdUseCheckModule: TRUE\npwdCheckModuleArg: %s\n\n" "$ppm_arg" |
    ppm_prepare_policy_changes "$ppm_arg_base64" "$ppm_arg" true
' -- 'minQuality 3')
if [[ -n $plain_ppm_changes ]]; then
  printf '%s\n' "$plain_ppm_changes" >&2
  echo "A matching plain pwdCheckModuleArg produced a redundant policy update." >&2
  exit 1
fi

# Empty octet strings have no space after the LDIF delimiter. They are still
# present values, so normal updates must replace them and migrations that only
# fill missing attributes must leave them unchanged.
docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
  source /opt/ppm.sh
  ppm_arg="minQuality 0"
  ppm_arg_base64=$(printf "%s" "$ppm_arg" | base64 -w 0)

  for empty_arg_line in "$@"; do
    policy_ldif=$(printf "dn: cn=Policy,dc=example,dc=com\nobjectClass: pwdPolicyChecker\npwdUseCheckModule: TRUE\n%s\n" "$empty_arg_line")
    changes=$(ppm_prepare_policy_changes "$ppm_arg_base64" "$ppm_arg" true <<<"$policy_ldif")
    if ! grep -Fx "replace: pwdCheckModuleArg" <<<"$changes" >/dev/null ||
        grep -Fx "add: pwdCheckModuleArg" <<<"$changes" >/dev/null; then
      printf "%s\n" "$changes" >&2
      echo "An empty pwdCheckModuleArg was not treated as an existing single value." >&2
      exit 1
    fi

    fill_only_changes=$(ppm_prepare_policy_changes "$ppm_arg_base64" "$ppm_arg" false <<<"$policy_ldif")
    if [[ -n $fill_only_changes ]]; then
      printf "%s\n" "$fill_only_changes" >&2
      echo "Fill-only PPM migration overwrote an existing empty argument." >&2
      exit 1
    fi
  done
' -- "pwdCheckModuleArg:" "pwdCheckModuleArg::"

# PPM policy attributes belong to the shared reconciliation phase. Keeping them
# out of the bootstrap template prevents a generated TRUE value from conflicting
# with a custom policy's explicit FALSE value before reconciliation can preserve it.
bootstrap_policy_ldif=$(docker run --rm --entrypoint bash \
  --env LDAP_PPOLICY_PPM_CONFIG="$native_ppm_config" \
  "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/ppm.sh
    LDAP_INIT_ORG_DN=DC=example,DC=com
    # run.sh expands nested LDAP_INIT variables before loading this template.
    # Reproduce that boundary so this check fails only on runtime PPM attributes.
    LDAP_INIT_PPOLICY_DEFAULT_DN="cn=DefaultPasswordPolicy,ou=Policies,$LDAP_INIT_ORG_DN"
    ppm_configure
    # Calling the retired hook when present makes this assertion fail against the
    # old image for the intended reason instead of an undefined placeholder.
    if declare -F ppm_prepare_initial_policy_ldif >/dev/null; then
      ppm_prepare_initial_policy_ldif
    fi
    interpolate </opt/ldifs/init_org_ppolicy.ldif
  ')
if [[ $bootstrap_policy_ldif == *'pwdUseCheckModule:'* ||
      $bootstrap_policy_ldif == *'pwdCheckModuleArg:'* ]] || ! awk '
    BEGIN { RS = "" }
    index($0, "dn: cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com") &&
      index($0, "pwdAttribute: userPassword") { found = 1 }
    END { exit !found }
  ' <<<"$bootstrap_policy_ldif"; then
  printf '%s\n' "$bootstrap_policy_ldif" >&2
  echo "The bootstrap policy template contains runtime PPM attributes." >&2
  exit 1
fi

# Unknown versions skip normal migration. Reject the old module path before the
# compatibility symlink can make PPM read pqChecker arguments. run.sh turns this
# failure into a startup error.
if unknown_version_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/ppm.sh
    # This function-level fixture runs as root and has no entrypoint lifecycle.
    # Keep the caller-provided boundary explicit; tests/image/version-marker.sh
    # proves that the real entrypoint drops to the service account.
    run_as_openldap() { "$@"; }
    ppm_read_check_module() { printf "%s\n" /usr/lib/ldap/pqchecker.so; }
    marker=$(mktemp)
    printf "%s\n" future-version >"$marker"
    ppm_configure
    ppm_detect_migration "$marker" 2.6
  ' 2>&1); then
  echo "An unknown configuration version accepted the retired pqChecker module path." >&2
  exit 1
fi
if [[ $unknown_version_output != *'Unknown configuration version [future-version] still references the retired pqChecker module'* ]]; then
  printf '%s\n' "$unknown_version_output" >&2
  echo "The retired pqChecker path failed for an unrelated reason." >&2
  exit 1
fi

# Keep malformed marker text out of diagnostics without narrowing legitimate
# unknown tokens. Exercise the inclusive boundary separately so an accidental
# greater-than-or-equal comparison cannot hide behind the oversized failure below.
if ! maximum_marker_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/ppm.sh
    run_as_openldap() { "$@"; }
    ppm_read_check_module() { printf "%s\n" /usr/lib/ldap/ppm.so; }
    marker=$(mktemp)
    printf "%0128d" 0 >"$marker"
    ppm_configure
    ppm_detect_migration "$marker" 2.6
  ' 2>&1); then
  printf '%s\n' "$maximum_marker_output" >&2
  echo "A maximum-sized configuration version marker was rejected." >&2
  exit 1
fi

# Reading one byte beyond the entrypoint bound must reject the value before module
# inspection or version-specific migration logic can use it.
if oversized_marker_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/ppm.sh
    run_as_openldap() { "$@"; }
    ppm_read_check_module() { printf "%s\n" /usr/lib/ldap/ppm.so; }
    marker=$(mktemp)
    printf "%0129d" 0 >"$marker"
    ppm_configure
    ppm_detect_migration "$marker" 2.6
  ' 2>&1); then
  printf '%s\n' "$oversized_marker_output" >&2
  echo "An oversized configuration version marker reached migration logic." >&2
  exit 1
fi
if [[ $oversized_marker_output != *'is not a bounded printable value'* ]]; then
  printf '%s\n' "$oversized_marker_output" >&2
  echo "The oversized configuration version marker failed for an unrelated reason." >&2
  exit 1
fi
}
