#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

set -euo pipefail

# ==============================================================================
# Test setup and cleanup
# ==============================================================================

# Resolve modules from this script so callers may launch the suite from another directory.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
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
second_consumer_container="$test_id-consumer-2"
root_password_container="$test_id-root-password"
replication_password_path_container="$test_id-replication-password-path"
consumer_config_volume="$test_id-consumer-config"
consumer_data_volume="$test_id-consumer-data"
second_consumer_config_volume="$test_id-consumer-2-config"
second_consumer_data_volume="$test_id-consumer-2-data"
test_dir=$(mktemp -d)
tls_dir="$test_dir/tls"
replication_secret_dir="$test_dir/secrets"
# docker cp preserves this basename under /opt/ldifs, so it must match the
# public container path rather than a descriptive test-only directory name.
custom_ldif_dir="$test_dir/custom"
custom_schema_ldif_dir="$test_dir/custom-schema"
custom_policy_ldif_file="$test_dir/init_org_ppolicy.ldif"
invalid_schema_path_file="$test_dir/custom-schema-file"
ldapmodify_failure_wrapper="$test_dir/ldapmodify"
offline_tool_uid_entrypoint="$test_dir/offline-tool-uid-entrypoint"
root_password_env_probe_file="$script_dir/tests/image/root-password-env-probe.sh"
replication_password_path_probe_file="$script_dir/tests/image/replication-password-path-probe.sh"
replication_password_file="$replication_secret_dir/ldap-replication-password"
root_password_secret_dir="$test_dir/root-password/secrets"
root_password_secret_file="$root_password_secret_dir/ldap-admin-password"
docker_ca_file="$tls_dir/ca.crt"
docker_cert_file="$tls_dir/server.crt"
docker_key_file="$tls_dir/server.key"
docker_replication_secret_dir="$replication_secret_dir"
docker_custom_ldif_dir="$custom_ldif_dir"
docker_custom_schema_ldif_dir="$custom_schema_ldif_dir"
docker_custom_policy_ldif_file="$custom_policy_ldif_file"
docker_invalid_schema_path_file="$invalid_schema_path_file"
docker_ldapmodify_failure_wrapper="$ldapmodify_failure_wrapper"
docker_offline_tool_uid_entrypoint="$offline_tool_uid_entrypoint"
docker_root_password_env_probe_file="$root_password_env_probe_file"
docker_replication_password_path_probe_file="$replication_password_path_probe_file"
docker_root_password_secret_dir="$root_password_secret_dir"
docker_root_password_secret_file="$root_password_secret_file"
root_dn='uid=admin,DC=example,DC=com'
root_password='test-only-password'
guest_dn='uid=guest1,ou=External,ou=Users,DC=example,DC=com'
custom_entry_dn='cn=custom-entry,ou=Custom,DC=example,DC=com'
replication_dn='uid=replicator,DC=example,DC=com'
# The embedded space verifies that LDIF interpolation preserves quoted credentials.
replication_password='test-only replication password'
replication_password_path_marker='test-only-root-disclosure-marker'
replication_group_dn='cn=replication-group,DC=example,DC=com'
replication_member_dn='uid=replication-member,DC=example,DC=com'
native_ppm_config=$'minQuality 0\nforbiddenChars @'
restart_native_ppm_config=$'minQuality 0\ncheckRDN 0\nforbiddenChars ~'
provider_ppm_config=$'minQuality 0\nforbiddenChars %'
consumer_conflicting_ppm_config=$'minQuality 0\nforbiddenChars ^'
ppm_peercred_dn='gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth'
ppm_search_acl="to attrs=entry,objectClass by dn.exact=\"$ppm_peercred_dn\" sockurl.exact=\"ldapi:///\" write by * break"
ppm_write_acl="to filter=\"(objectClass=pwdPolicyChecker)\" attrs=pwdCheckModule,pwdUseCheckModule,pwdCheckModuleArg by dn.exact=\"$ppm_peercred_dn\" sockurl.exact=\"ldapi:///\" write by * break"
ppm_blocking_acl="to * by dn.exact=\"$ppm_peercred_dn\" none by * break"
ppm_temporary_limits="dn.exact=\"$ppm_peercred_dn\" size.soft=unlimited size.hard=unlimited time.soft=unlimited time.hard=unlimited"
ppm_temporary_limits_marker='/etc/ldap/slapd.d/.ppm-reconciliation-limit'
ppm_legacy_data_marker='/var/lib/ldap/.ppm-reconciliation-limit'
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
  docker_custom_policy_ldif_file=$(cygpath -w "$docker_custom_policy_ldif_file")
  docker_invalid_schema_path_file=$(cygpath -w "$docker_invalid_schema_path_file")
  docker_ldapmodify_failure_wrapper=$(cygpath -w "$docker_ldapmodify_failure_wrapper")
  docker_offline_tool_uid_entrypoint=$(cygpath -w "$docker_offline_tool_uid_entrypoint")
  docker_root_password_env_probe_file=$(cygpath -w "$docker_root_password_env_probe_file")
  docker_replication_password_path_probe_file=$(cygpath -w "$docker_replication_password_path_probe_file")
  docker_root_password_secret_dir=$(cygpath -w "$docker_root_password_secret_dir")
  docker_root_password_secret_file=$(cygpath -w "$docker_root_password_secret_file")
