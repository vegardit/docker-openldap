#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

set -euo pipefail

image_name=${1:?Usage: test-image.sh IMAGE}
test_id="openldap-bootstrap-$$-$RANDOM"
container="$test_id-container"
config_volume="$test_id-config"
data_volume="$test_id-data"

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
function cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  docker volume rm --force "$config_volume" "$data_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for volume in "$config_volume" "$data_volume"; do
  docker volume create "$volume" >/dev/null
  # Reproduce fresh ext-backed mounts whose filesystem metadata makes `ls`
  # non-empty before the application has written anything.
  docker run --rm \
    --mount "type=volume,src=$volume,dst=/mnt" \
    "$image_name" mkdir /mnt/lost+found
done

docker run --detach --name "$container" \
  --env LDAP_BACKUP_TIME= \
  --env LDAP_INIT_ROOT_USER_PW=test-only-password \
  --mount "type=volume,src=$config_volume,dst=/etc/ldap/slapd.d" \
  --mount "type=volume,src=$data_volume,dst=/var/lib/ldap" \
  "$image_name" >/dev/null

# Initialization starts a temporary slapd first; wait for the final service
# instead of treating that intermediate socket as success.
for _ in {1..120}; do
  container_logs=$(docker logs "$container" 2>&1)
  if [[ $container_logs == *"Starting OpenLDAP: slapd..."* ]] && \
      docker exec "$container" ldapwhoami -H ldapi:/// >/dev/null 2>&1; then
    docker exec "$container" test -f /etc/ldap/slapd.d/cn=config.ldif
    docker exec "$container" test -s /var/lib/ldap/data.mdb
    docker exec "$container" test -d /etc/ldap/slapd.d/lost+found
    docker exec "$container" test -d /var/lib/ldap/lost+found
    exit 0
  fi
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done

docker logs "$container" >&2
exit 1
