#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="PCIE"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${JOBS:?JOBS is not set}"
: "${BSP_REPOSITORY:?BSP_REPOSITORY is not set}"
: "${BSP_REF:?BSP_REF is not set}"
: "${BSP_EXPECTED_COMMIT:?BSP_EXPECTED_COMMIT is not set}"

readonly EXPECTED_KERNEL_DIR="$BUILD_ROOT/linux-6.16-one-shot"
readonly GMAC1_STAMP="$KERNEL_DIR/.cubie-a5e-gmac1-upstream-backports"
readonly PCIE_STAMP="$KERNEL_DIR/.cubie-a5e-pcie-vendor-port"
readonly SOC_DTSI="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi"
readonly BOARD_DTS="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts"
readonly BOARD_DTB="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"
readonly CCU_DRIVER="$KERNEL_DIR/drivers/clk/sunxi-ng/ccu-sun55i-a523.c"
readonly CCU_HEADER="$KERNEL_DIR/drivers/clk/sunxi-ng/ccu-sun55i-a523.h"
readonly CLOCK_BINDING="$KERNEL_DIR/include/dt-bindings/clock/sun55i-a523-ccu.h"
readonly POWER_BINDING="$KERNEL_DIR/include/dt-bindings/power/allwinner,sun55i-a523-pck-600.h"
readonly PCIE_DIR="$KERNEL_DIR/drivers/pci/controller/sunxi"
readonly PHY_DRIVER="$KERNEL_DIR/drivers/phy/allwinner/phy-sunxi-inno-combophy.c"
TEMP_DIR="$(mktemp -d "$BUILD_ROOT/.pcie-port.XXXXXX")"
readonly TEMP_DIR

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly PCIE_REPORT="$LOG_DIR/pcie-backport-report.txt"
    readonly PCIE_DTS_REPORT="$LOG_DIR/pcie-compiled.dts"
else
    readonly PCIE_REPORT="$BUILD_ROOT/.one-shot-pcie-backport-report.txt"
    readonly PCIE_DTS_REPORT="$BUILD_ROOT/.one-shot-pcie-compiled.dts"
fi

cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

require_nonempty_file() {
    local path="$1"

    [[ -s "$path" ]] || die "Required file is missing or empty: $path"
}

completed_port_available() {
    [[ -s "$PCIE_STAMP" ]] || return 1
    grep -Fxq "bsp_commit=$BSP_EXPECTED_COMMIT" "$PCIE_STAMP" || return 1
    grep -Fxq 'dt_layout=mainline-soc-one-cell-v3' "$PCIE_STAMP" || return 1
    grep -Fxq 'driver_mode=initramfs-modules-v3' "$PCIE_STAMP" || return 1
    grep -Fxq 'status=complete' "$PCIE_STAMP" || return 1
    [[ -s "$BOARD_DTB" ]] || return 1
    [[ -s "$KERNEL_DIR/.config" ]] || return 1
    grep -Fxq 'CONFIG_AW_PCIE_RC=m' "$KERNEL_DIR/.config" || return 1
    grep -Fxq 'CONFIG_PHY_SUNXI_INNO_COMBOPHY=m' "$KERNEL_DIR/.config" || return 1
    grep -Fxq 'CONFIG_BLK_DEV_NVME=y' "$KERNEL_DIR/.config" || return 1

    return 0
}

fetch_vendor_commit() {
    local fetched_commit

    if git -C "$KERNEL_DIR" cat-file -e \
        "$BSP_EXPECTED_COMMIT^{commit}" 2>/dev/null; then
        log "Using cached pinned Radxa Allwinner BSP commit."
        return 0
    fi

    log "Fetching pinned Radxa Allwinner BSP source for PCIe."
    run git -C "$KERNEL_DIR" fetch \
        --no-tags \
        --depth=1 \
        "$BSP_REPOSITORY" \
        "$BSP_REF"

    fetched_commit="$(git -C "$KERNEL_DIR" rev-parse 'FETCH_HEAD^{commit}')"
    [[ "$fetched_commit" == "$BSP_EXPECTED_COMMIT" ]] ||
        die "BSP ref moved: expected $BSP_EXPECTED_COMMIT, found $fetched_commit"
}

extract_vendor_source() {
    local source_path="$1"
    local destination_path="$2"
    local expected_sha256="$3"
    local extracted_path="$TEMP_DIR/${source_path##*/}"
    local actual_sha256

    git -C "$KERNEL_DIR" show \
        "$BSP_EXPECTED_COMMIT:$source_path" >"$extracted_path" ||
        die "Could not extract pinned BSP source: $source_path"

    actual_sha256="$(sha256sum -- "$extracted_path" | awk '{print $1}')"
    [[ "$actual_sha256" == "$expected_sha256" ]] ||
        die "Pinned BSP source hash mismatch: $source_path"

    install -D -m 0644 -- "$extracted_path" "$destination_path"
}

