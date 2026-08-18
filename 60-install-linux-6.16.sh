#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh

source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="INSTALL"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${AIC_REPO:?AIC_REPO is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${TARGET_DEVICE:?TARGET_DEVICE is not set}"

readonly KERNEL_RELEASE_FILE="$BUILD_ROOT/.one-shot-kernel-release"
readonly TARGET_LAYOUT_FILE="$BUILD_ROOT/.one-shot-target-layout"
readonly LAYOUT_CANDIDATES_FILE="$BUILD_ROOT/.one-shot-layout-candidates"

readonly AIC_MODULE_LIST="$BUILD_ROOT/.one-shot-aic-modules"
readonly UPDATE_VERSION_FILE="$BUILD_ROOT/.one-shot-update-version"
readonly UPDATE_BUNDLE_FILE="$BUILD_ROOT/.one-shot-update-bundle"
readonly UPDATE_PUBLIC_KEY_FILE="$BUILD_ROOT/.one-shot-update-public-key"

readonly IMAGE_SRC="$KERNEL_DIR/arch/arm64/boot/Image"
readonly CONFIG_SRC="$KERNEL_DIR/.config"
readonly DTB_SRC="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"
readonly UPDATE_PROGRAM_SRC="$SCRIPT_DIR/assets/cubie-a5e-update"
readonly RSETUP_WRAPPER_SRC="$SCRIPT_DIR/assets/rsetup"
readonly UPDATE_SERVICE_SRC="$SCRIPT_DIR/assets/cubie-a5e-update-finalize.service"
readonly KERNEL_APT_GUARD_SRC="$SCRIPT_DIR/assets/99-cubie-a5e-managed-kernel"
readonly BASIC_PACKAGES_SRC="$SCRIPT_DIR/assets/raspios-lite-compatible-packages.txt"
readonly BASIC_PACKAGES_TARGET="/usr/share/cubie-a5e/raspios-lite-compatible-packages.txt"
readonly RADXA_REPO_HELPER_SRC="$SCRIPT_DIR/assets/ensure-radxa-trixie-repo"
readonly RADXA_REPO_HELPER_TARGET="/usr/local/sbin/cubie-a5e-ensure-radxa-repo"
readonly INITBOX_USER="initbox"
readonly INITBOX_PASSWORD="init"
readonly INITBOX_SUDOERS="/etc/sudoers.d/90-initbox"
readonly INITBOX_ACCOUNT_STATUS="/var/lib/cubie-a5e/initbox-account.status"
readonly GETTY_TTY1_DROPIN="/etc/systemd/system/getty@tty1.service.d/99-initbox-login.conf"
readonly SERIAL_GETTY_DROPIN="/etc/systemd/system/serial-getty@ttyS0.service.d/99-initbox-login.conf"
readonly ROOT_GROW_PROGRAM="/usr/local/sbin/cubie-a5e-grow-rootfs"
readonly ROOT_GROW_UNIT="/usr/lib/systemd/system/cubie-a5e-grow-rootfs.service"
readonly ROOT_GROW_WANTS="/etc/systemd/system/multi-user.target.wants/cubie-a5e-grow-rootfs.service"
readonly ROOT_GROW_MARKER="/var/lib/cubie-a5e/rootfs-expanded"

readonly ROOT_MNT="${ROOT_MNT:-$BUILD_ROOT/mnt/one-shot-root}"
readonly DEFAULT_BOOT_MNT="${BOOT_MNT:-$BUILD_ROOT/mnt/one-shot-boot}"
readonly INITBOX_PASSWORD_FILE="$ROOT_MNT/tmp/.cubie-a5e-initbox-password"

readonly RESOLVER_BACKUP="$BUILD_ROOT/.one-shot-resolv.conf.backup"
readonly RESOLVER_LINK_FILE="$BUILD_ROOT/.one-shot-resolv.conf.link"

readonly RUNTIME_CACHE_SCHEMA="stage60-runtime-rootfs-v1"
readonly RUNTIME_CACHE_MAX_AGE_SECONDS="${RUNTIME_CACHE_MAX_AGE_SECONDS:-86400}"
readonly RUNTIME_CACHE_REBUILD="${RUNTIME_CACHE_REBUILD:-0}"
readonly RUNTIME_CACHE_DIR="$BUILD_ROOT/cache/stage60-runtime-rootfs"
readonly RUNTIME_CACHE_ROOTFS="$RUNTIME_CACHE_DIR/rootfs"
readonly RUNTIME_CACHE_STATE="$RUNTIME_CACHE_DIR/state.env"

if [[ -n "${LOG_DIR:-}" ]]; then
mkdir -p -- "$LOG_DIR"
readonly INSTALL_REPORT="$LOG_DIR/linux-6.16-install-report.txt"
readonly INSTALLED_MODULE_REPORT="$LOG_DIR/installed-modules.txt"
readonly EXTLINUX_REPORT="$LOG_DIR/extlinux-after-install.conf"
else
readonly INSTALL_REPORT="$BUILD_ROOT/.one-shot-linux-install-report.txt"
readonly INSTALLED_MODULE_REPORT="$BUILD_ROOT/.one-shot-installed-modules.txt"
readonly EXTLINUX_REPORT="$BUILD_ROOT/.one-shot-extlinux-after-install.conf"
fi

ROOT_PART=""
BOOT_PART=""
EXTLINUX_REL=""
BOOT_MNT="$DEFAULT_BOOT_MNT"
KERNEL_RELEASE=""
UPDATE_VERSION=""
UPDATE_PUBLIC_KEY=""
SAME_FS=0
RESOLVER_PREPARED=0
QEMU_INSTALLED_BY_STAGE=0
QEMU_TARGET_PATH="$ROOT_MNT/usr/bin/qemu-aarch64-static"
RUNTIME_CACHE_FINGERPRINT=""
RUNTIME_CACHE_STATUS="miss"
RUNTIME_CACHE_TEMP=""

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

validate_module_release() {
local module_path="$1"
local vermagic

vermagic="$(module_vermagic "$module_path")"

[[ -n "$vermagic" ]] ||
    die "Could not read module vermagic: $module_path"

case "$vermagic" in
    "$KERNEL_RELEASE"*)
        ;;
    *)
        die "Module release mismatch: module=$module_path vermagic=$vermagic expected=$KERNEL_RELEASE"
        ;;
esac

}

mount_partition() {
local partition="$1"
local mount_dir="$2"
local mounted_source

mkdir -p -- "$mount_dir"

if mountpoint -q "$mount_dir"; then
    mounted_source="$(findmnt -nro SOURCE --target "$mount_dir")"

    [[ "$(readlink -f -- "$mounted_source")" == "$(readlink -f -- "$partition")" ]] ||
        die "$mount_dir is mounted from $mounted_source; expected $partition"

    return 0
fi

log "Mounting $partition at $mount_dir"
mount "$partition" "$mount_dir"

}

restore_chroot_resolver() {
local target_resolver="$ROOT_MNT/etc/resolv.conf"
local link_target

((RESOLVER_PREPARED == 1)) || return 0

rm -f -- "$target_resolver"

if [[ -s "$RESOLVER_LINK_FILE" ]]; then
    link_target="$(<"$RESOLVER_LINK_FILE")"
    ln -s -- "$link_target" "$target_resolver"
elif [[ -f "$RESOLVER_BACKUP" ]]; then
    cp -a -- "$RESOLVER_BACKUP" "$target_resolver"
fi

rm -f -- "$RESOLVER_BACKUP" "$RESOLVER_LINK_FILE"
RESOLVER_PREPARED=0

}

cleanup() {
local path

set +e

rm -f -- "$INITBOX_PASSWORD_FILE"

if [[ -n "$RUNTIME_CACHE_TEMP" &&
      "$RUNTIME_CACHE_TEMP" == "$BUILD_ROOT/cache/.stage60-runtime-rootfs."* ]]; then
    rm -rf -- "$RUNTIME_CACHE_TEMP"
fi

restore_chroot_resolver

if ((QEMU_INSTALLED_BY_STAGE == 1)); then
    rm -f -- "$QEMU_TARGET_PATH"
fi

for path in \
    "$ROOT_MNT/sys" \
    "$ROOT_MNT/proc" \
    "$ROOT_MNT/dev/pts" \
    "$ROOT_MNT/dev"; do
    if mountpoint -q "$path"; then
        umount "$path"
    fi
done

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
    die "Recorded extlinux relative path is empty."

}

mount_target_filesystems() {
mount_partition "$ROOT_PART" "$ROOT_MNT"

if [[ "$(readlink -f -- "$ROOT_PART")" == "$(readlink -f -- "$BOOT_PART")" ]]; then
    SAME_FS=1
    BOOT_MNT="$ROOT_MNT"
else
    SAME_FS=0
    BOOT_MNT="$DEFAULT_BOOT_MNT"
    mount_partition "$BOOT_PART" "$BOOT_MNT"
fi

}

