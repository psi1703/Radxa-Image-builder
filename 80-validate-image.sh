#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh

source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="VALIDATE"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${AIC_REPO:?AIC_REPO is not set}"
: "${TARGET_DEVICE:?TARGET_DEVICE is not set}"

readonly TARGET_LAYOUT_FILE="$BUILD_ROOT/.one-shot-target-layout"
readonly LAYOUT_CANDIDATES_FILE="$BUILD_ROOT/.one-shot-layout-candidates"
readonly KERNEL_RELEASE_FILE="$BUILD_ROOT/.one-shot-kernel-release"
readonly UPDATE_VERSION_FILE="$BUILD_ROOT/.one-shot-update-version"
readonly UPDATE_BUNDLE_FILE="$BUILD_ROOT/.one-shot-update-bundle"

readonly ROOT_MNT="${ROOT_MNT:-$BUILD_ROOT/mnt/one-shot-root}"
readonly DEFAULT_BOOT_MNT="${BOOT_MNT:-$BUILD_ROOT/mnt/one-shot-boot}"

readonly BOARD_DTS="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dts"
readonly KERNEL_CONFIG="$KERNEL_DIR/.config"
readonly SPI_DRIVER="$KERNEL_DIR/drivers/spi/spi-sun6i.c"
readonly GMAC1_DRIVER="$KERNEL_DIR/drivers/net/ethernet/stmicro/stmmac/dwmac-sun55i.c"
readonly SOC_DTSI="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi"
readonly PCK600_DRIVER="$KERNEL_DIR/drivers/pmdomain/sunxi/sun55i-pck600.c"
readonly PCK600_BINDING="$KERNEL_DIR/include/dt-bindings/power/allwinner,sun55i-a523-pck-600.h"
readonly R_CCU_RESET_BINDING="$KERNEL_DIR/include/dt-bindings/reset/sun55i-a523-r-ccu.h"
readonly R_CCU_DRIVER="$KERNEL_DIR/drivers/clk/sunxi-ng/ccu-sun55i-a523-r.c"
readonly AXP20X_MFD_DRIVER="$KERNEL_DIR/drivers/mfd/axp20x.c"
readonly PINCTRL_DRIVER="$KERNEL_DIR/drivers/pinctrl/sunxi/pinctrl-sun55i-a523.c"
readonly R_PINCTRL_DRIVER="$KERNEL_DIR/drivers/pinctrl/sunxi/pinctrl-sun55i-a523-r.c"
readonly MMC_PWRSEQ_SIMPLE_DRIVER="$KERNEL_DIR/drivers/mmc/core/pwrseq_simple.c"
readonly AIC_D80_FIRMWARE="$AIC_REPO/src/SDIO/driver_fw/fw/aic8800D80"
readonly WENS_REGDB_CERT="$KERNEL_DIR/net/wireless/certs/wens.hex"
readonly BASIC_PACKAGES_SRC="$SCRIPT_DIR/assets/raspios-lite-compatible-packages.txt"
readonly BASIC_PACKAGES_TARGET="/usr/share/cubie-a5e/raspios-lite-compatible-packages.txt"
readonly INITBOX_USER="initbox"
readonly INITBOX_SUDOERS="/etc/sudoers.d/90-initbox"
readonly INITBOX_ACCOUNT_STATUS="/var/lib/cubie-a5e/initbox-account.status"
readonly GETTY_TTY1_DROPIN="/etc/systemd/system/getty@tty1.service.d/99-initbox-login.conf"
readonly SERIAL_GETTY_DROPIN="/etc/systemd/system/serial-getty@ttyS0.service.d/99-initbox-login.conf"
readonly NM_WLAN_READY_FILE="/etc/NetworkManager/conf.d/20-initbox-wlan0-ready.conf"
readonly WLAN_READY_STATUS="/usr/share/cubie-a5e/wlan0-hotspot-ready.status"
readonly RADXA_REPO_HELPER_TARGET="/usr/local/sbin/cubie-a5e-ensure-radxa-repo"
readonly RADXA_REPO_FILE="/etc/apt/sources.list.d/70-trixie.list"
readonly RADXA_KEYRING="/usr/share/keyrings/radxa-archive-keyring.gpg"
readonly REGULATORY_INITRAMFS_STATUS="/var/lib/cubie-a5e/regulatory-initramfs.status"
readonly PCIE_INITRAMFS_STATUS="/var/lib/cubie-a5e/pcie-initramfs.status"
readonly PCIE_MODULE_REL="kernel/drivers/pci/controller/sunxi/pcie_sunxi_host.ko"
readonly PCIE_PHY_MODULE_REL="kernel/drivers/phy/allwinner/phy-sunxi-inno-combophy.ko"
readonly ROOT_GROW_PROGRAM="/usr/local/sbin/cubie-a5e-grow-rootfs"
readonly ROOT_GROW_UNIT="/usr/lib/systemd/system/cubie-a5e-grow-rootfs.service"
readonly ROOT_GROW_WANTS="/etc/systemd/system/multi-user.target.wants/cubie-a5e-grow-rootfs.service"
readonly ROOT_GROW_MARKER="/var/lib/cubie-a5e/rootfs-expanded"
readonly RADXA_UBOOT_VERSION="${RADXA_UBOOT_VERSION:-2018.07-17}"
readonly RADXA_UBOOT_PAYLOAD_DIR="/usr/lib/u-boot/radxa-cubie-a5e"
readonly EXPECTED_SPI_FREQUENCY="20000000"
readonly MINIMUM_ROOT_AVAILABLE_BYTES=$((512 * 1024 * 1024))

if [[ -n "${LOG_DIR:-}" ]]; then
mkdir -p -- "$LOG_DIR"

readonly VALIDATION_REPORT="$LOG_DIR/image-validation-report.txt"
readonly VALIDATION_EXTLINUX="$LOG_DIR/validated-extlinux.conf"
readonly VALIDATION_MODULES="$LOG_DIR/validated-modules.txt"
readonly VALIDATION_DTB="$LOG_DIR/validated-board.dts"

else
readonly VALIDATION_REPORT="$BUILD_ROOT/.one-shot-image-validation-report.txt"
readonly VALIDATION_EXTLINUX="$BUILD_ROOT/.one-shot-validated-extlinux.conf"
readonly VALIDATION_MODULES="$BUILD_ROOT/.one-shot-validated-modules.txt"
readonly VALIDATION_DTB="$BUILD_ROOT/.one-shot-validated-board.dts"
fi

ROOT_PART=""
BOOT_PART=""
EXTLINUX_REL=""
BOOT_MNT="$DEFAULT_BOOT_MNT"
KERNEL_RELEASE=""
UPDATE_VERSION=""
SAME_FS=0
ROOT_SIZE_BYTES=0
ROOT_USED_BYTES=0
ROOT_AVAILABLE_BYTES=0
ROOT_USE_PERCENT="0%"

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

module_vermagic() {
local module_path="$1"

strings "$module_path" |
    sed -n 's/^vermagic=//p' |
    head -n 1

}

cleanup() {
set +e

if ((SAME_FS == 0)) && mountpoint -q "$BOOT_MNT"; then
    umount "$BOOT_MNT"
fi

if mountpoint -q "$ROOT_MNT"; then
    umount "$ROOT_MNT"
fi

}

trap cleanup EXIT

discover_target_layout() {
local probe_root="$BUILD_ROOT/mnt/layout-probe"
local part
local mount_dir
local root_count=0
local boot_count=0
local found_root=""
local found_boot=""
local found_extlinux=""

mkdir -p -- "$probe_root"
: >"$LAYOUT_CANDIDATES_FILE"

while IFS= read -r part; do
    [[ -b "$part" ]] || continue

    mount_dir="$probe_root/$(basename -- "$part")"
    mkdir -p -- "$mount_dir"

    if mountpoint -q "$mount_dir"; then
        umount "$mount_dir"
    fi

    if ! mount -o ro "$part" "$mount_dir" 2>/dev/null; then
        continue
    fi

    if [[ -f "$mount_dir/etc/os-release" &&
          -d "$mount_dir/usr" &&
          -d "$mount_dir/boot" ]]; then
        printf 'ROOT %s\n' "$part" >>"$LAYOUT_CANDIDATES_FILE"
        found_root="$part"
        root_count=$((root_count + 1))
    fi

    if [[ -f "$mount_dir/boot/extlinux/extlinux.conf" ]]; then
        printf 'BOOT %s boot/extlinux/extlinux.conf\n' \
            "$part" >>"$LAYOUT_CANDIDATES_FILE"

        found_boot="$part"
        found_extlinux="boot/extlinux/extlinux.conf"
        boot_count=$((boot_count + 1))
    elif [[ -f "$mount_dir/extlinux/extlinux.conf" ]]; then
        printf 'BOOT %s extlinux/extlinux.conf\n' \
            "$part" >>"$LAYOUT_CANDIDATES_FILE"

        found_boot="$part"
        found_extlinux="extlinux/extlinux.conf"
        boot_count=$((boot_count + 1))
    fi

    umount "$mount_dir"
done < <(
    lsblk -lnpo NAME,TYPE "$TARGET_DEVICE" |
        awk '$2 == "part" {print $1}'
)

((root_count == 1)) ||
    die "Expected exactly one Debian root filesystem; found $root_count. See $LAYOUT_CANDIDATES_FILE"

((boot_count == 1)) ||
    die "Expected exactly one extlinux filesystem; found $boot_count. See $LAYOUT_CANDIDATES_FILE"

{
    printf 'ROOT_PART=%q\n' "$found_root"
    printf 'BOOT_PART=%q\n' "$found_boot"
    printf 'EXTLINUX_REL=%q\n' "$found_extlinux"
} >"$TARGET_LAYOUT_FILE"

}

load_target_layout() {
discover_target_layout

# shellcheck disable=SC1090
source "$TARGET_LAYOUT_FILE"

[[ -b "$ROOT_PART" ]] ||
    die "Recorded root partition is unavailable: $ROOT_PART"

[[ -b "$BOOT_PART" ]] ||
    die "Recorded boot partition is unavailable: $BOOT_PART"

[[ -n "$EXTLINUX_REL" ]] ||
    die "Recorded extlinux path is empty."

}

mount_read_only_filesystems() {
if mountpoint -q "$ROOT_MNT"; then
umount "$ROOT_MNT"
fi

if mountpoint -q "$DEFAULT_BOOT_MNT"; then
    umount "$DEFAULT_BOOT_MNT"
fi

sync

mkdir -p -- "$ROOT_MNT" "$DEFAULT_BOOT_MNT"

mount -o ro "$ROOT_PART" "$ROOT_MNT"

if [[ "$(readlink -f -- "$ROOT_PART")" == "$(readlink -f -- "$BOOT_PART")" ]]; then
    SAME_FS=1
    BOOT_MNT="$ROOT_MNT"
else
    SAME_FS=0
    BOOT_MNT="$DEFAULT_BOOT_MNT"
    mount -o ro "$BOOT_PART" "$BOOT_MNT"
fi

}

validate_root_identity() {
local os_id
local version_id

require_nonempty_file "$ROOT_MNT/etc/os-release"

os_id="$(
    sed -n 's/^ID=//p' "$ROOT_MNT/etc/os-release" |
        tr -d '"'
)"

version_id="$(
    sed -n 's/^VERSION_ID=//p' "$ROOT_MNT/etc/os-release" |
        tr -d '"'
)"

[[ "$os_id" == "debian" ]] ||
    die "Target root filesystem is not Debian: ID=$os_id"

case "$version_id" in
    13 | 13.*)
        ;;
    *)
        die "Target root filesystem is not Debian 13: VERSION_ID=$version_id"
        ;;
esac

}

validate_root_runtime_layout() {
local path
local tmp_mode

for path in dev proc sys run tmp mnt media; do
    [[ -d "$ROOT_MNT/$path" ]] ||
        die "Required runtime mountpoint directory is missing from the target root: /$path"
    [[ ! -L "$ROOT_MNT/$path" ]] ||
        die "Required runtime mountpoint must not be a symbolic link: /$path"
done

tmp_mode="$(stat -c '%a' "$ROOT_MNT/tmp")"
[[ "$tmp_mode" == "1777" ]] ||
    die "Target /tmp must have mode 1777; found $tmp_mode."

[[ -x "$ROOT_MNT/sbin/init" ]] ||
    die "Target /sbin/init is missing or not executable."
[[ -x "$ROOT_MNT/usr/lib/systemd/systemd" ]] ||
    die "Target systemd PID1 is missing or not executable."
}

