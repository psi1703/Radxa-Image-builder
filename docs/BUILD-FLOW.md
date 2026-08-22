# Build flow and provenance

The repository has one user-facing build entry point:

```text
build-cubie-a5e.sh
```

When run interactively without explicit build-selection environment variables, the wrapper presents the build manager menu. The same script remains automation-friendly: explicit `BUILD_MODE`, `OUTPUT_MODE`, `TARGET_DEVICE`, and rebuild variables bypass the menu and run the requested build directly.

The numbered stage scripts remain separate so the pipeline is deterministic, independently testable, and rerunnable where appropriate.

## Current managed-kernel baseline

The repository is now pinned to the Linux 6.18 LTS line for the migration build:

```text
Repository: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
Ref:        v6.18.45
Commit:     bf3be28f6721e24961992ebb9e61c0cf21a56806
```

The workspace name is derived from `LINUX_REF`, so the current default is:

```text
build/linux-6.18.45-one-shot/
```

Linux 6.16 remains the last fully hardware-validated board baseline until the 6.18.45 image is built, booted, and passes the board validation checklist. The repository must not describe 6.18.45 as hardware-validated before that test is complete.

## Stage sequence

| Stage | Role | Persistent output |
| --- | --- | --- |
| 10 | Install host packages, verify declared source pins, verify the Radxa donor image, and reuse or recreate validated source/build caches | `build/downloads/`, Linux tree, AIC8800 tree, and `build/cache/` |
| 15 | Create or reuse the Debian 13 Arm64 rootfs | `build/rootfs/` |
| 20 | Validate the GMAC/PCK600 support already present in Linux 6.18 and backport only the missing Cubie A5E GMAC1 DTS integration | Modified disposable Linux tree and `.cubie-a5e-gmac1-dts-backport` |
| 22 | Apply and validate the reviewed Radxa vendor PCIe/controller/combo-PHY port still required on Linux 6.18 for Cubie A5E NVMe | Modified disposable Linux tree and `.cubie-a5e-pcie-vendor-port-lts` |
| 25 | Apply and validate Cubie A5E board DTS policy, including the proven GMAC0 timings and AIC8800 SDIO/power/reset configuration | Kernel board DTS and DTB inputs |
| 27 | Backport and validate the A523 SPI support still missing from Linux 6.18; keep the validated SPI0 NOR path PIO-only at 20 MHz | Modified disposable Linux tree and `.cubie-a5e-a523-spi-backport` |
| 30 | Reuse hash-validated kernel outputs or build Linux, DTBs, and in-tree modules; verify the tree descends from the exact pinned 6.18.45 commit | Kernel tree, release marker, and kernel cache metadata |
| 40 | Reuse or build AIC8800 SDIO modules against the exact managed kernel release; apply Radxa compatibility patches through Linux 6.17 and stop before 6.19+ patches | AIC8800 tree, module manifest, and AIC8800 cache metadata |
| 45 | Reuse an exact validated bundle or create and sign the managed kernel/board update bundle; record kernel and AIC source provenance | `build/update-bundles/`, bundle cache metadata, and local signing identity |
| 50 | Write the Radxa donor disk layout, replace partition 3 with Debian 13, and expand it to the selected target or image size | Physical target or image-backed loop device |
| 60 | Install the managed kernel, DTB, firmware, packages, login policy, signed updater, `rsetup`, guarded SD-to-NVMe migration helper, and first-boot root-filesystem expansion service | Physical target or image-backed loop device |
| 70 | Install deterministic interface naming and NetworkManager policy | Physical target or image-backed loop device |
| 80 | Perform clean, read-only target validation, including 6.18 pin ancestry, stage evidence, kernel/modules/DTB, update integration, NVMe migration integration, expansion service, and free-space checks | Validation report and evidence |

Stage 60 is intentionally version-neutral and is named:

```text
60-install-managed-kernel.sh
```

There is no custom Cubie A5E APT-repository build stage. Normal Debian/Radxa userspace updates remain separate from the signed Cubie kernel/board update mechanism.

## Interactive build manager

Run:

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

Menu handling, automation dispatch, stage selection, logging, cleanup, and build execution all remain in `build-cubie-a5e.sh`. There is no standalone menu wrapper.

For non-interactive automation, explicit environment variables bypass the menu. Examples:

```bash
sudo env OUTPUT_MODE=etcher-image ./build-cubie-a5e.sh
sudo env BUILD_MODE=update-bundle ./build-cubie-a5e.sh
sudo env BUILD_MODE=update-bundle KERNEL_REBUILD=1 AIC_REBUILD=1 ./build-cubie-a5e.sh
sudo env OUTPUT_MODE=device TARGET_DEVICE=/dev/sdX ./build-cubie-a5e.sh
```

