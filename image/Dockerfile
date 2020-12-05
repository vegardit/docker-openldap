# Copyright 2019-2020 by Vegard IT GmbH, Germany, https://vegardit.com
# SPDX-License-Identifier: Apache-2.0
#
# Author: Sebastian Thomschke, Vegard IT GmbH
#
# https://github.com/vegardit/docker-openldap
#

# https://hub.docker.com/_/debian?tab=tags&name=buster-slim
ARG BASE_IMAGE=debian:buster-slim

FROM ${BASE_IMAGE}

LABEL maintainer="Vegard IT GmbH (vegardit.com)"

USER root

SHELL ["/bin/bash", "-c"]

# if set to 1 debug tools are added to the image (htop,less,mc,vim)
ARG DEBUG_BUILD=0

ARG PQCHECKER_URL=https://www.meddeb.net/pub/pqchecker/deb/8/pqchecker_2.0.0_amd64.deb
ARG PQCHECKER_MD5=c005ce596e97d13e39485e711dcbc7e1

ARG DEBIAN_FRONTEND=noninteractive
ARG LC_ALL=C

ARG BASE_LAYER_CACHE_KEY

RUN \
  set -eu && \
  echo "#################################################" && \
  echo "Installing OS updates..." && \
  echo "#################################################" && \
  apt-get update -y && \
  # https://github.com/phusion/baseimage-docker/issues/319
  apt-get install --no-install-recommends -y apt-utils 2> >( grep -v 'debconf: delaying package configuration, since apt-utils is not installed' >&2 ) && \
  apt-get upgrade -y && \
  #
  if [ "${DEBUG_BUILD}" = "1" ]; then \
     echo "#################################################" && \
     echo "Installing debugging tools..." && \
     echo "#################################################" && \
     apt-get install --no-install-recommends -y libcomerr2 mc && \
     apt-get install --no-install-recommends -y htop less procps vim && \
     echo -e 'set ignorecase\n\
set showmatch\n\
set novisualbell\n\
set noerrorbells\n\
syntax enable\n\
set mouse-=a' > ~/.vimrc; \
  fi && \
  echo "#################################################" && \
  echo "Installing slapd..." && \
  echo "#################################################" && \
  echo 'slapd slapd/root_password password whatever' | debconf-set-selections && \
  echo 'slapd slapd/root_password_again password whatever' | debconf-set-selections && \
  apt-get install --no-install-recommends -y slapd ldap-utils && \
  echo "OpenLDAP $(apt-cache show slapd | grep Version)" >> /opt/build_info  && \
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
  echo "#################################################" && \
  echo "apt-get clean up..." && \
  echo "#################################################" && \
  apt-get remove apt-utils -y && \
  apt-get clean autoclean && \
  apt-get autoremove --purge -y && \
  #
  echo "#################################################" && \
  echo "Removing logs, caches and temp files..." && \
  echo "#################################################" && \
  rm -rf /var/cache/{apt,debconf} \
     /var/lib/apt/lists/* \
     /var/log/{apt,alternatives.log,bootstrap.log,dpkg.log} \
     /tmp/* /var/tmp/*

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
  DEBUG_RUN_SH=0  \
  INIT_SH_FILE='' \
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

COPY ldifs /opt/ldifs
COPY run.sh /opt/run.sh

RUN \
  echo "GIT_REPO:    $GIT_REPO_URL" > /opt/build_info && \
  echo "GIT_BRANCH:  $GIT_BRANCH" >> /opt/build_info && \
  echo "GIT_COMMIT:  $GIT_COMMIT_HASH @ $GIT_COMMIT_DATE" >> /opt/build_info  && \
  echo "IMAGE_BUILD: $BUILD_DATE" >> /opt/build_info && \
  cat /opt/build_info

VOLUME ["/etc/ldap/slapd.d", "/var/lib/ldap"]

EXPOSE 389

ENTRYPOINT ["/bin/sh", "-c"]

# exec is required for propagating SIGTERM from docker to child process
CMD ["exec /bin/bash /opt/run.sh"]