validate_kernel_payload() {
local root_kernel="$ROOT_MNT/boot/vmlinuz-$KERNEL_RELEASE"
local root_config="$ROOT_MNT/boot/config-$KERNEL_RELEASE"
local root_initrd="$ROOT_MNT/boot/initrd.img-$KERNEL_RELEASE"
local root_dtb="$ROOT_MNT/usr/lib/linux-image-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"

require_nonempty_file "$root_kernel"
require_nonempty_file "$root_config"
require_nonempty_file "$root_initrd"
require_nonempty_file "$root_dtb"

grep -Fxq 'CONFIG_STMMAC_ETH=y' "$root_config" ||
    die "Installed kernel does not build STMMAC Ethernet support in."

grep -Fxq 'CONFIG_STMMAC_PLATFORM=y' "$root_config" ||
    die "Installed kernel does not build STMMAC platform support in."

grep -Fxq 'CONFIG_DWMAC_SUN55I=y' "$root_config" ||
    die "Installed kernel does not build the GMAC200 driver in."

grep -Fxq 'CONFIG_SUN55I_PCK600=y' "$root_config" ||
    die "Installed kernel does not build the PCK600 power-domain driver in."

grep -Fxq 'CONFIG_PM_GENERIC_DOMAINS=y' "$root_config" ||
    die "Installed kernel lacks generic power-domain support."

grep -Fxq 'CONFIG_AW_PCIE_RC=m' "$root_config" ||
    die "Installed kernel does not build the Allwinner PCIe host driver as a module."

grep -Fxq 'CONFIG_PHY_SUNXI_INNO_COMBOPHY=m' "$root_config" ||
    die "Installed kernel does not build the PCIe combo PHY as a module."

grep -Fxq 'CONFIG_BLK_DEV_NVME=y' "$root_config" ||
    die "Installed kernel does not build the NVMe host driver in."

grep -Fxq 'CONFIG_SPI=y' "$root_config" ||
    die "Installed kernel does not build the SPI core in."

grep -Fxq 'CONFIG_SPI_MEM=y' "$root_config" ||
    die "Installed kernel does not build the SPI memory framework in."

grep -Fxq 'CONFIG_SPI_SUN6I=y' "$root_config" ||
    die "Installed kernel does not build the Allwinner SPI driver in."

grep -Fxq 'CONFIG_MTD=y' "$root_config" ||
    die "Installed kernel does not build the MTD core in."

grep -Fxq 'CONFIG_MTD_BLOCK=y' "$root_config" ||
    die "Installed kernel does not build MTD block support in."

grep -Fxq 'CONFIG_MTD_SPI_NOR=y' "$root_config" ||
    die "Installed kernel does not build SPI-NOR support in."

grep -Fxq 'CONFIG_PWRSEQ_SIMPLE=y' "$root_config" ||
    die "Installed kernel does not build the simple MMC power sequencer in."

grep -Fxq 'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y' "$root_config" ||
    die "Installed kernel does not require a signed wireless regulatory database."

grep -Fxq 'CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y' "$root_config" ||
    die "Installed kernel does not include the upstream regulatory signing keys."

if ((SAME_FS == 1)); then
    require_nonempty_file "$BOOT_MNT/boot/vmlinuz-$KERNEL_RELEASE"
    require_nonempty_file "$BOOT_MNT/boot/initrd.img-$KERNEL_RELEASE"
    require_nonempty_file \
        "$BOOT_MNT/usr/lib/linux-image-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"
else
    require_nonempty_file "$BOOT_MNT/vmlinuz-$KERNEL_RELEASE"
    require_nonempty_file "$BOOT_MNT/initrd.img-$KERNEL_RELEASE"
    require_nonempty_file \
        "$BOOT_MNT/dtb-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"
fi

}

validate_module_tree() {
local module_root="$ROOT_MNT/lib/modules/$KERNEL_RELEASE"
local external_dir="$module_root/updates/aic8800"
local module_path
local module_name
local vermagic
local installed_module_count

require_nonempty_file "$module_root/modules.dep"
require_nonempty_file "$module_root/modules.alias"
require_nonempty_file "$module_root/modules.softdep"

: >"$VALIDATION_MODULES"

for module_path in \
    "$module_root/$PCIE_PHY_MODULE_REL" \
    "$module_root/$PCIE_MODULE_REL"; do
    require_nonempty_file "$module_path"
    module_name="$(basename -- "$module_path")"
    vermagic="$(module_vermagic "$module_path")"

    case "$vermagic" in
        "$KERNEL_RELEASE"*)
            ;;
        *)
            die "Module release mismatch: $module_name=$vermagic expected=$KERNEL_RELEASE"
            ;;
    esac

    printf '%s\t%s\n' "$module_path" "$vermagic" >> \
        "$VALIDATION_MODULES"
done

for module_name in \
    aic8800_bsp.ko \
    aic8800_fdrv.ko; do
    module_path="$external_dir/$module_name"

    require_nonempty_file "$module_path"

    vermagic="$(module_vermagic "$module_path")"

    [[ -n "$vermagic" ]] ||
        die "Could not determine vermagic for $module_name"

    case "$vermagic" in
        "$KERNEL_RELEASE"*)
            ;;
        *)
            die "Module release mismatch: $module_name=$vermagic expected=$KERNEL_RELEASE"
            ;;
    esac

    printf '%s\t%s\n' "$module_path" "$vermagic" >> \
        "$VALIDATION_MODULES"
done

[[ ! -e "$external_dir/aic8800_btlpm.ko" ]] ||
    die "Unsupported aic8800_btlpm.ko is present on the target."

[[ ! -e "$external_dir/sunxi_rfkill_compat.ko" ]] ||
    die "Obsolete sunxi_rfkill_compat.ko is present on the target."

if grep -q '^updates/aic8800/sunxi_rfkill_compat\.ko:' \
    "$module_root/modules.dep"; then
    die "Obsolete sunxi_rfkill_compat.ko remains in modules.dep."
fi

grep -q '^updates/aic8800/aic8800_bsp\.ko:' \
    "$module_root/modules.dep" ||
    die "aic8800_bsp.ko is absent from modules.dep"

grep -q '^updates/aic8800/aic8800_fdrv\.ko:' \
    "$module_root/modules.dep" ||
    die "aic8800_fdrv.ko is absent from modules.dep"

grep -q "^${PCIE_PHY_MODULE_REL}:" "$module_root/modules.dep" ||
    die "The combo-PHY module is absent from modules.dep."

grep -q "^${PCIE_MODULE_REL}:" "$module_root/modules.dep" ||
    die "The PCIe host module is absent from modules.dep."

if nm -u "$external_dir/aic8800_bsp.ko" |
    grep -Eq \
        '[[:space:]]U (sunxi_mmc_rescan_card|sunxi_wlan_get_bus_index|sunxi_wlan_set_power|sunxi_wlan_get_oob_irq)$'; then
    die "Installed AIC8800 BSP still imports obsolete Allwinner RFKill/rescan symbols."
fi

installed_module_count="$(
    find "$ROOT_MNT/lib/modules" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' |
        wc -l
)"

[[ "$installed_module_count" -eq 1 ]] ||
    die "Expected exactly one installed kernel module tree; found $installed_module_count"

[[ -d "$ROOT_MNT/lib/modules/$KERNEL_RELEASE" ]] ||
    die "The only installed module tree is not $KERNEL_RELEASE."

}

validate_module_policy() {
local load_file="$ROOT_MNT/etc/modules-load.d/cubie-a5e-aic8800.conf"
local softdep_file="$ROOT_MNT/etc/modprobe.d/cubie-a5e-aic8800.conf"
local initramfs_modules="$ROOT_MNT/etc/initramfs-tools/modules"
local legacy_pattern

require_nonempty_file "$load_file"
require_nonempty_file "$softdep_file"
require_nonempty_file "$initramfs_modules"

[[ "$(grep -Fxc 'phy-sunxi-inno-combophy' "$initramfs_modules")" == "1" ]] ||
    die "The combo-PHY initramfs module policy is invalid."
[[ "$(grep -Fxc 'pcie_sunxi_host' "$initramfs_modules")" == "1" ]] ||
    die "The PCIe host initramfs module policy is invalid."

diff -u \
    <(
        printf '%s\n' \
            aic8800_bsp \
            aic8800_fdrv
    ) \
    "$load_file" ||
    die "AIC8800 module load order is incorrect."

diff -u \
    <(
        printf '%s\n' \
            'softdep aic8800_fdrv pre: aic8800_bsp' \
            'options aic8800_bsp aic_fw_path=/lib/firmware/aic8800_fw/SDIO/aic8800D80' \
            'options aic8800_fdrv aicwf_dbg_level=0 custregd=0 ps_on=0'
    ) \
    "$softdep_file" ||
    die "AIC8800 module policy is incorrect."

if grep -Eq 'sunxi_rfkill_compat|sunxi_mmc_rescan_card' \
    "$load_file" "$softdep_file"; then
    die "Obsolete Sunxi RFKill/rescan module policy is still installed."
fi

legacy_pattern='^[[:space:]]*(aicwf_sdio|aic8800_sdio|aic8800_bsp_sdio|aic8800_btlpm_sdio|aic8800_fdrv_sdio)([[:space:]]*(#.*)?)?$'

if [[ -f "$ROOT_MNT/etc/modules" ]] &&
   grep -En "$legacy_pattern" "$ROOT_MNT/etc/modules"; then
    die "Obsolete AIC8800 aliases remain in /etc/modules."
fi

if grep -REn \
    --include='*.conf' \
    "$legacy_pattern" \
    "$ROOT_MNT/etc/modules-load.d" \
    "$ROOT_MNT/usr/local/lib/modules-load.d" \
    "$ROOT_MNT/usr/lib/modules-load.d" 2>/dev/null; then
    die "Obsolete AIC8800 aliases remain in modules-load.d."
fi

}

validate_single_wifi_loader() {
local unit

for unit in \
    initbox-radxa-wifi-modprobe.service \
    radxa-wifi-modprobe.service \
    aic8800-modprobe.service; do
    if find \
        "$ROOT_MNT/etc/systemd/system" \
        "$ROOT_MNT/lib/systemd/system" \
        "$ROOT_MNT/usr/lib/systemd/system" \
        -name "$unit" \
        -print -quit 2>/dev/null |
        grep -q .; then
        die "Duplicate Wi-Fi loader remains installed: $unit"
    fi
done

for path in \
    "$ROOT_MNT/usr/local/sbin/initbox-radxa-wifi-modprobe" \
    "$ROOT_MNT/usr/local/bin/initbox-radxa-wifi-modprobe" \
    "$ROOT_MNT/usr/local/sbin/radxa-wifi-modprobe" \
    "$ROOT_MNT/usr/local/bin/radxa-wifi-modprobe"; do
    [[ ! -e "$path" ]] ||
        die "Duplicate Wi-Fi loader helper remains installed: $path"
done
}

validate_firmware() {
local firmware_name
local installed_firmware="$ROOT_MNT/lib/firmware/aic8800_fw/SDIO/aic8800D80"

need_dir "$AIC_D80_FIRMWARE"
need_dir "$installed_firmware"

for firmware_name in \
    fw_patch_table_8800d80_u02.bin \
    fw_adid_8800d80_u02.bin \
    fw_patch_8800d80_u02.bin \
    fmacfw_8800d80_u02.bin; do
    require_nonempty_file "$AIC_D80_FIRMWARE/$firmware_name"
    require_nonempty_file "$installed_firmware/$firmware_name"
    cmp -s \
        "$AIC_D80_FIRMWARE/$firmware_name" \
        "$installed_firmware/$firmware_name" ||
        die "Installed AIC8800D80 firmware does not match the driver source: $firmware_name"
done
}

validate_network_policy() {
local required_files=(
"$ROOT_MNT/etc/systemd/network/10-cubie-gmac0.link"
"$ROOT_MNT/etc/systemd/network/11-cubie-gmac1.link"
"$ROOT_MNT/etc/systemd/network/20-cubie-aic8800.link"
"$ROOT_MNT$NM_WLAN_READY_FILE"
"$ROOT_MNT$WLAN_READY_STATUS"
)
local file
local connection_file

for file in "${required_files[@]}"; do
    require_nonempty_file "$file"
done

grep -Eq '^[[:space:]]*Name=eth0[[:space:]]*$' \
    "$ROOT_MNT/etc/systemd/network/10-cubie-gmac0.link" ||
    die "GMAC0 link policy does not assign eth0."

grep -Eq '^[[:space:]]*Name=eth1[[:space:]]*$' \
    "$ROOT_MNT/etc/systemd/network/11-cubie-gmac1.link" ||
    die "GMAC1 link policy does not assign eth1."

grep -Eq '^[[:space:]]*Name=wlan0[[:space:]]*$' \
    "$ROOT_MNT/etc/systemd/network/20-cubie-aic8800.link" ||
    die "AIC8800 link policy does not assign wlan0."

grep -Fxq 'match-device=interface-name:wlan0' \
    "$ROOT_MNT$NM_WLAN_READY_FILE" ||
    die "NetworkManager wlan0 device match is missing."

grep -Fxq 'managed=true' \
    "$ROOT_MNT$NM_WLAN_READY_FILE" ||
    die "NetworkManager does not explicitly manage wlan0."

grep -Fxq 'INTENDED_ROLE=unconfigured-hotspot-ready' \
    "$ROOT_MNT$WLAN_READY_STATUS" ||
    die "The wlan0 hotspot-ready status marker is invalid."

while IFS= read -r -d '' connection_file; do
    if grep -Eq \
        '^[[:space:]]*type[[:space:]]*=[[:space:]]*(wifi|802-11-wireless)[[:space:]]*$|^[[:space:]]*\[wifi\][[:space:]]*$' \
        "$connection_file"; then
        die "Saved Wi-Fi connection remains in the base image: $connection_file"
    fi
done < <(
    find "$ROOT_MNT/etc/NetworkManager/system-connections" \
        -maxdepth 1 \
        -type f \
        -print0
)

}