validate_input_manifests() {
local module
local module_count=0

require_nonempty_file "$AIC_MODULE_LIST"
require_nonempty_file "$BASIC_PACKAGES_SRC"
require_nonempty_file "$RADXA_REPO_HELPER_SRC"

[[ -x "$RADXA_REPO_HELPER_SRC" ]] ||
    die "Radxa repository helper is not executable."

if grep -Ev '^[[:space:]]*(#.*)?$|^[a-z0-9][a-z0-9+.-]*$' \
    "$BASIC_PACKAGES_SRC" |
    grep -q .; then
    die "Raspberry Pi OS Lite compatible package manifest is invalid."
fi

while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    require_nonempty_file "$module"
    validate_module_release "$module"
    module_count=$((module_count + 1))
done <"$AIC_MODULE_LIST"

((module_count == 2)) ||
    die "AIC module manifest must contain exactly two Wi-Fi modules."

grep -q '/aic8800_bsp\.ko$' "$AIC_MODULE_LIST" ||
    die "AIC manifest does not contain aic8800_bsp.ko"

grep -q '/aic8800_fdrv\.ko$' "$AIC_MODULE_LIST" ||
    die "AIC manifest does not contain aic8800_fdrv.ko"

if grep -q '/aic8800_btlpm\.ko$' "$AIC_MODULE_LIST"; then
    die "Bluetooth module must not be installed by the Linux 6.16 Wi-Fi stage."
fi

}

remove_existing_kernel_payloads() {
local candidate

log "Removing all donor and stale kernel payloads before installing $KERNEL_RELEASE."

if [[ -d "$ROOT_MNT/lib/modules" ]]; then
    find "$ROOT_MNT/lib/modules" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -exec rm -rf -- {} +
fi

if [[ -d "$ROOT_MNT/usr/lib" ]]; then
    find "$ROOT_MNT/usr/lib" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'linux-image-*' \
        -exec rm -rf -- {} +
fi

for candidate in \
    "$ROOT_MNT"/boot/vmlinuz-* \
    "$ROOT_MNT"/boot/initrd.img-* \
    "$ROOT_MNT"/boot/config-* \
    "$ROOT_MNT"/boot/System.map-*; do
    [[ -e "$candidate" ]] || continue
    rm -f -- "$candidate"
done

find "$ROOT_MNT/boot" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    \( -name dtb -o -name 'dtb-*' \) \
    -exec rm -rf -- {} +

if ((SAME_FS == 0)); then
    for candidate in \
        "$BOOT_MNT"/vmlinuz-* \
        "$BOOT_MNT"/initrd.img-*; do
        [[ -e "$candidate" ]] || continue
        rm -f -- "$candidate"
    done

    rm -rf -- "$BOOT_MNT/dtb"

    find "$BOOT_MNT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'dtb-*' \
        -exec rm -rf -- {} +
fi
}

install_kernel_modules() {
log "Installing in-tree modules for $KERNEL_RELEASE."

run make -C "$KERNEL_DIR" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$ROOT_MNT" \
    modules_install

need_dir "$ROOT_MNT/lib/modules/$KERNEL_RELEASE"

}

install_external_modules() {
local module
local destination="$ROOT_MNT/lib/modules/$KERNEL_RELEASE/updates/aic8800"

install -d -m 0755 -- "$destination"

while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    install -m 0644 -- "$module" "$destination/"
done <"$AIC_MODULE_LIST"

rm -f -- \
    "$destination/sunxi_rfkill_compat.ko" \
    "$destination/aic8800_btlpm.ko"

require_nonempty_file "$destination/aic8800_bsp.ko"
require_nonempty_file "$destination/aic8800_fdrv.ko"

}

install_kernel_image_and_dtb() {
install -D -m 0644 \
    "$IMAGE_SRC" \
    "$ROOT_MNT/boot/vmlinuz-$KERNEL_RELEASE"

install -D -m 0644 \
    "$CONFIG_SRC" \
    "$ROOT_MNT/boot/config-$KERNEL_RELEASE"

install -D -m 0644 \
    "$DTB_SRC" \
    "$ROOT_MNT/usr/lib/linux-image-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"

}

remove_duplicate_wifi_loader() {
local unit

for unit in \
    initbox-radxa-wifi-modprobe.service \
    radxa-wifi-modprobe.service \
    aic8800-modprobe.service; do
    rm -f -- \
        "$ROOT_MNT/etc/systemd/system/$unit" \
        "$ROOT_MNT/lib/systemd/system/$unit" \
        "$ROOT_MNT/usr/lib/systemd/system/$unit"

    find "$ROOT_MNT/etc/systemd/system" \
        -type l \
        -name "$unit" \
        -delete 2>/dev/null || true
done

rm -f -- \
    "$ROOT_MNT/usr/local/sbin/initbox-radxa-wifi-modprobe" \
    "$ROOT_MNT/usr/local/bin/initbox-radxa-wifi-modprobe" \
    "$ROOT_MNT/usr/local/sbin/radxa-wifi-modprobe" \
    "$ROOT_MNT/usr/local/bin/radxa-wifi-modprobe"
}

remove_obsolete_aic_module_aliases() {
local candidate
local candidate_dir
local candidate_tmp
local legacy_pattern
local -a search_paths=()

legacy_pattern='^[[:space:]]*(aicwf_sdio|aic8800_sdio|aic8800_bsp_sdio|aic8800_btlpm_sdio|aic8800_fdrv_sdio)([[:space:]]*(#.*)?)?$'

[[ -f "$ROOT_MNT/etc/modules" ]] &&
    search_paths+=("$ROOT_MNT/etc/modules")

for candidate_dir in \
    "$ROOT_MNT/etc/modules-load.d" \
    "$ROOT_MNT/usr/local/lib/modules-load.d" \
    "$ROOT_MNT/usr/lib/modules-load.d"; do
    [[ -d "$candidate_dir" ]] || continue

    while IFS= read -r -d '' candidate; do
        search_paths+=("$candidate")
    done < <(
        find "$candidate_dir" \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print0
    )
done

for candidate in "${search_paths[@]}"; do
    grep -Eq "$legacy_pattern" "$candidate" || continue

    candidate_tmp="$(mktemp "$(dirname -- "$candidate")/.aic-module-clean.XXXXXX")"
    grep -Ev "$legacy_pattern" "$candidate" >"$candidate_tmp" || true
    chmod --reference="$candidate" "$candidate_tmp"
    chown --reference="$candidate" "$candidate_tmp"
    mv -f -- "$candidate_tmp" "$candidate"
done
}

install_module_policy() {
local modules_load_file="$ROOT_MNT/etc/modules-load.d/cubie-a5e-aic8800.conf"
local modprobe_file="$ROOT_MNT/etc/modprobe.d/cubie-a5e-aic8800.conf"
local modules_load_tmp
local modprobe_tmp

install -d -m 0755 -- "$ROOT_MNT/etc/modules-load.d"
install -d -m 0755 -- "$ROOT_MNT/etc/modprobe.d"

modules_load_tmp="$(mktemp "$ROOT_MNT/etc/modules-load.d/.cubie-a5e-aic8800.conf.XXXXXX")"
modprobe_tmp="$(mktemp "$ROOT_MNT/etc/modprobe.d/.cubie-a5e-aic8800.conf.XXXXXX")"

printf '%s\n' aic8800_bsp aic8800_fdrv >"$modules_load_tmp"
printf '%s\n' \
    'softdep aic8800_fdrv pre: aic8800_bsp' \
    'options aic8800_bsp aic_fw_path=/lib/firmware/aic8800_fw/SDIO/aic8800D80' \
    'options aic8800_fdrv aicwf_dbg_level=0 custregd=0 ps_on=0' \
    >"$modprobe_tmp"

chmod 0644 "$modules_load_tmp" "$modprobe_tmp"

diff -u <(printf '%s\n' aic8800_bsp aic8800_fdrv) "$modules_load_tmp" ||
    die "Generated AIC8800 module load policy is incorrect."

diff -u \
    <(printf '%s\n' \
        'softdep aic8800_fdrv pre: aic8800_bsp' \
        'options aic8800_bsp aic_fw_path=/lib/firmware/aic8800_fw/SDIO/aic8800D80' \
        'options aic8800_fdrv aicwf_dbg_level=0 custregd=0 ps_on=0') \
    "$modprobe_tmp" ||
    die "Generated AIC8800 module policy is incorrect."

mv -f -- "$modules_load_tmp" "$modules_load_file"
mv -f -- "$modprobe_tmp" "$modprobe_file"
}

install_firmware() {
local firmware_name
local firmware_source="$AIC_REPO/src/SDIO/driver_fw/fw/aic8800D80"
local firmware_target="$ROOT_MNT/lib/firmware/aic8800_fw/SDIO/aic8800D80"

need_dir "$firmware_source"

for firmware_name in \
    fw_patch_table_8800d80_u02.bin \
    fw_adid_8800d80_u02.bin \
    fw_patch_8800d80_u02.bin \
    fmacfw_8800d80_u02.bin; do
    require_nonempty_file "$firmware_source/$firmware_name"
done

log "Installing AIC8800D80 firmware at the path compiled into the BSP."

rm -rf -- "$firmware_target"
install -d -m 0755 -- "$firmware_target"
rsync -a "$firmware_source/" "$firmware_target/"

for firmware_name in \
    fw_patch_table_8800d80_u02.bin \
    fw_adid_8800d80_u02.bin \
    fw_patch_8800d80_u02.bin \
    fmacfw_8800d80_u02.bin; do
    require_nonempty_file "$firmware_target/$firmware_name"
    cmp -s \
        "$firmware_source/$firmware_name" \
        "$firmware_target/$firmware_name" ||
        die "Installed AIC8800D80 firmware differs from the driver source: $firmware_name"
done

}

generate_module_metadata() {
log "Generating module dependency metadata for $KERNEL_RELEASE."

depmod -b "$ROOT_MNT" "$KERNEL_RELEASE"

require_nonempty_file "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/modules.dep"
require_nonempty_file "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/modules.alias"
require_nonempty_file "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/modules.softdep"

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
}

