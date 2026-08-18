#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="KERNEL"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${JOBS:?JOBS is not set}"
: "${KERNEL_INPUT_FINGERPRINT:?KERNEL_INPUT_FINGERPRINT is not set}"
: "${KERNEL_REBUILD:=0}"

readonly KERNEL_CONFIG="$KERNEL_DIR/.config"
readonly SCRIPTS_CONFIG="$KERNEL_DIR/scripts/config"
readonly KERNEL_RELEASE_FILE="$BUILD_ROOT/.one-shot-kernel-release"
readonly KERNEL_IMAGE="$KERNEL_DIR/arch/arm64/boot/Image"
readonly BOARD_DTB="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"
readonly SYSTEM_MAP="$KERNEL_DIR/System.map"
readonly KERNEL_SYMVERS="$KERNEL_DIR/Module.symvers"
readonly VMLINUX="$KERNEL_DIR/vmlinux"
readonly PINCTRL_DRIVER="$KERNEL_DIR/drivers/pinctrl/sunxi/pinctrl-sun55i-a523.c"
readonly R_PINCTRL_DRIVER="$KERNEL_DIR/drivers/pinctrl/sunxi/pinctrl-sun55i-a523-r.c"
readonly MMC_PWRSEQ_SIMPLE_DRIVER="$KERNEL_DIR/drivers/mmc/core/pwrseq_simple.c"
readonly WENS_REGDB_CERT="$KERNEL_DIR/net/wireless/certs/wens.hex"
readonly CACHE_DIR="$BUILD_ROOT/cache"
readonly KERNEL_CACHE_STATE="$CACHE_DIR/kernel-build.env"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly KERNEL_BUILD_REPORT="$LOG_DIR/kernel-build-report.txt"
    readonly KERNEL_SYMBOL_REPORT="$LOG_DIR/kernel-symbols.txt"
    readonly KERNEL_CONFIG_REPORT="$LOG_DIR/kernel-required-config.txt"
    readonly VMLINUX_NM_REPORT="$LOG_DIR/vmlinux-nm.txt"
else
    readonly KERNEL_BUILD_REPORT="$BUILD_ROOT/.one-shot-kernel-build-report.txt"
    readonly KERNEL_SYMBOL_REPORT="$BUILD_ROOT/.one-shot-kernel-symbols.txt"
    readonly KERNEL_CONFIG_REPORT="$BUILD_ROOT/.one-shot-kernel-required-config.txt"
    readonly VMLINUX_NM_REPORT="$BUILD_ROOT/.one-shot-vmlinux-nm.txt"
fi

KERNEL_RELEASE=""
KERNEL_CACHE_REUSED=0

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

cache_value() {
    local key="$1"

    awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$KERNEL_CACHE_STATE" 2>/dev/null
}

file_matches_cache_hash() {
    local key="$1"
    local path="$2"
    local expected_hash
    local actual_hash

    [[ -s "$path" ]] || return 1
    expected_hash="$(cache_value "$key")"
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash="$(sha256sum -- "$path" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]]
}

validated_kernel_cache_available() {
    [[ "$KERNEL_REBUILD" == "0" ]] || return 1
    [[ -s "$KERNEL_CACHE_STATE" ]] || return 1
    [[ "$(cache_value cache_format)" == "1" ]] || return 1
    [[ "$(cache_value fingerprint)" == "$KERNEL_INPUT_FINGERPRINT" ]] || return 1
    [[ "$(cache_value kernel_release)" == "$KERNEL_RELEASE" ]] || return 1
    [[ "$(cache_value linux_commit)" == \
       "$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || true)" ]] || return 1

    file_matches_cache_hash image_sha256 "$KERNEL_IMAGE" || return 1
    file_matches_cache_hash board_dtb_sha256 "$BOARD_DTB" || return 1
    file_matches_cache_hash config_sha256 "$KERNEL_CONFIG" || return 1
    file_matches_cache_hash module_symvers_sha256 "$KERNEL_SYMVERS" || return 1
    file_matches_cache_hash vmlinux_sha256 "$VMLINUX" || return 1

    return 0
}

