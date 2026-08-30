#!/usr/bin/env bash
# netavark / aardvark-dns: upstream rpm/<name>.spec with the two Amazon Linux
# 2023 adaptations Amazon's own netavark and aardvark-dns specs carry, built
# offline from the release vendor tarball with the distro's cargo.

rust_companion_configure_product() {
  case "${PRODUCT}" in
    netavark)
      COMPANION_NAME="netavark"
      COMPANION_TAG="${NETAVARK_TAG:-}"
      COMPANION_UPSTREAM_SHA256="${NETAVARK_UPSTREAM_SHA256:-}"
      COMPANION_VENDOR_SHA256="${NETAVARK_VENDOR_SHA256:-}"
      ;;
    aardvark-dns)
      COMPANION_NAME="aardvark-dns"
      COMPANION_TAG="${AARDVARK_TAG:-}"
      COMPANION_UPSTREAM_SHA256="${AARDVARK_UPSTREAM_SHA256:-}"
      COMPANION_VENDOR_SHA256="${AARDVARK_VENDOR_SHA256:-}"
      ;;
    *)
      die "unsupported Rust companion product: ${PRODUCT}"
      ;;
  esac
}

rust_companion_validate_inputs() {
  : "${COMPANION_TAG:?${PRODUCT} tag is required}"
  : "${COMPANION_UPSTREAM_SHA256:?${PRODUCT} upstream sha256 is required}"
  : "${COMPANION_VENDOR_SHA256:?${PRODUCT} vendor sha256 is required}"
  : "${RUST_MIN_VERSION:?RUST_MIN_VERSION is required}"

  [[ "${COMPANION_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "invalid ${PRODUCT} tag: ${COMPANION_TAG}"
  [[ "${RUST_MIN_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid RUST_MIN_VERSION: ${RUST_MIN_VERSION}"
}

rust_companion_prepare_spec() {
  UPSTREAM_VERSION="${COMPANION_TAG#v}"
  RPM_VERSION="${UPSTREAM_VERSION//-rc/~rc}"
  local base_url="https://github.com/containers/${COMPANION_NAME}"
  local tarball="${SOURCES_DIR}/${COMPANION_TAG}.tar.gz"

  # Source0 / Source1 basenames as the spec's URLs resolve them.
  fetch_upstream "${base_url}/archive/refs/tags/${COMPANION_TAG}.tar.gz" "${COMPANION_UPSTREAM_SHA256}" "${COMPANION_TAG}.tar.gz"
  fetch_upstream "${base_url}/releases/download/${COMPANION_TAG}/${COMPANION_NAME}-${COMPANION_TAG}-vendor.tar.gz" \
    "${COMPANION_VENDOR_SHA256}" "${COMPANION_NAME}-${COMPANION_TAG}-vendor.tar.gz"

  SPEC="${SPECS_DIR}/${COMPANION_NAME}.spec"
  extract_spec_from_archive "${tarball}" "${COMPANION_NAME}-${UPSTREAM_VERSION}/rpm/${COMPANION_NAME}.spec" "${COMPANION_NAME}.spec"

  spec_replace_line "${SPEC}" '^Version: 0$' "Version: ${RPM_VERSION}"
  spec_set_release "${SPEC}"

  # Amazon Linux 2023 defines %%fedora (34), which would select the Fedora /
  # RHEL 10 branches: %cargo_prep -v vendor, %cargo_license_summary,
  # %cargo_vendor_manifest and the generated license files. Its rust-packaging
  # (21) has none of those macros, so take the other branch, as Amazon's specs
  # do with their `!0%{?amzn}` guards.
  spec_replace_line "${SPEC}" '^%if 0%[{][?]fedora[}] [|][|] 0%[{][?]rhel[}] >= 10$' '%if 0'
  spec_replace_all "${SPEC}" '^%if [(]0%[{][?]fedora[}] [|][|] 0%[{][?]rhel[}] >= 10[)] && !%[{]defined copr_username[}]$' '%if 0'
  # The non-RHEL branch wants rust-packaging + rust-srpm-macros, but AL2023's
  # rust-toolset-srpm-macros (pulled in by cargo) obsoletes rust-srpm-macros, so
  # that pair cannot be installed; use the RHEL branch's rust-toolset instead.
  spec_delete_line "${SPEC}" '^BuildRequires: rust-packaging$'
  spec_replace_line "${SPEC}" '^BuildRequires: rust-srpm-macros$' 'BuildRequires: rust-toolset'
  # Amazon Linux 2023's rust-packaging %cargo_prep rewrites .cargo/config to
  # the /usr/share/cargo/registry local registry and deletes Cargo.lock, which
  # defeats the vendored offline build. Amazon's netavark/aardvark-dns specs
  # replace it with an explicit vendored-sources config; do the same.
  spec_replace_line "${SPEC}" '^%cargo_prep -V 1$' 'mkdir -p .cargo
cat > .cargo/config.toml << VENDOREOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
VENDOREOF'
  # %{__cargo} on Amazon Linux 2023 injects RUSTFLAGS pointing at a linker
  # script only %set_build_flags generates; the Amazon specs call plain cargo.
  spec_replace_text "${SPEC}" 'CARGO="%{__cargo}"' 'CARGO="cargo"'
  if [[ "${PRODUCT}" == netavark ]]; then
    # cargo uplifts the example binaries as hard links; `cp -a` keeps the links
    # and AL2023's rpm 4.16 brp-strip then strips the same inode in parallel
    # ("strip: file truncated"). Copy them as independent files instead (the
    # netavark-tests subpackage they land in is never published).
    spec_replace_text "${SPEC}" '%{__cp} -rpav targets/release/examples/*' '%{__cp} -rpv targets/release/examples/*'
  fi

  spec_set_changelog "${SPEC}" "${RPM_VERSION}" \
    "Build upstream ${COMPANION_NAME} ${COMPANION_TAG} (${PACKAGE_RELEASE}) with the upstream rpm/${COMPANION_NAME}.spec and the repo-managed patch series for ${DISTRO_LABEL}."
  inject_patch_series "${SPEC}"
}

product_main() {
  rust_companion_configure_product
  rust_companion_validate_inputs

  log "Starting ${DISTRO_LABEL} containerized ${COMPANION_NAME} build for ${TARGET_ARCH} (${COMPANION_TAG})"
  setup_rpm_tree
  rust_companion_prepare_spec
  install_build_deps "${SPEC}"
  assert_rust_min_version
  run_rpmbuild "${SPEC}"
  collect_artifacts "${SPEC}"
  log "Completed ${DISTRO_LABEL} ${COMPANION_NAME} build for ${TARGET_ARCH} (${COMPANION_TAG})"
}
