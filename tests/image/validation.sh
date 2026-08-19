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

test_step "Checking the image TLS CA default"

# Optional-versus-required CA behavior depends on this equality. Exercise the
# built image so a Dockerfile-only or shell-only default change cannot silently
# change the public policy.
docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
  source /opt/tls.sh
  [[ ${LDAP_TLS_CA_FILE:-} == "$tls_default_ca_file" ]]
'

test_step "Checking TLS source privilege boundaries"

# The configured path can live below a service-writable directory. Root must not
# follow that directory entry to data which the openldap identity cannot read.
if ! tls_source_guard_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/tls.sh

    readonly marker=ROOT_ONLY_TLS_SOURCE_MARKER
    install -d -o openldap -g openldap -m 0755 /opt/tls-source-probe
    printf "%s\n" "$marker" >/root/tls-source-target
    chmod 0600 /root/tls-source-target
    run_as_openldap ln -s /root/tls-source-target /opt/tls-source-probe/server.key

    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=128
    LDAP_LDAPS_ENABLED=false
    LDAP_TLS_VERIFY_CLIENT=never
    LDAP_TLS_KEY_FILE=/opt/tls-source-probe/server.key
    LDAP_TLS_CERT_FILE=/etc/hosts
    LDAP_TLS_CA_FILE=/does-not-exist

    tls_output=
    if tls_output=$(tls_prepare 2>&1); then
      echo "tls_prepare followed a service-controlled link to a root-only source." >&2
      exit 1
    fi
    if [[ $tls_output == *"$marker"* ]] ||
        { [[ -f /etc/ldap/certs/server.key ]] && grep -F "$marker" /etc/ldap/certs/server.key >/dev/null; }; then
      echo "tls_prepare exposed root-only TLS source content." >&2
      exit 1
    fi
    if [[ $tls_output != *"LDAP_TLS_KEY_FILE must name a service-readable or protected root-readable regular file"* ]]; then
      printf "%s\n" "$tls_output" >&2
      echo "tls_prepare did not report the rejected TLS key source." >&2
      exit 1
    fi

    # A regular root-owned file is still attacker-selectable when its directory
    # entry belongs to openldap. This covers the non-symlink race that the path
    # walk must reject before granting root read authority.
    run_as_openldap rm /opt/tls-source-probe/server.key
    printf "%s\n" "$marker" >/opt/tls-source-probe/server.key
    chown root:root /opt/tls-source-probe/server.key
    chmod 0600 /opt/tls-source-probe/server.key

    tls_output=
    if tls_output=$(tls_prepare 2>&1); then
      echo "tls_prepare accepted a root-only file below a service-writable directory." >&2
      exit 1
    fi
    if [[ $tls_output == *"$marker"* ]] ||
        { [[ -f /etc/ldap/certs/server.key ]] && grep -F "$marker" /etc/ldap/certs/server.key >/dev/null; }; then
      echo "tls_prepare exposed a replaceable root-only TLS source." >&2
      exit 1
    fi

    # `auto` may disable TLS for an unsafe source, but the distinction from an
    # ordinary missing source must remain visible without logging the path or its
    # root-only target.
    LDAP_TLS_ENABLED=auto
    tls_output=
    if ! tls_prepare >/tmp/tls-auto-output 2>&1; then
      tls_output=$(</tmp/tls-auto-output)
      printf "%s\n" "$tls_output" >&2
      echo "TLS auto-detection failed instead of disabling TLS." >&2
      exit 1
    fi
    tls_output=$(</tmp/tls-auto-output)
    if [[ $LDAP_TLS_ENABLED != false ]] ||
        [[ $tls_output != *"TLS auto-detection cannot safely use the configured certificate or private key source; disabling TLS"* ]]; then
      printf "%s\n" "$tls_output" >&2
      echo "TLS auto-detection disabled TLS without reporting the unsafe source." >&2
      exit 1
    fi

    # Missing files are the normal `auto` opt-out and must not warn on every
    # plaintext deployment. Only an unsafe or ambiguous path needs attention.
    LDAP_TLS_CERT_FILE=/run/secrets/ldap/missing-server.crt
    LDAP_TLS_KEY_FILE=/run/secrets/ldap/missing-server.key
    LDAP_TLS_ENABLED=auto
    tls_prepare >/tmp/tls-auto-output 2>&1
    if [[ $LDAP_TLS_ENABLED != false ]] || [[ -s /tmp/tls-auto-output ]]; then
      cat /tmp/tls-auto-output >&2
      echo "TLS auto-detection warned for ordinary missing sources." >&2
      exit 1
    fi

    LDAP_TLS_CERT_FILE=/etc/hosts
    LDAP_TLS_KEY_FILE=/opt/tls-source-probe/server.key
    LDAP_TLS_ENABLED=true

    # Removing write bits is not enough when openldap owns the directory: its
    # owner can chmod the directory and regain control before the root open.
    chmod 0555 /opt/tls-source-probe
    tls_output=
    if tls_output=$(tls_prepare 2>&1); then
      echo "tls_prepare trusted a root-only file below a service-owned directory." >&2
      exit 1
    fi

    # Service-readable links remain safe because the source is opened with service
    # authority; accepting them preserves common mounted-secret layouts.
    chmod 0755 /opt/tls-source-probe
    rm /opt/tls-source-probe/server.key
    run_as_openldap ln -s /etc/hosts /opt/tls-source-probe/server.key
    install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
    LDAP_TLS_CA_FILE=/etc/hosts
    tls_output=
    if ! tls_output=$(tls_prepare 2>&1); then
      printf "%s\n" "$tls_output" >&2
      echo "tls_prepare rejected a service-readable TLS source link." >&2
      exit 1
    fi
    cmp /etc/hosts /etc/ldap/certs/server.key
  ' 2>&1); then
  printf '%s\n' "$tls_source_guard_output" >&2
  exit 1
