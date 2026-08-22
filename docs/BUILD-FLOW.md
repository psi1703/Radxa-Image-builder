# Build flow and provenance

The repository has one user-facing build entry point:

```text
build-cubie-a5e.sh
```

When run interactively without explicit build-selection environment variables, the wrapper presents the build manager menu. The same script remains automation-friendly: explicit `BUILD_MODE`, `OUTPUT_MODE`, `TARGET_DEVICE`, and rebuild variables bypass the menu and run the requested build directly.

The numbered stage scripts remain separate so that the pipeline is deterministic, independently testable, and rerunnable where appropriate.

## Stage sequence

| Stage | Role | Persistent output |
| --- | --- | --- |
| 10 | Install host packages, verify the Radxa donor image, refresh declared pins, and reuse or recreate validated source/build caches | `build/downloads/`, Linux tree, AIC8800 tree, and `build/cache/` |
| 15 | Create or reuse the Debian 13 Arm64 rootfs | `build/rootfs/` |
| 20 | Apply the pinned GMAC/regulator/PCK600/SRAM/syscon backports required by the current managed kernel baseline | Modified disposable Linux tree |
| 22 | Apply and validate the Cubie A5E PCIe backport required for NVMe support | Modified disposable Linux tree |
| 25 | Apply and validate the Cubie A5E hardware DTS | Kernel DTS and DTB inputs |
| 27 | Apply and validate the Cubie A5E SPI support required by the current managed kernel baseline | Modified disposable Linux tree |
| 30 | Reuse hash-validated kernel outputs or build Linux, DTBs, and in-tree modules, then record successful cache state | Kernel tree, release marker, and kernel cache metadata |
| 40 | Reuse hash-validated AIC8800 outputs or build and validate the SDIO modules, then record successful cache state | AIC8800 tree, module manifest, and AIC8800 cache metadata |
| 45 | Reuse an exact validated bundle or create and sign the managed kernel/board update bundle | `build/update-bundles/`, bundle cache metadata, and local signing identity |
| 50 | Write the Radxa donor disk layout, replace partition 3 with Debian 13, and expand it to the selected target or image size | Physical target or image-backed loop device |
| 60 | Install the managed kernel, DTB, firmware, packages, login policy, signed updater, `rsetup`, guarded SD-to-NVMe migration helper, and first-boot root-filesystem expansion service | Physical target or image-backed loop device |
| 70 | Install the deterministic interface naming and NetworkManager policy | Physical target or image-backed loop device |
| 80 | Perform clean, read-only target validation, including managed-kernel state, update integration, NVMe migration integration, expansion service, and free-space checks | Validation report and evidence |

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

The standalone `cubie-build-menu.sh` wrapper is intentionally not used. Menu handling, automation dispatch, stage selection, logging, cleanup, and build execution all remain in `build-cubie-a5e.sh`.

For non-interactive automation, explicit environment variables bypass the menu. Examples:

```bash
sudo env OUTPUT_MODE=etcher-image ./build-cubie-a5e.sh
sudo env BUILD_MODE=update-bundle ./build-cubie-a5e.sh
sudo env BUILD_MODE=update-bundle KERNEL_REBUILD=1 AIC_REBUILD=1 ./build-cubie-a5e.sh
sudo env OUTPUT_MODE=device TARGET_DEVICE=/dev/sdX ./build-cubie-a5e.sh
```

A non-interactive invocation without an explicit build selection is rejected rather than silently falling through to a default destructive device write.

## Provenance policy

The official Radxa donor image supplies only the board's known-good boot chain and narrowly selected Radxa runtime payload. The generated Debian 13 rootfs remains the source of PID 1 and the core userspace. The base writer validates Debian 13 systemd linkage so vendor Debian 11 libraries cannot silently replace it.

Large inputs and build products are reproducible downloads or generated outputs and are intentionally excluded from Git. The small files under `assets/` are the exact board-specific runtime inputs consumed by the installation and validation stages.

Linux, AIC8800, the Radxa BSP sources, the donor image, bootloader maintenance packages, and required backport commits are pinned and verified before use. A missing commit, changed expected commit, moved source ref, or donor checksum mismatch stops the build.

## Cache and rebuild policy

The wrapper calculates a stable kernel-input fingerprint before running the stages. It includes the declared Linux repository/ref/commit, kernel-related stages, the selected kernel configuration and its content, the Arm64 compiler/linker/assembler identities, the device-tree compiler, `make`, `pahole`, and the kernel local version. The default local version is derived from those inputs rather than from the timestamped image `BUILD_ID`.

