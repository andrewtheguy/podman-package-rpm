# Podman RPM Package Builders for Amazon Linux 2023

This repository builds pinned Podman and supporting-component releases as
installable RPM packages for **Amazon Linux 2023** on `x86_64` and `aarch64`.
It is the RPM sibling of [podman-package](https://github.com/andrewtheguy/podman-package)
(the `.deb` builder for Ubuntu/Debian, published at
<https://andrewtheguy.github.io/podman-package/>) and follows the same template: Docker
builds, checksum-pinned upstream sources, the target distro's own packaging,
repo-managed patch series, and a signed package repository on GitHub Pages fed
by GitHub releases. Distro build dependencies are resolved when a build runs, so
the output is not promised to be byte-for-byte reproducible.

The project is dnf-first: the deliverable is the signed RPM repository with a
`main` component (Podman and its version-pinned companion packages) and an
`extra` component (crun, conmon, passt, catatonit). GitHub releases exist only
as the repository's storage layer, one release per component build.

## Install via dnf (maintainer's personal repository)

> [!WARNING]
> **This RPM repository is only for my own convenience.** It exists
> so *I* can `dnf install` these builds on my own Amazon Linux 2023 machines. It
> is not a supported distribution channel for anyone else: packages may change,
> break, or disappear without notice, the signing key is mine, and I make no
> promises about uptime or security review. **If you want to use these packages,
> fork this project and set up your own repository with your own signing key** —
> see [Hosting Your Own RPM Repository](#hosting-your-own-rpm-repository). Do not
> point production systems at my repository.

The repository is served from GitHub Pages at
<https://andrewtheguy.github.io/podman-package-rpm/> and is rebuilt by the
**Publish RPM Repository** workflow from up to three of the most recently
published `main` releases and up to three of the most recently published
`extra` releases. If fewer exist, it uses every available matching release.
dnf installs the newest indexed version; retained older versions stay
downloadable — so slightly stale metadata still resolves — and pinnable with
`sudo dnf install podman-<version>` until they rotate out. Use
`dnf --showduplicates list podman` to list the versions currently indexed.

```bash
# 1. Repository definition (both components) and signing key
sudo curl -fsSL -o /etc/yum.repos.d/podman-package-rpm.repo \
  https://andrewtheguy.github.io/podman-package-rpm/podman-package-rpm.repo
sudo rpm --import https://andrewtheguy.github.io/podman-package-rpm/RPM-GPG-KEY-podman-package-rpm

# 2. Install
sudo dnf install podman
```

`podman` pulls in everything else through its `Requires`: the version-pinned
`netavark`, `aardvark-dns` and `containers-common-extra` from `main`, and — via
`containers-common-extra`'s `oci-runtime` / `passt` / `container-network-stack`
and podman's own `conmon` / `catatonit` dependencies — `crun`, `conmon`, `passt`
and `catatonit` from `extra`.

The repository has two components, split by what Podman actually needs
(`packaging/repo/components`); each is built and released by its own run of the
build workflow:

| Component | Packages | Purpose |
|-----------|----------|---------|
| `main` | podman, podman-remote, podman-docker, podmansh, netavark, aardvark-dns, containers-common, containers-common-extra | Podman and the repo-built companions named by its version-pinned `Requires`. Core Amazon Linux 2023 ships netavark/aardvark-dns 1.17 and containers-common 0.67, which are too old for Podman 6.1. |
| `extra` | crun, conmon, passt, passt-selinux, catatonit | The OCI runtime, container monitor, user-mode networking and init that podman requires. **Core Amazon Linux 2023 ships none of them**, so on a stock host this component is required too. With the [SPAL repository](https://docs.aws.amazon.com/linux/al2023/ug/spal.html) enabled (`dnf install spal-release`; EPEL9 rebuilds of crun 1.26, conmon 2.1.13, passt 2025-09, catatonit 0.2.1) the component becomes optional: SPAL's versions satisfy podman's dependencies and `extra` just provides the newer upstream builds. |

Both components are enabled by the served `.repo` file with `priority=5`: dnf
ranks repository priority above package version, and core Amazon Linux 2023 is
`priority=10` and SPAL `priority=20`, so without it SPAL's podman 5.6.1 would be
chosen over the 6.1.2 here. Comment out `podman-package-rpm-extra` if you prefer
SPAL's crun/conmon/passt/catatonit.

To install every package the repository publishes (the thirteen below are the
full set):

```bash
sudo dnf install \
  podman podman-remote podman-docker podmansh \
  netavark aardvark-dns containers-common containers-common-extra \
  crun conmon passt passt-selinux catatonit
```

`podman-remote` is the client-only binary, `podman-docker` provides a `docker`
command that wraps Podman (it `Conflicts` with `docker`/`docker-ce`/`moby-engine`,
so leave it out on hosts running Docker), and `podmansh` is the confined login
shell. To upgrade after a new publish, `sudo dnf upgrade` is enough — every
package is versioned above its core-AL2023 or SPAL counterpart (same Epoch,
higher Version).

Things to know on Amazon Linux 2023:

- **buildah/skopeo from core AL2023.** containers-common 0.68 declares
  `Conflicts: buildah < 2:1.44` (upstream's guard against the pre-0.68 config
  layout). Core AL2023 currently ships buildah 2:1.43.1, so a host with buildah
  installed cannot install this containers-common until AL updates buildah;
  `dnf remove buildah` first if you need Podman now. skopeo 2:1.22.2 is fine.
- **Short image names.** Upstream's spec installs its Fedora vendor search list
  (`registry.fedoraproject.org`, `registry.access.redhat.com`, `docker.io`) with
  `short-name-mode = "enforcing"`, so `podman pull nginx` prompts for the registry
  in a terminal and errors without one (the pinned `shortnames.conf` aliases
  cover common distro images, including `amazonlinux`). Use fully qualified
  names (`docker.io/library/nginx`) or drop a file in
  `/etc/containers/registries.conf.d/` with your own
  `unqualified-search-registries`.
- **SELinux.** AL2023 runs SELinux permissive by default with
  `selinux-policy-targeted` installed, so `passt` pulls in `passt-selinux`
  (the upstream policy modules for passt/pasta/pesto) automatically.
- **Kernel.** Nothing here depends on the kernel version; the packages run on
  AL2023 with kernel 6.1, 6.12 or 6.18 (the default since August 2026).
  netavark 2 uses nftables, which every AL2023 kernel provides.

## Downloads

The GitHub releases mirror the repository components, one release per
component build:

- [`main` component releases](https://github.com/andrewtheguy/podman-package-rpm/releases?q=%22main+component%22) (`main-<YYYYMMDD>-<N>`) — podman, podman-remote, podman-docker, podmansh, netavark, aardvark-dns, containers-common and containers-common-extra.
- [`extra` component releases](https://github.com/andrewtheguy/podman-package-rpm/releases?q=%22extra+component%22) (`extra-<YYYYMMDD>-<N>`) — crun, conmon, passt, passt-selinux and catatonit.
- [All releases](https://github.com/andrewtheguy/podman-package-rpm/releases) — the combined chronological GitHub release history.

For a complete Podman 6.1 installation without the repository, download the
RPMs for your architecture from the latest `main` **and** `extra` releases and
`sudo dnf install ./*.rpm` them together (the noarch containers-common RPMs from
`main` are needed on both architectures).

## How the Packaging Works

Debian keeps packaging separate from upstream, so the `.deb` builder copies
`debian/` from `apt-get source`. The RPM world keeps packaging **in the upstream
tree**: podman, netavark, aardvark-dns, crun, conmon and containers-common each
ship `rpm/<name>.spec`, passt ships `contrib/fedora/passt.spec`, and the Fedora,
EPEL, SPAL and Amazon Linux specs are copies of those files with distro
conditionals (SPAL's podman.spec even says so in its header). The checksum-pinned
upstream tarball therefore already contains the version-matched packaging, and
the in-container product modules take it from there, applying only the few
Amazon Linux 2023 edits that SPAL and Amazon's own specs make:

| Product | Packaging | AL2023 edits (each asserted; a changed upstream spec fails the build) |
|---------|-----------|------------------------------------------------------------------------|
| podman | `rpm/podman.spec` | fill `Version: 0`; drop the Fedora-only `build_with_btrfs` (no btrfs-progs-devel on AL2023); pin `Requires: netavark >= 2:<NETAVARK_TAG>` and `aardvark-dns >= 2:<AARDVARK_TAG>` (core AL2023's 1.17 would otherwise satisfy `container-network-stack`); assert its `containers-common-extra >= 5:<version>` equals `CONTAINERS_COMMON_VERSION` |
| netavark, aardvark-dns | `rpm/<name>.spec` + release vendor tarball | fill `Version: 0`; take the non-Fedora branch of the cargo conditionals (AL2023's rust-packaging 21 lacks `%cargo_prep -v`, `%cargo_license_summary`, `%cargo_vendor_manifest`); `BuildRequires: rust-toolset` instead of `rust-packaging` + `rust-srpm-macros` (obsoleted on AL2023); replace `%cargo_prep -V 1` with an explicit vendored-sources `.cargo/config.toml` and `%{__cargo}` with plain `cargo` — AL2023's macros point crates.io at a local registry, delete `Cargo.lock` and reference a linker script only `%set_build_flags` writes (the same workarounds Amazon's netavark/aardvark-dns specs carry) |
| containers-common | `common/rpm/containers-common.spec` (noarch) | fill `Version: 0`; pin `shortnames.conf` to `SHORTNAMES_COMMIT` instead of the `main` branch and the `Source2` Red Hat release key by hash |
| crun | `rpm/crun.spec` (release dist tarball) | fill `Version: 0`; `.tar.zst` → the pinned `.tar.gz`; disable the Fedora-only krun/wasmedge block (no libkrun-devel/wasmedge-devel on AL2023, as SPAL does); relax `criu-devel >= 3.17.1-2` to `>= 3.17.1` (AL2023 ships 3.17.1-1, as SPAL does) |
| conmon | `rpm/conmon.spec` | assert the in-tree `Version:` equals `CONMON_VERSION` |
| passt | `contrib/fedora/passt.spec` (rpkg template) | render `git_hash` = `PASST_TAG`, `Version` = `0^<YYYYMMDD>.g<hash>` (Fedora's snapshot form), `%setup` → `%autosetup`; `%make_build` → serial `make` (AL2023's gcc 11 lto-wrapper fails against make's jobserver on the x86_64 passt + passt.avx2 build) |
| catatonit | SPAL source RPM (`dnf download --source catatonit`) | no in-tree spec upstream; SPAL's spec is used as-is, the direct `apt-get source` analogue |

Why the Fedora-only branches matter: Amazon Linux 2023 is Fedora-derived and
its rpm macros define `%fedora` (34) alongside `%amzn` (2023), so an unguarded
`%if %{defined fedora}` in an upstream spec is true there. Amazon's own specs
add `!0%{?amzn}` guards; this repository makes the equivalent edits.

Every product then gets the same treatment: `Release: <YYYYMMDD>.<N>%{?dist}`
(→ `.amzn2023`), a fresh `%changelog` entry, the repo-managed patch series as
`PatchNNNN:` lines applied by `%autosetup`, `dnf builddep`, and
`rpmbuild -bb` (debuginfo subpackages are not generated). Subpackages that
upstream builds but this repository never publishes (`podman-tests`,
`podman-machine`, `netavark-tests`, `aardvark-dns-tests`) are listed as `skip`
in `packaging/repo/components` and dropped at collect time; an RPM whose name is
not in that table aborts the build.

Toolchains are the distro's: AL2023's `golang` (1.25.12 at the time of writing)
and `rust`/`cargo` (1.97) drive `%gobuild` and `cargo`, and the build asserts
they satisfy the pinned upstream's `go.mod` directive and `RUST_MIN_VERSION`.

Dependency chain the podman RPM produces (all satisfied within this repository;
`extra` members also by SPAL):

```
podman
├── containers-common-extra >= 5:0.68.0   (main)
│   ├── containers-common = 5:0.68.0      (main)
│   ├── container-network-stack           → netavark      (main; also core AL2023 1.17)
│   ├── oci-runtime                       → crun          (extra; also SPAL crun — core runc does not provide it)
│   └── passt                             → passt         (extra; also SPAL)
├── netavark >= 2:2.0.0                   (main)  ── aardvark-dns >= 2:2.0  (main)
├── aardvark-dns >= 2:2.0.0               (main)
├── conmon >= 2:2.1.7-2                   → conmon        (extra; also SPAL)
└── catatonit                             → catatonit     (extra; also SPAL)
```

## Supported Platform

| Platform | Base image | Dist tag | Architectures |
|----------|------------|----------|---------------|
| Amazon Linux 2023 | `amazonlinux:2023` (Docker Hub official image; `public.ecr.aws/amazonlinux/amazonlinux:2023` is the same image) | `.amzn2023` | `x86_64`, `aarch64` |

The `amazonlinux:2023` tag tracks the current AL2023 quarterly release
(2023.12 at the time of writing) and its dnf is locked to that release's
versioned repositories, so every build resolves against a consistent package set.

### Why only Amazon Linux 2023

This repository exists to fill a gap that is specific to AL2023; it deliberately
has no RHEL/EPEL target.

- **Core AL2023 ships no podman at all** — no podman, crun, conmon, passt or
  catatonit; only netavark, aardvark-dns and containers-common (Fedora imports
  rebuilt by Amazon, currently 1.17.x / 0.67).
- **SPAL's podman is Amazon's own addition, not an EPEL rebuild.** EPEL 9 does
  not carry podman (RHEL ships it itself), so Amazon builds it from podman's
  upstream in-tree `rpm/podman.spec` and GitHub tarball in their own dist-git.
  It sits at 5.6.1 (January 2026) with no stated update cadence, and SPAL is
  explicitly unsupported with no AWS CVE tracking.
- **RHEL needs no such repository.** Podman is a first-party AppStream package
  (`container-tools`) that Red Hat rebases at every minor release — RHEL 10.2
  ships 5.8.2, CentOS Stream 10 already carries 6.1.0, so 10.3 will bring the
  same 6.1.x stack this repository builds, with Red Hat's CVE backports. A RHEL
  build here would only duplicate the distro a few months early. RHEL pins the
  podman version per minor release, so it trails upstream by up to ~6 months;
  wanting newer than that is a different goal from filling a gap, and out of
  scope.

The `.deb` sibling [podman-package](https://github.com/andrewtheguy/podman-package)
covers the equivalent gap on Ubuntu/Debian, whose distro podman is old.

## GitHub Actions (Default)

One build workflow, **Build and Release RPM Packages**
(`.github/workflows/build-and-release.yml`), is triggered manually from the
Actions tab (`workflow_dispatch`) with a `component` input:

- `main` — builds podman (with podman-remote, podman-docker, podmansh), netavark and aardvark-dns on native `x86_64` and `aarch64` runners in parallel, plus the noarch containers-common once. Run it when Podman or a required companion is bumped.
- `extra` — builds crun, conmon, passt and catatonit for both architectures. Run it when one of those is bumped.

Before uploading, the workflow checks every built RPM against
`packaging/repo/components` and fails if a package does not belong to the
component being released.

A second workflow, **Publish RPM Repository** (`.github/workflows/publish-rpm-repo.yml`),
runs automatically after a successful build (and can be dispatched manually).
It downloads the `.rpm` assets of up to the `keep_releases` most recent `main`
and `extra` releases (default 3 of each; a dispatch can instead pin exactly one
`main_release` / `extra_release` tag), signs every RPM and assembles the
repository under `al2023/<component>/<arch>/` with signed `repomd.xml`,
smoke-installs from it inside an `amazonlinux:2023` container (once with
`main extra`, once with `main` plus SPAL to prove the split holds), and deploys
the result to GitHub Pages. Each publish replaces the whole site, so a version
is gone once it falls outside the retention window. Its release assets remain
downloadable from GitHub unless the release or assets are manually deleted. See
[Hosting Your Own RPM Repository](#hosting-your-own-rpm-repository) for the
one-time setup it needs.

Each run builds its component's products, then publishes a **single unified
pre-release** containing every RPM from that run plus a combined `SHA256SUMS`,
tagged `<component>-<YYYYMMDD>-<N>`:

- `main-<YYYYMMDD>-<N>`
- `extra-<YYYYMMDD>-<N>`

`<N>` starts at `1` for the first build of that UTC date and increments for same-day reruns (`2`, `3`, ...).

## Hosting Your Own RPM Repository

The published repository is tied to my GitHub Pages site and my signing key, so
to use these packages you run the same pipeline in your own fork. One-time setup:

1. **Fork** this repository and run the build workflow once with
   `component=main` and once with `component=extra` so a `main-*` and an
   `extra-*` release exist.
2. **Generate your own signing key** (never reuse mine):

   ```bash
   ./scripts/rpm-repo-keygen.sh
   ```

   This writes the private key to `keys/rpm-signing-key.private.asc` — the
   `keys/` directory is gitignored; keep it secret and back it up — and the
   public key to `packaging/repo/pubkey.asc`, which you **commit**. The publish
   script refuses to sign with any key other than the one in
   `packaging/repo/pubkey.asc`, so a fork can never accidentally publish with
   the upstream key.
3. **Store the private key** as the `GPG_PRIVATE_KEY` repository secret. From
   inside your fork's checkout, with the [GitHub CLI](https://cli.github.com/)
   logged in (`gh auth status`):

   ```bash
   gh secret set GPG_PRIVATE_KEY < keys/rpm-signing-key.private.asc
   # or, from anywhere:
   gh secret set GPG_PRIVATE_KEY --repo <owner>/<repo> < keys/rpm-signing-key.private.asc
   ```

   `gh secret set` encrypts the value locally and uploads only the ciphertext;
   GitHub never returns a secret's value, so keep `keys/` as your own copy. The
   publish workflow pipes it into `gpg --import` inside a throwaway `GNUPGHOME`
   and the Actions log masks it. Without the CLI: *Settings → Secrets and
   variables → Actions → New repository secret*, name `GPG_PRIVATE_KEY`, paste
   the full contents of `keys/rpm-signing-key.private.asc`.

4. **Enable GitHub Pages** in *Settings → Pages* with source **GitHub Actions**.
5. **Run the Publish RPM Repository workflow** from the Actions tab (leave the
   release inputs empty to publish the latest releases). From then on it also
   runs automatically after each successful build workflow.

Your repository is served at `https://<owner>.github.io/<repo>/` with the same
`main` / `extra` components; the generated index page shows the exact install
snippet and key fingerprint for your fork. If you add a product, add its binary
package names to `packaging/repo/components` or the build fails. To re-run the
assembly locally (any host with `rpm`, `rpmsign`, `createrepo_c`, `gpg` and
`python3` — `apt-get install rpm createrepo-c gnupg` on Ubuntu,
`dnf install --allowerasing rpm-sign createrepo_c gnupg2 findutils` on Amazon Linux/Fedora — `--allowerasing` swaps out AL2023's `gnupg2-minimal`), download as
many releases as you want retained — every `.rpm` under the input directory is
indexed:

```bash
gpg --import keys/rpm-signing-key.private.asc
for tag in <main-tag-1> <main-tag-2> <main-tag-3>; do
  gh release download "$tag" --pattern '*.rpm' --dir "rpms/main/$tag"
done
for tag in <extra-tag-1> <extra-tag-2> <extra-tag-3>; do
  gh release download "$tag" --pattern '*.rpm' --dir "rpms/extra/$tag"
done
./scripts/build-rpm-repo.sh rpms repo-output https://<owner>.github.io/<repo>
./scripts/smoke-rpm-repo.sh repo-output      # optional: dnf install in amazonlinux:2023 containers
```

Retention is a size trade-off; keep the site below the
[GitHub Pages 1 GB published-site limit](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)
and raise `keep_releases` with care.

### Signing Key

The repository is trusted through one OpenPGP key pair created by
`scripts/rpm-repo-keygen.sh`:

| Half | Location | Role |
|------|----------|------|
| Private | `keys/rpm-signing-key.private.asc` (gitignored) and the `GPG_PRIVATE_KEY` repository secret | Signs every RPM and each `repomd.xml` during publish |
| Public | `packaging/repo/pubkey.asc` (committed), served as `<repo-url>/RPM-GPG-KEY-podman-package-rpm` | Imported by clients (`rpm --import`) and referenced by `gpgkey=` in the `.repo` file |

**What is signed.** Every `.rpm` carries a header signature (`gpgcheck=1`: rpm
verifies it before installing), and each component/architecture's
`repodata/repomd.xml` has a detached `repomd.xml.asc` (`repo_gpgcheck=1`: dnf
verifies it at `makecache`). `repomd.xml` lists the sha256 of every metadata
file and `primary.xml` lists the sha256 of every package, so signed metadata →
index → package is one hash chain, and the package signature covers the
package independently of it. The HTML landing page is not covered.

**Key properties.** RSA-4096, sign-only, **no passphrase** (the workflow must use
it non-interactively) and **no expiry** (an expiring key would break every
client's `dnf makecache` on the expiry date). Protection therefore rests
entirely on keeping the private half out of git and out of logs: `keys/` is
gitignored, the keygen script refuses to run if it is not, and in CI the key is
imported into a throwaway `GNUPGHOME` under `$RUNNER_TEMP`.

**Which key gets used.** `scripts/build-rpm-repo.sh` reads the fingerprint from
the committed `packaging/repo/pubkey.asc` and signs with exactly that key; if the
matching secret key is not in the keyring it aborts.

**Rotation (lost, leaked, or scheduled).**

```bash
./scripts/rpm-repo-keygen.sh --force                          # new pair; overwrites keys/ and pubkey.asc
gh secret set GPG_PRIVATE_KEY < keys/rpm-signing-key.private.asc
git commit -am "chore: rotate RPM signing key" && git push     # publish the new public key
gh workflow run "Publish RPM Repository"                       # re-sign the repository
```

Every client must then import the new key
(`sudo rpm --import <repo-url>/RPM-GPG-KEY-podman-package-rpm`); until they do,
`dnf` rejects the repository's metadata and packages. If the key leaked, rotate
immediately.

Repository layout notes:

- `al2023/<component>/<arch>/` holds the packages and their `repodata/`; the
  noarch containers-common RPMs are copied into both architecture directories.
  Packages are routed by the `.amzn2023` dist tag in their Release and by
  `packaging/repo/components`; anything else is an error.
- Every version found is indexed; the same filename with different content
  aborts the publish.
- `scripts/verify-rpm-repo.sh` re-checks the `repomd.xml` signature,
  `repomd.xml` ↔ metadata hashes, `primary.xml` ↔ package hashes (and that no
  package is unlisted), and that every RPM is signed by the repository key,
  before anything is uploaded.

## Local Builds

Use one explicit Buildx entrypoint:

```bash
./scripts/build-rpm.sh <package>
```

Packages: `podman`, `netavark`, `aardvark-dns`, `containers-common`, `crun`,
`conmon`, `passt`, `catatonit`. The target is always Amazon Linux 2023; compiled
packages build for `aarch64` then `x86_64`, containers-common (noarch) once.

```bash
./scripts/build-rpm.sh podman
BUILD_ARCHES=aarch64 ./scripts/build-rpm.sh netavark    # native arch only while iterating
```

The non-native architecture runs under QEMU emulation and is slow (podman takes
well over half an hour); use `BUILD_ARCHES` locally and leave both
architectures to the native GitHub runners.

## Script Layout

- GitHub Actions workflows: `.github/workflows/build-and-release.yml` (one component per run: `main` or `extra`) and `.github/workflows/publish-rpm-repo.yml` (RPM repository → GitHub Pages)
- Host/orchestrator entrypoint: `scripts/build-rpm.sh`
- RPM repository: `scripts/rpm-repo-keygen.sh` (signing key), `scripts/build-rpm-repo.sh` (assemble + sign), `scripts/verify-rpm-repo.sh` (integrity gate), `scripts/smoke-rpm-repo.sh` (container install test); config in `packaging/repo/components` and `packaging/repo/pubkey.asc`; private key in gitignored `keys/`
- Shared host helpers: `scripts/lib/`
- Shared in-container dispatcher and spec-editing helpers: `scripts/container/build.sh`, `scripts/container/lib/build-common.sh`
- Product build modules: `scripts/container/products/`
- Shared Dockerfile: `docker/Dockerfile`
- Package patch hierarchy: `packaging/<package>/patches/`

## Output Contract

Build artifacts are written to:

`output/al2023/<build-date>/<architecture>/`

Where:
- `<build-date>` is the UTC date in `YYYYMMDD` format from `date -u +%Y%m%d`
- `<architecture>` is `x86_64`, `aarch64`, or `noarch` (containers-common)

Each architecture directory holds the published `*.rpm` files, the rendered
`<product>.spec`, `build.log`, and `SHA256SUMS`; `manifest.txt` sits beside the
architecture directories.

Same-day rerun behavior:
- Each local build invocation deletes `output/al2023/<YYYYMMDD>/` before
  rebuilding. This intentionally replaces all same-day local artifacts already
  present (including those of other packages); copy them elsewhere first if you
  are assembling a repository locally.

Per-architecture run behavior:
- Local compiled-package builds run sequentially in order: aarch64, then x86_64.
- Each architecture run is isolated; artifacts are exported as soon as that
  architecture finishes.
- If one architecture fails, the script stops before attempting remaining
  architectures and exits non-zero at the end.

## What The Build Does

- Runs entirely in `amazonlinux:2023` Docker containers.
- GitHub Actions: uses native `x86_64` and `aarch64` runners with `docker build` (BuildKit default). All products of a component build in parallel.
- Local: uses `docker buildx build --platform`; the non-native architecture is emulated.
- Uses `--pull --no-cache` for each build so dnf metadata and packages are fresh every run.
- Uses pinned upstream inputs from `packaging/versions.env` and verifies every download's SHA-256.
- Takes the RPM spec from the pinned upstream tree (SPAL's source RPM for catatonit), applies the asserted Amazon Linux 2023 edits described above, sets `Release: <YYYYMMDD>.<N>.amzn2023`, and injects the repo-managed patch series.
- Resolves BuildRequires with `dnf builddep`, asserts the distro Go/Rust toolchains satisfy the upstream minimums, and runs `rpmbuild -bb` with `GOTOOLCHAIN=local`, `GOFLAGS=-mod=vendor`, `GOTELEMETRY=off`, `CARGO_NET_OFFLINE=true` and no debuginfo subpackages.
- Collects only the RPMs assigned to a published component, writes `SHA256SUMS` in each arch directory and `manifest.txt` at `output/al2023/<YYYYMMDD>/manifest.txt`.

## Deterministic Patch Policy

No runtime fallback or auto-detection is used.

Patch directory convention:
- `packaging/<package>/patches/series`
- `packaging/<package>/patches/*.patch`

Notes:
- Each build uses its `series` file exactly as-is; patches apply to the
  upstream source tree with `-p1` via the spec's `%autosetup`.
- Empty `series` means patch application is skipped.
- The distro spec never contributes patches of its own (the packaging comes
  from the pinned upstream tree); a spec that already carries `Patch` lines
  fails the build.

## Version Pinning

Pinned upstream input config: `packaging/versions.env` (sourced by every
orchestrator). Every tag/version pair is cross-checked, every archive has a
required SHA-256, and:

- `PODMAN_TAG` / `UPSTREAM_SHA256` — GitHub tag archive. To obtain a checksum:
  `curl -fsSL -L "https://github.com/podman-container-tools/podman/archive/refs/tags/v<VERSION>.tar.gz" | sha256sum`.
  The podman spec's `Requires: containers-common-extra >= 5:<version>` must equal
  `CONTAINERS_COMMON_VERSION`; bump both together.
- `NETAVARK_*` / `AARDVARK_*` — GitHub source archive plus the release
  vendored-deps tarball (`.../releases/download/v<VERSION>/<name>-v<VERSION>-vendor.tar.gz`)
  for an offline cargo build. `RUST_MIN_VERSION` is the MSRV the distro `rustc`
  must satisfy.
- `CRUN_*` — the release dist tarball `crun-<VERSION>.tar.gz` (tag = bare version).
- `CONMON_*` — GitHub tag archive (`v<VERSION>`).
- `CONTAINERS_COMMON_*` — container-libs monorepo tag archive `common/v<VERSION>`;
  `SHORTNAMES_COMMIT` / `SHORTNAMES_SHA256` pin `shortnames.conf` from
  containers/shortnames and `REDHAT_RELEASE_KEY_SHA256` pins the spec's
  `Source2` (`https://access.redhat.com/security/data/fd431d51.txt`).
- `PASST_TAG` / `PASST_ARCHIVE_SHA256` — `https://passt.top/passt/snapshot/passt-<TAG>.tar.xz`
  (tags are `YYYY_MM_DD.<hash>`); the RPM version becomes `0^<YYYYMMDD>.g<hash>`.
- `CATATONIT_*` — GitHub tag archive (`v<VERSION>`).

Go is not pinned: AL2023's `golang` is used and must satisfy the `go` directive
in the pinned podman `go.mod` (the build fails otherwise).

## Prerequisites

GitHub Actions (default):
- Repository with Actions enabled and `contents: write` permission for the workflow.
- Access to the standard
  [`ubuntu-24.04-arm` GitHub-hosted runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
  used by the build matrix; private repositories consume Actions minutes for
  that runner.
- For the RPM repository: GitHub Pages enabled with source "GitHub Actions", the
  `GPG_PRIVATE_KEY` secret, and your own `packaging/repo/pubkey.asc` (see
  [Hosting Your Own RPM Repository](#hosting-your-own-rpm-repository)).

Local builds:
- Docker with Buildx support.

Builds require network access to the Amazon Linux 2023 package mirrors
(`cdn.amazonlinux.com`, including SPAL for catatonit's spec), GitHub source
archives, `passt.top`, and `raw.githubusercontent.com`. The workflows also use
the GitHub API and Releases.

## Releases

Package version format: `<UPSTREAM_VERSION>-<YYYYMMDD>.<N>.amzn2023` with the
upstream Epoch preserved (for example `podman-5:6.1.0-20260830.1.amzn2023`,
`netavark-2:2.0.0-20260830.1.amzn2023`, `passt-0^20260728.gf8df3f1-20260830.1.amzn2023`).
GitHub normalizes `^` and `~` in release asset filenames to `.`, so the workflow
renames assets the same way before upload; the package headers, which the
repository indexes, are unchanged.
