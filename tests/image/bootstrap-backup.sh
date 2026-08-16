#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# stateful bootstrap, PPM migration, restart, and backup checks.
# This file is sourced by test-image.sh and intentionally shares its fixtures,
# helpers, and cleanup trap so scenario boundaries do not create extra Docker
# resources or alter lifecycle ordering.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_bootstrap_backup_and_ppm() {
# ==============================================================================
# Initial bootstrap and baseline server behavior
# ==============================================================================

test_phase "Checking fresh-volume initialization and restart behavior"
create_fresh_volumes

# Reserve backup intent before LDAP initialization becomes non-idempotent. Seed
# the volumes exactly as the entrypoint does, then inject an invalid marker so a
# failed reservation must leave the seeded configuration untouched and retryable.
docker run --rm --entrypoint sh \
  --mount "type=volume,src=$config_volume,dst=/mnt/config" \
  --mount "type=volume,src=$data_volume,dst=/mnt/data" \
  "$image_name" -c '
    cp -r --preserve=all /etc/ldap/slapd.d_orig/. /mnt/config
    cp -r --preserve=all /var/lib/ldap_orig/. /mnt/data
    printf "%s\n" collision > /mnt/data/.initial-backup-pending
  '
# This failure must occur before custom schemas or LDIFs are read, so copying those
# fixtures into a container that is expected to exit would only add Docker overhead.
start_container --env LDAP_INIT_RFC2307BIS_SCHEMA=1
for _ in {1..40}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done
invalid_initial_marker_logs=$(docker logs "$container" 2>&1)
if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] ||
    [[ $invalid_initial_marker_logs != *"Cannot create initial backup marker"* ]]; then
  printf '%s\n' "$invalid_initial_marker_logs" >&2
  echo "An invalid initial-backup marker did not fail initialization." >&2
  exit 1
fi

# The RFC2307bis replacement is the earliest optional durable mutation and the
# sudo schema is the first unconditional LDAP add. Their absence proves the
# marker failure happened at the intended transaction boundary, not merely that
# the entrypoint eventually rejected the collision.
if ! docker run --rm --entrypoint sh \
    --mount "type=volume,src=$config_volume,dst=/mnt/config" \
    --mount "type=volume,src=$data_volume,dst=/mnt/data" \
    "$image_name" -c '
      test -n "$(find /mnt/config -type f -name "*nis*.ldif" -print -quit)" &&
      test -z "$(find /mnt/config -type f -name "*rfc2307bis*.ldif" -print -quit)" &&
      test -z "$(find /mnt/config -type f -name "*sudo*.ldif" -print -quit)" &&
      rm -f /mnt/data/.initial-backup-pending &&
      mkdir -m 700 /mnt/data/.initial-backup-pending
    '; then
  echo "A failed initial-backup marker reservation modified LDAP configuration." >&2
  exit 1
fi

docker rm "$container" >/dev/null
# The volume helper above replaces the invalid fixture with an empty directory.
# That is the only state the image can safely adopt: rmdir later consumes the
# marker without ever deleting operator or partially written data.
# RFC2307bis is opt-in, so exercise its generated slapadd input here. Later
# fresh replication fixtures retain default-schema coverage.
# The invalid legacy rule is intentional. An explicitly set native PPM value must
# take precedence before the legacy rule is parsed. Docker must also keep its
# newline.
start_container \
  --bootstrap-ldifs \
  --env INIT_SH_FILE=/opt/ldifs/custom/.init.sh \
  --env PAUSE_INIT_FOR_LISTENER_TEST=true \
  --env LDAP_INIT_RFC2307BIS_SCHEMA=1 \
  --env LDAP_PPOLICY_PPM_CONFIG="$native_ppm_config" \
  --env 'LDAP_PPOLICY_PQCHECKER_RULE=1|ignored' \
  --env CUSTOM_ENTRY_CN=custom-entry \
  --env CUSTOM_SCHEMA_ATTRIBUTE_NAME=customBootstrapValue

