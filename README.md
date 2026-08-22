# Radxa Cubie A5E Debian 13 / Linux 6.16 Image Builder

This repository rebuilds the hardware-validated Radxa Cubie A5E image from a clean clone. It preserves Radxa's known-good boot chain, replaces the vendor userspace with Debian 13, builds one managed Linux 6.16 kernel, applies the required Cubie A5E kernel and DTB support, and builds the Radxa AIC8800 SDIO driver.

The top-level `build-cubie-a5e.sh` script is both the interactive build manager and the non-interactive build wrapper. It supports:

- Creating a complete compressed `.img.xz` image for Balena Etcher.
- Writing the complete image directly to a removable SD card or SSD.
- Building only the signed Cubie A5E kernel/board update bundle.
- Forcing clean kernel and AIC8800 rebuilds.
- Rebuilding the Debian rootfs when required.
- Running repository source validation.

## Validated board result

| Device | Linux name | Policy |
| --- | --- | --- |
| GMAC0 | `eth0` | Managed by NetworkManager |
| GMAC1 / GMAC200 | `eth1` | Managed by NetworkManager |
| AIC8800 SDIO | `wlan0` | Managed, disconnected, with no saved Wi-Fi profile |

The generated image creates the local account `initbox` with password `****`. The account has passwordless `sudo`, no forced password change, and no password expiry. Automatic root login is disabled. Stage 80 rejects an image that does not match this policy.

## Repository layout

```text
Radxa-Image-builder/
|-- build-cubie-a5e.sh             # interactive build manager and top-level build wrapper
|-- 10-...sh through 80-...sh      # ordered build, installation and validation stages
|-- base/                           # donor-image and Debian rootfs writer
|-- assets/                         # board runtime assets installed into the generated image
|-- config/source-pins.env          # pinned upstream refs, versions and donor checksum
|-- docs/                           # build-flow and validated-hardware documentation
|-- lib/common.sh                   # shared shell helpers used by build stages
|-- tools/                          # repository validation and maintenance utilities
|-- MANIFEST.sha256                 # checksums for tracked repository files
`-- build/                          # ignored downloads, sources, caches, logs, bundles and keys
```

Downloaded sources, rootfs files, build objects, logs, update bundles and signing keys stay under the ignored `build/` directory. In Etcher-image mode, the temporary raw image, final compressed image and checksum are created directly under `/home/psi/`; the temporary raw image is removed after successful compression. Failed Etcher builds remove their current raw/compressed image artifacts after the loop device is detached so a partial image cannot be mistaken for a successful build.

No file from the retired `/home/psi/cubie-a5e-build` layout is required.

## Prepare a fresh clone

Files created or replaced through the GitHub website can lose their executable bit. Normalize the repository programs after cloning:

```bash
git clone https://github.com/psi1703/Radxa-Image-builder.git
cd Radxa-Image-builder

