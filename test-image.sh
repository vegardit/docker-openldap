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
replication_network="$test_id-network"
provider_container="$test_id-provider"
provider_config_volume="$test_id-provider-config"
provider_data_volume="$test_id-provider-data"
consumer_container="$test_id-consumer"
consumer_config_volume="$test_id-consumer-config"
consumer_data_volume="$test_id-consumer-data"
test_dir=$(mktemp -d)
tls_dir="$test_dir/tls"
replication_secret_dir="$test_dir/secrets"
# docker cp preserves this basename under /opt/ldifs, so it must match the
# public container path rather than a descriptive test-only directory name.
custom_ldif_dir="$test_dir/custom"
custom_schema_ldif_dir="$test_dir/custom-schema"
invalid_schema_path_file="$test_dir/custom-schema-file"
replication_password_file="$replication_secret_dir/ldap-replication-password"
docker_ca_file="$tls_dir/ca.crt"
docker_cert_file="$tls_dir/server.crt"
docker_key_file="$tls_dir/server.key"
docker_replication_secret_dir="$replication_secret_dir"
docker_custom_ldif_dir="$custom_ldif_dir"
docker_custom_schema_ldif_dir="$custom_schema_ldif_dir"
docker_invalid_schema_path_file="$invalid_schema_path_file"
root_dn='uid=admin,DC=example,DC=com'
root_password='test-only-password'
custom_entry_dn='cn=custom-entry,ou=Custom,DC=example,DC=com'
replication_dn='uid=replicator,DC=example,DC=com'
# The embedded space verifies that LDIF interpolation preserves quoted credentials.
replication_password='test-only replication password'
replication_group_dn='cn=replication-group,DC=example,DC=com'
replication_member_dn='uid=replication-member,DC=example,DC=com'
initial_backup_pending_marker='/var/lib/ldap/.initial-backup-pending'

if [[ $OSTYPE == "cygwin" || $OSTYPE == "msys" ]]; then
  # MSYS otherwise rewrites Linux container targets such as /mnt. Convert only
  # client-side sources explicitly, then leave Docker's Linux paths untouched.
  function docker() {
    MSYS_NO_PATHCONV=1 command docker "$@"
  }
  docker_ca_file=$(cygpath -w "$docker_ca_file")
  docker_cert_file=$(cygpath -w "$docker_cert_file")
  docker_key_file=$(cygpath -w "$docker_key_file")
  docker_replication_secret_dir=$(cygpath -w "$docker_replication_secret_dir")
  docker_custom_ldif_dir=$(cygpath -w "$docker_custom_ldif_dir")
  docker_custom_schema_ldif_dir=$(cygpath -w "$docker_custom_schema_ldif_dir")
  docker_invalid_schema_path_file=$(cygpath -w "$docker_invalid_schema_path_file")
fi

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
function cleanup() {
  docker rm --force "$container" "$provider_container" "$consumer_container" >/dev/null 2>&1 || true
  docker volume rm --force \
    "$config_volume" "$data_volume" \
    "$provider_config_volume" "$provider_data_volume" \
    "$consumer_config_volume" "$consumer_data_volume" >/dev/null 2>&1 || true
  docker network rm "$replication_network" >/dev/null 2>&1 || true
  # Only the exact directory returned by mktemp is removed; cleanup never derives
  # a recursive-delete target from image input or caller-controlled environment.
  rm -rf -- "$test_dir"
}
trap cleanup EXIT

function test_phase() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$1"
}

function test_step() {
  printf '[%s]   %s\n' "$(date +%H:%M:%S)" "$1"
}

test_phase "Checking backup scheduler logic"

