#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="GMAC1"
# Stage 20 revision: pinned-nine-commits-patch-equivalent-rerun-20260811

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${JOBS:?JOBS is not set}"

readonly EXPECTED_LINUX_REF="${EXPECTED_LINUX_REF:-v6.16}"
readonly EXPECTED_KERNEL_DIR="$BUILD_ROOT/linux-6.16-one-shot"

readonly STAMP="$KERNEL_DIR/.cubie-a5e-gmac1-upstream-backports"
readonly SOC_DTSI="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi"
readonly SRAM_DRIVER="$KERNEL_DIR/drivers/soc/sunxi/sunxi_sram.c"
readonly BOARD_DTS="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts"
readonly STMMAC_DIR="$KERNEL_DIR/drivers/net/ethernet/stmicro/stmmac"
readonly GMAC1_DRIVER="$STMMAC_DIR/dwmac-sun55i.c"
readonly GMAC1_KCONFIG="$STMMAC_DIR/Kconfig"
readonly GMAC1_MAKEFILE="$STMMAC_DIR/Makefile"
readonly PCK600_DIR="$KERNEL_DIR/drivers/pmdomain/sunxi"
readonly PCK600_DRIVER="$PCK600_DIR/sun55i-pck600.c"
readonly PCK600_KCONFIG="$PCK600_DIR/Kconfig"
readonly PCK600_MAKEFILE="$PCK600_DIR/Makefile"
readonly PCK600_BINDING="$KERNEL_DIR/include/dt-bindings/power/allwinner,sun55i-a523-pck-600.h"
readonly R_CCU_RESET_BINDING="$KERNEL_DIR/include/dt-bindings/reset/sun55i-a523-r-ccu.h"
readonly R_CCU_DRIVER="$KERNEL_DIR/drivers/clk/sunxi-ng/ccu-sun55i-a523-r.c"
readonly AXP20X_MFD_DRIVER="$KERNEL_DIR/drivers/mfd/axp20x.c"
readonly DTB_FILE="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly GMAC1_REPORT="$LOG_DIR/gmac1-backport-report.txt"
    readonly GMAC1_COMMITS_REPORT="$LOG_DIR/gmac1-backport-commits.txt"
    readonly GMAC1_DTB_REPORT="$LOG_DIR/gmac1-compiled.dts"
else
    readonly GMAC1_REPORT="$BUILD_ROOT/.one-shot-gmac1-backport-report.txt"
    readonly GMAC1_COMMITS_REPORT="$BUILD_ROOT/.one-shot-gmac1-backport-commits.txt"
    readonly GMAC1_DTB_REPORT="$BUILD_ROOT/.one-shot-gmac1-compiled.dts"
fi

declare -a APPLIED_COMMITS=()
declare -a APPLIED_SUBJECTS=()

require_nonempty_file() {
    local path="$1"

    [[ -s "$path" ]] ||
        die "Required file is missing or empty: $path"
}

abort_stale_git_operation() {
    if [[ -f "$KERNEL_DIR/.git/CHERRY_PICK_HEAD" ]]; then
        warn "Aborting stale cherry-pick in the disposable kernel tree."
        git -C "$KERNEL_DIR" cherry-pick --abort
    fi

    if [[ -d "$KERNEL_DIR/.git/rebase-merge" ||
          -d "$KERNEL_DIR/.git/rebase-apply" ]]; then
        die "A stale Git rebase exists in the kernel tree."
    fi

    if [[ -f "$KERNEL_DIR/.git/MERGE_HEAD" ]]; then
        die "A stale Git merge exists in the kernel tree."
    fi
}

