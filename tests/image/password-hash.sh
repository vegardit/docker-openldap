#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Verifies password-hash bootstrap policy, its legacy opt-out, and persisted verifier compatibility.
# This file is sourced by test-image.sh and shares its primary container and volume fixtures.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.

function read_ldif_attribute_value() {
  local ldif=$1
  local attribute=$2
  local encoded_value
  local value

  value=$(sed -n "s/^${attribute}: //p" <<<"$ldif")
  if [[ -n $value ]]; then
    printf '%s' "$value"
    return 0
  fi

  # LDAP tools base64-encode values when their bytes are not safe in plain LDIF.
  # slapd's Argon2 password-modify result includes a terminating NUL; remove that
  # C-string detail because Bash cannot store it, while the bind checks below
  # still validate the complete persisted credential through OpenLDAP itself.
  encoded_value=$(sed -n "s/^${attribute}:: //p" <<<"$ldif")
  if [[ -z $encoded_value ]]; then
    # Do not echo credential-bearing LDIF merely to improve a test failure.
    echo "LDIF does not contain [$attribute] in plain or Base64 form." >&2
    return 1
  fi
  if ! printf '%s' "$encoded_value" | base64 -d | tr -d '\000'; then
    echo "LDIF contains malformed Base64 for [$attribute]." >&2
    return 1
  fi
}

function assert_hash_prefix() {
  local value=$1
  local expected_prefix=$2
  local description=$3

  if [[ $value != "$expected_prefix"* ]]; then
    echo "$description does not use the expected [$expected_prefix] password hash." >&2
    exit 1
  fi
}

function remove_password_hash_test_instance() {
  docker rm --force --volumes "$container" >/dev/null 2>&1 || true
  docker volume rm --force "$config_volume" "$data_volume" >/dev/null 2>&1 || true
}

function create_password_hash_test_instance() {
  # Reusing the primary fixture names keeps the global cleanup trap authoritative.
  # Both volumes must be replaced because the setting is intentionally first-run only.
  remove_password_hash_test_instance
  create_fresh_volumes
}

function replace_guest_password_hash() {
  local target_container=$1
  local password_hash=$2

  # Root DN intentionally bypasses ppolicy here, so pre-hashed fixtures isolate
  # hash-scheme verification from password-quality enforcement.
  docker exec -i "$target_container" \
    ldapmodify -x -H ldap://127.0.0.1 \
      -D "$root_dn" -w "$root_password" >/dev/null <<LDIF
dn: $guest_dn
changetype: modify
replace: userPassword
userPassword: $password_hash
LDIF
}

function test_password_hash_configuration() {
  local argon_module_count
  local argon_hash
  # Dollar signs delimit Argon2 PHC fields and must remain literal shell input.
  local argon2_hash_prefix="{ARGON2}\$argon2id\$"
  local changed_password='Strong2!'
  local config_modules
  local frontend_config
  local frontend_hash
  local legacy_hash
  local legacy_password='Legacy1!'
  local root_config
  local root_hash
  local user_entry
  local user_hash

  test_phase "Checking password hash configuration"

  create_password_hash_test_instance
  test_step "Reusing a custom-schema Argon2 module load during initialization"
  start_container \
    --bootstrap-ldifs \
    --env CUSTOM_ENTRY_CN=custom-entry \
    --env CUSTOM_SCHEMA_ATTRIBUTE_NAME=customBootstrapValue
  if ! wait_until_ready; then
    echo "A fresh installation did not reuse its custom-schema Argon2 module load." >&2
    exit 1
  fi

  frontend_config=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'olcDatabase={-1}frontend,cn=config' -s base olcPasswordHash)
  frontend_hash=$(read_ldif_attribute_value "$frontend_config" olcPasswordHash)
  if [[ $frontend_hash != '{ARGON2}' ]]; then
    printf '%s\n' "$frontend_config" >&2
    echo "A fresh installation does not select ARGON2 as its password hash." >&2
    exit 1
  fi

  config_modules=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'cn=module{0},cn=config' -s base olcModuleLoad)
  argon_module_count=$(grep -Eic '^olcModuleLoad: .*argon2' <<<"$config_modules" || true)
  if [[ $argon_module_count != 1 ]]; then
    printf '%s\n' "$config_modules" >&2
    echo "A fresh installation did not retain exactly one Argon2 module load." >&2
    exit 1
  fi

  root_config=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'olcDatabase={1}mdb,cn=config' -s base olcRootPW)
  root_hash=$(read_ldif_attribute_value "$root_config" olcRootPW)
  assert_hash_prefix "$root_hash" "$argon2_hash_prefix" "The root user"

  docker exec "$container" \
    ldappasswd -x -H ldap://127.0.0.1 \
      -D "$root_dn" -w "$root_password" -s "$changed_password" "$guest_dn" >/dev/null
  user_entry=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
      -D "$root_dn" -w "$root_password" -b "$guest_dn" -s base userPassword)
  user_hash=$(read_ldif_attribute_value "$user_entry" userPassword)
  assert_hash_prefix "$user_hash" "$argon2_hash_prefix" "A password changed through LDAP"
  argon_hash=$user_hash
  docker exec "$container" \
    ldapwhoami -x -H ldap://127.0.0.1 \
      -D "$guest_dn" -w "$changed_password" >/dev/null

  # A password generated through the legacy scheme isolates verification from
  # olcPasswordHash: the latter controls new hashes but must not invalidate old ones.
  legacy_hash=$(printf '%s' "$legacy_password" | \
    docker exec -i "$container" slappasswd -h '{SSHA}' -T /dev/stdin)
  replace_guest_password_hash "$container" "$legacy_hash"
  docker restart "$container" >/dev/null
  wait_until_ready
  docker exec "$container" \
    ldapwhoami -x -H ldap://127.0.0.1 \
      -D "$guest_dn" -w "$legacy_password" >/dev/null

  create_password_hash_test_instance
  start_container --env LDAP_INIT_PASSWORD_HASH=SSHA
  wait_until_ready

  frontend_config=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'olcDatabase={-1}frontend,cn=config' -s base olcPasswordHash)
  frontend_hash=$(read_ldif_attribute_value "$frontend_config" olcPasswordHash)
  if [[ $frontend_hash != '{SSHA}' ]]; then
    printf '%s\n' "$frontend_config" >&2
    echo "LDAP_INIT_PASSWORD_HASH=SSHA did not select the legacy password hash." >&2
    exit 1
  fi

  root_config=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'olcDatabase={1}mdb,cn=config' -s base olcRootPW)
  root_hash=$(read_ldif_attribute_value "$root_config" olcRootPW)
  assert_hash_prefix "$root_hash" '{SSHA}' "The root user with the legacy opt-out"

  docker exec "$container" \
    ldappasswd -x -H ldap://127.0.0.1 \
      -D "$root_dn" -w "$root_password" -s "$changed_password" "$guest_dn" >/dev/null
  user_entry=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -x -H ldap://127.0.0.1 \
      -D "$root_dn" -w "$root_password" -b "$guest_dn" -s base userPassword)
  user_hash=$(read_ldif_attribute_value "$user_entry" userPassword)
  assert_hash_prefix "$user_hash" '{SSHA}' "A password changed with the legacy opt-out"
  docker exec "$container" \
    ldapwhoami -x -H ldap://127.0.0.1 \
      -D "$guest_dn" -w "$changed_password" >/dev/null

  # The daemon module remains loaded independently of the generation default so
  # directories imported during SSHA compatibility mode can contain Argon2 hashes.
  replace_guest_password_hash "$container" "$argon_hash"
  docker exec "$container" \
    ldapwhoami -x -H ldap://127.0.0.1 \
      -D "$guest_dn" -w "$changed_password" >/dev/null

  create_password_hash_test_instance
  start_container
  wait_until_ready
  docker stop "$container" >/dev/null
  docker rm "$container" >/dev/null

  test_step "Reusing operator-owned Argon2 module configuration"
  # Persist one valid load outside the image-owned list and include both the
  # packaged .la alias and module arguments. Startup must recognize the global
  # module state without rewriting either list or loading the password scheme twice.
  # slapcat validates the referenced MDB path even when exporting only cn=config,
  # so the offline helper needs the matching data volume as well.
  docker run --rm -i --user openldap --entrypoint bash \
    --mount "type=volume,src=$config_volume,dst=/etc/ldap/slapd.d" \
    --mount "type=volume,src=$data_volume,dst=/var/lib/ldap" \
    "$image_name" -euo pipefail <<'BASH'
