#!/usr/bin/env bash
# podman: upstream rpm/podman.spec (the file SPAL's and Fedora's podman.spec are
# copied from) built against Amazon Linux 2023's golang.

podman_validate_inputs() {
  : "${PODMAN_TAG:?PODMAN_TAG is required}"
  : "${UPSTREAM_SHA256:?UPSTREAM_SHA256 is required}"
  : "${NETAVARK_TAG:?NETAVARK_TAG is required}"
  : "${AARDVARK_TAG:?AARDVARK_TAG is required}"
  : "${CONTAINERS_COMMON_VERSION:?CONTAINERS_COMMON_VERSION is required}"
}

podman_prepare_spec() {
  UPSTREAM_VERSION="${PODMAN_TAG#v}"
  # rpm cannot carry "-rc1"; the spec's %{version_no_tilde} maps ~rc1 back to
  # the tarball directory name.
  RPM_VERSION="${UPSTREAM_VERSION//-rc/~rc}"
  local source_url="https://github.com/podman-container-tools/podman/archive/refs/tags/${PODMAN_TAG}.tar.gz"
  local tarball="${SOURCES_DIR}/${PODMAN_TAG}.tar.gz"

  fetch_upstream "${source_url}" "${UPSTREAM_SHA256}" "${PODMAN_TAG}.tar.gz"
  SPEC="${SPECS_DIR}/podman.spec"
  extract_spec_from_archive "${tarball}" "podman-${UPSTREAM_VERSION}/rpm/podman.spec" podman.spec
  tar -xf "${tarball}" -O "podman-${UPSTREAM_VERSION}/go.mod" > "${WORK_ROOT}/go.mod" || die "unable to extract go.mod"

  # Version: 0 is the in-tree placeholder Packit fills in for Fedora builds.
  spec_replace_line "${SPEC}" '^Version: 0$' "Version: ${RPM_VERSION}"
  spec_set_release "${SPEC}"
  spec_replace_line "${SPEC}" '^Source0:[[:space:]]' "Source0: ${source_url}"
  # Amazon Linux 2023 defines %%fedora (34) but packages no btrfs-progs-devel;
  # drop the Fedora-only btrfs BuildRequires (hack/btrfs_installed_tag.sh then
  # selects exclude_graphdriver_btrfs on its own).
  spec_delete_line "${SPEC}" '^%define build_with_btrfs 1$'

  # Dependencies. Upstream pins the containers-common layout podman 6 needs;
  # it must be the version this repository ships, or the two drift apart.
  spec_require_line "${SPEC}" "^Requires: containers-common-extra >= 5:${CONTAINERS_COMMON_VERSION//./\\.}$" \
    "Requires: containers-common-extra does not match CONTAINERS_COMMON_VERSION=${CONTAINERS_COMMON_VERSION} — reconcile packaging/versions.env with the spec: $(grep -E '^Requires: containers-common-extra' "${SPEC}" || true)"
  # Core Amazon Linux 2023 ships netavark/aardvark-dns 1.17 (Epoch 2), which
  # satisfy the generic container-network-stack dependency; pin the versions
  # built here instead, the way the .deb build pins its companions.
  spec_insert_after "${SPEC}" '^Requires: catatonit$' \
    "Requires: netavark >= 2:${NETAVARK_TAG#v}"$'\n'"Requires: aardvark-dns >= 2:${AARDVARK_TAG#v}"
  # conmon >= 2:2.1.7-2 and catatonit stay as upstream wrote them: either the
  # SPAL packages or this repository's `extra` component satisfy them.

  spec_set_changelog "${SPEC}" "${RPM_VERSION}" \
    "Build upstream ${PODMAN_TAG} (${PACKAGE_RELEASE}) with the upstream rpm/podman.spec and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  podman_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized podman build for ${TARGET_ARCH} (${PODMAN_TAG})"
  setup_rpm_tree
  podman_prepare_spec
  install_build_deps "${SPEC}"
  assert_go_satisfies_go_mod "${WORK_ROOT}/go.mod"
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} podman build for ${TARGET_ARCH} (${PODMAN_TAG})"
}