A non-interactive invocation without an explicit build selection is rejected rather than silently falling through to a destructive device write.

## Provenance policy

The official Radxa donor image supplies only the board's known-good boot chain and narrowly selected Radxa runtime payload. The generated Debian 13 rootfs remains the source of PID 1 and the core userspace. The base writer validates Debian 13 systemd linkage so vendor Debian 11 libraries cannot silently replace it.

Large inputs and build products are reproducible downloads or generated outputs and are intentionally excluded from Git. The small files under `assets/` are the exact board-specific runtime inputs consumed by the installation and validation stages.

Linux, AIC8800, the Radxa BSP sources, the donor image, and bootloader maintenance packages are pinned and verified before use. A missing expected commit, moved source ref, changed donor checksum, or source tree not descended from the approved Linux base stops the build.

For Linux 6.18.45, the pinned base commit does not need to equal the final kernel tree `HEAD`: Stages 20, 22, 25, and 27 deliberately create reviewed Cubie-specific commits on top. Stage 30 and Stage 45 therefore require the pinned commit to be an ancestor of the final tree and record both the base commit and final tree commit.

## Linux 6.18 LTS backport policy

The LTS migration deliberately avoids carrying the old Linux 6.16 patch stack forward unchanged.

For the current 6.18.45 baseline:

```text
Already upstream in 6.18:
- DWMAC_SUN55I / GMAC200 driver support
- PCK600 power-domain support
- A523 SRAM/syscon support used by the Ethernet path

Still supplied by this repository:
- Cubie A5E GMAC1 DTS integration (Stage 20)
- Cubie A5E/A523 PCIe controller and combo-PHY integration (Stage 22)
- Cubie A5E board DTS policy and validated Wi-Fi/GMAC0 values (Stage 25)
- A523 SPI support and Cubie SPI-NOR integration (Stage 27)
```

This split is enforced by `tools/validate-repository.sh` so a future edit cannot accidentally restore the obsolete 6.16 backport model.

## Cache and rebuild policy

The wrapper calculates a stable kernel-input fingerprint before running the stages. It includes the declared Linux repository/ref/commit, kernel-related stages, the selected kernel configuration and its content, the Arm64 compiler/linker/assembler identities, the device-tree compiler, `make`, `pahole`, and the kernel local version. The default local version is derived from those inputs rather than from the timestamped image `BUILD_ID`.

Stage 10 always refreshes and verifies the declared Git pins. It preserves an existing Linux tree only when the cache metadata, pinned baseline ancestry, configured local version, compiled release, required stage stamps, and recorded output hashes agree with the current inputs. A cache created for another kernel ref, base commit, PCIe layout revision, SPI revision, or GMAC1 stage revision is rejected. `KERNEL_REBUILD=1` forces a clean kernel path and invalidates dependent AIC8800 cache state.

Stage 30 repeats the kernel cache checks before using compiled output. A cache hit runs the existing configuration, output, and board-DTB validation gates without recompiling. A miss performs the required build operation and writes cache metadata atomically only after every validation succeeds.

The AIC8800 fingerprint depends on the kernel fingerprint, declared AIC8800 source pin, cross-compiler, and Stage 40. Stages 10 and 40 verify the pinned AIC8800 commit, kernel release, module hashes, BSP symbol/version data, compiler flags, vermagic, and imported-symbol policy before reuse. For Linux 6.18, Stage 40 requires Radxa's Linux 6.17 compatibility patch and deliberately excludes Linux 6.19+ patches. `AIC_REBUILD=1` forces only the external-module rebuild; `KERNEL_REBUILD=1` forces both kernel and AIC8800 rebuilds.

Stage 45 fingerprints the exact kernel Image, configuration, DTB, AIC8800 modules, firmware, source commits, stage implementation, and persistent signing public key. An existing signed bundle is reused only when that fingerprint, bundle hash, archive structure, manifest format, and kernel release all match. Cache metadata remains under ignored `build/cache/`; incomplete or failed builds never publish new successful cache state.

## Image build mode

With `BUILD_MODE=image`, the wrapper runs the complete image pipeline including Stages 10, 15, 20, 22, 25, 27, 30, 40, 45, 50, 60, 70, and 80.

With `OUTPUT_MODE=device`, the wrapper operates on the explicitly verified whole removable disk in `TARGET_DEVICE` and completely erases it. Interactive menu option 2 asks for the whole target block-device path before launching the build. The destructive-write confirmation remains enforced unless the documented non-interactive confirmation mechanism is explicitly supplied.

With `OUTPUT_MODE=etcher-image`, the wrapper creates a sparse raw disk image directly under `/home/psi/`, attaches it through a temporary loop device with partition scanning, and passes that device through the same Stages 50 through 80. The current default image size is 4 GiB; `IMAGE_SIZE_GIB` can select a different whole-number size of at least 4 GiB.