fi

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
function cleanup() {
  docker rm --force --volumes \
    "$container" "$provider_container" "$consumer_container" "$second_consumer_container" \
    "$root_password_container" \
    "$replication_password_path_container" \
    >/dev/null 2>&1 || true
  docker volume rm --force \
    "$config_volume" "$data_volume" \
    "$provider_config_volume" "$provider_data_volume" \
    "$consumer_config_volume" "$consumer_data_volume" \
    "$second_consumer_config_volume" "$second_consumer_data_volume" \
    >/dev/null 2>&1 || true
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

# shellcheck source=tests/image/scheduler.sh
source "$script_dir/tests/image/scheduler.sh"
test_backup_scheduler

# ==============================================================================
# Shared container and replication helpers
# ==============================================================================

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
  local fixture_mode=
  local record_offline_tool_uids=false
  local -a command_options=()
  while (($#)); do
    case "$1" in
      --bootstrap-ldifs|--schema-path-file|--fail-ppm-reconcile)
        fixture_mode=$1
        shift
        ;;
      --record-offline-tool-uids)
        record_offline_tool_uids=true
        shift
        ;;
      *) break ;;
    esac
  done
  if [[ $record_offline_tool_uids == true ]]; then
    # Keep tini as PID 1 and invoke the copied fixture through sh because Docker
    # Desktop cannot preserve an executable mode from every Windows filesystem.
    command_options=(/bin/sh /opt/test-offline-tool-uid-entrypoint /bin/bash /opt/run.sh)
  fi

  docker create --name "$container" \
    --env LDAP_BACKUP_TIME= \
    --env LDAP_INIT_ROOT_USER_PW=test-only-password \
    "$@" \
    --mount "type=volume,src=$config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$data_volume,dst=/var/lib/ldap" \
    "$image_name" "${command_options[@]}" >/dev/null

  # act's nested Docker daemon cannot resolve runner-local bind paths. Copying
  # before start exercises the same container paths on every supported runner.
  case "$fixture_mode" in
    --bootstrap-ldifs)
      docker cp "$docker_custom_ldif_dir" "$container:/opt/ldifs/"
      docker cp "$docker_custom_schema_ldif_dir" "$container:/opt/ldifs/"
      # A replacement policy template may omit the image's private interpolation
      # hook. This exercises the public behavior: reconciliation must still update
      # the loaded policy, and the initial backup must contain the final values.
      docker cp "$docker_custom_policy_ldif_file" "$container:/opt/ldifs/init_org_ppolicy.ldif"
      ;;
    --schema-path-file)
      docker cp "$docker_invalid_schema_path_file" "$container:/opt/ldifs/custom-schema"
      ;;
    --fail-ppm-reconcile)
      # Replace the client only in this failed-start container. The retry uses the
      # image's normal client with the same persisted volumes.
      docker cp "$docker_ldapmodify_failure_wrapper" "$container:/usr/local/bin/ldapmodify"
      ;;
  esac
  if [[ $record_offline_tool_uids == true ]]; then
    docker cp "$docker_offline_tool_uid_entrypoint" "$container:/opt/test-offline-tool-uid-entrypoint"
  fi
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