# Inspect the daemon while initialization is blocked at its first LDAP write.
# Checking its exact -h argument covers both LDAP and LDAPS without relying on
# timing-sensitive connection failures or the container's published ports.
test_step "Checking temporary initialization listener"
# Poll inside one exec session. Repeated Docker API calls can take minutes through
# act's remote daemon even though each in-container file check is effectively free.
if ! temporary_slapd_arguments=$(docker exec "$container" sh -c '
  remaining=600
  while [ ! -e /run/init-listener-test-ready ] && [ "$remaining" -gt 0 ]; do
    sleep 0.1
    remaining=$((remaining - 1))
  done
  test -e /run/init-listener-test-ready || exit 1
  pid=$(cat /run/slapd-init/slapd.pid)
  tr "\0" "\n" <"/proc/$pid/cmdline" || exit
  touch /run/init-listener-test-release
'); then
  docker logs "$container" >&2
  echo "Initialization did not reach the temporary slapd listener check." >&2
  exit 1
fi
temporary_slapd_arguments=$'\n'"$temporary_slapd_arguments"$'\n'
if [[ $temporary_slapd_arguments != *$'\n-h\nldapi:///\n'* ]]; then
  printf '%s' "$temporary_slapd_arguments" >&2
  echo "The temporary initialization daemon exposed a network listener." >&2
  exit 1
fi

wait_until_ready
if docker exec "$container" test -e "$initial_backup_pending_marker"; then
  echo "An existing valid initial-backup marker was not consumed after export." >&2
  exit 1
fi
docker exec "$container" test -f /etc/ldap/slapd.d/cn=config.ldif
docker exec "$container" test -s /var/lib/ldap/data.mdb
docker exec "$container" test -d /etc/ldap/slapd.d/lost+found
docker exec "$container" test -d /var/lib/ldap/lost+found

ppolicy_config=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' '(objectClass=olcPPolicyConfig)' \
    dn olcPPolicyCheckModule | tr -d '\015')
if [[ $ppolicy_config != *'olcPPolicyCheckModule: /usr/lib/ldap/ppm.so'* ]]; then
  printf '%s\n' "$ppolicy_config" >&2
  echo "The password policy overlay does not use Debian PPM." >&2
  exit 1
fi
ppolicy_dn=$(sed -n 's/^dn: //p' <<<"$ppolicy_config")

policy_entry=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
if [[ $policy_entry != *'pwdUseCheckModule: TRUE'* ||
      $policy_entry != *'pwdCheckModuleArg:: '* ]]; then
  printf '%s\n' "$policy_entry" >&2
  echo "The default password policy does not enable PPM with native arguments." >&2
  exit 1
fi
initial_ppm_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$policy_entry")
initial_ppm_arg=$(printf '%s' "$initial_ppm_arg_base64" | base64 -d)
if [[ $initial_ppm_arg != "$native_ppm_config" ]]; then
  printf '%s\n' "$initial_ppm_arg" >&2
  echo "The native PPM configuration was not encoded without changing its text." >&2
  exit 1
fi

disabled_policy_entry=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DisabledPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
disabled_initial_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$disabled_policy_entry")
disabled_initial_arg=$(printf '%s' "$disabled_initial_arg_base64" | base64 -d)
if [[ $disabled_policy_entry != *'pwdUseCheckModule: FALSE'* ||
      $disabled_initial_arg != "$native_ppm_config" ]]; then
  printf '%s\n' "$disabled_policy_entry" >&2
  echo "Initial PPM reconciliation changed a policy's explicit opt-out." >&2
  exit 1
fi

# The mounted policy template intentionally has no PPM interpolation hook, so its
# attributes are added by the shared reconciliation phase. The first backup must
# describe that final state rather than the earlier bootstrap-only state.
if ! docker exec "$container" \
    grep -Fx 'pwdUseCheckModule: TRUE' /var/lib/ldap/data.ldif >/dev/null; then
  echo "The initial backup was created before PPM reconciliation completed." >&2
  exit 1
fi
# The backup contains two policies with Base64 arguments. Select one complete LDIF
# record at a time; concatenating padded values can either fail decoding or make a
# decoder stop after the first policy and hide an incorrect second value. slapcat
# may canonicalize attribute-type casing inside DNs, so match that text case-insensitively.
for initial_backup_policy_dn in \
    'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' \
    'cn=DisabledPasswordPolicy,ou=Policies,DC=example,DC=com'; do
  if ! initial_backup_ppm_arg_base64=$(docker exec "$container" \
      awk -v target_dn="$initial_backup_policy_dn" '
        BEGIN { RS = ""; FS = "\n"; target_dn = tolower(target_dn) }
        {
          matches_dn = 0
          arg = ""
          for (i = 1; i <= NF; i++) {
            if (tolower($i) == "dn: " target_dn) matches_dn = 1
            line = $i
            if (line ~ /^pwdCheckModuleArg:: /) {
              sub(/^pwdCheckModuleArg:: /, "", line)
              arg = line
            }
          }
          if (matches_dn) {
            print arg
            found = 1
            exit
          }
        }
        END { if (!found) exit 1 }
      ' /var/lib/ldap/data.ldif); then
    echo "The initial backup does not contain policy [$initial_backup_policy_dn]." >&2
    exit 1
  fi
  if ! initial_backup_ppm_arg=$(printf '%s' "$initial_backup_ppm_arg_base64" | base64 -d); then
    echo "The initial backup contains an invalid PPM argument for [$initial_backup_policy_dn]." >&2
    exit 1
  fi
  if [[ $initial_backup_ppm_arg != "$native_ppm_config" ]]; then
    printf '%s\n' "$initial_backup_ppm_arg" >&2
    echo "The initial backup does not contain the reconciled PPM configuration for [$initial_backup_policy_dn]." >&2
    exit 1
  fi
done
if docker exec "$container" test -e "$initial_backup_pending_marker"; then
  echo "The completed initial backup still has a pending marker." >&2
  exit 1
fi

# The native configuration forbids @. The accepted replacement proves that PPM
# used the decoded text instead of only storing the environment value.
if docker exec "$container" \
    ldappasswd -x -H ldap://127.0.0.1 \
      -D "$guest_dn" -w changeit -s 'Strong1@' "$guest_dn" >/dev/null 2>&1; then
  echo "PPM accepted a character forbidden by LDAP_PPOLICY_PPM_CONFIG." >&2
  exit 1
fi
docker exec "$container" \
  ldappasswd -x -H ldap://127.0.0.1 \
    -D "$guest_dn" -w changeit -s 'Strong1!' "$guest_dn" >/dev/null

custom_entry=$(docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b "$custom_entry_dn" -s base '(objectClass=*)' description customBootstrapValue)
if [[ $custom_entry != *'description: loaded-in-filename-order'* ||
      $custom_entry != *'customBootstrapValue: schema-loaded-before-data'* ]]; then
  printf '%s\n' "$custom_entry" >&2
  echo "Custom schema and data LDIFs were not interpolated and loaded in order." >&2
  exit 1
fi

# Search below a known base so absence is an empty successful result; querying a
# missing sentinel DN directly would abort this set -e test before the assertion.
hidden_custom_entry=$(docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'DC=example,DC=com' -s one '(cn=hidden-custom-entry)' 1.1)
if [[ $hidden_custom_entry == *'dn: '* ]]; then
  printf '%s\n' "$hidden_custom_entry" >&2
  echo "A hidden custom initialization LDIF was loaded." >&2
  exit 1
fi

# Anonymous Root DSE access is intentional: clients need it to discover server
# capabilities before choosing how to bind. It must not extend to directory data.
anonymous_root_dse=$(docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -b '' -s base '(objectClass=*)' namingContexts)
if [[ $anonymous_root_dse != *'namingContexts:'* ]]; then
  echo "Anonymous clients cannot discover the naming context via the Root DSE." >&2
  exit 1
fi

# ACLs may hide the base with either an empty result or an LDAP error. Only
# returned entry data violates the policy, so tolerate the status and inspect LDIF.
anonymous_directory_output=$(docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -b 'DC=example,DC=com' -s base '(objectClass=*)' 1.1 2>/dev/null || true)
if [[ $anonymous_directory_output == *'dn: '* ]]; then
  echo "Anonymous clients can read the organization entry." >&2
  exit 1
fi

# Prove the same entry is readable after bind, so an unavailable directory cannot
# make the anonymous denial check pass accidentally.
docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'DC=example,DC=com' -s base '(objectClass=*)' 1.1 >/dev/null

# The GSSAPI package depends on the generic SASL module bundle. Assert the
# server-facing allowlist so that dependency cannot silently expose password or
# legacy mechanisms and change automatic client negotiation again.
# Docker Desktop and native pipeline tools can emit CRLF on Windows. Normalize
# at the capture boundary so the exact policy assertion is platform-independent.
sasl_mechanisms=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b '' -s base '(objectClass=*)' supportedSASLMechanisms |
  sed -n 's/^supportedSASLMechanisms: //p' |
  sort |
  tr -d '\015')
if [[ $sasl_mechanisms != $'EXTERNAL\nGSSAPI' ]]; then
  printf 'Unexpected SASL mechanisms:\n%s\n' "$sasl_mechanisms" >&2
  exit 1
fi

# Root reads the temporary log and acts on the PID, so neither may live under a
# directory the service account can modify between entrypoint operations.
if ! docker exec "$container" sh -c \
   'test "$(stat -c "%U:%G:%a" /run/slapd-init)" = root:root:700 && test -s /run/slapd-init/slapd.log'; then
   echo "Temporary slapd state is not isolated in a root-only directory." >&2
   exit 1
fi

# ==============================================================================
# Persisted PPM reconciliation and migration
# ==============================================================================

# Removing the flag represents a policy created before PPM support. The disabled
# policy was created during initialization so the same explicit opt-out is covered
# across both bootstrap and later global rule updates.
docker exec -i "$container" \
  ldapmodify -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" >/dev/null <<LDIF
dn: cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com
changetype: modify
delete: pwdUseCheckModule
LDIF

# Stop cleanly so the next start tests initialization state rather than MDB
# crash recovery, then attach a new container to the same persistent volumes.
docker exec -i "$container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<LDIF
dn: $ppolicy_dn
changetype: modify
replace: olcPPolicyCheckModule
olcPPolicyCheckModule: /usr/lib/ldap/pqchecker.so

# Set the size limit below the number of policies. Successful updates prove that
# this limit does not apply to the local reconciliation identity.
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSizeLimit
olcSizeLimit: 1
LDIF
# Set an old timestamp so the test can detect an unnecessary same-version marker
# write without depending on timestamp resolution or startup speed. Seed both
# fixed spool files to model a hard kill; the next reconciliation must replace and
# then remove them before the post-start cleanup assertion below.
docker exec "$container" sh -c '
  printf "%s\n" 2.6 > /etc/ldap/slapd.d/initialized
  touch -d @946684800 /etc/ldap/slapd.d/initialized
  mkdir -p /var/tmp/docker-openldap-ppm
  chown root:root /var/tmp/docker-openldap-ppm
  chmod 700 /var/tmp/docker-openldap-ppm
  printf "%s\n" stale-search > /var/tmp/docker-openldap-ppm/policy-entries.ldif
  printf "%s\n" stale-changes > /var/tmp/docker-openldap-ppm/policy-changes.ldif
'
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start_container --env 'LDAP_PPOLICY_PQCHECKER_RULE=0|02010101#'

wait_until_ready
if [[ $(docker logs "$container" 2>&1) == *"Applying initial configuration"* ]]; then
  echo "Existing LDAP volumes were unexpectedly reinitialized." >&2
  exit 1
fi
if [[ $(docker exec "$container" stat -c %Y /etc/ldap/slapd.d/initialized) != 946684800 ]]; then
  echo "A path-only PPM migration unnecessarily rewrote the configuration version marker." >&2
  exit 1
fi
if ! docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b "$ppolicy_dn" -s base '(objectClass=*)' olcPPolicyCheckModule |
      grep -F 'olcPPolicyCheckModule: /usr/lib/ldap/ppm.so' >/dev/null; then
  echo "The persisted pqChecker module path was not migrated to Debian PPM." >&2
  exit 1
fi

test_phase "Checking backup publication and recovery hardening"

# Fresh-volume initialization above already proves that run.sh consumes a pending
# marker and publishes its initial export. Exercise the remaining helper contracts
# in that running container so remote Docker engines cannot turn redundant LDAP
# restarts into multi-minute gaps with no test output.
test_step "Exercising backup functions in the running container"
docker exec "$container" bash -c '
  source /opt/bash-init.sh
  source /opt/backup.sh

  function backup_test_step() {
    printf "[%s]     %s\n" "$(date +%H:%M:%S)" "$1"
  }

  backup_test_step "Checking initial backup publication"
  # Point the destination at a root-owned image file so direct root output would
  # corrupt it. Atomic replacement must leave the symlink target unchanged. The
  # marked abandoned export and lookalike sibling bound crash cleanup precisely.
  build_info_checksum=$(sha256sum /opt/build_info)
  build_info_checksum=${build_info_checksum%% *}
  LDAP_BACKUP_FILE=/var/lib/ldap/initial-backup-symlink.ldif
  ln -sf /opt/build_info "$LDAP_BACKUP_FILE"
  install -d -m 0700 "$initial_backup_pending_marker"
  initial_directory=/var/lib/ldap/.initial-backup-symlink.ldif.tmp
  install -d -o openldap -g openldap -m 0700 "$initial_directory"
  install -o openldap -g openldap -m 0600 /dev/null \
    "$initial_directory/$ldap_backup_temporary_directory_marker"
  install -o openldap -g openldap -m 0600 /dev/null "$initial_directory/export.ABC123"
  printf "%s\n" abandoned >"$initial_directory/export.ABC123"
  install -o openldap -g openldap -m 0600 /dev/null \
    /var/lib/ldap/.initial-backup-symlink.ldif.tmp.KEEP01
  printf "%s\n" preserve >/var/lib/ldap/.initial-backup-symlink.ldif.tmp.KEEP01
  load_ldap_backup_state
  create_initial_ldap_backup

  current_build_info_checksum=$(sha256sum /opt/build_info)
  current_build_info_checksum=${current_build_info_checksum%% *}
  if [[ $current_build_info_checksum != "$build_info_checksum" ]] ||
      [[ ! -f $LDAP_BACKUP_FILE || -L $LDAP_BACKUP_FILE ]] ||
      ! grep -F "dn:" "$LDAP_BACKUP_FILE" >/dev/null ||
      [[ $(stat -c "%U:%G:%a" "$LDAP_BACKUP_FILE") != openldap:openldap:600 ]] ||
      [[ $(stat -c "%U:%G:%a" "$initial_directory/$ldap_backup_temporary_directory_marker") != openldap:openldap:600 ]] ||
      [[ -e $initial_directory/export.ABC123 ]] ||
      ! grep -Fx preserve /var/lib/ldap/.initial-backup-symlink.ldif.tmp.KEEP01 >/dev/null ||
      [[ -e $initial_backup_pending_marker ]]; then
    echo "The initial backup was unsafe, incomplete, or cleaned data outside its private temporary directory." >&2
    exit 1
  fi

  backup_test_step "Checking periodic backup publication"
  # Scheduler arithmetic is covered deterministically above. Invoke its writer
  # directly so this integration suite never waits for a future wall-clock minute.
  # The service-owned victim proves that privilege dropping alone is insufficient.
  periodic_victim=/etc/ldap/slapd.d/periodic-backup-victim
  periodic_backup=/var/lib/ldap/periodic-backup-symlink.ldif
  install -o openldap -g openldap -m 0600 /dev/null "$periodic_victim"
  printf "%s\n" periodic-victim >"$periodic_victim"
  ln -sf "$periodic_victim" "$periodic_backup"
  write_ldap_backup "$periodic_backup"
  if [[ ! -f $periodic_backup || -L $periodic_backup ]] ||
      ! grep -F "dn:" "$periodic_backup" >/dev/null ||
      ! grep -Fx periodic-victim "$periodic_victim" >/dev/null ||
      [[ $(stat -c "%U:%G:%a" "$periodic_backup") != openldap:openldap:600 ]]; then
    echo "The periodic backup followed a symlink or was not published as a private service-owned file." >&2
    exit 1
  fi

  backup_test_step "Checking temporary-directory recovery"
  unmarked_directory=/var/lib/ldap/.unmarked-backup.ldif.tmp
  install -d -o openldap -g openldap -m 0700 "$unmarked_directory"
  install -o openldap -g openldap -m 0600 /dev/null "$unmarked_directory/operator-data"
  printf "%s\n" preserve >"$unmarked_directory/operator-data"
  if unmarked_logs=$(prepare_ldap_backup_temporary_directory "$unmarked_directory" 2>&1) ||
      [[ $unmarked_logs != *"is not an initialized private directory; refusing to remove its contents"* ]] ||
      ! grep -Fx preserve "$unmarked_directory/operator-data" >/dev/null; then
    printf "%s\n" "$unmarked_logs" >&2
    echo "An unmarked backup temporary directory was accepted or modified." >&2
    exit 1
  fi

  # Validation must finish before cleanup, or traversal order could delete a
  # legitimate stale export before a later unexpected entry is rejected.
  mixed_directory=/var/lib/ldap/.mixed-backup.ldif.tmp
  install -d -o openldap -g openldap -m 0700 "$mixed_directory"
  install -o openldap -g openldap -m 0600 /dev/null \
    "$mixed_directory/$ldap_backup_temporary_directory_marker"
  install -o openldap -g openldap -m 0600 /dev/null "$mixed_directory/export.ABC123"
  install -o openldap -g openldap -m 0600 /dev/null "$mixed_directory/operator-data"
  printf "%s\n" stale >"$mixed_directory/export.ABC123"
  printf "%s\n" preserve >"$mixed_directory/operator-data"
  if mixed_logs=$(prepare_ldap_backup_temporary_directory "$mixed_directory" 2>&1) ||
      [[ $mixed_logs != *"Unexpected entry "* ]] ||
      ! grep -Fx stale "$mixed_directory/export.ABC123" >/dev/null ||
      ! grep -Fx preserve "$mixed_directory/operator-data" >/dev/null; then
    printf "%s\n" "$mixed_logs" >&2
    echo "Backup temporary-directory validation modified data before rejecting an unexpected entry." >&2
    exit 1
  fi

  # A crash can occur after mkdir but before marker creation. An empty private
  # directory is safe to adopt because no unknown data can be lost.
  recoverable_directory=/var/lib/ldap/.recoverable-backup.ldif.tmp
  install -d -o openldap -g openldap -m 0700 "$recoverable_directory"
  prepare_ldap_backup_temporary_directory "$recoverable_directory"
  if [[ $(stat -c "%U:%G:%a" "$recoverable_directory/$ldap_backup_temporary_directory_marker") != openldap:openldap:600 ]]; then
    echo "An interrupted empty backup directory was not safely initialized." >&2
    exit 1
  fi

  # Recovery is tied to the configured destination, not the daily schedule. It
  # must reclaim validated crash state even when no periodic worker will start.
  disabled_directory=/var/lib/ldap/.disabled-backup.ldif.tmp
  install -d -o openldap -g openldap -m 0700 "$disabled_directory"
  install -o openldap -g openldap -m 0600 /dev/null \
    "$disabled_directory/$ldap_backup_temporary_directory_marker"
  install -o openldap -g openldap -m 0600 /dev/null "$disabled_directory/export.ABC123"
  recover_interrupted_ldap_backup /var/lib/ldap/disabled-backup.ldif
  if [[ -e $disabled_directory/export.ABC123 ]]; then
    echo "Disabled-schedule recovery retained a stale export." >&2
    exit 1
  fi

  # Read and search permission is insufficient: root-owned mode 0755 passes find
  # on an empty directory but cannot hold the next service-owned export.
  install -d -m 0777 /tmp/openldap-backup
  install -d -m 0755 /tmp/openldap-backup/.unwritable-backup.ldif.tmp
  if unwritable_logs=$(check_ldap_backup_directory /tmp/openldap-backup/unwritable-backup.ldif 2>&1) ||
      [[ $unwritable_logs != *"must be owned by openldap with mode 0700"* ]]; then
    printf "%s\n" "$unwritable_logs" >&2
    echo "An unusable backup temporary directory passed validation." >&2
    exit 1
  fi

  backup_test_step "Checking configured-directory validation"
  # Call the same configuration boundary used by run.sh. It must reject a fixed
  # permission problem before starting the background scheduler.
  LDAP_BACKUP_TIME=00:00
  LDAP_BACKUP_FILE=/opt/root-only-backup.ldif
  if root_only_logs=$(configure_ldap_backup 2>&1) ||
      [[ $root_only_logs != *"LDAP backup directory [/opt] is not writable by openldap"* ]]; then
    printf "%s\n" "$root_only_logs" >&2
    echo "A root-only backup directory did not fail with the service-account diagnostic." >&2
    exit 1
  fi
'

default_policy_after_restart=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
disabled_policy_after_restart=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DisabledPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
default_ppm_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$default_policy_after_restart")
disabled_ppm_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$disabled_policy_after_restart")
default_ppm_arg=$(printf '%s' "$default_ppm_arg_base64" | base64 -d)
disabled_ppm_arg=$(printf '%s' "$disabled_ppm_arg_base64" | base64 -d)

if [[ $default_policy_after_restart != *'pwdUseCheckModule: TRUE'* ||
      $default_ppm_arg != *'class-upperCase ABCDEFGHIJKLMNOPQRSTUVWXYZ 2 0 0'* ||
      $default_ppm_arg != *'forbiddenChars #'* ]]; then
  printf '%s\n' "$default_policy_after_restart" >&2
  echo "A restart did not apply the updated compatibility rule to the default policy." >&2
  exit 1
fi
if [[ $disabled_policy_after_restart != *'pwdUseCheckModule: FALSE'* ||
      $disabled_ppm_arg != "$default_ppm_arg" ]]; then
  printf '%s\n' "$disabled_policy_after_restart" >&2
  echo "A restart did not update a disabled policy without changing its explicit opt-out." >&2
  exit 1
fi

# Both candidates satisfy every translated legacy rule except the uppercase
# minimum. Exercising PPM itself protects the pqChecker field-order translation,
# which a text comparison alone cannot prove.
if docker exec "$container" \
    ldappasswd -x -H ldap://127.0.0.1 \
      -D "$guest_dn" -w 'Strong1!' -s 'Again12!' "$guest_dn" >/dev/null 2>&1; then
  echo "PPM accepted a password below the translated uppercase minimum." >&2
  exit 1
fi
docker exec "$container" \
  ldappasswd -x -H ldap://127.0.0.1 \
    -D "$guest_dn" -w 'Strong1!' -s 'AGain12!' "$guest_dn" >/dev/null

# The entrypoint has no persisted root password on restart. Its local identity
# needs discovery access, but certificate-authenticated clients can map to the
# same DN, so both permissions must also require the private ldapi socket.
ppm_reconciliation_config=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcAccess olcLimits)
ppm_search_acl_count=$(count_normalized_config_values "$ppm_reconciliation_config" olcAccess "$ppm_search_acl")
ppm_write_acl_count=$(count_normalized_config_values "$ppm_reconciliation_config" olcAccess "$ppm_write_acl")
ppm_temporary_limits_count=$(count_normalized_config_values "$ppm_reconciliation_config" olcLimits "$ppm_temporary_limits")
if ((ppm_search_acl_count != 1 || ppm_write_acl_count != 1 || ppm_temporary_limits_count != 0)); then
  printf '%s\n' "$ppm_reconciliation_config" >&2
  echo "The PPM reconciler persisted an unsafe ACL or its temporary search limit." >&2
  exit 1