# Exercise schedule arithmetic inside the image without waiting for wall-clock
# time. The 03:05 case models an export that started at 02:00 and ran for 65
# minutes: the next backup must still target the following 02:00, not add a
# fixed 23-hour delay and miss that day.
docker run --rm --entrypoint bash \
  --env LDAP_BACKUP_TIME=02:00 \
  "$image_name" -c '
    set -euo pipefail
    source /opt/backup.sh

    function assert_schedule_delay() {
      local current_time=$1
      local allow_current_minute=$2
      local expected_delay=$3
      local actual_delay

      actual_delay=$(ldap_backup_seconds_until_schedule \
        "$current_time" "$allow_current_minute")
      if [[ $actual_delay != "$expected_delay" ]]; then
        echo "At [$current_time], expected [$expected_delay] seconds until the next backup but got [$actual_delay]." >&2
        return 1
      fi
    }

    assert_schedule_delay 01:59:30 true 30
    assert_schedule_delay 02:00:30 true 0
    # A completed backup must not start again during the minute that launched it.
    assert_schedule_delay 02:00:30 false 86370
    assert_schedule_delay 03:05:00 true 82500

    # Each sleep advances one fixed GNU date response. This exercises the waiter
    # without duplicating its clock semantics in the test.
    function assert_selected_schedule_date() {
      local expected_date=$1
      local last_backup_date=$2
      shift 2
      local -a mock_schedule_states=("$@")
      local mock_schedule_index=0
      local selected_schedule_date=

      function date() {
        printf "%s\n" "${mock_schedule_states[$mock_schedule_index]}"
      }
      function sleep() {
        ((mock_schedule_index += 1))
        if (( mock_schedule_index >= ${#mock_schedule_states[@]} )); then
          echo "The scheduler did not select an occurrence from the supplied clock states." >&2
          return 1
        fi
      }

      wait_for_ldap_backup_schedule selected_schedule_date "$last_backup_date"
      if [[ $selected_schedule_date != "$expected_date" ]]; then
        echo "Expected backup date [$expected_date] but selected [$selected_schedule_date]." >&2
        return 1
      fi
    }

    ldap_backup_schedule_max_sleep_seconds=1

    # A delayed wake or same-offset forward correction must recover the occurrence
    # it crossed instead of silently waiting until tomorrow.
    assert_selected_schedule_date 2026-06-01 "" \
      "2026-06-01 01:58:00 +0200 1780271880" \
      "2026-06-01 03:05:00 +0200 1780275900"

    # A changed offset is a civil-time transition, not evidence that the absent
    # spring-forward hour should receive a catch-up backup.
    assert_selected_schedule_date 2026-03-30 "" \
      "2026-03-29 01:58:00 +0100 1774745880" \
      "2026-03-29 03:05:00 +0200 1774746300" \
      "2026-03-30 02:00:00 +0200 1774828800"

    # Suppress a date that already ran even when its local hour repeats at the end
    # of DST; the next date remains eligible.
    assert_selected_schedule_date 2026-10-26 2026-10-25 \
      "2026-10-25 02:00:30 +0200 1792886430" \
      "2026-10-26 02:00:00 +0100 1792976400"

    # Exercise the worker handoff without waiting for real time. The first mocked
    # occurrence must reach the configured writer; the second wait stops the loop.
    worker_wait_count=0
    worker_write_count=0
    LDAP_BACKUP_FILE=/tmp/scheduled-backup.ldif
    is_syncrepl_consumer=false
    function wait_for_ldap_backup_schedule() {
      ((worker_wait_count += 1))
      ((worker_wait_count == 1)) || return 1
      printf -v "$1" '%s' 2026-06-01
    }
    function write_ldap_backup() {
      [[ $1 == "$LDAP_BACKUP_FILE" ]] || return 1
      ((worker_write_count += 1))
    }
    function log() {
      :
    }
    backup_ldap || true
    if ((worker_wait_count != 2 || worker_write_count != 1)); then
      echo "The periodic backup worker did not hand the scheduled occurrence to the writer." >&2
      exit 1
    fi

    # An empty destination pauses the pending initial export. It must not be
    # converted into a relative path such as ./..tmp; retaining the pending state
    # lets a later startup complete the export after a destination is configured.
    initial_backup_pending=true
    LDAP_BACKUP_FILE=
    backup_write_attempted=false
    # Record the call without touching storage. Returning failure avoids marker
    # cleanup; the log stub lets the explicit assertion report the regression.
    function write_ldap_backup() {
      backup_write_attempted=true
      return 1
    }
    function log() {
      :
    }
    create_initial_ldap_backup
    if [[ $backup_write_attempted == true ]]; then
      echo "An empty LDAP_BACKUP_FILE must not start an initial backup." >&2
      exit 1
    fi
  '

function create_fresh_volumes() {
  for volume in "$config_volume" "$data_volume"; do
    docker volume create "$volume" >/dev/null
    # Reproduce fresh ext-backed mounts whose filesystem metadata makes `ls`
    # non-empty before the application has written anything.
    docker run --rm \
      --mount "type=volume,src=$volume,dst=/mnt" \
      "$image_name" mkdir /mnt/lost+found
  done
}

function start_container() {
  local fixture_mode=${1:-}
  case "$fixture_mode" in
    --bootstrap-ldifs|--schema-path-file) shift ;;
    *) fixture_mode= ;;
  esac

  docker create --name "$container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW=test-only-password \
    "$@" \
    --mount "type=volume,src=$config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$data_volume,dst=/var/lib/ldap" \
    "$image_name" >/dev/null

  # act's nested Docker daemon cannot resolve runner-local bind paths. Copying
  # before start exercises the same container paths on every supported runner.
  case "$fixture_mode" in
    --bootstrap-ldifs)
      docker cp "$docker_custom_ldif_dir" "$container:/opt/ldifs/"
      docker cp "$docker_custom_schema_ldif_dir" "$container:/opt/ldifs/"
      ;;
    --schema-path-file)
      docker cp "$docker_invalid_schema_path_file" "$container:/opt/ldifs/custom-schema"
      ;;
  esac
  docker start "$container" >/dev/null
}

