#!/usr/bin/env bash
# Install Podman from an assembled (not yet deployed) RPM repository inside a
# throwaway amazonlinux:2023 container, to prove the published metadata is
# usable and the component split holds.
#
# Usage: scripts/smoke-rpm-repo.sh <repo-root>
#
#   <repo-root>  Output of scripts/build-rpm-repo.sh (contains al2023/, the
#                .repo file and the RPM-GPG-KEY).
#
# The image mounts the repo read-only, adds it as file:// repositories with
# gpgcheck, repo_gpgcheck and the served .repo file's priority=5 (dnf ranks
# repository priority above package version; core AL2023 is 10, SPAL 20) and
# runs two installs:
#   1. main + extra — installs $PACKAGES and asserts that every member of
#      $ALL_PACKAGES was installed from this repository, then runs
#      `podman --version`. This is what a stock Amazon Linux 2023 host does.
#   2. main only + SPAL — enables Amazon's Supplementary Packages repository
#      (EPEL9 rebuilds), installs $MAIN_PACKAGES and asserts that podman and
#      its version-pinned companions came from this repository while crun,
#      conmon, passt and catatonit resolved from a distro repository: SPAL for
#      crun/conmon/catatonit, and core AL2023 for passt, which core has shipped
#      since mid-2026 and which wins on priority (core 10 beats SPAL 20). This
#      is the contract of the split: `main` alone is a complete Podman once a
#      distro-level source for the extra packages exists.
# Runs on the host architecture only.
#
# Environment:
#   PACKAGES      (default: podman passt crun conmon catatonit — netavark,
#                  aardvark-dns and containers-common are pulled in through
#                  podman's Requires)
#   ALL_PACKAGES  (default: podman netavark aardvark-dns containers-common
#                  containers-common-extra crun conmon passt catatonit)
#   MAIN_PACKAGES (default: podman) packages for the main-only install
#   ORIGIN        (default: podman-package-rpm)
#   IMAGE         (default: amazonlinux:2023)
#   DOCKER        container CLI (default: docker; podman works too)
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <repo-root>" >&2; exit 2; }
REPO_ROOT=$(cd "$1" && pwd)

ORIGIN=${ORIGIN:-podman-package-rpm}
IMAGE=${IMAGE:-amazonlinux:2023}
PACKAGES=${PACKAGES:-podman passt crun conmon catatonit}
ALL_PACKAGES=${ALL_PACKAGES:-podman netavark aardvark-dns containers-common containers-common-extra crun conmon passt catatonit}
MAIN_PACKAGES=${MAIN_PACKAGES:-podman}
DOCKER=${DOCKER:-docker}

[[ -d ${REPO_ROOT}/al2023 ]] || { echo "ERROR: ${REPO_ROOT}/al2023 missing" >&2; exit 2; }
[[ -f ${REPO_ROOT}/RPM-GPG-KEY-${ORIGIN} ]] || { echo "ERROR: ${REPO_ROOT}/RPM-GPG-KEY-${ORIGIN} missing" >&2; exit 2; }

# run_install <components> <packages> <from-repo-packages> <distro-packages>
#   <components>            space-separated components to enable from the repo
#   <packages>              what to dnf install
#   <from-repo-packages>    must have been installed from this repository
#   <distro-packages>       must have been installed from a distro repository —
#                           core amazonlinux or amazonlinux-spal ("" = do not
#                           enable SPAL and assert nothing)
run_install() {
  local components=$1 packages=$2 from_repo=$3 from_distro=$4
  echo "========================================"
  echo ">>> Smoke test: ${IMAGE} — components: ${components}${from_distro:+ + SPAL} — dnf install ${packages}"
  echo "========================================"
  "${DOCKER}" run --rm --pull=always \
       -v "${REPO_ROOT}:/repo:ro" \
       -e ORIGIN="${ORIGIN}" -e COMPONENTS="${components}" -e PACKAGES="${packages}" \
       -e FROM_REPO="${from_repo}" -e FROM_DISTRO="${from_distro}" \
       "${IMAGE}" bash -ec '
         rpm --import "/repo/RPM-GPG-KEY-${ORIGIN}"
         for c in ${COMPONENTS}; do
           printf "[%s-%s]\nname=%s %s (smoke)\nbaseurl=file:///repo/al2023/%s/\$basearch\nenabled=1\npriority=5\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file:///repo/RPM-GPG-KEY-%s\n\n" \
             "${ORIGIN}" "${c}" "${ORIGIN}" "${c}" "${c}" "${ORIGIN}"
         done > "/etc/yum.repos.d/${ORIGIN}.repo"
         if [[ -n ${FROM_DISTRO} ]]; then
           dnf -y -q install spal-release
         fi
         dnf -q makecache
         # shellcheck disable=SC2086
         dnf -y install ${PACKAGES}
         echo "--- installed versions ---"
         # shellcheck disable=SC2086
         rpm -q ${FROM_REPO} ${FROM_DISTRO}
         from_repo_of() { dnf -q repoquery --installed --qf "%{from_repo}" "$1"; }
         for pkg in ${FROM_REPO}; do
           repo=$(from_repo_of "${pkg}")
           case ${repo} in
             ${ORIGIN}-*) echo "${pkg}: from ${repo}" ;;
             *) echo "ERROR: ${pkg} was installed from ${repo:-<unknown>}, not from this repository" >&2; exit 1 ;;
           esac
         done
         for pkg in ${FROM_DISTRO}; do
           repo=$(from_repo_of "${pkg}")
           case ${repo} in
             amazonlinux|amazonlinux-spal) echo "${pkg}: from ${repo}" ;;
             *) echo "ERROR: ${pkg} was installed from ${repo:-<unknown>}, expected a distro repository (amazonlinux or amazonlinux-spal)" >&2; exit 1 ;;
           esac
         done
         podman --version
         podman info --format "{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}}" 2>/dev/null || true
       '
}

status=0
if run_install "main extra" "${PACKAGES}" "${ALL_PACKAGES}" ""; then
  echo ">>> main + extra: OK"
else
  echo ">>> main + extra: FAILED" >&2
  status=1
fi
if run_install "main" "${MAIN_PACKAGES}" "podman netavark aardvark-dns containers-common containers-common-extra" "crun conmon passt catatonit"; then
  echo ">>> main only + SPAL: OK"
else
  echo ">>> main only + SPAL: FAILED" >&2
  status=1
fi
exit "${status}"