fi

test_step "Checking protected root-readable TLS sources without a CA"

# A root entrypoint is useful for adapting mounted secrets to the service UID.
# Preserve that behavior only when openldap cannot replace any source component;
# auto-detection must recognize the same trusted source that installation accepts.
# The optional default CA is deliberately absent from that protected directory.
if ! trusted_tls_source_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/tls.sh

    install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
    install -d -o root -g root -m 0700 /run/secrets/ldap
    printf "%s\n" ROOT_ONLY_TLS_KEY >/run/secrets/ldap/server.key
    printf "%s\n" ROOT_ONLY_TLS_CERT >/run/secrets/ldap/server.crt
    chmod 0600 /run/secrets/ldap/server.key /run/secrets/ldap/server.crt

    LDAP_TLS_ENABLED=auto
    LDAP_TLS_SSF=128
    LDAP_LDAPS_ENABLED=false
    LDAP_TLS_VERIFY_CLIENT=never
    LDAP_TLS_KEY_FILE=/run/secrets/ldap/server.key
    LDAP_TLS_CERT_FILE=/run/secrets/ldap/server.crt
    LDAP_TLS_CA_FILE=/run/secrets/ldap/ca.crt

    tls_prepare
    [[ $LDAP_TLS_ENABLED == true ]]
    grep -Fx ROOT_ONLY_TLS_KEY /etc/ldap/certs/server.key >/dev/null
    grep -Fx ROOT_ONLY_TLS_CERT /etc/ldap/certs/server.crt >/dev/null
    [[ $(stat -c "%U:%G:%a" /etc/ldap/certs/server.key) == openldap:openldap:600 ]]
    [[ $(stat -c "%U:%G:%a" /etc/ldap/certs/server.crt) == openldap:openldap:644 ]]
    [[ ! -e /etc/ldap/certs/ca.crt && ! -L /etc/ldap/certs/ca.crt ]]
  ' 2>&1); then
  printf '%s\n' "$trusted_tls_source_output" >&2
  exit 1
fi

test_step "Checking protected custom TLS CA sources"