extract_vendor_sources() {
    log "Extracting and verifying the vendor PCIe and combo-PHY sources."

    mkdir -p -- "$PCIE_DIR" "$(dirname -- "$PHY_DRIVER")"

    extract_vendor_source \
        drivers/pcie/pcie-sunxi-rc.c \
        "$PCIE_DIR/pcie-sunxi-rc.c" \
        398ae4be0332a534dbba4f3fa9be17694e31244de29be6d29dc55091359c51b6
    extract_vendor_source \
        drivers/pcie/pcie-sunxi-dma.c \
        "$PCIE_DIR/pcie-sunxi-dma.c" \
        2c491b72677591f741e12d1680506c0e4d8d61ab415dad9571c5095f8b380784
    extract_vendor_source \
        drivers/pcie/pcie-sunxi-dma.h \
        "$PCIE_DIR/pcie-sunxi-dma.h" \
        e9e00511e4c3d66f6b2b08ab1235acefa4064c0425f8da18493dd382f7555785
    extract_vendor_source \
        drivers/pcie/pcie-sunxi-plat.c \
        "$PCIE_DIR/pcie-sunxi-plat.c" \
        7ab33f8275279af5896069f65e625662f32bf1c3e91695b3a01f969a143b42aa
    extract_vendor_source \
        drivers/pcie/pcie-sunxi.h \
        "$PCIE_DIR/pcie-sunxi.h" \
        3b2b3f0e1c3bff3600f4b933ef905574309f53eb5ca76f27ea770ed4823dd2be
    extract_vendor_source \
        drivers/phy/sunxi-inno-combophy.c \
        "$PHY_DRIVER" \
        fe1e3fe9f697376cf27d14365846838f368cccb6519c130519daa2b842be2d6b
}

port_vendor_sources_to_v616() {
    log "Applying the reviewed Linux 6.16 compatibility port."

    export KERNEL_DIR PCIE_DIR PHY_DRIVER
    run python3 <<'PY'
from pathlib import Path
import os

kernel = Path(os.environ["KERNEL_DIR"])
pcie = Path(os.environ["PCIE_DIR"])
phy_path = Path(os.environ["PHY_DRIVER"])


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"PCIe port: expected one {description} anchor, found {count}"
        )
    return text.replace(old, new, 1)


log_header = """/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _SUNXI_PCIE_LOG_H_
#define _SUNXI_PCIE_LOG_H_

#include <linux/device.h>
#include <linux/printk.h>

#define sunxi_err(dev, fmt, ...) \\
	do { \\
		if (dev) \\
			dev_err(dev, fmt, ##__VA_ARGS__); \\
		else \\
			pr_err(fmt, ##__VA_ARGS__); \\
	} while (0)

#define sunxi_warn(dev, fmt, ...) \\
	do { \\
		if (dev) \\
			dev_warn(dev, fmt, ##__VA_ARGS__); \\
		else \\
			pr_warn(fmt, ##__VA_ARGS__); \\
	} while (0)

#define sunxi_info(dev, fmt, ...) \\
	do { \\
		if (dev) \\
			dev_info(dev, fmt, ##__VA_ARGS__); \\
		else \\
			pr_info(fmt, ##__VA_ARGS__); \\
	} while (0)

#define sunxi_debug(dev, fmt, ...) \\
	do { \\
		if (dev) \\
			dev_dbg(dev, fmt, ##__VA_ARGS__); \\
		else \\
			pr_debug(fmt, ##__VA_ARGS__); \\
	} while (0)

#endif /* _SUNXI_PCIE_LOG_H_ */
"""
(pcie / "sunxi-pcie-log.h").write_text(log_header, encoding="utf-8")

for filename in (
    "pcie-sunxi-rc.c",
    "pcie-sunxi-dma.c",
    "pcie-sunxi-plat.c",
):
    path = pcie / filename
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "#include <sunxi-log.h>",
        '#include "sunxi-pcie-log.h"',
        f"{filename} logging include",
    )
    path.write_text(text, encoding="utf-8")

rc_path = pcie / "pcie-sunxi-rc.c"
rc = rc_path.read_text(encoding="utf-8")
rc = replace_once(
    rc,
    "#include <linux/gpio.h>\n",
    "#include <linux/gpio.h>\n#include <linux/gpio/consumer.h>\n",
    "PCIe RC GPIO include",
)
rc = replace_once(
    rc,
    '#include "../drivers/bus/sunxi-nsi.h"',
    '#if IS_ENABLED(CONFIG_AW_NSI)\n'
    '#include "../drivers/bus/sunxi-nsi.h"\n'
    '#endif',
    "optional NSI include",
)
for old, new, name in (
    (
        "int sunxi_pcie_host_init(struct sunxi_pcie_port *pp)",
        "static int sunxi_pcie_host_init(struct sunxi_pcie_port *pp)",
        "host init linkage",
    ),
    (
        "void sunxi_pcie_host_change_nsi_port_bwl(struct sunxi_pcie *pci, int gen)",
        "static void sunxi_pcie_host_change_nsi_port_bwl(struct sunxi_pcie *pci, int gen)",
        "NSI helper linkage",
    ),
    (
        "int sunxi_pcie_host_read_speed(struct sunxi_pcie *pci)",
        "static int sunxi_pcie_host_read_speed(struct sunxi_pcie *pci)",
        "speed helper linkage",
    ),
):
    rc = replace_once(rc, old, new, name)
