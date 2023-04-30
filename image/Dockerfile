#syntax=docker/dockerfile:1.2
# Copyright 2019-2021 by Vegard IT GmbH, Germany, https://vegardit.com
# SPDX-License-Identifier: Apache-2.0
#
# Author: Sebastian Thomschke, Vegard IT GmbH
#
# https://github.com/vegardit/docker-openldap
#

# https://hub.docker.com/_/debian?tab=tags&name=stable-slim
ARG BASE_IMAGE=debian:stable-slim

FROM ${BASE_IMAGE}

LABEL maintainer="Vegard IT GmbH (vegardit.com)"

USER root

SHELL ["/bin/bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG LC_ALL=C

ARG BASE_LAYER_CACHE_KEY
ARG INSTALL_SUPPORT_TOOLS=0

#ARG PQCHECKER_URL=https://meddeb.net/pub/pqchecker/deb/8/pqchecker_2.0.0_amd64.deb
ARG PQCHECKER_URL=https://github.com/pqchecker/pqchecker-binaries/raw/main/deb/8/pqchecker_2.0.0_amd64.deb
ARG PQCHECKER_MD5=c005ce596e97d13e39485e711dcbc7e1

RUN --mount=type=bind,source=.shared,target=/mnt/shared \
  set -eu && \
  /mnt/shared/cmd/debian-install-os-updates.sh && \
  /mnt/shared/cmd/debian-install-support-tools.sh && \
  #
  echo "#################################################" && \
  echo "Installing tini..." && \
  echo "#################################################" && \
  apt-get install --no-install-recommends -y tini && \
  #
  echo "#################################################" && \
  echo "Installing slapd..." && \
  echo "#################################################" && \
  echo 'slapd slapd/root_password password whatever' | debconf-set-selections && \
  echo 'slapd slapd/root_password_again password whatever' | debconf-set-selections && \
  apt-get install --no-install-recommends -y slapd ldap-utils && \
  echo "OpenLDAP $(apt-cache show slapd | grep Version)" >> /opt/build_info && \
  # workaround for 'service slapd stop' not working, see https://stackoverflow.com/a/58792698/5116073
  sed -i 's/--exec $SLAPD 2/--name slapd 2/' /etc/init.d/slapd && \
  #
  echo "#################################################" && \
  echo "Installing pqChecker password quality checker module..." && \
  echo "#################################################" && \
  # https://www.meddeb.net/pqchecker/
  apt-get install --no-install-recommends -y curl && \
  curl -k -o /tmp/pqchecker.deb -SL "${PQCHECKER_URL}" && \
  echo "${PQCHECKER_MD5} /tmp/pqchecker.deb" | md5sum -c - && \
  dpkg -i /tmp/pqchecker.deb && \
  rm /tmp/pqchecker.deb && \
  apt-get remove --auto-remove -y curl && \
  #
  echo "#################################################" && \
  echo "Moving config and data directories..." && \
  echo "#################################################" && \
  mv /etc/ldap/slapd.d /etc/ldap/slapd.d_orig && \
  mkdir /etc/ldap/slapd.d && \
  mv /var/lib/ldap /var/lib/ldap_orig && \
  mkdir /var/lib/ldap && \
  #
  /mnt/shared/cmd/debian-cleanup.sh

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
ENV \
  INIT_SH_FILE='' \
  #
  LDAP_INIT_ORG_DN='o=example.com' \
  LDAP_INIT_ORG_NAME='Example Corporation' \
  LDAP_INIT_ADMIN_GROUP_DN='cn=ldapadmins,ou=Groups,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_ROOT_USER_DN='uid=admin,${LDAP_INIT_ORG_DN}' \
  LDAP_INIT_ROOT_USER_PW='changeit' \
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
  LDAP_OPENLDAP_GID=''

RUN \
  set -eu && \
  echo -e "\
GIT_REPO:    $GIT_REPO_URL\n\
GIT_BRANCH:  $GIT_BRANCH\n\
GIT_COMMIT:  $GIT_COMMIT_HASH @ $GIT_COMMIT_DATE\n\
IMAGE_BUILD: $BUILD_DATE\n" >/opt/build_info && \
  cat /opt/build_info

COPY image/ldifs /opt/ldifs
COPY image/run.sh /opt/run.sh
COPY .shared/lib/bash-init.sh /opt/bash-init.sh

VOLUME ["/etc/ldap/slapd.d", "/var/lib/ldap"]

EXPOSE 389

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/bin/bash", "/opt/run.sh"]
