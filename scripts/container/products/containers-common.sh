#!/usr/bin/env bash
# containers-common: upstream common/rpm/containers-common.spec from the
# container-libs monorepo. noarch: config files and man pages only.

containers_common_validate_inputs() {
  : "${CONTAINERS_COMMON_TAG:?CONTAINERS_COMMON_TAG is required}"
  : "${CONTAINERS_COMMON_VERSION:?CONTAINERS_COMMON_VERSION is required}"
  : "${CONTAINERS_COMMON_ARCHIVE_SHA256:?CONTAINERS_COMMON_ARCHIVE_SHA256 is required}"
  : "${SHORTNAMES_COMMIT:?SHORTNAMES_COMMIT is required}"
  : "${SHORTNAMES_SHA256:?SHORTNAMES_SHA256 is required}"
  : "${REDHAT_RELEASE_KEY_SHA256:?REDHAT_RELEASE_KEY_SHA256 is required}"

  [[ "${CONTAINERS_COMMON_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid containers-common version: ${CONTAINERS_COMMON_VERSION}"
  [[ "${CONTAINERS_COMMON_TAG}" == "common/v${CONTAINERS_COMMON_VERSION}" ]] || \
    die "containers-common tag (${CONTAINERS_COMMON_TAG}) must equal common/v${CONTAINERS_COMMON_VERSION}"
  [[ "${SHORTNAMES_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "invalid SHORTNAMES_COMMIT: ${SHORTNAMES_COMMIT}"
  [[ "${TARGET_ARCH}" == "noarch" ]] || die "containers-common is noarch; build it with TARGET_ARCH=noarch"
}

containers_common_prepare_spec() {
  local source_url="https://github.com/containers/container-libs/archive/refs/tags/${CONTAINERS_COMMON_TAG}.tar.gz"
  local shortnames_url="https://raw.githubusercontent.com/containers/shortnames/${SHORTNAMES_COMMIT}/shortnames.conf"
  local tarball="${SOURCES_DIR}/v${CONTAINERS_COMMON_VERSION}.tar.gz"
  local tree="container-libs-common-v${CONTAINERS_COMMON_VERSION}"

  # Source0 resolves to the tag's basename, v<VERSION>.tar.gz.
  fetch_upstream "${source_url}" "${CONTAINERS_COMMON_ARCHIVE_SHA256}" "v${CONTAINERS_COMMON_VERSION}.tar.gz"
  # Source1: upstream fetches the alias table from the shortnames main branch;
  # pin it to an exact commit.
  fetch_upstream "${shortnames_url}" "${SHORTNAMES_SHA256}" "shortnames.conf"
  # Source2: Red Hat's release key, installed because Amazon Linux 2023 defines
  # %%fedora (Amazon's own containers-common ships it as well); pinned by hash.
  fetch_upstream "https://access.redhat.com/security/data/fd431d51.txt" "${REDHAT_RELEASE_KEY_SHA256}" "fd431d51.txt"

  SPEC="${SPECS_DIR}/containers-common.spec"
  extract_spec_from_archive "${tarball}" "${tree}/common/rpm/containers-common.spec" containers-common.spec

  spec_replace_line "${SPEC}" '^Version: 0$' "Version: ${CONTAINERS_COMMON_VERSION}"
  spec_set_release "${SPEC}"
  spec_replace_line "${SPEC}" '^Source1:[[:space:]]' "Source1: ${shortnames_url}"
  spec_require_line "${SPEC}" '^BuildArch: noarch$' "expected a noarch spec"

  spec_set_changelog "${SPEC}" "${CONTAINERS_COMMON_VERSION}" \
    "Build upstream ${CONTAINERS_COMMON_TAG} (${PACKAGE_RELEASE}) with the upstream common/rpm/containers-common.spec, shortnames.conf @ ${SHORTNAMES_COMMIT:0:12} and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  containers_common_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized containers-common build (${CONTAINERS_COMMON_TAG})"
  setup_rpm_tree
  containers_common_prepare_spec
  install_build_deps "${SPEC}"
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} containers-common build (${CONTAINERS_COMMON_TAG})"
}