rc_path.write_text(rc, encoding="utf-8")

dma_header_path = pcie / "pcie-sunxi-dma.h"
dma_header = dma_header_path.read_text(encoding="utf-8")
dma_header = replace_once(
    dma_header,
    "int sunxi_pcie_dma_obj_remove(struct device *dev);\n",
    "int sunxi_pcie_dma_obj_remove(struct device *dev);\n"
    "int sunxi_pcie_edma_config_start(struct sunxi_pci_edma_chan *edma_chan);\n",
    "eDMA start prototype",
)
dma_header_path.write_text(dma_header, encoding="utf-8")

pcie_header_path = pcie / "pcie-sunxi.h"
pcie_header = pcie_header_path.read_text(encoding="utf-8")
pcie_header = replace_once(
    pcie_header,
    "#include <sunxi-gpio.h>\n",
    "",
    "vendor GPIO include",
)
pcie_header = replace_once(
    pcie_header,
    "#include <linux/pci-epf.h>\n",
    "#include <linux/pci-epf.h>\n#include <linux/version.h>\n",
    "kernel version include",
)
pcie_header_path.write_text(pcie_header, encoding="utf-8")

plat_path = pcie / "pcie-sunxi-plat.c"
plat = plat_path.read_text(encoding="utf-8")
plat = replace_once(
    plat,
    "#include <linux/gpio.h>\n",
    "#include <linux/gpio.h>\n#include <linux/gpio/consumer.h>\n",
    "PCIe platform GPIO include",
)
plat = replace_once(
    plat,
    """#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0)
static int sunxi_pcie_plat_remove(struct platform_device *pdev)
#else
static void sunxi_pcie_plat_remove(struct platform_device *pdev)
#endif
""",
    "static void sunxi_pcie_plat_remove(struct platform_device *pdev)\n",
    "platform remove declaration",
)
plat = replace_once(
    plat,
    """#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0)
	return 0;
#endif
}
""",
    "}\n",
    "platform remove return",
)
plat = replace_once(
    plat,
    """	.probe  = sunxi_pcie_plat_probe,
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0)
	.remove = sunxi_pcie_plat_remove,
#else
	.remove_new = sunxi_pcie_plat_remove,
#endif
""",
    "\t.probe  = sunxi_pcie_plat_probe,\n"
    "\t.remove = sunxi_pcie_plat_remove,\n",
    "platform driver remove callback",
)
plat_path.write_text(plat, encoding="utf-8")

phy = phy_path.read_text(encoding="utf-8")
phy = replace_once(
    phy,
    "#include <linux/module.h>\n",
    "#include <linux/module.h>\n#include <linux/notifier.h>\n",
    "combo-PHY notifier include",
)
phy = replace_once(
    phy,
    "#include <linux/phy/phy.h>\n",
    "#include <linux/phy/phy.h>\n#include <linux/platform_device.h>\n"
    "#include <linux/regulator/consumer.h>\n",
    "combo-PHY platform includes",
)
phy = replace_once(
    phy,
    '#include "sunxi-inno.h"\n',
    "",
    "unused vendor combo-PHY header",
)
phy = replace_once(
    phy,
    "static struct phy *sunxi_combphy_xlate(struct device *dev,\n"
    "\t\t\t\t\t  struct of_phandle_args *args)",
    "static struct phy *sunxi_combphy_xlate(struct device *dev,\n"
    "\t\t\t\t      const struct of_phandle_args *args)",
    "combo-PHY xlate signature",
)
phy = replace_once(
    phy,
    "static int sunxi_combphy_remove(struct platform_device *pdev)",
    "static void sunxi_combphy_remove(struct platform_device *pdev)",
    "combo-PHY remove declaration",
)
phy = replace_once(
    phy,
    "\t\treturn ret;\n\t}\n\n\t/* unregister inno power notifier */",
    "\t\treturn;\n\t}\n\n\t/* unregister inno power notifier */",
    "combo-PHY remove error return",
)
phy = replace_once(
    phy,
    "\tpm_runtime_set_suspended(dev);\n\n\treturn 0;\n}",
    "\tpm_runtime_set_suspended(dev);\n\n}",
    "combo-PHY remove success return",
)
phy_path.write_text(phy, encoding="utf-8")

