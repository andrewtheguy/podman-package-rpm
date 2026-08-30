#!/usr/bin/env bash
# catatonit: no in-tree RPM spec upstream, so the packaging comes from the SPAL
# (Supplementary Packages for Amazon Linux, EPEL9 rebuild) source RPM — the
# direct analogue of `apt-get source` — with the pinned upstream tarball.

catatonit_validate_inputs() {
  : "${CATATONIT_TAG:?CATATONIT_TAG is required}"
  : "${CATATONIT_VERSION:?CATATONIT_VERSION is required}"
  : "${CATATONIT_ARCHIVE_SHA256:?CATATONIT_ARCHIVE_SHA256 is required}"

  [[ "${CATATONIT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid catatonit version: ${CATATONIT_VERSION}"
  [[ "${CATATONIT_TAG}" == "v${CATATONIT_VERSION}" ]] || die "catatonit tag (${CATATONIT_TAG}) must equal v${CATATONIT_VERSION}"
}

catatonit_fetch_distro_spec() {
  install_packages spal-release cpio
  local srpm_dir="${WORK_ROOT}/srpm"
  mkdir -p "${srpm_dir}"
  log "Fetching the SPAL catatonit source package"
  dnf -y -q download --source --destdir "${WORK_ROOT}" catatonit
  local srpm
  srpm="$(find "${WORK_ROOT}" -maxdepth 1 -name 'catatonit-*.src.rpm' | head -n 1)"
  [[ -n "${srpm}" ]] || die "dnf download --source produced no catatonit source RPM"
  log "Distro packaging: $(basename "${srpm}")"
  (cd "${srpm_dir}" && rpm2cpio "${srpm}" | cpio -idm --quiet)
  [[ -f "${srpm_dir}/catatonit.spec" ]] || die "catatonit.spec missing from $(basename "${srpm}")"
  SPEC="${SPECS_DIR}/catatonit.spec"
  cp -f "${srpm_dir}/catatonit.spec" "${SPEC}"
}

catatonit_prepare_spec() {
  local source_url="https://github.com/openSUSE/catatonit/archive/refs/tags/${CATATONIT_TAG}.tar.gz"

  # Source0 resolves to the tag basename, v<VERSION>.tar.gz.
  fetch_upstream "${source_url}" "${CATATONIT_ARCHIVE_SHA256}" "${CATATONIT_TAG}.tar.gz"

  spec_replace_line "${SPEC}" '^Version:[[:space:]]' "Version: ${CATATONIT_VERSION}"
  spec_set_release "${SPEC}"

  spec_set_changelog "${SPEC}" "${CATATONIT_VERSION}" \
    "Build upstream catatonit ${CATATONIT_TAG} (${PACKAGE_RELEASE}) with the SPAL catatonit.spec and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  catatonit_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized catatonit build for ${TARGET_ARCH} (${CATATONIT_TAG})"
  setup_rpm_tree
  catatonit_fetch_distro_spec
  catatonit_prepare_spec
  install_build_deps "${SPEC}"
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} catatonit build for ${TARGET_ARCH} (${CATATONIT_TAG})"
}