function wait_until_ready() {
  local target_container=${1:-$container}
  local container_logs
  local started_at

  # Docker retains logs across restarts. Anchor the marker to the daemon-recorded
  # current start so an old final-start message cannot pair with this invocation's
  # temporary slapd, and client/daemon clock skew cannot move the boundary.
  # Test containers do not auto-restart, so one snapshot stays authoritative.
  started_at=$(docker inspect --format '{{.State.StartedAt}}' "$target_container")

  # Initialization starts a temporary slapd first; require the final startup
  # message plus a live socket so the intermediate service cannot satisfy this.
  # Select EXTERNAL explicitly because GSSAPI-capable clients otherwise prefer
  # a mechanism that requires credentials unavailable to this readiness probe.
  for _ in {1..120}; do
    container_logs=$(docker logs --since "$started_at" "$target_container" 2>&1)
    if [[ $container_logs == *"Starting OpenLDAP: slapd..."* ]] && \
        docker exec "$target_container" \
          ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
      return 0
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$target_container") != true ]]; then
      break
    fi
    sleep 0.5
  done

  docker logs --since "$started_at" "$target_container" >&2
  return 1
}

function start_replication_node() {
  local node=$1
  local network_alias=$2
  local node_config_volume=$3
  local node_data_volume=$4
  local role=${5:-}
  local provider_uri=${6:-}
  local ca_file=${7:-}
  local backup_time=${8:-}
  local -a replication_options=()
  local -a tls_ca_options=()
  local -a tls_server_options=()
  if [[ -n $role ]]; then
    replication_options=(
      --env LDAP_INIT_REPLICATION_ROLE="$role"
      --env LDAP_INIT_REPLICATION_PROVIDER_URI="$provider_uri"
    )
  fi
  if [[ $role == provider ]]; then
    # Pin the inherited user-policy threshold so the failed binds below would
    # lock an account that accidentally lost its replication-only exemption.
    replication_options+=(--env LDAP_INIT_PPOLICY_MAX_FAILURES=3)
    # Syncrepl authenticates with its password, but inherits the consumer's
    # server-only certificate as a client certificate. Do not request that
    # unsuitable certificate; the consumer keeps the normal incoming-TLS policy.
    # A successful provider start covers zero-padded decimal SSF input.
    tls_server_options=(
      --env LDAP_TLS_VERIFY_CLIENT=never
      --env LDAP_TLS_SSF=0128
    )
  fi
  # Keep the CA explicit at each call site: one restart intentionally omits it
  # to prove persisted syncrepl fails closed instead of serving stale data.
  if [[ -n $ca_file ]]; then
    tls_ca_options=(--env LDAP_TLS_CA_FILE=/opt/test-ca.crt)
  fi

  # Resource names stay unique for parallel tests, while the isolated network
  # aliases remain stable so certificate hostname verification can stay strict.
  # Intentionally omit LDAP_TLS_ENABLED so the fixture covers the image's
  # certificate-and-key auto-detection instead of forcing TLS on.
  docker create --name "$node" --hostname "$network_alias" \
    --network "$replication_network" --network-alias "$network_alias" \
    --network-alias "${network_alias}-cn-only" \
    --env LDAP_BACKUP_TIME="$backup_time" \
    --env LDAP_INIT_ROOT_USER_PW="$root_password" \
    --env CUSTOM_SCHEMA_ATTRIBUTE_NAME=customBootstrapValue \
    "${replication_options[@]}" \
    "${tls_ca_options[@]}" \
    --env LDAP_TLS_CERT_FILE=/opt/test-server.crt \
    --env LDAP_TLS_KEY_FILE=/opt/test-server.key \
    "${tls_server_options[@]}" \
    --mount "type=volume,src=$node_config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$node_data_volume,dst=/var/lib/ldap" \
    "$image_name" >/dev/null

  # Copy before start so issue #50's TLS ordering is preserved. docker cp also
  # works when this script runs in act, where nested host bind paths do not.
  if [[ -n $ca_file ]]; then
    docker cp "$ca_file" "$node:/opt/test-ca.crt"
  fi
  docker cp "$docker_cert_file" "$node:/opt/test-server.crt"
  docker cp "$docker_key_file" "$node:/opt/test-server.key"
  if [[ -n $role ]]; then
    # Copy the directory because /run/secrets does not exist in a merely created
    # container. The image must discover the conventional secret path itself.
    docker cp "$docker_replication_secret_dir" "$node:/run/"
    # cn=config is local state, not syncrepl data. Every new node needs the same
    # custom schemas before it can accept entries that use them.
    docker cp "$docker_custom_schema_ldif_dir" "$node:/opt/ldifs/"
  fi
  if [[ $role == consumer ]]; then
    # The fixture contains an unresolved placeholder on this node. A consumer
    # can start only if custom data is correctly left to syncrepl's provider.
    docker cp "$docker_custom_ldif_dir" "$node:/opt/ldifs/"
  fi
  docker start "$node" >/dev/null
}

