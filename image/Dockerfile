#syntax=docker/dockerfile:1
# see https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/reference.md
# see https://docs.docker.com/engine/reference/builder/#syntax
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# https://hub.docker.com/_/debian/tags?name=trixie-slim
ARG BASE_IMAGE=debian:trixie-slim

#############################################################
# build final image
#############################################################

# https://github.com/hadolint/hadolint/wiki/DL3006 Always tag the version of an image explicitly
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS final

ARG DEBIAN_FRONTEND=noninteractive
ARG LC_ALL=C

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG INSTALL_SUPPORT_TOOLS=0
ARG BASE_LAYER_CACHE_KEY

# https://github.com/hadolint/hadolint/wiki/DL3008 Pin versions
# hadolint ignore=DL3008,SC2016
RUN --mount=type=bind,source=.shared,target=/mnt/shared <<EOF
  /mnt/shared/cmd/debian-install-os-updates.sh
  /mnt/shared/cmd/debian-install-support-tools.sh

  echo "#################################################"
  echo "Installing tini..."
  echo "#################################################"
  apt-get install --no-install-recommends -y tini

  echo "#################################################"
  echo "Installing slapd..."
  echo "#################################################"
  echo 'slapd slapd/root_password password whatever' | debconf-set-selections
  echo 'slapd slapd/root_password_again password whatever' | debconf-set-selections
  # ldap-utils provides the LDAP client commands used for bootstrap changes,
  # migrations, readiness checks, and syncrepl state inspection.
  # slapd-contrib provides Debian's packaged PPM password-quality module.
  # libsasl2-modules-gssapi-mit enables the GSSAPI mechanism advertised by slapd.
  # util-linux provides setpriv, which runs backup filesystem operations with the
  # configured openldap identity instead of inheriting entrypoint privileges.
  apt-get install --no-install-recommends -y \
    slapd \
    slapd-contrib \
    ldap-utils \
    libsasl2-modules-gssapi-mit \
    util-linux

  # Existing cn=config volumes may still use the old path. Keep it working until
  # the entrypoint replaces it with ppm.so. Fail the build here if Debian changes
  # the package layout; ln alone would silently create a dangling compatibility link.
  test -e /usr/lib/ldap/ppm.so
  ln -s ppm.so /usr/lib/ldap/pqchecker.so

  # The GSSAPI package depends on the generic module bundle. Limit slapd to the
  # two mechanisms this image supports so that PLAIN and legacy mechanisms do
  # not become advertised merely as a packaging side effect.
  install -d /etc/ldap/sasl2
  printf '%s\n' 'mech_list: EXTERNAL GSSAPI' >/etc/ldap/sasl2/slapd.conf

  echo "OpenLDAP $(apt-cache show slapd | grep Version)" >> /opt/build_info
  # workaround for 'service slapd stop' not working, see https://stackoverflow.com/a/58792698/5116073
  sed -i 's/--exec $SLAPD 2/--name slapd 2/' /etc/init.d/slapd

  echo "#################################################"
  echo "Moving config and data directories..."
  echo "#################################################"
  mv /etc/ldap/slapd.d /etc/ldap/slapd.d_orig
  mkdir /etc/ldap/slapd.d
  mv /var/lib/ldap /var/lib/ldap_orig
  mkdir /var/lib/ldap

  /mnt/shared/cmd/debian-cleanup.sh

EOF

ARG OCI_authors
ARG OCI_title
ARG OCI_description
ARG OCI_source
ARG OCI_revision
ARG OCI_version
ARG OCI_created

ARG GIT_BRANCH
ARG GIT_COMMIT_DATE

# https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL \
  org.opencontainers.image.title="$OCI_title" \
  org.opencontainers.image.description="$OCI_description" \
  org.opencontainers.image.source="$OCI_source" \
  org.opencontainers.image.revision="$OCI_revision" \
  org.opencontainers.image.version="$OCI_version" \
  org.opencontainers.image.created="$OCI_created"

LABEL maintainer="$OCI_authors"

# Default configuration: can be overridden at the docker command line
# see https://github.com/hadolint/hadolint/wiki/DL3044
# hadolint ignore=DL3044,DL3064 # Sensitive values are runtime-only; the image stores empty defaults and secret file paths.
ENV \
  INIT_SH_FILE='' \
  #
  LDAP_INIT_ORG_DN='DC=example,DC=com' \
  LDAP_INIT_ORG_NAME='Example Corporation' \
  LDAP_INIT_ORG_ATTR_O='' \
  LDAP_INIT_ADMIN_GROUP_DN='cn=ldap-admins,ou=Groups,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_PASSWORD_RESET_GROUP_DN='cn=ldap-password-reset,ou=Groups,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_ROOT_USER_DN='uid=admin,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_ROOT_USER_PW_FILE='' \
  LDAP_INIT_ROOT_USER_PW='' \
  LDAP_INIT_ALLOW_CONFIG_ACCESS='false' \
  LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE='true' \
  LDAP_INIT_REPLICATION_ROLE='' \
  LDAP_INIT_REPLICATION_PROVIDER_URI='' \
  LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE='' \
  LDAP_INIT_PPOLICY_DEFAULT_DN='cn=DefaultPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_PPOLICY_PW_MIN_LENGTH=8 \
  LDAP_INIT_PPOLICY_MAX_FAILURES=3 \
  LDAP_INIT_PPOLICY_LOCKOUT_DURATION=300 \
  LDAP_INIT_RFC2307BIS_SCHEMA=0 \
  # Do not set a default for LDAP_PPOLICY_PPM_CONFIG. The entrypoint must tell
  # unset (use the legacy default) from empty (disable automatic updates).
  LDAP_PPOLICY_PQCHECKER_RULE='0|01010101' \
  LDAP_NOFILE_LIMIT=1024 \
  LDAP_LOG_LEVELS='Config Stats' \
  # Format is "HH:MM", i.e. 24-hour format with minute precision
  LDAP_BACKUP_TIME='02:00' \
  LDAP_BACKUP_FILE='/var/lib/ldap/data.ldif' \
  LDAP_OPENLDAP_UID='' \
  LDAP_OPENLDAP_GID='' \
  LDAP_TLS_ENABLED='auto' \
  LDAP_LDAPS_ENABLED='true' \
  LDAP_TLS_SSF=128 \
  LDAP_TLS_CERT_FILE='/run/secrets/ldap/server.crt' \
  LDAP_TLS_KEY_FILE='/run/secrets/ldap/server.key' \
  LDAP_TLS_CA_FILE='/run/secrets/ldap/ca.crt' \
  LDAP_TLS_VERIFY_CLIENT='try'

RUN <<EOF
  echo "#################################################"
  echo "Writing build_info..."
  echo "#################################################"
  cat <<EOT >/opt/build_info
GIT_REPO:    $OCI_source
GIT_BRANCH:  $GIT_BRANCH
GIT_COMMIT:  $OCI_revision @ $GIT_COMMIT_DATE
IMAGE_BUILD: $OCI_created
EOT
  cat /opt/build_info

EOF

COPY image/ldifs /opt/ldifs
COPY image/backup.sh /opt/backup.sh
COPY image/config-migration.sh /opt/config-migration.sh
COPY image/ppm.sh /opt/ppm.sh
COPY image/tls.sh /opt/tls.sh
COPY image/run.sh /opt/run.sh
COPY .shared/lib/bash-init.sh /opt/bash-init.sh

VOLUME ["/etc/ldap/slapd.d", "/var/lib/ldap"]

EXPOSE 389 636

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/bin/bash", "/opt/run.sh"]