validate_clean_v616_tree() {
    local actual_ref
    local status

    [[ "$(readlink -m -- "$KERNEL_DIR")" == "$(readlink -m -- "$EXPECTED_KERNEL_DIR")" ]] ||
        die "Unexpected KERNEL_DIR: $KERNEL_DIR"

    need_dir "$KERNEL_DIR/.git"
    require_nonempty_file "$KERNEL_DIR/Makefile"

    actual_ref="$(
        git -C "$KERNEL_DIR" \
            describe \
            --tags \
            --exact-match \
            HEAD 2>/dev/null || true
    )"

    if [[ "$actual_ref" != "$EXPECTED_LINUX_REF" ]]; then
        if [[ -f "$STAMP" ]]; then
            log "Kernel tree already contains the GMAC1 backport; continuing."
            return 0
        fi

        warn "Kernel tree is not at a clean $EXPECTED_LINUX_REF baseline and no completion stamp exists."
        warn "Treating this as a leftover from a stage that failed before completion."
        warn "Resetting tree to $EXPECTED_LINUX_REF."

        abort_stale_git_operation
        run git -C "$KERNEL_DIR" reset --hard "$EXPECTED_LINUX_REF"
        run git -C "$KERNEL_DIR" clean -fdx -- \
            arch/arm64/boot/dts/allwinner

        actual_ref="$(
            git -C "$KERNEL_DIR" \
                describe \
                --tags \
                --exact-match \
                HEAD 2>/dev/null || true
        )"

        [[ "$actual_ref" == "$EXPECTED_LINUX_REF" ]] ||
            die "Automatic reset to $EXPECTED_LINUX_REF failed; found ${actual_ref:-modified tree}"
    fi

    status="$(git -C "$KERNEL_DIR" status --porcelain)"

    if [[ -n "$status" ]]; then
        printf '%s\n' "$status" >&2
        die "Kernel tree is not clean. Run 10-prepare-host.sh first."
    fi

}

configure_local_git_identity() {
    git -C "$KERNEL_DIR" config user.name "Cubie A5E Builder"
    git -C "$KERNEL_DIR" config user.email "builder@localhost"
}

cherry_pick_pinned_commit() {
    local commit="$1"
    local subject="$2"
    local actual_subject
    local patch_status

    git -C "$KERNEL_DIR" cat-file -e "$commit^{commit}" 2>/dev/null ||
        die "Pinned upstream commit is unavailable: $commit"

    actual_subject="$(git -C "$KERNEL_DIR" show -s --format='%s' "$commit")"
    [[ "$actual_subject" == "$subject" ]] ||
        die "Pinned commit subject mismatch: $commit"

    if git -C "$KERNEL_DIR" merge-base --is-ancestor "$commit" HEAD; then
        log "Backport already present: $subject"
        APPLIED_COMMITS+=("$commit")
        APPLIED_SUBJECTS+=("$subject")
        return 0
    fi

    git -C "$KERNEL_DIR" cat-file -e "${commit}^" 2>/dev/null ||
        die "Parent of pinned upstream commit is unavailable: $commit"

    patch_status="$(
        git -C "$KERNEL_DIR" \
            cherry \
            --abbrev=40 \
            HEAD \
            "$commit" \
            "${commit}^"
    )"

    case "$patch_status" in
        "- $commit")
            log "Patch-equivalent backport already present: $subject"
            APPLIED_COMMITS+=("$commit")
            APPLIED_SUBJECTS+=("$subject")
            return 0
            ;;
        "+ $commit")
            ;;
        *)
            die "Could not determine patch-equivalence status for: $subject ($commit)"
            ;;
    esac

    log "Cherry-picking upstream commit: $subject"
    log "Commit: $commit"

    if ! git -C "$KERNEL_DIR" cherry-pick "$commit"; then
        git -C "$KERNEL_DIR" cherry-pick --abort >/dev/null 2>&1 || true
        die "Upstream GMAC1 backport failed: $subject ($commit)"
    fi

    APPLIED_COMMITS+=("$commit")
    APPLIED_SUBJECTS+=("$subject")
}

