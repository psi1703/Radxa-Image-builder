[BUILD-FLOW.md](https://github.com/user-attachments/files/31264583/BUILD-FLOW.md)
# Build flow and provenance

| Stage | Role | Persistent output |
| --- | --- | --- |
| 10 | Install host packages, verify the Radxa donor image, refresh declared pins, and reuse or recreate validated source/build caches | `build/downloads/`, Linux tree, AIC8800 tree, and `build/cache/` |
| 15 | Create or reuse the Debian 13 Arm64 rootfs | `build/rootfs/` |
| 20 | Apply nine pinned upstream backports for the AXP313 regulator, PCK600, GMAC200, and SRAM/syscon support | Modified disposable Linux tree |
| 25 | Apply and validate the Cubie A5E hardware DTS | Kernel DTS and DTB inputs |
| 30 | Reuse hash-validated kernel outputs or build Linux, DTBs, and in-tree modules, then record successful cache state | Kernel tree, release marker, and kernel cache metadata |
| 40 | Reuse hash-validated AIC8800 outputs or build and validate the SDIO modules, then record successful cache state | AIC8800 tree, module manifest, and AIC8800 cache metadata |
| 45 | Reuse an exact validated bundle or create and sign the managed kernel/vendor update bundle | `build/update-bundles/`, bundle cache metadata, and local signing identity |
| 46 | Build `cubie-a5e-board-support` and `cubie-a5e-kernel-update` Debian packages, generate the flat APT index, and sign its Release metadata | `build/apt-repository/` and persistent `build/apt-signing/` identity |
| 50 | Write the Radxa donor disk layout, replace partition 3 with Debian 13, and expand it to the selected target or image size | Physical target or image-backed loop device |
| 60 | Install the kernel, DTB, firmware, packages, login policy, updater, `rsetup`, guarded SD-to-NVMe migration helper, APT-managed board/kernel packages, and first-boot root-filesystem expansion service | Physical target or image-backed loop device |
| 70 | Install the deterministic interface and NetworkManager policy | Physical target or image-backed loop device |
| 80 | Perform clean, read-only target validation, including the NVMe migration integration, expansion service, and free-space checks | Validation report and evidence |

## Provenance policy

The official Radxa donor image supplies only the board's known-good boot chain and narrowly selected Radxa runtime payload. The generated Debian 13 rootfs remains the source of PID 1 and the core userspace. The base writer validates Debian 13 systemd linkage so vendor Debian 11 libraries cannot silently replace it.

Large inputs and build products are reproducible downloads or generated outputs and are intentionally excluded from Git. The small files under `assets/` are the exact board-specific runtime inputs consumed by the installation and validation stages.

Linux, AIC8800, the donor image, and all nine Linux backports are pinned and verified before use. A missing commit, changed commit subject, moved source ref, or donor checksum mismatch stops the build.

## Cache and rebuild policy

The wrapper calculates a stable kernel-input fingerprint before running the stages. It includes the declared Linux repository/ref/commit, Stages 10/20/25/30, the selected kernel configuration and its content, the Arm64 compiler/linker/assembler identities, the device-tree compiler, `make`, `pahole`, and the kernel local version. The default local version is derived from those inputs rather than from the timestamped image `BUILD_ID`.

Stage 10 always refreshes and verifies the declared Git pins. It preserves the existing Linux tree when `build/cache/kernel-build.env`, the pinned baseline ancestry, the configured local version, the compiled release and the recorded hashes for the kernel Image, board DTB, configuration, `Module.symvers` and `vmlinux` all agree. For the one-time transition from the older non-caching builder, an existing tree without cache metadata may be retained only when it has no interrupted Git operation, descends from the exact pinned baseline, has a complete backport stamp, a valid configuration, and all required compiled outputs. That transition is treated as an incremental cache miss: Stage 30 still applies the stable local version, runs `make`, validates every normal output, and records the first successful cache state. All other missing or invalid states recreate the Linux tree from the declared pin. `KERNEL_REBUILD=1` forces that clean path and invalidates dependent AIC8800 cache state.

Stage 30 repeats the kernel cache checks before using compiled output. A cache hit runs the existing configuration, output and board-DTB validation gates without recompiling. A miss performs the required clean or incremental `make` operation and writes cache metadata atomically only after every validation succeeds.

The AIC8800 fingerprint depends on the kernel fingerprint, declared AIC8800 source pin, cross-compiler and Stage 40. Stages 10 and 40 verify the pinned AIC8800 commit, kernel release, module hashes, BSP symbol/version data, compiler flags, vermagic and imported-symbol policy before reuse. `AIC_REBUILD=1` forces only the external module rebuild; `KERNEL_REBUILD=1` forces both kernel and AIC8800 rebuilds.

Stage 45 fingerprints the exact kernel Image, configuration, DTB, AIC8800 modules, firmware, source commits, stage implementation and persistent bundle-signing public key. An existing signed bundle is reused only when that fingerprint, bundle hash, archive structure and manifest version/release all match. Stage 46 packages that signed bundle without weakening its validation: `cubie-a5e-kernel-update` invokes the existing updater from its package post-install step, while `cubie-a5e-board-support` owns the updater/runtime and APT trust configuration. The flat APT repository has a separate persistent GPG archive-signing identity. Cache metadata remains under ignored `build/cache/`; incomplete or failed builds never publish new successful cache state.

## Build modes

With `BUILD_MODE=image`, the wrapper runs all stages. `OUTPUT_MODE=device` operates on the verified whole removable disk in `TARGET_DEVICE` and completely erases it.

With `OUTPUT_MODE=etcher-image`, the wrapper creates a sparse raw disk image directly under `/home/psi/`, attaches it through a temporary loop device with partition scanning, and passes that device through the same Stages 50 through 80. The default image size is 4 GiB; `IMAGE_SIZE_GIB` can select a different whole-number size of at least 4 GiB. The wrapper detaches the loop device and compresses the validated result to `/home/psi/cubie-a5e-debian13-linux6.16-<build-id>.img.xz` only after Stage 80 succeeds, writes the adjacent `.sha256` file, and removes the temporary raw image after successful compression. Image output is restricted to `/home/psi/`.

When an Etcher image is flashed to a larger SD card or SSD, the enabled `cubie-a5e-grow-rootfs.service` runs on first boot. It verifies that the ext4 root filesystem is on final partition 3, expands that partition to the remaining capacity with `growpart`, and expands the filesystem with `resize2fs`. The service records completion only after both operations succeed; if the live kernel cannot reread a changed partition table, the next boot retries safely. Stage 80 verifies the required packages, commands, helper, enabled service, absent completion marker, and minimum root-filesystem free-space headroom before image compression.

The installed `rsetup` wrapper also exposes a guarded **Install the current Cubie A5E system to NVMe** operation. `assets/cubie-a5e-install-nvme` treats the repository's partition-3 root/boot layout as a hard contract: it identifies the live source from `/`, verifies partition 3 is final and the running managed kernel/initramfs/DTB/extlinux/fstab/PCIe-initramfs state is coherent with no pending update, accepts only a whole writable NVMe namespace, rejects mounted/swap targets and undersized devices, preserves the Radxa pre-root boot-chain area, recreates partition 3 to the NVMe capacity with a fresh ext4 UUID, performs a metadata-preserving two-pass filesystem copy, rewrites the managed UUID consumers, and verifies GPT/ext4/kernel/initramfs/DTB/update-layout state before success. Standalone NVMe boot still depends on compatible Cubie A5E SPI boot firmware.

With `BUILD_MODE=update-bundle`, the wrapper runs Stages 10 and 20 through 46. It builds and signs the kernel/vendor update bundle, produces the board-support and kernel-update Debian packages, and regenerates the signed flat APT repository without running the target-writing Stages 50 through 80.

On an installed board, a configured Cubie update channel can therefore be consumed by normal `apt-get full-upgrade` or by the rsetup full-system-upgrade menu. The kernel package still delegates activation to `cubie-a5e-update`, so a new kernel remains pending until a successful reboot finalizes it. SPI bootloader flashing and NVMe migration remain explicit rsetup operations and are never triggered by package upgrade.

The persistent private bundle-signing key stays under ignored `build/update-signing/`, and the persistent APT archive-signing identity stays under ignored `build/apt-signing/`. Neither private key is installed into the generated image and neither may be committed to Git.
