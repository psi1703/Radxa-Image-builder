#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="GMAC1"
# Stage 20 revision: linux-6.18-lts-upstream-dts-backport-v1-20260822

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${JOBS:?JOBS is not set}"
: "${LINUX_REF:?LINUX_REF is not set}"
: "${LINUX_EXPECTED_COMMIT:?LINUX_EXPECTED_COMMIT is not set}"

readonly STAMP="$KERNEL_DIR/.cubie-a5e-gmac1-dts-backport"
readonly SOC_DTSI="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi"
readonly BOARD_DTS="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts"
readonly SRAM_DRIVER="$KERNEL_DIR/drivers/soc/sunxi/sunxi_sram.c"
readonly STMMAC_DIR="$KERNEL_DIR/drivers/net/ethernet/stmicro/stmmac"
readonly GMAC1_DRIVER="$STMMAC_DIR/dwmac-sun55i.c"
readonly GMAC1_KCONFIG="$STMMAC_DIR/Kconfig"
readonly GMAC1_MAKEFILE="$STMMAC_DIR/Makefile"
readonly PCK600_DIR="$KERNEL_DIR/drivers/pmdomain/sunxi"
readonly PCK600_DRIVER="$PCK600_DIR/sun55i-pck600.c"
readonly PCK600_KCONFIG="$PCK600_DIR/Kconfig"
readonly PCK600_MAKEFILE="$PCK600_DIR/Makefile"
readonly PCK600_BINDING="$KERNEL_DIR/include/dt-bindings/power/allwinner,sun55i-a523-pck-600.h"
readonly DTB_FILE="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly GMAC1_REPORT="$LOG_DIR/gmac1-backport-report.txt"
    readonly GMAC1_EVIDENCE_REPORT="$LOG_DIR/gmac1-backport-evidence.txt"
    readonly GMAC1_DTB_REPORT="$LOG_DIR/gmac1-compiled.dts"
else
    readonly GMAC1_REPORT="$BUILD_ROOT/.one-shot-gmac1-backport-report.txt"
    readonly GMAC1_EVIDENCE_REPORT="$BUILD_ROOT/.one-shot-gmac1-backport-evidence.txt"
    readonly GMAC1_DTB_REPORT="$BUILD_ROOT/.one-shot-gmac1-compiled.dts"
fi

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

validate_kernel_baseline() {
    local actual_commit
    local actual_ref
    local status

    need_dir "$KERNEL_DIR/.git"
    require_nonempty_file "$KERNEL_DIR/Makefile"

    actual_commit="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
    actual_ref="$(
        git -C "$KERNEL_DIR" \
            describe \
            --tags \
            --exact-match \
            HEAD 2>/dev/null || true
    )"

    if [[ -f "$STAMP" ]]; then
        log "GMAC1 DTS backport completion stamp exists; validating the existing tree."
        return 0
    fi

    if [[ "$actual_commit" != "$LINUX_EXPECTED_COMMIT" ||
          "$actual_ref" != "$LINUX_REF" ]]; then
        warn "Kernel tree is not at the pinned $LINUX_REF baseline."
        warn "Treating this as a failed/incomplete previous Stage 20 run."
        warn "Resetting the disposable kernel tree to $LINUX_REF."

        abort_stale_git_operation
        run git -C "$KERNEL_DIR" reset --hard "$LINUX_REF"
        run git -C "$KERNEL_DIR" clean -fdx -- \
            arch/arm64/boot/dts/allwinner

        actual_commit="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        actual_ref="$(
            git -C "$KERNEL_DIR" \
                describe \
                --tags \
                --exact-match \
                HEAD 2>/dev/null || true
        )"
    fi

    [[ "$actual_commit" == "$LINUX_EXPECTED_COMMIT" ]] ||
        die "Kernel commit mismatch after reset: expected $LINUX_EXPECTED_COMMIT, found $actual_commit"

    [[ "$actual_ref" == "$LINUX_REF" ]] ||
        die "Kernel tag mismatch after reset: expected $LINUX_REF, found ${actual_ref:-unmatched HEAD}"

    status="$(git -C "$KERNEL_DIR" status --porcelain)"
    if [[ -n "$status" ]]; then
        printf '%s\n' "$status" >&2
        die "Kernel source tree is not clean before Stage 20."
    fi
}

configure_local_git_identity() {
    git -C "$KERNEL_DIR" config user.name "Cubie A5E Builder"
    git -C "$KERNEL_DIR" config user.email "builder@localhost"
}