fi
# The reduced size limit above forces the disk-spooled retry path. Successful
# startup must leave only its root-owned namespace, not policy data that could
# accumulate across container restarts.
if ! docker exec "$container" sh -c '
    test "$(stat -c "%u:%g:%a" /var/tmp/docker-openldap-ppm)" = 0:0:700 &&
    test -z "$(find /var/tmp/docker-openldap-ppm -mindepth 1 -maxdepth 1 -print -quit)"
  '; then
  echo "The PPM reconciler left an unsafe directory or stale spool data." >&2
  exit 1
fi

# Keep the reduced limit local to the regression above; later checks exercise
# ordinary client behavior and should continue using the image default.
docker exec -i "$container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<'LDIF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSizeLimit
olcSizeLimit: 500
LDIF

# Put an operator rule ahead of both image-owned rules. It denies only the local
# maintenance identity, while `by * break` leaves the existing ACL chain intact
# for clients. The next start must repair the managed prefix instead of treating
# matching-but-displaced rules as usable or deleting the operator's rule.
docker exec -i "$container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<LDIF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {0}$ppm_blocking_acl
LDIF

# Native PPM text is also a per-start setting. Keep an invalid legacy rule beside
# it so this restart covers precedence as well as automatic base64 conversion.
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start_container \
  --env LDAP_PPOLICY_PPM_CONFIG="$restart_native_ppm_config" \
  --env 'LDAP_PPOLICY_PQCHECKER_RULE=1|ignored'
