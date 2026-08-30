#!/usr/bin/env bash
# Integrity gate for an assembled RPM repository (run before deploying).
#
# Usage: scripts/verify-rpm-repo.sh <repo-root>
#
# For every al2023/<component>/<arch>/ under <repo-root> this asserts what dnf
# itself will check at `dnf makecache` / `dnf install` time:
#   1. repodata/repomd.xml.asc verifies against the key served at the
#      repository root (RPM-GPG-KEY-<ORIGIN>).
#   2. Every metadata file listed in repomd.xml exists with the listed size and
#      sha256 checksum.
#   3. Every package listed in primary.xml exists with the listed size and
#      sha256 checksum, and every .rpm in the directory is listed (no orphans).
#   4. Every .rpm carries a header signature made by that same key.
# A repository with no component directories is a failure too — an empty
# repository must not pass. Any mismatch exits 1 so an inconsistent repository
# never reaches GitHub Pages.
#
# Environment: ORIGIN (default: podman-package-rpm)
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <repo-root>" >&2; exit 2; }
REPO_ROOT=$(cd "$1" && pwd)
ORIGIN=${ORIGIN:-podman-package-rpm}
TARGET=al2023
KEY_FILE="${REPO_ROOT}/RPM-GPG-KEY-${ORIGIN}"

[[ -d ${REPO_ROOT}/${TARGET} ]] || { echo "ERROR: ${REPO_ROOT} has no ${TARGET}/ directory" >&2; exit 2; }
[[ -f ${KEY_FILE} ]] || { echo "ERROR: signing key ${KEY_FILE} not found" >&2; exit 2; }
for tool in gpg rpm python3 sha256sum; do
  command -v "${tool}" >/dev/null || { echo "ERROR: missing required tool: ${tool}" >&2; exit 2; }
done

KEYRING=$(mktemp)
trap 'rm -f "${KEYRING}"' EXIT
gpg --batch --yes --dearmor --output "${KEYRING}" "${KEY_FILE}"
FPR=$(gpg --batch --with-colons --import-options show-only --import "${KEY_FILE}" | awk -F: '$1=="fpr"{print $10; exit}')
KEYID=${FPR: -16}
KEYID=${KEYID,,}

verify_sig() { # <signature> <signed-file>
  if command -v gpgv >/dev/null; then
    gpgv --quiet --keyring "${KEYRING}" "$@" 2>&1
  else
    gpg --batch --quiet --no-default-keyring --keyring "${KEYRING}" --verify "$@" 2>&1
  fi
}

# list_repomd <repomd.xml>: "<href> <size> <sha256>" per data entry
list_repomd() {
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'r': 'http://linux.duke.edu/metadata/repo'}
for data in ET.parse(sys.argv[1]).getroot().findall('r:data', ns):
    href = data.find('r:location', ns).get('href')
    size = data.find('r:size', ns).text
    cks = data.find('r:checksum', ns)
    if cks.get('type') != 'sha256':
        sys.exit(f"repomd.xml: {href} uses checksum type {cks.get('type')}, expected sha256")
    print(href, size, cks.text)
PY
}

# list_primary <primary.xml.gz>: "<href> <size> <sha256>" per package
list_primary() {
  python3 - "$1" <<'PY'
import gzip, sys, xml.etree.ElementTree as ET
ns = {'c': 'http://linux.duke.edu/metadata/common'}
with gzip.open(sys.argv[1]) as f:
    root = ET.parse(f).getroot()
for pkg in root.findall('c:package', ns):
    href = pkg.find('c:location', ns).get('href')
    size = pkg.find('c:size', ns).get('package')
    cks = pkg.find('c:checksum', ns)
    if cks.get('type') != 'sha256':
        sys.exit(f"primary.xml: {href} uses checksum type {cks.get('type')}, expected sha256")
    print(href, size, cks.text)
PY
}

sha256() { sha256sum "$1" | awk '{print $1}'; }
fsize()  { wc -c < "$1" | tr -d '[:space:]'; }

checks=0 failures=0 repos=0
fail() { echo "  MISMATCH: $*" >&2; failures=$((failures + 1)); }

echo ">>> Verifying repository at ${REPO_ROOT} (key ${FPR})"
shopt -s nullglob
for dir in "${REPO_ROOT}/${TARGET}"/*/*/; do
  repos=$((repos + 1))
  rel=${dir#"${REPO_ROOT}"/}; rel=${rel%/}
  repomd="${dir}repodata/repomd.xml"
  echo ">>> ${rel}"
  [[ -f ${repomd} ]] || { fail "${rel}: repodata/repomd.xml missing"; continue; }

  # 1. metadata signature
  checks=$((checks + 1))
  if [[ -f ${repomd}.asc ]]; then
    out=$(verify_sig "${repomd}.asc" "${repomd}") || fail "${rel}: repomd.xml.asc signature invalid: ${out}"
  else
    fail "${rel}: repomd.xml.asc missing"
  fi

  # 2. repomd <-> metadata files
  primary=""
  while read -r href size hash; do
    [[ -n ${href} ]] || continue
    target="${dir}${href}"
    checks=$((checks + 1))
    [[ -f ${target} ]] || { fail "${rel}: repomd lists ${href} but it is missing"; continue; }
    [[ $(fsize "${target}") == "${size}" ]] || { fail "${rel}: ${href} size != repomd size"; continue; }
    [[ $(sha256 "${target}") == "${hash}" ]] || fail "${rel}: ${href} sha256 != repomd checksum"
    [[ ${href} == *primary.xml* ]] && primary=${target}
  done < <(list_repomd "${repomd}")
  checks=$((checks + 1))
  [[ -n ${primary} ]] || { fail "${rel}: repomd lists no primary metadata"; continue; }

  # 3. primary <-> packages, and no orphan packages
  declare -A listed=()
  while read -r href size hash; do
    [[ -n ${href} ]] || continue
    listed[${href}]=1
    pkg="${dir}${href}"
    checks=$((checks + 1))
    [[ -f ${pkg} ]] || { fail "${rel}: ${href} listed in primary but missing"; continue; }
    [[ $(fsize "${pkg}") == "${size}" ]] || { fail "${rel}: ${href} size != primary size"; continue; }
    [[ $(sha256 "${pkg}") == "${hash}" ]] || fail "${rel}: ${href} sha256 != primary checksum"
  done < <(list_primary "${primary}")
  for pkg in "${dir}"*.rpm; do
    checks=$((checks + 1))
    [[ -n ${listed[$(basename "${pkg}")]:-} ]] || fail "${rel}: $(basename "${pkg}") is not listed in primary.xml"
    # 4. package signature by our key
    checks=$((checks + 1))
    sig=$(rpm -qp --nosignature --qf '%{RSAHEADER:pgpsig}' "${pkg}" 2>/dev/null || true)
    [[ ${sig,,} == *"key id ${KEYID}"* ]] || fail "${rel}: $(basename "${pkg}") is not signed by ${FPR} (got: ${sig:-none})"
  done
  unset listed
done
shopt -u nullglob

checks=$((checks + 1))
[[ ${repos} -gt 0 ]] || fail "no component/architecture directories under ${TARGET}/ — an empty repository is not publishable"

if [[ ${failures} -gt 0 ]]; then
  echo ">>> FAIL: ${failures} mismatch(es) across ${checks} checks — refusing to publish" >&2
  exit 1
fi
echo ">>> OK: ${checks} checks passed"
