#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Test-only INIT_SH_FILE fixture. It can prepare a service-controlled password
# path and records inherited password variables at slapd executable boundaries.
# The container's procfs intentionally prevents an external process from reading
# the service-owned daemon environment afterward.

set -eu

if [[ ${ROOT_PASSWORD_TEST_CREATE_UNTRUSTED_LINK:-false} == true ]]; then
  # The target is root-readable, but the link lives below a directory that run.sh
  # later gives to openldap. Root must not follow this service-replaceable path.
  printf '%s' 'test-only protected root password' >/run/root-password-test-protected
  chmod 0600 /run/root-password-test-protected
  mkdir -p /run/slapd
  ln -s /run/root-password-test-protected /run/slapd/root-password-link
fi

if [[ ${ROOT_PASSWORD_TEST_PROBE_ENVIRONMENT:-false} == true &&
      ! -e /usr/sbin/slapd.root-password-test-real ]]; then
  mv /usr/sbin/slapd /usr/sbin/slapd.root-password-test-real
  cat >/usr/sbin/slapd <<'WRAPPER'
#!/bin/sh
set -eu

# Probe every slapd child, including the build-info and private initialization
# invocations. Waiting for the production daemon would miss an earlier export.
if [ "${LDAP_INIT_ROOT_USER_PW+x}" = x ] || [ "${root_user_password+x}" = x ]; then
  : >/run/root-password-env-probe-leaked
fi

# Only the production daemon exposes the public LDAP listener. Pre-start slapd
# instances use ldapi alone and must not satisfy this lifecycle assertion.
case " $* " in
  *" -h ldap:/// "*)
    : >/run/root-password-env-probe-reached
    ;;
esac

exec /usr/sbin/slapd.root-password-test-real "$@"
WRAPPER
  chmod 0755 /usr/sbin/slapd
fi

if [[ ${ROOT_PASSWORD_TEST_PROBE_ENVIRONMENT:-false} == true ]]; then
  # A pre-exported collision keeps Bash's export attribute across a plain declare.
  # Leave allexport and xtrace enabled as well: run.sh must establish its own safe
  # post-hook state before it captures either environment- or file-backed secrets.
  export root_user_password=preexisting-export-marker
  set -a
  set -x
fi