wait_until_ready

ppm_access_after_order_repair=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcAccess)
ppm_search_acl_at_zero=$(count_normalized_config_values \
  "$ppm_access_after_order_repair" olcAccess "$ppm_search_acl" 0)
ppm_write_acl_at_one=$(count_normalized_config_values \
  "$ppm_access_after_order_repair" olcAccess "$ppm_write_acl" 1)
ppm_blocking_acl_count=$(count_normalized_config_values \
  "$ppm_access_after_order_repair" olcAccess "$ppm_blocking_acl")
if ((ppm_search_acl_at_zero != 1 || ppm_write_acl_at_one != 1 || ppm_blocking_acl_count != 1)); then
  printf '%s\n' "$ppm_access_after_order_repair" >&2
  echo "The PPM reconciler did not repair displaced ACLs without losing the operator rule." >&2
  exit 1
fi

default_policy_after_native_restart=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
disabled_policy_after_native_restart=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DisabledPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
default_native_ppm_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$default_policy_after_native_restart")
disabled_native_ppm_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$disabled_policy_after_native_restart")
default_native_ppm_arg=$(printf '%s' "$default_native_ppm_arg_base64" | base64 -d)
disabled_native_ppm_arg=$(printf '%s' "$disabled_native_ppm_arg_base64" | base64 -d)

