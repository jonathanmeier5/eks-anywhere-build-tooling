#!/usr/bin/env bash
# Copyright Amazon.com Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


set -x
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_ROOT}/common.sh"

# go $GOBUILD_COMMAND -trimpath -a -ldflags "$GO_LDFLAGS" $EXTRA_GOBUILD_FLAGS -o $TARGET_FILE $SOURCE_PATTERN

GOLANG_VERSION="$1"
shift

# proper version of go installed locally
if false; then # go version = GOLANG_VERSION
    go $@
    exit $?
fi

project_mount=$(realpath .)
output_mount=$(realpath .)/../_output

TARGET_FILE=""
ARGS=()
while test $# -gt 0; do
  case "$1" in
    -o)
      shift
      TARGET_FILE=$1

        output_mount=$(dirname $(realpath $TARGET_FILE))
        output_file=$(basename $TARGET_FILE)
        if [ -d $TARGET_FILE ]; then
            output_mount=$TARGET_FILE
            output_file=
        fi
      ARGS+=("-o" "/output/$output_file")   
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if true && command -v docker &> /dev/null && docker info > /dev/null 2>&1 ; then
    #echo "golang version $GOLANG_VERSION not available locally, falling back to docker"
    GOLANG_VERSION=1.16
    #build::docker::retry_pull public.ecr.aws/k1e6s8o8/eks-distro-minimal-base-golang:$GOLANG_VERSION-latest

    docker run \
        --mount type=bind,source=$project_mount,target=/project \
        --mount type=bind,source=$output_mount,target=/output \
        -e CGO_ENABLED=${CGO_ENABLED:-0} -e GOOS=$GOOS -e GOARCH=$GOARCH -w /project \
        public.ecr.aws/k1e6s8o8/eks-distro-minimal-base-golang:$GOLANG_VERSION-latest go "${ARGS[@]}"
    exit $?
fi


longest_common_prefix()
{
    declare -a names
    declare -a parts
    declare i=0

    names=("$@")
    name="$1"
    while x=$(dirname "$name"); [ "$x" != "/" ]
    do
        parts[$i]="$x"
        i=$(($i + 1))
        name="$x"
    done

    for prefix in "${parts[@]}" /
    do
        for name in "${names[@]}"
        do
            if [ "${name#$prefix/}" = "${name}" ]
            then continue 2
            fi
        done
        echo "$prefix"
        break
    done
}

echo "golang version $GOLANG_VERSION not available locally,  falling back to buildctl"

dockerfile_dir=$(mktemp -d)
trap "rm -rf $dockerfile_dir" EXIT

cat << 'EOF' > $dockerfile_dir/Dockerfile
ARG IMAGE
FROM $IMAGE AS run

ARG CGO_ENABLED
ARG GOOS
ARG GOARCH
ARG PROJECT_ROOT
ARG OUTPUT_DIRECTORY
ARG GOBUILD_COMMAND

ENV GOCACHE /go-build
WORKDIR /project
RUN --mount=type=bind,source=$PROJECT_ROOT,target=/project \
    --mount=type=cache,target=/go-build \
    /project/command 

FROM scratch
COPY --from=run /output/* .
EOF


context=$(longest_common_prefix $project_mount $output_mount)
relative_project_mount=$(realpath --relative-to=$context $project_mount)
relative_output_mount=$(realpath --relative-to=$context $output_mount)

#echo "go ${ARGS[@]@Q}" > $project_mount/command
echo "go $(printf " '%q'" "${ARGS[@]}")" > $project_mount/command
chmod +x $project_mount/command
#exit
$BUILD_ROOT/buildkit.sh build \
    --frontend dockerfile.v0 \
    --local dockerfile=$dockerfile_dir \
    --local context=$context \
    --progress plain \
    --opt build-arg:IMAGE=public.ecr.aws/k1e6s8o8/eks-distro-minimal-base-golang:$GOLANG_VERSION-latest \
    --opt build-arg:CGO_ENABLED=$CGO_ENABLED \
    --opt build-arg:GOOS=$GOOS \
    --opt build-arg:GOARCH=$GOARCH \
    --opt build-arg:PROJECT_ROOT=$relative_project_mount \
    --opt build-arg:OUTPUT_DIRECTORY=$relative_output_mount \
    --output type=local,dest=$output_mount

if [ "${JOB_TYPE:-}" == "presubmit" ]; then
    $BUILD_ROOT/buildkit.sh prune --all
fi