validate_upstream_618_prerequisites() {
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

    grep -F 'config DWMAC_SUN55I' "$GMAC1_KCONFIG" >/dev/null ||
        die "Pinned kernel lacks upstream DWMAC_SUN55I support."

    grep -F 'dwmac-sun55i' "$GMAC1_MAKEFILE" >/dev/null ||
        die "Pinned kernel lacks the upstream dwmac-sun55i build rule."

    grep -F 'allwinner,sun55i-a523-gmac200' "$GMAC1_DRIVER" >/dev/null ||
        die "Pinned kernel lacks upstream A523 GMAC200 driver support."

    grep -F 'tx-internal-delay-ps' "$GMAC1_DRIVER" >/dev/null ||
        die "GMAC200 driver lacks tx-internal-delay-ps support."

    grep -F 'rx-internal-delay-ps' "$GMAC1_DRIVER" >/dev/null ||
        die "GMAC200 driver lacks rx-internal-delay-ps support."

    grep -Eq '^#define[[:space:]]+SYSCON_REG[[:space:]]+0x34([[:space:]]|$)' \
        "$GMAC1_DRIVER" ||
        die "GMAC200 driver does not use the required GMAC1 syscon offset 0x34."

    grep -F 'config SUN55I_PCK600' "$PCK600_KCONFIG" >/dev/null ||
        die "Pinned kernel lacks upstream SUN55I_PCK600 support."

    grep -F 'sun55i-pck600' "$PCK600_MAKEFILE" >/dev/null ||
        die "Pinned kernel lacks the upstream sun55i-pck600 build rule."

    grep -F 'allwinner,sun55i-a523-pck-600' "$PCK600_DRIVER" >/dev/null ||
        die "Pinned kernel lacks upstream A523 PCK600 driver support."

    grep -Eq '^#define[[:space:]]+PD_VO1[[:space:]]+4([[:space:]]|$)' \
        "$PCK600_BINDING" ||
        die "Pinned kernel has an unexpected PCK600 PD_VO1 binding."

    grep -F 'allwinner,sun55i-a523-system-control' "$SRAM_DRIVER" >/dev/null ||
        die "Pinned kernel lacks the A523 system-control/SRAM variant."

    grep -F 'of_syscon_register_regmap' "$SRAM_DRIVER" >/dev/null ||
        die "Pinned kernel lacks SRAM syscon regmap registration required by GMAC200."

    grep -F 'pck600: power-controller@7060000' "$SOC_DTSI" >/dev/null ||
        die "Pinned kernel DTS lacks the upstream A523 PCK600 node."

    if grep -F 'gmac1: ethernet@4510000' "$SOC_DTSI" >/dev/null; then
        log "Pinned kernel already contains the GMAC1 SoC node; Stage 20 will normalize/validate it."
    else
        log "GMAC1 driver and PCK600 are upstream in $LINUX_REF; only DTS enablement needs backporting."
    fi
}

