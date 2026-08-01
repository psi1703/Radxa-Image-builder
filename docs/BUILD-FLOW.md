# Build flow and provenance

| Stage | Role | Persistent output |
|---|---|---|
| 10 | Install host packages, download/check donor, fetch pinned sources | `build/downloads`, Linux and AIC trees |
| 15 | Create/reuse Debian 13 arm64 rootfs | `build/rootfs` |
| 20 | Apply eight pinned GMAC1/PCK600/SRAM upstream commits | modified disposable Linux tree |
| 25 | Apply and validate the board hardware DTS | kernel DTS/DTB inputs |
| 30 | Build Linux, DTBs and in-tree modules | kernel tree and release marker |
| 40 | Build and validate AIC8800 modules | AIC tree and module manifest |
| 45 | Create and sign the managed update bundle | `build/update-bundles`, local signing keys |
| 50 | Write the Radxa donor and replace partition 3 with Debian | target media |
| 60 | Install kernel, firmware, packages, login policy and `rsetup` | target media |
| 70 | Install deterministic interface/network policy | target media |
| 80 | Clean read-only target validation | validation report and evidence |

The official donor is used only for the board's boot chain and narrow Radxa runtime payload. The generated Debian rootfs remains the source of PID1 and the core userspace. The base writer explicitly validates Debian 13 systemd linkage to prevent vendor Debian 11 libraries from replacing it.

Large artifacts are reproducible downloads or generated outputs and are intentionally absent from Git. The small `assets/` files are the exact board/runtime inputs consumed by Stages 60–80.
