#syntax=docker/dockerfile:1
# see https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/reference.md
# see https://docs.docker.com/engine/reference/builder/#syntax
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# https://hub.docker.com/_/debian/tags?name=bookworm-slim
ARG BASE_IMAGE=debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG LC_ALL=C

# https://github.com/hadolint/hadolint/wiki/DL3006 Always tag the version of an image explicitly
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS pqchecker-build

# https://github.com/hadolint/hadolint/wiki/DL3008 Pin versions
# hadolint ignore=DL3008
RUN <<EOF
   set -eux
   apt-get update
   apt-get install --no-install-recommends -y \
      build-essential \
      ca-certificates \
      git

EOF

RUN <<EOF
   git config --global advice.detachedHead false
   git config --global core.sparseCheckout true
   git config --global init.defaultBranch main
EOF

WORKDIR /opt/openldap-src
RUN <<EOF
   git clone --depth 1 --branch OPENLDAP_REL_ENG_2_5 https://github.com/openldap/openldap.git .
   ./configure
   make depend
EOF

WORKDIR /opt/jni-headers

ENV JVM_DIR=/usr/lib/jvm/openjdk11

RUN <<EOF
   set -eux

   git clone --depth 1 --filter=blob:none --no-checkout --branch jdk-11-ga https://github.com/openjdk/jdk.git .
   git sparse-checkout init --cone
   git sparse-checkout set \
        src/java.base/share/native/include/jni.h \
        src/java.base/unix/native/include/jni_md.h
   git checkout

   mkdir -p "$JVM_DIR/include/linux"
   cp src/java.base/share/native/include/jni.h   "$JVM_DIR/include/"
   cp src/java.base/unix/native/include/jni_md.h "$JVM_DIR/include/linux/"
EOF

WORKDIR /opt/pqchecker

RUN <<EOF
   set -eu

   # auto-detect JAVA_HOME from wherever jni.h landed
   JNI_HDR=$(find /usr/lib/jvm -path '*/include/jni.h' -print -quit)
   if [ -z "$JNI_HDR" ]; then
      echo "ERROR: jni.h not found under /usr/lib/jvm – cannot set JAVA_HOME" >&2
      exit 1
   fi
   JAVA_HOME=$(dirname "$(dirname "$JNI_HDR")")
   echo "Detected JAVA_HOME=$JAVA_HOME"
   export JAVA_HOME

   set -x
   git init .
   # git remote add origin https://bitbucket.org/ameddeb/pqchecker.git
   git remote add origin https://github.com/pqchecker/pqchecker.git
   git fetch --depth 1 origin 2813c1922c4233d72066201d11b6b4ad4f61239d
   git checkout FETCH_HEAD

   bash ./adjustdate.bash
   ./configure \
      LDAPSRC=/opt/openldap-src \
      JAVAHOME="$JAVA_HOME" \
      libdir=/usr/lib/ldap \
      PARAMDIR=/etc/ldap/pqchecker
   make

EOF

# https://github.com/hadolint/hadolint/wiki/DL3006 Always tag the version of an image explicitly
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} as final

LABEL maintainer="Vegard IT GmbH (vegardit.com)"

# see https://github.com/hadolint/hadolint/wiki/DL3002
# hadolint ignore=DL3002
USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG INSTALL_SUPPORT_TOOLS=0

ARG BASE_LAYER_CACHE_KEY

COPY --from=pqchecker-build /opt/pqchecker/src/.libs/pqchecker.so /usr/lib/ldap/pqchecker.so
COPY --from=pqchecker-build /opt/pqchecker/pqparams.dat           /etc/ldap/pqchecker/pqparams.dat

# see https://github.com/hadolint/hadolint/wiki/DL3008
# hadolint ignore=DL3008,SC2016
RUN --mount=type=bind,source=.shared,target=/mnt/shared <<EOF

  /mnt/shared/cmd/debian-install-os-updates.sh
  /mnt/shared/cmd/debian-install-support-tools.sh

  function curl() {
    command curl -sSfL --connect-timeout 10 --max-time 30 --retry 3 --retry-all-errors "$@"
  }

  echo "#################################################"
  echo "Installing tini..."
  echo "#################################################"
  apt-get install --no-install-recommends -y tini

  echo "#################################################"
  echo "Installing slapd..."
  echo "#################################################"
  echo 'slapd slapd/root_password password whatever' | debconf-set-selections
  echo 'slapd slapd/root_password_again password whatever' | debconf-set-selections
  apt-get install --no-install-recommends -y slapd ldap-utils
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

ARG BUILD_DATE
ARG GIT_BRANCH
ARG GIT_COMMIT_HASH
ARG GIT_COMMIT_DATE
ARG GIT_REPO_URL

LABEL \
  org.label-schema.schema-version="1.0" \
  org.label-schema.build-date=$BUILD_DATE \
  org.label-schema.vcs-ref=$GIT_COMMIT_HASH \
  org.label-schema.vcs-url=$GIT_REPO_URL

# Default configuration: can be overridden at the docker command line
# see https://github.com/hadolint/hadolint/wiki/DL3044
# hadolint ignore=DL3044
ENV \
  INIT_SH_FILE='' \
  #
  LDAP_INIT_ORG_DN='DC=example,DC=com' \
  LDAP_INIT_ORG_NAME='Example Corporation' \
  LDAP_INIT_ORG_ATTR_O='' \
  LDAP_INIT_ADMIN_GROUP_DN='cn=ldap-admins,ou=Groups,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_PASSWORD_RESET_GROUP_DN='cn=ldap-password-reset,ou=Groups,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_ROOT_USER_DN='uid=admin,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_ROOT_USER_PW='' \
  LDAP_INIT_ALLOW_CONFIG_ACCESS='false' \
  LDAP_INIT_PPOLICY_DEFAULT_DN='cn=DefaultPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_PPOLICY_PW_MIN_LENGTH=8 \
  LDAP_INIT_PPOLICY_MAX_FAILURES=3 \
  LDAP_INIT_PPOLICY_LOCKOUT_DURATION=300 \
  LDAP_INIT_RFC2307BIS_SCHEMA=0 \
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
  echo "
GIT_REPO:    $GIT_REPO_URL
GIT_BRANCH:  $GIT_BRANCH
GIT_COMMIT:  $GIT_COMMIT_HASH @ $GIT_COMMIT_DATE
IMAGE_BUILD: $BUILD_DATE" >/opt/build_info
  cat /opt/build_info

EOF

COPY image/ldifs /opt/ldifs
COPY image/run.sh /opt/run.sh
COPY .shared/lib/bash-init.sh /opt/bash-init.sh

VOLUME ["/etc/ldap/slapd.d", "/var/lib/ldap"]

EXPOSE 389 636

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/bin/bash", "/opt/run.sh"]