validate_installed_modules() {
local module_dir="$ROOT_MNT/lib/modules/$KERNEL_RELEASE/updates/aic8800"
local module
local module_name
local vermagic

: >"$INSTALLED_MODULE_REPORT"

for module_name in \
    aic8800_bsp.ko \
    aic8800_fdrv.ko; do
    module="$module_dir/$module_name"
    require_nonempty_file "$module"

    vermagic="$(module_vermagic "$module")"

    case "$vermagic" in
        "$KERNEL_RELEASE"*)
            ;;
        *)
            die "Installed module vermagic mismatch: $module_name=$vermagic"
            ;;
    esac

    printf '%s\t%s\n' "$module" "$vermagic" >> \
        "$INSTALLED_MODULE_REPORT"
done

[[ ! -e "$module_dir/aic8800_btlpm.ko" ]] ||
    die "Unsupported Bluetooth module was installed."

[[ ! -e "$module_dir/sunxi_rfkill_compat.ko" ]] ||
    die "Obsolete Sunxi RFKill compatibility module was installed."

if grep -q 'updates/aic8800/sunxi_rfkill_compat\.ko:' \
    "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/modules.dep"; then
    die "modules.dep still contains the obsolete Sunxi RFKill compatibility module."
fi

grep -q 'updates/aic8800/aic8800_bsp\.ko:' \
    "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/modules.dep" ||
    die "modules.dep does not contain aic8800_bsp.ko"

grep -q 'updates/aic8800/aic8800_fdrv\.ko:' \
    "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/modules.dep" ||
    die "modules.dep does not contain aic8800_fdrv.ko"

diff -u \
    <(
        printf '%s\n' \
            aic8800_bsp \
            aic8800_fdrv
    ) \
    "$ROOT_MNT/etc/modules-load.d/cubie-a5e-aic8800.conf" ||
    die "AIC8800 module load order is incorrect."

diff -u \
    <(
        printf '%s\n' \
            'softdep aic8800_fdrv pre: aic8800_bsp' \
            'options aic8800_bsp aic_fw_path=/lib/firmware/aic8800_fw/SDIO/aic8800D80' \
            'options aic8800_fdrv aicwf_dbg_level=0 custregd=0 ps_on=0'
    ) \
    "$ROOT_MNT/etc/modprobe.d/cubie-a5e-aic8800.conf" ||
    die "AIC8800 module policy is incorrect."

}

validate_runtime_cache_settings() {
[[ "$RUNTIME_CACHE_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] ||
    die "RUNTIME_CACHE_MAX_AGE_SECONDS must be a non-negative integer."

case "$RUNTIME_CACHE_REBUILD" in
    0 | 1)
        ;;
    *)
        die "RUNTIME_CACHE_REBUILD must be 0 or 1."
        ;;
esac

[[ "$RUNTIME_CACHE_DIR" == "$BUILD_ROOT/cache/stage60-runtime-rootfs" ]] ||
    die "Unexpected Stage 60 runtime cache path: $RUNTIME_CACHE_DIR"

[[ ! -L "$BUILD_ROOT/cache" ]] ||
    die "BUILD_ROOT/cache must not be a symbolic link: $BUILD_ROOT/cache"
[[ ! -L "$RUNTIME_CACHE_DIR" ]] ||
    die "Stage 60 runtime cache must not be a symbolic link: $RUNTIME_CACHE_DIR"
[[ ! -L "$RUNTIME_CACHE_ROOTFS" ]] ||
    die "Stage 60 runtime cache rootfs must not be a symbolic link: $RUNTIME_CACHE_ROOTFS"
[[ ! -L "$RUNTIME_CACHE_STATE" ]] ||
    die "Stage 60 runtime cache state must not be a symbolic link: $RUNTIME_CACHE_STATE"
}

print_runtime_cache_file_digest() {
local label="$1"
local path="$2"
local digest

if [[ -L "$path" ]]; then
    printf '%s\tsymlink\t%s\n' "$label" "$(readlink -- "$path")"
elif [[ -f "$path" ]]; then
    digest="$(sha256sum "$path" | awk '{print $1}')"
    printf '%s\tfile\t%s\n' "$label" "$digest"
elif [[ -d "$path" ]]; then
    printf '%s\tdirectory\n' "$label"
else
    printf '%s\tmissing\n' "$label"
fi
}

runtime_cache_input_fingerprint() {
local path
local relative_path

{
    printf 'schema\t%s\n' "$RUNTIME_CACHE_SCHEMA"
    print_runtime_cache_file_digest \
        stage-script \
        "${BASH_SOURCE[0]}"
    print_runtime_cache_file_digest \
        basic-packages \
        "$BASIC_PACKAGES_SRC"
    print_runtime_cache_file_digest \
        radxa-repository-helper \
        "$RADXA_REPO_HELPER_SRC"
    print_runtime_cache_file_digest \
        kernel-apt-guard \
        "$KERNEL_APT_GUARD_SRC"
    print_runtime_cache_file_digest \
        target-os-release \
        "$ROOT_MNT/etc/os-release"
    print_runtime_cache_file_digest \
        target-rootfs-release \
        "$ROOT_MNT/etc/cubie-a5e-rootfs-release"
    print_runtime_cache_file_digest \
        target-dpkg-status \
        "$ROOT_MNT/var/lib/dpkg/status"

    while IFS= read -r -d '' path; do
        relative_path="${path#"$ROOT_MNT"}"
        print_runtime_cache_file_digest \
            "target$relative_path" \
            "$path"
    done < <(
        find "$ROOT_MNT/etc/apt" \
            -xdev \
            \( -type f -o -type l \) \
            -print0 2>/dev/null |
            sort -z
    )

    for path in \
        "$ROOT_MNT/usr/bin/rsetup" \
        "$ROOT_MNT/usr/lib/rsetup" \
        "$ROOT_MNT/usr/lib/librtui"; do
        [[ -e "$path" || -L "$path" ]] || continue

        if [[ -d "$path" && ! -L "$path" ]]; then
            while IFS= read -r -d '' path; do
                relative_path="${path#"$ROOT_MNT"}"
                print_runtime_cache_file_digest \
                    "target$relative_path" \
                    "$path"
            done < <(
                find "$path" \
                    -xdev \
                    \( -type f -o -type l \) \
                    -print0 |
                    sort -z
            )
        else
            relative_path="${path#"$ROOT_MNT"}"
            print_runtime_cache_file_digest \
                "target$relative_path" \
                "$path"
        fi
    done
} | sha256sum | awk '{print $1}'
}

runtime_cache_tree_is_valid() {
local cache_root="$1"
local candidate

[[ -d "$cache_root" ]] || return 1
[[ -x "$cache_root/bin/bash" ]] || return 1
[[ -s "$cache_root/var/lib/dpkg/status" ]] || return 1
[[ -x "$cache_root/usr/bin/rsetup" ]] || return 1
[[ -d "$cache_root/usr/lib/rsetup" ]] || return 1
[[ -d "$cache_root/usr/lib/librtui" ]] || return 1
[[ -s "$cache_root/usr/share/bash-completion/bash_completion" ]] || return 1
[[ -x "$cache_root/usr/sbin/update-initramfs" ]] || return 1
[[ -x "$cache_root/usr/bin/unmkinitramfs" ]] || return 1
[[ -s "$cache_root/usr/lib/firmware/regulatory.db-upstream" ]] || return 1
[[ -s "$cache_root/usr/lib/firmware/regulatory.db.p7s-upstream" ]] || return 1
[[ -s "$cache_root/etc/apt/preferences.d/99-cubie-a5e-managed-kernel" ]] || return 1
[[ ! -e "$cache_root/usr/bin/qemu-aarch64-static" ]] || return 1

if [[ -d "$cache_root/lib/modules" ]] &&
   find "$cache_root/lib/modules" \
       -mindepth 1 \
       -maxdepth 1 \
       -type d \
       -print -quit |
       grep -q .; then
    return 1
fi

for candidate in \
    "$cache_root"/boot/vmlinuz-* \
    "$cache_root"/boot/initrd.img-* \
    "$cache_root"/boot/config-* \
    "$cache_root"/boot/System.map-*; do
    [[ ! -e "$candidate" ]] || return 1
done

return 0
}

runtime_cache_is_valid() {
local created_epoch
local current_epoch
local cache_age

[[ "$RUNTIME_CACHE_REBUILD" == "0" ]] || return 1
[[ -s "$RUNTIME_CACHE_STATE" ]] || return 1
runtime_cache_tree_is_valid "$RUNTIME_CACHE_ROOTFS" || return 1

grep -Fxq "CACHE_SCHEMA=$RUNTIME_CACHE_SCHEMA" \
    "$RUNTIME_CACHE_STATE" || return 1
grep -Fxq "INPUT_FINGERPRINT=$RUNTIME_CACHE_FINGERPRINT" \
    "$RUNTIME_CACHE_STATE" || return 1

created_epoch="$(
    sed -n 's/^CREATED_EPOCH=//p' "$RUNTIME_CACHE_STATE" |
        head -n 1
)"
[[ "$created_epoch" =~ ^[0-9]+$ ]] || return 1

if ((RUNTIME_CACHE_MAX_AGE_SECONDS > 0)); then
    current_epoch="$(date -u +%s)"
    ((current_epoch >= created_epoch)) || return 1
    cache_age=$((current_epoch - created_epoch))
    ((cache_age <= RUNTIME_CACHE_MAX_AGE_SECONDS)) || return 1
fi

return 0
}

