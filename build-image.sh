#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

function curl() {
  command curl -sSfL --connect-timeout 10 --max-time 30 --retry 3 --retry-all-errors "$@"
}

shared_lib="$(dirname $0)/.shared"
[ -e "$shared_lib" ] || curl https://raw.githubusercontent.com/vegardit/docker-shared/v1/download.sh?_=$(date +%s) | bash -s v1 "$shared_lib" || exit 1
source "$shared_lib/lib/build-image-init.sh"


#################################################
# specify target repo and image name
#################################################
image_repo=${DOCKER_IMAGE_REPO:-vegardit/openldap}
base_image_name=${DOCKER_BASE_IMAGE:-debian:bookworm-slim}
image_name=$image_repo:latest


#################################################
# build the image
#################################################
log INFO "Building docker image [$image_name]..."
if [[ $OSTYPE == "cygwin" || $OSTYPE == "msys" ]]; then
  project_root=$(cygpath -w "$project_root")
fi

set -x
docker pull $base_image_name
DOCKER_BUILDKIT=1 docker build "$project_root" \
  --file "image/Dockerfile" \
  --progress=plain \
  --build-arg INSTALL_SUPPORT_TOOLS=${INSTALL_SUPPORT_TOOLS:-0} \
  `# using the current date as value for BASE_LAYER_CACHE_KEY, i.e. the base layer cache (that holds system packages with security updates) will be invalidate once per day` \
  --build-arg BASE_LAYER_CACHE_KEY=$base_layer_cache_key \
  --build-arg BASE_IMAGE=$base_image_name \
  --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  --build-arg GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}" \
  --build-arg GIT_COMMIT_DATE="$(date -d @$(git log -1 --format='%at') --utc +'%Y-%m-%d %H:%M:%S UTC')" \
  --build-arg GIT_COMMIT_HASH="$(git rev-parse --short HEAD)" \
  --build-arg GIT_REPO_URL="$(git config --get remote.origin.url)" \
  -t $image_name \
  "$@"
set +x


#################################################
# determine effective OpenLDAP version
#################################################
# LC_ALL=en_US.utf8 -> workaround for "grep: -P supports only unibyte and UTF-8 locales"
ldap_version=$(docker run --rm $image_name dpkg -s slapd | LC_ALL=en_US.utf8 grep -oP 'Version: \K\d+\.\d+\.\d+')
echo "ldap_version=$ldap_version"


#################################################
# apply tags
#################################################
declare -a tags=()
tags+=($image_name) # :latest
tags+=($image_repo:${ldap_version})       # :2.5.12
tags+=($image_repo:${ldap_version%.*}.x)  # :2.5.x
tags+=($image_repo:${ldap_version%%.*}.x) # :2.x

for tag in ${tags[@]}; do
  docker image tag $image_name $tag
  if [[ "${DOCKER_PUSH:-}" == "true" ]]; then
    docker image tag $image_name ghcr.io/$tag
  fi
done


#################################################
# perform security audit
#################################################
if [[ "${DOCKER_AUDIT_IMAGE:-1}" == 1 ]]; then
  bash "$shared_lib/cmd/audit-image.sh" $image_name
fi


#################################################
# push image with tags to remote docker image registry
#################################################
if [[ "${DOCKER_PUSH:-}" == "true" ]]; then
  for tag in ${tags[@]}; do
    set -x
    docker push $tag
    docker push ghcr.io/$tag
    set +x
  done
fi
