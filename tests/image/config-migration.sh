#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Configuration migration checks. This file is sourced by test-image.sh so it can
# reuse the current image name and readiness helper.

# shellcheck disable=SC2154  # image_name and test_phase are supplied by test-image.sh.
function test_config_migration_functions() {
  test_phase "Checking configuration migration recovery guards"

  docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/config-migration.sh

    fixture_root=$(run_as_openldap mktemp -d -- /tmp/config-migration-test.XXXXXX)
    trap "run_as_openldap rm -rf -- \"$fixture_root\"" EXIT
    config_migration_root=$fixture_root
    config_migration_journal=$config_migration_root/.upgrade-legacy-ppolicy
    config_migration_state_file=$config_migration_journal/state

    run_as_openldap mkdir -m 0700 -- "$config_migration_journal"
    printf "%s\n" operator-data |
      run_as_openldap tee -- "$config_migration_journal/do-not-delete" >/dev/null
    # A fixed private-looking pathname is not enough proof that recursive cleanup
    # owns its contents. Unknown state must fail closed and leave the data intact.
    if config_migration_recover_if_needed; then
      echo "Recovery accepted an unmarked nonempty migration journal." >&2
      exit 1
    fi
    test -f "$config_migration_journal/do-not-delete"
    run_as_openldap rm -rf -- "$config_migration_journal"

    # mkdir and state publication are separate operations. An empty directory is
    # the only no-state interruption that can be reclaimed without guessing.
    run_as_openldap mkdir -m 0700 -- "$config_migration_journal"
    config_migration_recover_if_needed
    test ! -e "$config_migration_journal"

    run_as_openldap mkdir -m 0700 -- "$config_migration_journal"
    config_migration_publish_state preparing
    run_as_openldap mkdir -m 0700 -- "$config_migration_journal/working"
    run_as_openldap touch -- "$config_migration_journal/working/partial-copy"
    config_migration_recover_if_needed
    test ! -e "$config_migration_journal"

    run_as_openldap mkdir -m 0700 -- "$config_migration_journal"
    config_migration_publish_state preparing
    run_as_openldap touch -- "$config_migration_journal/operator-data"
    if config_migration_recover_if_needed; then
      echo "Recovery deleted an unexpected entry from a recognized journal." >&2
      exit 1
    fi
    test -f "$config_migration_journal/operator-data"
    run_as_openldap rm -rf -- "$config_migration_journal"

    marker_file=$config_migration_root/initialized
    printf "2.4\n" | run_as_openldap tee -- "$marker_file" >/dev/null
    # The published 2.4.x image writes marker 1. A literal version label is an
    # unknown marker and must not enter only the first half of the migration.
    config_migration_find_legacy_ppolicy_schema() { return 99; }
    migrate_legacy_ppolicy_schema "$marker_file"
  '
}

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_legacy_ppolicy_schema_migration_from_openldap_24() {
(
  local legacy_image=ghcr.io/vegardit/openldap:2.4.x
  local legacy_container="$test_id-openldap-24"
  local migrated_container="$test_id-openldap-24-migrated"
  local migration_config_volume="$test_id-openldap-24-config"
  local migration_data_volume="$test_id-openldap-24-data"
  local legacy_root_dn='uid=admin,o=example.com'
  local legacy_root_password='test-only-legacy-password'
  local migration_logs
  local schema_config
  local sentinel

  # shellcheck disable=SC2329  # Invoked indirectly by the subshell EXIT trap.
  function cleanup_legacy_ppolicy_migration_fixture() {
    docker rm --force "$legacy_container" "$migrated_container" >/dev/null 2>&1 || true
    docker volume rm --force \
      "$migration_config_volume" "$migration_data_volume" >/dev/null 2>&1 || true
  }
  trap cleanup_legacy_ppolicy_migration_fixture EXIT

  test_phase "Checking OpenLDAP 2.4 to 2.6 configuration migration"
  docker volume create "$migration_config_volume" >/dev/null
  docker volume create "$migration_data_volume" >/dev/null

  docker create --name "$legacy_container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW="$legacy_root_password" \
    --mount "type=volume,src=$migration_config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$migration_data_volume,dst=/var/lib/ldap" \
    "$legacy_image" >/dev/null
  docker start "$legacy_container" >/dev/null

  test_step "Initializing the published 2.4.x image"
  # The 2.4 entrypoint exposes a temporary slapd while it imports bootstrap LDIFs.
  # Require its final-start log marker so the persisted fixture is never partial.
  wait_until_ready "$legacy_container"

  if ! docker exec "$legacy_container" grep -R -Fq \
      '1.3.6.1.4.1.42.2.27.8.1.1' \
      '/etc/ldap/slapd.d/cn=config/cn=schema'; then
    docker logs "$legacy_container" >&2
    echo "The published 2.4.x fixture does not contain the expected external ppolicy schema." >&2
    exit 1
  fi

  test_step "Adding data that must survive the upgrade"
  if ! docker exec -i "$legacy_container" \
      ldapadd -x -H ldap://127.0.0.1 \
        -D "$legacy_root_dn" -w "$legacy_root_password" <<'LDIF'
dn: cn=migration-regression,o=example.com
objectClass: organizationalRole
cn: migration-regression
description: persisted-across-openldap-upgrade
LDIF
  then
    docker logs "$legacy_container" >&2
    echo "Cannot add the legacy ppolicy migration sentinel." >&2
    exit 1
  fi

  docker stop "$legacy_container" >/dev/null
  docker rm "$legacy_container" >/dev/null
  docker create --name "$migrated_container" \
    --env LDAP_BACKUP_TIME= \
    --mount "type=volume,src=$migration_config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$migration_data_volume,dst=/var/lib/ldap" \
    "$image_name" >/dev/null

  test_step "Starting the current image with 2.4.x volumes"
  docker start "$migrated_container" >/dev/null
  wait_until_ready "$migrated_container"
  migration_logs=$(docker logs "$migrated_container" 2>&1)
  if [[ $migration_logs != *'Migrating legacy ppolicy schema for OpenLDAP 2.6'* ]] ||
      [[ $migration_logs != *'Finalized the legacy ppolicy schema migration'* ]]; then
    printf '%s\n' "$migration_logs" >&2
    echo "The legacy ppolicy schema migration did not report completion." >&2
    exit 1
  fi

  if [[ $(docker exec "$migrated_container" cat /etc/ldap/slapd.d/initialized) != 2.6 ]] ||
      docker exec "$migrated_container" test -e /etc/ldap/slapd.d/.upgrade-legacy-ppolicy; then
    docker logs "$migrated_container" >&2
    echo "The legacy ppolicy schema migration did not commit and clean its journal." >&2
    exit 1
  fi

  schema_config=$(docker exec "$migrated_container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'cn=schema,cn=config' -s one '(objectClass=olcSchemaConfig)' dn olcAttributeTypes)
  if [[ $schema_config == *'1.3.6.1.4.1.42.2.27.8.1.1'* ]] ||
      [[ $schema_config == *'cn={4}ppolicy,cn=schema,cn=config'* ]] ||
      [[ $schema_config != *'sudo,cn=schema,cn=config'* ]] ||
      [[ $schema_config != *'openssh-lpk,cn=schema,cn=config'* ]]; then
    printf '%s\n' "$schema_config" >&2
    echo "The migrated schema tree is missing retained schemas or still contains external ppolicy." >&2
    exit 1
  fi

  sentinel=$(docker exec "$migrated_container" \
    ldapsearch -LLL -x -H ldap://127.0.0.1 \
      -D "$legacy_root_dn" -w "$legacy_root_password" \
      -b 'cn=migration-regression,o=example.com' -s base description)
  if [[ $sentinel != *'description: persisted-across-openldap-upgrade'* ]]; then
    printf '%s\n' "$sentinel" >&2
    echo "Directory data did not survive the legacy ppolicy schema migration." >&2
    exit 1
  fi

  if ! docker exec --user openldap "$migrated_container" \
      slaptest -u -F /etc/ldap/slapd.d >/dev/null; then
    docker logs "$migrated_container" >&2
    echo "The migrated cn=config fails slaptest." >&2
    exit 1
  fi

  test_step "Restarting the migrated configuration"
  docker restart "$migrated_container" >/dev/null
  wait_until_ready "$migrated_container"
  if docker logs "$migrated_container" 2>&1 |
      grep -Fq 'Duplicate attributeType: "1.3.6.1.4.1.42.2.27.8.1.1"'; then
    docker logs "$migrated_container" >&2
    echo "The migrated configuration regressed to the external ppolicy schema." >&2
    exit 1
  fi
)
}
