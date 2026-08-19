#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="SPI"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"

readonly EXPECTED_KERNEL_DIR="$BUILD_ROOT/linux-6.16-one-shot"
readonly SPI_DRIVER="$KERNEL_DIR/drivers/spi/spi-sun6i.c"
readonly SOC_DTSI="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi"
readonly BOARD_DTS="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts"
readonly SPI_STAMP="$KERNEL_DIR/.cubie-a5e-a523-spi-backport"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly SPI_REPORT="$LOG_DIR/spi-backport-report.txt"
else
    readonly SPI_REPORT="$BUILD_ROOT/.one-shot-spi-backport-report.txt"
fi

require_nonempty_file() {
    local path="$1"

    [[ -s "$path" ]] || die "Required file is missing or empty: $path"
}

validate_backport() {
    require_nonempty_file "$SPI_DRIVER"
    require_nonempty_file "$SOC_DTSI"
    require_nonempty_file "$BOARD_DTS"

    grep -qF \
        '{ .compatible = "allwinner,sun55i-a523-spi", .data = &sun50i_r329_spi_cfg },' \
        "$SPI_DRIVER" ||
        die "The A523 compatible is missing from spi-sun6i.c."

    grep -qF 'spi0_pc_pins: spi0-pc-pins {' "$SOC_DTSI" ||
        die "The A523 SPI0 PC pin group is missing."
    grep -qF 'pins = "PC2", "PC4", "PC12";' "$SOC_DTSI" ||
        die "The A523 SPI0 data/clock pins are incorrect."
    grep -qF 'spi0_cs0_pc_pin: spi0-cs0-pc-pin {' "$SOC_DTSI" ||
        die "The A523 SPI0 CS0 pin group is missing."
    grep -qF 'pins = "PC3";' "$SOC_DTSI" ||
        die "The A523 SPI0 CS0 pin is incorrect."
    grep -qF 'spi0: spi@4025000 {' "$SOC_DTSI" ||
        die "The A523 SPI0 controller node is missing."
    grep -qF 'compatible = "allwinner,sun55i-a523-spi";' "$SOC_DTSI" ||
        die "The A523 SPI0 controller compatible is missing."
    grep -qF 'reg = <0x04025000 0x1000>;' "$SOC_DTSI" ||
        die "The A523 SPI0 register range is incorrect."
    grep -qF 'interrupts = <GIC_SPI 16 IRQ_TYPE_LEVEL_HIGH>;' "$SOC_DTSI" ||
        die "The A523 SPI0 interrupt is incorrect."
    grep -qF 'dmas = <&dma 22>, <&dma 22>;' "$SOC_DTSI" ||
        die "The A523 SPI0 DMA requests are incorrect."

    grep -qF '&spi0 {' "$BOARD_DTS" ||
        die "Cubie A5E SPI0 enablement is missing."
    grep -qF 'pinctrl-0 = <&spi0_pc_pins>, <&spi0_cs0_pc_pin>;' \
        "$BOARD_DTS" ||
        die "Cubie A5E SPI0 pinctrl wiring is incorrect."
    grep -qF 'flash@0 {' "$BOARD_DTS" ||
        die "Cubie A5E SPI-NOR node is missing."
    grep -qF 'compatible = "jedec,spi-nor";' "$BOARD_DTS" ||
        die "Cubie A5E SPI-NOR compatible is missing."
    grep -qF 'spi-max-frequency = <50000000>;' "$BOARD_DTS" ||
        die "Cubie A5E SPI-NOR frequency is incorrect."
}

completed_backport_available() {
    [[ -s "$SPI_STAMP" ]] || return 1
    grep -Fxq 'revision=a523-spi-mainline-backport-v1' "$SPI_STAMP" ||
        return 1
    grep -Fxq 'status=complete' "$SPI_STAMP" || return 1
    grep -qF \
        '{ .compatible = "allwinner,sun55i-a523-spi", .data = &sun50i_r329_spi_cfg },' \
        "$SPI_DRIVER" || return 1
    grep -qF 'spi0: spi@4025000 {' "$SOC_DTSI" || return 1
    grep -qF '&spi0 {' "$BOARD_DTS" || return 1
    grep -qF 'compatible = "jedec,spi-nor";' "$BOARD_DTS" || return 1
    return 0
}