restore_runtime_cache() {
runtime_cache_is_valid || return 1

log "Stage 60 runtime rootfs cache hit: $RUNTIME_CACHE_FINGERPRINT"
log "Restoring the prepared ARM64 runtime without repeating the QEMU APT transaction."

rsync \
    -aHAXx \
    --numeric-ids \
    --delete \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/run/*' \
    --exclude='/sys/*' \
    --exclude='/usr/bin/qemu-aarch64-static' \
    "$RUNTIME_CACHE_ROOTFS/" \
    "$ROOT_MNT/"

rm -f -- "$QEMU_TARGET_PATH"
runtime_cache_tree_is_valid "$ROOT_MNT" ||
    die "The restored Stage 60 runtime rootfs cache failed validation."

RUNTIME_CACHE_STATUS="hit"
return 0
}

publish_runtime_cache() {
local created_epoch

mkdir -p -- "$BUILD_ROOT/cache"
RUNTIME_CACHE_TEMP="$(
    mktemp -d "$BUILD_ROOT/cache/.stage60-runtime-rootfs.XXXXXX"
)"

install -d -m 0755 -- "$RUNTIME_CACHE_TEMP/rootfs"

log "Publishing the prepared ARM64 runtime rootfs cache."
rsync \
    -aHAXx \
    --numeric-ids \
    --delete \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/run/*' \
    --exclude='/sys/*' \
    --exclude='/usr/bin/qemu-aarch64-static' \
    "$ROOT_MNT/" \
    "$RUNTIME_CACHE_TEMP/rootfs/"

runtime_cache_tree_is_valid "$RUNTIME_CACHE_TEMP/rootfs" ||
    die "The new Stage 60 runtime rootfs cache failed validation."

created_epoch="$(date -u +%s)"
{
    printf 'CACHE_SCHEMA=%s\n' "$RUNTIME_CACHE_SCHEMA"
    printf 'INPUT_FINGERPRINT=%s\n' "$RUNTIME_CACHE_FINGERPRINT"
    printf 'CREATED_EPOCH=%s\n' "$created_epoch"
    printf 'CREATED_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$RUNTIME_CACHE_TEMP/state.env"
chmod 0644 "$RUNTIME_CACHE_TEMP/state.env"

rm -rf -- "$RUNTIME_CACHE_DIR"
mv -- "$RUNTIME_CACHE_TEMP" "$RUNTIME_CACHE_DIR"
RUNTIME_CACHE_TEMP=""
RUNTIME_CACHE_STATUS="miss-published"

log "Stage 60 runtime rootfs cache published: $RUNTIME_CACHE_FINGERPRINT"
}

validate_target_runtime_package_state() {
# The backslashes keep Bash from consuming dpkg-query's field placeholders.
# shellcheck disable=SC2016
run_arm64_chroot '
    mapfile -t basic_packages < <(
        sed -E \
            -e "/^[[:space:]]*(#|$)/d" \
            -e "s/[[:space:]]+$//" \
            /usr/share/cubie-a5e/raspios-lite-compatible-packages.txt
    )

    required_packages=(
        "${basic_packages[@]}"
        cloud-guest-utils
        device-tree-compiler
        e2fsprogs
        gdisk
        initramfs-tools
        iw
        jq
        kmod
        librtui
        network-manager
        openssl
        pkexec
        python3
        python3-yaml
        rfkill
        rsetup
        tar
        tzdata
        u-boot-menu
        wget
        whiptail
        wireless-regdb
        wpasupplicant
    )

    declare -A checked_packages=()

    for package in "${required_packages[@]}"; do
        [[ -z "${checked_packages[$package]+x}" ]] || continue
        checked_packages[$package]=1

        status="$(
            dpkg-query -W \
                -f="\${db:Status-Abbrev}" \
                "$package" 2>/dev/null
        )" || {
            printf "Required runtime package is not registered: %s\n" \
                "$package" >&2
            exit 1
        }

        [[ "$status" == "ii " ]] || {
            printf "Required runtime package is not fully installed: %s status=<%s>\n" \
                "$package" \
                "$status" >&2
            exit 1
        }
    done

    while IFS=$'\t' read -r package status; do
        [[ "$status" == "ii " ]] || continue

        case "$package" in
            linux-image-* | linux-dtb-*)
                printf "Packaged kernel remains in the prepared runtime cache: %s\n" \
                    "$package" >&2
                exit 1
                ;;
        esac
    done < <(
        dpkg-query -W \
            -f="\${binary:Package}\t\${db:Status-Abbrev}\n" \
            2>/dev/null
    )

    test -x /usr/sbin/update-initramfs
    test -x /usr/bin/unmkinitramfs
    test -x /usr/bin/rsetup
    test -d /usr/lib/rsetup
    test -d /usr/lib/librtui
    test -s /usr/share/bash-completion/bash_completion
    test -s /usr/lib/firmware/regulatory.db-upstream
    test -s /usr/lib/firmware/regulatory.db.p7s-upstream
'
}

prepare_cached_target_runtime() {
RUNTIME_CACHE_FINGERPRINT="$(runtime_cache_input_fingerprint)"
[[ "$RUNTIME_CACHE_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] ||
    die "Could not calculate the Stage 60 runtime cache fingerprint."

if [[ "$RUNTIME_CACHE_REBUILD" == "1" ]]; then
    log "Stage 60 runtime rootfs cache rebuild was explicitly requested."
elif [[ -e "$RUNTIME_CACHE_DIR" ]] && ! runtime_cache_is_valid; then
    log "Stage 60 runtime rootfs cache miss: input, age or validation changed."
fi

if restore_runtime_cache; then
    mount_chroot_filesystems
    install_qemu_for_chroot
    install_kernel_apt_guard
    validate_target_runtime_package_state
    return 0
fi

log "Stage 60 runtime rootfs cache miss: $RUNTIME_CACHE_FINGERPRINT"

mount_chroot_filesystems
install_qemu_for_chroot
install_kernel_apt_guard
purge_packaged_kernels
remove_existing_kernel_payloads
ensure_target_runtime_packages
ensure_initramfs_tools
validate_target_runtime_package_state
clean_target_apt_cache
publish_runtime_cache
}

mount_chroot_filesystems() {
local pseudo

for pseudo in dev dev/pts proc sys; do
    install -d -m 0755 -- "$ROOT_MNT/$pseudo"
done

mountpoint -q "$ROOT_MNT/dev" ||
    mount --bind /dev "$ROOT_MNT/dev"

mountpoint -q "$ROOT_MNT/dev/pts" ||
    mount --bind /dev/pts "$ROOT_MNT/dev/pts"

mountpoint -q "$ROOT_MNT/proc" ||
    mount -t proc proc "$ROOT_MNT/proc"

mountpoint -q "$ROOT_MNT/sys" ||
    mount -t sysfs sysfs "$ROOT_MNT/sys"

}

install_qemu_for_chroot() {
local qemu_path

qemu_path="$(command -v qemu-aarch64-static || true)"

[[ -n "$qemu_path" ]] ||
    die "qemu-aarch64-static is required."

if [[ ! -x "$QEMU_TARGET_PATH" ]]; then
    install -D -m 0755 "$qemu_path" "$QEMU_TARGET_PATH"
    QEMU_INSTALLED_BY_STAGE=1
fi

}

run_arm64_chroot() {
chroot "$ROOT_MNT" \
    /usr/bin/qemu-aarch64-static \
    /bin/bash -c "$1"
}

install_kernel_apt_guard() {
install -D -m 0644 \
    "$KERNEL_APT_GUARD_SRC" \
    "$ROOT_MNT/etc/apt/preferences.d/99-cubie-a5e-managed-kernel"

grep -Fxq 'Package: linux-image-* linux-dtb-*' \
    "$ROOT_MNT/etc/apt/preferences.d/99-cubie-a5e-managed-kernel" ||
    die "Managed-kernel APT guard is invalid."

grep -Fxq 'Pin-Priority: -1' \
    "$ROOT_MNT/etc/apt/preferences.d/99-cubie-a5e-managed-kernel" ||
    die "Managed-kernel APT guard lacks its blocking priority."
}

purge_packaged_kernels() {
log "Purging donor kernel packages so package updates cannot restore Linux 5.15."

# The backslashes keep Bash from consuming dpkg-query's field placeholders.
# shellcheck disable=SC2016
run_arm64_chroot '
    kernel_packages=()

    while read -r package status; do
        [[ "$status" == ii* ]] || continue

        case "$package" in
            linux-image-* | linux-dtb-*)
                kernel_packages+=("$package")
                ;;
        esac
    done < <(
        dpkg-query -W \
            -f="\${binary:Package} \${db:Status-Abbrev}\n" \
            2>/dev/null
    )

    if ((${#kernel_packages[@]} > 0)); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y -- "${kernel_packages[@]}"
    fi
'
}

prepare_chroot_resolver() {
local target_resolver="$ROOT_MNT/etc/resolv.conf"

rm -f -- "$RESOLVER_BACKUP" "$RESOLVER_LINK_FILE"

if [[ -L "$target_resolver" ]]; then
    readlink "$target_resolver" >"$RESOLVER_LINK_FILE"
elif [[ -e "$target_resolver" ]]; then
    cp -a -- "$target_resolver" "$RESOLVER_BACKUP"
fi

rm -f -- "$target_resolver"
install -D -m 0644 /etc/resolv.conf "$target_resolver"

RESOLVER_PREPARED=1

}

ensure_target_runtime_packages() {
local bashrc="$ROOT_MNT/etc/bash.bashrc"
local candidate
local timesyncd_unit=""

log "Installing the Raspberry Pi OS Lite compatible base utilities and rsetup runtime."

prepare_chroot_resolver

install -D -m 0644 \
    "$BASIC_PACKAGES_SRC" \
    "$ROOT_MNT$BASIC_PACKAGES_TARGET"

install -D -m 0755 \
    "$RADXA_REPO_HELPER_SRC" \
    "$ROOT_MNT$RADXA_REPO_HELPER_TARGET"

run_arm64_chroot "$RADXA_REPO_HELPER_TARGET"

# The variables intentionally expand inside the target chroot.
# shellcheck disable=SC2016
run_arm64_chroot '
    export DEBIAN_FRONTEND=noninteractive

    mapfile -t basic_packages < <(
        sed -E \
            -e "/^[[:space:]]*(#|$)/d" \
            -e "s/[[:space:]]+$//" \
            /usr/share/cubie-a5e/raspios-lite-compatible-packages.txt
    )

    ((${#basic_packages[@]} > 0)) || {
        printf "%s\n" "The basic package manifest is empty." >&2
        exit 1
    }

    apt-get update

    for package in "${basic_packages[@]}"; do
        apt-cache show "$package" >/dev/null 2>&1 || {
            printf "Required basic package has no APT candidate: %s\n" "$package" >&2
            exit 1
        }
    done

    apt-get install -y --no-install-recommends "${basic_packages[@]}"

    rsetup_packages=(
        device-tree-compiler
        dialog
        gdisk
        iw
        jq
        kmod
        librtui
        network-manager
        openssl
        pkexec
        python3
        python3-yaml
        rfkill
        rsetup
        tar
        tzdata
        u-boot-menu
        wget
        whiptail
        wpasupplicant
    )

    root_resize_packages=(
        cloud-guest-utils
        e2fsprogs
    )

    for package in \
        "${rsetup_packages[@]}" \
        "${root_resize_packages[@]}"; do
        apt-cache show "$package" >/dev/null 2>&1 || {
            printf "Required target package has no APT candidate: %s\n" "$package" >&2
            printf "%s\n" "Verify that the Debian 13 and official Radxa APT sources are enabled." >&2
            exit 1
        }
    done

    apt-get install -y --no-install-recommends \
        "${rsetup_packages[@]}" \
        "${root_resize_packages[@]}"

    apt-get install -y --reinstall --no-install-recommends \
        librtui \
        rsetup

    apt-get install -y --reinstall --no-install-recommends \
        wireless-regdb

    update-alternatives --set \
        regulatory.db \
        /lib/firmware/regulatory.db-upstream

    cmp -s \
        /lib/firmware/regulatory.db \
        /lib/firmware/regulatory.db-upstream

    cmp -s \
        /lib/firmware/regulatory.db.p7s \
        /lib/firmware/regulatory.db.p7s-upstream
'

restore_chroot_resolver

require_nonempty_file "$ROOT_MNT/usr/share/bash-completion/bash_completion"
require_nonempty_file "$bashrc"

if ! grep -qF '/usr/share/bash-completion/bash_completion' "$bashrc"; then
    cat >>"$bashrc" <<'EOF'

if [[ $- == *i* ]] && [[ -r /usr/share/bash-completion/bash_completion ]]; then
    . /usr/share/bash-completion/bash_completion
fi
EOF
fi

run_arm64_chroot 'ln -snf /usr/share/zoneinfo/Asia/Dubai /etc/localtime'
run_arm64_chroot 'printf "%s\n" "Asia/Dubai" > /etc/timezone'

for candidate in \
    "$ROOT_MNT/usr/lib/systemd/system/systemd-timesyncd.service" \
    "$ROOT_MNT/lib/systemd/system/systemd-timesyncd.service"; do
    if [[ -s "$candidate" ]]; then
        timesyncd_unit="$candidate"
        break
    fi
done

[[ -n "$timesyncd_unit" ]] ||
    die "systemd-timesyncd.service was not installed."

install -d -m 0755 -- "$ROOT_MNT/etc/systemd/system/sysinit.target.wants"
ln -sfn \
    /usr/lib/systemd/system/systemd-timesyncd.service \
    "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"

grep -qF '/usr/share/bash-completion/bash_completion' "$bashrc" ||
    die "Bash completion was not enabled in /etc/bash.bashrc."

[[ -L "$ROOT_MNT/etc/localtime" ]] ||
    die "/etc/localtime is not a symlink."

[[ "$(readlink "$ROOT_MNT/etc/localtime")" == "/usr/share/zoneinfo/Asia/Dubai" ]] ||
    die "Timezone is not set to Asia/Dubai."

[[ -L "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" ]] ||
    die "systemd-timesyncd.service is not enabled."

require_nonempty_file "$ROOT_MNT/usr/lib/firmware/regulatory.db-upstream"
require_nonempty_file "$ROOT_MNT/usr/lib/firmware/regulatory.db.p7s-upstream"

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
}

install_root_filesystem_expander() {
local service_link="$ROOT_MNT$ROOT_GROW_WANTS"

log "Installing the one-time root filesystem expansion service."

install -D -m 0755 /dev/null "$ROOT_MNT$ROOT_GROW_PROGRAM"
cat >"$ROOT_MNT$ROOT_GROW_PROGRAM" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly MARKER="/var/lib/cubie-a5e/rootfs-expanded"
readonly LOG_FILE="/var/log/cubie-a5e-grow-rootfs.log"

marker_tmp=""

cleanup() {
    if [[ -n "$marker_tmp" ]]; then
        rm -f -- "$marker_tmp"
    fi
}

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

trap cleanup EXIT

mkdir -p -- /var/lib/cubie-a5e /var/log
exec >>"$LOG_FILE" 2>&1

if [[ -e "$MARKER" ]]; then
    log "Root filesystem expansion was already completed."
    exit 0
fi

for command_name in \
    awk \
    blockdev \
    findmnt \
    growpart \
    lsblk \
    partprobe \
    readlink \
    resize2fs \
    sfdisk \
    sgdisk \
    udevadm; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is missing: $command_name"
done

root_source="$(findmnt -nro SOURCE --target /)"
[[ -n "$root_source" ]] || die "Unable to identify the mounted root source."

root_part="$(readlink -f -- "$root_source")"
[[ -b "$root_part" ]] || die "Root source is not a block device: $root_source"

root_fstype="$(findmnt -nro FSTYPE --target /)"
[[ "$root_fstype" == "ext4" ]] ||
    die "Automatic expansion supports only ext4 root filesystems: $root_fstype"

root_type="$(lsblk -nro TYPE "$root_part")"
[[ "$root_type" == "part" ]] ||
    die "Root filesystem is not on a disk partition: $root_part"

parent_name="$(lsblk -nro PKNAME "$root_part")"
parent_name="${parent_name//[[:space:]]/}"
[[ -n "$parent_name" ]] || die "Unable to identify the parent disk for $root_part"

disk="/dev/$parent_name"
[[ -b "$disk" ]] || die "Parent disk is unavailable: $disk"

part_num="$(lsblk -nro PARTN "$root_part")"
part_num="${part_num//[[:space:]]/}"
[[ "$part_num" =~ ^[0-9]+$ ]] ||
    die "Unable to identify the root partition number: $root_part"
[[ "$part_num" == "3" ]] ||
    die "Expected the Cubie A5E root filesystem on partition 3; found $part_num"

highest_part="$(
    lsblk -nr -o TYPE,PARTN "$disk" |
        awk '$1 == "part" && ($2 + 0) > highest { highest = $2 + 0 } END { print highest + 0 }'
)"
[[ "$highest_part" == "$part_num" ]] ||
    die "Root partition is not the final partition: root=$part_num final=$highest_part"

disk_size="$(blockdev --getsize64 "$disk")"
part_size_before="$(blockdev --getsize64 "$root_part")"

log "Expanding root partition $root_part on $disk."
log "Size before expansion: disk=$disk_size partition=$part_size_before"

set +e
grow_output="$(growpart "$disk" "$part_num" 2>&1)"
grow_status=$?
set -e

if [[ -n "$grow_output" ]]; then
    printf '%s\n' "$grow_output"
fi

case "$grow_status" in
    0)
        log "Partition table expansion completed."
        ;;
    1)
        log "Partition already uses all available space; continuing with filesystem verification."
        ;;
    *)
        die "growpart failed with exit status $grow_status"
        ;;
esac

if ! partprobe "$disk"; then
    log "partprobe could not refresh the live partition table; the next boot will retry."
fi
udevadm settle

part_size_after="$(blockdev --getsize64 "$root_part")"

if [[ "$grow_status" == "0" ]] &&
   ((part_size_after <= part_size_before)); then
    die "The partition table changed but the kernel still reports the old partition size; reboot to retry."
fi

log "Expanding ext4 filesystem on $root_part."
resize2fs "$root_part"

marker_tmp="$(mktemp "${MARKER}.XXXXXX")"
{
    printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'disk=%s\n' "$disk"
    printf 'root_partition=%s\n' "$root_part"
    printf 'disk_size_bytes=%s\n' "$disk_size"
    printf 'partition_size_before_bytes=%s\n' "$part_size_before"
    printf 'partition_size_after_bytes=%s\n' "$part_size_after"
} >"$marker_tmp"
chmod 0644 "$marker_tmp"
mv -f -- "$marker_tmp" "$MARKER"
marker_tmp=""

sync
log "Root filesystem expansion completed successfully."
EOF

install -D -m 0644 /dev/null "$ROOT_MNT$ROOT_GROW_UNIT"
cat >"$ROOT_MNT$ROOT_GROW_UNIT" <<'EOF'
[Unit]
Description=Expand the Cubie A5E root filesystem to fill its storage device
After=local-fs.target
Before=multi-user.target
ConditionPathExists=!/var/lib/cubie-a5e/rootfs-expanded

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cubie-a5e-grow-rootfs
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

rm -f -- "$ROOT_MNT$ROOT_GROW_MARKER"
install -d -m 0755 -- "$(dirname -- "$service_link")"
ln -sfn \
    /usr/lib/systemd/system/cubie-a5e-grow-rootfs.service \
    "$service_link"

bash -n "$ROOT_MNT$ROOT_GROW_PROGRAM"
require_nonempty_file "$ROOT_MNT$ROOT_GROW_UNIT"

[[ -L "$service_link" ]] ||
    die "Root filesystem expansion service is not enabled."
[[ "$(readlink "$service_link")" == \
   "/usr/lib/systemd/system/cubie-a5e-grow-rootfs.service" ]] ||
    die "Root filesystem expansion service link is incorrect."

run_arm64_chroot '
    for command_name in growpart resize2fs; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf "Required root expansion command is missing: %s\n" "$command_name" >&2
            exit 1
        }
    done

    for package in cloud-guest-utils e2fsprogs; do
        status="$(dpkg-query -W -f="\${db:Status-Abbrev}" "$package" 2>/dev/null)"
        [[ "$status" == ii* ]] || {
            printf "Required root expansion package is not installed: %s status=%s\n" \
                "$package" \
                "$status" >&2
            exit 1
        }
    done
'
}

clean_target_apt_cache() {
log "Cleaning disposable target APT indexes and package archives."

run_arm64_chroot '
    export DEBIAN_FRONTEND=noninteractive
    apt-get clean
    rm -rf -- /var/lib/apt/lists/* /var/cache/apt/archives/partial/*
'

if find "$ROOT_MNT/var/cache/apt/archives" \
    -maxdepth 1 \
    -type f \
    -name '*.deb' \
    -print -quit 2>/dev/null |
    grep -q .; then
    die "Target APT package archives were not cleaned."
fi

if find "$ROOT_MNT/var/lib/apt/lists" \
    -mindepth 1 \
    -print -quit 2>/dev/null |
    grep -q .; then
    die "Target APT package indexes were not cleaned."
fi
}

install_initbox_account_and_login_policy() {
local autologin_file
local group
local group_csv
local -a supplementary_groups=()

log "Enforcing the fixed initbox administrator password and disabling automatic root login."

run_arm64_chroot "
    if ! id -u '$INITBOX_USER' >/dev/null 2>&1; then
        if ! getent group '$INITBOX_USER' >/dev/null 2>&1; then
            groupadd '$INITBOX_USER'
        fi

        useradd \
            --create-home \
            --gid '$INITBOX_USER' \
            --shell /bin/bash \
            '$INITBOX_USER'
    fi

    usermod \
        --home '/home/$INITBOX_USER' \
        --shell /bin/bash \
        '$INITBOX_USER'
"

for group in sudo adm dialout plugdev netdev; do
    if grep -Eq "^${group}:" "$ROOT_MNT/etc/group"; then
        supplementary_groups+=("$group")
    fi
done

printf '%s\n' "${supplementary_groups[@]}" |
    grep -Fxq sudo ||
    die "The target root filesystem does not provide the sudo group."

group_csv="$(
    IFS=,
    printf '%s' "${supplementary_groups[*]}"
)"

run_arm64_chroot \
    "usermod --append --groups '$group_csv' '$INITBOX_USER'"

install -d -m 0755 -- "$ROOT_MNT/tmp"
install -m 0600 /dev/null "$INITBOX_PASSWORD_FILE"
printf '%s:%s\n' "$INITBOX_USER" "$INITBOX_PASSWORD" \
    >"$INITBOX_PASSWORD_FILE"

run_arm64_chroot "
    chpasswd < /tmp/.cubie-a5e-initbox-password
    chage \
        --mindays 0 \
        --maxdays -1 \
        --lastday \"\$(date -u +%Y-%m-%d)\" \
        '$INITBOX_USER'
"

rm -f -- "$INITBOX_PASSWORD_FILE"

run_arm64_chroot "
    user_uid=\"\$(id -u '$INITBOX_USER')\"
    user_gid=\"\$(id -g '$INITBOX_USER')\"
    install \
        -d \
        -m 0750 \
        -o \"\$user_uid\" \
        -g \"\$user_gid\" \
        '/home/$INITBOX_USER'
"

install -D -m 0440 /dev/null "$ROOT_MNT$INITBOX_SUDOERS"
printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$INITBOX_USER" \
    >"$ROOT_MNT$INITBOX_SUDOERS"

run_arm64_chroot "visudo --check --file '$INITBOX_SUDOERS'"

while IFS= read -r -d '' autologin_file; do
    grep -Eq \
        -- '--autologin([=[:space:]]+)root([[:space:]]|$)|agetty.*([[:space:]]-a|--autologin)([=[:space:]]+)root([[:space:]]|$)' \
        "$autologin_file" ||
        continue

    rm -f -- "$autologin_file"
done < <(
    find "$ROOT_MNT/etc/systemd/system" \
        \( -type f -o -type l \) \
        -print0
)

install -D -m 0644 /dev/null "$ROOT_MNT$GETTY_TTY1_DROPIN"
cat >"$ROOT_MNT$GETTY_TTY1_DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear - $TERM
Type=idle
EOF

install -D -m 0644 /dev/null "$ROOT_MNT$SERIAL_GETTY_DROPIN"
cat >"$ROOT_MNT$SERIAL_GETTY_DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 - $TERM
Type=idle
EOF

install -d -m 0755 \
    "$ROOT_MNT/etc/systemd/system/getty.target.wants"

ln -sfn \
    /usr/lib/systemd/system/getty@.service \
    "$ROOT_MNT/etc/systemd/system/getty.target.wants/getty@tty1.service"

ln -sfn \
    /usr/lib/systemd/system/serial-getty@.service \
    "$ROOT_MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

install -D -m 0644 /dev/null "$ROOT_MNT$INITBOX_ACCOUNT_STATUS"
{
    printf 'USER=%s\n' "$INITBOX_USER"
    printf 'HOME=/home/%s\n' "$INITBOX_USER"
    printf 'SHELL=/bin/bash\n'
    printf 'SUDO=NOPASSWD\n'
    printf 'CONSOLE_LOGIN=prompt\n'
    printf 'ROOT_AUTOLOGIN=disabled\n'
    printf 'PASSWORD_POLICY=fixed-init\n'
    printf 'PASSWORD_EXPIRY=disabled\n'
    printf 'INITIAL_PASSWORD_CHANGE=not-required\n'
} >"$ROOT_MNT$INITBOX_ACCOUNT_STATUS"

run_arm64_chroot "
    id '$INITBOX_USER'
    passwd --status '$INITBOX_USER'
    getent group sudo
"

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

grep -Fxq 'CONSOLE_LOGIN=prompt' \
    "$ROOT_MNT$INITBOX_ACCOUNT_STATUS" ||
    die "The initbox console login policy marker is invalid."
}

validate_rsetup_runtime() {
local smoke_output
local smoke_status
local status_file="$ROOT_MNT/var/lib/cubie-a5e/rsetup-self-test.status"

log "Running the installed rsetup dependency and source-chain smoke test."

if smoke_output="$(
    run_arm64_chroot '/usr/local/bin/rsetup --self-test' 2>&1
)"; then
    smoke_status=0
else
    smoke_status=$?
fi

if [[ -n "$smoke_output" ]]; then
    printf '%s\n' "$smoke_output"
fi

((smoke_status == 0)) ||
    die "Installed rsetup chroot smoke test exited with status $smoke_status."

grep -Fxq 'rsetup self-test: PASS' <<<"$smoke_output" ||
    die "Installed rsetup chroot smoke test did not report PASS."

# The backslashes keep Bash from consuming dpkg-query's field placeholders.
# shellcheck disable=SC2016
run_arm64_chroot '
    for package in rsetup librtui; do
        if ! status="$(
            dpkg-query -W \
                -f="\${db:Status-Abbrev}" \
                "$package" 2>/dev/null
        )"; then
            printf "Required package is not registered by dpkg: %s\n" \
                "$package" >&2
            exit 1
        fi

        if [[ "$status" != "ii " ]]; then
            printf "Required package is not fully installed: %s status=<%s>\n" \
                "$package" \
                "$status" >&2
            exit 1
        fi

        printf "rsetup package status: %s %s\n" "$package" "$status"
    done
'

install -d -m 0755 -- "$(dirname -- "$status_file")"
{
    printf 'RSETUP_SELF_TEST=PASS\n'
    printf 'RSETUP_PACKAGE_STATUS=installed\n'
    printf 'LIBRTUI_PACKAGE_STATUS=installed\n'
    printf 'TESTED_UTC=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$status_file"
chmod 0644 "$status_file"
}

install_update_manager() {
local root_uuid
local boot_uuid
local layout_file="$ROOT_MNT/etc/cubie-a5e-update/layout.env"
local state_file="$ROOT_MNT/var/lib/cubie-a5e-update/active.env"
local service_link="$ROOT_MNT/etc/systemd/system/multi-user.target.wants/cubie-a5e-update-finalize.service"

need_file "$UPDATE_PROGRAM_SRC"
need_file "$RSETUP_WRAPPER_SRC"
need_file "$UPDATE_SERVICE_SRC"
need_file "$KERNEL_APT_GUARD_SRC"
require_nonempty_file "$UPDATE_PUBLIC_KEY"

[[ -x "$ROOT_MNT/usr/bin/rsetup" ]] ||
    die "The original Radxa rsetup executable is missing."

root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
boot_uuid="$(blkid -s UUID -o value "$BOOT_PART")"

[[ -n "$root_uuid" ]] || die "Could not determine the root filesystem UUID."
[[ -n "$boot_uuid" ]] || die "Could not determine the boot filesystem UUID."

install -D -m 0755 \
    "$UPDATE_PROGRAM_SRC" \
    "$ROOT_MNT/usr/local/sbin/cubie-a5e-update"
install -D -m 0755 \
    "$RSETUP_WRAPPER_SRC" \
    "$ROOT_MNT/usr/local/bin/rsetup"
install -D -m 0644 \
    "$UPDATE_SERVICE_SRC" \
    "$ROOT_MNT/usr/lib/systemd/system/cubie-a5e-update-finalize.service"
install -D -m 0644 \
    "$UPDATE_PUBLIC_KEY" \
    "$ROOT_MNT/etc/cubie-a5e-update/trusted-public.pem"

install -d -m 0755 -- \
    "$ROOT_MNT/etc/cubie-a5e-update" \
    "$ROOT_MNT/var/lib/cubie-a5e-update/inbox" \
    "$(dirname -- "$service_link")"

{
    printf 'ROOT_UUID=%q\n' "$root_uuid"
    printf 'BOOT_UUID=%q\n' "$boot_uuid"
    printf 'EXTLINUX_REL=%q\n' "$EXTLINUX_REL"
    printf 'SAME_FS=%q\n' "$SAME_FS"
} >"$layout_file"

{
    printf 'ACTIVE_KERNEL_RELEASE=%q\n' "$KERNEL_RELEASE"
    printf 'ACTIVE_UPDATE_VERSION=%q\n' "$UPDATE_VERSION"
    printf 'UPDATED_UTC=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$state_file"

chmod 0644 "$layout_file" "$state_file"

ln -sfn \
    /usr/lib/systemd/system/cubie-a5e-update-finalize.service \
    "$service_link"

[[ -x "$ROOT_MNT/usr/local/sbin/cubie-a5e-update" ]] ||
    die "Cubie A5E updater was not installed."
[[ -x "$ROOT_MNT/usr/local/bin/rsetup" ]] ||
    die "rsetup update wrapper was not installed."
[[ -L "$service_link" ]] ||
    die "Kernel update finalization service was not enabled."
}

disable_inapplicable_efi_automount() {
local unit

install -d -m 0755 -- "$ROOT_MNT/etc/systemd/system"

for unit in efi.automount efi.mount; do
    ln -sfn /dev/null "$ROOT_MNT/etc/systemd/system/$unit"

    [[ -L "$ROOT_MNT/etc/systemd/system/$unit" ]] ||
        die "Failed to mask $unit."

    [[ "$(readlink "$ROOT_MNT/etc/systemd/system/$unit")" == "/dev/null" ]] ||
        die "$unit is not masked to /dev/null."
done
}

ensure_initramfs_tools() {
if run_arm64_chroot \
    'test -x /usr/sbin/update-initramfs && test -x /usr/bin/unmkinitramfs'; then
return 0
fi

log "Installing initramfs-tools in the target root filesystem."

prepare_chroot_resolver

run_arm64_chroot \
    'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends initramfs-tools'

restore_chroot_resolver

run_arm64_chroot \
    'test -x /usr/sbin/update-initramfs && test -x /usr/bin/unmkinitramfs' ||
    die "update-initramfs or unmkinitramfs remains unavailable."

}

create_initramfs() {
log "Creating initramfs for $KERNEL_RELEASE."

rm -f -- "$ROOT_MNT/boot/initrd.img-$KERNEL_RELEASE"

run_arm64_chroot \
    "update-initramfs -c -k '$KERNEL_RELEASE'"

require_nonempty_file "$ROOT_MNT/boot/initrd.img-$KERNEL_RELEASE"

}

validate_initramfs_regulatory_database() {
local status_file="$ROOT_MNT/var/lib/cubie-a5e/regulatory-initramfs.status"

log "Validating the upstream regulatory database embedded in the initramfs."

run_arm64_chroot "
    set -Eeuo pipefail

    extract_dir=\"\$(mktemp -d /tmp/cubie-regdb-initramfs.XXXXXX)\"

    cleanup_regdb_extract() {
        rm -rf -- \"\$extract_dir\"
    }

    trap cleanup_regdb_extract EXIT

    unmkinitramfs \
        '/boot/initrd.img-$KERNEL_RELEASE' \
        \"\$extract_dir\"

    regdb_match=0
    signature_match=0

    while IFS= read -r -d '' candidate; do
        if cmp -s \
            \"\$candidate\" \
            /lib/firmware/regulatory.db-upstream; then
            regdb_match=1
            break
        fi
    done < <(
        find \"\$extract_dir\" \
            \( -type f -o -type l \) \
            -path '*/lib/firmware/regulatory.db' \
            -print0
    )

    while IFS= read -r -d '' candidate; do
        if cmp -s \
            \"\$candidate\" \
            /lib/firmware/regulatory.db.p7s-upstream; then
            signature_match=1
            break
        fi
    done < <(
        find \"\$extract_dir\" \
            \( -type f -o -type l \) \
            -path '*/lib/firmware/regulatory.db.p7s' \
            -print0
    )

    ((regdb_match == 1)) || {
        printf '%s\n' \
            'The initramfs does not contain the selected upstream regulatory database.' \
            >&2
        exit 1
    }

    ((signature_match == 1)) || {
        printf '%s\n' \
            'The initramfs does not contain the selected upstream regulatory signature.' \
            >&2
        exit 1
    }
