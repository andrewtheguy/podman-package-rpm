#!/usr/bin/env bash
# Assemble and sign the RPM (dnf) repository that is deployed to GitHub Pages.
#
# Usage: scripts/build-rpm-repo.sh <rpms-dir> <output-dir> <repo-url>
#
#   <rpms-dir>    Directory holding the .rpm files to publish (searched
#                 recursively) — normally every RPM from the most recent few
#                 main-* and extra-* component releases. Several versions of a
#                 package may be present; createrepo indexes all of them so dnf
#                 installs the newest while older ones remain downloadable and
#                 pinnable. An RPM that appears more than once with identical
#                 content is kept once; the same filename with different
#                 content is an error.
#   <output-dir>  Repository root to create. Must not exist or must be empty.
#   <repo-url>    Public base URL of the repository, e.g.
#                 https://andrewtheguy.github.io/podman-package-rpm (written
#                 into the generated .repo file and index.html).
#
# Environment:
#   PUBKEY_FILE   Armored public signing key committed to the repository
#                 (default: packaging/repo/pubkey.asc). The matching SECRET key
#                 must already be imported into the GnuPG keyring ($GNUPGHOME);
#                 the script refuses to sign with any other key.
#   COMPONENTS_FILE
#                 Package -> component table (default: packaging/repo/components).
#   ORIGIN        Repository id prefix and file basename
#                 (default: podman-package-rpm -> podman-package-rpm.repo,
#                 RPM-GPG-KEY-podman-package-rpm, repo ids
#                 podman-package-rpm-main / podman-package-rpm-extra).
#   SOURCE_URL    Link to the source repository shown on index.html
#   SIBLING_URL   Optional link to the sibling APT repository shown on index.html
#                 (default: derived from the git `origin` remote).
#   ARCHES        Architectures every component must provide (default:
#                 "x86_64 aarch64"). Only narrow this for a local, single-arch
#                 dry run; the published repository always carries both.
#
# Layout produced:
#   <output-dir>/
#     index.html  .nojekyll
#     RPM-GPG-KEY-<ORIGIN>                 armored public key (rpm --import / gpgkey=)
#     <ORIGIN>.repo                        drop-in for /etc/yum.repos.d/
#     al2023/<component>/<arch>/*.rpm      signed packages (noarch copied into every arch)
#     al2023/<component>/<arch>/repodata/  createrepo_c metadata + repomd.xml.asc
#
# Target: only Amazon Linux 2023 (dist tag .amzn2023). An RPM whose Release
# does not end in .amzn2023 is an error.
#
# Components (packaging/repo/components, keyed by package name; the build
# workflow releases one component per run, but routing never trusts the
# release — only the package name):
#   main   podman and the version-pinned companions its Requires name
#   extra  crun, conmon, passt, catatonit — required on stock AL2023 (core ships
#          none of them), optional when SPAL supplies them
# An RPM whose package name is not in the table, or is marked skip, is an error.
#
# What is signed: every RPM (gpgcheck=1) and each repomd.xml (repo_gpgcheck=1).
#
# Requires: rpm, rpmsign, createrepo_c, gpg, sha256sum, python3, findutils — e.g.
#           `apt-get install rpm createrepo-c gnupg` on Ubuntu, or
#           `dnf install --allowerasing rpm-sign createrepo_c gnupg2 findutils`
#           on Amazon Linux 2023 (the container image ships gnupg2-minimal and
#           no findutils).
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}
[[ $# -eq 3 ]] || usage

RPMS_DIR=$1
OUTPUT_DIR=$2
REPO_URL=${3%/}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PUBKEY_FILE=${PUBKEY_FILE:-${ROOT_DIR}/packaging/repo/pubkey.asc}
COMPONENTS_FILE=${COMPONENTS_FILE:-${ROOT_DIR}/packaging/repo/components}
ORIGIN=${ORIGIN:-podman-package-rpm}
TARGET=al2023
TARGET_DESC="Amazon Linux 2023"
DIST_TAG=.amzn2023
read -r -a ARCHES <<< "${ARCHES:-x86_64 aarch64}"
KEY_FILE="RPM-GPG-KEY-${ORIGIN}"

log() { echo ">>> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for a in "${ARCHES[@]}"; do
  case ${a} in x86_64|aarch64) ;; *) die "ARCHES may only contain x86_64 and aarch64: ${a}" ;; esac
done
for tool in rpm rpmsign createrepo_c gpg sha256sum python3 find xargs; do
  command -v "${tool}" >/dev/null \
    || die "missing required tool: ${tool} (apt-get install rpm createrepo-c gnupg / dnf install rpm-sign createrepo_c gnupg2 findutils)"
done

[[ -d ${RPMS_DIR} ]] || die "rpms directory not found: ${RPMS_DIR}"
[[ -f ${PUBKEY_FILE} ]] || die "public key not found: ${PUBKEY_FILE} — generate one with scripts/rpm-repo-keygen.sh"
[[ -f ${COMPONENTS_FILE} ]] || die "components file not found: ${COMPONENTS_FILE}"
if [[ -e ${OUTPUT_DIR} ]] && [[ -n $(ls -A "${OUTPUT_DIR}") ]]; then
  die "output directory exists and is not empty: ${OUTPUT_DIR}"
fi
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd)
RPMS_DIR=$(cd "${RPMS_DIR}" && pwd)