validate_userland_runtime() {
local bash_completion="$ROOT_MNT/usr/share/bash-completion/bash_completion"
local bashrc="$ROOT_MNT/etc/bash.bashrc"
local candidate
local efi_unit
local timesync_unit=""
local wants_link=""

require_nonempty_file "$bash_completion"
require_nonempty_file "$bashrc"

grep -Eq '(^|[[:space:]])(source|\.)[[:space:]]+/usr/share/bash-completion/bash_completion([[:space:]]|$)' \
    "$bashrc" ||
    grep -q '/usr/share/bash-completion/bash_completion' "$bashrc" ||
    die "System-wide Bash completion is not enabled."

for candidate in \
    "$ROOT_MNT/usr/lib/systemd/system/systemd-timesyncd.service" \
    "$ROOT_MNT/lib/systemd/system/systemd-timesyncd.service"; do
    if [[ -s "$candidate" ]]; then
        timesync_unit="$candidate"
        break
    fi
done

[[ -n "$timesync_unit" ]] ||
    die "systemd-timesyncd.service is not installed."

for candidate in \
    "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" \
    "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service"; do
    if [[ -L "$candidate" ]]; then
        wants_link="$candidate"
        break
    fi
done

[[ -n "$wants_link" ]] ||
    die "systemd-timesyncd.service is not enabled."

[[ -e "$ROOT_MNT/etc/localtime" ]] ||
    die "/etc/localtime is missing."

if [[ -L "$ROOT_MNT/etc/localtime" ]]; then
    [[ "$(readlink "$ROOT_MNT/etc/localtime")" == "/usr/share/zoneinfo/Asia/Dubai" ]] ||
        die "Timezone is not Asia/Dubai."
fi

target_package_installed wireless-regdb ||
    die "The wireless-regdb package is not installed."

require_nonempty_file "$ROOT_MNT/usr/lib/firmware/regulatory.db-upstream"
require_nonempty_file "$ROOT_MNT/usr/lib/firmware/regulatory.db.p7s-upstream"

[[ -L "$ROOT_MNT/usr/lib/firmware/regulatory.db" ]] ||
    die "The active regulatory.db firmware link is missing."

[[ "$(readlink "$ROOT_MNT/usr/lib/firmware/regulatory.db")" == \
   "/etc/alternatives/regulatory.db" ]] ||
    die "The active regulatory.db firmware link does not use update-alternatives."

[[ -L "$ROOT_MNT/usr/lib/firmware/regulatory.db.p7s" ]] ||
    die "The active regulatory.db.p7s firmware link is missing."

[[ "$(readlink "$ROOT_MNT/usr/lib/firmware/regulatory.db.p7s")" == \
   "/etc/alternatives/regulatory.db.p7s" ]] ||
    die "The active regulatory.db.p7s firmware link does not use update-alternatives."

[[ -L "$ROOT_MNT/etc/alternatives/regulatory.db" ]] ||
    die "The regulatory.db alternative is missing."

[[ "$(readlink "$ROOT_MNT/etc/alternatives/regulatory.db")" == \
   "/lib/firmware/regulatory.db-upstream" ]] ||
    die "The upstream regulatory database is not selected."

[[ -L "$ROOT_MNT/etc/alternatives/regulatory.db.p7s" ]] ||
    die "The regulatory.db.p7s alternative is missing."

[[ "$(readlink "$ROOT_MNT/etc/alternatives/regulatory.db.p7s")" == \
   "/lib/firmware/regulatory.db.p7s-upstream" ]] ||
    die "The upstream regulatory database signature is not selected."

require_nonempty_file "$ROOT_MNT$REGULATORY_INITRAMFS_STATUS"

grep -Fxq \
    'upstream regulatory.db and regulatory.db.p7s: PASS' \
    "$ROOT_MNT$REGULATORY_INITRAMFS_STATUS" ||
    die "The initramfs upstream regulatory payload validation did not pass."

require_nonempty_file "$ROOT_MNT$PCIE_INITRAMFS_STATUS"

grep -Fxq \
    'Allwinner combo-PHY and PCIe host modules: PASS' \
    "$ROOT_MNT$PCIE_INITRAMFS_STATUS" ||
    die "The initramfs PCIe module validation did not pass."

for efi_unit in efi.automount efi.mount; do
    [[ -L "$ROOT_MNT/etc/systemd/system/$efi_unit" ]] ||
        die "$efi_unit is not masked."

    [[ "$(readlink "$ROOT_MNT/etc/systemd/system/$efi_unit")" == "/dev/null" ]] ||
        die "$efi_unit is not masked to /dev/null."
done
}

target_command_exists() {
local command_name="$1"
local directory

for directory in \
    bin \
    sbin \
    usr/bin \
    usr/sbin \
    usr/local/bin \
    usr/local/sbin; do
    if [[ -x "$ROOT_MNT/$directory/$command_name" ]]; then
        return 0
    fi
done

return 1
}

target_package_installed() {
local package="$1"
local status

status="$(
    dpkg-query \
        --admindir="$ROOT_MNT/var/lib/dpkg" \
        -W \
        -f='${db:Status-Abbrev}' \
        "$package" 2>/dev/null || true
)"

[[ "$status" == ii* ]]
}

validate_spi_maintenance_runtime() {
local common_version
local board_version
local command_name
local package
local payload
local status_file="$ROOT_MNT/var/lib/cubie-a5e/rsetup-self-test.status"
local version_prefix

for package in mtd-utils u-boot-aw2501 u-boot-radxa-cubie-a5e; do
    target_package_installed "$package" ||
        die "Required SPI maintenance package is not installed: $package"
done

for command_name in flashcp flash_erase; do
    target_command_exists "$command_name" ||
        die "Required SPI maintenance command is missing: $command_name"
done

common_version="$(
    dpkg-query \
        --admindir="$ROOT_MNT/var/lib/dpkg" \
        -W \
        -f='${Version}' \
        u-boot-aw2501 2>/dev/null || true
)"
board_version="$(
    dpkg-query \
        --admindir="$ROOT_MNT/var/lib/dpkg" \
        -W \
        -f='${Version}' \
        u-boot-radxa-cubie-a5e 2>/dev/null || true
)"

[[ "$common_version" == "$RADXA_UBOOT_VERSION" ]] ||
    die "Unexpected u-boot-aw2501 version: ${common_version:-missing}; expected $RADXA_UBOOT_VERSION"
[[ "$board_version" == "$RADXA_UBOOT_VERSION" ]] ||
    die "Unexpected u-boot-radxa-cubie-a5e version: ${board_version:-missing}; expected $RADXA_UBOOT_VERSION"

for payload in boot0_spinor.bin boot_package.fex sys_partition_nor.bin setup.sh; do
    require_nonempty_file "$ROOT_MNT$RADXA_UBOOT_PAYLOAD_DIR/$payload"
done

[[ -x "$ROOT_MNT$RADXA_UBOOT_PAYLOAD_DIR/setup.sh" ]] ||
    die "Cubie A5E Radxa U-Boot setup backend is not executable."

version_prefix="U-Boot $RADXA_UBOOT_VERSION-boot-aw2501-"
grep -aFq -- "$version_prefix" \
    "$ROOT_MNT$RADXA_UBOOT_PAYLOAD_DIR/boot_package.fex" ||
    die "Packaged Cubie A5E boot_package.fex does not contain the expected U-Boot $RADXA_UBOOT_VERSION marker."

require_nonempty_file "$status_file"
grep -Fxq 'NVME_INSTALLER_SELF_TEST=PASS' "$status_file" ||
    die "NVMe installer Stage 60 self-test marker is missing."
grep -Fxq "RADXA_UBOOT_VERSION=$RADXA_UBOOT_VERSION" "$status_file" ||
    die "Stage 60 U-Boot validation marker has the wrong version."
grep -Fxq 'RADXA_UBOOT_BACKEND=PASS' "$status_file" ||
    die "Stage 60 rsetup U-Boot backend validation marker is missing."
}