if [[ $default_policy_after_native_restart != *'pwdUseCheckModule: TRUE'* ||
      $default_native_ppm_arg != "$restart_native_ppm_config" ]]; then
  printf '%s\n' "$default_policy_after_native_restart" >&2
  echo "A restart did not apply the native PPM configuration to the default policy." >&2
  exit 1
fi
if [[ $disabled_policy_after_native_restart != *'pwdUseCheckModule: FALSE'* ||
      $disabled_native_ppm_arg != "$restart_native_ppm_config" ]]; then
  printf '%s\n' "$disabled_policy_after_native_restart" >&2
  echo "A native PPM restart changed a policy's explicit opt-out." >&2
  exit 1
fi

# An operator may independently configure the same unlimited peercred rule. Its
# text is indistinguishable from the temporary rule, so absence of the image's
# ownership marker must keep it intact even while PPM updates are disabled.
ppm_limits_before_native_opt_out=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcLimits)
ppm_temporary_limits_count=$(count_normalized_config_values \
  "$ppm_limits_before_native_opt_out" olcLimits "$ppm_temporary_limits")
if ((ppm_temporary_limits_count == 0)); then
  docker exec -i "$container" \
    ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<LDIF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcLimits
olcLimits: {0}$ppm_temporary_limits
LDIF
fi

