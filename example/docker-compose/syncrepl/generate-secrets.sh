#!/bin/sh

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

replication_secret=secrets/ldap-replication-password

# Refuse to overwrite or combine credential material from separate runs. If the
# initial generation fails, remove its partial output explicitly before retrying.
if [ -e tls ] || [ -L tls ] || [ -e "$replication_secret" ] || [ -L "$replication_secret" ]; then
  echo "Refusing to overwrite existing TLS or replication-secret material." >&2
  exit 1
fi

umask 077
mkdir -p secrets
mkdir tls
openssl rand -hex 32 >"$replication_secret"

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
chmod 600 tls/*.key "$replication_secret"

echo "Created local TLS material and the replication password."
