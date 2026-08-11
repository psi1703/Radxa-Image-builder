# Build flow and provenance

| Stage | Role | Persistent output |
| --- | --- | --- |
| 10 | Install host packages, verify the Radxa donor image, and fetch pinned source trees | `build/downloads/`, Linux tree, and AIC8800 tree |
| 15 | Create or reuse the Debian 13 Arm64 rootfs | `build/rootfs/` |
| 20 | Apply nine pinned upstream backports for the AXP313 regulator, PCK600, GMAC200, and SRAM/syscon support | Modified disposable Linux tree |
| 25 | Apply and validate the Cubie A5E hardware DTS | Kernel DTS and DTB inputs |
| 30 | Build Linux, DTBs, and in-tree modules | Kernel tree and release marker |
| 40 | Build and validate the AIC8800 SDIO modules | AIC8800 tree and module manifest |
| 45 | Create and sign the managed kernel/vendor update bundle | `build/update-bundles/` and local signing identity |
| 50 | Write the Radxa donor disk layout and replace partition 3 with Debian 13 | Physical target or image-backed loop device |
| 60 | Install the kernel, DTB, firmware, packages, login policy, updater, and `rsetup` | Physical target or image-backed loop device |
| 70 | Install the deterministic interface and NetworkManager policy | Physical target or image-backed loop device |
| 80 | Perform clean, read-only target validation | Validation report and evidence |

## Provenance policy

The official Radxa donor image supplies only the board's known-good boot chain and narrowly selected Radxa runtime payload. The generated Debian 13 rootfs remains the source of PID 1 and the core userspace. The base writer validates Debian 13 systemd linkage so vendor Debian 11 libraries cannot silently replace it.

Large inputs and build products are reproducible downloads or generated outputs and are intentionally excluded from Git. The small files under `assets/` are the exact board-specific runtime inputs consumed by the installation and validation stages.

Linux, AIC8800, the donor image, and all nine Linux backports are pinned and verified before use. A missing commit, changed commit subject, moved source ref, or donor checksum mismatch stops the build.

## Build modes

With `BUILD_MODE=image`, the wrapper runs all stages. `OUTPUT_MODE=device` operates on the verified whole removable disk in `TARGET_DEVICE` and completely erases it.

With `OUTPUT_MODE=etcher-image`, the wrapper creates a sparse raw disk image under `build/images/`, attaches it through a temporary loop device with partition scanning, and passes that device through the same Stages 50 through 80. It detaches the loop device and compresses the validated result to `.img.xz` only after Stage 80 succeeds.

With `BUILD_MODE=update-bundle`, the wrapper runs Stages 10 and 20 through 45. It builds and signs the kernel/vendor update bundle without running the target-writing Stages 50 through 80.

The persistent private update-signing key stays under ignored `build/update-signing/`. It is never installed into the generated image and must never be committed to Git.