# A data-volume writer must not be able to authorize deletion from cn=config.
# Leave a marker at the retired location so this restart distinguishes storage
# ownership from marker syntax instead of merely testing for no marker at all.
docker exec "$container" mkdir "$ppm_legacy_data_marker"
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start_container \
  --env LDAP_PPOLICY_PPM_CONFIG= \
  --env 'LDAP_PPOLICY_PQCHECKER_RULE=0|01010101@'
wait_until_ready

ppm_limits_after_native_opt_out=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcLimits)
ppm_temporary_limits_count=$(count_normalized_config_values \
  "$ppm_limits_after_native_opt_out" olcLimits "$ppm_temporary_limits")
if ((ppm_temporary_limits_count != 1)) ||
    ! docker exec "$container" test -d "$ppm_legacy_data_marker"; then
  printf '%s\n' "$ppm_limits_after_native_opt_out" >&2
  echo "A data-volume marker authorized deletion of an operator-owned limit." >&2
  exit 1
fi
docker exec "$container" rmdir "$ppm_legacy_data_marker"

# The configuration-volume marker changes only ownership, not LDAP text. Treat
# the surviving rule as one left by an interrupted image start and verify that
# the next start removes both pieces of state, even with PPM updates disabled.
docker exec "$container" mkdir "$ppm_temporary_limits_marker"
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start_container \
  --env LDAP_PPOLICY_PPM_CONFIG= \
  --env 'LDAP_PPOLICY_PQCHECKER_RULE=0|01010101@'