apply_gmac1_dts_backport() {
    log "Applying the upstream GMAC1 DTS enablement to $LINUX_REF."

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


def insert_before_node(text: str, anchor: str, block: str) -> str:
    pos = text.find(anchor)
    if pos < 0:
        sys.exit(f"GMAC1: insertion anchor not found: {anchor}")
    line_start = text.rfind("\n", 0, pos) + 1
    return text[:line_start] + block + "\n" + text[line_start:]


rgmii1_block = """\t\t\trgmii1_pins: rgmii1-pins {
\t\t\t\tpins = \"PJ0\", \"PJ1\", \"PJ2\", \"PJ3\", \"PJ4\",
\t\t\t\t       \"PJ5\", \"PJ6\", \"PJ7\", \"PJ8\", \"PJ9\",
\t\t\t\t       \"PJ11\", \"PJ12\", \"PJ13\", \"PJ14\", \"PJ15\";
\t\t\t\tallwinner,pinmux = <5>;
\t\t\t\tfunction = \"gmac1\";
\t\t\t\tdrive-strength = <40>;
\t\t\t\tbias-disable;
\t\t\t};
"""

rgmii1_span = node_span(soc, "rgmii1_pins: rgmii1-pins")
if rgmii1_span is None:
    soc = insert_before_node(soc, "uart0_pb_pins: uart0-pb-pins", rgmii1_block)
else:
    start, end = rgmii1_span
    soc = soc[:start] + rgmii1_block + soc[end:]


gmac1_block = """\t\tgmac1: ethernet@4510000 {
\t\t\tcompatible = \"allwinner,sun55i-a523-gmac200\",
\t\t\t\t     \"snps,dwmac-4.20a\";
\t\t\treg = <0x04510000 0x10000>;
\t\t\tclocks = <&ccu CLK_BUS_EMAC1>, <&ccu CLK_MBUS_EMAC1>;
\t\t\tclock-names = \"stmmaceth\", \"mbus\";
\t\t\tresets = <&ccu RST_BUS_EMAC1>;
\t\t\treset-names = \"stmmaceth\";
\t\t\tinterrupts = <GIC_SPI 47 IRQ_TYPE_LEVEL_HIGH>;
\t\t\tinterrupt-names = \"macirq\";
\t\t\tpinctrl-names = \"default\";
\t\t\tpinctrl-0 = <&rgmii1_pins>;
\t\t\tpower-domains = <&pck600 PD_VO1>;
\t\t\tsyscon = <&syscon>;
\t\t\tsnps,fixed-burst;
\t\t\tsnps,axi-config = <&gmac1_stmmac_axi_setup>;
\t\t\tsnps,mtl-rx-config = <&gmac1_mtl_rx_setup>;
\t\t\tsnps,mtl-tx-config = <&gmac1_mtl_tx_setup>;
\t\t\tstatus = \"disabled\";

\t\t\tmdio1: mdio {
\t\t\t\tcompatible = \"snps,dwmac-mdio\";
\t\t\t\t#address-cells = <1>;
\t\t\t\t#size-cells = <0>;
\t\t\t};

\t\t\tgmac1_mtl_rx_setup: rx-queues-config {
\t\t\t\tsnps,rx-queues-to-use = <1>;
\t\t\t\tqueue0 {};
\t\t\t};

\t\t\tgmac1_stmmac_axi_setup: stmmac-axi-config {
\t\t\t\tsnps,wr_osr_lmt = <0xf>;
\t\t\t\tsnps,rd_osr_lmt = <0xf>;
\t\t\t\tsnps,blen = <256 128 64 32 16 8 4>;
\t\t\t};

\t\t\tgmac1_mtl_tx_setup: tx-queues-config {
\t\t\t\tsnps,tx-queues-to-use = <1>;
\t\t\t\tqueue0 {};
\t\t\t};
\t\t};
"""

gmac1_span = node_span(soc, "gmac1: ethernet@4510000")
if gmac1_span is None:
    ppu_anchor = "ppu: power-controller@7001400"
    soc = insert_before_node(soc, ppu_anchor, gmac1_block)
else:
    start, end = gmac1_span
    soc = soc[:start] + gmac1_block + soc[end:]


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

board = board.replace(
    "phy-handle = <&ext_rgmii_phy>;",
    "phy-handle = <&ext_rgmii0_phy>;",
    1,
)
board = board.replace(
    "ext_rgmii_phy: ethernet-phy@1 {",
    "ext_rgmii0_phy: ethernet-phy@1 {",
    1,
)


gmac1_board_block = """&gmac1 {
\tphy-mode = \"rgmii-id\";
\tphy-handle = <&ext_rgmii1_phy>;
\tphy-supply = <&reg_cldo4>;

\ttx-internal-delay-ps = <300>;
\trx-internal-delay-ps = <400>;

\tstatus = \"okay\";
};
"""

gmac1_board_span = node_span(board, "&gmac1 {")
if gmac1_board_span is None:
    gpu_anchor = "&gpu {"
    board = insert_before_node(board, gpu_anchor, gmac1_board_block)
else:
    start, end = gmac1_board_span
    board = board[:start] + gmac1_board_block + board[end:]


mdio1_block = """&mdio1 {
\text_rgmii1_phy: ethernet-phy@1 {
\t\tcompatible = \"ethernet-phy-ieee802.3-c22\";
\t\treg = <1>;
\t\treset-gpios = <&pio 9 16 GPIO_ACTIVE_LOW>; /* PJ16 */
\t\treset-assert-us = <10000>;
\t\treset-deassert-us = <150000>;
\t};
};
"""

mdio1_span = node_span(board, "&mdio1 {")
if mdio1_span is None:
    mmc0_anchor = "&mmc0 {"
    board = insert_before_node(board, mmc0_anchor, mdio1_block)
else:
    start, end = mdio1_span
    board = board[:start] + mdio1_block + board[end:]


cldo4_span = node_span(board, "reg_cldo4: cldo4")
if cldo4_span is None:
    sys.exit("GMAC1: CLDO4 regulator node not found")

start, end = cldo4_span
cldo4 = board[start:end]
if "regulator-enable-ramp-delay = <150000>;" not in cldo4:
    anchor = '\t\t\t\tregulator-name = "vcc-pj-phy";'
    if anchor not in cldo4:
        sys.exit("GMAC1: CLDO4 regulator-name anchor not found")
    cldo4 = cldo4.replace(
        anchor,
        anchor
        + "\n\t\t\t\t/* enough time for the PHY to fully power on */"
        + "\n\t\t\t\tregulator-enable-ramp-delay = <150000>;",
        1,
    )
    board = board[:start] + cldo4 + board[end:]


soc_path.write_text(soc.rstrip() + "\n", encoding="utf-8")
board_path.write_text(board.rstrip() + "\n", encoding="utf-8")
PYPORT

    git -C "$KERNEL_DIR" add -- "$SOC_DTSI" "$BOARD_DTS"

    if ! git -C "$KERNEL_DIR" diff --cached --quiet; then
        run git -C "$KERNEL_DIR" commit \
            -m "arm64: dts: allwinner: backport Cubie A5E GMAC1 enablement"
    fi
}