# A custom CA is required when configured, but it need not be directly readable by
# openldap when its protected path lets root delegate only that opened file.
if ! protected_custom_ca_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/tls.sh

    install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
    printf "%s\n" ROOT_ONLY_CUSTOM_CA >/root/custom-ca.crt
    chmod 0600 /root/custom-ca.crt

    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=128
    LDAP_LDAPS_ENABLED=false
    LDAP_TLS_VERIFY_CLIENT=never
    LDAP_TLS_KEY_FILE=/etc/hosts
    LDAP_TLS_CERT_FILE=/etc/hosts
    LDAP_TLS_CA_FILE=/root/custom-ca.crt

    tls_prepare
    grep -Fx ROOT_ONLY_CUSTOM_CA /etc/ldap/certs/ca.crt >/dev/null
    [[ $(stat -c "%U:%G:%a" /etc/ldap/certs/ca.crt) == openldap:openldap:644 ]]
  ' 2>&1); then
  printf '%s\n' "$protected_custom_ca_output" >&2
  exit 1
fi

test_step "Checking protected default TLS CA sources"

# The default CA remains auto-discovered through a protected directory. Its source
# must be installed rather than mistaken for the optional absent state.
if ! protected_default_ca_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/tls.sh

    install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
    install -d -o root -g root -m 0700 /run/secrets/ldap
    printf "%s\n" ROOT_ONLY_DEFAULT_CA >/run/secrets/ldap/ca.crt
    chmod 0644 /run/secrets/ldap/ca.crt

    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=128
    LDAP_LDAPS_ENABLED=false
    LDAP_TLS_VERIFY_CLIENT=never
    LDAP_TLS_KEY_FILE=/etc/hosts
    LDAP_TLS_CERT_FILE=/etc/hosts
    LDAP_TLS_CA_FILE=/run/secrets/ldap/ca.crt

    tls_prepare
    grep -Fx ROOT_ONLY_DEFAULT_CA /etc/ldap/certs/ca.crt >/dev/null
    [[ $(stat -c "%U:%G:%a" /etc/ldap/certs/ca.crt) == openldap:openldap:644 ]]
  ' 2>&1); then
  printf '%s\n' "$protected_default_ca_output" >&2
  exit 1
fi

test_step "Checking persisted syncrepl CA inspection"

# slapcat base64-encodes an entire attribute when any part needs LDIF encoding.
# The non-ASCII bind DN forces that representation while the managed CA path stays
# ordinary ASCII, reproducing the form that raw grep cannot see.
if ! syncrepl_ca_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/tls.sh

    printf -v syncrepl_value "rid=001 provider=ldaps://provider binddn=\"uid=r\303\251plica,dc=example\" tls_cacert=/etc/ldap/certs/ca.crt"
    encoded_value=$(printf "%s" "$syncrepl_value" | /usr/bin/base64 -w0)
    printf "dn: olcDatabase={1}mdb,cn=config\nolcSyncrepl:: %s\n\n" "$encoded_value" |
      run_as_openldap /bin/bash -c "source /opt/tls.sh; tls_ldif_has_managed_syncrepl_ca"

    if printf "%s\n" "olcSyncrepl: rid=001 provider=ldaps://provider tls_cacert=/somewhere/else" |
        run_as_openldap /bin/bash -c "source /opt/tls.sh; tls_ldif_has_managed_syncrepl_ca"; then
      echo "The syncrepl CA inspection matched an unrelated path." >&2
      exit 1
    fi
  ' 2>&1); then
  printf '%s\n' "$syncrepl_ca_output" >&2
  exit 1
fi

test_step "Checking stale optional TLS CA handling"