wait_until_ready

ppm_limits_after_owned_cleanup=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcLimits)
ppm_temporary_limits_count=$(count_normalized_config_values \
  "$ppm_limits_after_owned_cleanup" olcLimits "$ppm_temporary_limits")
if ((ppm_temporary_limits_count != 0)) ||
    docker exec "$container" test -e "$ppm_temporary_limits_marker"; then
  printf '%s\n' "$ppm_limits_after_owned_cleanup" >&2
  echo "An explicit PPM opt-out retained image-owned temporary limit state." >&2
  exit 1
fi

# Empty is an explicit native opt-out, not absence. A conflicting nonempty
# legacy rule must therefore leave both persisted policy values untouched.
default_policy_after_native_opt_out=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
disabled_policy_after_native_opt_out=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DisabledPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
default_opt_out_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$default_policy_after_native_opt_out")
disabled_opt_out_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$disabled_policy_after_native_opt_out")
default_opt_out_arg=$(printf '%s' "$default_opt_out_arg_base64" | base64 -d)
disabled_opt_out_arg=$(printf '%s' "$disabled_opt_out_arg_base64" | base64 -d)

if [[ $default_policy_after_native_opt_out != *'pwdUseCheckModule: TRUE'* ||
      $disabled_policy_after_native_opt_out != *'pwdUseCheckModule: FALSE'* ||
      $default_opt_out_arg != "$restart_native_ppm_config" ||
      $disabled_opt_out_arg != "$restart_native_ppm_config" ]]; then
  printf '%s\n%s\n' "$default_policy_after_native_opt_out" "$disabled_policy_after_native_opt_out" >&2
  echo "An empty native PPM setting did not override the compatibility rule." >&2
  exit 1
