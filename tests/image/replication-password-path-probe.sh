#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Test-only INIT_SH_FILE fixture for the replication-password path boundary. The
# link is created with service authority and targets bytes that only root can read.

set -eu

marker=${REPLICATION_PASSWORD_PATH_TEST_MARKER:?}
protected_target=/run/replication-password-test-root-only
service_directory=/run/replication-password-source

function run_as_test_openldap() {
  /usr/bin/setpriv \
    --reuid openldap \
    --regid openldap \
    --clear-groups \
    --inh-caps=-all \
    --ambient-caps=-all \
    --no-new-privs \
    -- "$@"
}

printf '%s' "$marker" >"$protected_target"
chmod 0600 "$protected_target"
mkdir "$service_directory"
chown openldap:openldap "$service_directory"
chmod 0700 "$service_directory"

# Assert the fixture really separates authorities before creating the link. A
# root-open regression would otherwise only prove access to ordinary service data.
if run_as_test_openldap /usr/bin/test -r "$protected_target"; then
  echo "The replication path probe target is readable by openldap." >&2
  exit 1
fi
run_as_test_openldap \
  /usr/bin/ln -s -- "$protected_target" "$service_directory/password-link"
