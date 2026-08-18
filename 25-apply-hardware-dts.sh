#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="DTS"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"

readonly DTS="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts"
readonly DTB="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"
readonly SOC_DTSI="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi"
readonly PINCTRL_DRIVER="$KERNEL_DIR/drivers/pinctrl/sunxi/pinctrl-sun55i-a523.c"
readonly R_PINCTRL_DRIVER="$KERNEL_DIR/drivers/pinctrl/sunxi/pinctrl-sun55i-a523-r.c"
readonly MARK_BEGIN='/* CUBIE_A5E_ONE_SHOT_BEGIN */'
readonly MARK_END='/* CUBIE_A5E_ONE_SHOT_END */'
readonly BACKUP="$DTS.before-one-shot"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly DTS_REPORT="$LOG_DIR/hardware-dts-report.txt"
    readonly DTB_DECOMPILED="$LOG_DIR/sun55i-a527-cubie-a5e.compiled.dts"
else
    readonly DTS_REPORT="$BUILD_ROOT/.one-shot-hardware-dts-report.txt"
    readonly DTB_DECOMPILED="$BUILD_ROOT/.one-shot-compiled-board.dts"
fi

require_command() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is missing: $command_name"
}

require_nonempty_file() {
    local path="$1"

    [[ -s "$path" ]] ||
        die "Required file is missing or empty: $path"
}

print_managed_block() {
    awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
        $0 == begin { printing = 1 }
        printing { print }
        $0 == end { printing = 0 }
    ' "$DTS"
}

remove_existing_managed_block() {
    log "Removing any existing one-shot DTS block."

    python3 - "$DTS" "$MARK_BEGIN" "$MARK_END" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]

text = path.read_text(encoding="utf-8")

while begin in text:
    begin_index = text.index(begin)

    if end not in text[begin_index:]:
        raise SystemExit(
            f"Found begin marker without matching end marker in {path}"
        )

    end_index = text.index(end, begin_index) + len(end)
    text = text[:begin_index] + text[end_index:]

path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY
}

