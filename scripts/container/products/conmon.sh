#!/usr/bin/env bash
# conmon: upstream rpm/conmon.spec (its Version is a literal, not a placeholder).

conmon_validate_inputs() {
  : "${CONMON_TAG:?CONMON_TAG is required}"
  : "${CONMON_VERSION:?CONMON_VERSION is required}"
  : "${CONMON_ARCHIVE_SHA256:?CONMON_ARCHIVE_SHA256 is required}"

  [[ "${CONMON_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid conmon version: ${CONMON_VERSION}"
  [[ "${CONMON_TAG}" == "v${CONMON_VERSION}" ]] || die "conmon tag (${CONMON_TAG}) must equal v${CONMON_VERSION}"
}

conmon_prepare_spec() {
  local source_url="https://github.com/containers/conmon/archive/refs/tags/${CONMON_TAG}.tar.gz"
  local tarball="${SOURCES_DIR}/${CONMON_TAG}.tar.gz"

  fetch_upstream "${source_url}" "${CONMON_ARCHIVE_SHA256}" "${CONMON_TAG}.tar.gz"
  SPEC="${SPECS_DIR}/conmon.spec"
  extract_spec_from_archive "${tarball}" "conmon-${CONMON_VERSION}/rpm/conmon.spec" conmon.spec

  spec_require_line "${SPEC}" "^Version: ${CONMON_VERSION//./\\.}$" \
    "in-tree spec Version differs from CONMON_VERSION=${CONMON_VERSION}: $(grep -E '^Version:' "${SPEC}" || true)"
  spec_set_release "${SPEC}"

  spec_set_changelog "${SPEC}" "${CONMON_VERSION}" \
    "Build upstream conmon ${CONMON_TAG} (${PACKAGE_RELEASE}) with the upstream rpm/conmon.spec and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  conmon_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized conmon build for ${TARGET_ARCH} (${CONMON_TAG})"
  setup_rpm_tree
  conmon_prepare_spec
  install_build_deps "${SPEC}"
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} conmon build for ${TARGET_ARCH} (${CONMON_TAG})"
}