write_kernel_cache_state() {
    local temporary_state

    mkdir -p -- "$CACHE_DIR"
    temporary_state="$(mktemp "$CACHE_DIR/.kernel-build.XXXXXX")"

    {
        printf 'cache_format=1\n'
        printf 'fingerprint=%s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
        printf 'linux_commit=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        printf 'image_sha256=%s\n' "$(sha256sum -- "$KERNEL_IMAGE" | awk '{print $1}')"
        printf 'board_dtb_sha256=%s\n' "$(sha256sum -- "$BOARD_DTB" | awk '{print $1}')"
        printf 'config_sha256=%s\n' "$(sha256sum -- "$KERNEL_CONFIG" | awk '{print $1}')"
        printf 'module_symvers_sha256=%s\n' "$(sha256sum -- "$KERNEL_SYMVERS" | awk '{print $1}')"
        printf 'vmlinux_sha256=%s\n' "$(sha256sum -- "$VMLINUX" | awk '{print $1}')"
    } >"$temporary_state"

    chmod 0644 "$temporary_state"
    mv -f -- "$temporary_state" "$KERNEL_CACHE_STATE"
}

apply_mmc_pwrseq_simple_fix() {
    require_nonempty_file "$MMC_PWRSEQ_SIMPLE_DRIVER"

    log "Applying the MMC simple power-sequence reset-gpios probe fix."

    run python3 - "$MMC_PWRSEQ_SIMPLE_DRIVER" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

correct_condition = 'if (device_property_present(dev, "resets")) {'
old_condition_re = re.compile(
    r'(?m)^(?P<indent>[ \t]*)'
    r'ngpio = of_count_phandle_with_args'
    r'\(dev->of_node, "reset-gpios", "#gpio-cells"\);\n'
    r'(?P=indent)if \(ngpio == 1\) \{\n'
)
old_declaration_re = re.compile(r'(?m)^[ \t]*int ngpio;\n')

correct_count = text.count(correct_condition)
old_conditions = list(old_condition_re.finditer(text))
old_declarations = list(old_declaration_re.finditer(text))

if correct_count == 1 and not old_conditions and not old_declarations:
    raise SystemExit(0)

if correct_count != 0:
    raise SystemExit(
        f"{path}: unexpected number of corrected reset checks: {correct_count}"
    )

if len(old_conditions) != 1 or len(old_declarations) != 1:
    raise SystemExit(
        f"{path}: source does not match the known Linux 6.16 "
        "pwrseq_simple probe implementation"
    )

updated = old_declaration_re.sub("", text, count=1)
updated, replacements = old_condition_re.subn(
    r'\g<indent>if (device_property_present(dev, "resets")) {\n',
    updated,
    count=1,
)

if replacements != 1:
    raise SystemExit(f"{path}: failed to replace the reset-gpios heuristic")

path.write_text(updated, encoding="utf-8")
PY
}

validate_mmc_pwrseq_simple_fix() {
    require_nonempty_file "$MMC_PWRSEQ_SIMPLE_DRIVER"

    grep -qF 'if (device_property_present(dev, "resets")) {' \
        "$MMC_PWRSEQ_SIMPLE_DRIVER" ||
        die "MMC pwrseq_simple does not use the explicit resets property."

    if grep -qF \
        'of_count_phandle_with_args(dev->of_node, "reset-gpios", "#gpio-cells")' \
        "$MMC_PWRSEQ_SIMPLE_DRIVER"; then
        die "MMC pwrseq_simple still misclassifies a single reset-gpios entry."
    fi

    if grep -Eq '^[[:space:]]*int ngpio;' "$MMC_PWRSEQ_SIMPLE_DRIVER"; then
        die "MMC pwrseq_simple still contains the obsolete ngpio heuristic."
    fi

    grep -qF \
        'devm_gpiod_get_array(dev, "reset", GPIOD_OUT_HIGH)' \
        "$MMC_PWRSEQ_SIMPLE_DRIVER" ||
        die "MMC pwrseq_simple lacks its GPIO reset fallback."
}

enable_kernel_option() {
    local option="$1"
    run "$SCRIPTS_CONFIG" --file "$KERNEL_CONFIG" --enable "$option"
}

enable_kernel_module() {
    local option="$1"
    run "$SCRIPTS_CONFIG" --file "$KERNEL_CONFIG" --module "$option"
}

