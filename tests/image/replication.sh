#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# TLS syncrepl and persisted-consumer lifecycle checks.
# This file is sourced by test-image.sh and intentionally shares its fixtures,
# helpers, and cleanup trap so scenario boundaries do not create extra Docker
# resources or alter lifecycle ordering.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_replication() {
# ==============================================================================
# Syncrepl bootstrap, TLS, and initial synchronization
# ==============================================================================

command -v openssl >/dev/null || {
  echo "openssl is required for the TLS replication lifecycle test." >&2
  exit 1
}

test_phase "Checking TLS replication and consumer backup lifecycle"

mkdir "$tls_dir" "$replication_secret_dir"
printf '%s\n' \
  '[server]' \
  'subjectAltName=DNS:provider,DNS:consumer,DNS:consumer-2' \
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
# A single short-lived test keypair keeps the fixture small; its SANs match all
# fixed Docker DNS names so hostname verification remains strict on every hop.
openssl x509 -req -sha256 -days 1 \
  -in "$tls_dir/server.csr" \
  -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" -CAcreateserial \
  -extfile "$tls_dir/server.ext" -extensions server \
  -out "$tls_dir/server.crt" >/dev/null 2>&1
# docker cp assigns root ownership and preserves these modes where the host can
# represent them. The 0600 key then exercises the protected root-readable path;
# validation.sh provides direct container-side coverage on other hosts.
chmod 0600 "$tls_dir/server.key"
chmod 0644 "$tls_dir/server.crt" "$tls_dir/ca.crt"

# Windows-native secret generators commonly terminate text with CRLF. The
# container must discard that terminator without treating CR as password data.
printf '%s\r\n' "$replication_password" >"$replication_password_file"
chmod 600 "$replication_password_file"

test_step "Rejecting a service-controlled replication password link"
docker create --name "$replication_password_path_container" \
  --hostname replication-password-path-probe \
  --env LDAP_BACKUP_TIME= \
  --env LDAP_INIT_ROOT_USER_PW="$root_password" \
  --env INIT_SH_FILE=/opt/replication-password-path-probe.sh \
  --env REPLICATION_PASSWORD_PATH_TEST_MARKER="$replication_password_path_marker" \
  --env LDAP_INIT_REPLICATION_ROLE=consumer \
  --env LDAP_INIT_REPLICATION_PROVIDER_URI=ldaps://provider \
  --env LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE=/run/replication-password-source/password-link \
  --env LDAP_TLS_CERT_FILE=/opt/test-server.crt \
  --env LDAP_TLS_KEY_FILE=/opt/test-server.key \
  --env LDAP_TLS_CA_FILE=/opt/test-ca.crt \
  "$image_name" >/dev/null
docker cp "$docker_replication_password_path_probe_file" \
  "$replication_password_path_container:/opt/replication-password-path-probe.sh"
docker cp "$docker_cert_file" "$replication_password_path_container:/opt/test-server.crt"
docker cp "$docker_key_file" "$replication_password_path_container:/opt/test-server.key"
docker cp "$docker_ca_file" "$replication_password_path_container:/opt/test-ca.crt"
docker start "$replication_password_path_container" >/dev/null
assert_initialization_rejected \
  "$replication_password_path_container" \
  "must name a readable regular file" \
  "A service-controlled replication-password link" \
  "$replication_password_path_marker"

docker network create "$replication_network" >/dev/null
for volume in \
    "$provider_config_volume" "$provider_data_volume" \
    "$consumer_config_volume" "$consumer_data_volume" \
    "$second_consumer_config_volume" "$second_consumer_data_volume"; do
  docker volume create "$volume" >/dev/null
done

# Match the current minute so the backup worker is immediately eligible. Keeping
# the provider offline then proves it waits for the initial refresh rather than
# publishing the consumer's empty database.
consumer_backup_time=$(date +%H:%M)
start_replication_node \
  "$consumer_container" consumer "$consumer_config_volume" "$consumer_data_volume" \
  consumer ldaps://provider "$docker_ca_file" "$consumer_backup_time" \
  "$consumer_conflicting_ppm_config"
wait_until_ready "$consumer_container"