# A missing optional source must not reactivate the CA copied by an earlier start.
# Keep the file long enough for stopped reconciliation to remove its persisted
# reference, but leave readiness false so online reconciliation cannot republish it.
if ! stale_ca_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    source /opt/backup.sh
    source /opt/tls.sh

    install -d -o openldap -g openldap -m 0755 /etc/ldap/certs
    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=128
    LDAP_LDAPS_ENABLED=false
    LDAP_TLS_VERIFY_CLIENT=never
    LDAP_TLS_KEY_FILE=/etc/hosts
    LDAP_TLS_CERT_FILE=/etc/hosts
    LDAP_TLS_CA_FILE=/etc/hosts
    tls_prepare
    [[ $TLS_CA_READY_THIS_START == true ]]

    LDAP_TLS_CA_FILE=/run/secrets/ldap/ca.crt
    tls_prepare
    [[ $TLS_CA_READY_THIS_START == false ]]
    cmp /etc/hosts /etc/ldap/certs/ca.crt

    # A compromised service can replace the managed destination with a link. The
    # online decision must use readiness alone; probing this link as root would
    # both expose target metadata and republish a CA absent from the current start.
    printf "%s\n" ROOT_ONLY_CA_TARGET >/root/managed-ca-target
    run_as_openldap rm /etc/ldap/certs/ca.crt
    run_as_openldap ln -s /root/managed-ca-target /etc/ldap/certs/ca.crt
    function ldif() {
      local reconciliation_file=${!#}
      if grep -F "olcTLSCACertificateFile:" "$reconciliation_file" >/dev/null; then
        echo "Online TLS reconciliation followed a stale managed CA path." >&2
        return 74
      fi
      return 0
    }
    tls_reconcile_enabled
  ' 2>&1); then
  printf '%s\n' "$stale_ca_output" >&2
  exit 1
fi

test_step "Checking stopped TLS publication and rollback"

# Exercise the recovery contract around the only persistent file replacement in
# stopped reconciliation. Each case starts from Debian's packaged configuration so
# a previous injected failure cannot make the next assertion pass accidentally.
if ! stopped_tls_output=$(docker run --rm --entrypoint bash "$image_name" -euo pipefail -c '
    source /opt/bash-init.sh
    # These cases inject expected command failures from an inline script. The shared
    # ERR reporter assumes a file-backed caller and dereferences BASH_SOURCE, which is
    # unset here under nounset; disabling only that diagnostic keeps errexit active.
    trap - ERR
    source /opt/tls.sh

    function test_run_as_openldap() {
      /usr/bin/setpriv \
        --reuid openldap \
        --regid openldap \
        --clear-groups \
        --inh-caps=-all \
        --ambient-caps=-all \
        --no-new-privs \
        -- "$@"
    }

    function reset_test_config() {
      # Docker mounts this VOLUME even for an unmounted `docker run`; reset its
      # contents without trying to remove the mount point itself.
      find /etc/ldap/slapd.d -mindepth 1 -delete
      install -d -o openldap -g openldap -m 0755 /etc/ldap/slapd.d
      cp -a /etc/ldap/slapd.d_orig/. /etc/ldap/slapd.d/
      chown -R openldap:openldap /etc/ldap/slapd.d
      # Offline config tools validate referenced data and runtime paths even though
      # these tests modify only cn=config.
      chown -R openldap:openldap /var/lib/ldap
      install -d -o openldap -g openldap -m 0755 /var/run/slapd
    }

    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=256
    TLS_CA_READY_THIS_START=false

    # A failed publication happens before the destination rename. The original
    # global entry must therefore remain byte-identical.
    (
      reset_test_config
      cp /etc/ldap/slapd.d/cn=config.ldif /tmp/original-global.ldif
      function run_as_openldap() {
        if [[ $1 == /usr/bin/mv && ${4:-} == /etc/ldap/slapd.d/.cn=config.ldif.* &&
              ${4:-} != *.backup.* && ${5:-} == /etc/ldap/slapd.d/cn=config.ldif ]]; then
          return 71
        fi
        test_run_as_openldap "$@"
      }

      if tls_reconcile_stopped_config; then
        echo "Stopped TLS reconciliation ignored a publication failure." >&2
        exit 1
      fi
      cmp /tmp/original-global.ldif /etc/ldap/slapd.d/cn=config.ldif
    )

    # If validation rejects the published entry, restoration must put the exact
    # prior global file back and remove the temporary rollback copy.
    (
      reset_test_config
      cp /etc/ldap/slapd.d/cn=config.ldif /tmp/original-global.ldif
      function run_as_openldap() { test_run_as_openldap "$@"; }
      function tls_config_tool_logged() {
        if [[ $1 == /usr/sbin/slaptest && ${3:-} == /etc/ldap/slapd.d ]]; then
          return 72
        fi
        test_run_as_openldap "$@"
      }

      if tls_reconcile_stopped_config; then
        echo "Stopped TLS reconciliation ignored final validation failure." >&2
        exit 1
      fi
      cmp /tmp/original-global.ldif /etc/ldap/slapd.d/cn=config.ldif
      [[ -z $(find /etc/ldap/slapd.d -maxdepth 1 \
        -name ".cn=config.ldif.backup.*" -print -quit) ]]
    )

    # A failed restore is not recoverable automatically. Preserve the known-good
    # rollback file and verify its contents so the diagnostic path is actionable.
    (
      reset_test_config
      cp /etc/ldap/slapd.d/cn=config.ldif /tmp/original-global.ldif
      function run_as_openldap() {
        if [[ $1 == /usr/bin/mv && ${4:-} == */.cn=config.ldif.backup.* &&
              ${5:-} == /etc/ldap/slapd.d/cn=config.ldif ]]; then
          return 73
        fi
        test_run_as_openldap "$@"
      }
      function tls_config_tool_logged() {
        if [[ $1 == /usr/sbin/slaptest && ${3:-} == /etc/ldap/slapd.d ]]; then
          return 72
        fi
        run_as_openldap "$@"
      }

      if tls_reconcile_stopped_config; then
        echo "Stopped TLS reconciliation ignored restoration failure." >&2
        exit 1
      fi
      rollback_file=$(find /etc/ldap/slapd.d -maxdepth 1 \
        -name ".cn=config.ldif.backup.*" -print -quit)
      [[ -n $rollback_file ]]
      cmp /tmp/original-global.ldif "$rollback_file"
      if cmp -s /tmp/original-global.ldif /etc/ldap/slapd.d/cn=config.ldif; then
        echo "The injected restoration failure unexpectedly restored cn=config." >&2
        exit 1
      fi
    )
  ' 2>&1); then
  printf '%s\n' "$stopped_tls_output" >&2
  exit 1
fi

test_step "Checking TLS module failure propagation"

# The `||` is deliberate: Bash suppresses inherited errexit throughout a function
# used as a conditional command. The module must therefore return the failed
# service-authority install instead of appearing successful after a later false `if`.
if docker run --rm --entrypoint bash "$image_name" -c '
    function log() { :; }
    function run_as_openldap() {
      if [[ $1 == /usr/bin/install ]]; then
        return 23
      fi
      "$@"
    }
    source /opt/tls.sh
    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=128
    LDAP_LDAPS_ENABLED=false
    LDAP_TLS_VERIFY_CLIENT=never
    LDAP_TLS_KEY_FILE=/etc/hosts
    LDAP_TLS_CERT_FILE=/etc/hosts
    LDAP_TLS_CA_FILE=/etc/hosts
    tls_prepare || exit $?
  '; then
  echo "tls_prepare masked a failed certificate installation." >&2
  exit 1
fi

# Cleanup follows the LDAP write in tls_reconcile_enabled. Invoke the function from the
# same errexit-suppressing context to prove a successful cleanup cannot replace
# the failed LDAP status returned to a future guarded caller.
if docker run --rm --entrypoint bash "$image_name" -c '
    function log() { :; }
    function ldapsearch() { printf "%s\n" "dn: cn=config"; }
    function ldif() { return 42; }
    source /opt/tls.sh
    LDAP_TLS_ENABLED=true
    LDAP_TLS_SSF=128
    LDAP_TLS_VERIFY_CLIENT=never
    tls_reconcile_enabled || exit $?
  '; then
  echo "tls_reconcile_enabled masked a failed LDAP modification." >&2
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