(pcie / "Kconfig").write_text(
    """# SPDX-License-Identifier: GPL-2.0-only

config AW_PCIE_RC
	tristate "Allwinner vendor PCIe root complex controller"
	depends on ARCH_SUNXI || COMPILE_TEST
	depends on PCI_MSI
	select GENERIC_PHY
	help
	  Enable the Allwinner PCIe root-complex controller used by the
	  A523/A527/T527 family. This is required for the Cubie A5E M.2 NVMe
	  slot.
""",
    encoding="utf-8",
)
(pcie / "Makefile").write_text(
    """# SPDX-License-Identifier: GPL-2.0

ccflags-y += -I $(srctree)/drivers/pci/

pcie_sunxi_host-objs := pcie-sunxi-rc.o pcie-sunxi-dma.o pcie-sunxi-plat.o
obj-$(CONFIG_AW_PCIE_RC) += pcie_sunxi_host.o
""",
    encoding="utf-8",
)

controller_kconfig_path = kernel / "drivers/pci/controller/Kconfig"
controller_kconfig = controller_kconfig_path.read_text(encoding="utf-8")
controller_source = 'source "drivers/pci/controller/sunxi/Kconfig"'
if controller_source not in controller_kconfig:
    controller_kconfig = replace_once(
        controller_kconfig,
        "endmenu\n",
        controller_source + "\nendmenu\n",
        "PCI controller Kconfig end",
    )
controller_kconfig_path.write_text(controller_kconfig, encoding="utf-8")

controller_makefile_path = kernel / "drivers/pci/controller/Makefile"
controller_makefile = controller_makefile_path.read_text(encoding="utf-8")
controller_object = "obj-$(CONFIG_AW_PCIE_RC) += sunxi/"
if controller_object not in controller_makefile:
    controller_makefile = replace_once(
        controller_makefile,
        "obj-y\t\t\t\t+= dwc/\n",
        controller_object + "\n\nobj-y\t\t\t\t+= dwc/\n",
        "PCI controller Makefile DWC entry",
    )
controller_makefile_path.write_text(controller_makefile, encoding="utf-8")

phy_kconfig_path = kernel / "drivers/phy/allwinner/Kconfig"
phy_kconfig = phy_kconfig_path.read_text(encoding="utf-8")
if "config PHY_SUNXI_INNO_COMBOPHY" not in phy_kconfig:
    phy_kconfig = replace_once(
        phy_kconfig,
        "# Phy drivers for Allwinner platforms\n#\n",
        """# Phy drivers for Allwinner platforms
#
config PHY_SUNXI_INNO_COMBOPHY
	tristate "Allwinner Innosilicon PCIe/USB3 combo PHY"
	depends on ARCH_SUNXI || COMPILE_TEST
	depends on OF
	select GENERIC_PHY
	help
	  Enable the Innosilicon combo PHY used by the Allwinner A523/A527/T527
	  PCIe and USB3 subsystem.

""",
        "Allwinner PHY Kconfig heading",
    )
phy_kconfig_path.write_text(phy_kconfig, encoding="utf-8")

phy_makefile_path = kernel / "drivers/phy/allwinner/Makefile"
phy_makefile = phy_makefile_path.read_text(encoding="utf-8")
phy_object = (
    "obj-$(CONFIG_PHY_SUNXI_INNO_COMBOPHY) += phy-sunxi-inno-combophy.o"
)
if phy_object not in phy_makefile:
    phy_makefile = replace_once(
        phy_makefile,
        "# SPDX-License-Identifier: GPL-2.0-only\n",
        "# SPDX-License-Identifier: GPL-2.0-only\n" + phy_object + "\n",
        "Allwinner PHY Makefile heading",
    )
phy_makefile_path.write_text(phy_makefile, encoding="utf-8")
PY
}

add_usb3_reference_clock() {
    log "Adding the missing A523 USB3/PCIe 100 MHz reference clock."

    export CCU_DRIVER CCU_HEADER CLOCK_BINDING
    run python3 <<'PY'
from pathlib import Path
import os

driver_path = Path(os.environ["CCU_DRIVER"])
header_path = Path(os.environ["CCU_HEADER"])
binding_path = Path(os.environ["CLOCK_BINDING"])


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"PCIe clock: expected one {description} anchor, found {count}"
        )
    return text.replace(old, new, 1)


binding = binding_path.read_text(encoding="utf-8")
if "#define CLK_USB3_REF" not in binding:
    binding = replace_once(
        binding,
        "#define CLK_FANOUT2\t\t178\n",
        "#define CLK_FANOUT2\t\t178\n#define CLK_USB3_REF\t\t179\n",
        "clock binding tail",
    )
binding_path.write_text(binding, encoding="utf-8")

header = header_path.read_text(encoding="utf-8")
header = header.replace(
    "#define CLK_NUMBER\t(CLK_FANOUT2 + 1)",
    "#define CLK_NUMBER\t(CLK_USB3_REF + 1)",
)
if "#define CLK_NUMBER\t(CLK_USB3_REF + 1)" not in header:
    raise SystemExit("PCIe clock: CLK_NUMBER was not updated")