config_export=$(mktemp)
modified_config=$(mktemp)
trap 'rm -f "$config_export" "$modified_config"' EXIT

/usr/sbin/slapcat -F /etc/ldap/slapd.d -n 0 -o ldif-wrap=no >"$config_export"
awk '
  $0 == "dn: cn=module{0},cn=config" { in_image_module_list = 1 }
  in_image_module_list &&
      $0 ~ /^olcModuleLoad: ([{][0-9]+[}])?([^[:space:]]*\/)?argon2([.]so|[.]la)?([[:space:]].*)?$/ {
    removed_argon2 = 1
    next
  }
  in_image_module_list && $0 == "" {
    if (!removed_argon2) exit 1
    print
    print "dn: cn=module{1},cn=config"
    print "objectClass: olcModuleList"
    print "cn: module{1}"
    print "olcModulePath: /usr/lib/ldap"
    print "olcModuleLoad: argon2.la m=7168 t=5 p=1"
    print ""
    inserted_operator_list = 1
    in_image_module_list = 0
    next
  }
  { print }
  END { if (!inserted_operator_list) exit 1 }
' "$config_export" >"$modified_config"

# Preserve the image marker so the next container exercises reconciliation,
# while slapadd regenerates checksums for the deliberately reshaped cn=config.
find /etc/ldap/slapd.d -mindepth 1 -depth ! -name initialized -delete
/usr/sbin/slapadd -F /etc/ldap/slapd.d -n 0 <"$modified_config"
BASH

  start_container
  if ! wait_until_ready; then
    echo "A persisted operator-owned Argon2 module load prevented startup." >&2
    exit 1
  fi
  docker exec "$container" \
    ldapwhoami -x -H ldap://127.0.0.1 \
      -D "$root_dn" -w "$root_password" >/dev/null
  config_modules=$(docker exec "$container" \
    ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
      -b 'cn=config' -s one '(objectClass=olcModuleList)' olcModuleLoad)
  argon_module_count=$(grep -Eic '^olcModuleLoad: .*argon2' <<<"$config_modules" || true)
  if [[ $argon_module_count != 1 ||
        $config_modules != *'argon2.la m=7168 t=5 p=1'* ]]; then
    printf '%s\n' "$config_modules" >&2
    echo "Startup rewrote or duplicated the operator-owned Argon2 module load." >&2
    exit 1
  fi

  create_password_hash_test_instance
  start_container --env LDAP_INIT_PASSWORD_HASH=
  assert_initialization_rejected \
    "$container" \
    "LDAP_INIT_PASSWORD_HASH must be ARGON2|SSHA" \
    "An empty password hash setting"

  create_password_hash_test_instance
  start_container --env LDAP_INIT_PASSWORD_HASH=ARGON2ID
  assert_initialization_rejected \
    "$container" \
    "LDAP_INIT_PASSWORD_HASH must be ARGON2|SSHA" \
    "An unsupported password hash setting"

  remove_password_hash_test_instance
}
