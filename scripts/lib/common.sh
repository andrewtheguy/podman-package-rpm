#!/usr/bin/env bash

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

verify_sha256() {
  local file="$1"
  local expected="${2,,}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "invalid expected sha256 for ${file}: ${2}"
  local actual
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || \
    die "checksum mismatch for ${file}: expected ${expected}, got ${actual}"
}

# Loads packaging/versions.env and resolves the product-specific pinned inputs.
# PRODUCT selects which input set to validate and which docker build args to pass.
load_versions_config() {
  [[ -f "${VERSION_CONFIG}" ]] || die "missing versions config: ${VERSION_CONFIG}"
  # shellcheck disable=SC1090
  source "${VERSION_CONFIG}"

  : "${PRODUCT:?PRODUCT is required}"
  PRODUCT_BUILD_ARGS=()

  local sha_re='^[0-9a-fA-F]{64}$'
  local semver_tag_re='^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
  local semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'

  case "${PRODUCT}" in
    podman)
      [[ "${PODMAN_TAG:-}" =~ ${semver_tag_re} ]] || \
        die "invalid or missing PODMAN_TAG in ${VERSION_CONFIG}: ${PODMAN_TAG:-<empty>}"
      [[ "${UPSTREAM_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing UPSTREAM_SHA256 in ${VERSION_CONFIG}: ${UPSTREAM_SHA256:-<empty>}"
      # The podman spec's Requires are pinned to these companions.
      [[ "${NETAVARK_TAG:-}" =~ ${semver_tag_re} ]] || die "invalid or missing NETAVARK_TAG in ${VERSION_CONFIG}"
      [[ "${AARDVARK_TAG:-}" =~ ${semver_tag_re} ]] || die "invalid or missing AARDVARK_TAG in ${VERSION_CONFIG}"
      [[ "${CONTAINERS_COMMON_VERSION:-}" =~ ${semver_re} ]] || die "invalid or missing CONTAINERS_COMMON_VERSION in ${VERSION_CONFIG}"
      RESOLVED_TAG="${PODMAN_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "PODMAN_TAG=${PODMAN_TAG}"
        --build-arg "UPSTREAM_SHA256=${UPSTREAM_SHA256}"
        --build-arg "NETAVARK_TAG=${NETAVARK_TAG}"
        --build-arg "AARDVARK_TAG=${AARDVARK_TAG}"
        --build-arg "CONTAINERS_COMMON_VERSION=${CONTAINERS_COMMON_VERSION}"
      )
      ;;
    netavark|aardvark-dns)
      local prefix tag_var upstream_var vendor_var tag upstream_sha vendor_sha
      if [[ "${PRODUCT}" == netavark ]]; then prefix=NETAVARK; else prefix=AARDVARK; fi
      tag_var="${prefix}_TAG"; tag="${!tag_var:-}"
      upstream_var="${prefix}_UPSTREAM_SHA256"; upstream_sha="${!upstream_var:-}"
      vendor_var="${prefix}_VENDOR_SHA256"; vendor_sha="${!vendor_var:-}"
      [[ "${tag}" =~ ${semver_tag_re} ]] || die "invalid or missing ${prefix}_TAG in ${VERSION_CONFIG}: ${tag:-<empty>}"
      [[ "${upstream_sha}" =~ ${sha_re} ]] || die "invalid or missing ${prefix}_UPSTREAM_SHA256 in ${VERSION_CONFIG}: ${upstream_sha:-<empty>}"
      [[ "${vendor_sha}" =~ ${sha_re} ]] || die "invalid or missing ${prefix}_VENDOR_SHA256 in ${VERSION_CONFIG}: ${vendor_sha:-<empty>}"
      [[ "${RUST_MIN_VERSION:-}" =~ ${semver_re} ]] || die "invalid or missing RUST_MIN_VERSION in ${VERSION_CONFIG}: ${RUST_MIN_VERSION:-<empty>}"
      RESOLVED_TAG="${tag}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "${prefix}_TAG=${tag}"
        --build-arg "${prefix}_UPSTREAM_SHA256=${upstream_sha}"
        --build-arg "${prefix}_VENDOR_SHA256=${vendor_sha}"
        --build-arg "RUST_MIN_VERSION=${RUST_MIN_VERSION}"
      )
      ;;
    crun)
      [[ "${CRUN_VERSION:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
        die "invalid or missing CRUN_VERSION in ${VERSION_CONFIG}: ${CRUN_VERSION:-<empty>}"
      [[ "${CRUN_TAG:-}" == "${CRUN_VERSION}" ]] || \
        die "CRUN_TAG (${CRUN_TAG:-<empty>}) must equal CRUN_VERSION (${CRUN_VERSION}) in ${VERSION_CONFIG}"
      [[ "${CRUN_ARCHIVE_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing CRUN_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${CRUN_ARCHIVE_SHA256:-<empty>}"
      RESOLVED_TAG="${CRUN_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CRUN_TAG=${CRUN_TAG}"
        --build-arg "CRUN_VERSION=${CRUN_VERSION}"
        --build-arg "CRUN_ARCHIVE_SHA256=${CRUN_ARCHIVE_SHA256}"
      )
      ;;
    conmon)
      [[ "${CONMON_VERSION:-}" =~ ${semver_re} ]] || \
        die "invalid or missing CONMON_VERSION in ${VERSION_CONFIG}: ${CONMON_VERSION:-<empty>}"
      [[ "${CONMON_TAG:-}" == "v${CONMON_VERSION}" ]] || \
        die "CONMON_TAG (${CONMON_TAG:-<empty>}) must equal v${CONMON_VERSION} in ${VERSION_CONFIG}"
      [[ "${CONMON_ARCHIVE_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing CONMON_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${CONMON_ARCHIVE_SHA256:-<empty>}"
      RESOLVED_TAG="${CONMON_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CONMON_TAG=${CONMON_TAG}"
        --build-arg "CONMON_VERSION=${CONMON_VERSION}"
        --build-arg "CONMON_ARCHIVE_SHA256=${CONMON_ARCHIVE_SHA256}"
      )
      ;;
    containers-common)
      [[ "${CONTAINERS_COMMON_VERSION:-}" =~ ${semver_re} ]] || \
        die "invalid or missing CONTAINERS_COMMON_VERSION in ${VERSION_CONFIG}: ${CONTAINERS_COMMON_VERSION:-<empty>}"
      [[ "${CONTAINERS_COMMON_TAG:-}" == "common/v${CONTAINERS_COMMON_VERSION}" ]] || \
        die "CONTAINERS_COMMON_TAG (${CONTAINERS_COMMON_TAG:-<empty>}) must equal common/v${CONTAINERS_COMMON_VERSION} in ${VERSION_CONFIG}"
      [[ "${CONTAINERS_COMMON_ARCHIVE_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing CONTAINERS_COMMON_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${CONTAINERS_COMMON_ARCHIVE_SHA256:-<empty>}"
      [[ "${SHORTNAMES_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || \
        die "invalid or missing SHORTNAMES_COMMIT in ${VERSION_CONFIG}: ${SHORTNAMES_COMMIT:-<empty>}"
      [[ "${SHORTNAMES_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing SHORTNAMES_SHA256 in ${VERSION_CONFIG}: ${SHORTNAMES_SHA256:-<empty>}"
      [[ "${REDHAT_RELEASE_KEY_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing REDHAT_RELEASE_KEY_SHA256 in ${VERSION_CONFIG}: ${REDHAT_RELEASE_KEY_SHA256:-<empty>}"
      RESOLVED_TAG="${CONTAINERS_COMMON_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CONTAINERS_COMMON_TAG=${CONTAINERS_COMMON_TAG}"
        --build-arg "CONTAINERS_COMMON_VERSION=${CONTAINERS_COMMON_VERSION}"
        --build-arg "CONTAINERS_COMMON_ARCHIVE_SHA256=${CONTAINERS_COMMON_ARCHIVE_SHA256}"
        --build-arg "SHORTNAMES_COMMIT=${SHORTNAMES_COMMIT}"
        --build-arg "SHORTNAMES_SHA256=${SHORTNAMES_SHA256}"
        --build-arg "REDHAT_RELEASE_KEY_SHA256=${REDHAT_RELEASE_KEY_SHA256}"
      )
      ;;
    passt)
      [[ "${PASST_TAG:-}" =~ ^[0-9]{4}_[0-9]{2}_[0-9]{2}\.[0-9a-f]{7,40}$ ]] || \
        die "invalid or missing PASST_TAG in ${VERSION_CONFIG} (expected YYYY_MM_DD.<hash>): ${PASST_TAG:-<empty>}"
      [[ "${PASST_ARCHIVE_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing PASST_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${PASST_ARCHIVE_SHA256:-<empty>}"
      RESOLVED_TAG="${PASST_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "PASST_TAG=${PASST_TAG}"
        --build-arg "PASST_ARCHIVE_SHA256=${PASST_ARCHIVE_SHA256}"
      )
      ;;
    catatonit)
      [[ "${CATATONIT_VERSION:-}" =~ ${semver_re} ]] || \
        die "invalid or missing CATATONIT_VERSION in ${VERSION_CONFIG}: ${CATATONIT_VERSION:-<empty>}"
      [[ "${CATATONIT_TAG:-}" == "v${CATATONIT_VERSION}" ]] || \
        die "CATATONIT_TAG (${CATATONIT_TAG:-<empty>}) must equal v${CATATONIT_VERSION} in ${VERSION_CONFIG}"
      [[ "${CATATONIT_ARCHIVE_SHA256:-}" =~ ${sha_re} ]] || \
        die "invalid or missing CATATONIT_ARCHIVE_SHA256 in ${VERSION_CONFIG}: ${CATATONIT_ARCHIVE_SHA256:-<empty>}"
      RESOLVED_TAG="${CATATONIT_TAG}"
      PRODUCT_BUILD_ARGS=(
        --build-arg "CATATONIT_TAG=${CATATONIT_TAG}"
        --build-arg "CATATONIT_VERSION=${CATATONIT_VERSION}"
        --build-arg "CATATONIT_ARCHIVE_SHA256=${CATATONIT_ARCHIVE_SHA256}"
      )
      ;;
    *)
      die "unknown PRODUCT: ${PRODUCT} (expected podman, netavark, aardvark-dns, containers-common, crun, conmon, passt, or catatonit)"
      ;;
  esac
}

check_patch_source() {
  [[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
  [[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"
}

# Docker platform for an RPM architecture. noarch products build once, on the
# host's native platform.
docker_platform_for_arch() {
  case "$1" in
    x86_64) echo "linux/amd64" ;;
    aarch64) echo "linux/arm64" ;;
    noarch)
      case "$(uname -m)" in
        x86_64|amd64) echo "linux/amd64" ;;
        arm64|aarch64) echo "linux/arm64" ;;
        *) die "unsupported host architecture for a noarch build: $(uname -m)" ;;
      esac
      ;;
    *) die "unsupported architecture: $1" ;;
  esac
}

run_build_for_arch() {
  local arch="$1"
  local revision="${BUILD_REVISION:-1}"
  local platform
  platform="$(docker_platform_for_arch "${arch}")"

  log "Running ${PIPELINE_LABEL} for ${arch} (${platform}) with ${PRODUCT} ${RESOLVED_TAG}"
  docker buildx build \
    --pull \
    --no-cache \
    --platform "${platform}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "PRODUCT=${PRODUCT}" \
    --build-arg "BUILD_VERSION=${BUILD_VERSION}" \
    --build-arg "BUILD_REVISION=${revision}" \
    "${PRODUCT_BUILD_ARGS[@]}" \
    --build-arg "TARGET_ARCH=${arch}" \
    --target artifact-export \
    --output "type=local,dest=${OUTPUT_ROOT}" \
    --file "${DOCKERFILE_PATH}" \
    "${REPO_ROOT}"
}

write_manifest() {
  local tag="$1"
  local revision="${BUILD_REVISION:-1}"
  local tag_dir="${OUTPUT_ROOT}/${TARGET}/${BUILD_VERSION}"
  local manifest_path="${tag_dir}/manifest.txt"

  mkdir -p "${tag_dir}"
  {
    echo "product=${PRODUCT}"
    echo "${PRODUCT}_tag=${tag}"
    echo "target=${TARGET}"
    echo "base_image=${BASE_IMAGE}"
    echo "build_version=${BUILD_VERSION}"
    echo "build_revision=${revision}"
    echo "build_id=${BUILD_VERSION}-${revision}"
    echo "generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    for arch in "${ARCHES[@]}"; do
      local arch_dir="${tag_dir}/${arch}"
      echo
      echo "[${arch}]"

      if [[ ! -d "${arch_dir}" ]]; then
        echo "missing output directory: ${arch_dir}"
        continue
      fi

      (
        cd "${arch_dir}"
        shopt -s nullglob
        files=( *.rpm )
        if [[ "${#files[@]}" -eq 0 ]]; then
          echo "no package artifacts found"
          exit 0
        fi
        sha256sum "${files[@]}"
      )
    done
  } > "${manifest_path}"

  log "Wrote manifest: ${manifest_path}"
}

run_orchestrator() {
  require_cmd docker
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"
  load_versions_config
  check_patch_source

  mkdir -p "${OUTPUT_ROOT}"
  local target_version_dir="${OUTPUT_ROOT}/${TARGET}/${BUILD_VERSION}"
  rm -rf "${target_version_dir}"

  log "Using pinned ${PRODUCT} tag from ${VERSION_CONFIG}: ${RESOLVED_TAG}"
  log "Builds run with docker buildx --pull --no-cache so dnf metadata/packages refresh every run."
  log "Per-arch runs are sequential; completed arch artifacts are exported immediately."

  local failed_arches=()
  for arch in "${ARCHES[@]}"; do
    log "Starting full workflow for ${arch} (single buildx pipeline)"

    if run_build_for_arch "${arch}"; then
      log "Completed ${arch}; artifacts exported to ${target_version_dir}/${arch}"
    else
      log "ERROR: build failed for ${arch}"
      failed_arches+=( "${arch}:build" )
      break
    fi
  done

  write_manifest "${RESOLVED_TAG}"

  if [[ "${#failed_arches[@]}" -gt 0 ]]; then
    die "one or more architecture runs failed: ${failed_arches[*]}"
  fi

  log "${DONE_MESSAGE}"
}
