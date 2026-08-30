#!/usr/bin/env bash
# crun: upstream rpm/crun.spec built from the self-contained release dist
# tarball, with SPAL's Amazon Linux 2023 criu-devel relaxation.

crun_validate_inputs() {
  : "${CRUN_TAG:?CRUN_TAG is required}"
  : "${CRUN_VERSION:?CRUN_VERSION is required}"
  : "${CRUN_ARCHIVE_SHA256:?CRUN_ARCHIVE_SHA256 is required}"

  # crun tags are the bare version (e.g. "1.28" or "1.14.4"); no leading "v".
  [[ "${CRUN_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "invalid crun version: ${CRUN_VERSION}"
  [[ "${CRUN_TAG}" == "${CRUN_VERSION}" ]] || die "crun tag (${CRUN_TAG}) must equal version (${CRUN_VERSION})"
}

crun_prepare_spec() {
  # The release dist tarball (configure + bundled libocispec/blake3), not the
  # git archive, which lacks the submodule and configure.
  local source_url="https://github.com/containers/crun/releases/download/${CRUN_TAG}/crun-${CRUN_VERSION}.tar.gz"
  local tarball="${SOURCES_DIR}/crun-${CRUN_VERSION}.tar.gz"

  fetch_upstream "${source_url}" "${CRUN_ARCHIVE_SHA256}" "crun-${CRUN_VERSION}.tar.gz"
  SPEC="${SPECS_DIR}/crun.spec"
  extract_spec_from_archive "${tarball}" "crun-${CRUN_VERSION}/rpm/crun.spec" crun.spec

  spec_replace_line "${SPEC}" '^Version: 0$' "Version: ${CRUN_VERSION}"
  spec_set_release "${SPEC}"
  # Upstream points at the .tar.zst release asset; this repository pins the
  # .tar.gz of the same release.
  spec_replace_line "${SPEC}" '^Source0:[[:space:]].*\.tar\.zst$' 'Source0: %{url}/releases/download/%{version}/%{name}-%{version}.tar.gz'
  # Amazon Linux 2023 defines %%fedora but packages neither libkrun-devel nor
  # wasmedge-devel; disable the Fedora-only krun/wasm block the way SPAL does
  # (it wraps the same block in `%if 0%{?spal} < 2023`).
  spec_replace_line "${SPEC}" '^%ifarch aarch64 [|][|] x86_64$' '%if 0'
  # Amazon Linux 2023 ships criu-devel 3.17.1-1; SPAL relaxes the Fedora
  # 3.17.1-2 floor to the upstream version.
  spec_replace_line "${SPEC}" '^BuildRequires: criu-devel >= 3\.17\.1-2$' 'BuildRequires: criu-devel >= 3.17.1'

  spec_set_changelog "${SPEC}" "${CRUN_VERSION}" \
    "Build upstream crun ${CRUN_TAG} (${PACKAGE_RELEASE}) with the upstream rpm/crun.spec and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  crun_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized crun build for ${TARGET_ARCH} (${CRUN_TAG})"
  setup_rpm_tree
  crun_prepare_spec
  install_build_deps "${SPEC}"
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} crun build for ${TARGET_ARCH} (${CRUN_TAG})"
}
