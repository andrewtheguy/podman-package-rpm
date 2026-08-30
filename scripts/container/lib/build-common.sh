#!/usr/bin/env bash
# Shared in-container helpers: the RPM analogue of "distro packaging + pinned
# upstream source + repo-managed patch series".
#
# The packaging (the .spec) comes from the pinned upstream tarball itself — the
# containers projects keep their RPM spec in-tree (rpm/<name>.spec), and the
# Fedora / EPEL / SPAL / Amazon Linux specs are copies of it with distro
# conditionals. Each product module makes the few Amazon Linux 2023 edits that
# SPAL and Amazon's own specs make, with every edit asserted so a changed
# upstream spec fails the build loudly instead of silently building something
# else. catatonit has no in-tree spec, so its packaging is fetched from the
# SPAL source RPM (the `apt-get source` analogue).

validate_common_container_env() {
  : "${PRODUCT:?PRODUCT is required}"
  : "${TARGET_ARCH:?TARGET_ARCH is required}"
  : "${BUILD_VERSION:?BUILD_VERSION is required}"
  : "${BUILD_REVISION:=1}"

  [[ "${BUILD_VERSION}" =~ ^[0-9]{8}$ ]] || die "BUILD_VERSION must be a UTC date YYYYMMDD: ${BUILD_VERSION}"
  [[ "${BUILD_REVISION}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_REVISION must be a positive integer: ${BUILD_REVISION}"

  case "${TARGET_ARCH}" in
    x86_64|aarch64)
      [[ "$(uname -m)" == "${TARGET_ARCH}" ]] || \
        die "container architecture $(uname -m) does not match TARGET_ARCH ${TARGET_ARCH}"
      ;;
    noarch) ;;
    *) die "unsupported TARGET_ARCH: ${TARGET_ARCH}" ;;
  esac

  grep -q 'PLATFORM_ID="platform:al2023"' /etc/os-release || \
    die "this builder only supports Amazon Linux 2023 (got: $(grep PRETTY_NAME /etc/os-release))"

  TARGET="al2023"
  DISTRO_LABEL="Amazon Linux 2023"
  DIST_TAG="$(rpm -E '%{?dist}')"
  [[ "${DIST_TAG}" == ".amzn2023" ]] || die "unexpected %{dist}: ${DIST_TAG}"

  PATCH_SOURCE_DIR="/workspace/packaging/${PRODUCT}/patches"
  [[ -d "${PATCH_SOURCE_DIR}" ]] || die "patch directory not found: ${PATCH_SOURCE_DIR}"
  [[ -f "${PATCH_SOURCE_DIR}/series" ]] || die "missing patch series file: ${PATCH_SOURCE_DIR}/series"

  COMPONENTS_FILE="/workspace/packaging/repo/components"
  [[ -f "${COMPONENTS_FILE}" ]] || die "components table not found: ${COMPONENTS_FILE}"

  # RPM Release without %{?dist}: <build-date>.<revision>
  PACKAGE_RELEASE="${BUILD_VERSION}.${BUILD_REVISION}"
  BUILDER_NAME="Podman ${DISTRO_LABEL} Builder"
  BUILDER_EMAIL="builder@example.invalid"

  OUT_DIR="/out/${TARGET}/${BUILD_VERSION}/${TARGET_ARCH}"
}

install_packages() {
  dnf -y -q install "$@"
}

# rpmdev-setuptree + the tools every product needs (curl is already present as
# curl-minimal; installing curl would conflict with it).
setup_rpm_tree() {
  install_packages rpm-build rpmdevtools dnf-plugins-core git-core tar gzip xz ca-certificates
  rpmdev-setuptree
  RPM_TOP="$(rpm -E '%{_topdir}')"
  SOURCES_DIR="${RPM_TOP}/SOURCES"
  SPECS_DIR="${RPM_TOP}/SPECS"
  WORK_ROOT="/tmp/${PRODUCT}-build"
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}" "${SOURCES_DIR}" "${SPECS_DIR}"
}

# fetch_upstream <url> <sha256> <name>: download into SOURCES/<name>, verify.
# <name> must be the basename rpmbuild derives from the spec's SourceN URL.
fetch_upstream() {
  local url="$1" sha="$2" name="$3"
  local dest="${SOURCES_DIR}/${name}"
  log "Downloading ${url}"
  curl -fsSL --retry 3 --retry-all-errors -o "${dest}" -L "${url}"
  verify_sha256 "${dest}" "${sha}"
}

# extract_spec_from_archive <archive> <member> <spec-name>: copy one file out
# of a tarball (any compression) into SPECS/<spec-name>.
extract_spec_from_archive() {
  local archive="$1" member="$2" spec_name="$3"
  local dest="${SPECS_DIR}/${spec_name}"
  tar -xf "${archive}" -O "${member}" > "${dest}" || die "unable to extract ${member} from ${archive}"
  [[ -s "${dest}" ]] || die "extracted spec is empty: ${member}"
  log "Using packaging from ${member}"
}