# Each syncrepl rid is local to its consumer. A second node can therefore use the
# same generated configuration and bind identity, but it must own independent
# config and data volumes so the two slapd processes never share database files.
start_replication_node \
  "$second_consumer_container" consumer-2 \
  "$second_consumer_config_volume" "$second_consumer_data_volume" \
  consumer ldaps://provider "$docker_ca_file" '' \
  "$consumer_conflicting_ppm_config"
wait_until_ready "$second_consumer_container"

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

start_replication_node \
  "$provider_container" provider "$provider_config_volume" "$provider_data_volume" \
  provider '' '' '' "$provider_ppm_config"
wait_until_ready "$provider_container"
# Client verification is disabled, so the provider must not need unused
# peer-trust material merely to serve LDAPS to the consumer.
docker exec "$provider_container" test ! -e /etc/ldap/certs/ca.crt

# Query both attributes together: the overall policy and the local transport
# allowance are one startup invariant, not two independently acceptable states.
provider_security=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcSecurity olcLocalSSF)
if [[ $provider_security != *"olcSecurity: ssf=128"* ||
      $provider_security != *"olcLocalSSF: 128"* ]]; then
  printf '%s\n' "$provider_security" >&2
  echo "The provider did not apply the normalized TLS SSF policy atomically." >&2
  exit 1
fi

# A valid simple bind must fail only because the unprotected transport has SSF
# zero. The same credentials over verified LDAPS distinguish policy enforcement
# from an unrelated authentication or account-policy failure.
if docker exec "$provider_container" \
    ldapwhoami -x -H ldap:/// -D "$root_dn" -w "$root_password" >/dev/null 2>&1; then
  echo "The provider accepted a plaintext bind despite LDAP_TLS_SSF=128." >&2
  exit 1
fi
docker exec --env LDAPTLS_CACERT=/opt/test-ca.crt "$consumer_container" \
  ldapwhoami -x -H ldaps://provider -D "$root_dn" -w "$root_password" >/dev/null

# Use the provider's optional default CA path so the same container can first
# stage a current source and then lose only that source. The managed copy survives
# the second restart, proving stopped reconciliation uses current-start readiness
# rather than destination existence when removing the global CA attribute.
docker exec "$provider_container" mkdir -p /run/secrets/ldap
docker cp "$docker_ca_file" "$provider_container:/run/secrets/ldap/ca.crt"
docker restart "$provider_container" >/dev/null
wait_until_ready "$provider_container"
provider_ca_config=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcTLSCACertificateFile)
if [[ $provider_ca_config != *"olcTLSCACertificateFile: /etc/ldap/certs/ca.crt"* ]]; then
  printf '%s\n' "$provider_ca_config" >&2
  echo "The provider did not publish its current optional CA source." >&2
  exit 1
fi

docker exec "$provider_container" rm /run/secrets/ldap/ca.crt
docker restart "$provider_container" >/dev/null
wait_until_ready "$provider_container"
provider_ca_config=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcTLSCACertificateFile)
if [[ $provider_ca_config == *"olcTLSCACertificateFile:"* ]] ||
    ! docker exec "$provider_container" test -s /etc/ldap/certs/ca.crt; then
  printf '%s\n' "$provider_ca_config" >&2
  echo "A stale optional CA remained active after a same-container restart." >&2
  exit 1
fi

function restart_replication_provider() {
  local tls_ssf=${1:-0128}

  docker stop "$provider_container" >/dev/null
  docker rm "$provider_container" >/dev/null
  # Recreate rather than restart the container so the entrypoint must reconcile
  # the requested policy against the persisted cn=config on every invocation.
  start_replication_node \
    "$provider_container" provider "$provider_config_volume" "$provider_data_volume" \
    provider '' '' '' "$provider_ppm_config" "$tls_ssf"
  wait_until_ready "$provider_container"
}

# Reproduce a volume created by an older image or changed by an administrator:
# the overall floor is already active, but no explicit local allowance exists.
# The entrypoint must repair that persisted state before its readiness bind,
# because an online reconciliation cannot run until the bind succeeds.
docker exec -i "$provider_container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: cn=config
changetype: modify
delete: olcLocalSSF
LDIF