function wait_for_replica_entry() {
  local entry_dn=$1

  for _ in {1..120}; do
    # A successful base-scope lookup is the protocol-level existence check; DN
    # text is unsuitable because servers may normalize attribute type casing.
    if docker exec \
        --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
        --env LDAPTLS_REQCERT=demand \
        "$consumer_container" \
        ldapsearch -LLL -x -H ldaps://consumer \
          -D "$root_dn" -w "$root_password" \
          -b "$entry_dn" -s base '(objectClass=*)' 1.1 >/dev/null 2>&1; then
      return 0
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$consumer_container") != true ]]; then
      break
    fi
    sleep 0.5
  done

  docker logs --tail 80 "$consumer_container" >&2
  echo "Replication did not deliver $entry_dn." >&2
  return 1
}

mkdir "$custom_ldif_dir" "$custom_schema_ldif_dir"
printf 'not a directory\n' >"$invalid_schema_path_file"

# The second schema uses the attribute from the first. Their deliberately
# non-padded names prove that the loader uses documented bytewise ordering.
cat >"$custom_schema_ldif_dir/10-attribute.ldif" <<'LDIF'
dn: cn=custom-bootstrap-attribute,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: custom-bootstrap-attribute
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.1 NAME '${CUSTOM_SCHEMA_ATTRIBUTE_NAME}' DESC 'Custom bootstrap test value' EQUALITY caseIgnoreMatch SUBSTR caseIgnoreSubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
LDIF
cat >"$custom_schema_ldif_dir/2-objectclass.ldif" <<'LDIF'
dn: cn=custom-bootstrap-objectclass,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: custom-bootstrap-objectclass
olcObjectClasses: ( 1.3.6.1.4.1.55555.1.2 NAME 'customBootstrapEntry' SUP top AUXILIARY MAY ( customBootstrapValue ) )
LDIF
# The sourced init script below enables dotglob. This unresolved placeholder
# makes accidental loading of the hidden schema fail instead of passing unseen.
cat >"$custom_schema_ldif_dir/.must-not-load.ldif" <<'LDIF'
dn: cn=hidden-custom-bootstrap,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: hidden-custom-bootstrap
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.3 NAME '${UNDEFINED_HIDDEN_SCHEMA_ATTRIBUTE}' SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 )
LDIF