apply_required_upstream_backports() {
    local entry
    local commit
    local subject
    local -a required_commits=(
        "88828c7e940dd45d139ad4a39d702b23840a37c5|mfd: axp20x: Set explicit ID for AXP313 regulator"
        "f99d4fccd2185176baf4ecac9a49d280fc62b953|dt-bindings: power: Add A523 PPU and PCK600 power controllers"
        "61977ccf6568f9d104462727b49412a80c22c519|dt-bindings: reset: sun55i-a523-r-ccu: Add missing PPU0 reset"
        "c17b1b6c86059664e91008a23547ef0aadfc2228|clk: sunxi-ng: sun55i-a523-r-ccu: Add missing PPU0 reset"
        "76e4310115ca66d28166cf94bb1edf37a750363a|pmdomain: sunxi: add driver for Allwinner A523's PCK-600 power controller"
        "d9fcb34f8b3bf793fadb591aafc76f27ecb48ff0|dt-bindings: net: sun8i-emac: Add A523 GMAC200 compatible"
        "f603808a98afd37c50a736f1d3c8e186b625b115|net: stmmac: Add support for Allwinner A523 GMAC200"
        "30849ab484f7397c9902082c7567ca4cd4eb03d3|soc: sunxi: sram: add entry for a523"
        "e6b84cc2a6fe62b4070d73f2d2d7b2544a11df87|soc: sunxi: sram: register regmap as syscon"
    )

    for entry in "${required_commits[@]}"; do
        commit="${entry%%|*}"
        subject="${entry#*|}"
        cherry_pick_pinned_commit "$commit" "$subject"
    done
}