chmod 0755 -- \
  ./*.sh \
  base/*.sh \
  lib/*.sh \
  tools/*.sh \
  assets/rsetup \
  assets/cubie-a5e-update \
  assets/cubie-a5e-install-nvme \
  assets/ensure-radxa-trixie-repo
```

## Host requirements

- Debian or Ubuntu x86-64 build host with `sudo` and Internet access.
- Approximately 40 GB of free space for downloads, source trees, rootfs, build objects and bundles.
- For direct writing, a removable SD card or SSD of at least 4 GiB.
- For Etcher-image creation, enough free space under `/home/psi/` for the raw working image and compressed output.

Required host packages and the Arm64 cross toolchain are installed with `apt-get` by the build process.

## Interactive build manager

Run the top-level wrapper without build-selection environment variables:

```bash
sudo ./build-cubie-a5e.sh
```

The integrated menu provides:

```text
1. Build complete Balena Etcher image
2. Build complete image directly to a device
3. Build signed kernel / board update bundle
4. Force clean kernel + AIC8800 rebuild and signed update bundle
5. Rebuild Debian rootfs and complete Etcher image
6. Validate repository scripts and policy
7. Show source pins
8. Exit
```

Additional front-end commands are available:

```bash
./build-cubie-a5e.sh --help
./build-cubie-a5e.sh --validate
./build-cubie-a5e.sh --show-pins
sudo ./build-cubie-a5e.sh --menu
```

Automation remains environment driven. Supplying build variables bypasses the interactive menu.

## Validated build cache

The first build from a fresh clone performs a complete Linux and AIC8800 build. When this cache implementation is introduced on a build machine that already has a completed pre-cache kernel tree, Stage 10 can retain that strictly checked tree for one incremental migration build instead of deleting it; Stage 30 then runs all normal gates and publishes the first guarded cache state.

After a successful cache-aware build, the wrapper reuses the compiled kernel, external Wi-Fi modules and signed update bundle only when their recorded fingerprints and output hashes still pass validation.

The kernel fingerprint covers the pinned Linux source, all kernel backport/DTS/config/build scripts, an optional external kernel configuration, compiler/linker/assembler and other kernel build-tool identities, and the kernel local version. The AIC8800 fingerprint also covers its pinned source and module-build script. Changes limited to image creation, rootfs installation, network policy, Stage 80 validation or documentation therefore do not trigger an unnecessary kernel rebuild.

The image `BUILD_ID` remains timestamped for logs and output filenames. The kernel local version is stable and derived from its inputs, for example `+cubie-a5e.k<12-hex-digits>`. A different Linux pin, backport, DTS, kernel configuration, compiler or explicit `KERNEL_LOCALVERSION` produces a new fingerprint and a clean kernel rebuild automatically. An AIC8800-only input change rebuilds only the external Wi-Fi modules. The signed update bundle is reused only when its exact kernel, DTB, configuration, AIC8800 modules, firmware and signing-key fingerprint still match.

To force a clean kernel and AIC8800 rebuild in a full Etcher image build:

```bash
sudo env OUTPUT_MODE=etcher-image KERNEL_REBUILD=1 AIC_REBUILD=1 ./build-cubie-a5e.sh
```

To rebuild only the AIC8800 external modules:

```bash
sudo env OUTPUT_MODE=etcher-image AIC_REBUILD=1 ./build-cubie-a5e.sh
```

Successful cache metadata is stored under `build/cache/`. Missing, stale, inconsistent or hash-mismatched cache state is never trusted; the affected component is rebuilt and the cache is recorded again only after all validation gates pass.

## Create a Balena Etcher image

Use menu option 1, or run non-interactively:

```bash
sudo env OUTPUT_MODE=etcher-image ./build-cubie-a5e.sh
```

The wrapper creates a sparse raw image and attaches it to a temporary loop device. Stages 50 through 80 use that loop device and perform the same target validation as direct-device mode. The wrapper detaches and compresses the image only after Stage 80 passes.

Successful output:

```text
/home/psi/cubie-a5e-debian13-linux6.16-<build-id>.img.xz
/home/psi/cubie-a5e-debian13-linux6.16-<build-id>.img.xz.sha256
```

The `.img.xz` is a complete disk image containing the Radxa boot chain and all three partitions. Select it directly in Balena Etcher and flash it to an SD card or SSD whose capacity is at least `IMAGE_SIZE_GIB`.

The default image size is 4 GiB. A different whole-number size of at least 4 GiB can be selected with `IMAGE_SIZE_GIB`. Stage 50 expands the root partition to fill the generated image. After the image is flashed to a larger SD card or SSD, the enabled `cubie-a5e-grow-rootfs.service` expands final partition 3 and its ext4 root filesystem on first boot so they use all remaining capacity on the storage medium. Stage 80 validates the required expansion packages, helper and enabled service before the image is compressed.

To replace the current output path deliberately, set `IMAGE_OVERWRITE=1`. Image output is restricted to `/home/psi/`.

## Write directly to an SD card or SSD

The selected device is completely erased. Inspect it before starting:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
```

Use menu option 2, or run non-interactively with an explicit whole-device path:

```bash
sudo env OUTPUT_MODE=device TARGET_DEVICE=/dev/sdX ./build-cubie-a5e.sh
```

Replace `/dev/sdX` with the verified removable device. The wrapper displays the device identity and rejects known host-system disk paths. Unless `CONFIRM_WRITE=1` is explicitly supplied, direct-device mode requires the interactive `I-UNDERSTAND` confirmation before destructive writing begins.

For intentionally automated destructive writing:

```bash
sudo env \
  OUTPUT_MODE=device \
  TARGET_DEVICE=/dev/sdX \
  CONFIRM_WRITE=1 \
  ./build-cubie-a5e.sh
```

A non-interactive invocation with no build selection is rejected rather than falling through to an implicit target device.

## Rebuild the Debian rootfs

Use menu option 5 for an Etcher image, or set `ROOTFS_REBUILD=1` explicitly. For example:

```bash
sudo env \
  OUTPUT_MODE=etcher-image \
  ROOTFS_REBUILD=1 \
  ./build-cubie-a5e.sh
```

The builder normally reuses a completed validated rootfs, so this option should be used only when a deliberate rootfs replacement is required.

## Build only a signed kernel/board update bundle

Use menu option 3, or run:

```bash
sudo env BUILD_MODE=update-bundle ./build-cubie-a5e.sh
```

To force a clean kernel and AIC8800 rebuild before creating the bundle, use menu option 4 or run:

```bash
sudo env \
  BUILD_MODE=update-bundle \
  KERNEL_REBUILD=1 \
  AIC_REBUILD=1 \
  ./build-cubie-a5e.sh
```

The first bundle build creates the private signing key at:

```text
build/update-signing/cubie-a5e-update-private.pem
```

The private key is excluded by `.gitignore`. Back it up securely and never upload it to GitHub. Losing it prevents existing devices from trusting bundles signed with a replacement identity.

The matching public trust material is installed in generated images. `cubie-a5e-update` verifies the signed bundle before staging a managed kernel/DTB/module update and retains the existing rollback/finalization mechanism.

## On-board update policy

The generated image exposes the supported maintenance operations through:

```bash
sudo rsetup
```

The wrapper separates normal operating-system maintenance from Cubie-specific kernel maintenance:

```text
Radxa system configuration and package updates
Full Debian/Radxa system upgrade
Cubie A5E signed kernel and board updates
Install the current Cubie A5E system to NVMe
```

`Full Debian/Radxa system upgrade` runs normal `apt-get update` and `apt-get full-upgrade` maintenance. The managed Cubie kernel is protected from replacement by generic Debian/Radxa kernel packages through `assets/99-cubie-a5e-managed-kernel`.

Cubie kernel, DTB and matching external-module releases use the separate signed `cubie-a5e-update` path. SPI bootloader flashing and NVMe migration remain explicit maintenance operations and are not performed automatically by a normal Debian package upgrade.

## Install the running SD system to NVMe

The generated image installs a guarded Cubie A5E NVMe migration helper at `/usr/local/sbin/cubie-a5e-install-nvme` and exposes it through `rsetup` as **Install the current Cubie A5E system to NVMe**. The operation is destructive to the selected NVMe namespace.

The installer is intentionally specific to this repository's validated disk layout. It requires the running Debian ext4 root and `/boot/extlinux` payload to be on final partition 3. Before any destructive action it verifies the running managed kernel, initramfs, Cubie A5E DTB, extlinux root UUID, `/etc/fstab`, PCIe/PHY initramfs policy, absence of a pending managed update, the running 20 MHz SPI-NOR DTB policy, and a compatible Radxa SPI U-Boot version.

It identifies the source disk from the mounted root filesystem, refuses an NVMe source, accepts only a whole writable `/dev/nvmeXnY` target, refuses mounted or active-swap targets, requires the NVMe to be at least as large as the source media, and requires matching logical sector sizes.

The migration preserves the Radxa boot-chain area before partition 3 with a bounded raw copy, relocates and regenerates the target GPT identifiers, recreates partition 3 to fill the NVMe, creates a fresh ext4 root UUID, copies the running Debian filesystem with metadata-preserving `rsync`, and rewrites `/etc/fstab`, `/boot/extlinux/extlinux.conf`, and `/etc/cubie-a5e-update/layout.env` for the new UUID. It validates the kernel, initramfs, DTB, PCIe initramfs policy, GPT, ext4 filesystem, managed update metadata and SPI/U-Boot preflight before reporting success.

Run it through the wrapper:

```bash
sudo rsetup
```

Or invoke the helper directly:

```bash
sudo /usr/local/sbin/cubie-a5e-install-nvme --tui
```

After a successful migration, power the board off completely, remove the microSD card, and boot again. Standalone NVMe boot requires the validated Cubie A5E SPI bootloader; if its installed version is unsuitable, the migration helper refuses to proceed before destructive NVMe work begins.

## Reproducible inputs

| Input | Pin |
| --- | --- |
| Linux | Tag `v6.16`, commit `038d61fd642278bab63ee8ef722c50d10ab01e8f` |
| Radxa AIC8800 | Tag `5.0+git20260123.5f7be68d-7`, commit `6e076049b719ac2ff7ce5c92786a680407b11cdb` |
| Radxa donor image | Release `rsdk-r7`, with its SHA-512 pinned in `config/source-pins.env` |

The build stages verify their required upstream commits and pinned source state before applying board-specific changes. A moved tag, missing commit, changed expected source state or donor checksum mismatch stops the build.

## Generated outputs

| Output | Path |
| --- | --- |
| Build logs | `build/logs/<build-id>/` |
| Kernel tree | `build/linux-6.16-one-shot/` |
| AIC8800 tree | `build/aic8800-radxa/` |
| Validated build-cache metadata | `build/cache/` |
| Debian rootfs | `build/rootfs/` |
| Signed update bundles | `build/update-bundles/` |
| Flashable image and checksum | `/home/psi/cubie-a5e-debian13-linux6.16-<build-id>.img.xz{,.sha256}` |
| Private update signing identity | `build/update-signing/` |

## Validate repository contents

After normalizing executable permissions, run:

```bash
./tools/validate-repository.sh
```

Or use:

```bash
./build-cubie-a5e.sh --validate
```

The checker runs Bash parsing, ShellCheck when installed, manifest verification, executable-mode checks, large-file checks, private-key/path-leak checks, build-policy checks, and regression guards for safety-critical behavior such as the NVMe SPI/GPT validation. Stage 80 remains the authoritative validation of the written image.

`MANIFEST.sha256` is updated only after all planned repository corrections are complete. During a staged correction pass, the validator can therefore report expected checksum mismatches for files changed since the last manifest update.

## Tested hardware state

The completed image was boot-tested with kernel `6.16.0+cubie-a5e.20260728T094708Z+`. The `initbox` login worked, `ping` and `nano` were present, systemd reported zero failed units, `eth1` linked, and `eth0` and `wlan0` appeared under their expected names.

The SD-to-NVMe migration path has also been validated with the SD card removed: SPI U-Boot started the NVMe boot chain, Debian mounted `/dev/nvme0n1p3` as `/`, the kernel command line used the migrated NVMe root UUID, and systemd reported zero failed units.

See `docs/VALIDATED-HARDWARE.md` for the recorded board result. The repository is licensed under the included MIT `LICENSE` file.