validate_rsetup_and_basic_packages() {
local basic_manifest="$ROOT_MNT$BASIC_PACKAGES_TARGET"
local package
local package_count=0
local required_command
local required_commands=(
    apt-get
    dtc
    jq
    nano
    nmcli
    parted
    ping
    python3
    rfkill
    sgdisk
    sudo
    u-boot-update
    whiptail
)
local required_file
local required_files=(
    "$ROOT_MNT/usr/bin/rsetup"
    "$ROOT_MNT$RADXA_REPO_HELPER_TARGET"
    "$ROOT_MNT$RADXA_REPO_FILE"
    "$ROOT_MNT$RADXA_KEYRING"
    "$ROOT_MNT/usr/lib/librtui/tui.sh"
    "$ROOT_MNT/usr/lib/librtui/utils/utils.sh"
    "$ROOT_MNT/usr/lib/rsetup/cli/main.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/main.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/system/system.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/comm/comm.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/hardware/hardware.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/overlay/overlay.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/local/local.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/task/task.sh"
    "$ROOT_MNT/usr/lib/rsetup/tui/user/user.sh"
    "$ROOT_MNT/var/lib/cubie-a5e/rsetup-self-test.status"
)
local required_package
local required_packages=(
    device-tree-compiler
    dialog
    gdisk
    iw
    iputils-ping
    jq
    kmod
    librtui
    mtd-utils
    network-manager
    nano
    pkexec
    python3-yaml
    radxa-archive-keyring
    rfkill
    rsetup
    u-boot-aw2501
    u-boot-menu
    u-boot-radxa-cubie-a5e
    wget
    whiptail
    wpasupplicant
)

require_nonempty_file "$BASIC_PACKAGES_SRC"
require_nonempty_file "$basic_manifest"

cmp -s "$BASIC_PACKAGES_SRC" "$basic_manifest" ||
    die "Installed basic package manifest differs from the project manifest."

while IFS= read -r package; do
    [[ "$package" =~ ^[[:space:]]*(#|$) ]] && continue

    target_package_installed "$package" ||
        die "Raspberry Pi OS Lite compatible package is not installed: $package"

    package_count=$((package_count + 1))
done <"$basic_manifest"

((package_count >= 40)) ||
    die "Basic package manifest is unexpectedly short: $package_count packages"

for required_package in "${required_packages[@]}"; do
    target_package_installed "$required_package" ||
        die "Required rsetup package is not installed: $required_package"
done

for required_file in "${required_files[@]}"; do
    require_nonempty_file "$required_file"
done

[[ -x "$ROOT_MNT$RADXA_REPO_HELPER_TARGET" ]] ||
    die "Installed Radxa repository helper is not executable."

grep -Fxq \
    "deb [signed-by=$RADXA_KEYRING] https://radxa-repo.github.io/trixie/ trixie main" \
    "$ROOT_MNT$RADXA_REPO_FILE" ||
    die "Official signed Radxa Trixie repository is not configured."

for required_command in "${required_commands[@]}"; do
    target_command_exists "$required_command" ||
        die "Required target command is missing: $required_command"
done

grep -Fxq 'RSETUP_SELF_TEST=PASS' \
    "$ROOT_MNT/var/lib/cubie-a5e/rsetup-self-test.status" ||
    die "rsetup chroot smoke-test marker is missing."
}

validate_root_autogrow_and_compact_image() {
local helper="$ROOT_MNT$ROOT_GROW_PROGRAM"
local unit="$ROOT_MNT$ROOT_GROW_UNIT"
local service_link="$ROOT_MNT$ROOT_GROW_WANTS"
local command_name
local package
local required_line
local root_use_numeric
local available_mib
local minimum_mib
local -a required_commands=(
    growpart
    partprobe
    resize2fs
    sfdisk
    sgdisk
)
local -a required_packages=(
    cloud-guest-utils
    e2fsprogs
)
local -a required_unit_lines=(
    'After=local-fs.target'
    'Before=multi-user.target'
    'ConditionPathExists=!/var/lib/cubie-a5e/rootfs-expanded'
    'Type=oneshot'
    'ExecStart=/usr/local/sbin/cubie-a5e-grow-rootfs'
    'RemainAfterExit=yes'
    'TimeoutStartSec=0'
    'WantedBy=multi-user.target'
)

require_nonempty_file "$helper"
require_nonempty_file "$unit"

[[ -x "$helper" ]] ||
    die "Root filesystem expansion helper is not executable."

bash -n "$helper"

[[ -L "$service_link" ]] ||
    die "Root filesystem expansion service is not enabled."
[[ "$(readlink "$service_link")" == \
   "/usr/lib/systemd/system/cubie-a5e-grow-rootfs.service" ]] ||
    die "Root filesystem expansion service link is incorrect."

[[ ! -e "$ROOT_MNT$ROOT_GROW_MARKER" ]] ||
    die "Fresh image unexpectedly contains a completed root expansion marker."

for package in "${required_packages[@]}"; do
    target_package_installed "$package" ||
        die "Required root expansion package is not installed: $package"
done

for command_name in "${required_commands[@]}"; do
    target_command_exists "$command_name" ||
        die "Required root expansion command is missing: $command_name"
done

for required_line in "${required_unit_lines[@]}"; do
    grep -Fxq "$required_line" "$unit" ||
        die "Root filesystem expansion service is missing: $required_line"
done

grep -Fq 'findmnt -nro SOURCE --target /' "$helper" ||
    die "Root expansion helper does not detect the mounted root source."
grep -Fq '[[ "$part_num" == "3" ]] ||' "$helper" ||
    die "Root expansion helper does not enforce partition 3."
grep -Fq 'die "Root partition is not the final partition:' "$helper" ||
    die "Root expansion helper does not enforce the final-partition safety check."
grep -Fq 'growpart "$disk" "$part_num"' "$helper" ||
    die "Root expansion helper does not expand the detected partition."
grep -Fq 'resize2fs "$root_part"' "$helper" ||
    die "Root expansion helper does not resize the ext4 filesystem."
grep -Fq 'mv -f -- "$marker_tmp" "$MARKER"' "$helper" ||
    die "Root expansion helper does not finalize its success marker atomically."

[[ -d "$ROOT_MNT/var/cache/apt/archives" ]] ||
    die "Target APT archive directory is missing."
[[ -d "$ROOT_MNT/var/lib/apt/lists" ]] ||
    die "Target APT index directory is missing."

if find "$ROOT_MNT/var/cache/apt/archives" \
    -maxdepth 1 \
    -type f \
    -name '*.deb' \
    -print -quit |
    grep -q .; then
    die "Target image still contains cached APT package archives."
fi

if find "$ROOT_MNT/var/lib/apt/lists" \
    -mindepth 1 \
    -print -quit |
    grep -q .; then
    die "Target image still contains disposable APT package indexes."
fi

IFS=' ' read -r \
    ROOT_SIZE_BYTES \
    ROOT_USED_BYTES \
    ROOT_AVAILABLE_BYTES \
    ROOT_USE_PERCENT < <(
        df -B1 --output=size,used,avail,pcent "$ROOT_MNT" |
            awk 'NR == 2 { print $1, $2, $3, $4 }'
    )

[[ "$ROOT_SIZE_BYTES" =~ ^[0-9]+$ ]] ||
    die "Unable to determine root filesystem size."
[[ "$ROOT_USED_BYTES" =~ ^[0-9]+$ ]] ||
    die "Unable to determine root filesystem used space."
[[ "$ROOT_AVAILABLE_BYTES" =~ ^[0-9]+$ ]] ||
    die "Unable to determine root filesystem available space."
[[ "$ROOT_USE_PERCENT" =~ ^[0-9]+%$ ]] ||
    die "Unable to determine root filesystem use percentage."

root_use_numeric="${ROOT_USE_PERCENT%\%}"
((root_use_numeric < 100)) ||
    die "Root filesystem has no usable free space."

available_mib=$((ROOT_AVAILABLE_BYTES / 1024 / 1024))
minimum_mib=$((MINIMUM_ROOT_AVAILABLE_BYTES / 1024 / 1024))

((ROOT_AVAILABLE_BYTES >= MINIMUM_ROOT_AVAILABLE_BYTES)) ||
    die "Root filesystem has only ${available_mib} MiB available; a compact image requires at least ${minimum_mib} MiB."
}

validate_initbox_account_and_login_policy() {
local account_record
local account_uid
local account_gid
local account_home
local account_shell
local home_gid
local home_uid
local shadow_record
local shadow_hash
local shadow_last_change
local shadow_max_days
local -a shadow_fields=()
local sudo_members
local autologin_file

require_nonempty_file "$ROOT_MNT/etc/passwd"
require_nonempty_file "$ROOT_MNT/etc/group"
require_nonempty_file "$ROOT_MNT/etc/shadow"
require_nonempty_file "$ROOT_MNT$INITBOX_SUDOERS"
require_nonempty_file "$ROOT_MNT$INITBOX_ACCOUNT_STATUS"
require_nonempty_file "$ROOT_MNT$GETTY_TTY1_DROPIN"
require_nonempty_file "$ROOT_MNT$SERIAL_GETTY_DROPIN"

awk -F: '$1 == "root" {found = 1} END {exit found ? 0 : 1}' \
    "$ROOT_MNT/etc/passwd" ||
    die "The root recovery account is missing."

account_record="$(
    awk -F: -v user="$INITBOX_USER" \
        '$1 == user {print; found = 1} END {exit found ? 0 : 1}' \
        "$ROOT_MNT/etc/passwd"
)" ||
    die "The initbox account is missing from /etc/passwd."

IFS=: read -r _ _ account_uid account_gid _ account_home account_shell \
    <<<"$account_record"

[[ "$account_uid" =~ ^[0-9]+$ && "$account_uid" -ge 1000 ]] ||
    die "The initbox account does not have a normal user UID."

[[ "$account_gid" =~ ^[0-9]+$ ]] ||
    die "The initbox account has an invalid primary GID."

[[ "$account_home" == "/home/$INITBOX_USER" ]] ||
    die "The initbox account home directory is incorrect: $account_home"

[[ "$account_shell" == "/bin/bash" ]] ||
    die "The initbox account shell is incorrect: $account_shell"

[[ -d "$ROOT_MNT$account_home" ]] ||
    die "The initbox home directory is missing."

home_uid="$(stat -c '%u' "$ROOT_MNT$account_home")"
home_gid="$(stat -c '%g' "$ROOT_MNT$account_home")"

[[ "$home_uid" == "$account_uid" && "$home_gid" == "$account_gid" ]] ||
    die "The initbox home directory ownership is incorrect."

shadow_record="$(
    awk -F: -v user="$INITBOX_USER" \
        '$1 == user {print; found = 1} END {exit found ? 0 : 1}' \
        "$ROOT_MNT/etc/shadow"
)" ||
    die "The initbox account is missing from /etc/shadow."

IFS=: read -r -a shadow_fields <<<"$shadow_record"
shadow_hash="${shadow_fields[1]:-}"
shadow_last_change="${shadow_fields[2]:-}"
shadow_max_days="${shadow_fields[4]:-}"

[[ -n "$shadow_hash" &&
   "$shadow_hash" != '!'* &&
   "$shadow_hash" != '*'* ]] ||
    die "The initbox password is empty or locked."

[[ "$shadow_last_change" =~ ^[1-9][0-9]*$ ]] ||
    die "The initbox password is marked for a mandatory change."

[[ -z "$shadow_max_days" ]] ||
    die "The initbox password expiry policy is not disabled."

sudo_members="$(
    awk -F: '$1 == "sudo" {print $4}' "$ROOT_MNT/etc/group"
)"

tr ',' '\n' <<<"$sudo_members" |
    grep -Fxq "$INITBOX_USER" ||
    die "The initbox account is not a member of the sudo group."

[[ "$(stat -c '%a' "$ROOT_MNT$INITBOX_SUDOERS")" == "440" ]] ||
    die "The initbox sudoers file does not have mode 0440."

grep -Fxq "$INITBOX_USER ALL=(ALL:ALL) NOPASSWD:ALL" \
    "$ROOT_MNT$INITBOX_SUDOERS" ||
    die "The initbox passwordless sudo policy is incorrect."

grep -Fxq 'CONSOLE_LOGIN=prompt' \
    "$ROOT_MNT$INITBOX_ACCOUNT_STATUS" ||
    die "The console login policy marker is incorrect."

grep -Fxq 'ROOT_AUTOLOGIN=disabled' \
    "$ROOT_MNT$INITBOX_ACCOUNT_STATUS" ||
    die "The root autologin policy marker is incorrect."

grep -Fxq 'PASSWORD_POLICY=fixed-init' \
    "$ROOT_MNT$INITBOX_ACCOUNT_STATUS" ||
    die "The fixed initbox password policy marker is incorrect."

grep -Fxq 'PASSWORD_EXPIRY=disabled' \
    "$ROOT_MNT$INITBOX_ACCOUNT_STATUS" ||
    die "The initbox password-expiry policy marker is incorrect."

grep -Fxq 'INITIAL_PASSWORD_CHANGE=not-required' \
    "$ROOT_MNT$INITBOX_ACCOUNT_STATUS" ||
    die "The initial password-change policy marker is incorrect."

grep -Fxq \
    "ExecStart=-/sbin/agetty -o '-p -- \\\\u' --noclear - \$TERM" \
    "$ROOT_MNT$GETTY_TTY1_DROPIN" ||
    die "tty1 does not use a normal login prompt."

grep -Fxq \
    "ExecStart=-/sbin/agetty -o '-p -- \\\\u' --keep-baud 115200,57600,38400,9600 - \$TERM" \
    "$ROOT_MNT$SERIAL_GETTY_DROPIN" ||
    die "ttyS0 does not use a normal serial login prompt."

[[ -L "$ROOT_MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" ]] ||
    die "getty@tty1.service is not enabled."

[[ -L "$ROOT_MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ]] ||
    die "serial-getty@ttyS0.service is not enabled."

[[ "$(readlink "$ROOT_MNT/etc/systemd/system/getty.target.wants/getty@tty1.service")" == \
   "/usr/lib/systemd/system/getty@.service" ]] ||
    die "getty@tty1.service does not use the standard getty template."

[[ "$(readlink "$ROOT_MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service")" == \
   "/usr/lib/systemd/system/serial-getty@.service" ]] ||
    die "serial-getty@ttyS0.service does not use the standard serial-getty template."

while IFS= read -r -d '' autologin_file; do
    if grep -Eq \
        -- '--autologin([=[:space:]]+)root([[:space:]]|$)|agetty.*([[:space:]]-a|--autologin)([=[:space:]]+)root([[:space:]]|$)' \
        "$autologin_file"; then
        die "Automatic root login remains enabled: $autologin_file"
    fi
done < <(
    find "$ROOT_MNT/etc/systemd/system" \
        \( -type f -o -type l \) \
        -print0
)
}

validate_single_kernel_state() {
local count
local packaged_kernels

count="$(
    find "$ROOT_MNT/boot" \
        -maxdepth 1 \
        -type f \
        -name 'vmlinuz-*' \
        -printf '%f\n' |
        wc -l
)"
[[ "$count" -eq 1 ]] ||
    die "Expected one rootfs kernel image; found $count"

count="$(
    find "$ROOT_MNT/boot" \
        -maxdepth 1 \
        -type f \
        -name 'initrd.img-*' \
        -printf '%f\n' |
        wc -l
)"
[[ "$count" -eq 1 ]] ||
    die "Expected one rootfs initramfs; found $count"

count="$(
    find "$ROOT_MNT/boot" \
        -maxdepth 1 \
        -type f \
        -name 'config-*' \
        -printf '%f\n' |
        wc -l
)"
[[ "$count" -eq 1 ]] ||
    die "Expected one rootfs kernel config; found $count"

if find "$ROOT_MNT/boot" \
    -maxdepth 1 \
    -type d \
    \( -name dtb -o -name 'dtb-*' \) \
    -print -quit |
    grep -q .; then
    die "Stale DTB directory remains under the rootfs /boot."
fi

count="$(
    find "$ROOT_MNT/usr/lib" \
        -maxdepth 1 \
        -type d \
        -name 'linux-image-*' \
        -printf '%f\n' |
        wc -l
)"
[[ "$count" -eq 1 ]] ||
    die "Expected one versioned DTB tree; found $count"