# The visible modification depends on the visible add and uses an explicit change
# record. Together they cover bytewise ordering, default-add behavior, and interpolation.
cat >"$custom_ldif_dir/.init.sh" <<'SH'
if [[ ${PAUSE_INIT_FOR_LISTENER_TEST:-} == true ]]; then
  function ldapadd() {
    # Hold the first durable LDAP write while the host verifies that the
    # initialization daemon is reachable only through its local Unix socket.
    : >/run/init-listener-test-ready
    while [[ ! -e /run/init-listener-test-release ]]; do
      sleep 0.1
    done
    /usr/bin/ldapadd "$@"
  }
fi

# The entrypoint sources this file into its own shell. Leaving dotglob enabled
# reproduces an operator customization that must not broaden the LDIF contract.
shopt -s dotglob
SH
cat >"$custom_ldif_dir/.must-not-load.ldif" <<'LDIF'
dn: cn=hidden-custom-entry,${LDAP_INIT_ORG_DN}
objectClass: top
objectClass: organizationalRole
cn: hidden-custom-entry
LDIF
cat >"$custom_ldif_dir/10-add.ldif" <<'LDIF'
dn: ou=Custom,${LDAP_INIT_ORG_DN}
objectClass: top
objectClass: organizationalUnit
ou: Custom

dn: cn=${CUSTOM_ENTRY_CN},ou=Custom,${LDAP_INIT_ORG_DN}
objectClass: top
objectClass: organizationalRole
objectClass: customBootstrapEntry
cn: ${CUSTOM_ENTRY_CN}
description: value-before-ordered-modify
${CUSTOM_SCHEMA_ATTRIBUTE_NAME}: schema-loaded-before-data
LDIF
# The non-padded "2" is intentional: C-locale bytewise order must place "10"
# first, while natural numeric ordering would attempt this modification too soon.
cat >"$custom_ldif_dir/2-modify.ldif" <<'LDIF'
dn: cn=${CUSTOM_ENTRY_CN},ou=Custom,${LDAP_INIT_ORG_DN}
changetype: modify
replace: description
description: loaded-in-filename-order
LDIF

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
start_container \
  --bootstrap-ldifs \
  --env INIT_SH_FILE=/opt/ldifs/custom/.init.sh \
  --env PAUSE_INIT_FOR_LISTENER_TEST=true \
  --env LDAP_INIT_RFC2307BIS_SCHEMA=1 \
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

# Stop cleanly so the next start tests initialization state rather than MDB
# crash recovery, then attach a new container to the same persistent volumes.
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start_container

wait_until_ready
if [[ $(docker logs "$container" 2>&1) == *"Applying initial configuration"* ]]; then
  echo "Existing LDAP volumes were unexpectedly reinitialized." >&2
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

test_step "Resetting volumes for invalid-configuration checks"
# Persistence behavior was verified before this phase, and these volumes are
# discarded next. Forced removal avoids another graceful-shutdown wait here.
docker rm --force "$container" >/dev/null
docker volume rm "$config_volume" "$data_volume" >/dev/null
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

command -v openssl >/dev/null || {
  echo "openssl is required for the TLS replication lifecycle test." >&2
  exit 1
}

test_phase "Checking TLS replication and consumer backup lifecycle"

mkdir "$tls_dir" "$replication_secret_dir"
printf '%s\n' \
  '[server]' \
  'subjectAltName=DNS:provider,DNS:consumer' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' >"$tls_dir/server.ext"

# MSYS treats OpenSSL's slash-prefixed subject as a path unless this one
# argument prefix is excluded from its automatic path conversion.
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=openldap-test-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -keyout "$tls_dir/ca.key" -out "$tls_dir/ca.crt" >/dev/null 2>&1
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=provider-cn-only' \
  -keyout "$tls_dir/server.key" -out "$tls_dir/server.csr" >/dev/null 2>&1
# A single short-lived test keypair keeps the fixture small; its SANs match both
# fixed Docker DNS names so hostname verification remains strict on every hop.
openssl x509 -req -sha256 -days 1 \
  -in "$tls_dir/server.csr" \
  -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" -CAcreateserial \
  -extfile "$tls_dir/server.ext" -extensions server \
  -out "$tls_dir/server.crt" >/dev/null 2>&1

# Windows-native secret generators commonly terminate text with CRLF. The
# container must discard that terminator without treating CR as password data.
printf '%s\r\n' "$replication_password" >"$replication_password_file"
chmod 600 "$replication_password_file"