restart_replication_provider
provider_security=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcSecurity olcLocalSSF)
if [[ $provider_security != *"olcSecurity: ssf=128"* ||
      $provider_security != *"olcLocalSSF: 128"* ]]; then
  printf '%s\n' "$provider_security" >&2
  echo "The provider did not repair its local SSF before restarting." >&2
  exit 1
fi

# Administrator-owned factors must survive both removal and restoration of the
# image-owned overall ssf factor. Keep both update floors above the image's local
# floor, with update_transport higher, so the restart proves that the entrypoint
# accounts for each independent requirement before making its own LDAP writes.
docker exec -i "$provider_container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: update_ssf=192
olcSecurity: update_transport=193
LDIF

restart_replication_provider 0
provider_security=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcSecurity olcLocalSSF)
if [[ ${provider_security,,} == *"olcsecurity: ssf="* ||
      $provider_security != *"olcSecurity: update_ssf=192"* ||
      $provider_security != *"olcSecurity: update_transport=193"* ||
      $provider_security != *"olcLocalSSF: 193"* ]]; then
  printf '%s\n' "$provider_security" >&2
  echo "LDAP_TLS_SSF=0 did not remove only the image-owned overall factor." >&2
  exit 1
fi
# The surviving requirements constrain updates only. A successful plaintext bind
# therefore still proves that removing the image-owned overall floor took effect.
docker exec "$provider_container" \
  ldapwhoami -x -H ldap:/// -D "$root_dn" -w "$root_password" >/dev/null
docker exec "$provider_container" \
  ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null

restart_replication_provider
provider_security=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcSecurity olcLocalSSF)
if [[ $provider_security != *"olcSecurity: ssf=128"* ||
      $provider_security != *"olcSecurity: update_ssf=192"* ||
      $provider_security != *"olcSecurity: update_transport=193"* ||
      $provider_security != *"olcLocalSSF: 193"* ]]; then
  printf '%s\n' "$provider_security" >&2
  echo "The provider did not restore SSF 128 while preserving unrelated factors." >&2
  exit 1
fi
if docker exec "$provider_container" \
    ldapwhoami -x -H ldap:/// -D "$root_dn" -w "$root_password" >/dev/null 2>&1; then
  echo "The restarted provider accepted a plaintext bind with LDAP_TLS_SSF=128." >&2
  exit 1
fi
docker exec "$provider_container" \
  ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null

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

# A successful bind proves that the credential works, not which cost profile was
# persisted. Inspect the provider-owned entry so replication covers the same
# initialization hash policy as root and user password changes.
replication_account=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldapi:/// \
    -D "$root_dn" -w "$root_password" \
    -b "$replication_dn" -s base userPassword)
replication_password_hash=$(sed -n 's/^userPassword: //p' <<<"$replication_account")
if [[ -z $replication_password_hash ]]; then
  # Keep this parser local so a replication failure names the provider lookup and
  # does not depend on the password-hash scenario's helper or source ordering.
  replication_password_hash_base64=$(sed -n 's/^userPassword:: //p' <<<"$replication_account")
  if [[ -z $replication_password_hash_base64 ]]; then
    echo "The replication account search did not return userPassword." >&2
    exit 1
  fi
  if ! replication_password_hash=$(printf '%s' "$replication_password_hash_base64" | base64 -d); then
    echo "The replication account password hash is not valid Base64." >&2
    exit 1
  fi
fi
# Dollar signs delimit Argon2 PHC fields and must remain literal shell input.
if [[ $replication_password_hash != "{ARGON2}\$argon2id\$"* ]]; then
  echo "The replication account does not use the default Argon2 password hash." >&2
  exit 1
fi

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
wait_for_replica_entry 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com'
# One provider entry reaching two independently initialized consumers is the
# supported one-to-many contract. Do not infer synchronized cn=config: each node
# loaded its local schema before the shared directory entry could be accepted.
wait_for_replica_entry \
  'cn=replication-before-restart,DC=example,DC=com' \
  ldaps://consumer-2 \
  "$second_consumer_container"

