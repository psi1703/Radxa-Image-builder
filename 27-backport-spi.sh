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
readonly SPI_REVISION="a523-spi-mainline-backport-v2-no-dma"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly SPI_REPORT="$LOG_DIR/spi-backport-report.txt"
else
    readonly SPI_REPORT="$BUILD_ROOT/.one-shot-spi-backport-report.txt"
fi

spi0_has_no_dma_properties() {
    python3 - "$SOC_DTSI" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
match = re.search(r"^[ \t]*spi0:\s*spi@4025000\s*\{", text, flags=re.MULTILINE)
if match is None:
    raise SystemExit(1)

depth = 0
end = None
for index in range(match.start(), len(text)):
    char = text[index]
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            end = index + 1
            break

if end is None:
    raise SystemExit(1)

node = text[match.start():end]
if re.search(r"^[ \t]*(?:dmas|dma-names)\s*=", node, flags=re.MULTILINE):
    raise SystemExit(1)
PY
}

validate_backport() {
    need_nonempty_file "$SPI_DRIVER"
    need_nonempty_file "$SOC_DTSI"
    need_nonempty_file "$BOARD_DTS"

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
    grep -qF 'clocks = <&ccu CLK_BUS_SPI0>, <&ccu CLK_SPI0>;' "$SOC_DTSI" ||
        die "The A523 SPI0 clocks are incorrect."
    grep -qF 'clock-names = "ahb", "mod";' "$SOC_DTSI" ||
        die "The A523 SPI0 clock names are incorrect."
    grep -qF 'resets = <&ccu RST_BUS_SPI0>;' "$SOC_DTSI" ||
        die "The A523 SPI0 reset is incorrect."

    spi0_has_no_dma_properties ||
        die "The A523 SPI0 node still contains unsupported DMA properties."

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
    grep -Fxq "revision=$SPI_REVISION" "$SPI_STAMP" || return 1
    grep -Fxq 'status=complete' "$SPI_STAMP" || return 1
    grep -qF \
        '{ .compatible = "allwinner,sun55i-a523-spi", .data = &sun50i_r329_spi_cfg },' \
        "$SPI_DRIVER" || return 1
    grep -qF 'spi0: spi@4025000 {' "$SOC_DTSI" || return 1
    grep -qF '&spi0 {' "$BOARD_DTS" || return 1
    grep -qF 'compatible = "jedec,spi-nor";' "$BOARD_DTS" || return 1
    spi0_has_no_dma_properties || return 1
    return 0
}

apply_backport() {
    log "Applying the reviewed A523 SPI support to Linux 6.16 without unsupported DMA references."

    export BOARD_DTS SOC_DTSI SPI_DRIVER
    run python3 <<'PY'
from pathlib import Path
import os
import re


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")


def node_span(text: str, pattern: str) -> tuple[int, int] | None:
    match = re.search(pattern, text, flags=re.MULTILINE)
    if match is None:
        return None

    depth = 0
    for index in range(match.start(), len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if end < len(text) and text[end] == ";":
                    end += 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return match.start(), end
    raise SystemExit("SPI backport: unterminated SPI0 controller node")


driver_path = Path(os.environ["SPI_DRIVER"])
soc_path = Path(os.environ["SOC_DTSI"])
board_path = Path(os.environ["BOARD_DTS"])

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

spi_span = node_span(soc, r"^[ \t]*spi0:\s*spi@4025000\s*\{")
if spi_span is None:
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
        f"{inner}resets = <&ccu RST_BUS_SPI0>;\n"
        f'{inner}status = "disabled";\n'
        f"{inner}#address-cells = <1>;\n"
        f"{inner}#size-cells = <0>;\n"
        f"{indent}}};\n\n"
    )
    soc = soc[:controller_anchor.start()] + controller + soc[controller_anchor.start():]
else:
    start, end = spi_span
    controller = soc[start:end]
    controller = re.sub(
        r"^[ \t]*dmas\s*=\s*[^;]+;[ \t]*\n?",
        "",
        controller,
        flags=re.MULTILINE,
    )
    controller = re.sub(
        r"^[ \t]*dma-names\s*=\s*[^;]+;[ \t]*\n?",
        "",
        controller,
        flags=re.MULTILINE,
    )
    soc = soc[:start] + controller + soc[end:]

write(soc_path, soc)

board = read(board_path)
if re.search(r"^&spi0\s*\{", board, flags=re.MULTILINE) is None:
    board += """

&spi0 {
\tpinctrl-names = "default";
\tpinctrl-0 = <&spi0_pc_pins>, <&spi0_cs0_pc_pin>;
\tstatus = "okay";

\tflash@0 {
\t\tcompatible = "jedec,spi-nor";
\t\treg = <0>;
\t\tspi-max-frequency = <50000000>;
\t};
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
        printf 'Revision: %s\n' "$SPI_REVISION"
        printf 'Linux base: 6.16\n'
        printf 'Controller compatible: allwinner,sun55i-a523-spi\n'
        printf 'Controller address: 0x04025000\n'
        printf 'Controller interrupt: 16\n'
        printf 'Controller DMA properties: omitted (A523 6.16 DTSI has no dma provider label)\n'
        printf 'Transfer fallback: FIFO/PIO when DMA channels are unavailable\n'
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
    need_cmd grep
    need_cmd python3
    need_cmd readlink

    [[ "$(readlink -f -- "$KERNEL_DIR")" == \
       "$(readlink -f -- "$EXPECTED_KERNEL_DIR")" ]] ||
        die "Unexpected kernel directory: $KERNEL_DIR"

    need_nonempty_file "$SPI_DRIVER"
    need_nonempty_file "$SOC_DTSI"
    need_nonempty_file "$BOARD_DTS"

    if completed_backport_available; then
        log "Using the validated cached A523 SPI backport."
        write_report
        return 0
    fi

    rm -f -- "$SPI_STAMP"
    apply_backport
    validate_backport

    {
        printf 'revision=%s\n' "$SPI_REVISION"
        printf 'status=complete\n'
    } >"$SPI_STAMP"

    write_report
    log "A523 SPI controller and Cubie A5E SPI-NOR enablement validated without DMA properties."
    log "SPI report: $SPI_REPORT"
}

main "$@"