apply_wifi_support_backports() {
    log "Applying tested Cubie A5E Wi-Fi power and GPIO fixes."

    # The transformer is supplied by the heredoc on stdin.  Keep the explicit
    # "-" so Python does not try to execute the DTS path as Python source.
    python3 - \
        "$DTS" \
        "$SOC_DTSI" \
        "$PINCTRL_DRIVER" \
        "$R_PINCTRL_DRIVER" <<'PY'
from pathlib import Path
import sys

board_path = Path(sys.argv[1])
soc_path = Path(sys.argv[2])
pinctrl_path = Path(sys.argv[3])
r_pinctrl_path = Path(sys.argv[4])

board = board_path.read_text(encoding="utf-8")
soc = soc_path.read_text(encoding="utf-8")
pinctrl = pinctrl_path.read_text(encoding="utf-8")
r_pinctrl = r_pinctrl_path.read_text(encoding="utf-8")


def node_span(text: str, marker: str):
    marker_pos = text.find(marker)
    if marker_pos < 0:
        raise SystemExit(f"Wi-Fi: node marker not found: {marker}")

    line_start = text.rfind("\n", 0, marker_pos) + 1
    open_brace = text.find("{", marker_pos)
    if open_brace < 0:
        raise SystemExit(f"Wi-Fi: opening brace not found for {marker}")

    depth = 0
    for pos in range(open_brace, len(text)):
        char = text[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                semicolon = text.find(";", pos)
                if semicolon < 0:
                    raise SystemExit(
                        f"Wi-Fi: terminating semicolon not found for {marker}"
                    )
                line_end = text.find("\n", semicolon)
                if line_end < 0:
                    line_end = len(text)
                else:
                    line_end += 1
                return line_start, line_end, open_brace

    raise SystemExit(f"Wi-Fi: closing brace not found for {marker}")


bldo1_start, bldo1_end, bldo1_open = node_span(
    board, "reg_bldo1: bldo1"
)
bldo1 = board[bldo1_start:bldo1_end]

if "regulator-always-on;" not in bldo1:
    insertion = board.find("\n", bldo1_open)
    if insertion < 0:
        raise SystemExit("Wi-Fi: BLDO1 opening line is malformed")
    board = (
        board[:insertion + 1]
        + "\t\t\t\tregulator-always-on;\n"
        + board[insertion + 1:]
    )

pio_start, pio_end, _ = node_span(soc, "pio: pinctrl@2000000")
pio_node = soc[pio_start:pio_end]

if "<GIC_SPI 67 IRQ_TYPE_LEVEL_HIGH>" not in pio_node:
    old = "interrupts = <GIC_SPI 69 IRQ_TYPE_LEVEL_HIGH>,"
    new = (
        "interrupts = <GIC_SPI 67 IRQ_TYPE_LEVEL_HIGH>,\n"
        "\t\t\t\t     <GIC_SPI 69 IRQ_TYPE_LEVEL_HIGH>,"
    )

    if old not in pio_node:
        raise SystemExit(
            "Wi-Fi: A523 main pinctrl interrupt insertion anchor not found"
        )

    pio_node = pio_node.replace(old, new, 1)
    soc = soc[:pio_start] + pio_node + soc[pio_end:]

irq_mux_line = "\t.irq_read_needs_mux = true,\n"

for path, text in (
    (pinctrl_path, pinctrl),
    (r_pinctrl_path, r_pinctrl),
):
    if text.count(irq_mux_line) > 1:
        raise SystemExit(
            f"Wi-Fi: unexpected duplicate IRQ remux flags in {path}"
        )

pinctrl = pinctrl.replace(irq_mux_line, "")
r_pinctrl = r_pinctrl.replace(irq_mux_line, "")

board_path.write_text(board, encoding="utf-8")
soc_path.write_text(soc, encoding="utf-8")
pinctrl_path.write_text(pinctrl, encoding="utf-8")
r_pinctrl_path.write_text(r_pinctrl, encoding="utf-8")
PY
}

append_hardware_configuration() {
    log "Appending Cubie A5E GMAC0 and AIC8800 SDIO configuration."

    cat >>"$DTS" <<'EOF'

/* CUBIE_A5E_ONE_SHOT_BEGIN */

/*
 * GMAC1 is owned exclusively by 20-backport-gmac1.sh.
 * This block configures only the verified GMAC0 and AIC8800 SDIO hardware.
 */

/ {
        reg_3v3_wifi: 3v3-wifi {
                compatible = "regulator-fixed";
                regulator-name = "3v3-wifi";
                regulator-min-microvolt = <3300000>;
                regulator-max-microvolt = <3300000>;
                vin-supply = <&reg_vcc5v>;
                gpio = <&r_pio 0 7 GPIO_ACTIVE_HIGH>;
                enable-active-high;
        };

        wifi_pwrseq: wifi-pwrseq {
                compatible = "mmc-pwrseq-simple";
                reset-gpios = <&r_pio 1 1 GPIO_ACTIVE_LOW>;
                post-power-on-delay-ms = <200>;
        };

};

&gmac0 {
        phy-mode = "rgmii";
        allwinner,tx-delay-ps = <200>;
        allwinner,rx-delay-ps = <400>;
        phy-handle = <&cubie_a5e_gmac0_phy>;
        status = "okay";
};

&mdio0 {
        status = "okay";

        /delete-node/ ethernet-phy@1;

        cubie_a5e_gmac0_phy: ethernet-phy@1 {
                compatible = "ethernet-phy-ieee802.3-c22";
                reg = <1>;
                max-speed = <1000>;
                reset-gpios = <&pio 7 8 GPIO_ACTIVE_LOW>;
                reset-assert-us = <50000>;
                reset-deassert-us = <200000>;
        };
};

&mmc1 {
        pinctrl-names = "default";
        pinctrl-0 = <&mmc1_pins>;
        bus-width = <4>;
        non-removable;
        max-frequency = <40000000>;
        mmc-pwrseq = <&wifi_pwrseq>;
        vmmc-supply = <&reg_3v3_wifi>;
        vqmmc-supply = <&reg_bldo1>;
        status = "okay";

        wifi@1 {
                reg = <1>;
                interrupt-parent = <&r_pio>;
                interrupts = <1 0 IRQ_TYPE_LEVEL_LOW>;
                interrupt-names = "host-wake";
        };
};

/* CUBIE_A5E_ONE_SHOT_END */
EOF
}

validate_source_dts() {
    log "Validating source DTS modifications."

    [[ "$(grep -cF "$MARK_BEGIN" "$DTS")" -eq 1 ]] ||
        die "DTS does not contain exactly one managed begin marker."

    [[ "$(grep -cF "$MARK_END" "$DTS")" -eq 1 ]] ||
        die "DTS does not contain exactly one managed end marker."

    grep -qF 'reg_3v3_wifi: 3v3-wifi {' "$DTS" ||
        die "PL7-controlled Wi-Fi 3.3 V regulator is missing."

    grep -qF 'regulator-name = "3v3-wifi";' "$DTS" ||
        die "Wi-Fi 3.3 V regulator name is incorrect."

    grep -qF 'gpio = <&r_pio 0 7 GPIO_ACTIVE_HIGH>;' "$DTS" ||
        die "Wi-Fi 3.3 V regulator is not controlled by PL7."

    grep -qF 'enable-active-high;' "$DTS" ||
        die "Wi-Fi PL7 regulator is not active-high."

    grep -qF 'wifi_pwrseq: wifi-pwrseq {' "$DTS" ||
        die "Wi-Fi MMC power-sequence node is missing."

    grep -qF 'reset-gpios = <&r_pio 1 1 GPIO_ACTIVE_LOW>;' "$DTS" ||
        die "Wi-Fi reset is not connected to PM1 active-low."

    grep -qF 'post-power-on-delay-ms = <200>;' "$DTS" ||
        die "Wi-Fi power-on delay is not 200 ms."

    grep -qF 'reg_bldo1: bldo1 {' "$DTS" ||
        die "BLDO1 regulator node is missing."

    python3 - "$DTS" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "reg_bldo1: bldo1"
start = text.find(marker)
if start < 0:
    raise SystemExit("BLDO1 regulator node is missing")

open_brace = text.find("{", start)
depth = 0
end = -1
for pos in range(open_brace, len(text)):
    if text[pos] == "{":
        depth += 1
    elif text[pos] == "}":
        depth -= 1
        if depth == 0:
            end = pos
            break

if end < 0 or "regulator-always-on;" not in text[start:end]:
    raise SystemExit("BLDO1 is not marked regulator-always-on")
PY

    if print_managed_block |
        grep -Eq 'sunxi-rfkill|sunxi-wlan|wlan_busnum|wlan_power'; then
        die "Managed DTS block must use native MMC/SDIO power and must not add the vendor RFKill contract."
    fi

    if print_managed_block |
        grep -qF '&mmc1_pins {'; then
        die "Managed DTS block must retain the SoC mmc1 pin drive strength and must not override mmc1_pins."
    fi

    grep -qF 'pinctrl-0 = <&mmc1_pins>;' "$DTS" ||
        die "mmc1 pinctrl is not explicit."

    grep -qF 'max-frequency = <40000000>;' "$DTS" ||
        die "mmc1 maximum clock is not limited to the tested 40 MHz."

    grep -qF 'mmc-pwrseq = <&wifi_pwrseq>;' "$DTS" ||
        die "mmc1 is not connected to the Wi-Fi power sequence."

    grep -qF 'vmmc-supply = <&reg_3v3_wifi>;' "$DTS" ||
        die "mmc1 vmmc supply is not connected to the PL7 3.3 V rail."

    grep -qF 'vqmmc-supply = <&reg_bldo1>;' "$DTS" ||
        die "mmc1 vqmmc supply is not connected to BLDO1 at 1.8 V."

    grep -qF 'wifi@1 {' "$DTS" ||
        die "AIC8800 SDIO function node is missing."

    grep -qF 'interrupt-parent = <&r_pio>;' "$DTS" ||
        die "AIC8800 host-wake interrupt parent is not R_PIO."

    grep -qF 'interrupts = <1 0 IRQ_TYPE_LEVEL_LOW>;' "$DTS" ||
        die "AIC8800 host-wake interrupt is not PM0 active-low."

    grep -qF 'interrupt-names = "host-wake";' "$DTS" ||
        die "AIC8800 host-wake interrupt name is missing."

    if print_managed_block |
        grep -qF 'vmmc-supply = <&reg_bldo1>;'; then
        die "mmc1 vmmc must not use the BLDO1 I/O rail."
    fi

    if print_managed_block |
        grep -Eq '^&gmac1|^&mdio1|ethernet1[[:space:]]*='; then
        die "Stage 25 must not modify GMAC1."
    fi

    grep -qF '<GIC_SPI 67 IRQ_TYPE_LEVEL_HIGH>,' "$SOC_DTSI" ||
        die "A523 main pinctrl is missing the GPIO bank interrupt."

    if grep -qF '.irq_read_needs_mux = true,' \
        "$PINCTRL_DRIVER" "$R_PINCTRL_DRIVER"; then
        die "A523 pinctrl drivers still enable invalid IRQ remuxing."
    fi
}

build_board_dtb() {
    log "Compiling Cubie A5E Device Tree."

    run make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        allwinner/sun55i-a527-cubie-a5e.dtb

    require_nonempty_file "$DTB"
}

decompile_and_validate_dtb() {
    local bldo1_phandle
    local gpio_bank
    local gpio_flags
    local gpio_phandle
    local gpio_pin
    local mmc_pwrseq
    local mmc_vmmc
    local mmc_vqmmc
    local pio_pg_supply
    local pwrseq_gpio_bank
    local pwrseq_gpio_flags
    local pwrseq_gpio_phandle
    local pwrseq_gpio_pin
    local pwrseq_phandle
    local r_pio_phandle
    local wifi_3v3_phandle
    local wifi_interrupt_parent

    log "Decompiling and validating the generated board DTB."

    rm -f -- "$DTB_DECOMPILED"

    run dtc \
        -I dtb \
        -O dts \
        -Wno-unit_address_vs_reg \
        -o "$DTB_DECOMPILED" \
        "$DTB"

    require_nonempty_file "$DTB_DECOMPILED"

    if grep -Eq 'allwinner,sunxi-rfkill|allwinner,sunxi-wlan|wlan_busnum|wlan_power' \
        "$DTB_DECOMPILED"; then
        die "Compiled DTB still contains the obsolete vendor RFKill/rescan contract."
    fi

    grep -qF 'regulator-name = "3v3-wifi";' \
        "$DTB_DECOMPILED" ||
        die "Compiled DTB lacks the Wi-Fi 3.3 V regulator."

    grep -qF 'non-removable;' "$DTB_DECOMPILED" ||
        die "Compiled DTB does not mark Wi-Fi non-removable."

    [[ "$(
        fdtget -t s \
            "$DTB" \
            /soc/pinctrl@2000000/mmc1-pins \
            pins
    )" == "PG0 PG1 PG2 PG3 PG4 PG5" ]] ||
        die "Compiled DTB does not contain the mmc1 PG0-PG5 pin group."

    [[ "$(fdtget -t s "$DTB" /soc/mmc@4021000 status)" == "okay" ]] ||
        die "Compiled DTB does not enable mmc1."

    [[ "$(fdtget -t u "$DTB" /soc/mmc@4021000 max-frequency)" == "40000000" ]] ||
        die "Compiled DTB does not cap mmc1 at the tested 40 MHz."

    [[ "$(fdtget -t u "$DTB" /soc/mmc@4021000/wifi@1 reg)" == "1" ]] ||
        die "Compiled DTB lacks the AIC8800 SDIO function at address 1."

    wifi_3v3_phandle="$(fdtget -t x "$DTB" /3v3-wifi phandle)"
    mmc_vmmc="$(fdtget -t x "$DTB" /soc/mmc@4021000 vmmc-supply)"
    mmc_vqmmc="$(fdtget -t x "$DTB" /soc/mmc@4021000 vqmmc-supply)"
    pwrseq_phandle="$(fdtget -t x "$DTB" /wifi-pwrseq phandle)"
    mmc_pwrseq="$(fdtget -t x "$DTB" /soc/mmc@4021000 mmc-pwrseq)"

    [[ "$mmc_vmmc" == "$wifi_3v3_phandle" ]] ||
        die "Compiled DTB does not connect mmc1 vmmc to the PL7 3.3 V rail."

    [[ "$mmc_pwrseq" == "$pwrseq_phandle" ]] ||
        die "Compiled DTB does not connect mmc1 to the Wi-Fi power sequence."

    IFS=' ' read -r gpio_phandle gpio_bank gpio_pin gpio_flags < <(
        fdtget -t x "$DTB" /3v3-wifi gpio
    )

    [[ -n "$gpio_phandle" &&
       "$gpio_bank" == "0" &&
       "$gpio_pin" == "7" &&
       "$gpio_flags" == "0" ]] ||
        die "Compiled DTB does not control Wi-Fi 3.3 V with PL7 active-high."

    IFS=' ' read -r \
        pwrseq_gpio_phandle \
        pwrseq_gpio_bank \
        pwrseq_gpio_pin \
        pwrseq_gpio_flags < <(
        fdtget -t x "$DTB" /wifi-pwrseq reset-gpios
    )

    [[ -n "$pwrseq_gpio_phandle" &&
       "$pwrseq_gpio_bank" == "1" &&
       "$pwrseq_gpio_pin" == "1" &&
       "$pwrseq_gpio_flags" == "1" ]] ||
        die "Compiled DTB does not reset Wi-Fi through PM1 active-low."

    [[ "$(
        fdtget -t u \
            "$DTB" \
            /wifi-pwrseq \
            post-power-on-delay-ms
    )" == "200" ]] ||
        die "Compiled DTB does not wait 200 ms after Wi-Fi power-on."

    bldo1_phandle="$(
        fdtget -t x \
            "$DTB" \
            /soc/i2c@7081400/pmic@34/regulators/bldo1 \
            phandle
    )"
    pio_pg_supply="$(
        fdtget -t x "$DTB" /soc/pinctrl@2000000 vcc-pg-supply
    )"

    [[ "$pio_pg_supply" == "$bldo1_phandle" ]] ||
        die "Compiled DTB does not connect the PG I/O domain to BLDO1."

    [[ "$mmc_vqmmc" == "$bldo1_phandle" ]] ||
        die "Compiled DTB does not connect mmc1 vqmmc to BLDO1."

    fdtget -p \
        "$DTB" \
        /soc/i2c@7081400/pmic@34/regulators/bldo1 |
        grep -Fxq 'regulator-always-on' ||
        die "Compiled DTB does not keep BLDO1 enabled."

    [[ "$(
        fdtget -t s \
            "$DTB" \
            /soc/i2c@7081400/pmic@34/regulators/bldo1 \
            regulator-name
    )" == "vcc-pg-iowifi" ]] ||
        die "Compiled DTB does not name BLDO1 as vcc-pg-iowifi."

    [[ "$(
        fdtget -t u \
            "$DTB" \
            /soc/i2c@7081400/pmic@34/regulators/bldo1 \
            regulator-min-microvolt
    )" == "1800000" ]] ||
        die "Compiled DTB does not keep BLDO1 at the required 1.8 V."

    [[ "$(
        fdtget -t u \
            "$DTB" \
            /soc/i2c@7081400/pmic@34/regulators/bldo1 \
            regulator-max-microvolt
    )" == "1800000" ]] ||
        die "Compiled DTB does not cap BLDO1 at the required 1.8 V."

    [[ "$(
        fdtget -t u \
            "$DTB" \
            /soc/pinctrl@2000000/mmc1-pins \
            drive-strength
    )" == "30" ]] ||
        die "Compiled DTB does not retain the tested 30 mA mmc1 pin drive strength."

    r_pio_phandle="$(fdtget -t x "$DTB" /soc/pinctrl@7022000 phandle)"

    [[ "$gpio_phandle" == "$r_pio_phandle" ]] ||
        die "Compiled DTB does not source the PL7 Wi-Fi enable from R_PIO."

    [[ "$pwrseq_gpio_phandle" == "$r_pio_phandle" ]] ||
        die "Compiled DTB does not source the PM1 Wi-Fi reset from R_PIO."

    wifi_interrupt_parent="$(
        fdtget -t x \
            "$DTB" \
            /soc/mmc@4021000/wifi@1 \
            interrupt-parent
    )"

    [[ "$wifi_interrupt_parent" == "$r_pio_phandle" ]] ||
        die "Compiled DTB does not route AIC8800 host-wake through R_PIO."

    [[ "$(
        fdtget -t u \
            "$DTB" \
            /soc/mmc@4021000/wifi@1 \
            interrupts
    )" == "1 0 8" ]] ||
        die "Compiled DTB does not route AIC8800 host-wake from PM0 active-low."

    [[ "$(
        fdtget -t s \
            "$DTB" \
            /soc/mmc@4021000/wifi@1 \
            interrupt-names
    )" == "host-wake" ]] ||
        die "Compiled DTB does not name the AIC8800 host-wake interrupt."
}

write_report() {
    {
        printf 'Cubie A5E hardware DTS report\n'
        printf '==============================\n'
        printf 'Source DTS: %s\n' "$DTS"
        printf 'Compiled DTB: %s\n' "$DTB"
        printf 'Backup DTS: %s\n' "$BACKUP"
        printf 'Decompiled DTB: %s\n' "$DTB_DECOMPILED"
        printf 'GMAC0 enabled: yes\n'
        printf 'GMAC1 modified by this stage: no\n'
        printf 'Wi-Fi SDIO controller: mmc1\n'
        printf 'Wi-Fi pins: PG0-PG5\n'
        printf 'Wi-Fi main regulator: reg_3v3_wifi\n'
        printf 'Wi-Fi main regulator GPIO: PL7 active-high\n'
        printf 'Wi-Fi main voltage: 3300000 uV\n'
        printf 'Wi-Fi PG I/O regulator: reg_bldo1 at 1800000 uV\n'
        printf 'Wi-Fi PG I/O regulator always on: yes\n'
        printf 'Wi-Fi SDIO I/O supply: reg_bldo1\n'
        printf 'Wi-Fi reset GPIO: PM1 active-low\n'
        printf 'Wi-Fi post-power-on delay: 200 ms\n'
        printf 'Wi-Fi host-wake GPIO: PM0 active-low\n'
        printf 'Wi-Fi SDIO maximum clock: 40000000 Hz\n'
        printf 'Wi-Fi SDIO pin drive strength: 30 mA\n'
        printf 'Wi-Fi SDIO function: wifi@1\n'
        printf 'A523 GPIO IRQ remux workaround removed: yes\n'
        printf 'Wi-Fi driver platform path: generic Linux SDIO\n'
        printf 'Vendor RFKill/rescan node present: no\n'
    } >"$DTS_REPORT"
}

commit_hardware_dts() {
    git -C "$KERNEL_DIR" add -- \
        arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts \
        arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi \
        drivers/pinctrl/sunxi/pinctrl-sun55i-a523.c \
        drivers/pinctrl/sunxi/pinctrl-sun55i-a523-r.c

    if ! git -C "$KERNEL_DIR" diff --cached --quiet; then
        run git -C "$KERNEL_DIR" commit \
            -m "arm64: allwinner: apply Cubie A5E hardware configuration"
    fi
}

main() {
    require_command awk
    require_command python3
    require_command make
    require_command dtc
    require_command fdtget
    require_command git
    require_command grep

    need_dir "$KERNEL_DIR"
    require_nonempty_file "$DTS"
    require_nonempty_file "$SOC_DTSI"
    require_nonempty_file "$PINCTRL_DRIVER"
    require_nonempty_file "$R_PINCTRL_DRIVER"

    if [[ ! -f "$BACKUP" ]]; then
        cp -a -- "$DTS" "$BACKUP"
        log "Created original DTS backup: $BACKUP"
    fi

    remove_existing_managed_block
    apply_wifi_support_backports
    append_hardware_configuration
    validate_source_dts
    build_board_dtb
    decompile_and_validate_dtb
    commit_hardware_dts
    write_report

    log "Hardware DTS applied and compiled successfully."
    log "DTS report: $DTS_REPORT"
}

main "$@"