if ((SAME_FS == 0)); then
    count="$(
        find "$BOOT_MNT" \
            -maxdepth 1 \
            -type f \
            -name 'vmlinuz-*' \
            -printf '%f\n' |
            wc -l
    )"
    [[ "$count" -eq 1 ]] ||
        die "Expected one kernel image on the boot filesystem; found $count"

    count="$(
        find "$BOOT_MNT" \
            -maxdepth 1 \
            -type f \
            -name 'initrd.img-*' \
            -printf '%f\n' |
            wc -l
    )"
    [[ "$count" -eq 1 ]] ||
        die "Expected one initramfs on the boot filesystem; found $count"

    count="$(
        find "$BOOT_MNT" \
            -maxdepth 1 \
            -type d \
            -name 'dtb-*' \
            -printf '%f\n' |
            wc -l
    )"
    [[ "$count" -eq 1 ]] ||
        die "Expected one DTB directory on the boot filesystem; found $count"

    [[ ! -e "$BOOT_MNT/dtb" ]] ||
        die "Unversioned donor DTB directory remains on the boot filesystem."
fi

packaged_kernels="$(
    dpkg-query \
        --admindir="$ROOT_MNT/var/lib/dpkg" \
        -W \
        -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null |
        awk '$2 ~ /^ii/ && $1 ~ /^(linux-image|linux-dtb)(-|$)/ { print $1 }'
)"

[[ -z "$packaged_kernels" ]] ||
    die "Donor kernel packages remain installed: $packaged_kernels"

if find "$ROOT_MNT" "$BOOT_MNT" \
    -xdev \
    \( -name '*5.15.147-20-aw2501*' -o -name 'extlinux.conf.before-6.16' \) \
    -print -quit |
    grep -q .; then
    die "Linux 5.15 kernel or recovery artifacts remain installed."
fi
}

validate_update_manager() {
local apt_guard="$ROOT_MNT/etc/apt/preferences.d/99-cubie-a5e-managed-kernel"
local layout="$ROOT_MNT/etc/cubie-a5e-update/layout.env"
local state="$ROOT_MNT/var/lib/cubie-a5e-update/active.env"
local trusted_key="$ROOT_MNT/etc/cubie-a5e-update/trusted-public.pem"
local service="$ROOT_MNT/usr/lib/systemd/system/cubie-a5e-update-finalize.service"
local service_link="$ROOT_MNT/etc/systemd/system/multi-user.target.wants/cubie-a5e-update-finalize.service"
local rsetup_wrapper="$ROOT_MNT/usr/local/bin/rsetup"
local updater="$ROOT_MNT/usr/local/sbin/cubie-a5e-update"
local nvme_installer="$ROOT_MNT/usr/local/sbin/cubie-a5e-install-nvme"
local update_bundle
local verify_dir

require_nonempty_file "$apt_guard"
require_nonempty_file "$layout"
require_nonempty_file "$state"
require_nonempty_file "$trusted_key"
require_nonempty_file "$service"
require_nonempty_file "$rsetup_wrapper"
require_nonempty_file "$updater"
require_nonempty_file "$nvme_installer"
require_nonempty_file "$ROOT_MNT/usr/bin/rsetup"

[[ -x "$rsetup_wrapper" ]] || die "rsetup wrapper is not executable."
[[ -x "$updater" ]] || die "Cubie A5E updater is not executable."
[[ -x "$nvme_installer" ]] || die "Cubie A5E NVMe installer is not executable."
[[ -L "$service_link" ]] || die "Update finalization service is not enabled."
[[ "$(readlink "$service_link")" == \
   "/usr/lib/systemd/system/cubie-a5e-update-finalize.service" ]] ||
    die "Update finalization service link is incorrect."

grep -Fxq 'Package: linux-image-* linux-dtb-*' "$apt_guard" ||
    die "Managed-kernel APT guard package list is incorrect."
grep -Fxq 'Pin-Priority: -1' "$apt_guard" ||
    die "Managed-kernel APT guard priority is incorrect."
grep -Fq 'Cubie A5E signed kernel and board updates' "$rsetup_wrapper" ||
    die "rsetup wrapper lacks the Cubie A5E update menu."
grep -Fq -- '--self-test' "$rsetup_wrapper" ||
    die "rsetup wrapper lacks its non-interactive self-test."
grep -Fq 'Install the current Cubie A5E system to NVMe' "$rsetup_wrapper" ||
    die "rsetup wrapper lacks the Cubie A5E NVMe installation menu."
grep -Fq '"$CUBIE_NVME_INSTALL" --tui' "$rsetup_wrapper" ||
    die "rsetup wrapper does not invoke the managed NVMe installer."

bash -n "$nvme_installer" ||
    die "Installed Cubie A5E NVMe installer failed bash syntax validation."
grep -Fq 'self-test: PASS' "$nvme_installer" ||
    die "NVMe installer lacks its non-destructive self-test marker."
grep -Fq 'Expected the running Cubie A5E root filesystem on partition 3' "$nvme_installer" ||
    die "NVMe installer lacks the managed partition-3 source guard."
grep -Fq 'Expected partition 3 to be the final source partition' "$nvme_installer" ||
    die "NVMe installer lacks the final-source-partition guard."
grep -Fq 'validate_source_runtime' "$nvme_installer" ||
    die "NVMe installer lacks managed source-runtime preflight validation."
grep -Fq 'A managed kernel/board update is pending' "$nvme_installer" ||
    die "NVMe installer lacks the pending-update safety guard."
grep -Fq 'Target must be a whole NVMe namespace' "$nvme_installer" ||
    die "NVMe installer lacks the whole-device target guard."
grep -Fq 'TARGET_DISK_SIZE >= SOURCE_DISK_SIZE' "$nvme_installer" ||
    die "NVMe installer lacks the guarded target-capacity check."
grep -Fq 'iflag=count_bytes' "$nvme_installer" ||
    die "NVMe installer does not preserve the Radxa pre-root boot-chain area."
grep -Fq 'sgdisk -A 3:set:2 "$TARGET_DISK"' "$nvme_installer" ||
    die "NVMe installer does not restore the partition-3 GPT bootable attribute required by SPI U-Boot."
grep -Fq 'Target partition 3 is missing the GPT legacy bootable attribute required by SPI U-Boot.' "$nvme_installer" ||
    die "NVMe installer lacks post-partitioning bootable-attribute validation."
grep -Fq 'sgdisk -G "$TARGET_DISK"' "$nvme_installer" ||
    die "NVMe installer does not regenerate GPT identifiers on the target."
grep -Fq 'mkfs.ext4 -F -L rootfs -U random' "$nvme_installer" ||
    die "NVMe installer does not create a fresh root filesystem UUID."
grep -Fq -- '-aHAXx' "$nvme_installer" ||
    die "NVMe installer lacks filesystem-preserving rsync options."
for exclusion in dev proc run sys tmp mnt media; do
    grep -Fq -- "--exclude='/${exclusion}/*'" "$nvme_installer" ||
        die "NVMe installer does not preserve the /$exclusion mountpoint directory."
    if grep -Fq -- "--exclude='/${exclusion}/***'" "$nvme_installer"; then
        die "NVMe installer still excludes the /$exclusion mountpoint directory itself."
    fi
done
grep -Fq 'normalize_target_runtime_layout' "$nvme_installer" ||
    die "NVMe installer lacks target runtime mountpoint normalization."
grep -Fq 'install -d -m 1777 -- "$TARGET_ROOT_MNT/tmp"' "$nvme_installer" ||
    die "NVMe installer does not enforce mode 1777 on target /tmp."
grep -Fq 'validate_runtime_root_layout "$TARGET_ROOT_MNT" "Target"' "$nvme_installer" ||
    die "NVMe installer does not validate target runtime mountpoints and PID1."
grep -Fq 'EXPECTED_SPI_FREQUENCY="20000000"' "$nvme_installer" ||
    die "NVMe installer does not enforce the field-validated 20 MHz SPI-NOR frequency."
grep -Fq 'validate_spi_bootloader' "$nvme_installer" ||
    die "NVMe installer lacks the on-board SPI bootloader preflight."
grep -Fq 'On-board SPI firmware does not contain the installed Cubie A5E U-Boot' "$nvme_installer" ||
    die "NVMe installer does not reject an outdated on-board SPI bootloader."
grep -Fq 'dpkg --compare-versions "$aw2501_version" ge "$MINIMUM_UBOOT_VERSION"' "$nvme_installer" ||
    die "NVMe installer does not enforce the validated minimum SPI U-Boot version."
grep -Fq 'rewrite_target_fstab' "$nvme_installer" ||
    die "NVMe installer lacks target fstab rewriting."
grep -Fq 'rewrite_target_extlinux' "$nvme_installer" ||
    die "NVMe installer lacks target extlinux rewriting."
grep -Fq 'rewrite_target_layout' "$nvme_installer" ||
    die "NVMe installer lacks update-layout rewriting."
grep -Fq 'e2fsck -fn "$TARGET_ROOT_PART"' "$nvme_installer" ||
    die "NVMe installer lacks final read-only ext4 verification."
grep -Fq 'ExecStart=/usr/local/sbin/cubie-a5e-update --finalize-boot' "$service" ||
    die "Update finalization service command is incorrect."
grep -Fq "ACTIVE_KERNEL_RELEASE=$KERNEL_RELEASE" "$state" ||
    die "Managed update state has the wrong kernel release."
grep -Fq "ACTIVE_UPDATE_VERSION=$UPDATE_VERSION" "$state" ||
    die "Managed update state has the wrong update version."

[[ ! -e "$ROOT_MNT/var/lib/cubie-a5e-update/pending.env" ]] ||
    die "Fresh image unexpectedly contains a pending kernel update."
[[ ! -e "$ROOT_MNT/var/lib/cubie-a5e-update/rollback-firmware" ]] ||
    die "Fresh image unexpectedly contains rollback firmware."

openssl pkey -pubin -in "$trusted_key" -noout >/dev/null ||
    die "Trusted update public key is invalid."

update_bundle="$(<"$UPDATE_BUNDLE_FILE")"
tar -tzf "$update_bundle" >/dev/null ||
    die "Generated signed update bundle is unreadable."

verify_dir="$(mktemp -d "$BUILD_ROOT/update-validation.XXXXXX")"
tar -xzf "$update_bundle" \
    -C "$verify_dir" \
    manifest.env \
    SHA256SUMS \
    SHA256SUMS.sig \
    payload

openssl dgst \
    -sha256 \
    -verify "$trusted_key" \
    -signature "$verify_dir/SHA256SUMS.sig" \
    "$verify_dir/SHA256SUMS" >/dev/null ||
    die "Installed public key does not verify the generated update bundle."

(
    cd "$verify_dir"
    sha256sum -c SHA256SUMS >/dev/null
) || die "Generated update bundle checksum verification failed."

rm -rf -- "$verify_dir"
}

