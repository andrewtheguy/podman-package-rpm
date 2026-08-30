#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: ./scripts/build-rpm.sh <package>

Packages:
  podman
  netavark
  aardvark-dns
  containers-common   (noarch; built once on the host's native platform)
  crun
  conmon
  passt
  catatonit

Target: Amazon Linux 2023 (amazonlinux:2023), aarch64 then x86_64.

Environment:
  BUILD_ARCHES    Space-separated subset of "aarch64 x86_64" to build
                  (compiled packages only; default: both). Cross-platform
                  builds run under emulation and are slow — limit to the
                  native architecture when iterating locally.
  BUILD_REVISION  Positive integer appended to the build date (default: 1).
  BASE_IMAGE      Builder image (default: amazonlinux:2023).
USAGE
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

PRODUCT="$1"

case "${PRODUCT}" in
  podman|netavark|aardvark-dns|containers-common|crun|conmon|passt|catatonit) ;;
  *)
    usage
    die "unsupported package: ${PRODUCT}"
    ;;
esac

TARGET="al2023"
TARGET_LABEL="Amazon Linux 2023"
BASE_IMAGE="${BASE_IMAGE:-amazonlinux:2023}"

if [[ "${PRODUCT}" == "containers-common" ]]; then
  # containers-common is noarch; one deterministic build is enough.
  ARCHES=("noarch")
else
  read -r -a ARCHES <<< "${BUILD_ARCHES:-aarch64 x86_64}"
  for arch in "${ARCHES[@]}"; do
    case "${arch}" in
      aarch64|x86_64) ;;
      *) die "BUILD_ARCHES may only contain aarch64 and x86_64: ${arch}" ;;
    esac
  done
fi

OUTPUT_ROOT="${REPO_ROOT}/output"
BUILD_VERSION="$(date -u +%Y%m%d)"
VERSION_CONFIG="${REPO_ROOT}/packaging/versions.env"
PATCH_SOURCE_DIR="${REPO_ROOT}/packaging/${PRODUCT}/patches"
DOCKERFILE_PATH="${REPO_ROOT}/docker/Dockerfile"
PIPELINE_LABEL="single buildx ${TARGET_LABEL} ${PRODUCT} pipeline"
DONE_MESSAGE="Done. ${TARGET_LABEL} ${PRODUCT} artifacts are in ${OUTPUT_ROOT}/${TARGET}/${BUILD_VERSION}"

main() {
  run_orchestrator
}

main