docker network create "$replication_network" >/dev/null
for volume in \
    "$provider_config_volume" "$provider_data_volume" \
    "$consumer_config_volume" "$consumer_data_volume"; do
  docker volume create "$volume" >/dev/null
done

# Match the current minute so the backup worker is immediately eligible. Keeping
# the provider offline then proves it waits for the initial refresh rather than
# publishing the consumer's empty database.
consumer_backup_time=$(date +%H:%M)
start_replication_node \
  "$consumer_container" consumer "$consumer_config_volume" "$consumer_data_volume" \
  consumer ldaps://provider "$docker_ca_file" "$consumer_backup_time"
wait_until_ready "$consumer_container"

# Syncrepl's default schema checking can accept replicated attributes without a
# local definition. Query cn=config before the provider starts so replication
# cannot mask a missing bootstrap step. Match definition text rather than DNs
# because slapd adds runtime-dependent {N} indexes; disable wrapping so the
# substring assertions stay stable.
consumer_custom_schema=$(docker exec "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=schema,cn=config' -s one '(objectClass=olcSchemaConfig)' \
    olcAttributeTypes olcObjectClasses)
if [[ $consumer_custom_schema != *"NAME 'customBootstrapValue'"* ||
      $consumer_custom_schema != *"NAME 'customBootstrapEntry'"* ]]; then
  printf '%s\n' "$consumer_custom_schema" >&2
  echo "The replication consumer did not load both custom schema definitions." >&2
  exit 1
fi

# The provider is deliberately still offline, so either the initialization path
# or the scheduled worker would create an empty or partial, misleading export.
if docker exec "$consumer_container" test -e /var/lib/ldap/data.ldif; then
  echo "The replication consumer created a backup before its initial refresh." >&2
  exit 1
fi

# Pair the provider's accepted 0128 with a padded value above the documented
# maximum; both cases exercise the public entrypoint environment boundary.
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

start_replication_node \
  "$provider_container" provider "$provider_config_volume" "$provider_data_volume" provider
wait_until_ready "$provider_container"
# Client verification is disabled, so the provider must not need unused
# peer-trust material merely to serve LDAPS to the consumer.
docker exec "$provider_container" test ! -e /etc/ldap/certs/ca.crt

provider_indexes=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base olcDbIndex)
if [[ $provider_indexes != *"entryCSN,entryUUID eq"* ]]; then
  printf '%s\n' "$provider_indexes" >&2
  echo "The replication provider is missing required syncrepl indexes." >&2
  exit 1
fi

# syncprov otherwise keeps contextCSN only in memory between clean shutdowns.
# A checkpoint bounds the database scan needed after an unclean restart.
provider_syncprov_config=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s one \
    '(objectClass=olcSyncProvConfig)' olcSpCheckpoint)
if [[ $provider_syncprov_config != *"olcSpCheckpoint: 100 10"* ]]; then
  printf '%s\n' "$provider_syncprov_config" >&2
  echo "The replication provider is missing its syncprov checkpoint." >&2
  exit 1
fi

# A fixed, remotely usable service DN must not inherit the human-user lockout
# policy: one client could otherwise disable replication for every consumer.
# The provider deliberately has no CA. Use its local socket for account and seed
# operations; the consumer exercises strict provider LDAPS verification below.
for _ in {1..4}; do
  if docker exec "$provider_container" \
      ldapwhoami -x -H ldapi:/// \
        -D "$replication_dn" -w definitely-wrong >/dev/null 2>&1; then
    echo "The replication account accepted an incorrect password." >&2
    exit 1
  fi
done
docker exec "$provider_container" \
  ldapwhoami -x -H ldapi:/// \
    -D "$replication_dn" -w "$replication_password" >/dev/null

docker exec -i "$provider_container" \
  ldapadd -x -H ldapi:/// -D "$root_dn" -w "$root_password" <<'LDIF'
dn: cn=replication-group,DC=example,DC=com
objectClass: top
objectClass: groupOfUniqueNames
cn: replication-group
uniqueMember: uid=replication-member,DC=example,DC=com

dn: uid=replication-member,DC=example,DC=com
objectClass: top
objectClass: inetOrgPerson
uid: replication-member
cn: Replication Member
sn: Member