"

install -D -m 0644 /dev/null "$status_file"
printf '%s\n' \
    'upstream regulatory.db and regulatory.db.p7s: PASS' \
    >"$status_file"
}

copy_boot_payload() {
if ((SAME_FS == 1)); then
return 0
fi

install -D -m 0644 \
    "$ROOT_MNT/boot/vmlinuz-$KERNEL_RELEASE" \
    "$BOOT_MNT/vmlinuz-$KERNEL_RELEASE"

install -D -m 0644 \
    "$ROOT_MNT/boot/initrd.img-$KERNEL_RELEASE" \
    "$BOOT_MNT/initrd.img-$KERNEL_RELEASE"

install -D -m 0644 \
    "$DTB_SRC" \
    "$BOOT_MNT/dtb-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"

}

update_extlinux() {
local extlinux_file="$BOOT_MNT/$EXTLINUX_REL"
local extlinux_dir
local root_uuid
local linux_path
local initrd_path
local fdtdir_path
local existing_append
local temporary_extlinux

require_nonempty_file "$extlinux_file"

root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"

[[ -n "$root_uuid" ]] ||
    die "Could not determine root UUID."

if [[ "$EXTLINUX_REL" == boot/* ]]; then
    linux_path="/boot/vmlinuz-$KERNEL_RELEASE"
    initrd_path="/boot/initrd.img-$KERNEL_RELEASE"
    fdtdir_path="/usr/lib/linux-image-$KERNEL_RELEASE/"
else
    linux_path="/vmlinuz-$KERNEL_RELEASE"
    initrd_path="/initrd.img-$KERNEL_RELEASE"
    fdtdir_path="/dtb-$KERNEL_RELEASE/"
fi

existing_append="$(
    awk '
        /^[[:space:]]*append[[:space:]]+/ {
            sub(/^[[:space:]]*append[[:space:]]+/, "")
            print
            exit
        }
    ' "$extlinux_file"
)"

if [[ -z "$existing_append" ]]; then
    existing_append="root=UUID=$root_uuid rootwait rw console=tty1"
elif grep -qE '(^|[[:space:]])root=UUID=[^[:space:]]+' <<<"$existing_append"; then
    existing_append="$(
        sed -E \
            "s#(^|[[:space:]])root=UUID=[^[:space:]]+#\\1root=UUID=$root_uuid#" \
            <<<"$existing_append"
    )"
else
    existing_append="root=UUID=$root_uuid $existing_append"
fi

existing_append="$(
    awk '
        {
            for (i = 1; i <= NF; i++) {
                argument = $i
                if (argument == "quiet" ||
                    argument == "splash" ||
                    argument == "console=ttyAS0,115200n8" ||
                    argument == "earlyprintk=sunxi-uart,0x2500000" ||
                    argument == "earlycon" ||
                    argument == "loglevel=4" ||
                    argument == "console=ttyS0,115200n8" ||
                    argument == "earlycon=uart8250,mmio32,0x02500000,115200" ||
                    argument == "ignore_loglevel" ||
                    argument == "loglevel=8") {
                    continue
                }
                output = output (output == "" ? "" : " ") argument
            }
        }
        END { print output }
    ' <<<"$existing_append"
)"

existing_append="$existing_append console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x02500000,115200 ignore_loglevel loglevel=8"

extlinux_dir="$(dirname -- "$extlinux_file")"
temporary_extlinux="$(mktemp "$extlinux_dir/.extlinux.conf.XXXXXX")"

cat >"$temporary_extlinux" <<EOF
default cubie-a5e
menu title Radxa Cubie A5E
timeout 10

label cubie-a5e
menu label Debian GNU/Linux 13 Linux $KERNEL_RELEASE
linux $linux_path
initrd $initrd_path
fdtdir $fdtdir_path
append $existing_append
EOF

chmod 0644 "$temporary_extlinux"
sync "$temporary_extlinux"
mv -f -- "$temporary_extlinux" "$extlinux_file"
sync "$extlinux_file"

grep -Fxq 'default cubie-a5e' \
    "$extlinux_file" ||
    die "extlinux default is not cubie-a5e."

[[ "$(grep -Ec '^[[:space:]]*label[[:space:]]+' "$extlinux_file")" -eq 1 ]] ||
    die "extlinux must contain exactly one boot entry."

grep -Fxq 'label cubie-a5e' \
    "$extlinux_file" ||
    die "Managed Cubie A5E entry is missing."

grep -Fq "linux $linux_path" "$extlinux_file" ||
    die "Managed kernel path is incorrect."

grep -Fq "initrd $initrd_path" "$extlinux_file" ||
    die "Managed initrd path is incorrect."

grep -Fq "fdtdir $fdtdir_path" "$extlinux_file" ||
    die "Managed DTB directory is incorrect."

linux_616_append="$(
    awk '
        /^[[:space:]]*label[[:space:]]+cubie-a5e[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]*label[[:space:]]+/ { exit }
        inside && /^[[:space:]]*append[[:space:]]+/ {
            sub(/^[[:space:]]*append[[:space:]]+/, "")
            print
            exit
        }
    ' "$extlinux_file"
)"

[[ -n "$linux_616_append" ]] || die "Managed append line is missing."
grep -Eq '(^|[[:space:]])console=ttyS0,115200n8([[:space:]]|$)' <<<"$linux_616_append" || die "Managed entry does not use ttyS0."
grep -Eq '(^|[[:space:]])earlycon=uart8250,mmio32,0x02500000,115200([[:space:]]|$)' <<<"$linux_616_append" || die "Managed earlycon is missing."
grep -Eq '(^|[[:space:]])ignore_loglevel([[:space:]]|$)' <<<"$linux_616_append" || die "Managed ignore_loglevel is missing."
grep -Eq '(^|[[:space:]])loglevel=8([[:space:]]|$)' <<<"$linux_616_append" || die "Managed loglevel=8 is missing."
if grep -Eq '(^|[[:space:]])(console=ttyAS0,115200n8|quiet|splash|loglevel=4)([[:space:]]|$)' <<<"$linux_616_append"; then
    die "Managed entry still contains vendor or suppressed-console arguments."
fi

if grep -Eq '5\.15\.147-20-aw2501|^[[:space:]]*label[[:space:]]+(l0|l0r)[[:space:]]*$' \
    "$extlinux_file"; then
    die "Linux 5.15 recovery references remain in extlinux."
fi

cp -a -- "$extlinux_file" "$EXTLINUX_REPORT"
rm -f -- "$extlinux_file.before-6.16"

}

write_install_report() {
{
printf 'Linux 6.16 installation report\n'
printf '==============================\n'
printf 'Kernel release: %s\n' "$KERNEL_RELEASE"
printf 'Target device: %s\n' "$TARGET_DEVICE"
printf 'Root partition: %s\n' "$ROOT_PART"
printf 'Boot partition: %s\n' "$BOOT_PART"
printf 'Extlinux path: %s\n' "$EXTLINUX_REL"
printf 'Kernel Image source: %s\n' "$IMAGE_SRC"
printf 'Board DTB source: %s\n' "$DTB_SRC"
printf 'Installed module directory: %s\n' \
    "$ROOT_MNT/lib/modules/$KERNEL_RELEASE/updates/aic8800"
printf 'Module load order file: /etc/modules-load.d/cubie-a5e-aic8800.conf\n'
printf 'AIC platform path: generic Linux SDIO\n'
printf 'External RFKill/rescan module installed: no\n'
printf 'Duplicate Wi-Fi loader services removed: yes\n'
printf 'Obsolete AIC8800 module aliases removed: yes\n'
printf 'Kernel config installed: /boot/config-%s\n' "$KERNEL_RELEASE"
printf 'Bash completion installed and enabled: yes\n'
printf 'systemd-timesyncd installed and enabled: yes\n'
printf 'Upstream-signed wireless regulatory database selected before initramfs: yes\n'
printf 'Initramfs upstream regulatory payload verification: PASS\n'
printf 'Inapplicable EFI automount masked: yes\n'
printf 'Timezone: Asia/Dubai\n'
printf 'Managed update version: %s\n' "$UPDATE_VERSION"
printf 'Signed update bundle: %s\n' "$(<"$UPDATE_BUNDLE_FILE")"
printf 'Trusted update public key installed: yes\n'
printf 'rsetup update gateway installed: yes\n'
printf 'rsetup and librtui installed from packages: yes\n'
printf 'rsetup chroot source-chain smoke test: PASS\n'
printf 'Raspberry Pi OS Lite compatible base utilities installed: yes\n'
printf 'Basic package manifest: %s\n' "$BASIC_PACKAGES_TARGET"
printf 'Stage 60 runtime rootfs cache status: %s\n' "$RUNTIME_CACHE_STATUS"
printf 'Stage 60 runtime rootfs cache fingerprint: %s\n' "$RUNTIME_CACHE_FINGERPRINT"
printf 'Stage 60 runtime rootfs cache max age seconds: %s\n' "$RUNTIME_CACHE_MAX_AGE_SECONDS"
printf 'Automatic root filesystem expansion installed: yes\n'
printf 'Root filesystem expansion service: cubie-a5e-grow-rootfs.service\n'
printf 'Root filesystem expansion marker: %s\n' "$ROOT_GROW_MARKER"
printf 'Disposable target APT caches cleaned: yes\n'
printf 'ping command installed: yes\n'
printf 'nano editor installed: yes\n'
printf 'Default interactive user: %s\n' "$INITBOX_USER"
printf 'Automatic root login: disabled\n'
printf 'Console login mode: prompt\n'
printf 'initbox password policy: fixed-init\n'
printf 'initbox password expiry: disabled\n'
printf 'Initial initbox password change required: no\n'
printf 'Kernel update finalizer enabled: yes\n'
printf 'APT kernel replacement guard installed: yes\n'
printf 'Installed kernel count: 1\n'
printf 'Extlinux entry count: 1\n'
printf 'Linux 5.15 retained: no\n'
printf 'Managed Cubie A5E entry default: yes\n'
} >"$INSTALL_REPORT"
}

main() {
log "Stage 60 revision: guarded-runtime-rootfs-cache-20260818"
require_command awk
require_command blkid
require_command chroot
require_command cmp
require_command date
require_command depmod
require_command diff
require_command find
require_command findmnt
require_command grep
require_command install
require_command ln
require_command lsblk
require_command make
require_command mktemp
require_command mount
require_command mountpoint
require_command nm
require_command openssl
require_command qemu-aarch64-static
require_command readlink
require_command rsync
require_command sed
require_command sha256sum
require_command sort
require_command strings
require_command sync
require_command umount

[[ "$(id -u)" -eq 0 ]] ||
    die "Run this stage as root."

[[ -b "$TARGET_DEVICE" ]] ||
    die "Target device is not a block device: $TARGET_DEVICE"

need_dir "$BUILD_ROOT"
need_dir "$KERNEL_DIR"
need_dir "$AIC_REPO"

require_nonempty_file "$KERNEL_RELEASE_FILE"
require_nonempty_file "$UPDATE_VERSION_FILE"
require_nonempty_file "$UPDATE_BUNDLE_FILE"
require_nonempty_file "$UPDATE_PUBLIC_KEY_FILE"
require_nonempty_file "$IMAGE_SRC"
require_nonempty_file "$CONFIG_SRC"
require_nonempty_file "$DTB_SRC"

KERNEL_RELEASE="$(tr -d '[:space:]' <"$KERNEL_RELEASE_FILE")"
UPDATE_VERSION="$(tr -d '[:space:]' <"$UPDATE_VERSION_FILE")"
UPDATE_PUBLIC_KEY="$(<"$UPDATE_PUBLIC_KEY_FILE")"

[[ -n "$KERNEL_RELEASE" ]] ||
    die "Kernel release file is empty."
[[ "$UPDATE_VERSION" =~ ^[A-Za-z0-9._+:-]+$ ]] ||
    die "Update version is invalid: $UPDATE_VERSION"
require_nonempty_file "$UPDATE_PUBLIC_KEY"

validate_runtime_cache_settings
validate_input_manifests
load_target_layout
mount_target_filesystems

prepare_cached_target_runtime
remove_existing_kernel_payloads

install_kernel_modules
install_kernel_image_and_dtb
install_external_modules
remove_duplicate_wifi_loader
remove_obsolete_aic_module_aliases
install_module_policy
install_firmware
generate_module_metadata
validate_single_wifi_loader
validate_installed_modules

install_root_filesystem_expander
install_initbox_account_and_login_policy
disable_inapplicable_efi_automount
create_initramfs
validate_initramfs_regulatory_database
copy_boot_payload
update_extlinux
install_update_manager
clean_target_apt_cache
validate_rsetup_runtime

sync

write_install_report

log "Installed Linux $KERNEL_RELEASE."
log "Set extlinux default to the single cubie-a5e entry."
log "Removed the official Linux 5.15 kernel and recovery entries."
log "Installed and smoke-tested rsetup with signed Cubie A5E updates."
log "Installed the Raspberry Pi OS Lite compatible base utility set."
log "Installed one-time automatic root filesystem expansion."
log "Cleaned disposable target APT caches to reduce image size."
log "Configured initbox with fixed password init, no password expiry and passwordless sudo."
log "Disabled automatic root login on tty1 and ttyS0."
log "Installation report: $INSTALL_REPORT"

}

main "$@"