validate_gmac1_sources() {
    require_nonempty_file "$SOC_DTSI"
    require_nonempty_file "$BOARD_DTS"

    grep -F 'rgmii1_pins: rgmii1-pins' "$SOC_DTSI" >/dev/null ||
        die "RGMII1 pinctrl node is missing."

    grep -F 'allwinner,pinmux = <5>;' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 numeric pinmux encoding is missing."

    grep -F 'function = "gmac1";' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 pinctrl function property is missing."

    grep -F 'gmac1: ethernet@4510000' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 controller node is missing."

    grep -F 'compatible = "allwinner,sun55i-a523-gmac200"' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 controller compatible is missing."

    grep -F 'reg = <0x04510000 0x10000>;' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 register range is incorrect."

    grep -F 'interrupts = <GIC_SPI 47 IRQ_TYPE_LEVEL_HIGH>;' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 interrupt configuration is incorrect."

    grep -F 'power-domains = <&pck600 PD_VO1>;' "$SOC_DTSI" >/dev/null ||
        die "GMAC1 is not attached to PCK600 PD_VO1."

    grep -F 'ethernet1 = &gmac1;' "$BOARD_DTS" >/dev/null ||
        die "ethernet1 alias is missing."

    grep -F 'phy-handle = <&ext_rgmii0_phy>;' "$BOARD_DTS" >/dev/null ||
        die "GMAC0 PHY label was not normalized to ext_rgmii0_phy."

    grep -F 'ext_rgmii0_phy: ethernet-phy@1' "$BOARD_DTS" >/dev/null ||
        die "GMAC0 PHY label definition was not normalized."

    grep -Fx '&gmac1 {' "$BOARD_DTS" >/dev/null ||
        die "Cubie A5E GMAC1 board enablement is missing."

    grep -F 'phy-handle = <&ext_rgmii1_phy>;' "$BOARD_DTS" >/dev/null ||
        die "GMAC1 PHY handle is missing or incorrect."

    grep -F 'phy-supply = <&reg_cldo4>;' "$BOARD_DTS" >/dev/null ||
        die "GMAC1 PHY supply must use CLDO4."

    grep -F 'tx-internal-delay-ps = <300>;' "$BOARD_DTS" >/dev/null ||
        die "GMAC1 TX delay is missing or incorrect."

    grep -F 'rx-internal-delay-ps = <400>;' "$BOARD_DTS" >/dev/null ||
        die "GMAC1 RX delay is missing or incorrect."

    grep -F 'reset-gpios = <&pio 9 16 GPIO_ACTIVE_LOW>;' "$BOARD_DTS" >/dev/null ||
        die "GMAC1 PHY reset must use PJ16 active-low."

    grep -F 'regulator-enable-ramp-delay = <150000>;' "$BOARD_DTS" >/dev/null ||
        die "CLDO4 is missing the upstream 150 ms PHY power-on ramp delay."

    git -C "$KERNEL_DIR" diff --check ||
        die "Whitespace errors were detected after the GMAC1 DTS backport."
}