# --- asserted spec edits ----------------------------------------------------
# Every edit requires its anchor to match exactly once (or at least once for
# the _all variant); a spec that changed upstream fails here, on purpose.

_spec_count() { grep -cE -- "$2" "$1" || true; }

spec_replace_line() { # <spec> <ERE anchor> <replacement line(s)>
  local spec="$1" pattern="$2" replacement="$3" count
  count="$(_spec_count "${spec}" "${pattern}")"
  [[ "${count}" -eq 1 ]] || die "spec edit anchor /${pattern}/ matched ${count} lines in $(basename "${spec}") (expected 1)"
  REPLACEMENT="${replacement}" awk -v pat="${pattern}" '$0 ~ pat { print ENVIRON["REPLACEMENT"]; next } { print }' \
    "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
}

spec_replace_all() { # <spec> <ERE anchor> <replacement line>
  local spec="$1" pattern="$2" replacement="$3" count
  count="$(_spec_count "${spec}" "${pattern}")"
  [[ "${count}" -ge 1 ]] || die "spec edit anchor /${pattern}/ matched nothing in $(basename "${spec}")"
  REPLACEMENT="${replacement}" awk -v pat="${pattern}" '$0 ~ pat { print ENVIRON["REPLACEMENT"]; next } { print }' \
    "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
}

spec_replace_text() { # <spec> <literal text> <literal replacement>: in-line, every occurrence
  local spec="$1" from="$2" to="$3" count
  count="$(grep -cF -- "${from}" "${spec}" || true)"
  [[ "${count}" -ge 1 ]] || die "spec edit text '${from}' not found in $(basename "${spec}")"
  FROM="${from}" TO="${to}" awk '
    BEGIN { f = ENVIRON["FROM"]; t = ENVIRON["TO"] }
    { out = ""; s = $0
      while ((i = index(s, f)) > 0) { out = out substr(s, 1, i - 1) t; s = substr(s, i + length(f)) }
      print out s }' "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
}

spec_delete_line() { # <spec> <ERE anchor>
  local spec="$1" pattern="$2" count
  count="$(_spec_count "${spec}" "${pattern}")"
  [[ "${count}" -eq 1 ]] || die "spec edit anchor /${pattern}/ matched ${count} lines in $(basename "${spec}") (expected 1)"
  grep -vE -- "${pattern}" "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
}

spec_insert_after() { # <spec> <ERE anchor> <line(s) to insert>
  local spec="$1" pattern="$2" insertion="$3" count
  count="$(_spec_count "${spec}" "${pattern}")"
  [[ "${count}" -eq 1 ]] || die "spec edit anchor /${pattern}/ matched ${count} lines in $(basename "${spec}") (expected 1)"
  INSERTION="${insertion}" awk -v pat="${pattern}" '{ print } $0 ~ pat { print ENVIRON["INSERTION"] }' \
    "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
}

spec_require_line() { # <spec> <ERE> <message>
  local spec="$1" pattern="$2" message="$3"
  grep -qE -- "${pattern}" "${spec}" || die "$(basename "${spec}"): ${message}"
}

spec_set_release() {
  spec_replace_line "$1" '^Release:[[:space:]]' "Release: ${PACKAGE_RELEASE}%{?dist}"
}

# spec_set_changelog <spec> <version> <summary>: drop the upstream %changelog
# (%autochangelog / rpkg templates) and write this build's entry.
spec_set_changelog() {
  local spec="$1" version="$2" summary="$3"
  spec_require_line "${spec}" '^%changelog' "no %changelog section to replace"
  sed -i '/^%changelog/,$d' "${spec}"
  {
    echo '%changelog'
    printf '* %s %s <%s> - %s-%s\n' "$(LC_ALL=C date -u +'%a %b %d %Y')" \
      "${BUILDER_NAME}" "${BUILDER_EMAIL}" "${version}" "${PACKAGE_RELEASE}"
    printf -- '- %s\n' "${summary}"
  } >> "${spec}"
}