apply_v616_gmac1_dts_port() {
    log "Applying deterministic v6.16 GMAC1 DTS port."

    export SOC_DTSI
    export BOARD_DTS

    python3 <<'PYPORT'
from pathlib import Path
import os
import re
import sys

soc_path = Path(os.environ["SOC_DTSI"])
board_path = Path(os.environ["BOARD_DTS"])

soc = soc_path.read_text(encoding="utf-8")
board = board_path.read_text(encoding="utf-8")

def node_span(text: str, marker: str):
    marker_pos = text.find(marker)
    if marker_pos < 0:
        return None

    line_start = text.rfind("\n", 0, marker_pos) + 1
    open_brace = text.find("{", marker_pos)
    if open_brace < 0:
        sys.exit(f"GMAC1: opening brace not found for {marker}")

    depth = 0
    close_brace = -1
    for pos in range(open_brace, len(text)):
        char = text[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                close_brace = pos
                break

    if close_brace < 0:
        sys.exit(f"GMAC1: closing brace not found for {marker}")

    semicolon = text.find(";", close_brace)
    if semicolon < 0:
        sys.exit(f"GMAC1: terminating semicolon not found for {marker}")

    line_end = text.find("\n", semicolon)
    if line_end < 0:
        line_end = len(text)
    else:
        line_end += 1

    return line_start, line_end

power_include = "#include <dt-bindings/power/allwinner,sun55i-a523-pck-600.h>"
if power_include not in soc:
    anchor = "#include <dt-bindings/reset/sun55i-a523-r-ccu.h>"
    if anchor not in soc:
        sys.exit("GMAC1: power-domain include anchor not found")
    soc = soc.replace(anchor, anchor + "\n" + power_include, 1)

rgmii1_block = """		rgmii1_pins: rgmii1-pins {
			pins = "PJ0", "PJ1", "PJ2", "PJ3", "PJ4",
			       "PJ5", "PJ6", "PJ7", "PJ8", "PJ9",
			       "PJ11", "PJ12", "PJ13", "PJ14", "PJ15";
			allwinner,pinmux = <5>;
			function = "gmac1";
			drive-strength = <40>;
			bias-disable;
		};
"""

rgmii1_span = node_span(soc, "rgmii1_pins: rgmii1-pins")
if rgmii1_span is None:
    anchor = "		uart0_pb_pins: uart0-pb-pins {"
    if anchor not in soc:
        sys.exit("GMAC1: pinctrl insertion anchor not found")

    soc = soc.replace(anchor, rgmii1_block + "\n" + anchor, 1)
else:
    start, end = rgmii1_span
    soc = soc[:start] + rgmii1_block + soc[end:]

def insert_soc_block(text: str, block: str) -> str:
    soc_match = re.search(r"\n\s*soc\s*\{", text)
    if soc_match is None:
        sys.exit("GMAC1: /soc node not found in sun55i-a523.dtsi")

    open_brace = text.find("{", soc_match.start())
    if open_brace < 0:
        sys.exit("GMAC1: /soc opening brace not found")

    depth = 0
    for pos in range(open_brace, len(text)):
        char = text[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[:pos] + block + text[pos:]

    sys.exit("GMAC1: /soc closing brace not found")

if "pck600: power-controller@7060000" not in soc:
    block = """		pck600: power-controller@7060000 {
			compatible = "allwinner,sun55i-a523-pck-600";
			reg = <0x07060000 0x8000>;
			clocks = <&r_ccu CLK_BUS_R_PPU0>;
			resets = <&r_ccu RST_BUS_R_PPU0>;
			#power-domain-cells = <1>;
		};

"""
    soc = insert_soc_block(soc, block)

if "gmac1: ethernet@4510000" not in soc:
    block = """		gmac1: ethernet@4510000 {
			compatible = "allwinner,sun55i-a523-gmac200",
				     "snps,dwmac-4.20a";
			reg = <0x04510000 0x10000>;
			clocks = <&ccu CLK_BUS_EMAC1>, <&ccu CLK_MBUS_EMAC1>;
			clock-names = "stmmaceth", "mbus";
			resets = <&ccu RST_BUS_EMAC1>;
			reset-names = "stmmaceth";
			interrupts = <GIC_SPI 47 IRQ_TYPE_LEVEL_HIGH>;
			interrupt-names = "macirq";
			pinctrl-names = "default";
			pinctrl-0 = <&rgmii1_pins>;
			power-domains = <&pck600 PD_VO1>;
			syscon = <&syscon>;
			snps,fixed-burst;
			snps,axi-config = <&gmac1_stmmac_axi_setup>;
			snps,mtl-rx-config = <&gmac1_mtl_rx_setup>;
			snps,mtl-tx-config = <&gmac1_mtl_tx_setup>;
			status = "disabled";

			mdio1: mdio {
				compatible = "snps,dwmac-mdio";
				#address-cells = <1>;
				#size-cells = <0>;
			};

			gmac1_mtl_rx_setup: rx-queues-config {
				snps,rx-queues-to-use = <1>;
				queue0 {};
			};

			gmac1_stmmac_axi_setup: stmmac-axi-config {
				snps,wr_osr_lmt = <0xf>;
				snps,rd_osr_lmt = <0xf>;
				snps,blen = <256 128 64 32 16 8 4>;
			};

			gmac1_mtl_tx_setup: tx-queues-config {
				snps,tx-queues-to-use = <1>;
				queue0 {};
			};
		};

"""
    soc = insert_soc_block(soc, block)

if not re.search(r"\bethernet1\s*=\s*&gmac1\s*;", board):
    match = re.search(r"(\baliases\s*\{)(.*?)(\n\s*\};)", board, re.S)
    if match is None:
        sys.exit("GMAC1: aliases node not found")
    body = match.group(2)
    replacement = match.group(1) + body
    if not body.endswith("\n"):
        replacement += "\n"
    replacement += "\t\tethernet1 = &gmac1;" + match.group(3)
    board = board[:match.start()] + replacement + board[match.end():]

gmac1_board_block = """&gmac1 {
	phy-mode = "rgmii-id";
	phy-handle = <&ext_rgmii1_phy>;
	phy-supply = <&reg_cldo4>;
	tx-internal-delay-ps = <300>;
	rx-internal-delay-ps = <400>;
	status = "okay";
};
"""

gmac1_board_span = node_span(board, "&gmac1 {")
if gmac1_board_span is None:
    board = board.rstrip() + "\n\n" + gmac1_board_block
else:
    start, end = gmac1_board_span
    board = board[:start] + gmac1_board_block + board[end:]

if "\n&mdio1 {" not in board:
    board = board.rstrip() + """

&mdio1 {
	ext_rgmii1_phy: ethernet-phy@1 {
		compatible = "ethernet-phy-ieee802.3-c22";
		reg = <1>;
		reset-gpios = <&pio 9 16 GPIO_ACTIVE_LOW>;
		reset-assert-us = <10000>;
		reset-deassert-us = <150000>;
	};
};
"""

soc_path.write_text(soc, encoding="utf-8")
board_path.write_text(board.rstrip() + "\n", encoding="utf-8")
PYPORT

    git -C "$KERNEL_DIR" add -- "$SOC_DTSI" "$BOARD_DTS"

    if ! git -C "$KERNEL_DIR" diff --cached --quiet; then
        run git -C "$KERNEL_DIR" commit \
            -m "arm64: dts: allwinner: port Cubie A5E GMAC1 to v6.16"
    fi
}

validate_gmac1_sources() {
    require_nonempty_file "$SOC_DTSI"
    require_nonempty_file "$BOARD_DTS"
    require_nonempty_file "$SRAM_DRIVER"
    require_nonempty_file "$GMAC1_DRIVER"
    require_nonempty_file "$GMAC1_KCONFIG"
    require_nonempty_file "$GMAC1_MAKEFILE"
    require_nonempty_file "$PCK600_DRIVER"
    require_nonempty_file "$PCK600_KCONFIG"
    require_nonempty_file "$PCK600_MAKEFILE"
    require_nonempty_file "$PCK600_BINDING"
    require_nonempty_file "$R_CCU_RESET_BINDING"
    require_nonempty_file "$R_CCU_DRIVER"
    require_nonempty_file "$AXP20X_MFD_DRIVER"

    grep -qF \
        'MFD_CELL_BASIC("axp20x-regulator", NULL, NULL, 0, 1),' \
        "$AXP20X_MFD_DRIVER" ||
        die "AXP313 regulator cell lacks its conflict-free explicit device ID."

    grep -q 'config DWMAC_SUN55I' "$GMAC1_KCONFIG" ||
        die "DWMAC_SUN55I Kconfig entry is missing."

    grep -q 'dwmac-sun55i' "$GMAC1_MAKEFILE" ||
        die "dwmac-sun55i Makefile entry is missing."

    grep -q 'allwinner,sun55i-a523-gmac200' "$GMAC1_DRIVER" ||
        die "GMAC200 driver compatible is missing."

    grep -q '"tx-internal-delay-ps"' "$GMAC1_DRIVER" ||
        die "GMAC200 driver does not read tx-internal-delay-ps."

    grep -q '"rx-internal-delay-ps"' "$GMAC1_DRIVER" ||
        die "GMAC200 driver does not read rx-internal-delay-ps."

    grep -q 'config SUN55I_PCK600' "$PCK600_KCONFIG" ||
        die "SUN55I_PCK600 Kconfig entry is missing."

    grep -q 'sun55i-pck600' "$PCK600_MAKEFILE" ||
        die "sun55i-pck600 Makefile entry is missing."

    grep -q 'allwinner,sun55i-a523-pck-600' "$PCK600_DRIVER" ||
        die "A523 PCK600 driver compatible is missing."

    grep -Eq '^#define[[:space:]]+PD_VO1[[:space:]]+4([[:space:]]|$)' \
        "$PCK600_BINDING" ||
        die "PD_VO1 binding is missing or incorrect."

    grep -Eq '^#define[[:space:]]+RST_BUS_R_PPU0[[:space:]]+15([[:space:]]|$)' \
        "$R_CCU_RESET_BINDING" ||
        die "PCK600 reset binding is missing."

    grep -q '\[RST_BUS_R_PPU0\].*0x1ac.*BIT(16)' "$R_CCU_DRIVER" ||
        die "PCK600 reset is missing from the A523 R-CCU driver."

    grep -Eq '^#define[[:space:]]+SYSCON_REG[[:space:]]+0x34([[:space:]]|$)' \
        "$GMAC1_DRIVER" ||
        die "GMAC1 driver does not define the required syscon register offset 0x34."

    grep -q 'sun55i_a523_sramc_variant' "$SRAM_DRIVER" ||
        die "A523 SRAM controller variant is missing."

    grep -q 'allwinner,sun55i-a523-system-control' "$SRAM_DRIVER" ||
        die "A523 SRAM system-control compatible is missing."

    grep -q 'of_syscon_register_regmap' "$SRAM_DRIVER" ||
        die "SRAM syscon regmap registration is missing."

    grep -q 'allwinner,sun55i-a523-gmac200' "$SOC_DTSI" ||
        die "Upstream GMAC200 SoC node is missing."

    grep -q 'ethernet@4510000' "$SOC_DTSI" ||
        die "GMAC1 controller node is missing."

    grep -q 'pck600: power-controller@7060000' "$SOC_DTSI" ||
        die "PCK600 power-controller node is missing."

    grep -q 'compatible = "allwinner,sun55i-a523-pck-600";' "$SOC_DTSI" ||
        die "PCK600 power-controller compatible is missing."

    grep -q 'resets = <&r_ccu RST_BUS_R_PPU0>;' "$SOC_DTSI" ||
        die "PCK600 power-controller reset is missing."

    grep -q 'power-domains = <&pck600 PD_VO1>;' "$SOC_DTSI" ||
        die "GMAC1 is not attached to the required PCK600 VO1 domain."

    grep -q 'reg = <0x04510000 0x10000>;' "$SOC_DTSI" ||
        die "GMAC1 register range is incorrect."

    grep -q 'interrupts = <GIC_SPI 47 IRQ_TYPE_LEVEL_HIGH>;' "$SOC_DTSI" ||
        die "GMAC1 interrupt configuration is incorrect."

    grep -q 'allwinner,pinmux = <5>;' "$SOC_DTSI" ||
        die "GMAC1 numeric pinmux encoding is missing."

    grep -q 'function = "gmac1";' "$SOC_DTSI" ||
        die "GMAC1 pinctrl function property is missing."

    grep -Eq 'ethernet1[[:space:]]*=[[:space:]]*&gmac1' "$BOARD_DTS" ||
        die "ethernet1 alias is missing."

    grep -q '^&gmac1 {' "$BOARD_DTS" ||
        die "Upstream Cubie A5E GMAC1 board enablement is missing."

    grep -q 'phy-handle = <&ext_rgmii1_phy>;' "$BOARD_DTS" ||
        die "GMAC1 PHY handle is missing or incorrect."

    grep -q 'phy-supply = <&reg_cldo4>;' "$BOARD_DTS" ||
        die "GMAC1 PHY supply must use CLDO4."

    grep -q 'tx-internal-delay-ps = <300>;' "$BOARD_DTS" ||
        die "GMAC1 TX delay is missing or uses the wrong property."

    grep -q 'rx-internal-delay-ps = <400>;' "$BOARD_DTS" ||
        die "GMAC1 RX delay is missing or uses the wrong property."

    grep -q 'reset-gpios = <&pio 9 16 GPIO_ACTIVE_LOW>;' "$BOARD_DTS" ||
        die "GMAC1 PHY reset must use PJ16 active-low."

    git -C "$KERNEL_DIR" diff --check ||
        die "Whitespace errors were detected after the GMAC1 backport."
}

enable_gmac1_driver_config() {
    local scripts_config="$KERNEL_DIR/scripts/config"

    require_nonempty_file "$scripts_config"

    run "$scripts_config" \
        --file "$KERNEL_DIR/.config" \
        --enable STMMAC_ETH

    run "$scripts_config" \
        --file "$KERNEL_DIR/.config" \
        --enable STMMAC_PLATFORM

    run "$scripts_config" \
        --file "$KERNEL_DIR/.config" \
        --enable DWMAC_SUN55I

    run "$scripts_config" \
        --file "$KERNEL_DIR/.config" \
        --enable SUN55I_PCK600

    run make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        olddefconfig

    grep -Fxq 'CONFIG_STMMAC_ETH=y' \
        "$KERNEL_DIR/.config" ||
        die "CONFIG_STMMAC_ETH was not built in."

    grep -Fxq 'CONFIG_STMMAC_PLATFORM=y' \
        "$KERNEL_DIR/.config" ||
        die "CONFIG_STMMAC_PLATFORM was not built in."

    grep -Fxq 'CONFIG_DWMAC_SUN55I=y' \
        "$KERNEL_DIR/.config" ||
        die "CONFIG_DWMAC_SUN55I was not built in."

    grep -Fxq 'CONFIG_SUN55I_PCK600=y' \
        "$KERNEL_DIR/.config" ||
        die "CONFIG_SUN55I_PCK600 was not built in."

    grep -Fxq 'CONFIG_PM_GENERIC_DOMAINS=y' \
        "$KERNEL_DIR/.config" ||
        die "CONFIG_PM_GENERIC_DOMAINS was not enabled."
}

build_and_validate_dtb() {
    local cldo4_phandle
    local gmac1_pinctrl
    local gmac1_power_domain
    local gmac1_phy_supply
    local pck600_phandle
    local rgmii1_phandle
    local reset_bank
    local reset_flags
    local reset_gpio_phandle
    local reset_pin

    log "Compiling the Cubie A5E DTB as a mandatory GMAC1 gate."

    local dtb_dir dtb_base
    dtb_dir="$(dirname -- "$DTB_FILE")"
    dtb_base="$(basename -- "$DTB_FILE")"

    rm -f -- \
        "$DTB_FILE" \
        "$dtb_dir/.${dtb_base}.cmd"

    run make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        -j"$JOBS" \
        allwinner/sun55i-a527-cubie-a5e.dtb

    require_nonempty_file "$DTB_FILE"

    run dtc \
        -I dtb \
        -O dts \
        -Wno-unit_address_vs_reg \
        -o "$GMAC1_DTB_REPORT" \
        "$DTB_FILE"

    require_nonempty_file "$GMAC1_DTB_REPORT"

    grep -q 'ethernet@4510000' "$GMAC1_DTB_REPORT" ||
        die "Compiled DTB does not contain GMAC1."

    grep -q 'allwinner,sun55i-a523-gmac200' "$GMAC1_DTB_REPORT" ||
        die "Compiled DTB does not contain the GMAC200 compatible."

    [[ "$(fdtget -t s "$DTB_FILE" /soc/ethernet@4510000 status)" == "okay" ]] ||
        die "Compiled DTB does not enable GMAC1."

    [[ "$(fdtget -t s "$DTB_FILE" /soc/ethernet@4510000 phy-mode)" == "rgmii-id" ]] ||
        die "Compiled DTB has the wrong GMAC1 PHY mode."

    [[ "$(
        fdtget -t u \
            "$DTB_FILE" \
            /soc/pinctrl@2000000/rgmii1-pins \
            allwinner,pinmux
    )" == "5" ]] ||
        die "Compiled DTB has the wrong GMAC1 numeric pinmux."

    [[ "$(
        fdtget -t s \
            "$DTB_FILE" \
            /soc/pinctrl@2000000/rgmii1-pins \
            function
    )" == "gmac1" ]] ||
        die "Compiled DTB is missing the GMAC1 pinctrl function."

    rgmii1_phandle="$(
        fdtget -t x \
            "$DTB_FILE" \
            /soc/pinctrl@2000000/rgmii1-pins \
            phandle
    )"
    gmac1_pinctrl="$(
        fdtget -t x "$DTB_FILE" /soc/ethernet@4510000 pinctrl-0
    )"

    [[ "$gmac1_pinctrl" == "$rgmii1_phandle" ]] ||
        die "Compiled DTB does not connect GMAC1 to the RGMII1 pinctrl node."

    [[ "$(fdtget -t s "$DTB_FILE" /soc/ethernet@4510000 pinctrl-names)" == "default" ]] ||
        die "Compiled DTB has the wrong GMAC1 pinctrl name."

    [[ "$(fdtget -t u "$DTB_FILE" /soc/ethernet@4510000 tx-internal-delay-ps)" == "300" ]] ||
        die "Compiled DTB has the wrong GMAC1 TX delay."

    [[ "$(fdtget -t u "$DTB_FILE" /soc/ethernet@4510000 rx-internal-delay-ps)" == "400" ]] ||
        die "Compiled DTB has the wrong GMAC1 RX delay."

    pck600_phandle="$(
        fdtget -t x "$DTB_FILE" /soc/power-controller@7060000 phandle
    )"
    gmac1_power_domain="$(
        fdtget -t x "$DTB_FILE" /soc/ethernet@4510000 power-domains
    )"

    [[ "$gmac1_power_domain" == "$pck600_phandle 4" ]] ||
        die "Compiled DTB does not connect GMAC1 to PCK600 PD_VO1."

    cldo4_phandle="$(
        fdtget -t x \
            "$DTB_FILE" \
            /soc/i2c@7081400/pmic@34/regulators/cldo4 \
            phandle
    )"
    gmac1_phy_supply="$(
        fdtget -t x "$DTB_FILE" /soc/ethernet@4510000 phy-supply
    )"

    [[ "$gmac1_phy_supply" == "$cldo4_phandle" ]] ||
        die "Compiled DTB does not connect GMAC1 PHY power to CLDO4."

    IFS=' ' read -r reset_gpio_phandle reset_bank reset_pin reset_flags < <(
        fdtget -t x \
            "$DTB_FILE" \
            /soc/ethernet@4510000/mdio/ethernet-phy@1 \
            reset-gpios
    )

    [[ -n "$reset_gpio_phandle" &&
       "$reset_bank" == "9" &&
       "$reset_pin" == "10" &&
       "$reset_flags" == "1" ]] ||
        die "Compiled DTB does not use PJ16 active-low for GMAC1 PHY reset."

    [[ "$(
        fdtget -t u \
            "$DTB_FILE" \
            /soc/ethernet@4510000/mdio/ethernet-phy@1 \
            reset-assert-us
    )" == "10000" ]] ||
        die "Compiled DTB has the wrong GMAC1 PHY reset assertion time."

    [[ "$(
        fdtget -t u \
            "$DTB_FILE" \
            /soc/ethernet@4510000/mdio/ethernet-phy@1 \
            reset-deassert-us
    )" == "150000" ]] ||
        die "Compiled DTB has the wrong GMAC1 PHY reset deassertion time."
}

write_stamp_and_reports() {
    local index

    {
        printf 'baseline=%s\n' "$EXPECTED_LINUX_REF"

        for index in "${!APPLIED_COMMITS[@]}"; do
            printf '%s=%s\n' \
                "${APPLIED_SUBJECTS[$index]}" \
                "${APPLIED_COMMITS[$index]}"
        done

        printf 'dts_method=upstream-nine-commits-plus-v6.16-dts-port\n'
        printf 'axp313_regulator_id_backport=required-and-applied\n'
        printf 'sram_syscon_backport=required-and-applied\n'
        printf 'pck600_backport=required-and-applied\n'
        printf 'status=complete\n'
    } >"$STAMP"

    cp -a -- "$STAMP" "$GMAC1_COMMITS_REPORT"

    {
        printf 'Cubie A5E GMAC1 backport report\n'
        printf '================================\n'
        printf 'Status: PASS\n'
        printf 'Kernel baseline: %s\n' "$EXPECTED_LINUX_REF"
        printf 'AXP313/AXP323 regulator device-ID conflict fixed: yes\n'
        printf 'GMAC1 controller address: 0x04510000\n'
        printf 'GMAC1 IRQ: 47\n'
        printf 'GMAC1 PHY address: 1\n'
        printf 'GMAC1 PHY reset: PJ16 active-low\n'
        printf 'GMAC1 PHY supply: CLDO4\n'
        printf 'GMAC1 power domain: PCK600 PD_VO1\n'
        printf 'GMAC1 pinctrl: PJ0-PJ9 and PJ11-PJ15, function gmac1, pinmux 5\n'
        printf 'GMAC1 delays: TX 300 ps, RX 400 ps\n'
        printf 'GMAC1 driver: dwmac-sun55i.c\n'
        printf 'GMAC1 compatible: allwinner,sun55i-a523-gmac200\n'
        printf 'SRAM syscon backport: applied\n'
        printf 'PCK600 backport: applied and built in\n'
        printf 'Compiled DTB: %s\n' "$DTB_FILE"
        printf 'Decompiled DTB evidence: %s\n' "$GMAC1_DTB_REPORT"
        printf 'Commit evidence: %s\n' "$GMAC1_COMMITS_REPORT"
    } >"$GMAC1_REPORT"
}

main() {
    [[ "$(id -u)" -eq 0 ]] ||
        die "Run this stage as root."

    need_cmd git
    need_cmd python3
    need_cmd make
    need_cmd dtc
    need_cmd fdtget
    need_cmd grep
    need_cmd awk
    need_cmd readlink

    abort_stale_git_operation
    validate_clean_v616_tree
    configure_local_git_identity
    apply_required_upstream_backports
    apply_v616_gmac1_dts_port
    validate_gmac1_sources
    enable_gmac1_driver_config
    build_and_validate_dtb
    write_stamp_and_reports

    log "GMAC200 upstream backports and deterministic v6.16 GMAC1 DTS port verified."
    log "DTB gate passed: $DTB_FILE"
    log "GMAC1 report: $GMAC1_REPORT"
}

main "$@"