dn: cn=replication-before-restart,DC=example,DC=com
objectClass: top
objectClass: organizationalRole
objectClass: customBootstrapEntry
cn: replication-before-restart
customBootstrapValue: replicated-through-custom-schema
LDIF

# Small fixtures cannot expose the quadratic behavior caused by missing indexes,
# and a client TLS check does not prove syncrepl owns the strict policy. Assert
# those settings and the memberOf exclusion in persisted config directly.
replication_config=$(docker exec "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base olcSyncrepl olcDbIndex)
if [[ $replication_config != *"exattrs=memberOf"* ||
      $replication_config != *"tls_reqcert=demand"* ||
      $replication_config != *"tls_reqsan=demand"* ||
      $replication_config != *"entryCSN,entryUUID eq"* ]]; then
  printf '%s\n' "$replication_config" >&2
  echo "The consumer is missing required syncrepl safety settings or indexes." >&2
  exit 1
fi

# addcheck repairs backlinks when replication delivers a group before its
# member, but OpenLDAP requires memberof's internal refint mode to be disabled.
consumer_memberof_config=$(docker exec "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s one \
    '(objectClass=olcMemberOf)' olcMemberOfAddCheck olcMemberOfRefInt)
if [[ $consumer_memberof_config != *"olcMemberOfAddCheck: TRUE"* ||
      $consumer_memberof_config != *"olcMemberOfRefInt: FALSE"* ]]; then
  printf '%s\n' "$consumer_memberof_config" >&2
  echo "The consumer has incompatible memberof replication settings." >&2
  exit 1
fi

# The certificate deliberately has a matching legacy CN but no matching SAN for
# this alias. The weaker policy accepts it; strict SAN verification must not.
docker exec \
  --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
  --env LDAPTLS_REQCERT=demand \
  --env LDAPTLS_REQSAN=allow \
  "$consumer_container" ldapwhoami -x -H ldaps://provider-cn-only >/dev/null
if docker exec \
    --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
    --env LDAPTLS_REQCERT=demand \
    --env LDAPTLS_REQSAN=demand \
    "$consumer_container" ldapwhoami -x -H ldaps://provider-cn-only >/dev/null 2>&1; then
  echo "Strict SAN verification accepted a certificate without a matching SAN." >&2
  exit 1
fi

wait_for_replica_entry 'cn=replication-before-restart,DC=example,DC=com'
wait_for_replica_entry "$replication_group_dn"
wait_for_replica_entry "$replication_member_dn"

# The local cn=config assertion above covers consumer bootstrap. This separate
# directory search proves syncrepl delivered a value that uses the custom schema.
replicated_custom_entry=$(docker exec \
  --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
  --env LDAPTLS_REQCERT=demand \
  "$consumer_container" \
  ldapsearch -LLL -x -H ldaps://consumer \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=replication-before-restart,DC=example,DC=com' -s base \
    '(objectClass=*)' customBootstrapValue)
if [[ $replicated_custom_entry != *'customBootstrapValue: replicated-through-custom-schema'* ]]; then
  printf '%s\n' "$replicated_custom_entry" >&2
  echo "The consumer did not expose the replicated custom attribute." >&2
  exit 1
fi

# The backup worker sleeps while the provider is unavailable. Require its
# explicit transition after refresh so a fix cannot suppress consumer backups
# permanently merely to satisfy the pre-refresh assertion above.
for _ in {1..40}; do
  if [[ $(docker logs "$consumer_container" 2>&1) == *"Initial syncrepl refresh completed; enabling periodic LDAP backups."* ]]; then
    break
  fi
  sleep 0.5
done
if [[ $(docker logs "$consumer_container" 2>&1) != *"Initial syncrepl refresh completed; enabling periodic LDAP backups."* ]]; then
  docker logs --tail 80 "$consumer_container" >&2
  echo "The consumer backup worker did not resume after the initial refresh." >&2
  exit 1
fi

# The provider creates the group before its target member. Requiring search
# output (not merely a successful LDAP result) proves addcheck repaired the
# backlink when the member arrived later on the consumer.
member_of_entry=$(docker exec \
  --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
  --env LDAPTLS_REQCERT=demand \
  "$consumer_container" \
  ldapsearch -LLL -x -H ldaps://consumer \
    -D "$root_dn" -w "$root_password" \
    -b "$replication_member_dn" -s base "(memberOf=$replication_group_dn)" 1.1)
if [[ -z $member_of_entry ]]; then
  echo "The consumer did not derive memberOf for a group received before its member." >&2
  exit 1
fi

# A successful bind proves the provider ACL copied userPassword, not merely the
# replication account's visible attributes.
docker exec \
  --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
  --env LDAPTLS_REQCERT=demand \
  "$consumer_container" \
  ldapwhoami -x -H ldaps://consumer \
    -D "$replication_dn" -w "$replication_password" >/dev/null

# A one-way replica must reject local updates or its database can diverge from
# the provider even though its replicated entries continue to look healthy.
if docker exec -i \
    --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
    --env LDAPTLS_REQCERT=demand \
    "$consumer_container" \
    ldapadd -x -H ldaps://consumer -D "$root_dn" -w "$root_password" >/dev/null 2>&1 <<'LDIF'; then
dn: cn=must-not-be-written-locally,DC=example,DC=com
objectClass: top
objectClass: organizationalRole
cn: must-not-be-written-locally
LDIF
  echo "The replication consumer accepted a local write." >&2
  exit 1
fi

# Reuse both volumes without the bootstrap inputs or CA. Persisted cn=config
# still requires that CA, so startup must fail instead of serving stale data.
docker stop "$consumer_container" >/dev/null
docker rm "$consumer_container" >/dev/null
start_replication_node \
  "$consumer_container" consumer "$consumer_config_volume" "$consumer_data_volume"
for _ in {1..20}; do
  if [[ $(docker inspect --format '{{.State.Running}}' "$consumer_container") != true ]]; then
    break
  fi
  sleep 0.5
done
missing_ca_logs=$(docker logs "$consumer_container" 2>&1)
if [[ $(docker inspect --format '{{.State.Running}}' "$consumer_container") == true ]] ||
    [[ $(docker inspect --format '{{.State.ExitCode}}' "$consumer_container") == 0 ]] ||
    [[ $missing_ca_logs != *"Persisted syncrepl requires /etc/ldap/certs/ca.crt"* ]]; then
  printf '%s\n' "$missing_ca_logs" >&2
  echo "A persisted replication consumer started without its configured CA." >&2
  exit 1
fi

# A normal restart still omits one-time replication inputs, but supplies the
# runtime CA required by the persisted consumer configuration.
docker rm "$consumer_container" >/dev/null
start_replication_node \
  "$consumer_container" consumer "$consumer_config_volume" "$consumer_data_volume" \
  '' '' "$docker_ca_file"
wait_until_ready "$consumer_container"
if [[ $(docker logs "$consumer_container" 2>&1) == *"Applying initial configuration"* ]]; then
  echo "The persisted replication consumer was unexpectedly reinitialized." >&2
  exit 1
fi

# A writer marker can survive beside a configuration volume that is later paired
# with persisted consumer state. The persisted syncrepl role is authoritative:
# discard the stale request instead of exporting a potentially partial replica.
docker exec "$consumer_container" sh -c \
  "rm -f /var/lib/ldap/data.ldif && mkdir '$initial_backup_pending_marker'"
docker stop "$consumer_container" >/dev/null
docker rm "$consumer_container" >/dev/null
start_replication_node \
  "$consumer_container" consumer "$consumer_config_volume" "$consumer_data_volume" \
  '' '' "$docker_ca_file"
wait_until_ready "$consumer_container"
if docker exec "$consumer_container" test -e /var/lib/ldap/data.ldif ||
    docker exec "$consumer_container" test -e "$initial_backup_pending_marker"; then
  echo "A persisted consumer processed or retained a stale initial-backup marker." >&2
  exit 1
fi

docker exec -i "$provider_container" \
  ldapadd -x -H ldapi:/// -D "$root_dn" -w "$root_password" <<'LDIF'
dn: cn=replication-after-restart,DC=example,DC=com
objectClass: top
objectClass: organizationalRole
cn: replication-after-restart
LDIF

# A new provider write proves syncrepl resumed; the pre-restart entry alone
# could have been stale data that merely survived in the consumer volume.
wait_for_replica_entry 'cn=replication-after-restart,DC=example,DC=com'

test_phase "All image integration checks passed"