configure_kernel() {
    local required_options=(
        CFG80211 CFG80211_REQUIRE_SIGNED_REGDB
        CFG80211_USE_KERNEL_REGDB_KEYS
        MAC80211 RFKILL MMC MMC_SUNXI PWRSEQ_SIMPLE
        FW_LOADER PHYLIB
        REALTEK_PHY STMMAC_ETH STMMAC_PLATFORM DWMAC_SUN8I
        DWMAC_SUN55I SUN55I_PCK600 PM_GENERIC_DOMAINS
        PCI PCI_MSI
        NVME_CORE BLK_DEV_NVME
        IKCONFIG IKCONFIG_PROC
    )
    local required_modules=(
        AW_PCIE_RC PHY_SUNXI_INNO_COMBOPHY
    )
    local option

    log "Enabling required kernel configuration options."

    for option in "${required_options[@]}"; do
        enable_kernel_option "$option"
    done

    for option in "${required_modules[@]}"; do
        enable_kernel_module "$option"
    done

    run make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
}

validate_kernel_config() {
    local required_options=(
        CONFIG_CFG80211 CONFIG_CFG80211_REQUIRE_SIGNED_REGDB
        CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS
        CONFIG_MAC80211 CONFIG_RFKILL CONFIG_MMC
        CONFIG_MMC_SUNXI CONFIG_PWRSEQ_SIMPLE CONFIG_FW_LOADER
        CONFIG_PHYLIB
        CONFIG_REALTEK_PHY CONFIG_STMMAC_ETH CONFIG_STMMAC_PLATFORM
        CONFIG_DWMAC_SUN8I CONFIG_DWMAC_SUN55I CONFIG_SUN55I_PCK600
        CONFIG_PCI CONFIG_PCI_MSI CONFIG_AW_PCIE_RC
        CONFIG_PHY_SUNXI_INNO_COMBOPHY CONFIG_NVME_CORE
        CONFIG_BLK_DEV_NVME
        CONFIG_PM_GENERIC_DOMAINS CONFIG_IKCONFIG CONFIG_IKCONFIG_PROC
    )
    local option

    : >"$KERNEL_CONFIG_REPORT"

    for option in "${required_options[@]}"; do
        grep -Eq "^${option}=(y|m)$" "$KERNEL_CONFIG" ||
            die "Required kernel option is not enabled: $option"
        grep -E "^${option}=(y|m)$" "$KERNEL_CONFIG" >>"$KERNEL_CONFIG_REPORT"
    done


    grep -Fxq 'CONFIG_AW_PCIE_RC=m' "$KERNEL_CONFIG" ||
        die "CONFIG_AW_PCIE_RC must be a module."
    grep -Fxq 'CONFIG_PHY_SUNXI_INNO_COMBOPHY=m' "$KERNEL_CONFIG" ||
        die "CONFIG_PHY_SUNXI_INNO_COMBOPHY must be a module."
}

build_kernel() {
    log "Building Linux kernel Image, modules and Device Trees."
    run make -C "$KERNEL_DIR"         ARCH=arm64         CROSS_COMPILE="$CROSS_COMPILE"         -j"$JOBS"         Image modules dtbs
}

determine_kernel_release() {
    KERNEL_RELEASE="$(
        make -s -C "$KERNEL_DIR"             ARCH=arm64             CROSS_COMPILE="$CROSS_COMPILE"             kernelrelease
    )"

    [[ -n "$KERNEL_RELEASE" ]] ||
        die "Could not determine kernel release."

    case "$KERNEL_RELEASE" in
        6.16.0*) ;;
        *) die "Unexpected kernel release: $KERNEL_RELEASE" ;;
    esac

    printf '%s\n' "$KERNEL_RELEASE" >"$KERNEL_RELEASE_FILE"
    require_nonempty_file "$KERNEL_RELEASE_FILE"
}

validate_kernel_outputs() {
    require_nonempty_file "$KERNEL_IMAGE"
    require_nonempty_file "$BOARD_DTB"
    require_nonempty_file "$SYSTEM_MAP"
    require_nonempty_file "$KERNEL_SYMVERS"
    require_nonempty_file "$VMLINUX"

    if command -v nm >/dev/null 2>&1; then
        nm "$VMLINUX" >"$VMLINUX_NM_REPORT"
    fi
}