header_path.write_text(header, encoding="utf-8")

driver = driver_path.read_text(encoding="utf-8")
if "static SUNXI_CCU_M_DATA_WITH_MUX_GATE(usb3_ref_clk" not in driver:
    clock_block = """static const struct clk_parent_data usb3_ref_parents[] = {
	{ .fw_name = "hosc" },
	{ .hw = &pll_periph0_200M_clk.hw },
	{ .hw = &pll_periph1_200M_clk.hw },
};

static SUNXI_CCU_M_DATA_WITH_MUX_GATE(usb3_ref_clk, "usb3-ref",
				      usb3_ref_parents, 0xa84,
				      0, 5,
				      24, 3,
				      BIT(31),
				      0);

"""
    driver = replace_once(
        driver,
        "static SUNXI_CCU_M_DATA_WITH_MUX_GATE(pcie_aux_clk",
        clock_block + "static SUNXI_CCU_M_DATA_WITH_MUX_GATE(pcie_aux_clk",
        "PCIe auxiliary clock declaration",
    )

if "\t&usb3_ref_clk.common,\n" not in driver:
    driver = replace_once(
        driver,
        "\t&pcie_aux_clk.common,\n",
        "\t&usb3_ref_clk.common,\n\t&pcie_aux_clk.common,\n",
        "CCU common clock array",
    )

if "\t\t[CLK_USB3_REF]\t\t= &usb3_ref_clk.common.hw,\n" not in driver:
    driver = replace_once(
        driver,
        "\t\t[CLK_PCIE_AUX]\t\t= &pcie_aux_clk.common.hw,\n",
        "\t\t[CLK_USB3_REF]\t\t= &usb3_ref_clk.common.hw,\n"
        "\t\t[CLK_PCIE_AUX]\t\t= &pcie_aux_clk.common.hw,\n",
        "CCU hardware clock array",
    )

driver_path.write_text(driver, encoding="utf-8")
PY
}