fi

# An empty legacy setting normally disables updates. During migration from the old
# pqChecker path, add the old defaults only where native settings are missing.
# Leave the disabled policy's existing values unchanged.
docker exec -i "$container" \
  ldapmodify -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" >/dev/null <<'LDIF'
dn: cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com
changetype: modify
delete: pwdUseCheckModule
-
delete: pwdCheckModuleArg
LDIF
docker exec -i "$container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<LDIF
dn: $ppolicy_dn
changetype: modify
replace: olcPPolicyCheckModule
olcPPolicyCheckModule: /usr/lib/ldap/pqchecker.so
LDIF
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start_container --fail-ppm-reconcile --env LDAP_PPOLICY_PQCHECKER_RULE=

# Pause at the first policy update. Keep the old module path until all updates
# succeed, so the next start knows to retry. The temporary server must not expose
# LDAP.
for _ in {1..120}; do
  if docker exec "$container" test -e /run/ppm-reconcile-blocked 2>/dev/null; then
    break
  fi
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done
if ! docker exec "$container" test -e /run/ppm-reconcile-blocked 2>/dev/null; then
  docker logs "$container" >&2
  echo "The injected PPM reconciliation failure was not reached." >&2
  exit 1
fi
if ! docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b "$ppolicy_dn" -s base '(objectClass=*)' olcPPolicyCheckModule |
      grep -F 'olcPPolicyCheckModule: /usr/lib/ldap/pqchecker.so' >/dev/null; then
  echo "A partial PPM migration discarded the module-path retry signal." >&2
  exit 1
fi
if docker exec "$container" ldapwhoami -x -H ldap://127.0.0.1 >/dev/null 2>&1; then
  echo "The temporary migration daemon exposed an LDAP network listener." >&2
  exit 1
fi

docker exec "$container" touch /run/ppm-reconcile-release
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done
failed_ppm_logs=$(docker logs "$container" 2>&1)
if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] ||
    [[ $(docker inspect --format '{{.State.ExitCode}}' "$container") == 0 ]] ||
    [[ $failed_ppm_logs != *'Cannot reconcile Debian PPM policy attributes.'* ]]; then
  printf '%s\n' "$failed_ppm_logs" >&2
  echo "The injected PPM reconciliation failure did not stop startup." >&2
  exit 1
fi

# Retry with a new container, without the test wrapper, and reuse the partially
# migrated volumes. This checks that startup reads migration state from stored
# configuration.
docker rm "$container" >/dev/null
start_container --env LDAP_PPOLICY_PQCHECKER_RULE=
wait_until_ready
if ! docker exec "$container" grep -Fx '2.6' /etc/ldap/slapd.d/initialized >/dev/null; then
  echo "The PPM migration changed the established configuration version marker." >&2
  exit 1
fi
if ! docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b "$ppolicy_dn" -s base '(objectClass=*)' olcPPolicyCheckModule |
      grep -F 'olcPPolicyCheckModule: /usr/lib/ldap/ppm.so' >/dev/null; then
  echo "The empty-rule migration left the retired pqChecker module path in place." >&2
  exit 1
fi

default_policy_after_empty_migration=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
disabled_policy_after_empty_migration=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DisabledPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdUseCheckModule pwdCheckModuleArg)
default_empty_migration_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$default_policy_after_empty_migration")
disabled_empty_migration_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$disabled_policy_after_empty_migration")
default_empty_migration_arg=$(printf '%s' "$default_empty_migration_arg_base64" | base64 -d)
disabled_empty_migration_arg=$(printf '%s' "$disabled_empty_migration_arg_base64" | base64 -d)

if [[ $default_policy_after_empty_migration != *'pwdUseCheckModule: TRUE'* ||
      $default_empty_migration_arg != *'class-upperCase ABCDEFGHIJKLMNOPQRSTUVWXYZ 1 0 0'* ||
      $default_empty_migration_arg == *'forbiddenChars '* ]]; then
  printf '%s\n' "$default_policy_after_empty_migration" >&2
  echo "An empty-rule pqChecker migration did not fill missing PPM attributes with the old default." >&2
  exit 1
fi
if [[ $disabled_policy_after_empty_migration != *'pwdUseCheckModule: FALSE'* ||
      $disabled_empty_migration_arg != "$disabled_opt_out_arg" ]]; then
  printf '%s\n' "$disabled_policy_after_empty_migration" >&2
  echo "An empty-rule pqChecker migration overwrote existing native PPM attributes." >&2
  exit 1
fi

test_step "Resetting volumes for invalid-configuration checks"
# Persistence behavior was verified before this phase, and these volumes are
# discarded next. Forced removal avoids another graceful-shutdown wait here.
docker rm --force "$container" >/dev/null
docker volume rm "$config_volume" "$data_volume" >/dev/null
}
