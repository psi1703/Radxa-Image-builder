Radxa Cubie A5E — Debian 13 / Linux 6.16 image builder

This repository rebuilds the hardware-validated Cubie A5E image from a clean clone. It preserves Radxa's known-good boot chain, replaces the vendor userspace with Debian 13, builds a single Linux 6.16 kernel, backports GMAC200 support, and builds the Radxa AIC8800 SDIO driver.

The validated board result is:

Device

Linux name

Policy

GMAC0

eth0

NetworkManager-managed

GMAC1 / GMAC200

eth1

NetworkManager-managed

AIC8800 SDIO

wlan0

Managed, disconnected, no saved Wi-Fi profile

The image creates initbox with password, passwordless sudo, no forced password change, and no password expiry. Automatic root login is disabled. Stage 80 rejects an image that does not match this policy.

Repository layout

.
├── build-cubie-a5e.sh             # top-level wrapper
├── 10-...sh through 80-...sh      # ordered build and validation stages
├── base/                           # proven donor-image/rootfs writer
├── assets/                         # small board runtime assets committed to Git
├── config/source-pins.env          # upstream refs and donor checksum
├── lib/common.sh                   # shared shell helpers
├── tools/validate-repository.sh    # optional local source validation
└── build/                          # downloads, sources, rootfs, logs, keys; ignored

Everything produced after cloning stays under build/. No file from the old /home/psi/cubie-a5e-build layout is required.

Files added or replaced through the GitHub website may lose their executable bit. After each fresh clone, normalize the repository programs once:

chmod 0755 -- \
  ./*.sh \
  base/*.sh \
  lib/*.sh \
  tools/*.sh \
  assets/rsetup \
  assets/cubie-a5e-update \
  assets/ensure-radxa-trixie-repo

Host requirements

Debian or Ubuntu x86-64 host with sudo and Internet access

Approximately 40 GB free for sources, rootfs, objects and bundles

For direct writing: a removable SD card or SSD of at least 4 GB

For Etcher-image creation: enough free host storage for the generated image

Required packages and the arm64 cross toolchain are installed with apt-get. The selected target disk is completely erased. Inspect it before running:

lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS

Build directly to an SD card or SSD

git clone YOUR_GITHUB_REPOSITORY_URL cubie-a5e-image-builder
cd cubie-a5e-image-builder

chmod 0755 -- \
  ./*.sh \
  base/*.sh \
  lib/*.sh \
  tools/*.sh \
  assets/rsetup \
  assets/cubie-a5e-update \
  assets/ensure-radxa-trixie-repo

sudo env \
  OUTPUT_MODE=device \
  TARGET_DEVICE=/dev/sdX \
  CONFIRM_WRITE=1 \
  ./build-cubie-a5e.sh

Replace /dev/sdX with the verified removable device. Omit CONFIRM_WRITE=1 to require the interactive I-UNDERSTAND confirmation.

The first run downloads the official Radxa r7 donor image, verifies its published SHA-512, creates the Debian 13 arm64 rootfs, fetches pinned Linux/AIC8800 sources, builds, writes the target, and performs a clean read-only validation.

OUTPUT_MODE=device is the default. The wrapper accepts only a whole removable disk, displays its identity, and refuses known host-system disk paths. The selected device is completely erased.

Build a flashable Balena Etcher image

No SD card or SSD needs to be connected during this build:

sudo env \
  OUTPUT_MODE=etcher-image \
  IMAGE_SIZE_GIB=8 \
  ./build-cubie-a5e.sh

The wrapper creates a temporary loop device backed by a sparse raw image. Stages 50–80 use that block device and perform the same clean read-only validation as direct-device mode. Only after Stage 80 passes does the wrapper detach the loop device and compress the result.

The default outputs are:

build/images/cubie-a5e-debian13-linux6.16-<build-id>.img.xz
build/images/cubie-a5e-debian13-linux6.16-<build-id>.img.xz.sha256

The .img.xz is a complete disk image containing the Radxa boot chain and all three partitions. Select it directly in Balena Etcher and flash it to an SD card or SSD whose capacity is at least IMAGE_SIZE_GIB.

The default image size is 8 GiB. Set a different whole-number size of at least 4 GiB when required. The root partition is expanded to fill the image during Stage 50; flashing it to a larger drive does not automatically enlarge it beyond the image size.

To replace an existing output deliberately, set IMAGE_OVERWRITE=1. Image output is restricted to build/images/ so generated media cannot be mixed with version-controlled source.

To deliberately replace an incomplete or old generated rootfs:

sudo env \
  OUTPUT_MODE=device \
  TARGET_DEVICE=/dev/sdX \
  ROOTFS_REBUILD=1 \
  ./build-cubie-a5e.sh

Build only a signed update bundle

sudo env BUILD_MODE=update-bundle ./build-cubie-a5e.sh

The first bundle build creates a private update key at build/update-signing/cubie-a5e-update-private.pem. It is excluded by .gitignore. Back it up securely and never upload it to GitHub. Losing it prevents later devices from trusting bundles signed with a replacement identity.

Reproducible inputs

Input

Pin

Linux

tag v6.16, commit 038d61fd642278bab63ee8ef722c50d10ab01e8f

Radxa AIC8800

tag 5.0+git20260123.5f7be68d-7, commit 6e076049b719ac2ff7ce5c92786a680407b11cdb

Radxa donor

rsdk-r7, SHA-512 in config/source-pins.env

Stage 20 names and verifies all eight upstream Linux backport commit IDs before cherry-picking. A moved tag, missing commit, changed subject, or donor checksum mismatch stops the build.

Outputs

Logs: build/logs/<build-id>/

Kernel tree: build/linux-6.16-one-shot/

AIC8800 tree: build/aic8800-radxa/

Debian rootfs: build/rootfs/

Signed bundles: build/update-bundles/

Flashable images and checksums: build/images/

Signing identity: build/update-signing/ (private; never commit)

Validate repository contents

./tools/validate-repository.sh

The checker runs Bash parsing, ShellCheck when installed, manifest verification, executable-mode checks, large-file checks, and private-key/path-leak checks. The full hardware result is still established by Stage 80 on the written target.

Tested hardware state

The completed image was boot-tested with kernel 6.16.0+cubie-a5e.20260728T094708Z+: initbox login worked, ping and nano were present, systemd reported zero failed units, eth1 linked, and eth0/wlan0 were available under their expected names. See docs/VALIDATED-HARDWARE.md for the recorded result and docs/validated-build-report.txt for the earlier source-tree validation record.

No license has been selected for this repository. Add the intended license before publishing it for third-party reuse.