add_pcie_device_tree() {
    log "Adding the A523 PCIe controller, combo-PHY and Cubie A5E supplies."

    export SOC_DTSI BOARD_DTS
    run python3 <<'PY'
from pathlib import Path
import os

soc_path = Path(os.environ["SOC_DTSI"])
board_path = Path(os.environ["BOARD_DTS"])
soc = soc_path.read_text(encoding="utf-8")
board = board_path.read_text(encoding="utf-8")

soc_begin = "/* CUBIE_A5E_PCIE_SOC_BEGIN */"
soc_end = "/* CUBIE_A5E_PCIE_SOC_END */"
board_begin = "/* CUBIE_A5E_PCIE_BOARD_BEGIN */"
board_end = "/* CUBIE_A5E_PCIE_BOARD_END */"


def remove_block(text: str, begin: str, end: str) -> str:
    while begin in text:
        start = text.index(begin)
        if end not in text[start:]:
            raise SystemExit(f"PCIe DTS: {begin} has no matching end marker")
        finish = text.index(end, start) + len(end)
        text = text[:start] + text[finish:]
    return text.rstrip() + "\n"


soc = remove_block(soc, soc_begin, soc_end)
board = remove_block(board, board_begin, board_end)

phy_include = "#include <dt-bindings/phy/phy.h>"
if phy_include not in soc:
    anchor = "#include <dt-bindings/interrupt-controller/arm-gic.h>"
    if anchor not in soc:
        raise SystemExit("PCIe DTS: PHY include anchor not found")
    soc = soc.replace(anchor, anchor + "\n" + phy_include, 1)

soc_block = r'''
/* CUBIE_A5E_PCIE_SOC_BEGIN */

&{/soc} {
	combophy: phy@4f00000 {
		compatible = "allwinner,inno-combphy";
		reg = <0x04f00000 0x00080000>,
		      <0x04f80000 0x00080000>;
		reg-names = "phy-ctl", "phy-clk";
		power-domains = <&pck600 PD_PCIE>;
		phy_refclk_sel = <0>;
		clocks = <&ccu CLK_USB3_REF>,
			 <&ccu CLK_PLL_PERIPH0_200M>;
		clock-names = "phyclk_ref", "refclk_par";
		resets = <&ccu RST_BUS_PCIE_USB3>;
		reset-names = "phy_rst";
		#phy-cells = <1>;
		status = "disabled";
	};

	pcie: pcie@4800000 {
		compatible = "allwinner,sunxi-pcie-v210-rc";
		#address-cells = <3>;
		#size-cells = <2>;
		bus-range = <0x00 0xff>;
		reg = <0x04800000 0x00480000>;
		reg-names = "dbi";
		device_type = "pci";
		ranges = <0x00000800 0 0x20000000 0x20000000 0 0x01000000>,
			 <0x81000000 0 0x21000000 0x21000000 0 0x01000000>,
			 <0x82000000 0 0x22000000 0x22000000 0 0x0e000000>;
		num-lanes = <1>;
		phys = <&combophy PHY_TYPE_PCIE>;
		phy-names = "pcie-phy";
		interrupts = <GIC_SPI 107 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 106 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 98 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 99 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 100 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 101 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 102 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 103 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 104 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 105 IRQ_TYPE_LEVEL_HIGH>;
		interrupt-names = "msi", "sii",
				  "edma-w0", "edma-w1", "edma-w2", "edma-w3",
				  "edma-r0", "edma-r1", "edma-r2", "edma-r3";
		#interrupt-cells = <1>;
		interrupt-map-mask = <0 0 0 7>;
		interrupt-map = <0 0 0 1 &pcie_intc 0>,
				<0 0 0 2 &pcie_intc 1>,
				<0 0 0 3 &pcie_intc 2>,
				<0 0 0 4 &pcie_intc 3>;
		num-edma = <4>;
		max-link-speed = <2>;
		num-ib-windows = <8>;
		num-ob-windows = <8>;
		linux,pci-domain = <0>;
		power-domains = <&pck600 PD_PCIE>;
		clocks = <&osc24M>, <&ccu CLK_PCIE_AUX>;
		clock-names = "hosc", "pclk_aux";
		status = "disabled";

		pcie_intc: legacy-interrupt-controller {
			interrupt-controller;
			#address-cells = <0>;
			#interrupt-cells = <1>;
		};
	};
};

/* CUBIE_A5E_PCIE_SOC_END */
'''

board_block = r'''
/* CUBIE_A5E_PCIE_BOARD_BEGIN */

/ {
	reg_pcie_3v3: pcie-3v3 {
		compatible = "regulator-fixed";
		regulator-name = "pcie-3v3";
		regulator-min-microvolt = <3300000>;
		regulator-max-microvolt = <3300000>;
		regulator-enable-ramp-delay = <1000>;
		regulator-always-on;
		regulator-boot-on;
		gpio = <&r_pio 0 11 GPIO_ACTIVE_HIGH>;
		enable-active-high;
	};

	/* The official BSP names this rail pcie-1v8 but fixes it at 3.3 V. */
	reg_pcie_1v8: pcie-1v8 {
		compatible = "regulator-fixed";
		regulator-name = "pcie-1v8";
		regulator-min-microvolt = <3300000>;
		regulator-max-microvolt = <3300000>;
		regulator-enable-ramp-delay = <1000>;
		regulator-always-on;
		regulator-boot-on;
	};
};

&combophy {
	phy_use_sel = <0>;
	status = "okay";
};

&pcie {
	reset-gpios = <&pio 7 11 GPIO_ACTIVE_HIGH>;
	wake-gpios = <&pio 7 12 GPIO_ACTIVE_HIGH>;
	clk-freq-100M;
	pcie3v3-supply = <&reg_pcie_3v3>;
	pcie1v8-supply = <&reg_pcie_1v8>;
	status = "okay";
};

/* CUBIE_A5E_PCIE_BOARD_END */
'''

soc_path.write_text(soc.rstrip() + "\n" + soc_block, encoding="utf-8")
board_path.write_text(board.rstrip() + "\n" + board_block, encoding="utf-8")
PY
}

validate_sources() {
    local required_files=(
        "$GMAC1_STAMP"
        "$SOC_DTSI"
        "$BOARD_DTS"
        "$CCU_DRIVER"
        "$CCU_HEADER"
        "$CLOCK_BINDING"
        "$POWER_BINDING"
        "$PCIE_DIR/Kconfig"
        "$PCIE_DIR/Makefile"
        "$PCIE_DIR/pcie-sunxi-rc.c"
        "$PCIE_DIR/pcie-sunxi-dma.c"
        "$PCIE_DIR/pcie-sunxi-dma.h"
        "$PCIE_DIR/pcie-sunxi-plat.c"
        "$PCIE_DIR/pcie-sunxi.h"
        "$PCIE_DIR/sunxi-pcie-log.h"
        "$PHY_DRIVER"
    )
    local path

    for path in "${required_files[@]}"; do
        require_nonempty_file "$path"
    done

    grep -Eq '^#define[[:space:]]+PD_PCIE[[:space:]]+7([[:space:]]|$)' \
        "$POWER_BINDING" || die "PD_PCIE power-domain binding is unavailable."
    grep -Eq '^#define[[:space:]]+CLK_USB3_REF[[:space:]]+179([[:space:]]|$)' \
        "$CLOCK_BINDING" || die "CLK_USB3_REF binding is missing or incorrect."
    grep -qF 'usb3_ref_clk, "usb3-ref"' "$CCU_DRIVER" ||
        die "USB3/PCIe reference clock implementation is missing."
    grep -qF 'config AW_PCIE_RC' "$PCIE_DIR/Kconfig" ||
        die "Allwinner PCIe root-complex Kconfig entry is missing."
    grep -qF 'allwinner,sunxi-pcie-v210-rc' "$PCIE_DIR/pcie-sunxi-plat.c" ||
        die "Allwinner v210 PCIe compatible is missing."
    grep -qF 'allwinner,inno-combphy' "$PHY_DRIVER" ||
        die "Allwinner combo-PHY compatible is missing."
    grep -qF 'pcie: pcie@4800000 {' "$SOC_DTSI" ||
        die "A523 PCIe controller node is missing."
    grep -qF 'combophy: phy@4f00000 {' "$SOC_DTSI" ||
        die "A523 combo-PHY node is missing."
    grep -qF 'reset-gpios = <&pio 7 11 GPIO_ACTIVE_HIGH>;' "$BOARD_DTS" ||
        die "Cubie A5E PCIe PERST GPIO must be PH11."
    grep -qF 'gpio = <&r_pio 0 11 GPIO_ACTIVE_HIGH>;' "$BOARD_DTS" ||
        die "Cubie A5E PCIe 3.3 V enable must be PL11."
    git -C "$KERNEL_DIR" diff --check ||
        die "Whitespace errors were detected after the PCIe port."
}