enable_gmac1_driver_config() {
    local scripts_config="$KERNEL_DIR/scripts/config"

    require_nonempty_file "$scripts_config"
    require_nonempty_file "$KERNEL_DIR/.config"

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

    grep -Fx 'CONFIG_STMMAC_ETH=y' "$KERNEL_DIR/.config" >/dev/null ||
        die "CONFIG_STMMAC_ETH was not built in."

    grep -Fx 'CONFIG_STMMAC_PLATFORM=y' "$KERNEL_DIR/.config" >/dev/null ||
        die "CONFIG_STMMAC_PLATFORM was not built in."

    grep -Fx 'CONFIG_DWMAC_SUN55I=y' "$KERNEL_DIR/.config" >/dev/null ||
        die "CONFIG_DWMAC_SUN55I was not built in."

    grep -Fx 'CONFIG_SUN55I_PCK600=y' "$KERNEL_DIR/.config" >/dev/null ||
        die "CONFIG_SUN55I_PCK600 was not built in."

    grep -Fx 'CONFIG_PM_GENERIC_DOMAINS=y' "$KERNEL_DIR/.config" >/dev/null ||
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
    local dtb_dir
    local dtb_base

    log "Compiling the Cubie A5E DTB as a mandatory GMAC1 gate."

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

    grep -F 'ethernet@4510000' "$GMAC1_DTB_REPORT" >/dev/null ||
        die "Compiled DTB does not contain GMAC1."

    grep -F 'allwinner,sun55i-a523-gmac200' "$GMAC1_DTB_REPORT" >/dev/null ||
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

    [[ "$(
        fdtget -t u \
            "$DTB_FILE" \
            /soc/i2c@7081400/pmic@34/regulators/cldo4 \
            regulator-enable-ramp-delay
    )" == "150000" ]] ||
        die "Compiled DTB is missing the 150 ms CLDO4 PHY ramp delay."

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
    {
        printf 'baseline=%s\n' "$LINUX_REF"
        printf 'baseline_commit=%s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'driver_source=upstream-linux-6.18-lts\n'
        printf 'pck600_source=upstream-linux-6.18-lts\n'
        printf 'dts_method=backport-upstream-post-6.18-gmac1-dts-enablement\n'
        printf 'gmac1_controller=0x04510000\n'
        printf 'gmac1_irq=47\n'
        printf 'gmac1_phy_reset=PJ16-active-low\n'
        printf 'gmac1_phy_supply=CLDO4\n'
        printf 'gmac1_phy_ramp_delay_us=150000\n'
        printf 'status=complete\n'
    } >"$STAMP"

    cp -a -- "$STAMP" "$GMAC1_EVIDENCE_REPORT"

    {
        printf 'Cubie A5E GMAC1 backport report\n'
        printf '================================\n'
        printf 'Status: PASS\n'
        printf 'Kernel baseline: %s\n' "$LINUX_REF"
        printf 'Kernel commit: %s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'GMAC200 driver: upstream in baseline\n'
        printf 'PCK600 power-domain driver: upstream in baseline\n'
        printf 'Stage 20 operation: DTS-only GMAC1 enablement backport\n'
        printf 'GMAC1 controller address: 0x04510000\n'
        printf 'GMAC1 IRQ: 47\n'
        printf 'GMAC1 PHY address: 1\n'
        printf 'GMAC1 PHY reset: PJ16 active-low\n'
        printf 'GMAC1 PHY supply: CLDO4\n'
        printf 'GMAC1 PHY supply ramp delay: 150000 us\n'
        printf 'GMAC1 power domain: PCK600 PD_VO1\n'
        printf 'GMAC1 pinctrl: PJ0-PJ9 and PJ11-PJ15, function gmac1, pinmux 5\n'
        printf 'GMAC1 delays: TX 300 ps, RX 400 ps\n'
        printf 'GMAC1 driver: dwmac-sun55i.c\n'
        printf 'GMAC1 compatible: allwinner,sun55i-a523-gmac200\n'
        printf 'Compiled DTB: %s\n' "$DTB_FILE"
        printf 'Decompiled DTB evidence: %s\n' "$GMAC1_DTB_REPORT"
        printf 'Backport evidence: %s\n' "$GMAC1_EVIDENCE_REPORT"
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

    abort_stale_git_operation
    validate_kernel_baseline
    configure_local_git_identity
    validate_upstream_618_prerequisites
    apply_gmac1_dts_backport
    validate_gmac1_sources
    enable_gmac1_driver_config
    build_and_validate_dtb
    write_stamp_and_reports

    log "Upstream GMAC200/PCK600 support and Cubie A5E GMAC1 DTS backport verified."
    log "DTB gate passed: $DTB_FILE"
    log "GMAC1 report: $GMAC1_REPORT"
}

main "$@"
