#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

function curl() {
   command curl -sSfL --connect-timeout 10 --max-time 30 --retry 3 --retry-all-errors "$@"
}

shared_lib="$(dirname "${BASH_SOURCE[0]}")/.shared"
[[ -e $shared_lib ]] || curl "https://raw.githubusercontent.com/vegardit/docker-shared/v1/download.sh?_=$(date +%s)" | bash -s v1 "$shared_lib" || exit 1
# shellcheck disable=SC1091  # Not following: $shared_lib/lib/build-image-init.sh was not specified as input
source "$shared_lib/lib/build-image-init.sh"

if [[ $OSTYPE == "cygwin" || $OSTYPE == "msys" ]]; then
   project_root=$(cygpath -w "$project_root")
fi

#################################################
# specify target repo and image name
#################################################
image_repo=${DOCKER_IMAGE_REPO:-vegardit/openldap}
base_image_name=${DOCKER_BASE_IMAGE:-debian:bookworm-slim}
image_name=$image_repo:latest


#################################################
# define target plaforms for multiach builds
#################################################
if [[ ${DOCKER_PUSH:-} == "true" || ${DOCKER_PUSH_GHCR:-} == "true" ]]; then
   platforms="linux/amd64,linux/arm64/v8,linux/arm/v7"
   build_multi_arch="true"
fi


#################################################
# prepare docker
#################################################
(set -x; docker version)

# https://github.com/docker/buildx/#building-multi-platform-images
(set -x; docker buildx version) # ensures buildx is enabled

export DOCKER_BUILDKIT=1
export DOCKER_CLI_EXPERIMENTAL=1 # prevents "docker: 'buildx' is not a docker command." in older Docker versions

if [[ ${build_multi_arch:-} == "true" ]]; then

   # Use a temporary local registry to work around Docker/Buildx/BuildKit quirks,
   # enabling us to build/test multiarch images locally before pushing.
   for local_registry_port in {5000..6000}; do
      if ! lsof -iTCP:"$local_registry_port" -sTCP:LISTEN -t >/dev/null; then
         local_registry_container_name="local-registry-$local_registry_port"
         (set -x; docker run -d --rm -p "$local_registry_port:5000" \
            --name "$local_registry_container_name" \
            ghcr.io/dockerhub-mirror/registry)
         local_registry="127.0.0.1:$local_registry_port"
         trap 'docker stop "$local_registry_container_name"' EXIT

         log INFO "Waiting for Docker registry at [$local_registry] to be ready..."
         until curl -sSf "http://$local_registry/v2/"; do sleep 0.1; done
         log INFO "✅ Registry is ready"
         break
      fi
   done
   if [[ -z "${local_registry:-}" ]]; then
      echo "❌ No free TCP port between 5000–6000" >&2
      exit 1
   fi
fi

if [[ ${build_multi_arch:-} == "true" ]]; then
   # Register QEMU emulators so Docker can run and build multi-arch images
   (set -x; docker run --privileged --rm ghcr.io/dockerhub-mirror/tonistiigi__binfmt --install all)
fi

# https://docs.docker.com/build/buildkit/configure/#resource-limiting
echo "
[worker.oci]
  max-parallelism = 3
" | sudo tee /etc/buildkitd.toml

builder_name="bx-$(date +%s)-$RANDOM"
(set -x; docker buildx create \
   --name "$builder_name" \
   --bootstrap \
   --config /etc/buildkitd.toml \
   --driver-opt network=host `# required for buildx to access the temporary registry` \
   --driver docker-container)
trap 'docker buildx rm --force "$builder_name"' EXIT


#################################################
# build the image
#################################################
log INFO "Pulling base image [$base_image_name]..."
if [[ ${build_multi_arch:-} == "true" ]]; then
   for platform in ${platforms//,/ }; do
      docker pull --platform "$platform" "$base_image_name"
   done
else
   docker pull "$base_image_name"
fi

log INFO "Building docker image [$image_name]..."

# common build arguments
build_opts=(
   --builder "$builder_name"
   --progress=plain
   --file "image/Dockerfile"
   --build-arg INSTALL_SUPPORT_TOOLS="${INSTALL_SUPPORT_TOOLS:-0}"
   # using the current date as value for BASE_LAYER_CACHE_KEY, i.e. the base layer cache (that holds system packages with security updates) will be invalidate once per day
   --build-arg BASE_LAYER_CACHE_KEY="$base_layer_cache_key"
   --build-arg BASE_IMAGE="$base_image_name"
   --build-arg BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
   --build-arg GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
   --build-arg GIT_COMMIT_DATE="$(date -d "@$(git log -1 --format='%at')" --utc +'%Y-%m-%d %H:%M:%S UTC')"
   --build-arg GIT_COMMIT_HASH="$(git rev-parse --short HEAD)"
   --build-arg GIT_REPO_URL="$(git config --get remote.origin.url)"
)

if [[ ${build_multi_arch:-} == "true" ]]; then
   build_opts+=(--push)
   build_opts+=(--sbom=true) # https://docs.docker.com/build/metadata/attestations/sbom/#create-sbom-attestations
   build_opts+=(--platform "$platforms")
   build_opts+=(--tag "$local_registry/$image_name")
else
   build_opts+=(--output "type=docker,load=true")
   build_opts+=(--tag "$image_name")
fi

# shellcheck disable=SC2154,SC2046  # base_layer_cache_key is referenced but not assigned / Quote this to prevent word splitting
(set -x; docker buildx build "${build_opts[@]}" "$project_root")


#################################################
# load image into local docker daemon for testing
#################################################
if [[ ${build_multi_arch:-} == "true" ]]; then
   docker pull "$local_registry/$image_name"
   docker tag "$local_registry/$image_name" "$image_name"
fi


#################################################
# perform security audit
#################################################
if [[ ${DOCKER_AUDIT_IMAGE:-1} == "1" ]]; then
   bash "$shared_lib/cmd/audit-image.sh" "$image_name"
fi


#################################################
# determine effective OpenLDAP version
#################################################
echo
log INFO "Determining effective OpenLDAP version of [$image_name]..."
# LC_ALL=en_US.utf8 -> workaround for "grep: -P supports only unibyte and UTF-8 locales"
ldap_version=$(docker run --rm "$image_name" dpkg -s slapd | LC_ALL=en_US.utf8 grep -oP 'Version: \K\d+\.\d+\.\d+')
echo "ldap_version=$ldap_version"


#################################################
# calculate tags
#################################################
declare -a tags=()
tags+=("$image_name") # :latest
tags+=("$image_repo:${ldap_version}")       # :2.5.12
tags+=("$image_repo:${ldap_version%.*}.x")  # :2.5.x
tags+=("$image_repo:${ldap_version%%.*}.x") # :2.x


#################################################
# push image
#################################################
function regctl() {
   (set -x;
   docker run --rm \
      -u "$(id -u):$(id -g)" -e HOME -v "$HOME:$HOME" \
      -v /etc/docker/certs.d:/etc/docker/certs.d:ro \
      --network host `# required to access the temporary registry` \
      ghcr.io/regclient/regctl:latest \
      --host "reg=$local_registry,tls=disabled" \
      "${@}")
}

if [[ ${DOCKER_PUSH:-} == "true" ]]; then
   for tag in "${tags[@]}"; do
      regctl image copy "$local_registry/$image_name" "docker.io/$tag"
   done
fi
if [[ ${DOCKER_PUSH_GHCR:-} == true ]]; then
   for tag in "${tags[@]}"; do
      regctl image copy "$local_registry/$image_name" "ghcr.io/$tag"
   done
fi
