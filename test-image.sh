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

create_fresh_volumes
# RFC2307bis is opt-in, so exercise its generated slapadd input here. Later
# fresh replication fixtures retain default-schema coverage.
start_container \
  --bootstrap-ldifs \
  --env INIT_SH_FILE=/opt/ldifs/custom/.init.sh \
  --env LDAP_INIT_RFC2307BIS_SCHEMA=1 \
  --env CUSTOM_ENTRY_CN=custom-entry \
  --env CUSTOM_SCHEMA_ATTRIBUTE_NAME=customBootstrapValue

wait_until_ready
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

docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
docker volume rm "$config_volume" "$data_volume" >/dev/null
create_fresh_volumes

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