function assert_offline_config_tools_service_uid() {
  local target_container=$1
  local openldap_uid
  local observed_uids
  local tool

  openldap_uid=$(docker exec "$target_container" id -u openldap)
  # Keep each tool's observations separate so a safe slapcat invocation cannot
  # hide a privileged slapadd invocation behind the same unique-UID assertion.
  for tool in slapcat slapadd; do
    if ! observed_uids=$(docker exec "$target_container" sort -u "/run/$tool-uids"); then
      printf 'The %s UID probe did not produce a readable record.\n' "$tool" >&2
      return 1
    fi
    if [[ $observed_uids != "$openldap_uid" ]]; then
      printf '%s ran with unexpected UID(s): [%s].\n' "$tool" "$observed_uids" >&2
      return 1
    fi
  done
}

function assert_initialization_rejected() {
  local target_container=$1
  local expected_message=$2
  local rejected_case=$3
  local forbidden_persisted_value=${4:-}
  local container_running=true
  local exit_code
  local output

  # Successful initialization keeps slapd in the foreground. Bound this wait so
  # a missing fail-closed check becomes a useful assertion instead of a hung suite.
  for _ in {1..40}; do
    container_running=$(docker inspect --format '{{.State.Running}}' "$target_container")
    [[ $container_running == false ]] && break
    sleep 0.25
  done
  output=$(docker logs "$target_container" 2>&1)
  if [[ $container_running == true ]]; then
    # The optional marker makes authority-boundary regressions prove disclosure,
    # not merely that an initialization expected to fail happened to continue.
    if [[ -n $forbidden_persisted_value ]] &&
        docker exec --user openldap "$target_container" \
          grep -R -F -- "$forbidden_persisted_value" /etc/ldap/slapd.d >/dev/null 2>&1; then
      printf '%s\n' "$output" >&2
      echo "$rejected_case exposed a root-only marker in service-readable configuration." >&2
    else
      printf '%s\n' "$output" >&2
      echo "$rejected_case unexpectedly continued initialization." >&2
    fi
    docker rm --force --volumes "$target_container" >/dev/null
    return 1
  fi

  exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$target_container")
  docker rm --force --volumes "$target_container" >/dev/null
  if [[ $exit_code == 0 || $output != *"$expected_message"* ||
        $output == *"Starting slapd for init/migration..."* ]]; then
    printf '%s\n' "$output" >&2
    echo "$rejected_case did not fail before LDAP initialization." >&2
    return 1
  fi
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
  local ppm_config=${9:-}
  local provider_tls_ssf=${10:-0128}
  local tls_mode=${11:-auto}
  local -a replication_options=()
  local -a ppm_options=()
  local -a tls_ca_options=()
  local -a tls_mode_options=()
  local -a tls_server_options=()
  local -a tls_source_options=()
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
    # Keep the zero-padded default at this boundary so every ordinary provider
    # start covers input normalization; lifecycle tests can still select 0
    # without relying on duplicate Docker environment entries and their order.
    tls_server_options=(
      --env LDAP_TLS_VERIFY_CLIENT=never
      --env LDAP_TLS_SSF="$provider_tls_ssf"
    )
  fi
  # Keep the CA explicit at each call site: one restart intentionally omits it
  # to prove persisted syncrepl fails closed instead of serving stale data.
  if [[ -n $ca_file ]]; then
    tls_ca_options=(--env LDAP_TLS_CA_FILE=/opt/test-ca.crt)
  fi
  if [[ -n $ppm_config ]]; then
    ppm_options=(--env LDAP_PPOLICY_PPM_CONFIG="$ppm_config")
  fi
  if [[ $tls_mode == false ]]; then
    tls_mode_options=(--env LDAP_TLS_ENABLED=false)
  else
    tls_source_options=(
      --env LDAP_TLS_CERT_FILE=/opt/test-server.crt
      --env LDAP_TLS_KEY_FILE=/opt/test-server.key
    )
  fi

  # Resource names stay unique for parallel tests, while the isolated network
  # aliases remain stable so certificate hostname verification can stay strict.
  # Ordinary nodes omit LDAP_TLS_ENABLED so the fixture covers certificate-and-key
  # auto-detection. The disablement lifecycle explicitly sets false and omits the
  # sources to reproduce a container recreated with only its documented volumes.
  docker create --name "$node" --hostname "$network_alias" \
    --network "$replication_network" --network-alias "$network_alias" \
    --network-alias "${network_alias}-cn-only" \
    --env LDAP_BACKUP_TIME="$backup_time" \
    --env LDAP_INIT_ROOT_USER_PW="$root_password" \
    --env CUSTOM_SCHEMA_ATTRIBUTE_NAME=customBootstrapValue \
    "${replication_options[@]}" \
    "${ppm_options[@]}" \
    "${tls_ca_options[@]}" \
    "${tls_mode_options[@]}" \
    "${tls_server_options[@]}" \
    "${tls_source_options[@]}" \
    --mount "type=volume,src=$node_config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$node_data_volume,dst=/var/lib/ldap" \
    "$image_name" >/dev/null

  # Copy before start so issue #50's TLS ordering is preserved. docker cp also
  # works when this script runs in act, where nested host bind paths do not.
  if [[ -n $ca_file ]]; then
    docker cp "$ca_file" "$node:/opt/test-ca.crt"
  fi
  if [[ $tls_mode != false ]]; then
    docker cp "$docker_cert_file" "$node:/opt/test-server.crt"
    docker cp "$docker_key_file" "$node:/opt/test-server.key"
  fi
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
  local ldap_uri=${2:-ldaps://consumer}
  local target_consumer=${3:-$consumer_container}
  local -a tls_options=()

  # Most checks exercise the normal LDAPS listener. The inbound-disable lifecycle
  # deliberately has no TLS listener, so keep the transport selectable without
  # weakening certificate verification for the default path.
  if [[ $ldap_uri == ldaps://* ]]; then
    tls_options=(
      --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt
      --env LDAPTLS_REQCERT=demand
    )
  fi

  for _ in {1..120}; do
    # A successful base-scope lookup is the protocol-level existence check; DN
    # text is unsuitable because servers may normalize attribute type casing.
    if docker exec \
        "${tls_options[@]}" \
        "$target_consumer" \
        ldapsearch -LLL -x -H "$ldap_uri" \
          -D "$root_dn" -w "$root_password" \
          -b "$entry_dn" -s base '(objectClass=*)' 1.1 >/dev/null 2>&1; then
      return 0
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$target_consumer") != true ]]; then
      break
    fi
    sleep 0.5
  done

  docker logs --tail 80 "$target_consumer" >&2
  echo "Replication did not deliver $entry_dn." >&2
  return 1
}

function count_normalized_config_values() {
  local config=$1
  local attribute=$2
  local expected=$3
  local expected_index=${4:-}
  local count=0
  local index
  local line
  local value
  local -a fields=()

  while IFS= read -r line; do
    [[ $line == "$attribute: "* ]] || continue
    value=${line#"$attribute: "}
    if [[ $value =~ ^\{([0-9]+)\}(.*)$ ]]; then
      index=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
    else
      index=""
    fi

    # Most assertions count a value anywhere. ACL-order regressions also pass the
    # required ordinal so a matching but ineffective later rule cannot pass.
    # OpenLDAP chooses the stored form: it adds indexes, reorders equivalent
    # clauses, and may insert extra spaces. Full equality after folding that
    # formatting keeps the test strict without depending on raw LDIF text.
    fields=()
    read -r -a fields <<<"$value"
    if [[ ${fields[*]} == "$expected" &&
          ( -z $expected_index || $index == "$expected_index" ) ]]; then
      ((count += 1))
    fi
  done <<<"$config"

  printf '%s\n' "$count"
}

# ==============================================================================
# Test fixture definitions
# ==============================================================================

mkdir "$custom_ldif_dir" "$custom_schema_ldif_dir"
printf 'not a directory\n' >"$invalid_schema_path_file"

# Keep the normal default-policy behavior while deliberately omitting
# LDAP_INIT_PPOLICY_PPM_CONFIG. Mounted policy templates are not required to know
# about the image's internal interpolation fragment.
cat >"$custom_policy_ldif_file" <<'LDIF'
version: 1

dn: ou=Policies,${LDAP_INIT_ORG_DN}
ou: Policies
objectClass: top
objectClass: organizationalUnit

dn: ${LDAP_INIT_PPOLICY_DEFAULT_DN:-cn=DefaultPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}}
objectClass: top
objectClass: device
objectClass: pwdPolicy
objectClass: pwdPolicyChecker
cn: DefaultPasswordPolicy
pwdAttribute: userPassword
pwdFailureCountInterval: 0
pwdMaxFailure: ${LDAP_INIT_PPOLICY_MAX_FAILURES:-3}
pwdMinAge: 0
pwdMustChange: TRUE
pwdSafeModify: FALSE
pwdInHistory: 0
pwdGraceAuthNLimit: 0
pwdLockoutDuration: ${LDAP_INIT_PPOLICY_LOCKOUT_DURATION:-300}
pwdAllowUserChange: TRUE
pwdExpireWarning: 0
pwdLockout: TRUE
pwdMaxAge: 0
pwdMinLength: ${LDAP_INIT_PPOLICY_PW_MIN_LENGTH:-8}
pwdCheckQuality: 2

# This policy starts disabled so initialization itself, not only a later restart,
# proves that global PPM settings do not override an explicit per-policy opt-out.
dn: cn=DisabledPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}
objectClass: top
objectClass: device
objectClass: pwdPolicy
objectClass: pwdPolicyChecker
cn: DisabledPasswordPolicy
pwdUseCheckModule: FALSE
pwdAttribute: userPassword
pwdCheckQuality: 2
LDIF

# Stop at the first policy write. The host test can inspect the active migration,
# then force it to fail and retry with the image's normal client. ACL setup uses
# the same attribute names, so only the base64 policy value line identifies it.
cat >"$ldapmodify_failure_wrapper" <<'SH'
#!/bin/sh
set -eu
input=$(mktemp)
trap 'rm -f "$input"' EXIT
cat >"$input"
if grep -F 'pwdCheckModuleArg:: ' "$input" >/dev/null; then
  : >/run/ppm-reconcile-blocked
  while [ ! -e /run/ppm-reconcile-release ]; do
    sleep 0.1
  done
  exit 1
fi
/usr/bin/ldapmodify "$@" <"$input"
SH
chmod +x "$ldapmodify_failure_wrapper"

# The probe replaces offline configuration tools only inside selected test
# containers. It records the effective UID at each executable boundary, then
# delegates unchanged, so the test does not need a hostile LDAP module.
cat >"$offline_tool_uid_entrypoint" <<'SH'
#!/bin/sh
set -eu

# OpenLDAP's hard-linked admin binary selects its mode from argv[0]. Keep the
# original basename when moving each link aside or the delegate can select the
# wrong tool mode.
for tool in slapcat slapadd; do
  mkdir "/run/real-$tool"
  mv "/usr/sbin/$tool" "/run/real-$tool/$tool"
  # Fixed calls reach the wrapper as openldap, so the root-created record must be
  # service-writable while still allowing the baseline's root calls to append.
  install -o openldap -g openldap -m 0600 /dev/null "/run/$tool-uids"
  cat >"/usr/sbin/$tool" <<WRAPPER
#!/bin/sh
set -eu
id -u >>/run/$tool-uids
exec /run/real-$tool/$tool "\$@"
WRAPPER
  chmod 0755 "/usr/sbin/$tool"
done
exec "$@"
SH
chmod +x "$offline_tool_uid_entrypoint"

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

# shellcheck source=tests/image/ppm.sh
source "$script_dir/tests/image/ppm.sh"
test_ppm_functions

# shellcheck source=tests/image/root-password.sh
source "$script_dir/tests/image/root-password.sh"
test_root_password_file

# shellcheck source=tests/image/config-migration.sh
source "$script_dir/tests/image/config-migration.sh"
test_config_migration_functions
test_legacy_ppolicy_schema_migration_from_openldap_24

# shellcheck source=tests/image/version-marker.sh
source "$script_dir/tests/image/version-marker.sh"
test_version_marker_security

# shellcheck source=tests/image/bootstrap-backup.sh
source "$script_dir/tests/image/bootstrap-backup.sh"
test_bootstrap_backup_and_ppm

# shellcheck source=tests/image/validation.sh
source "$script_dir/tests/image/validation.sh"
test_startup_validation

# shellcheck source=tests/image/replication.sh
source "$script_dir/tests/image/replication.sh"
test_replication

test_phase "All image integration checks passed"