if [[ -z ${SOURCE_URL:-} ]]; then
  SOURCE_URL=""
  if origin=$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null) \
     && [[ ${origin} =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
    SOURCE_URL="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  fi
fi

# --------------------------------------------------------------------------
# Signing key: the committed public key decides which key we sign with.
# --------------------------------------------------------------------------
FPR=$(gpg --batch --with-colons --import-options show-only --import "${PUBKEY_FILE}" \
      | awk -F: '$1=="fpr"{print $10; exit}')
[[ -n ${FPR} ]] || die "could not read a key fingerprint from ${PUBKEY_FILE}"
if ! gpg --batch --list-secret-keys "${FPR}" >/dev/null 2>&1; then
  die "the secret key for ${FPR} (the key in ${PUBKEY_FILE#"${ROOT_DIR}"/}) is not in the GnuPG keyring.
  - In GitHub Actions: set the GPG_PRIVATE_KEY secret to the matching private key.
  - Locally: gpg --import keys/rpm-signing-key.private.asc
  - If you forked this repository: run scripts/rpm-repo-keygen.sh to create your own
    key and commit the new ${PUBKEY_FILE#"${ROOT_DIR}"/}."
fi
log "Signing key: ${FPR}"
# rpmsign runs gpg with --homedir %{_gpg_path}; point it at the keyring in use.
GPG_HOME=${GNUPGHOME:-${HOME}/.gnupg}

# --------------------------------------------------------------------------
# Components: package name -> component, in table order
# --------------------------------------------------------------------------
COMPONENTS=()
declare -A PKG_COMPONENT=()
while read -r pkg comp _; do
  [[ -z ${pkg} || ${pkg} == \#* ]] && continue
  [[ -n ${comp} && ${comp} =~ ^[a-z][a-z0-9-]*$ ]] \
    || die "malformed line in ${COMPONENTS_FILE}: '${pkg} ${comp}'"
  [[ -z ${PKG_COMPONENT[${pkg}]:-} ]] || die "package ${pkg} listed twice in ${COMPONENTS_FILE}"
  PKG_COMPONENT[${pkg}]=${comp}
  [[ ${comp} == skip ]] && continue
  found=0
  for c in "${COMPONENTS[@]}"; do [[ ${c} == "${comp}" ]] && found=1; done
  [[ ${found} -eq 1 ]] || COMPONENTS+=("${comp}")
done < "${COMPONENTS_FILE}"
[[ ${#COMPONENTS[@]} -gt 0 ]] || die "no components defined in ${COMPONENTS_FILE}"
log "Components: ${COMPONENTS[*]}"

# --------------------------------------------------------------------------
# Sort every RPM into <target>/<component>/<arch>/
# --------------------------------------------------------------------------
cd "${OUTPUT_DIR}"
log "Sorting .rpm files into ${TARGET}/<component>/<arch>"
rpm_count=0
while IFS= read -r -d '' rpm; do
  IFS=$'\t' read -r name arch release <<< "$(rpm -qp --nosignature --qf '%{NAME}\t%{ARCH}\t%{RELEASE}' "${rpm}")"
  [[ -n ${name} && -n ${arch} && -n ${release} ]] || die "cannot read package headers from ${rpm}"
  [[ ${arch} != src ]] || die "$(basename "${rpm}") is a source RPM; only binary packages are published"
  [[ ${release} == *"${DIST_TAG}" ]] \
    || die "cannot route $(basename "${rpm}") (release ${release}): expected the ${DIST_TAG} dist tag of ${TARGET_DESC}"
  comp=${PKG_COMPONENT[${name}]:-}
  [[ -n ${comp} ]] \
    || die "package ${name} ($(basename "${rpm}")) is not assigned to a component — add it to ${COMPONENTS_FILE#"${ROOT_DIR}"/}"
  [[ ${comp} != skip ]] \
    || die "package ${name} ($(basename "${rpm}")) is marked skip and must never be published"

  case ${arch} in
    noarch) targets=("${ARCHES[@]}") ;;
    x86_64|aarch64) targets=("${arch}") ;;
    *) die "unsupported architecture ${arch} in $(basename "${rpm}")" ;;
  esac
  for a in "${targets[@]}"; do
    dest="${TARGET}/${comp}/${a}/$(basename "${rpm}")"
    if [[ -e ${dest} ]]; then
      cmp -s "${rpm}" "${dest}" \
        || die "conflicting package: ${dest} already exists with different content (from ${rpm})"
      printf '  %-6s %-8s %s (identical copy, skipped)\n' "${comp}" "${a}" "$(basename "${dest}")"
      continue
    fi
    mkdir -p "$(dirname "${dest}")"
    cp "${rpm}" "${dest}"
    printf '  %-6s %-8s %s\n' "${comp}" "${a}" "$(basename "${dest}")"
  done
  rpm_count=$((rpm_count + 1))
done < <(find "${RPMS_DIR}" -type f -name '*.rpm' -print0 | sort -z)
[[ ${rpm_count} -gt 0 ]] || die "no .rpm files found under ${RPMS_DIR}"

for c in "${COMPONENTS[@]}"; do
  for a in "${ARCHES[@]}"; do
    [[ -d ${TARGET}/${c}/${a} ]] || die "component ${c} received no ${a} packages — every component must be non-empty for every architecture"
  done
done

# --------------------------------------------------------------------------
# Sign every RPM, then generate and sign the metadata per component/arch
# --------------------------------------------------------------------------
log "Signing packages"
find "${TARGET}" -type f -name '*.rpm' -print0 | sort -z | xargs -0 \
  rpmsign --define "_gpg_name ${FPR}" --define "_gpg_path ${GPG_HOME}" \
          --define "_gpg_digest_algo sha256" --addsign >/dev/null

for c in "${COMPONENTS[@]}"; do
  for a in "${ARCHES[@]}"; do
    dir="${TARGET}/${c}/${a}"
    log "${dir}: createrepo_c ($(find "${dir}" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ') packages)"
    createrepo_c --quiet --checksum sha256 --general-compress-type gz "${dir}"
    gpg --batch --yes --local-user "${FPR}" --digest-algo SHA512 \
        --armor --detach-sign --output "${dir}/repodata/repomd.xml.asc" "${dir}/repodata/repomd.xml"
  done
done

# --------------------------------------------------------------------------
# Key, .repo file, index.html
# --------------------------------------------------------------------------
cp "${PUBKEY_FILE}" "${KEY_FILE}"
touch .nojekyll

{
  for c in "${COMPONENTS[@]}"; do
    cat <<REPO
[${ORIGIN}-${c}]
name=${ORIGIN} ${c} - Podman for ${TARGET_DESC}
baseurl=${REPO_URL}/${TARGET}/${c}/\$basearch
enabled=1
# dnf lets repository priority beat package version: core AL2023 is priority 10
# and SPAL 20, so this repository must rank above both for the packages it
# ships (podman, netavark, aardvark-dns, containers-common, ...) to be chosen.
priority=5
gpgcheck=1
repo_gpgcheck=1
gpgkey=${REPO_URL}/${KEY_FILE}
skip_if_unavailable=False

REPO
  done
} > "${ORIGIN}.repo"

log "Writing index.html"
{
  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${ORIGIN} RPM repository</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;max-width:64em;margin:2em auto;padding:0 1em;line-height:1.5;color:#222}
  pre{background:#f4f4f4;padding:1em;overflow-x:auto;border-radius:4px}
  code{font-size:.95em}
  table{border-collapse:collapse;margin:1em 0}
  td,th{border:1px solid #ccc;padding:.25em .7em;text-align:left;font-family:ui-monospace,monospace;font-size:.9em}
  th{background:#eee}
  .warn{border-left:4px solid #c60;background:#fff6ee;padding:.8em 1em}
</style>
</head>
<body>
<h1>${ORIGIN} RPM repository</h1>
<div class="warn">
<p><strong>This repository exists only for its maintainer's own convenience</strong> so the
builds can be installed with <code>dnf</code> on Amazon Linux 2023. It is not a supported
distribution channel: packages may change, break or disappear without notice, and the signing
key belongs to the maintainer. If you want to use these packages yourself, fork the project,
generate your own signing key and publish your own repository — the source repository's README
explains how.</p>
</div>
HTML
  [[ -n ${SOURCE_URL} ]] && echo "<p>Source and build workflows: <a href=\"${SOURCE_URL}\">${SOURCE_URL}</a></p>"
  [[ -n ${SIBLING_URL:-} ]] && echo "<p>APT sibling for Ubuntu/Debian: <a href=\"${SIBLING_URL}\">${SIBLING_URL}</a></p>"
  cat <<HTML
<h2>Usage (${TARGET_DESC}, x86_64 and aarch64)</h2>
<pre>sudo curl -fsSL -o /etc/yum.repos.d/${ORIGIN}.repo ${REPO_URL}/${ORIGIN}.repo
sudo rpm --import ${REPO_URL}/${KEY_FILE}

sudo dnf install podman            # pulls in netavark, aardvark-dns, containers-common,
                                   # crun, conmon, passt and catatonit from this repository

# or everything the repository publishes:
sudo dnf install podman podman-remote podman-docker podmansh \\
  netavark aardvark-dns containers-common containers-common-extra \\
  crun conmon passt catatonit</pre>
<h2>Components</h2>
<ul>
<li><code>main</code> — podman, podman-remote, podman-docker, podmansh and the version-pinned
companions podman's <code>Requires</code> name: netavark, aardvark-dns, containers-common and
containers-common-extra.</li>
<li><code>extra</code> — crun, conmon, passt (with passt-selinux) and catatonit. Core Amazon Linux
2023 ships none of these, so a stock host needs this component too; with the SPAL repository
enabled its EPEL9 rebuilds also satisfy podman's dependencies, and this component then just
provides the newer upstream builds.</li>
</ul>
<p>Signing key: <a href="${KEY_FILE}">${KEY_FILE}</a> · fingerprint <code>${FPR}</code>.
Every RPM is signed (<code>gpgcheck=1</code>) and so is each repository's metadata
(<code>repo_gpgcheck=1</code>).</p>
<p>The repository carries the most recent few releases of every package; dnf installs the
newest, and older versions stay downloadable (and pinnable with
<code>dnf install podman-&lt;version&gt;</code>) until they rotate out.</p>
<h2>Packages</h2>
HTML
  for c in "${COMPONENTS[@]}"; do
    echo "<h3><code>${c}</code></h3>"
    echo "<table><tr><th>Package</th><th>Version</th><th>Architecture</th></tr>"
    for a in "${ARCHES[@]}"; do
      find "${TARGET}/${c}/${a}" -maxdepth 1 -name '*.rpm' -print0 | sort -z \
        | xargs -0 rpm -qp --nosignature --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | sed 's/\t(none):/\t/'
    done | sort -u | sort -t "$(printf '\t')" -k1,1 -k2,2Vr -k3,3 \
         | awk -F'\t' '{printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1, $2, $3}'
    echo "</table>"
  done
  echo "<p>Generated $(date -u +'%Y-%m-%d %H:%M UTC').</p>"
  echo "</body></html>"
} > index.html

log "Repository assembled at ${OUTPUT_DIR}"
"${ROOT_DIR}/scripts/verify-rpm-repo.sh" "${OUTPUT_DIR}"