Stage 10 always refreshes and verifies the declared Git pins. It preserves the existing Linux tree when `build/cache/kernel-build.env`, the pinned baseline ancestry, the configured local version, the compiled release, and the recorded hashes for the kernel Image, board DTB, configuration, `Module.symvers`, and `vmlinux` all agree. For the one-time transition from an older non-caching builder, an existing tree without cache metadata may be retained only when it has no interrupted Git operation, descends from the exact pinned baseline, has the required backport state, a valid configuration, and all required compiled outputs. That transition is treated as an incremental cache miss: Stage 30 still applies the stable local version, runs `make`, validates every normal output, and records the first successful cache state. All other missing or invalid states recreate the Linux tree from the declared pin. `KERNEL_REBUILD=1` forces that clean path and invalidates dependent AIC8800 cache state.

Stage 30 repeats the kernel cache checks before using compiled output. A cache hit runs the existing configuration, output, and board-DTB validation gates without recompiling. A miss performs the required clean or incremental `make` operation and writes cache metadata atomically only after every validation succeeds.

The AIC8800 fingerprint depends on the kernel fingerprint, declared AIC8800 source pin, cross-compiler, and Stage 40. Stages 10 and 40 verify the pinned AIC8800 commit, kernel release, module hashes, BSP symbol/version data, compiler flags, vermagic, and imported-symbol policy before reuse. `AIC_REBUILD=1` forces only the external module rebuild; `KERNEL_REBUILD=1` forces both kernel and AIC8800 rebuilds.

Stage 45 fingerprints the exact kernel Image, configuration, DTB, AIC8800 modules, firmware, source commits, stage implementation, and persistent signing public key. An existing signed bundle is reused only when that fingerprint, bundle hash, archive structure, and manifest version/release all match. Cache metadata remains under ignored `build/cache/`; incomplete or failed builds never publish new successful cache state.

## Image build mode

With `BUILD_MODE=image`, the wrapper runs the complete image pipeline including Stages 10, 15, 20, 22, 25, 27, 30, 40, 45, 50, 60, 70, and 80.

With `OUTPUT_MODE=device`, the wrapper operates on the explicitly verified whole removable disk in `TARGET_DEVICE` and completely erases it. Interactive menu option 2 asks for the whole target block-device path before launching the build. The destructive-write confirmation remains enforced unless the documented non-interactive confirmation mechanism is explicitly supplied.

With `OUTPUT_MODE=etcher-image`, the wrapper creates a sparse raw disk image directly under `/home/psi/`, attaches it through a temporary loop device with partition scanning, and passes that device through the same Stages 50 through 80. The current default image size is 4 GiB; `IMAGE_SIZE_GIB` can select a different whole-number size of at least 4 GiB. The wrapper detaches the loop device and compresses the validated result to `/home/psi/cubie-a5e-debian13-linux6.16-<build-id>.img.xz` only after Stage 80 succeeds, writes the adjacent `.sha256` file, and removes the temporary raw image after successful compression. Image output is restricted to `/home/psi/`.

If an Etcher-image build fails, the wrapper first detaches any active loop device and then removes the current build's incomplete `.img`, `.img.xz`, and checksum artifacts. This prevents stale or partial image output from being mistaken for a successful build or reused by the next run.

When an Etcher image is flashed to a larger SD card or SSD, the enabled `cubie-a5e-grow-rootfs.service` runs on first boot. It verifies that the ext4 root filesystem is on final partition 3, expands that partition to the remaining capacity with `growpart`, and expands the filesystem with `resize2fs`. The service records completion only after both operations succeed; if the live kernel cannot reread a changed partition table, the next boot retries safely. Stage 80 verifies the required packages, commands, helper, enabled service, absent completion marker, and minimum root-filesystem free-space headroom before image compression.

## Signed kernel and board update mode

With `BUILD_MODE=update-bundle`, the wrapper runs Stages 10, 20, 22, 25, 27, 30, 40, and 45. It builds and signs the kernel/board update bundle without running the rootfs or target-writing Stages 15 and 50 through 80.

The persistent private update-signing key stays under ignored `build/update-signing/`. It is never installed into the generated image and must never be committed to Git. The corresponding public verification key is installed into the image so `cubie-a5e-update` can reject unsigned or modified bundles.

The signed bundle remains the controlled delivery path for Cubie-specific kernel, DTB, AIC8800 module, and related board updates. It is intentionally separate from normal Debian/Radxa package maintenance.

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

The SPI/U-Boot validation intentionally avoids early-exit `grep -q` pipelines under `set -o pipefail`; this prevents a successful firmware match from being misreported as a failure because an upstream command receives SIGPIPE.

Standalone NVMe boot has been validated with the updated on-board Radxa SPI U-Boot and the root filesystem on `/dev/nvme0n1p3`.

## Future managed-kernel migration

The current repository remains pinned to the validated Linux 6.16 baseline until the dedicated LTS migration is completed. The planned next kernel baseline is Linux 6.18.y LTS. That migration is intentionally separate from this cleanup so each existing Cubie backport can be checked against 6.18 and removed when already upstream rather than carried forward unnecessarily.