For the current kernel pin, successful compressed output is named from `LINUX_REF`, for example:

```text
/home/psi/cubie-a5e-debian13-linux6.18.45-<build-id>.img.xz
/home/psi/cubie-a5e-debian13-linux6.18.45-<build-id>.img.xz.sha256
```

The wrapper removes the temporary raw `.img` after successful compression. If an Etcher-image build fails, it first detaches any active loop device and then removes that build's incomplete `.img`, `.img.xz`, and checksum artifacts. This prevents stale or partial image output from being mistaken for a successful build or reused by the next run.

When an Etcher image is flashed to a larger SD card or SSD, the enabled `cubie-a5e-grow-rootfs.service` runs on first boot. It verifies that the ext4 root filesystem is on final partition 3, expands that partition to the remaining capacity with `growpart`, and expands the filesystem with `resize2fs`. The service records completion only after both operations succeed; if the live kernel cannot reread a changed partition table, the next boot retries safely. Stage 80 verifies the required packages, commands, helper, enabled service, absent completion marker, and minimum root-filesystem free-space headroom before image compression.

## Signed kernel and board update mode

With `BUILD_MODE=update-bundle`, the wrapper runs Stages 10, 20, 22, 25, 27, 30, 40, and 45. It builds and signs the kernel/board update bundle without running the rootfs or target-writing Stages 15 and 50 through 80.

The persistent private update-signing key stays under ignored `build/update-signing/`. It is never installed into the generated image and must never be committed to Git. The corresponding public verification key is installed into the image so `cubie-a5e-update` can reject unsigned or modified bundles.

The Stage 45 signed manifest records the managed kernel release plus source provenance, including the pinned Linux base ref/commit, final kernel tree commit, AIC source ref/commit, and payload hashes. The signed bundle remains the controlled delivery path for Cubie-specific kernel, DTB, AIC8800 module, and related board updates.

## Installed update policy

The installed `rsetup` wrapper keeps two update paths separate:

```text
Full Debian/Radxa system upgrade
    -> apt-get update
    -> apt-get full-upgrade

Cubie A5E signed kernel and board updates
    -> cubie-a5e-update
```

The managed-kernel APT preference prevents a normal Debian/Radxa `full-upgrade` from replacing the tested Cubie kernel with a generic distribution kernel. SPI bootloader flashing and SD-to-NVMe migration remain explicit board-maintenance operations rather than automatic package-upgrade actions.

## SD-to-NVMe migration

The installed `rsetup` wrapper exposes a guarded **Install the current Cubie A5E system to NVMe** operation. `assets/cubie-a5e-install-nvme` treats the repository's partition-3 root/boot layout as a hard contract: it identifies the live source from `/`, verifies partition 3 is final and the running managed kernel/initramfs/DTB/extlinux/fstab/PCIe-initramfs state is coherent with no pending update, accepts only a whole writable NVMe namespace, rejects mounted/swap targets and undersized devices, validates the installed on-board SPI U-Boot version, preserves the Radxa pre-root boot-chain area, recreates partition 3 to the NVMe capacity with a fresh ext4 UUID, performs a metadata-preserving two-pass filesystem copy, rewrites the managed UUID consumers, and verifies GPT/ext4/kernel/initramfs/DTB/update-layout state before success.

The SPI/U-Boot validation intentionally avoids early-exit `grep -q` pipelines under `set -o pipefail`; this prevents a successful firmware match from being misreported as a failure because an upstream command receives SIGPIPE. The repository validator rejects regression to the unsafe pipeline form.

Standalone NVMe boot was validated on the Linux 6.16 board baseline with Radxa SPI U-Boot 2018.07-17 and root on `/dev/nvme0n1p3`. It must be revalidated after the Linux 6.18.45 migration before the LTS baseline is declared complete.

## Linux 6.18.45 acceptance gate

The migration is complete only after a newly built image passes Stage 80 and the physical board confirms at least:

```text
uname -r                       -> 6.18.45+cubie-a5e...
systemctl --failed             -> 0 failed units
eth0                           -> present and usable
eth1                           -> present and usable
wlan0                          -> present; AIC8800 loads cleanly
SPI NOR                        -> readable at the validated 20 MHz DT setting
NVMe                           -> detected through the retained PCIe port
rsetup self-test               -> PASS
signed update integration      -> PASS
SD-to-NVMe migration           -> PASS or revalidated from a fresh test media
standalone NVMe boot           -> PASS with the SD card removed
```

Until those physical checks pass, Linux 6.18.45 is the repository's migration target, not the final hardware-validated production baseline.
