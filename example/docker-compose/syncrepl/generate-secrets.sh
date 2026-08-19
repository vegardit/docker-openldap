#!/bin/sh

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

provider_admin_secret=secrets/ldap-provider-admin-password
consumer_admin_secret=secrets/ldap-consumer-admin-password
replication_secret=secrets/ldap-replication-password

# Refuse to overwrite or combine credential material from separate runs. If the
# initial generation fails, remove its partial output explicitly before retrying.
if [ -e tls ] || [ -L tls ]; then
  echo "Refusing to overwrite existing TLS material." >&2
  exit 1
fi
for secret_file in "$provider_admin_secret" "$consumer_admin_secret" "$replication_secret"; do
  if [ -e "$secret_file" ] || [ -L "$secret_file" ]; then
    echo "Refusing to overwrite existing secret [$secret_file]." >&2
    exit 1
  fi
done

umask 077
mkdir -p secrets
mkdir tls
# Keep generated credential files byte-exact for tools such as `ldapsearch -y`,
# which treat a line terminator as password data. Separate assignments preserve
# each OpenSSL exit status under `set -e` before printf writes the secret.
generated_secret=$(openssl rand -hex 32)
printf '%s' "$generated_secret" >"$provider_admin_secret"
generated_secret=$(openssl rand -hex 32)
printf '%s' "$generated_secret" >"$consumer_admin_secret"
generated_secret=$(openssl rand -hex 32)
printf '%s' "$generated_secret" >"$replication_secret"
unset generated_secret

# Git Bash rewrites slash-prefixed arguments as Windows paths unless /CN= is
# excluded from MSYS argument conversion for these OpenSSL commands.
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
  -subj '/CN=OpenLDAP local test CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout tls/ca.key -out tls/ca.crt

for node in provider consumer; do
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -newkey rsa:4096 -nodes -sha256 \
    -subj "/CN=$node" \
    -keyout "tls/$node.key" -out "tls/$node.csr"
  printf 'subjectAltName=DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
    "$node" >"tls/$node.ext"
  openssl x509 -req -sha256 -days 825 \
    -in "tls/$node.csr" \
    -CA tls/ca.crt -CAkey tls/ca.key -CAcreateserial \
    -extfile "tls/$node.ext" -out "tls/$node.crt"
done

rm tls/provider.csr tls/provider.ext tls/consumer.csr tls/consumer.ext tls/ca.srl
# POSIX modes keep private material owner-only while public certificates remain
# service-readable. chmod does not configure Windows ACLs; the example README
# documents the host-side protection required there.
chmod 644 tls/*.crt
chmod 600 tls/*.key "$provider_admin_secret" "$consumer_admin_secret" "$replication_secret"

echo "Created local TLS material, separate administrator passwords, and the replication password."
