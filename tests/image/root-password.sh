#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Root-password secret integration checks. This file is sourced by test-image.sh
# and uses its container names, temporary directory, and readiness helper.

function assert_root_password_container_rejected() {
  local root_password_container=$1
  local expected_message=$2
  local rejected_case=$3
  local container_running=true
  local exit_code
  local output

  # Successful initialization keeps slapd in the foreground. Bound this wait so
  # a missing fail-closed check becomes a useful assertion instead of a hung suite.
  for _ in {1..40}; do
    container_running=$(docker inspect --format '{{.State.Running}}' "$root_password_container")
    [[ $container_running == false ]] && break
    sleep 0.25
  done
  output=$(docker logs "$root_password_container" 2>&1)
  if [[ $container_running == true ]]; then
    docker rm --force --volumes "$root_password_container" >/dev/null
    printf '%s\n' "$output" >&2
    echo "$rejected_case unexpectedly continued initialization." >&2
    return 1
  fi

  exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$root_password_container")
  docker rm --force --volumes "$root_password_container" >/dev/null
  if [[ $exit_code == 0 || $output != *"$expected_message"* ||
        $output == *"Starting slapd for init/migration..."* ]]; then
    printf '%s\n' "$output" >&2
    echo "$rejected_case did not fail before LDAP initialization." >&2
    return 1
  fi
}

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_root_password_file() {
  local container_logs
  local docker_generated_secret_dir
  local generated_example_dir="$test_dir/root-password/generated-example"
  # shellcheck disable=SC2016  # Literal placeholder text must bypass interpolation.
  local root_password_secret='test-only ${literal} admin "secret" \ path'

  test_phase "Checking root password file handling"
  mkdir -p "$root_password_secret_dir"

  # An explicitly selected file is authoritative. Falling back to a stale
  # environment password would initialize the directory with unintended access.
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW=stale-environment-password \
    --env LDAP_INIT_ROOT_USER_PW_FILE=/run/secrets/missing-admin-password \
    "$image_name" >/dev/null
  docker start "$root_password_container" >/dev/null
  assert_root_password_container_rejected \
    "$root_password_container" \
    "must name a readable regular file" \
    "A missing explicit root password file"

  # The auto-detected default is also an intentional selection once present. An
  # empty secret must not revive the compatibility environment value.
  : >"$root_password_secret_file"
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW=stale-environment-password \
    "$image_name" >/dev/null
  # docker cp avoids MSYS rewriting bind-mount targets and also works under act's
  # Docker-in-Docker layout. The basename keeps the production /run/secrets path.
  docker cp "$docker_root_password_secret_dir" "$root_password_container:/run/"
  docker start "$root_password_container" >/dev/null
  assert_root_password_container_rejected \
    "$root_password_container" \
    "LDAP_INIT_ROOT_USER_PW_FILE must not be empty" \
    "An empty root password file"

  # A service-controlled link must not make the root entrypoint open its protected
  # target. The hook creates the link before run.sh gives /run/slapd to openldap.
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    --env INIT_SH_FILE=/opt/root-password-env-probe.sh \
    --env LDAP_INIT_ROOT_USER_PW_FILE=/run/slapd/root-password-link \
    --env ROOT_PASSWORD_TEST_CREATE_UNTRUSTED_LINK=true \
    "$image_name" >/dev/null
  docker cp "$docker_root_password_env_probe_file" \
    "$root_password_container:/opt/root-password-env-probe.sh"
  docker start "$root_password_container" >/dev/null
  assert_root_password_container_rejected \
    "$root_password_container" \
    "must name a readable regular file" \
    "A service-controlled root-password link"

  # Bash variables cannot represent NUL. Continuing after command substitution
  # removes it would silently select a different effective LDAP credential.
  printf 'test-only\0password' >"$root_password_secret_file"
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    "$image_name" >/dev/null
  docker cp "$docker_root_password_secret_dir" "$root_password_container:/run/"
  docker start "$root_password_container" >/dev/null
  assert_root_password_container_rejected \
    "$root_password_container" \
    "must not contain NUL bytes" \
    "A root-password file containing NUL"

  # Remove exactly one conventional terminator. The remaining LF is password data
  # and must survive hashing and every later simple bind unchanged.
  printf '%s\n\n' "$root_password_secret" >"$root_password_secret_file"
  chmod 0644 "$root_password_secret_file"
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    "$image_name" >/dev/null
  docker cp "$docker_root_password_secret_dir" "$root_password_container:/run/"
  docker start "$root_password_container" >/dev/null
  wait_until_ready "$root_password_container"
  printf '%s\n' "$root_password_secret" >"$root_password_secret_file"
  docker cp "$docker_root_password_secret_file" \
    "$root_password_container:/run/secrets/ldap-admin-password"
  docker exec "$root_password_container" \
    ldapwhoami -x -H ldapi:/// -D "$root_dn" -y /run/secrets/ldap-admin-password >/dev/null
  docker rm --force --volumes "$root_password_container" >/dev/null

  # CRLF is a common mounted-secret terminator. Shell-looking text, quotes, and
  # backslashes stay opaque because the password bypasses template interpolation.
  # Keep this source service-readable so the integration test exercises the
  # unprivileged read branch rather than only protected root-owned files.
  printf '%s\r\n' "$root_password_secret" >"$root_password_secret_file"
  chmod 0644 "$root_password_secret_file"
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    --env INIT_SH_FILE=/opt/root-password-env-probe.sh \
    --env LDAP_INIT_ROOT_USER_PW=stale-environment-password \
    --env ROOT_PASSWORD_TEST_PROBE_ENVIRONMENT=true \
    "$image_name" >/dev/null
  docker cp "$docker_root_password_env_probe_file" \
    "$root_password_container:/opt/root-password-env-probe.sh"
  docker cp "$docker_root_password_secret_dir" "$root_password_container:/run/"
  docker start "$root_password_container" >/dev/null
  wait_until_ready "$root_password_container"
  container_logs=$(docker logs "$root_password_container" 2>&1)

  if ! docker exec "$root_password_container" \
      test -e /run/root-password-env-probe-reached; then
    echo "The root password environment probe did not observe production slapd." >&2
    exit 1
  fi
  if docker exec "$root_password_container" \
      test -e /run/root-password-env-probe-leaked; then
    echo "A slapd child inherited a public or private root-password variable." >&2
    exit 1
  fi
  if [[ $container_logs == *"$root_password_secret"* ]]; then
    echo "Shell tracing exposed the file-backed root password in container logs." >&2
    exit 1
  fi

  # Rewrite only the host-side test input so ldapwhoami reads the exact normalized
  # value through -y; the persisted LDAP password must have come from the earlier CRLF file.
  printf '%s' "$root_password_secret" >"$root_password_secret_file"
  docker cp "$docker_root_password_secret_file" \
    "$root_password_container:/run/secrets/ldap-admin-password"
  docker exec "$root_password_container" chmod 0600 /run/secrets/ldap-admin-password
  docker exec "$root_password_container" \
    ldapwhoami -x -H ldapi:/// -D "$root_dn" -y /run/secrets/ldap-admin-password >/dev/null
  if docker exec "$root_password_container" \
      ldapwhoami -x -H ldapi:/// -D "$root_dn" -w stale-environment-password >/dev/null 2>&1; then
    echo "The environment password remained effective after the secret file was selected." >&2
    exit 1
  fi

  # A restart takes the already-initialized branch, where the bootstrap password is
  # not otherwise consumed. It must still be removed before production slapd starts.
  docker exec "$root_password_container" rm -f \
    /run/root-password-env-probe-reached /run/root-password-env-probe-leaked
  docker restart "$root_password_container" >/dev/null
  wait_until_ready "$root_password_container"

  # Docker ENV imports are exported by Bash. The entrypoint must remove the public
  # variable on every startup, not merely overwrite its value during initialization.
  if ! docker exec "$root_password_container" \
      test -e /run/root-password-env-probe-reached; then
    echo "The root password environment probe did not observe restarted production slapd." >&2
    exit 1
  fi
  if docker exec "$root_password_container" \
      test -e /run/root-password-env-probe-leaked; then
    echo "The restarted production slapd inherited a root-password variable." >&2
    exit 1
  fi
  docker rm --force --volumes "$root_password_container" >/dev/null

  # Exercise the example exactly as documented. Its owner-only generated file is
  # also the protected-root source case; ldapwhoami must consume that same file
  # without a test-only rewrite or terminator normalization.
  mkdir -p "$generated_example_dir"
  cp "$script_dir/example/docker-compose/syncrepl/generate-secrets.sh" \
    "$generated_example_dir/generate-secrets.sh"
  sh "$generated_example_dir/generate-secrets.sh" >/dev/null 2>&1
  docker_generated_secret_dir="$generated_example_dir/secrets"
  if [[ $OSTYPE == "cygwin" || $OSTYPE == "msys" ]]; then
    docker_generated_secret_dir=$(cygpath -w "$docker_generated_secret_dir")
  fi
  docker create --name "$root_password_container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW_FILE=/run/secrets/ldap-provider-admin-password \
    "$image_name" >/dev/null
  docker cp "$docker_generated_secret_dir" "$root_password_container:/run/"
  docker start "$root_password_container" >/dev/null
  wait_until_ready "$root_password_container"
  docker exec "$root_password_container" \
    ldapwhoami -x -H ldapi:/// -D "$root_dn" \
      -y /run/secrets/ldap-provider-admin-password >/dev/null
  docker rm --force --volumes "$root_password_container" >/dev/null
}
