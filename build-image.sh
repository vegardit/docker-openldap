#!/usr/bin/env bash
#
# Copyright 2019-2020 by Vegard IT GmbH, Germany, https://vegardit.com
# SPDX-License-Identifier: Apache-2.0
#
# @author Sebastian Thomschke, Vegard IT GmbH
#
# https://github.com/vegardit/docker-openldap
#

set -e -x
if [ ! -n "$BASH" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

DOCKER_REGISTRY=${DOCKER_REGISTRY:-docker.io}
DOCKER_REPO=${DOCKER_REPO:-vegardit/openldap}

last_commit_date=$(date -d @$(git log -1 --format="%at") --utc +"%Y%m%d_%H%M%S")

docker build $(dirname $0)/image \
   --compress \
   --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
   --build-arg GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}" \
   --build-arg GIT_COMMIT_DATE="$(date -d @$(git log -1 --format='%at') --utc +'%Y-%m-%d %H:%M:%S UTC')" \
   --build-arg GIT_COMMIT_HASH="$(git rev-parse --short HEAD)" \
   --build-arg GIT_REPO_URL="$(git config --get remote.origin.url)" \
   `# using the current date as value for BASE_LAYER_CACHE_KEY, i.e. the base layer cache (that holds system packages with security updates) will be invalidate once per day` \
   --build-arg BASE_LAYER_CACHE_KEY=$(date +%Y%m%d) \
   -t $DOCKER_REPO:latest \
   -t $DOCKER_REPO:latest-buster \
   -t $DOCKER_REPO:${last_commit_date} \
   -t $DOCKER_REPO:${last_commit_date}-buster \
   "$@"

#
# perform security audit using https://github.com/aquasecurity/trivy
#
mkdir -p ${TRIVY_CACHE_DIR:-$HOME/.trivy/cache}
docker run --rm \
   -v /var/run/docker.sock:/var/run/docker.sock \
   -v ${TRIVY_CACHE_DIR:-$HOME/.trivy/cache}:/root/.cache/ \
   aquasec/trivy --no-progress --exit-code 0 --severity HIGH,CRITICAL $DOCKER_REPO:${last_commit_date}
docker run --rm \
   -v /var/run/docker.sock:/var/run/docker.sock \
   -v ${TRIVY_CACHE_DIR:-$HOME/.trivy/cache}:/root/.cache/ \
   aquasec/trivy --no-progress --ignore-unfixed --exit-code 1 --severity HIGH,CRITICAL $DOCKER_REPO:${last_commit_date}
sudo chown -R $USER:$(id -gn) $TRIVY_CACHE_DIR || true

#
# determine effective LDAP version and apply tags
#
ldap_version=$(docker run $DOCKER_REPO:${last_commit_date} "dpkg -s slapd | grep 'Version:' | grep -oP 'Version: \K\d+\.\d+\.\d+'")
docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REPO:${ldap_version%.*}.x        #2.4.x
docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REPO:${ldap_version%.*}.x-buster #2.4.x
docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REPO:${ldap_version%%.*}.x        #2.x
docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REPO:${ldap_version%%.*}.x-buster #2.x

#
# push image with tags to remote docker registry
#
if [[ "${DOCKER_PUSH:-0}" == "1" ]]; then
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:latest
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:latest-buster
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version}        #2.4.47
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version}-buster #2.4.47
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%.*}.x        #2.4.x
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%.*}.x-buster #2.4.x
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%%.*}.x        #2.x
   docker image tag $DOCKER_REPO:${last_commit_date} $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%%.*}.x-buster #2.x

   docker push $DOCKER_REGISTRY/$DOCKER_REPO:latest
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:latest-buster
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version}        #2.4.47
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version}-buster #2.4.47
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%.*}.x        #2.4.x
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%.*}.x-buster #2.4.x
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%%.*}.x        #2.x
   docker push $DOCKER_REGISTRY/$DOCKER_REPO:${ldap_version%%.*}.x-buster #2.x
fi
