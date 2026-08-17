#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Configuration-version marker privilege-boundary and publication regressions.
# This file is sourced by test-image.sh and uses a subshell-local cleanup trap so
# its deliberately failed final start cannot affect the shared LDAP fixtures.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_version_marker_security() {
(
  local marker_container="$test_id-version-marker"
  local marker_config_volume="$test_id-version-marker-config"
  local marker_data_volume="$test_id-version-marker-data"
  local root_marker_secret=marker-root-read-sentinel
  local root_marker_logs

  # shellcheck disable=SC2329  # Invoked indirectly by the subshell EXIT trap.
  function cleanup_version_marker_fixture() {
    docker rm --force "$marker_container" >/dev/null 2>&1 || true
    docker volume rm --force \
      "$marker_config_volume" "$marker_data_volume" >/dev/null 2>&1 || true
  }
  trap cleanup_version_marker_fixture EXIT

  test_phase "Checking configuration version marker hardening"
  docker volume create "$marker_config_volume" >/dev/null
  docker volume create "$marker_data_volume" >/dev/null

  # Seed the normal packaged state before adding a dangling marker. Leaving only
  # the symlink would make the entrypoint reject an unseeded cn=config before it
  # reaches the publication path that this scenario is intended to exercise.
  docker run --rm --entrypoint sh \
    --mount "type=volume,src=$marker_config_volume,dst=/mnt/config" \
    --mount "type=volume,src=$marker_data_volume,dst=/mnt/data" \
    "$image_name" -eu -c '
      cp -r --preserve=all /etc/ldap/slapd.d_orig/. /mnt/config
      cp -r --preserve=all /var/lib/ldap_orig/. /mnt/data
      ln -s /root/fresh-version-marker-target /mnt/config/initialized
    '

  docker create --name "$marker_container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW="$root_password" \
    --mount "type=volume,src=$marker_config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$marker_data_volume,dst=/var/lib/ldap" \
    "$image_name" >/dev/null
  test_step "Publishing the fresh-initialization marker"
  docker start "$marker_container" >/dev/null
  wait_until_ready "$marker_container"

  # A dangling link is absent to test -e, so initialization is expected to run.
  # Publication must replace that directory entry rather than create its target.
  if docker exec "$marker_container" test -e /root/fresh-version-marker-target ||
      docker exec "$marker_container" test -L /etc/ldap/slapd.d/initialized ||
      ! docker exec "$marker_container" test -f /etc/ldap/slapd.d/initialized ||
      [[ $(docker exec "$marker_container" cat /etc/ldap/slapd.d/initialized) != 2.6 ]] ||
      [[ $(docker exec "$marker_container" stat -c '%U:%G:%a' /etc/ldap/slapd.d/initialized) != openldap:openldap:600 ]]; then
    docker logs "$marker_container" >&2
    echo "Fresh initialization followed the marker link or did not publish private service-owned state." >&2
    exit 1
  fi

  # Initialization and migration share the publisher. The persisted-consumer
  # restart in tests/image/replication.sh proves next-start service-account
  # readability without another container cycle here.
  # /var/tmp is traversable while this file remains root-owned and non-writable by
  # openldap. The reader may follow the link, but the publisher must atomically
  # replace it instead of truncating the root-owned target. A 2.5 marker requests
  # the existing PPM migration path.
  docker exec "$marker_container" bash -euo pipefail -c '
    printf "%s\n" 2.5 >/var/tmp/migration-version-marker-target
    chmod 0644 /var/tmp/migration-version-marker-target
    rm -f /etc/ldap/slapd.d/initialized
    ln -s /var/tmp/migration-version-marker-target /etc/ldap/slapd.d/initialized
  '
  test_step "Publishing the migrated marker"
  docker restart "$marker_container" >/dev/null
  wait_until_ready "$marker_container"
  if [[ $(docker exec "$marker_container" cat /var/tmp/migration-version-marker-target) != 2.5 ]] ||
      docker exec "$marker_container" test -L /etc/ldap/slapd.d/initialized ||
      [[ $(docker exec "$marker_container" cat /etc/ldap/slapd.d/initialized) != 2.6 ]] ||
      [[ $(docker exec "$marker_container" stat -c '%U:%G:%a' /etc/ldap/slapd.d/initialized) != openldap:openldap:600 ]]; then
    docker logs "$marker_container" >&2
    echo "Migration followed the marker link or did not atomically publish the new version." >&2
    exit 1
  fi

  # Run the root-only read case last because the secure behavior intentionally
  # aborts this container. The fixed sentinel makes any disclosure unambiguous.
  docker exec "$marker_container" bash -euo pipefail -c '
    printf "%s\n" "$1" >/root/root-only-version-marker-target
    chmod 0600 /root/root-only-version-marker-target
    rm -f /etc/ldap/slapd.d/initialized
    ln -s /root/root-only-version-marker-target /etc/ldap/slapd.d/initialized
  ' -- "$root_marker_secret"
  test_step "Rejecting a root-only marker target"
  docker restart "$marker_container" >/dev/null
  for _ in {1..80}; do
    if [[ $(docker inspect --format '{{.State.Running}}' "$marker_container") != true ]]; then
      break
    fi
    sleep 0.25
  done

  root_marker_logs=$(docker logs "$marker_container" 2>&1)
  if [[ $(docker inspect --format '{{.State.Running}}' "$marker_container") == true ]] ||
      [[ $(docker inspect --format '{{.State.ExitCode}}' "$marker_container") == 0 ]] ||
      [[ $root_marker_logs == *"$root_marker_secret"* ]] ||
      [[ $root_marker_logs != *'Cannot read configuration version marker'* ]]; then
    printf '%s\n' "$root_marker_logs" >&2
    echo "A root-only marker target did not fail closed without exposing its contents." >&2
    exit 1
  fi
)
}