validate_board_dtb() {
    local bldo1_phandle
    local decompiled_dts
    local mmc_pwrseq
    local mmc_vmmc
    local mmc_vqmmc
    local pwrseq_gpio_bank
    local pwrseq_gpio_flags
    local pwrseq_gpio_phandle
    local pwrseq_gpio_pin
    local pwrseq_phandle
    local combophy_phandle
    local pcie_phy
    local pcie_power
    local pck600_phandle
    local r_pio_phandle
    local wifi_3v3_phandle
    local wifi_interrupt_parent

    require_command dtc
    require_command fdtget
    require_nonempty_file "$PINCTRL_DRIVER"
    require_nonempty_file "$R_PINCTRL_DRIVER"

    if grep -qF '.irq_read_needs_mux = true,' \
        "$PINCTRL_DRIVER" "$R_PINCTRL_DRIVER"; then
        die "A523 pinctrl drivers still enable invalid IRQ remuxing."
    fi

    decompiled_dts="$(mktemp "$BUILD_ROOT/.one-shot-dtb-check.XXXXXX")"
    trap 'rm -f -- "$decompiled_dts"' RETURN

    dtc \
        -I dtb \
        -O dts \
        -E ranges_format \
        -E reg_format \
        -E simple_bus_reg \
        -Wno-unit_address_vs_reg \
        -o "$decompiled_dts" \
        "$BOARD_DTB"

    if grep -Eq 'allwinner,sunxi-rfkill|allwinner,sunxi-wlan|wlan_busnum|wlan_power' \
        "$decompiled_dts"; then
        die "Compiled board DTB contains the obsolete vendor RFKill/rescan contract."
    fi

    [[ "$(fdtget -t s "$BOARD_DTB" /soc/pcie@4800000 status)" == "okay" ]] ||
        die "Compiled board DTB does not enable PCIe."
    [[ "$(fdtget -t s "$BOARD_DTB" /soc/phy@4f00000 status)" == "okay" ]] ||
        die "Compiled board DTB does not enable the PCIe combo PHY."
    [[ "$(fdtget -t u "$BOARD_DTB" /soc/pcie@4800000 max-link-speed)" == "2" ]] ||
        die "Compiled board DTB does not request PCIe Gen2."
    [[ "$(fdtget -t u "$BOARD_DTB" /soc '#address-cells')" == "1" ]] ||
        die "Compiled board DTB /soc bus does not use one address cell."
    [[ "$(fdtget -t u "$BOARD_DTB" /soc '#size-cells')" == "1" ]] ||
        die "Compiled board DTB /soc bus does not use one size cell."
    [[ "$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 reg)" == \
       "4800000 480000" ]] ||
        die "Compiled board DTB has the wrong PCIe register range."
    [[ "$(fdtget -t x "$BOARD_DTB" /soc/phy@4f00000 reg)" == \
       "4f00000 80000 4f80000 80000" ]] ||
        die "Compiled board DTB has the wrong combo-PHY register ranges."
    [[ "$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 ranges)" == \
       "800 0 20000000 20000000 0 1000000 81000000 0 21000000 21000000 0 1000000 82000000 0 22000000 22000000 0 e000000" ]] ||
        die "Compiled board DTB has the wrong PCIe outbound address windows."

    combophy_phandle="$(fdtget -t x "$BOARD_DTB" /soc/phy@4f00000 phandle)"
    pcie_phy="$(fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 phys)"
    [[ "$pcie_phy" == "$combophy_phandle 2" ]] ||
        die "Compiled board DTB has the wrong PCIe combo-PHY reference."

    pck600_phandle="$(
        fdtget -t x "$BOARD_DTB" /soc/power-controller@7060000 phandle
    )"
    pcie_power="$(
        fdtget -t x "$BOARD_DTB" /soc/pcie@4800000 power-domains
    )"
    [[ "$pcie_power" == "$pck600_phandle 7" ]] ||
        die "Compiled board DTB has the wrong PCIe power-domain reference."

    grep -qF 'regulator-name = "3v3-wifi";' "$decompiled_dts" ||
        die "Compiled board DTB lacks the PL7-controlled Wi-Fi supply."

    grep -qF 'non-removable;' "$decompiled_dts" ||
        die "Compiled board DTB does not mark mmc1 as non-removable."

    [[ "$(fdtget -t s "$BOARD_DTB" /soc/mmc@4021000 status)" == "okay" ]] ||
        die "Compiled board DTB does not enable mmc1."

    [[ "$(fdtget -t u "$BOARD_DTB" /soc/mmc@4021000 max-frequency)" == "40000000" ]] ||
        die "Compiled board DTB does not cap mmc1 at the tested 40 MHz."

    [[ "$(fdtget -t u "$BOARD_DTB" /soc/mmc@4021000/wifi@1 reg)" == "1" ]] ||
        die "Compiled board DTB lacks the AIC8800 SDIO function at address 1."

    wifi_3v3_phandle="$(fdtget -t x "$BOARD_DTB" /3v3-wifi phandle)"
    mmc_vmmc="$(fdtget -t x "$BOARD_DTB" /soc/mmc@4021000 vmmc-supply)"
    bldo1_phandle="$(
        fdtget -t x \
            "$BOARD_DTB" \
            /soc/i2c@7081400/pmic@34/regulators/bldo1 \
            phandle
    )"
    mmc_vqmmc="$(
        fdtget -t x "$BOARD_DTB" /soc/mmc@4021000 vqmmc-supply
    )"
    pwrseq_phandle="$(fdtget -t x "$BOARD_DTB" /wifi-pwrseq phandle)"
    mmc_pwrseq="$(
        fdtget -t x "$BOARD_DTB" /soc/mmc@4021000 mmc-pwrseq
    )"

    [[ "$mmc_vmmc" == "$wifi_3v3_phandle" ]] ||
        die "Compiled board DTB does not connect mmc1 to the PL7-controlled 3.3 V supply."

    [[ "$mmc_vqmmc" == "$bldo1_phandle" ]] ||
        die "Compiled board DTB does not connect mmc1 vqmmc to BLDO1."

    [[ "$mmc_pwrseq" == "$pwrseq_phandle" ]] ||
        die "Compiled board DTB does not connect mmc1 to the Wi-Fi power sequence."

    [[ "$(
        fdtget -t u \
            "$BOARD_DTB" \
            /wifi-pwrseq \
            post-power-on-delay-ms
    )" == "200" ]] ||
        die "Compiled board DTB does not wait 200 ms after Wi-Fi power-on."

    IFS=' ' read -r \
        pwrseq_gpio_phandle \
        pwrseq_gpio_bank \
        pwrseq_gpio_pin \
        pwrseq_gpio_flags < <(
        fdtget -t x "$BOARD_DTB" /wifi-pwrseq reset-gpios
    )

    r_pio_phandle="$(
        fdtget -t x "$BOARD_DTB" /soc/pinctrl@7022000 phandle
    )"

    [[ "$pwrseq_gpio_phandle" == "$r_pio_phandle" &&
       "$pwrseq_gpio_bank" == "1" &&
       "$pwrseq_gpio_pin" == "1" &&
       "$pwrseq_gpio_flags" == "1" ]] ||
        die "Compiled board DTB does not reset Wi-Fi through PM1 active-low."

    fdtget -p \
        "$BOARD_DTB" \
        /soc/i2c@7081400/pmic@34/regulators/bldo1 |
        grep -Fxq 'regulator-always-on' ||
        die "Compiled board DTB does not keep BLDO1 enabled."

    wifi_interrupt_parent="$(
        fdtget -t x \
            "$BOARD_DTB" \
            /soc/mmc@4021000/wifi@1 \
            interrupt-parent
    )"

    [[ "$wifi_interrupt_parent" == "$r_pio_phandle" ]] ||
        die "Compiled board DTB does not route AIC8800 host-wake through R_PIO."

    [[ "$(
        fdtget -t u \
            "$BOARD_DTB" \
            /soc/mmc@4021000/wifi@1 \
            interrupts
    )" == "1 0 8" ]] ||
        die "Compiled board DTB does not route AIC8800 host-wake from PM0 active-low."

    [[ "$(
        fdtget -t s \
            "$BOARD_DTB" \
            /soc/mmc@4021000/wifi@1 \
            interrupt-names
    )" == "host-wake" ]] ||
        die "Compiled board DTB does not name the AIC8800 host-wake interrupt."

    rm -f -- "$decompiled_dts"
    trap - RETURN
}

write_reports() {
    {
        printf 'Kernel build report\n'
        printf '===================\n'
        printf 'Kernel release: %s\n' "$KERNEL_RELEASE"
        printf 'Kernel input fingerprint: %s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'Validated kernel cache reused: %s\n' "$KERNEL_CACHE_REUSED"
        printf 'Kernel directory: %s\n' "$KERNEL_DIR"
        printf 'Kernel Image: %s\n' "$KERNEL_IMAGE"
        printf 'Board DTB: %s\n' "$BOARD_DTB"
        printf 'PCIe root complex: Allwinner v210, Gen2 x1, built in\n'
        printf 'PCIe combo PHY: Innosilicon, built in\n'
        printf 'NVMe host driver: built in\n'
        printf 'Wi-Fi power sequence: PM1 reset with 200 ms delay\n'
        printf 'MMC power-sequence reset routing: explicit resets property; reset-gpios use GPIO consumer path\n'
        printf 'Wi-Fi I/O supply: BLDO1 at 1.8 V, always on\n'
        printf 'Wi-Fi host wake: PM0 active-low\n'
        printf 'Wi-Fi SDIO maximum clock: 40000000 Hz\n'
        printf 'Wireless regulatory database signing key: in-kernel wens certificate\n'
        printf 'AIC driver platform path: generic Linux SDIO\n'
        printf 'External MMC rescan compatibility: not used\n'
        printf 'Kernel release file: %s\n' "$KERNEL_RELEASE_FILE"
    } >"$KERNEL_BUILD_REPORT"

    {
        printf 'AIC8800 kernel symbol policy\n'
        printf '============================\n'
        printf 'External sunxi_mmc_rescan_card export required: no\n'
        printf 'External sunxi_wlan_* exports required: no\n'
    } >"$KERNEL_SYMBOL_REPORT"
}

main() {
    require_command awk
    require_command chmod
    require_command git
    require_command make
    require_command grep
    require_command mktemp
    require_command mv
    require_command python3
    require_command dtc
    require_command fdtget
    require_command sha256sum

    case "$KERNEL_REBUILD" in
        0 | 1) ;;
        *) die "KERNEL_REBUILD must be 0 or 1, got: $KERNEL_REBUILD" ;;
    esac

    need_dir "$KERNEL_DIR"
    require_nonempty_file "$KERNEL_CONFIG"
    require_nonempty_file "$SCRIPTS_CONFIG"
    require_nonempty_file "$WENS_REGDB_CERT"

    log "Kernel build stage starting."

    determine_kernel_release

    if validated_kernel_cache_available; then
        KERNEL_CACHE_REUSED=1
        log "Reusing validated kernel Image, modules, DTBs, and build objects."
        log "Kernel cache fingerprint: $KERNEL_INPUT_FINGERPRINT"

        validate_mmc_pwrseq_simple_fix
        validate_kernel_config
        validate_kernel_outputs
        validate_board_dtb
        write_reports

        log "Kernel cache validation passed: $KERNEL_RELEASE"
        log "Kernel Image: $KERNEL_IMAGE"
        log "Board DTB: $BOARD_DTB"
        return 0
    fi

    KERNEL_CACHE_REUSED=0
    rm -f -- "$KERNEL_CACHE_STATE"
    log "Kernel cache miss; running the required clean or incremental build."

    apply_mmc_pwrseq_simple_fix
    validate_mmc_pwrseq_simple_fix
    configure_kernel
    validate_kernel_config
    build_kernel
    determine_kernel_release
    validate_kernel_outputs
    validate_board_dtb
    write_reports
    write_kernel_cache_state

    log "Kernel build passed: $KERNEL_RELEASE"
    log "Kernel cache state: $KERNEL_CACHE_STATE"
    log "Kernel Image: $KERNEL_IMAGE"
    log "Board DTB: $BOARD_DTB"
    log "Symbol report: $KERNEL_SYMBOL_REPORT"
}

main "$@"