configure_and_compile_gate() {
    local scripts_config="$KERNEL_DIR/scripts/config"

    require_nonempty_file "$scripts_config"
    require_nonempty_file "$KERNEL_DIR/.config"

    log "Enabling and cross-compiling the PCIe, PHY and NVMe path."
    run "$scripts_config" --file "$KERNEL_DIR/.config" --enable PCI
    run "$scripts_config" --file "$KERNEL_DIR/.config" --enable PCI_MSI
    run "$scripts_config" --file "$KERNEL_DIR/.config" --module AW_PCIE_RC
    run "$scripts_config" --file "$KERNEL_DIR/.config" --module PHY_SUNXI_INNO_COMBOPHY
    run "$scripts_config" --file "$KERNEL_DIR/.config" --enable NVME_CORE
    run "$scripts_config" --file "$KERNEL_DIR/.config" --enable BLK_DEV_NVME

    run make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        olddefconfig

    grep -Fxq 'CONFIG_AW_PCIE_RC=m' "$KERNEL_DIR/.config" ||
        die "CONFIG_AW_PCIE_RC was not configured as a module."
    grep -Fxq 'CONFIG_PHY_SUNXI_INNO_COMBOPHY=m' "$KERNEL_DIR/.config" ||
        die "CONFIG_PHY_SUNXI_INNO_COMBOPHY was not configured as a module."
    grep -Fxq 'CONFIG_BLK_DEV_NVME=y' "$KERNEL_DIR/.config" ||
        die "CONFIG_BLK_DEV_NVME was not built in."

    run make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        -j"$JOBS" \
        drivers/phy/allwinner/phy-sunxi-inno-combophy.o \
        drivers/pci/controller/sunxi/pcie-sunxi-rc.o \
        drivers/pci/controller/sunxi/pcie-sunxi-dma.o \
        drivers/pci/controller/sunxi/pcie-sunxi-plat.o \
        allwinner/sun55i-a527-cubie-a5e.dtb
}

validate_compiled_dtb() {
    local combophy_phandle
    local pcie_phy
    local pcie_power
    local pck600_phandle

    require_nonempty_file "$BOARD_DTB"

    run dtc \
        -I dtb \
        -O dts \
        -E ranges_format \
        -E reg_format \
        -E simple_bus_reg \
        -Wno-unit_address_vs_reg \
        -o "$PCIE_DTS_REPORT" \
        "$BOARD_DTB"

    [[ "$(fdtget -t s "$BOARD_DTB" /soc/pcie@4800000 status)" == "okay" ]] ||
        die "Compiled DTB does not enable PCIe."
    [[ "$(fdtget -t s "$BOARD_DTB" /soc/phy@4f00000 status)" == "okay" ]] ||
        die "Compiled DTB does not enable the combo PHY."
    [[ "$(fdtget -t u "$BOARD_DTB" /soc/pcie@4800000 max-link-speed)" == "2" ]] ||
        die "Compiled DTB does not request PCIe Gen2."
    [[ "$(fdtget -t u "$BOARD_DTB" /soc '#address-cells')" == "1" ]] ||
        die "Compiled DTB /soc bus does not use one address cell."
    [[ "$(fdtget -t u "$BOARD_DTB" /soc '#size-cells')" == "1" ]] ||
        die "Compiled DTB /soc bus does not use one size cell."
    [[ "$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 reg)" == \
       "4800000 480000" ]] ||
        die "Compiled DTB PCIe register range is incorrect."
    [[ "$(fdtget -t x "$BOARD_DTB" /soc/phy@4f00000 reg)" == \
       "4f00000 80000 4f80000 80000" ]] ||
        die "Compiled DTB combo-PHY register ranges are incorrect."
    [[ "$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 ranges)" == \
       "800 0 20000000 20000000 0 1000000 81000000 0 21000000 21000000 0 1000000 82000000 0 22000000 22000000 0 e000000" ]] ||
        die "Compiled DTB PCIe outbound address windows are incorrect."

    combophy_phandle="$(fdtget -t x "$BOARD_DTB" /soc/phy@4f00000 phandle)"
    pcie_phy="$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 phys)"
    [[ "$pcie_phy" == "$combophy_phandle 2" ]] ||
        die "Compiled DTB PCIe PHY reference is incorrect."

    pck600_phandle="$(fdtget -t x "$BOARD_DTB" /soc/power-controller@7060000 phandle)"
    pcie_power="$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 power-domains)"
    [[ "$pcie_power" == "$pck600_phandle 7" ]] ||
        die "Compiled DTB PCIe power-domain reference is incorrect."

    grep -qF 'pcie@4800000' "$PCIE_DTS_REPORT" ||
        die "Decompiled DTB lacks the PCIe controller."
}

