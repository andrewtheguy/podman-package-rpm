#!/usr/bin/env bash
# passt: upstream contrib/fedora/passt.spec (an rpkg template — the file
# Fedora's, EPEL's and SPAL's passt.spec are rendered from) built from the tag
# snapshot on passt.top.

passt_validate_inputs() {
  : "${PASST_TAG:?PASST_TAG is required}"
  : "${PASST_ARCHIVE_SHA256:?PASST_ARCHIVE_SHA256 is required}"
  [[ "${PASST_TAG}" =~ ^([0-9]{4})_([0-9]{2})_([0-9]{2})\.([0-9a-f]{7,40})$ ]] || \
    die "invalid PASST_TAG (expected YYYY_MM_DD.<hash>): ${PASST_TAG}"
  # Fedora's snapshot versioning: 0^<YYYYMMDD>.g<hash>
  RPM_VERSION="0^${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}.g${BASH_REMATCH[4]}"
}

passt_prepare_spec() {
  local source_url="https://passt.top/passt/snapshot/passt-${PASST_TAG}.tar.xz"
  local tarball="${SOURCES_DIR}/passt-${PASST_TAG}.tar.xz"

  fetch_upstream "${source_url}" "${PASST_ARCHIVE_SHA256}" "passt-${PASST_TAG}.tar.xz"
  SPEC="${SPECS_DIR}/passt.spec"
  extract_spec_from_archive "${tarball}" "passt-${PASST_TAG}/contrib/fedora/passt.spec" passt.spec

  # Render the rpkg template: git_hash names the tarball/tree (passt-<TAG>),
  # git_version becomes the pinned snapshot version, the changelog is ours.
  spec_replace_line "${SPEC}" '^%global git_hash [{][{][{] git_head [}][}][}]$' "%global git_hash ${PASST_TAG}"
  spec_replace_line "${SPEC}" '^Version:[[:space:]]+[{][{][{] git_version [}][}][}]$' "Version:	${RPM_VERSION}"
  spec_set_release "${SPEC}"
  # %make_build (make -jN) hands gcc 11's lto-wrapper a jobserver whose fds
  # make has already closed ("write jobserver: Bad file descriptor"), which
  # kills the -flto=auto link of passt/passt.avx2 on x86_64. Build serially;
  # gcc still parallelizes LTO on its own and the tree is small.
  spec_replace_text "${SPEC}" '%make_build' '%{__make}'
  # %setup -> %autosetup so the repo-managed patch series applies.
  spec_replace_line "${SPEC}" '^%setup -q -n passt-%[{]git_hash[}]$' '%autosetup -p1 -n passt-%{git_hash}'

  spec_set_changelog "${SPEC}" "${RPM_VERSION}" \
    "Build upstream passt ${PASST_TAG} (${PACKAGE_RELEASE}) with the upstream contrib/fedora/passt.spec and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  passt_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized passt build for ${TARGET_ARCH} (${PASST_TAG})"
  setup_rpm_tree
  passt_prepare_spec
  install_build_deps "${SPEC}"
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} passt build for ${TARGET_ARCH} (${PASST_TAG})"
}