# inject_patch_series <spec>: the repo-managed series becomes PatchNNNN: lines
# after the last SourceN:, applied by the spec's %autosetup (-p1). An empty
# series means no patches; the distro spec never contributes patches of its own
# because the packaging comes from the pinned upstream tree.
inject_patch_series() {
  local spec="$1" series="${PATCH_SOURCE_DIR}/series"
  local patches=() patch
  while IFS= read -r patch; do
    patch="${patch%%#*}"; patch="${patch## }"; patch="${patch%% }"
    [[ -n "${patch}" ]] && patches+=("${patch}")
  done < "${series}"

  if [[ "${#patches[@]}" -eq 0 ]]; then
    log "Patch series is empty; no patches applied"
    return 0
  fi

  spec_require_line "${spec}" '^%autosetup' "spec has no %autosetup; the patch series cannot be applied"
  local count
  count="$(_spec_count "${spec}" '^Patch[0-9]*:')"
  [[ "${count}" -eq 0 ]] || die "$(basename "${spec}") already carries ${count} Patch lines; only the repo-managed series may apply patches"

  local lines="" n=1000
  for patch in "${patches[@]}"; do
    [[ -f "${PATCH_SOURCE_DIR}/${patch}" ]] || die "patch listed in series not found: ${PATCH_SOURCE_DIR}/${patch}"
    cp -f "${PATCH_SOURCE_DIR}/${patch}" "${SOURCES_DIR}/"
    lines+="Patch${n}: ${patch}"$'\n'
    n=$((n + 1))
  done

  local anchor
  anchor="$(grep -nE '^Source[0-9]*:' "${spec}" | tail -n 1 | cut -d: -f1)"
  [[ -n "${anchor}" ]] || die "$(basename "${spec}") has no Source line to anchor Patch lines to"
  PATCH_LINES="${lines%$'\n'}" awk -v n="${anchor}" '{ print } NR == n { print ENVIRON["PATCH_LINES"] }' \
    "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
  log "Applying ${#patches[@]} patch(es) from ${series}: ${patches[*]}"
}

# --- toolchain assertions ----------------------------------------------------

version_ge() { # <have> <want>
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

# The distro Go must satisfy the `go` directive of the pinned upstream go.mod.
assert_go_satisfies_go_mod() {
  local go_mod="$1" required have
  required="$(awk '/^go[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $2; exit}' "${go_mod}")"
  [[ "${required}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "unable to read required Go version from ${go_mod}"
  have="$(go env GOVERSION)"; have="${have#go}"
  version_ge "${have}" "${required}" || \
    die "${DISTRO_LABEL} golang ${have} is older than the ${required} required by ${go_mod}; a newer toolchain is needed"
  log "Go toolchain ${have} satisfies go.mod requirement ${required}"
}

assert_rust_min_version() {
  local have
  have="$(rustc --version | awk '{print $2}')"
  version_ge "${have}" "${RUST_MIN_VERSION}" || \
    die "${DISTRO_LABEL} rustc ${have} is older than RUST_MIN_VERSION=${RUST_MIN_VERSION}"
  log "Rust toolchain ${have} satisfies RUST_MIN_VERSION=${RUST_MIN_VERSION}"
}

# --- build ------------------------------------------------------------------

install_build_deps() {
  local spec="$1"
  log "Resolving BuildRequires of $(basename "${spec}") with dnf builddep"
  dnf -y builddep "${spec}"
}

run_rpmbuild() {
  local spec="$1"
  mkdir -p "${OUT_DIR}"
  local build_log="${OUT_DIR}/build.log"

  export GOTOOLCHAIN=local GOTELEMETRY=off GOFLAGS=-mod=vendor CARGO_NET_OFFLINE=true
  log "Running rpmbuild -bb $(basename "${spec}") for ${TARGET_ARCH}; logging to ${build_log}"
  # Debuginfo subpackages are never published; skipping them keeps the build
  # fast (the deb builder's noautodbgsym equivalent).
  rpmbuild -bb --define 'debug_package %{nil}' "${spec}" 2>&1 | tee "${build_log}"
}

# collect_artifacts <spec>: copy every RPM whose Name is assigned to a published
# component into OUT_DIR; `skip` packages are dropped, unlisted ones abort.
collect_artifacts() {
  local spec="$1"
  declare -A component=()
  local pkg comp _
  while read -r pkg comp _; do
    [[ -z "${pkg}" || "${pkg}" == \#* ]] && continue
    [[ -n "${comp}" ]] || die "malformed line in ${COMPONENTS_FILE}: '${pkg}'"
    component["${pkg}"]="${comp}"
  done < "${COMPONENTS_FILE}"

  shopt -s nullglob
  local rpms=( "${RPM_TOP}"/RPMS/*/*.rpm )
  shopt -u nullglob
  [[ "${#rpms[@]}" -gt 0 ]] || die "rpmbuild produced no packages"

  local published=0 rpm name
  for rpm in "${rpms[@]}"; do
    name="$(rpm -qp --nosignature --qf '%{NAME}' "${rpm}")"
    case "${component[${name}]:-}" in
      "")
        die "package ${name} ($(basename "${rpm}")) is not listed in packaging/repo/components — assign it a component or mark it skip"
        ;;
      skip)
        log "Not publishing ${name} (marked skip in packaging/repo/components)"
        ;;
      *)
        cp -f "${rpm}" "${OUT_DIR}/"
        log "Collected $(basename "${rpm}") -> component ${component[${name}]}"
        published=$((published + 1))
        ;;
    esac
  done
  [[ "${published}" -gt 0 ]] || die "every built package is marked skip; nothing to publish"

  # Keep the rendered spec next to the packages for traceability.
  cp -f "${spec}" "${OUT_DIR}/"
  (
    cd "${OUT_DIR}"
    sha256sum *.rpm > SHA256SUMS
  )
}