apply_backport() {
    log "Applying the reviewed upstream A523 SPI support to Linux 6.16."

    export BOARD_DTS SOC_DTSI SPI_DRIVER
    run python3 <<'PY'
from pathlib import Path
import os
import re

driver_path = Path(os.environ["SPI_DRIVER"])
soc_path = Path(os.environ["SOC_DTSI"])
board_path = Path(os.environ["BOARD_DTS"])


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")


driver = read(driver_path)
driver_compatible = 'allwinner,sun55i-a523-spi'

if driver_compatible not in driver:
    table = re.search(
        r"(static const struct of_device_id sun6i_spi_match\[\] = \{)"
        r"(?P<body>.*?)"
        r"(?P<sentinel>\n[ \t]*\{\}[ \t]*\n\};)",
        driver,
        flags=re.DOTALL,
    )
    if table is None:
        raise SystemExit("SPI backport: sun6i SPI match table anchor is missing")
    if 'allwinner,sun50i-r329-spi' not in table.group("body"):
        raise SystemExit("SPI backport: R329 SPI compatible anchor is missing")

    addition = """
    /*
     * A523's SPI controller has a combined RX buffer + FIFO counter
     * at offset 0x400, instead of split buffer count in FIFO status
     * register. But in practice we only care about the FIFO level.
     */
    { .compatible = "allwinner,sun55i-a523-spi", .data = &sun50i_r329_spi_cfg },
"""
    insert_at = table.start("sentinel")
    driver = driver[:insert_at] + addition + driver[insert_at:]
    write(driver_path, driver)

soc = read(soc_path)

if "spi0_pc_pins: spi0-pc-pins" not in soc:
    pin_anchor = re.search(
        r"^(?P<indent>[ \t]*)uart0_[A-Za-z0-9_]+:\s*uart0-[^\n]*\{",
        soc,
        flags=re.MULTILINE,
    )
    if pin_anchor is None:
        raise SystemExit("SPI backport: A523 main pinctrl insertion anchor is missing")

    indent = pin_anchor.group("indent")
    inner = indent + "\t"
    pin_nodes = (
        f"{indent}/omit-if-no-ref/\n"
        f"{indent}spi0_pc_pins: spi0-pc-pins {{\n"
        f'{inner}pins = "PC2", "PC4", "PC12";\n'
        f'{inner}function = "spi0";\n'
        f"{inner}allwinner,pinmux = <4>;\n"
        f"{indent}}};\n\n"
        f"{indent}/omit-if-no-ref/\n"
        f"{indent}spi0_cs0_pc_pin: spi0-cs0-pc-pin {{\n"
        f'{inner}pins = "PC3";\n'
        f'{inner}function = "spi0";\n'
        f"{inner}allwinner,pinmux = <4>;\n"
        f"{indent}}};\n\n"
    )
    soc = soc[:pin_anchor.start()] + pin_nodes + soc[pin_anchor.start():]

if "spi0: spi@4025000" not in soc:
    controller_anchor = re.search(
        r"^(?P<indent>[ \t]*)usb_otg:\s*usb@4100000\s*\{",
        soc,
        flags=re.MULTILINE,
    )
    if controller_anchor is None:
        raise SystemExit("SPI backport: A523 SPI controller insertion anchor is missing")

    indent = controller_anchor.group("indent")
    inner = indent + "\t"
    controller = (
        f"{indent}spi0: spi@4025000 {{\n"
        f'{inner}compatible = "allwinner,sun55i-a523-spi";\n'
        f"{inner}reg = <0x04025000 0x1000>;\n"
        f"{inner}interrupts = <GIC_SPI 16 IRQ_TYPE_LEVEL_HIGH>;\n"
        f"{inner}clocks = <&ccu CLK_BUS_SPI0>, <&ccu CLK_SPI0>;\n"
        f'{inner}clock-names = "ahb", "mod";\n'
        f"{inner}dmas = <&dma 22>, <&dma 22>;\n"
        f'{inner}dma-names = "rx", "tx";\n'
        f"{inner}resets = <&ccu RST_BUS_SPI0>;\n"
        f'{inner}status = "disabled";\n'
        f"{inner}#address-cells = <1>;\n"
        f"{inner}#size-cells = <0>;\n"
        f"{indent}}};\n\n"
    )
    soc = soc[:controller_anchor.start()] + controller + soc[controller_anchor.start():]

write(soc_path, soc)

board = read(board_path)

if re.search(r"^&spi0\s*\{", board, flags=re.MULTILINE) is None:
    board += """

&spi0 {
	pinctrl-names = "default";
	pinctrl-0 = <&spi0_pc_pins>, <&spi0_cs0_pc_pin>;
	status = "okay";

	flash@0 {
		compatible = "jedec,spi-nor";
		reg = <0>;
		spi-max-frequency = <50000000>;
	};
};
"""

write(board_path, board)
PY
}

write_report() {
    {
        printf 'Cubie A5E A523 SPI backport report\n'
        printf '==================================\n'
        printf 'Status: PASS\n'
        printf 'Revision: a523-spi-mainline-backport-v1\n'
        printf 'Linux base: 6.16\n'
        printf 'Controller compatible: allwinner,sun55i-a523-spi\n'
        printf 'Controller address: 0x04025000\n'
        printf 'Controller interrupt: 16\n'
        printf 'Controller DMA request: 22\n'
        printf 'SPI0 pins: PC2 PC4 PC12\n'
        printf 'SPI0 CS0 pin: PC3\n'
        printf 'SPI0 pinmux: 4\n'
        printf 'SPI-NOR compatible: jedec,spi-nor\n'
        printf 'SPI-NOR maximum frequency: 50000000\n'
        printf 'Driver: %s\n' "$SPI_DRIVER"
        printf 'SoC DTSI: %s\n' "$SOC_DTSI"
        printf 'Board DTS: %s\n' "$BOARD_DTS"
    } >"$SPI_REPORT"
}

main() {
    require_command grep
    require_command python3
    require_command readlink

    [[ "$(readlink -f -- "$KERNEL_DIR")" == \
       "$(readlink -f -- "$EXPECTED_KERNEL_DIR")" ]] ||
        die "Unexpected kernel directory: $KERNEL_DIR"

    require_nonempty_file "$SPI_DRIVER"
    require_nonempty_file "$SOC_DTSI"
    require_nonempty_file "$BOARD_DTS"

    if completed_backport_available; then
        log "Using the validated cached A523 SPI backport."
        write_report
        return 0
    fi

    rm -f -- "$SPI_STAMP"
    apply_backport
    validate_backport

    {
        printf 'revision=a523-spi-mainline-backport-v1\n'
        printf 'status=complete\n'
    } >"$SPI_STAMP"

    write_report
    log "A523 SPI controller and Cubie A5E SPI-NOR enablement validated."
    log "SPI report: $SPI_REPORT"
}

main "$@"
