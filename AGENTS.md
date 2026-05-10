# AGENTS.md — SEAPATH Yocto BSP

## Overview

Yocto-based firmware build system for the SEAPATH virtualization platform.
Uses `repo` for multi-repository source sync and `cqfd` for containerized builds.
Builds produce UEFI-only images (host, guest, flasher, observer) with optional SwUpdate `.swu` packages.

## Prerequisites

- `repo` tool (from Google)
- `cqfd` (from https://github.com/savoirfairelinux/cqfd)
- Docker (user must be in `docker` group)
- `seapath.conf` **must exist** at the repo root before building — copy from `seapath.conf.sample`
- SSH public key at `keys/ansible_public_ssh_key.pub` (used by Ansible; dummy file is OK for build)
- The Docker build container is Ubuntu 22.04 based (see `.cqfd/docker/Dockerfile`)

## Source management

Sources are NOT in-tree. Use `repo`:
```
repo init -u https://github.com/seapath/repo-manifest.git
repo sync
```
All fetched sources land in `sources/` (gitignored). Poky is found under `sources/poky/`.

## Building

### Simple (recommended)
```
cqfd init                  # first time only (creates Docker image)
cqfd -b <flavor>           # build a specific image
```
Key flavors (`cqfd flavors` lists all): `host_efi`, `guest_efi`, `flasher`, `observer_efi`, `host_standalone_efi`, plus `_dbg`, `_test`, `_swu` variants.

### Manual
```
./build.sh -i <image> -m <machine> --distro <distro>
```
Defaults (settable via optional `build.conf` at repo root): `IMAGE=seapath-host-efi-image`, `MACHINE=seapath-hypervisor`, `DISTRO=seapath-host`.

### Custom bitbake commands
```
./build.sh -i <image> -- bitbake -c clean <package>
./build.sh -i seapath -m <machine> --sdk   # build SDK
./build.sh -i <image> --clean-image        # clean only
```

## Build output

Build artifacts land in `build/tmp/deploy/images/<machine>/`.
Output formats: `.wic.gz` (disk images), `.wic.bmap` (block maps), `.swu` (SwUpdate packages), `.qcow2` (QEMU guests), SPDX SBOM (`.spdx.tar.zst`), OpenVEX annotations (`.rootfs.json`).

## Configuration (`seapath.conf`)

Shell-sourced by `build.sh`. All `SEAPATH_*` vars are auto-exported into BitBake. Important vars:
- `SEAPATH_PARALLEL_MAKE` — limit parallel jobs for memory-heavy packages (Ceph)
- `SEAPATH_KEYMAP` — keyboard layout (default `us`)
- `SEAPATH_RT_CORES` — reserved CPUs (default `2-N`, meaning all cores except 0-1)
- `SEAPATH_COCKPIT` — enable Cockpit web UI (default `false`)
- `SEAPATH_SECCOMPILE_MANIFEST_SKIP` — skip compile-options report (saves ~1h)

## Patches

All `.patch` files in `patches/` are auto-applied by `build.sh` before each build.
A `.done` flag file next to each patch prevents re-application. To force reapply, delete the matching `.done` file.

## Layers blocklist

`layers.blocklist` lists Yocto layer paths to exclude from the build (one per line).
Paths are relative to `sources/`. Used by `build.sh` to filter `bblayers.conf` content.
Excluded: various OpenStack layers, GNOME/multimedia/XFCE layers, secure-core TPM/encrypted-storage layers, poky selftest/skeleton.

## meta-seapath

For details on the meta-seapath layer (Yocto recipes, classes, machine configs), see `sources/meta-seapath/AGENTS.md`.

## Git conventions

All commits must be signed off with `-s` (`git commit -s`). No unsigned commits are accepted.

## CI / testing

- CI is **not** for this repo in isolation. Other repos (e.g. `meta-seapath`, `repo-manifest`) trigger workflow_dispatch to run the full SEAPATH build pipeline here.
- CI jobs run on a **self-hosted** runner (`runner-sfl-seapath`).
- Action variables are deliberately hardcoded in `_build.yml` and `_cve-check.yml` because GH Action variables are not accessible to PRs from forks.
- The CVE check (`_cve-check.yml`) downloads SBOM artifacts from the build job, runs `sbom-cve-check` then `VulnScout` (Docker image `sflinux/vulnscout`), and posts PR comments via Jinja2 template + GitHub App token.

## Important quirks

- **No tests to run locally.** Testing happens through the CI pipeline which performs full Yocto builds + CVE analysis. A full build takes 4-5 hours and ~50GB disk.
- **`build/` is gitignored.** Do not look for source files there — all yocto layers and poky are in `sources/` (also gitignored, fetched by `repo`).
- **License**: The `build.sh` is Apache-2.0; docs/README are CC-BY-4.0. Files use `SPDX-License-Identifier` headers.
- **Branch**: All work targets the `scarthgap` branch (Yocto Scarthgap release).

## Key directories

| Path | Purpose |
|------|---------|
| `build/` | Yocto build directory (gitignored, generated) |
| `sources/` | Fetched Yocto layers + poky (gitignored, via `repo`) |
| `patches/` | Auto-applied patches for poky/meta layers |
| `tools/` | Utility scripts (deploy VM, demo setup, releases, license checks) |
| `scripts/` | get-version helper, secureboot key generator |
| `keys/` | SSH keys for Ansible (gitignored except README) |
| `.cqfd/` | Dockerfile and cqfd config |

## Images, distros, and machines

**Machines**: `seapath-hypervisor` (default, x86-64 host), `seapath-vm` (QEMU guests), `seapath-installer` (flasher USB), `seapath-observer` (cluster observer), `seapath-observer-rpi` (Raspberry Pi observer).

**Distros**: `seapath-host` (full: containers + VMs + security + read-only + clustering + no secureboot), `seapath-host-sb` (same + secureboot), `seapath-host-minimal` (containers + VMs only, no security/read-only/clustering), `seapath-standalone-host` (same as seapath-host but no clustering), `seapath-container-host` (containers only, no VMs), `seapath-standalone-containers-host` (containers only, no VMs, no clustering), `seapath-host-cluster-minimal` (VMs + clustering only, no security/read-only), `seapath-guest`, `seapath-flash`, `seapath-observer`.
