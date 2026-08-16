#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# startup validation and Root DSE checks.
# This file is sourced by test-image.sh and intentionally shares its fixtures,
# helpers, and cleanup trap so scenario boundaries do not create extra Docker
# resources or alter lifecycle ordering.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_startup_validation() {
# ==============================================================================
# Startup validation and Root DSE behavior
# ==============================================================================

create_fresh_volumes

test_phase "Checking invalid startup configuration"

# A file mounted at the public directory path is almost always a Compose typo.
# Reject it before slapd starts so the same volumes remain safe for a corrected retry.
start_container --schema-path-file
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done
if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]]; then
  docker logs "$container" >&2
  echo "A non-directory custom schema path did not stop the container." >&2
  exit 1
fi

failure_logs=$(docker logs "$container" 2>&1)
if [[ $(docker inspect --format '{{.State.ExitCode}}' "$container") == 0 ]] || \
    [[ $failure_logs != *"[/opt/ldifs/custom-schema] must be a directory"* ]]; then
  printf '%s\n' "$failure_logs" >&2
  echo "A non-directory custom schema path did not report the expected failure." >&2
  exit 1
fi
if [[ $failure_logs == *"Starting slapd for init/migration..."* ]]; then
  printf '%s\n' "$failure_logs" >&2
  echo "LDAP initialization started before custom schema path validation completed." >&2
  exit 1
fi

docker rm "$container" >/dev/null
# A bad organization DN must fail before non-idempotent LDAP changes, leaving
# the seeded volumes safe for a corrected retry.
start_container --env LDAP_INIT_ORG_DN=invalid
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done
if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]]; then
  docker logs "$container" >&2
  echo "Invalid LDAP_INIT_ORG_DN did not stop the container." >&2
  exit 1
fi

failure_logs=$(docker logs "$container" 2>&1)
if [[ $(docker inspect --format '{{.State.ExitCode}}' "$container") == 0 ]] || \
    [[ $failure_logs != *"Unable to derive required 'o' attribute"* ]]; then
  printf '%s\n' "$failure_logs" >&2
  echo "Invalid LDAP_INIT_ORG_DN did not report the expected failure." >&2
  exit 1
fi
if [[ $failure_logs == *"Starting slapd for init/migration..."* ]]; then
  printf '%s\n' "$failure_logs" >&2
  echo "LDAP initialization started before organization validation completed." >&2
  exit 1
fi

docker rm "$container" >/dev/null

# The replication provider later checks that zero-padded 0128 is accepted. Keep
# this invalid value with the other public environment validation tests.
invalid_tls_ssf_logs=
if invalid_tls_ssf_logs=$(docker run --rm \
    --env LDAP_TLS_ENABLED=true \
    --env LDAP_TLS_SSF=0257 \
    "$image_name" 2>&1); then
  echo "An out-of-range LDAP_TLS_SSF unexpectedly started the container." >&2
  exit 1
fi
if [[ $invalid_tls_ssf_logs != *"LDAP_TLS_SSF must be an integer between 0 and 256 (got '0257')"* ]]; then
  printf '%s\n' "$invalid_tls_ssf_logs" >&2
  echo "A zero-padded out-of-range LDAP_TLS_SSF was not rejected." >&2
  exit 1
fi

# An explicit empty value is different from an omitted variable. Reject it so
# an empty Compose or env-file substitution cannot silently retain anonymous access.
start_container --env LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE=
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    break
  fi
  sleep 0.5
done
if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]]; then
  docker logs "$container" >&2
  echo "Empty LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE did not stop the container." >&2
  exit 1
fi

failure_logs=$(docker logs "$container" 2>&1)
if [[ $(docker inspect --format '{{.State.ExitCode}}' "$container") == 0 ]] || \
    [[ $failure_logs != *"LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE must be true|false"* ]]; then
  printf '%s\n' "$failure_logs" >&2
  echo "Empty LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE did not report the expected failure." >&2
  exit 1
fi
# Validation must precede the non-idempotent LDAP changes so these volumes remain
# safe for the corrected retry below.
if [[ $failure_logs == *"Starting slapd for init/migration..."* ]]; then
  printf '%s\n' "$failure_logs" >&2
  echo "LDAP initialization started before Root DSE policy validation completed." >&2
  exit 1
fi

docker rm "$container" >/dev/null
start_container --env LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE=false
wait_until_ready
docker exec "$container" test -f /etc/ldap/slapd.d/initialized

# The opt-out changes only Root DSE visibility. LDAP servers may hide a denied
# base with an empty result or an error, so inspect returned data instead of status.
anonymous_root_dse=$(docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -b '' -s base '(objectClass=*)' namingContexts 2>/dev/null || true)
if [[ $anonymous_root_dse == *'namingContexts:'* ]]; then
  echo "LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE=false still exposes Root DSE data anonymously." >&2
  exit 1
fi

# Prove the option did not remove the `auth` privilege needed to establish an
# identity and that the same Root DSE remains visible after a password bind.
authenticated_root_dse=$(docker exec "$container" \
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -D 'uid=employee1,ou=Internal,ou=Users,DC=example,DC=com' -w changeit \
    -b '' -s base '(objectClass=*)' namingContexts)
if [[ $authenticated_root_dse != *'namingContexts:'* ]]; then
  echo "Authenticated clients cannot read the Root DSE after anonymous access is disabled." >&2
  exit 1
fi

# entryCSN and entryUUID support syncrepl searches but add write and storage cost
# to every database entry, so ordinary deployments must not inherit them.
ordinary_indexes=$(docker exec "$container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base olcDbIndex)
if [[ $ordinary_indexes == *"entryCSN,entryUUID eq"* ]]; then
  printf '%s\n' "$ordinary_indexes" >&2
  echo "A non-replicating server has syncrepl-only indexes." >&2
  exit 1
fi
}
