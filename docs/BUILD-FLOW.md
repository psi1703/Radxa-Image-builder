Build flow and provenance

Stage

Role

Persistent output

10

Install host packages, download/check donor, fetch pinned sources

build/downloads, Linux and AIC trees

15

Create/reuse Debian 13 arm64 rootfs

build/rootfs

20

Apply eight pinned GMAC1/PCK600/SRAM upstream commits

modified disposable Linux tree

25

Apply and validate the board hardware DTS

kernel DTS/DTB inputs

30

Build Linux, DTBs and in-tree modules

kernel tree and release marker

40

Build and validate AIC8800 modules

AIC tree and module manifest

45

Create and sign the managed update bundle

build/update-bundles, local signing keys

50

Write the Radxa donor and replace partition 3 with Debian

physical target or image-backed loop device

60

Install kernel, firmware, packages, login policy and rsetup

physical target or image-backed loop device

70

Install deterministic interface/network policy

physical target or image-backed loop device

80

Clean read-only target validation

validation report and evidence

The official donor is used only for the board's boot chain and narrow Radxa runtime payload. The generated Debian rootfs remains the source of PID1 and the core userspace. The base writer explicitly validates Debian 13 systemd linkage to prevent vendor Debian 11 libraries from replacing it.

Large artifacts are reproducible downloads or generated outputs and are intentionally absent from Git. The small assets/ files are the exact board/runtime inputs consumed by Stages 60–80.

For OUTPUT_MODE=device, the stages operate on the verified removable disk in TARGET_DEVICE. For OUTPUT_MODE=etcher-image, the wrapper creates a sparse raw image under build/images/, attaches it with partition scanning, and passes the resulting loop device through the same stages. The wrapper detaches and compresses the image to .img.xz only after Stage 80 succeeds.