validate_extlinux() {
local extlinux="$BOOT_MNT/$EXTLINUX_REL"
local expected_linux_path
local expected_initrd_path
local expected_fdtdir_path
local root_uuid

require_nonempty_file "$extlinux"

if [[ "$EXTLINUX_REL" == boot/* ]]; then
    expected_linux_path="/boot/vmlinuz-$KERNEL_RELEASE"
    expected_initrd_path="/boot/initrd.img-$KERNEL_RELEASE"
    expected_fdtdir_path="/usr/lib/linux-image-$KERNEL_RELEASE/"
else
    expected_linux_path="/vmlinuz-$KERNEL_RELEASE"
    expected_initrd_path="/initrd.img-$KERNEL_RELEASE"
    expected_fdtdir_path="/dtb-$KERNEL_RELEASE/"
fi

root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"

[[ -n "$root_uuid" ]] ||
    die "Could not determine target root UUID."

grep -Eq '^[[:space:]]*default[[:space:]]+cubie-a5e[[:space:]]*$' \
    "$extlinux" ||
    die "The managed Cubie A5E entry is not the extlinux default."

[[ "$(
    grep -Ec '^[[:space:]]*label[[:space:]]+cubie-a5e[[:space:]]*$' \
        "$extlinux"
)" -eq 1 ]] ||
    die "Expected exactly one managed Cubie A5E extlinux entry."

[[ "$(grep -Ec '^[[:space:]]*label[[:space:]]+' "$extlinux")" -eq 1 ]] ||
    die "Expected exactly one extlinux boot entry."

grep -Fq "menu label Debian GNU/Linux 13 Linux $KERNEL_RELEASE" \
    "$extlinux" ||
    die "Managed kernel menu label is missing or incorrect."

grep -Fq "linux $expected_linux_path" "$extlinux" ||
    die "Managed kernel path is incorrect."

grep -Fq "initrd $expected_initrd_path" "$extlinux" ||
    die "Managed initrd path is incorrect."

grep -Fq "fdtdir $expected_fdtdir_path" "$extlinux" ||
    die "Managed fdtdir path is incorrect."

grep -Eq \
    "^[[:space:]]*append[[:space:]].*root=UUID=${root_uuid}([[:space:]]|$)" \
    "$extlinux" ||
    die "Managed entry does not use the target root UUID."

linux_616_append="$(
    awk '
        /^[[:space:]]*label[[:space:]]+cubie-a5e[[:space:]]*$/ {
            inside = 1
            next
        }

        inside && /^[[:space:]]*label[[:space:]]+/ {
            exit
        }

        inside && /^[[:space:]]*append[[:space:]]+/ {
            sub(/^[[:space:]]*append[[:space:]]+/, "")
            print
            exit
        }
    ' "$extlinux"
)"

[[ -n "$linux_616_append" ]] ||
    die "Managed append line is missing."

for required_argument in \
    'console=ttyS0,115200n8' \
    'earlycon=uart8250,mmio32,0x02500000,115200' \
    'ignore_loglevel' \
    'loglevel=8'; do
    grep -Eq "(^|[[:space:]])${required_argument}([[:space:]]|$)" \
        <<<"$linux_616_append" ||
        die "Managed append line is missing: $required_argument"
done

if grep -Eq '(^|[[:space:]])(console=ttyAS0,115200n8|earlyprintk=sunxi-uart,0x2500000|quiet|splash|loglevel=4|earlycon)([[:space:]]|$)' \
    <<<"$linux_616_append"; then
    die "Managed append line still contains vendor or suppressed-console arguments."
fi

if grep -Eq '5\.15\.147-20-aw2501|^[[:space:]]*label[[:space:]]+(l0|l0r)[[:space:]]*$' \
    "$extlinux"; then
    die "Official Linux 5.15 recovery references remain in extlinux."
fi

cp -a -- "$extlinux" "$VALIDATION_EXTLINUX"

}

validate_compiled_dtb() {
local bldo1_phandle
local cldo4_phandle
local gmac1_pinctrl
local gmac1_phy_supply
local gmac1_power_domain
local gpio_bank
local gpio_flags
local gpio_phandle
local gpio_pin
local mmc_pwrseq
local mmc_vmmc
local mmc_vqmmc
local pck600_phandle
local combophy_phandle
local pcie_phy
local pcie_power_domain
local pio_pg_supply
local pwrseq_phandle
local r_pio_phandle
local rgmii1_phandle
local spi0_cs0_phandle
local spi0_pc_phandle
local spi0_pinctrl
local reset_bank
local reset_flags
local reset_gpio_phandle
local reset_pin
local target_dtb
local wifi_3v3_phandle
local wifi_interrupt_parent
local wifi_reset_bank
local wifi_reset_flags
local wifi_reset_gpio_phandle
local wifi_reset_pin

if ((SAME_FS == 1)); then
    target_dtb="$ROOT_MNT/usr/lib/linux-image-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"
else
    target_dtb="$BOOT_MNT/dtb-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"
fi

require_nonempty_file "$target_dtb"

rm -f -- "$VALIDATION_DTB"

dtc \
    -I dtb \
    -O dts \
    -E ranges_format \
    -E reg_format \
    -E simple_bus_reg \
    -Wno-unit_address_vs_reg \
    -o "$VALIDATION_DTB" \
    "$target_dtb"

require_nonempty_file "$VALIDATION_DTB"

if grep -Eq \
    'allwinner,sunxi-rfkill|allwinner,sunxi-wlan|wlan_busnum|wlan_power' \
    "$VALIDATION_DTB"; then
    die "Installed DTB still contains the obsolete vendor RFKill/rescan contract."
fi

grep -qF 'regulator-name = "3v3-wifi";' \
    "$VALIDATION_DTB" ||
    die "Installed DTB lacks the PL7-controlled Wi-Fi 3.3 V regulator."

grep -qF 'cap-sdio-irq;' "$VALIDATION_DTB" ||
    die "Installed DTB lacks cap-sdio-irq."

grep -qF 'non-removable;' "$VALIDATION_DTB" ||
    die "Installed DTB does not mark Wi-Fi as non-removable."

[[ "$(
    fdtget -t s \
        "$target_dtb" \
        /soc/pinctrl@2000000/mmc1-pins \
        pins
)" == "PG0 PG1 PG2 PG3 PG4 PG5" ]] ||
    die "Installed DTB lacks the mmc1 PG0-PG5 pin group."

grep -qF 'ethernet@4510000' "$VALIDATION_DTB" ||
    die "Installed DTB lacks GMAC1."

grep -qF 'allwinner,sun55i-a523-gmac200' "$VALIDATION_DTB" ||
    die "Installed DTB lacks the GMAC200 compatible."

[[ "$(fdtget -t s "$target_dtb" /aliases ethernet1)" == \
   "/soc/ethernet@4510000" ]] ||
    die "Installed DTB ethernet1 alias does not resolve to GMAC1."

[[ "$(fdtget -t s "$target_dtb" /soc/ethernet@4510000 status)" == \
   "okay" ]] ||
    die "Installed DTB does not enable GMAC1."

[[ "$(fdtget -t s "$target_dtb" /soc/ethernet@4510000 phy-mode)" == \
   "rgmii-id" ]] ||
    die "Installed DTB has the wrong GMAC1 PHY mode."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/pinctrl@2000000/rgmii1-pins \
    allwinner,pinmux)" == "5" ]] ||
    die "Installed DTB has the wrong GMAC1 numeric pinmux."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/pinctrl@2000000/rgmii1-pins \
    function)" == "gmac1" ]] ||
    die "Installed DTB lacks the GMAC1 pinctrl function property."

rgmii1_phandle="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/pinctrl@2000000/rgmii1-pins \
        phandle
)"
gmac1_pinctrl="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/ethernet@4510000 \
        pinctrl-0
)"

[[ "$gmac1_pinctrl" == "$rgmii1_phandle" ]] ||
    die "Installed DTB does not connect GMAC1 to the RGMII1 pinctrl node."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/ethernet@4510000 \
    pinctrl-names)" == "default" ]] ||
    die "Installed DTB has the wrong GMAC1 pinctrl name."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/ethernet@4510000 \
    tx-internal-delay-ps)" == "300" ]] ||
    die "Installed DTB has the wrong GMAC1 TX delay property."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/ethernet@4510000 \
    rx-internal-delay-ps)" == "400" ]] ||
    die "Installed DTB has the wrong GMAC1 RX delay property."

pck600_phandle="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/power-controller@7060000 \
        phandle
)"
gmac1_power_domain="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/ethernet@4510000 \
        power-domains
)"

[[ "$gmac1_power_domain" == "$pck600_phandle 4" ]] ||
    die "Installed DTB does not connect GMAC1 to PCK600 PD_VO1."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/power-controller@7060000 \
    compatible)" == "allwinner,sun55i-a523-pck-600" ]] ||
    die "Installed DTB lacks the A523 PCK600 controller compatible."

[[ "$(fdtget -t s "$target_dtb" /soc/pcie@4800000 status)" == \
   "okay" ]] ||
    die "Installed DTB does not enable PCIe."

[[ "$(fdtget -t s "$target_dtb" /soc/phy@4f00000 status)" == \
   "okay" ]] ||
    die "Installed DTB does not enable the PCIe combo PHY."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/pcie@4800000 \
    max-link-speed)" == "2" ]] ||
    die "Installed DTB does not request PCIe Gen2."

[[ "$(fdtget -t u "$target_dtb" /soc '#address-cells')" == "1" ]] ||
    die "Installed DTB /soc bus does not use one address cell."

[[ "$(fdtget -t u "$target_dtb" /soc '#size-cells')" == "1" ]] ||
    die "Installed DTB /soc bus does not use one size cell."

[[ "$(fdtget -t x "$target_dtb" /soc/pcie@4800000 reg)" == \
   "4800000 480000" ]] ||
    die "Installed DTB has the wrong PCIe register range."

[[ "$(fdtget -t x "$target_dtb" /soc/phy@4f00000 reg)" == \
   "4f00000 80000 4f80000 80000" ]] ||
    die "Installed DTB has the wrong combo-PHY register ranges."

[[ "$(fdtget -t x "$target_dtb" /soc/pcie@4800000 ranges)" == \
   "800 0 20000000 20000000 0 1000000 81000000 0 21000000 21000000 0 1000000 82000000 0 22000000 22000000 0 e000000" ]] ||
    die "Installed DTB has the wrong PCIe outbound address windows."

combophy_phandle="$(
    fdtget -t x "$target_dtb" /soc/phy@4f00000 phandle
)"
pcie_phy="$(
    fdtget -t x "$target_dtb" /soc/pcie@4800000 phys
)"
pcie_power_domain="$(
    fdtget -t x "$target_dtb" /soc/pcie@4800000 power-domains
)"

[[ "$pcie_phy" == "$combophy_phandle 2" ]] ||
    die "Installed DTB does not connect PCIe to the combo PHY."

[[ "$pcie_power_domain" == "$pck600_phandle 7" ]] ||
    die "Installed DTB does not connect PCIe to PCK600 PD_PCIE."

[[ "$(fdtget -t s "$target_dtb" /soc/spi@4025000 compatible)" == \
   "allwinner,sun55i-a523-spi" ]] ||
    die "Installed DTB lacks the A523 SPI0 compatible."

[[ "$(fdtget -t s "$target_dtb" /soc/spi@4025000 status)" == \
   "okay" ]] ||
    die "Installed DTB does not enable SPI0."

[[ "$(fdtget -t x "$target_dtb" /soc/spi@4025000 reg)" == \
   "4025000 1000" ]] ||
    die "Installed DTB has the wrong SPI0 register range."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/pinctrl@2000000/spi0-pc-pins \
    pins)" == "PC2 PC4 PC12" ]] ||
    die "Installed DTB has the wrong SPI0 data/clock pins."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/pinctrl@2000000/spi0-pc-pins \
    allwinner,pinmux)" == "4" ]] ||
    die "Installed DTB has the wrong SPI0 data/clock pinmux."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/pinctrl@2000000/spi0-cs0-pc-pin \
    pins)" == "PC3" ]] ||
    die "Installed DTB has the wrong SPI0 CS0 pin."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/pinctrl@2000000/spi0-cs0-pc-pin \
    allwinner,pinmux)" == "4" ]] ||
    die "Installed DTB has the wrong SPI0 CS0 pinmux."

spi0_pc_phandle="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/pinctrl@2000000/spi0-pc-pins \
        phandle
)"
spi0_cs0_phandle="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/pinctrl@2000000/spi0-cs0-pc-pin \
        phandle
)"
spi0_pinctrl="$(fdtget -t x "$target_dtb" /soc/spi@4025000 pinctrl-0)"

[[ "$spi0_pinctrl" == "$spi0_pc_phandle $spi0_cs0_phandle" ]] ||
    die "Installed DTB has the wrong SPI0 pinctrl references."

[[ "$(fdtget -t s "$target_dtb" /soc/spi@4025000 pinctrl-names)" == \
   "default" ]] ||
    die "Installed DTB has the wrong SPI0 pinctrl name."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/spi@4025000/flash@0 \
    compatible)" == "jedec,spi-nor" ]] ||
    die "Installed DTB lacks the SPI-NOR flash compatible."

[[ "$(fdtget -t u "$target_dtb" /soc/spi@4025000/flash@0 reg)" == \
   "0" ]] ||
    die "Installed DTB has the wrong SPI-NOR chip select."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/spi@4025000/flash@0 \
    spi-max-frequency)" == "$EXPECTED_SPI_FREQUENCY" ]] ||
    die "Installed DTB SPI-NOR frequency is not the field-validated ${EXPECTED_SPI_FREQUENCY} Hz."

cldo4_phandle="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/i2c@7081400/pmic@34/regulators/cldo4 \
        phandle
)"
gmac1_phy_supply="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/ethernet@4510000 \
        phy-supply
)"

[[ "$gmac1_phy_supply" == "$cldo4_phandle" ]] ||
    die "Installed DTB does not connect GMAC1 PHY power to CLDO4."

IFS=' ' read -r reset_gpio_phandle reset_bank reset_pin reset_flags < <(
    fdtget -t x \
        "$target_dtb" \
        /soc/ethernet@4510000/mdio/ethernet-phy@1 \
        reset-gpios
)

[[ -n "$reset_gpio_phandle" &&
   "$reset_bank" == "9" &&
   "$reset_pin" == "10" &&
   "$reset_flags" == "1" ]] ||
    die "Installed DTB does not use PJ16 active-low for GMAC1 PHY reset."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/ethernet@4510000/mdio/ethernet-phy@1 \
    reset-assert-us)" == "10000" ]] ||
    die "Installed DTB has the wrong GMAC1 PHY reset assertion time."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/ethernet@4510000/mdio/ethernet-phy@1 \
    reset-deassert-us)" == "150000" ]] ||
    die "Installed DTB has the wrong GMAC1 PHY reset deassertion time."

[[ "$(fdtget -t s "$target_dtb" /soc/mmc@4021000 status)" == \
   "okay" ]] ||
    die "Installed DTB does not enable mmc1."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/mmc@4021000 \
    max-frequency)" == "40000000" ]] ||
    die "Installed DTB does not cap Wi-Fi SDIO at the tested 40 MHz."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/mmc@4021000/wifi@1 \
    reg)" == "1" ]] ||
    die "Installed DTB lacks the AIC8800 SDIO function at address 1."

wifi_3v3_phandle="$(fdtget -t x "$target_dtb" /3v3-wifi phandle)"
mmc_vmmc="$(
    fdtget -t x "$target_dtb" /soc/mmc@4021000 vmmc-supply
)"
bldo1_phandle="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/i2c@7081400/pmic@34/regulators/bldo1 \
        phandle
)"
mmc_vqmmc="$(
    fdtget -t x "$target_dtb" /soc/mmc@4021000 vqmmc-supply
)"
pwrseq_phandle="$(fdtget -t x "$target_dtb" /wifi-pwrseq phandle)"
mmc_pwrseq="$(
    fdtget -t x "$target_dtb" /soc/mmc@4021000 mmc-pwrseq
)"

[[ "$mmc_vmmc" == "$wifi_3v3_phandle" ]] ||
    die "Installed DTB does not connect mmc1 vmmc to Wi-Fi 3.3 V."

[[ "$mmc_vqmmc" == "$bldo1_phandle" ]] ||
    die "Installed DTB does not connect mmc1 vqmmc to BLDO1."

[[ "$mmc_pwrseq" == "$pwrseq_phandle" ]] ||
    die "Installed DTB does not connect mmc1 to the Wi-Fi power sequence."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /3v3-wifi \
    regulator-min-microvolt)" == "3300000" ]] ||
    die "Installed DTB has the wrong Wi-Fi main-rail minimum voltage."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /3v3-wifi \
    regulator-max-microvolt)" == "3300000" ]] ||
    die "Installed DTB has the wrong Wi-Fi main-rail maximum voltage."

IFS=' ' read -r gpio_phandle gpio_bank gpio_pin gpio_flags < <(
    fdtget -t x "$target_dtb" /3v3-wifi gpio
)

[[ -n "$gpio_phandle" &&
   "$gpio_bank" == "0" &&
   "$gpio_pin" == "7" &&
   "$gpio_flags" == "0" ]] ||
    die "Installed DTB does not control Wi-Fi 3.3 V with PL7 active-high."

IFS=' ' read -r \
    wifi_reset_gpio_phandle \
    wifi_reset_bank \
    wifi_reset_pin \
    wifi_reset_flags < <(
    fdtget -t x "$target_dtb" /wifi-pwrseq reset-gpios
)

r_pio_phandle="$(
    fdtget -t x "$target_dtb" /soc/pinctrl@7022000 phandle
)"

[[ "$gpio_phandle" == "$r_pio_phandle" ]] ||
    die "Installed DTB does not source the PL7 Wi-Fi enable from R_PIO."

[[ "$wifi_reset_gpio_phandle" == "$r_pio_phandle" &&
   "$wifi_reset_bank" == "1" &&
   "$wifi_reset_pin" == "1" &&
   "$wifi_reset_flags" == "1" ]] ||
    die "Installed DTB does not reset Wi-Fi through PM1 active-low."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /wifi-pwrseq \
    post-power-on-delay-ms)" == "200" ]] ||
    die "Installed DTB does not wait 200 ms after Wi-Fi power-on."

pio_pg_supply="$(
    fdtget -t x "$target_dtb" /soc/pinctrl@2000000 vcc-pg-supply
)"

[[ "$pio_pg_supply" == "$bldo1_phandle" ]] ||
    die "Installed DTB does not connect the PG I/O domain to BLDO1."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/i2c@7081400/pmic@34/regulators/bldo1 \
    regulator-name)" == "vcc-pg-iowifi" ]] ||
    die "Installed DTB does not name BLDO1 as vcc-pg-iowifi."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/i2c@7081400/pmic@34/regulators/bldo1 \
    regulator-min-microvolt)" == "1800000" ]] ||
    die "Installed DTB does not keep BLDO1 at the required 1.8 V."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/i2c@7081400/pmic@34/regulators/bldo1 \
    regulator-max-microvolt)" == "1800000" ]] ||
    die "Installed DTB does not cap BLDO1 at the required 1.8 V."

fdtget -p \
    "$target_dtb" \
    /soc/i2c@7081400/pmic@34/regulators/bldo1 |
    grep -Fxq 'regulator-always-on' ||
    die "Installed DTB does not keep BLDO1 enabled."

wifi_interrupt_parent="$(
    fdtget -t x \
        "$target_dtb" \
        /soc/mmc@4021000/wifi@1 \
        interrupt-parent
)"

[[ "$wifi_interrupt_parent" == "$r_pio_phandle" ]] ||
    die "Installed DTB does not route AIC8800 host-wake through R_PIO."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/mmc@4021000/wifi@1 \
    interrupts)" == "1 0 8" ]] ||
    die "Installed DTB does not route AIC8800 host-wake from PM0 active-low."

[[ "$(fdtget -t s \
    "$target_dtb" \
    /soc/mmc@4021000/wifi@1 \
    interrupt-names)" == "host-wake" ]] ||
    die "Installed DTB does not name the AIC8800 host-wake interrupt."

[[ "$(fdtget -t u \
    "$target_dtb" \
    /soc/pinctrl@2000000/mmc1-pins \
    drive-strength)" == "30" ]] ||
    die "Installed DTB does not set mmc1 drive strength to 30 mA."

}

validate_build_tree() {
require_nonempty_file "$KERNEL_CONFIG"
require_nonempty_file "$SOC_DTSI"
require_nonempty_file "$BOARD_DTS"
require_nonempty_file "$GMAC1_DRIVER"
require_nonempty_file "$PCK600_DRIVER"
require_nonempty_file "$PCK600_BINDING"
require_nonempty_file "$R_CCU_RESET_BINDING"
require_nonempty_file "$R_CCU_DRIVER"
require_nonempty_file "$AXP20X_MFD_DRIVER"
require_nonempty_file "$SPI_DRIVER"
require_nonempty_file "$PINCTRL_DRIVER"
require_nonempty_file "$R_PINCTRL_DRIVER"
require_nonempty_file "$MMC_PWRSEQ_SIMPLE_DRIVER"
require_nonempty_file "$WENS_REGDB_CERT"

grep -Fxq 'CONFIG_STMMAC_ETH=y' "$KERNEL_CONFIG" ||
    die "CONFIG_STMMAC_ETH is not built in."

grep -Fxq 'CONFIG_STMMAC_PLATFORM=y' "$KERNEL_CONFIG" ||
    die "CONFIG_STMMAC_PLATFORM is not built in."

grep -Fxq 'CONFIG_DWMAC_SUN55I=y' "$KERNEL_CONFIG" ||
    die "CONFIG_DWMAC_SUN55I is not built in."

grep -Fxq 'CONFIG_SUN55I_PCK600=y' "$KERNEL_CONFIG" ||
    die "CONFIG_SUN55I_PCK600 is not built in."

grep -Fxq 'CONFIG_PM_GENERIC_DOMAINS=y' "$KERNEL_CONFIG" ||
    die "CONFIG_PM_GENERIC_DOMAINS is not enabled."

grep -Fxq 'CONFIG_PWRSEQ_SIMPLE=y' "$KERNEL_CONFIG" ||
    die "CONFIG_PWRSEQ_SIMPLE is not built in."

grep -Fxq 'CONFIG_SPI=y' "$KERNEL_CONFIG" ||
    die "CONFIG_SPI is not built in."

grep -Fxq 'CONFIG_SPI_MEM=y' "$KERNEL_CONFIG" ||
    die "CONFIG_SPI_MEM is not built in."

grep -Fxq 'CONFIG_SPI_SUN6I=y' "$KERNEL_CONFIG" ||
    die "CONFIG_SPI_SUN6I is not built in."

grep -Fxq 'CONFIG_MTD=y' "$KERNEL_CONFIG" ||
    die "CONFIG_MTD is not built in."

grep -Fxq 'CONFIG_MTD_BLOCK=y' "$KERNEL_CONFIG" ||
    die "CONFIG_MTD_BLOCK is not built in."

grep -Fxq 'CONFIG_MTD_SPI_NOR=y' "$KERNEL_CONFIG" ||
    die "CONFIG_MTD_SPI_NOR is not built in."

grep -qF \
    '{ .compatible = "allwinner,sun55i-a523-spi", .data = &sun50i_r329_spi_cfg },' \
    "$SPI_DRIVER" ||
    die "spi-sun6i.c lacks the A523 controller compatible."

grep -qF 'spi0: spi@4025000 {' "$SOC_DTSI" ||
    die "A523 SPI0 controller node is missing from sun55i-a523.dtsi."

grep -qF 'spi0_pc_pins: spi0-pc-pins {' "$SOC_DTSI" ||
    die "A523 SPI0 pinctrl node is missing from sun55i-a523.dtsi."

grep -qF '&spi0 {' "$BOARD_DTS" ||
    die "Cubie A5E SPI0 enablement is missing from the board DTS."

grep -qF 'compatible = "jedec,spi-nor";' "$BOARD_DTS" ||
    die "Cubie A5E SPI-NOR node is missing from the board DTS."

grep -qF 'spi-max-frequency = <20000000>;' "$BOARD_DTS" ||
    die "Cubie A5E source DTS does not use the field-validated 20 MHz SPI-NOR frequency."
if grep -qF 'spi-max-frequency = <50000000>;' "$BOARD_DTS"; then
    die "Cubie A5E source DTS still contains the rejected 50 MHz SPI-NOR frequency."
fi

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

grep -Fxq 'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y' "$KERNEL_CONFIG" ||
    die "CONFIG_CFG80211_REQUIRE_SIGNED_REGDB is not enabled."

grep -Fxq 'CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y' "$KERNEL_CONFIG" ||
    die "CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS is not enabled."

grep -Eq '^CONFIG_MMC_SUNXI=(y|m)$' "$KERNEL_CONFIG" ||
    die "CONFIG_MMC_SUNXI is not enabled."

grep -Eq '^CONFIG_CFG80211=(y|m)$' "$KERNEL_CONFIG" ||
    die "CONFIG_CFG80211 is not enabled."

grep -q 'ethernet1' "$BOARD_DTS" ||
    die "ethernet1 alias is missing from the Cubie A5E DTS."

grep -q 'gmac1' "$BOARD_DTS" ||
    die "GMAC1 enablement is missing from the Cubie A5E DTS."

grep -q 'allwinner,sun55i-a523-gmac200' "$SOC_DTSI" ||
    die "GMAC200 SoC node is missing from sun55i-a523.dtsi."

grep -q 'ethernet@4510000' "$SOC_DTSI" ||
    die "GMAC1 controller node is missing from sun55i-a523.dtsi."

grep -q 'pck600: power-controller@7060000' "$SOC_DTSI" ||
    die "PCK600 controller node is missing from sun55i-a523.dtsi."

grep -q 'power-domains = <&pck600 PD_VO1>;' "$SOC_DTSI" ||
    die "GMAC1 PCK600 PD_VO1 attachment is missing."

grep -qF 'allwinner,pinmux = <5>;' "$SOC_DTSI" ||
    die "A523 GMAC1 numeric pinmux encoding is missing from sun55i-a523.dtsi."

grep -qF 'function = "gmac1";' "$SOC_DTSI" ||
    die "A523 GMAC1 pinctrl function is missing from sun55i-a523.dtsi."

if grep -Eq \
    'allwinner,sunxi-rfkill|allwinner,sunxi-wlan|wlan_busnum|wlan_power' \
    "$BOARD_DTS"; then
    die "Source DTS still contains the obsolete vendor RFKill/rescan contract."
fi

grep -qF 'phy-supply = <&reg_cldo4>;' "$BOARD_DTS" ||
    die "GMAC1 CLDO4 PHY supply is missing from the source DTS."

grep -qF 'tx-internal-delay-ps = <300>;' "$BOARD_DTS" ||
    die "GMAC1 driver-compatible TX delay is missing."

grep -qF 'rx-internal-delay-ps = <400>;' "$BOARD_DTS" ||
    die "GMAC1 driver-compatible RX delay is missing."

grep -qF 'reset-gpios = <&pio 9 16 GPIO_ACTIVE_LOW>;' "$BOARD_DTS" ||
    die "GMAC1 PJ16 PHY reset is missing."

grep -qF 'reg_3v3_wifi: 3v3-wifi {' "$BOARD_DTS" ||
    die "PL7-controlled Wi-Fi 3.3 V regulator is missing."

grep -qF 'gpio = <&r_pio 0 7 GPIO_ACTIVE_HIGH>;' "$BOARD_DTS" ||
    die "Wi-Fi PL7 power GPIO is missing."

grep -qF 'wifi_pwrseq: wifi-pwrseq {' "$BOARD_DTS" ||
    die "Wi-Fi MMC power-sequence node is missing."

grep -qF 'reset-gpios = <&r_pio 1 1 GPIO_ACTIVE_LOW>;' "$BOARD_DTS" ||
    die "Wi-Fi PM1 active-low reset is missing."

grep -qF 'post-power-on-delay-ms = <200>;' "$BOARD_DTS" ||
    die "Wi-Fi 200 ms power-on delay is missing."

grep -qF 'vmmc-supply = <&reg_3v3_wifi>;' "$BOARD_DTS" ||
    die "mmc1 does not use the Wi-Fi 3.3 V regulator."

grep -qF 'vqmmc-supply = <&reg_bldo1>;' "$BOARD_DTS" ||
    die "mmc1 does not use BLDO1 for its 1.8 V I/O supply."

grep -qF 'mmc-pwrseq = <&wifi_pwrseq>;' "$BOARD_DTS" ||
    die "mmc1 is not connected to the Wi-Fi power sequence."

grep -qF 'max-frequency = <40000000>;' "$BOARD_DTS" ||
    die "mmc1 is not capped at the tested 40 MHz."

grep -qF 'interrupt-parent = <&r_pio>;' "$BOARD_DTS" ||
    die "AIC8800 host-wake interrupt parent is not R_PIO."

grep -qF 'interrupts = <1 0 IRQ_TYPE_LEVEL_LOW>;' "$BOARD_DTS" ||
    die "AIC8800 host-wake is not connected to PM0 active-low."

grep -qF 'interrupt-names = "host-wake";' "$BOARD_DTS" ||
    die "AIC8800 host-wake interrupt name is missing."

grep -qF '<GIC_SPI 67 IRQ_TYPE_LEVEL_HIGH>,' "$SOC_DTSI" ||
    die "A523 main pinctrl is missing the GPIO bank interrupt."

if grep -qF '.irq_read_needs_mux = true,' \
    "$PINCTRL_DRIVER" "$R_PINCTRL_DRIVER"; then
    die "A523 pinctrl drivers still enable invalid IRQ remuxing."
fi

python3 - "$BOARD_DTS" <<'PY'
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

if grep -qF 'vmmc-supply = <&reg_bldo1>;' "$BOARD_DTS"; then
    die "mmc1 incorrectly uses BLDO1 as its main 3.3 V supply."
fi

grep -q 'allwinner,sun55i-a523-pck-600' "$PCK600_DRIVER" ||
    die "PCK600 driver compatible is missing."

grep -q '"tx-internal-delay-ps"' "$GMAC1_DRIVER" ||
    die "GMAC200 driver does not read tx-internal-delay-ps."

grep -q '"rx-internal-delay-ps"' "$GMAC1_DRIVER" ||
    die "GMAC200 driver does not read rx-internal-delay-ps."

grep -Eq '^#define[[:space:]]+PD_VO1[[:space:]]+4([[:space:]]|$)' \
    "$PCK600_BINDING" ||
    die "PCK600 PD_VO1 binding is missing."

grep -Eq '^#define[[:space:]]+RST_BUS_R_PPU0[[:space:]]+15([[:space:]]|$)' \
    "$R_CCU_RESET_BINDING" ||
    die "PCK600 reset binding is missing."

grep -q '\[RST_BUS_R_PPU0\].*0x1ac.*BIT(16)' "$R_CCU_DRIVER" ||
    die "PCK600 reset is missing from the A523 R-CCU driver."

grep -qF \
    'MFD_CELL_BASIC("axp20x-regulator", NULL, NULL, 0, 1),' \
    "$AXP20X_MFD_DRIVER" ||
    die "AXP313 regulator cell lacks its conflict-free explicit device ID."

}

write_validation_report() {
{
printf 'Cubie A5E image validation report\n'
printf '=================================\n'
printf 'Status: PASS\n'
printf 'Kernel release: %s\n' "$KERNEL_RELEASE"
printf 'Target device: %s\n' "$TARGET_DEVICE"
printf 'Root partition: %s\n' "$ROOT_PART"
printf 'Boot partition: %s\n' "$BOOT_PART"
printf 'Extlinux path: %s\n' "$EXTLINUX_REL"
printf 'Managed update version: %s\n' "$UPDATE_VERSION"
printf 'Managed Cubie A5E entry default: yes\n'
printf 'Extlinux entry count: 1\n'
printf 'Installed kernel count: 1\n'
printf 'Linux 5.15 retained: no\n'
printf 'Signed update bundle validated: yes\n'
printf 'Trusted update public key installed: yes\n'
printf 'rsetup update gateway installed: yes\n'
printf 'rsetup and librtui packages installed: yes\n'
printf 'rsetup chroot source-chain smoke test: PASS\n'
printf 'rsetup NVMe migration entry installed: yes\n'
printf 'Guarded SD-to-NVMe installer validated: yes\n'
printf 'Raspberry Pi OS Lite compatible base utilities installed: yes\n'
printf 'Basic package manifest: %s\n' "$BASIC_PACKAGES_TARGET"
printf 'Automatic root filesystem expansion validated: yes\n'
printf 'Root filesystem expansion service: cubie-a5e-grow-rootfs.service\n'
printf 'Root filesystem expansion marker absent before first boot: yes\n'
printf 'Disposable target APT caches absent: yes\n'
printf 'Root filesystem size bytes: %s\n' "$ROOT_SIZE_BYTES"
printf 'Root filesystem used bytes: %s\n' "$ROOT_USED_BYTES"
printf 'Root filesystem available bytes: %s\n' "$ROOT_AVAILABLE_BYTES"
printf 'Root filesystem use: %s\n' "$ROOT_USE_PERCENT"
printf 'Minimum compact-image free-space headroom bytes: %s\n' \
    "$MINIMUM_ROOT_AVAILABLE_BYTES"
printf 'ping command installed: yes\n'
printf 'nano editor installed: yes\n'
printf 'Default interactive user: initbox\n'
printf 'initbox passwordless sudo: yes\n'
printf 'Automatic root login: disabled\n'
printf 'Console login mode: prompt\n'
printf 'initbox password policy: fixed-init\n'
printf 'initbox password expiry: disabled\n'
printf 'Initial initbox password change required: no\n'
printf 'Kernel update finalizer enabled: yes\n'
printf 'APT kernel replacement guard installed: yes\n'
printf 'GMAC0 expected name: eth0\n'
printf 'GMAC1 expected name: eth1\n'
printf 'AIC8800 expected name: wlan0\n'
printf 'wlan0 NetworkManager managed: yes\n'
printf 'wlan0 saved Wi-Fi connection count: 0\n'
printf 'wlan0 role: unconfigured-hotspot-ready\n'
printf 'AIC platform path: generic Linux SDIO\n'
printf 'RFKill/rescan compatibility module installed: no\n'
printf 'Obsolete Allwinner symbol imports: no\n'
printf 'AIC8800 BSP installed: yes\n'
printf 'AIC8800 FDRV installed: yes\n'
printf 'AIC8800 Bluetooth module excluded: yes\n'
printf 'AIC8800 firmware present: yes\n'
printf 'Obsolete AIC8800 module aliases absent: yes\n'
printf 'AXP313/AXP323 regulator device-ID conflict fixed: yes\n'
printf 'PCK600 PD_VO1 built and wired: yes\n'
printf 'GMAC1 pinmux function and numeric mux validated: yes\n'
printf 'GMAC1 internal delays validated: yes\n'
printf 'GMAC1 CLDO4 and PJ16 wiring validated: yes\n'
printf 'Wi-Fi PL7 3.3 V rail validated: yes\n'
printf 'Wi-Fi BLDO1 1.8 V I/O rail validated: yes\n'
printf 'Wi-Fi PM1 reset sequence validated: yes\n'
printf 'MMC pwrseq_simple reset-gpios backport validated: yes\n'
printf 'Wi-Fi PM0 host-wake interrupt validated: yes\n'
printf 'A523 pinctrl IRQ backports validated: yes\n'
printf 'Vendor RFKill/rescan DT node absent: yes\n'
printf 'Wi-Fi SDIO clock capped at tested 40 MHz: yes\n'
printf 'Duplicate Wi-Fi loader absent: yes\n'
printf 'Bash completion enabled: yes\n'
printf 'systemd-timesyncd enabled: yes\n'
printf 'Upstream-signed wireless regulatory database selected before initramfs: yes\n'
printf 'Initramfs upstream regulatory payload verification: PASS\n'
printf 'Wireless regulatory signing key built in: yes\n'
printf 'Inapplicable EFI automount masked: yes\n'
printf 'Timezone: Asia/Dubai\n'
printf 'Installed DTB validated: yes\n'
printf 'PCIe/PHY initramfs modules validated: yes\n'
printf 'A523 SPI0 and SPI-NOR DT wiring validated: yes\n'
printf 'SPI-NOR maximum frequency: %s Hz\n' "$EXPECTED_SPI_FREQUENCY"
printf 'mtd-utils installed: yes\n'
printf 'Radxa Cubie A5E U-Boot maintenance payload: %s\n' "$RADXA_UBOOT_VERSION"
printf 'Radxa rsetup SPI bootloader backend validated: yes\n'
printf 'Required root runtime mountpoints validated: yes\n'
printf 'systemd PID1 executable validated: yes\n'
printf 'NVMe rsync mountpoint preservation validated: yes\n'
printf 'NVMe on-board SPI preflight validated: yes\n'
printf 'SPI and MTD/SPI-NOR drivers built in: yes\n'
printf 'Read-only remount validation: yes\n'
printf '\nEvidence files:\n'
printf 'Extlinux: %s\n' "$VALIDATION_EXTLINUX"
printf 'Modules: %s\n' "$VALIDATION_MODULES"
printf 'Decompiled DTB: %s\n' "$VALIDATION_DTB"
} >"$VALIDATION_REPORT"
}

main() {
require_command awk
require_command bash
require_command basename
require_command blkid
require_command cmp
require_command df
require_command diff
require_command dpkg-query
require_command dtc
require_command fdtget
require_command find
require_command grep
require_command head
require_command lsblk
require_command mount
require_command mountpoint
require_command nm
require_command openssl
require_command python3
require_command readlink
require_command sed
require_command tr
require_command strings
require_command stat
require_command sync
require_command tar
require_command umount
require_command wc

[[ "$(id -u)" -eq 0 ]] ||
    die "Run this stage as root."

[[ -b "$TARGET_DEVICE" ]] ||
    die "Target device is not a block device: $TARGET_DEVICE"

require_nonempty_file "$KERNEL_RELEASE_FILE"
require_nonempty_file "$UPDATE_VERSION_FILE"
require_nonempty_file "$UPDATE_BUNDLE_FILE"

KERNEL_RELEASE="$(tr -d '[:space:]' <"$KERNEL_RELEASE_FILE")"
UPDATE_VERSION="$(tr -d '[:space:]' <"$UPDATE_VERSION_FILE")"

[[ -n "$KERNEL_RELEASE" ]] ||
    die "Kernel release file is empty."
[[ "$UPDATE_VERSION" =~ ^[A-Za-z0-9._+:-]+$ ]] ||
    die "Update version is invalid: $UPDATE_VERSION"

log "Stage 80 revision: storage-nvme-spi-hardening-v2-20260821"
log "Beginning clean read-only target validation."

load_target_layout
mount_read_only_filesystems

validate_root_identity
validate_root_runtime_layout
validate_kernel_payload
validate_module_tree
validate_module_policy
validate_single_wifi_loader
validate_firmware
validate_network_policy
validate_userland_runtime
validate_spi_maintenance_runtime
validate_rsetup_and_basic_packages
validate_root_autogrow_and_compact_image
validate_initbox_account_and_login_policy
validate_single_kernel_state
validate_update_manager
validate_extlinux
validate_compiled_dtb
validate_build_tree
write_validation_report

log "Validation passed after clean read-only remount."
log "U-Boot source: $BOOT_PART:$EXTLINUX_REL"
log "Root filesystem: $ROOT_PART"
log "Root filesystem capacity: size=$ROOT_SIZE_BYTES used=$ROOT_USED_BYTES available=$ROOT_AVAILABLE_BYTES use=$ROOT_USE_PERCENT"
log "Automatic first-boot root filesystem expansion validated."
log "Expected interfaces after Linux $KERNEL_RELEASE boots: eth0, eth1 and wlan0."
log "Validation report: $VALIDATION_REPORT"

}

main "$@"