# Both nodes receive conflicting local input, but the consumer's suffix belongs
# to syncrepl. Its policy must therefore retain the provider-authored PPM text.
consumer_policy=$(docker exec \
  --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
  --env LDAPTLS_REQCERT=demand \
  "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldaps://consumer \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdCheckModuleArg)
consumer_ppm_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$consumer_policy")
consumer_ppm_arg=$(printf '%s' "$consumer_ppm_arg_base64" | base64 -d)
if [[ $consumer_ppm_arg != "$provider_ppm_config" ]]; then
  printf '%s\n' "$consumer_policy" >&2
  echo "The replication consumer replaced the provider's PPM configuration." >&2
  exit 1
fi

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
function assert_replication_consumer_read_only() {
  local target_consumer=$1
  local ldap_uri=$2

  if docker exec -i \
      --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
      --env LDAPTLS_REQCERT=demand \
      "$target_consumer" \
      ldapadd -x -H "$ldap_uri" -D "$root_dn" -w "$root_password" >/dev/null 2>&1 <<'LDIF'; then
dn: cn=must-not-be-written-locally,DC=example,DC=com
objectClass: top
objectClass: organizationalRole
cn: must-not-be-written-locally
LDIF
    echo "Replication consumer [$target_consumer] accepted a local write." >&2
    return 1
  fi
}

assert_replication_consumer_read_only "$consumer_container" ldaps://consumer
assert_replication_consumer_read_only "$second_consumer_container" ldaps://consumer-2

# ==============================================================================
# Persisted consumer restart and replication recovery
# ==============================================================================

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
  '' '' "$docker_ca_file" '' "$consumer_conflicting_ppm_config"
wait_until_ready "$consumer_container"
if [[ $(docker logs "$consumer_container" 2>&1) == *"Applying initial configuration"* ]]; then
  echo "The persisted replication consumer was unexpectedly reinitialized." >&2
  exit 1
fi

consumer_policy_after_restart=$(docker exec \
  --env LDAPTLS_CACERT=/etc/ldap/certs/ca.crt \
  --env LDAPTLS_REQCERT=demand \
  "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -x -H ldaps://consumer \
    -D "$root_dn" -w "$root_password" \
    -b 'cn=DefaultPasswordPolicy,ou=Policies,DC=example,DC=com' -s base \
    '(objectClass=*)' pwdCheckModuleArg)
consumer_restart_arg_base64=$(sed -n 's/^pwdCheckModuleArg:: //p' <<<"$consumer_policy_after_restart")
consumer_restart_arg=$(printf '%s' "$consumer_restart_arg_base64" | base64 -d)
consumer_access=$(docker exec "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcAccess)
# Compare complete normalized ACLs because OpenLDAP adds ordered prefixes and
# preserves quotes around filters; raw substrings can silently miss a managed rule.
consumer_search_acl_count=$(count_normalized_config_values \
  "$consumer_access" olcAccess "$ppm_search_acl")
consumer_write_acl_count=$(count_normalized_config_values \
  "$consumer_access" olcAccess "$ppm_write_acl")
if [[ $consumer_restart_arg != "$provider_ppm_config" ||
      $consumer_search_acl_count != 0 || $consumer_write_acl_count != 0 ]]; then
  printf '%s\n%s\n' "$consumer_policy_after_restart" "$consumer_access" >&2
  echo "A consumer restart locally reconciled provider-owned PPM policy data." >&2
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
  '' '' "$docker_ca_file" '' "$consumer_conflicting_ppm_config"
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

# Recreate the persisted consumer without server certificates. Disabling its
# inbound TLS must not suppress the current CA source needed by outbound syncrepl.
docker stop "$consumer_container" >/dev/null
docker rm "$consumer_container" >/dev/null
# The tenth helper argument is provider-only; retain its default value solely to
# select the eleventh-slot TLS mode for this role-less persisted restart.
start_replication_node \
  "$consumer_container" consumer "$consumer_config_volume" "$consumer_data_volume" \
  '' '' "$docker_ca_file" '' '' 0128 false
wait_until_ready "$consumer_container"
docker exec "$consumer_container" test ! -e /etc/ldap/certs/server.crt
docker exec "$consumer_container" test ! -e /etc/ldap/certs/server.key
consumer_tls_config=$(docker exec "$consumer_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base '(objectClass=*)' \
    olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCACertificateFile \
    olcTLSVerifyClient olcSecurity)
if [[ $consumer_tls_config == *"olcTLSCertificateFile:"* ||
      $consumer_tls_config == *"olcTLSCertificateKeyFile:"* ||
      $consumer_tls_config == *"olcTLSCACertificateFile:"* ||
      $consumer_tls_config == *"olcTLSVerifyClient:"* ||
      ${consumer_tls_config,,} == *"olcsecurity: ssf="* ]]; then
  printf '%s\n' "$consumer_tls_config" >&2
  echo "Disabling inbound TLS left managed server attributes on the consumer." >&2
  exit 1
fi
docker exec "$consumer_container" \
  ldapwhoami -x -H ldap://127.0.0.1 -D "$root_dn" -w "$root_password" >/dev/null

docker exec -i "$provider_container" \
  ldapadd -x -H ldapi:/// -D "$root_dn" -w "$root_password" <<'LDIF'
dn: cn=replication-with-inbound-tls-disabled,DC=example,DC=com
objectClass: top
objectClass: organizationalRole
cn: replication-with-inbound-tls-disabled
LDIF

# Query over plaintext because the listener is intentionally disabled; the new
# provider write, rather than retained data, proves outbound syncrepl still runs.
wait_for_replica_entry \
  'cn=replication-with-inbound-tls-disabled,DC=example,DC=com' \
  'ldap://127.0.0.1'

# Recreate the provider with only its documented persistent volumes. Its old
# cn=config still names certificate copies from the removed container, so those
# attributes must be removed before the temporary maintenance daemon starts.
docker stop "$provider_container" >/dev/null
docker rm "$provider_container" >/dev/null
start_replication_node \
  "$provider_container" provider "$provider_config_volume" "$provider_data_volume" \
  provider '' '' '' "$provider_ppm_config" 0 false
wait_until_ready "$provider_container"
docker exec "$provider_container" test ! -e /etc/ldap/certs/server.crt
docker exec "$provider_container" test ! -e /etc/ldap/certs/server.key
provider_tls_config=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base '(objectClass=*)' \
    olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCACertificateFile \
    olcTLSVerifyClient olcSecurity)
if [[ $provider_tls_config == *"olcTLSCertificateFile:"* ||
      $provider_tls_config == *"olcTLSCertificateKeyFile:"* ||
      $provider_tls_config == *"olcTLSCACertificateFile:"* ||
      $provider_tls_config == *"olcTLSVerifyClient:"* ||
      ${provider_tls_config,,} == *"olcsecurity: ssf="* ||
      $provider_tls_config != *"olcSecurity: update_ssf=192"* ||
      $provider_tls_config != *"olcSecurity: update_transport=193"* ]]; then
  printf '%s\n' "$provider_tls_config" >&2
  echo "Disabling TLS did not remove only the image-managed persisted attributes." >&2
  exit 1
fi
docker exec "$provider_container" \
  ldapwhoami -x -H ldap:/// -D "$root_dn" -w "$root_password" >/dev/null

# Restore the provider's normal TLS sources for the remaining transport-floor
# check. This also proves that online enablement still follows offline disablement.
restart_replication_provider

# Exercise the general transport floor only after all remote replication checks.
# It measures the underlying socket rather than TLS layered over TCP, so enabling
# it earlier would deliberately disconnect syncrepl and obscure this local-startup
# invariant with retry timing. Keeping it above both update floors makes the final
# readiness search prove that the stopped-server preflight raises local SSF first.
docker exec -i "$provider_container" \
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: transport=194
LDIF

restart_replication_provider
provider_security=$(docker exec "$provider_container" \
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
    -b 'cn=config' -s base olcSecurity olcLocalSSF)
if [[ $provider_security != *"olcSecurity: ssf=128"* ||
      $provider_security != *"olcSecurity: update_ssf=192"* ||
      $provider_security != *"olcSecurity: update_transport=193"* ||
      $provider_security != *"olcSecurity: transport=194"* ||
      $provider_security != *"olcLocalSSF: 194"* ]]; then
  printf '%s\n' "$provider_security" >&2
  echo "The provider did not satisfy and preserve its transport SSF floors." >&2
  exit 1
fi
}
