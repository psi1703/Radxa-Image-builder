# Radxa Cubie A5E Debian 13 / Linux 6.16 Image Builder

This repository rebuilds the hardware-validated Radxa Cubie A5E image from a clean clone. It preserves Radxa's known-good boot chain, replaces the vendor userspace with Debian 13, builds a single Linux 6.16 kernel, backports the required GMAC200 and regulator support, and builds the Radxa AIC8800 SDIO driver.

The builder supports two image output paths:

- Write directly to a removable SD card or SSD.
- Create a complete compressed `.img.xz` disk image for Balena Etcher.

It can also build a signed kernel/vendor update bundle without writing a target device.

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
├── build-cubie-a5e.sh             # top-level build wrapper
├── 10-...sh through 80-...sh      # ordered build and validation stages
├── base/                           # donor-image and Debian rootfs writer
├── assets/                         # small board runtime assets tracked by Git
├── config/source-pins.env          # pinned upstream refs and donor checksum
├── docs/                           # build flow and validated hardware record
├── lib/common.sh                   # shared shell helpers
├── tools/validate-repository.sh    # optional local source validation
└── build/                          # downloads, sources, outputs, logs and keys
```

Everything produced after cloning stays under the ignored `build/` directory. No file from the old `/home/psi/cubie-a5e-build` layout is required.

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
  assets/ensure-radxa-trixie-repo
```

## Host requirements

- Debian or Ubuntu x86-64 build host with `sudo` and Internet access.
- Approximately 40 GB of free space for downloads, source trees, rootfs, build objects and bundles.
- For direct writing, a removable SD card or SSD of at least 4 GiB.
- For Etcher-image creation, enough host storage for the raw working image and compressed output.

Required host packages and the Arm64 cross toolchain are installed with `apt-get`.

## Write directly to an SD card or SSD

The selected device is completely erased. Inspect it before starting:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
```

Then run:

```bash
sudo env \
  OUTPUT_MODE=device \
  TARGET_DEVICE=/dev/sdX \
  CONFIRM_WRITE=1 \
  ./build-cubie-a5e.sh
```

Replace `/dev/sdX` with the verified whole removable device. `OUTPUT_MODE=device` is the default. The wrapper displays the device identity and rejects known host-system disk paths.

Omit `CONFIRM_WRITE=1` if you want the interactive `I-UNDERSTAND` confirmation instead.

## Create a Balena Etcher image

No SD card or SSD needs to be connected:

```bash
sudo env \
  OUTPUT_MODE=etcher-image \
  IMAGE_SIZE_GIB=8 \
  ./build-cubie-a5e.sh
```

The wrapper creates a sparse raw image and attaches it to a temporary loop device. Stages 50 through 80 use that loop device and perform the same target validation as direct-device mode. The wrapper detaches and compresses the image only after Stage 80 passes.

Successful output:

```text
build/images/cubie-a5e-debian13-linux6.16-<build-id>.img.xz
build/images/cubie-a5e-debian13-linux6.16-<build-id>.img.xz.sha256
```

The `.img.xz` is a complete disk image containing the Radxa boot chain and all three partitions. Select it directly in Balena Etcher and flash it to an SD card or SSD whose capacity is at least `IMAGE_SIZE_GIB`.

The default image size is 8 GiB. A different whole-number size of at least 4 GiB can be selected. Stage 50 expands the root partition to fill the generated image, but flashing that image to a larger drive does not automatically expand it beyond the selected image size.

To replace an existing image output deliberately, set `IMAGE_OVERWRITE=1`. Image output is restricted to `build/images/`.

## Rebuild the Debian rootfs

The builder normally reuses a completed rootfs. To deliberately replace an incomplete or old generated rootfs:

```bash
sudo env \
  OUTPUT_MODE=device \
  TARGET_DEVICE=/dev/sdX \
  ROOTFS_REBUILD=1 \
  ./build-cubie-a5e.sh
```

## Build only a signed update bundle

```bash
sudo env BUILD_MODE=update-bundle ./build-cubie-a5e.sh
```

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
| Debian rootfs | `build/rootfs/` |
| Signed update bundles | `build/update-bundles/` |
| Flashable images and checksums | `build/images/` |
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