write_stamp_and_report() {
    {
        printf 'bsp_repository=%s\n' "$BSP_REPOSITORY"
        printf 'bsp_ref=%s\n' "$BSP_REF"
        printf 'bsp_commit=%s\n' "$BSP_EXPECTED_COMMIT"
        printf 'linux_compatibility=6.16\n'
        printf 'dt_layout=mainline-soc-one-cell-v3\n'
        printf 'driver_mode=initramfs-modules-v3\n'
        printf 'pcie_controller=allwinner,sunxi-pcie-v210-rc\n'
        printf 'pcie_link=gen2-x1\n'
        printf 'pcie_controller_driver=initramfs-module\n'
        printf 'pcie_phy_driver=initramfs-module\n'
        printf 'nvme_driver=built-in\n'
        printf 'status=complete\n'
    } >"$PCIE_STAMP"

    {
        printf 'Cubie A5E PCIe/NVMe backport report\n'
        printf '===================================\n'
        printf 'Status: PASS\n'
        printf 'BSP commit: %s\n' "$BSP_EXPECTED_COMMIT"
        printf 'PCIe controller: allwinner,sunxi-pcie-v210-rc\n'
        printf 'PCIe capability: Gen2 x1\n'
        printf 'Combo PHY: allwinner,inno-combphy\n'
        printf 'Power domain: PCK600 PD_PCIE (7)\n'
        printf 'PERST: PH11\n'
        printf 'WAKE: PH12\n'
        printf '3.3 V enable: PL11\n'
        printf 'Driver cross-compile gate: PASS\n'
        printf 'Compiled DTB gate: PASS\n'
        printf 'Compiled DTB: %s\n' "$BOARD_DTB"
        printf 'Decompiled evidence: %s\n' "$PCIE_DTS_REPORT"
    } >"$PCIE_REPORT"
}

commit_port() {
    git -C "$KERNEL_DIR" add -- \
        drivers/clk/sunxi-ng/ccu-sun55i-a523.c \
        drivers/clk/sunxi-ng/ccu-sun55i-a523.h \
        drivers/pci/controller/Kconfig \
        drivers/pci/controller/Makefile \
        drivers/pci/controller/sunxi \
        drivers/phy/allwinner/Kconfig \
        drivers/phy/allwinner/Makefile \
        drivers/phy/allwinner/phy-sunxi-inno-combophy.c \
        include/dt-bindings/clock/sun55i-a523-ccu.h \
        arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi \
        arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts

    if ! git -C "$KERNEL_DIR" diff --cached --quiet; then
        run git -C "$KERNEL_DIR" commit \
            -m "arm64: allwinner: port A523 PCIe and combo PHY to v6.16"
    fi
}

main() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this stage as root."
    [[ "$(readlink -m -- "$KERNEL_DIR")" == \
       "$(readlink -m -- "$EXPECTED_KERNEL_DIR")" ]] ||
        die "Unexpected KERNEL_DIR: $KERNEL_DIR"

    need_cmd awk
    need_cmd dtc
    need_cmd fdtget
    need_cmd git
    need_cmd grep
    need_cmd install
    need_cmd make
    need_cmd mktemp
    need_cmd python3
    need_cmd readlink
    need_cmd sha256sum

    require_nonempty_file "$GMAC1_STAMP"

    if completed_port_available; then
        log "Reusing the completed PCIe/PHY source and compile gates."
        validate_sources
        validate_compiled_dtb
        write_stamp_and_report
        log "Allwinner PCIe/PHY port remains verified."
        log "PCIe report: $PCIE_REPORT"
        return 0
    fi

    fetch_vendor_commit
    extract_vendor_sources
    port_vendor_sources_to_v616
    add_usb3_reference_clock
    add_pcie_device_tree
    validate_sources
    configure_and_compile_gate
    validate_compiled_dtb
    commit_port
    write_stamp_and_report

    log "Allwinner PCIe/PHY port and Cubie A5E NVMe DT path verified."
    log "PCIe report: $PCIE_REPORT"
}

main "$@"
