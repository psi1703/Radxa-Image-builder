[README.md](https://github.com/user-attachments/files/31264467/README.md)
# Radxa Cubie A5E Debian 13 / Linux 6.16 Image Builder

This repository rebuilds the hardware-validated Radxa Cubie A5E image from a clean clone. It preserves Radxa's known-good boot chain, replaces the vendor userspace with Debian 13, builds a single Linux 6.16 kernel, backports the required GMAC200 and regulator support, and builds the Radxa AIC8800 SDIO driver.

The builder supports two image output paths:

- Write directly to a removable SD card or SSD.
- Create a complete compressed `.img.xz` disk image for Balena Etcher.

It can also build the signed kernel/vendor update bundle together with APT-managed `cubie-a5e-board-support` and `cubie-a5e-kernel-update` packages, without writing a target device.

## Validated board result

| Device | Linux name | Policy |
| --- | --- | --- |
| GMAC0 | `eth0` | Managed by NetworkManager |
| GMAC1 / GMAC200 | `eth1` | Managed by NetworkManager |
| AIC8800 SDIO | `wlan0` | Managed, disconnected, with no saved Wi-Fi profile |

The generated image creates the local account `initbox` with password `init`. The account has passwordless `sudo`, no forced password change, and no password expiry. Automatic root login is disabled. Stage 80 rejects an image that does not match this policy.

## Repository layout

```text
.
â”œâ”€â”€ build-cubie-a5e.sh             # top-level build wrapper
â”œâ”€â”€ 10-...sh through 80-...sh      # ordered build and validation stages
â”œâ”€â”€ base/                           # donor-image and Debian rootfs writer
â”œâ”€â”€ assets/                         # small board runtime assets tracked by Git
â”œâ”€â”€ config/source-pins.env          # pinned upstream refs and donor checksum
â”œâ”€â”€ docs/                           # build flow and validated hardware record
â”œâ”€â”€ lib/common.sh                   # shared shell helpers
â”œâ”€â”€ tools/validate-repository.sh    # optional local source validation
â””â”€â”€ build/                          # downloads, sources, build state, logs and keys
```

Downloaded sources, rootfs files, build objects, logs, update bundles, generated APT repositories and signing keys stay under the ignored `build/` directory. In Etcher-image mode, the temporary raw image, final compressed image and checksum are created directly under `/home/psi/`; the temporary raw image is removed after successful compression. No file from the old `/home/psi/cubie-a5e-build` layout is required.

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

Required host packages and the Arm64 cross toolchain are installed with `apt-get`.

## Validated build cache

The first build from a fresh clone performs a complete Linux and AIC8800 build. When this cache implementation is introduced on a build machine that already has a completed pre-cache kernel tree, Stage 10 can retain that strictly checked tree for one incremental migration build instead of deleting it; Stage 30 then runs all normal gates and publishes the first guarded cache state. After a successful cache-aware build, the wrapper reuses the compiled kernel, external Wi-Fi modules and signed update bundle only when their recorded fingerprints and output hashes still pass validation.

The kernel fingerprint covers the pinned Linux source, all kernel backport/DTS/config/build scripts, an optional external kernel configuration, the compiler/linker/assembler and other kernel build-tool identities, and the kernel local version. The AIC8800 fingerprint also covers its pinned source and module-build script. Changes limited to image creation, rootfs installation, network policy, Stage 80 validation or documentation therefore do not trigger an unnecessary kernel rebuild.

The image `BUILD_ID` remains timestamped for logs and output filenames. The kernel local version is stable and derived from its inputs, for example `+cubie-a5e.k<12-hex-digits>`. A different Linux pin, backport, DTS, kernel configuration, compiler or explicit `KERNEL_LOCALVERSION` produces a new fingerprint and a clean kernel rebuild automatically. An AIC8800-only input change rebuilds only the external Wi-Fi modules. The signed update bundle is reused only when its exact kernel, DTB, configuration, AIC8800 modules, firmware and signing-key fingerprint still match.

To force a clean kernel and AIC8800 rebuild even when the cache is valid:

```bash
sudo env OUTPUT_MODE=etcher-image KERNEL_REBUILD=1 ./build-cubie-a5e.sh
```

To rebuild only the AIC8800 external modules:

```bash
sudo env OUTPUT_MODE=etcher-image AIC_REBUILD=1 ./build-cubie-a5e.sh
```

Successful cache metadata is stored under `build/cache/`. Missing, stale, inconsistent or hash-mismatched cache state is never trusted; the affected component is rebuilt and the cache is recorded again only after all existing validation gates pass.

## Interactive build menu

For normal build-host use, launch the menu front end:

```bash
sudo ./cubie-build-menu.sh
```

The menu does not duplicate build logic. It maps the selected operation to the existing `build-cubie-a5e.sh` modes and environment variables, including complete Etcher images, direct-device builds, signed APT update-repository builds, forced kernel/AIC rebuilds, source-pin display and repository validation.

## Write directly to an SD card or SSD

The selected device is completely erased. Inspect it before starting:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
```

Then run:

```bash
sudo env OUTPUT_MODE=device TARGET_DEVICE=/dev/sdX CONFIRM_WRITE=1 ./build-cubie-a5e.sh
```

Replace `/dev/sdX` with the verified whole removable device. `OUTPUT_MODE=device` is the default. The wrapper displays the device identity and rejects known host-system disk paths.

Omit `CONFIRM_WRITE=1` if you want the interactive `I-UNDERSTAND` confirmation instead.

## Create a Balena Etcher image

No SD card or SSD needs to be connected:

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

To replace an existing image output deliberately, set `IMAGE_OVERWRITE=1`. Image output is restricted to `/home/psi/`.

## Install the running SD system to NVMe

The generated image installs a guarded Cubie A5E NVMe migration helper at `/usr/local/sbin/cubie-a5e-install-nvme` and exposes it through `rsetup` as **Install the current Cubie A5E system to NVMe**. The operation is destructive to the selected NVMe namespace.

The installer is intentionally specific to this repository's validated disk layout. It requires the running Debian ext4 root and `/boot/extlinux` payload to be on final partition 3. Before any destructive action it also verifies the running managed kernel, initramfs, Cubie A5E DTB, extlinux root UUID, `/etc/fstab`, PCIe/PHY initramfs policy, and absence of a pending managed update. It identifies the source disk from the mounted root filesystem, refuses an NVMe source, accepts only a whole writable `/dev/nvmeXnY` target, refuses mounted or active-swap targets, requires the NVMe to be at least as large as the source media, and requires matching logical sector sizes.

The migration preserves the Radxa boot-chain area before partition 3 with a bounded raw copy, relocates and regenerates the target GPT identifiers, recreates partition 3 to fill the NVMe, creates a fresh ext4 root UUID, copies the running Debian filesystem with metadata-preserving `rsync`, and rewrites `/etc/fstab`, `/boot/extlinux/extlinux.conf`, and `/etc/cubie-a5e-update/layout.env` for the new UUID. It validates the kernel, initramfs, DTB, PCIe initramfs policy, GPT, ext4 filesystem, and managed update metadata before reporting success.

Run it from the wrapper:

```bash
sudo rsetup
```

Or invoke the helper directly:

```bash
sudo /usr/local/sbin/cubie-a5e-install-nvme --tui
```

Standalone NVMe boot requires compatible Cubie A5E SPI boot firmware. After a successful migration, power the board off completely, remove the microSD card, and boot again. If standalone NVMe boot does not start, install or update the board's SPI boot firmware from the underlying Radxa system configuration and retry.

## Rebuild the Debian rootfs

The builder normally reuses a completed rootfs. To deliberately replace an incomplete or old generated rootfs:

```bash
sudo env OUTPUT_MODE=device TARGET_DEVICE=/dev/sdX ROOTFS_REBUILD=1 ./build-cubie-a5e.sh
```

## Build signed kernel/board APT updates only

```bash
sudo env BUILD_MODE=update-bundle ./build-cubie-a5e.sh
```

This mode builds the signed kernel/vendor bundle and then Stage 46 wraps the managed runtime and bundle into two Debian packages:

- `cubie-a5e-board-support` owns the updater, `rsetup` wrapper, guarded NVMe installer, update trust material and APT-channel policy. Bump `CUBIE_BOARD_SUPPORT_VERSION` when those runtime assets need to be delivered to installed boards.
- `cubie-a5e-kernel-update` carries the signed kernel/vendor bundle and delegates activation to `cubie-a5e-update`, preserving the existing pending-boot, rollback and successful-boot finalization flow.

Stage 46 also creates and signs a flat APT repository under `build/apt-repository/`. The archive signing key is persistent under ignored `build/apt-signing/`. Keep both the APT private key and the existing bundle-signing private key private and backed up.

`CUBIE_APT_REPO_URL` is intentionally empty by default. Once the generated repository is published at a stable HTTPS endpoint, set that URL in the build environment or `config/source-pins.env`; new board-support packages will install the signed deb822 source. `rsetup` then exposes **Full Debian/Radxa + approved Cubie A5E package upgrade**, which runs `apt-get update` followed by `apt-get full-upgrade`. Generic Debian kernel replacement remains blocked by the managed-kernel APT policy, and SPI firmware is never flashed automatically.

The first bundle build creates the private signing key at:

```text
build/update-signing/cubie-a5e-update-private.pem
```

The key is excluded by `.gitignore`. Back it up securely and never upload it to GitHub. Losing it prevents existing devices from trusting bundles signed with a replacement identity.

## Reproducible inputs

| Input | Pin |
| --- | --- |
| Linux | Tag `v6.16`, commit `038d61fd642278bab63ee8ef722c50d10ab01e8f` |
| Radxa AIC8800 | Tag `5.0+git20260123.5f7be68d-7`, commit `6e076049b719ac2ff7ce5c92786a680407b11cdb` |
| Radxa donor image | Release `rsdk-r7`, with its SHA-512 pinned in `config/source-pins.env` |

Stage 20 names and verifies all nine required upstream Linux backport commit IDs before applying them. A moved tag, missing commit, changed subject or donor checksum mismatch stops the build.

## Generated outputs

| Output | Path |
| --- | --- |
| Build logs | `build/logs/<build-id>/` |
| Kernel tree | `build/linux-6.16-one-shot/` |
| AIC8800 tree | `build/aic8800-radxa/` |
| Validated build-cache metadata | `build/cache/` |
| Debian rootfs | `build/rootfs/` |
| Signed update bundles | `build/update-bundles/` |
| Cubie A5E Debian packages and signed flat APT repository | `build/apt-repository/` |
| APT archive signing identity | `build/apt-signing/` |
| Flashable image and checksum | `/home/psi/cubie-a5e-debian13-linux6.16-<build-id>.img.xz{,.sha256}` |
| Private signing identity | `build/update-signing/` |

## Validate repository contents

After normalizing executable permissions, run:

```bash
./tools/validate-repository.sh
```

The checker runs Bash parsing, ShellCheck when installed, manifest verification, executable-mode checks, large-file checks, and private-key/path-leak checks. Stage 80 remains the authoritative validation of the written image.

`MANIFEST.sha256` is updated only after all planned repository corrections are complete. During a staged correction pass, the validator can therefore report expected checksum mismatches for files changed since the last manifest update.

## Tested hardware state

The completed image was boot-tested with kernel `6.16.0+cubie-a5e.20260728T094708Z+`. The `initbox` login worked, `ping` and `nano` were present, systemd reported zero failed units, `eth1` linked, and `eth0` and `wlan0` appeared under their expected names.

See `docs/VALIDATED-HARDWARE.md` for the recorded board result. The repository is licensed under the included MIT `LICENSE` file.
