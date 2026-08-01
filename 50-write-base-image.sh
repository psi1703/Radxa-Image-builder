#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh

source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="BASEIMAGE"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${TARGET_DEVICE:?TARGET_DEVICE is not set}"
: "${BASE_IMAGE_BUILDER:?BASE_IMAGE_BUILDER is not set}"
: "${ROOTFS_DIR:?ROOTFS_DIR is not set}"

readonly ROOTFS_DIR
readonly STOCK_IMG_XZ="${STOCK_IMG_XZ:-$BUILD_ROOT/downloads/radxa-cubie-a5e_bullseye_cli_r7.output_512.img.xz}"
readonly TARGET_HOSTNAME="${TARGET_HOSTNAME:-cubie-a5e}"
readonly TIMEZONE="${TIMEZONE:-Asia/Dubai}"

readonly TARGET_LAYOUT_FILE="$BUILD_ROOT/.one-shot-target-layout"
readonly LAYOUT_CANDIDATES_FILE="$BUILD_ROOT/.one-shot-layout-candidates"

if [[ -n "${LOG_DIR:-}" ]]; then
mkdir -p -- "$LOG_DIR"

readonly BASE_IMAGE_REPORT="$LOG_DIR/base-image-write-report.txt"
readonly TARGET_BEFORE_REPORT="$LOG_DIR/target-before-base-image.txt"
readonly TARGET_AFTER_REPORT="$LOG_DIR/target-after-base-image.txt"

else
readonly BASE_IMAGE_REPORT="$BUILD_ROOT/.one-shot-base-image-write-report.txt"
readonly TARGET_BEFORE_REPORT="$BUILD_ROOT/.one-shot-target-before-base-image.txt"
readonly TARGET_AFTER_REPORT="$BUILD_ROOT/.one-shot-target-after-base-image.txt"
fi

require_nonempty_file() {
local path="$1"

[[ -s "$path" ]] ||
    die "Required file is missing or empty: $path"

}

device_identity() {
local device="$1"

lsblk -dnro MAJ:MIN "$device"

}

unmount_target_partitions() {
local mountpoint_path

while IFS= read -r mountpoint_path; do
    [[ -n "$mountpoint_path" ]] || continue

    log "Unmounting target mountpoint: $mountpoint_path"
    run umount "$mountpoint_path"
done < <(
    lsblk -lnpo MOUNTPOINTS "$TARGET_DEVICE" |
        awk 'NF > 0 && $1 != "" {print $1}' |
        sort -r
)

}

validate_target_before_write() {
local target_type
local holders
local build_root_real
local base_image_builder_real
local stock_img_real
local rootfs_real
local script_dir_real

[[ "$(id -u)" -eq 0 ]] ||
    die "Run this stage as root."

need_block_device "$TARGET_DEVICE"
need_file "$BASE_IMAGE_BUILDER"
require_nonempty_file "$STOCK_IMG_XZ"

build_root_real="$(readlink -m -- "$BUILD_ROOT")"
base_image_builder_real="$(readlink -m -- "$BASE_IMAGE_BUILDER")"
stock_img_real="$(readlink -m -- "$STOCK_IMG_XZ")"
rootfs_real="$(readlink -m -- "$ROOTFS_DIR")"
script_dir_real="$(readlink -m -- "$SCRIPT_DIR")"

[[ "$build_root_real" == "$script_dir_real/build" ]] ||
    die "BUILD_ROOT must be the repository build directory: $build_root_real"

[[ "$base_image_builder_real" == "$script_dir_real/base/build-debian13-donor-image.sh" ]] ||
    die "Unexpected BASE_IMAGE_BUILDER: $base_image_builder_real"

[[ "$stock_img_real" == "$build_root_real/downloads/radxa-cubie-a5e_bullseye_cli_r7.output_512.img.xz" ]] ||
    die "STOCK_IMG_XZ must be inside BUILD_ROOT/downloads: $stock_img_real"

[[ "$rootfs_real" == "$build_root_real/rootfs" ]] ||
    die "ROOTFS_DIR must be BUILD_ROOT/rootfs: $rootfs_real"

[[ -x "$BASE_IMAGE_BUILDER" ]] ||
    die "Base image builder is not executable: $BASE_IMAGE_BUILDER"

target_type="$(lsblk -dnro TYPE "$TARGET_DEVICE" 2>/dev/null || true)"

[[ "$target_type" == "disk" ]] ||
    die "TARGET_DEVICE must be an entire disk: $TARGET_DEVICE"

case "$TARGET_DEVICE" in
    /dev/sda | /dev/vda | /dev/xvda | /dev/nvme0n1 | /dev/mmcblk0)
        die "Refusing dangerous target device: $TARGET_DEVICE"
        ;;
esac

holders="$(
    find "/sys/class/block/$(basename -- "$(readlink -f -- "$TARGET_DEVICE")")/holders" \
        -mindepth 1 \
        -maxdepth 1 \
        -print -quit 2>/dev/null || true
)"

[[ -z "$holders" ]] ||
    die "Target device has active holders: $TARGET_DEVICE"

unmount_target_partitions

lsblk -o \
    NAME,PATH,MAJ:MIN,SIZE,TYPE,FSTYPE,LABEL,UUID,MODEL,SERIAL,TRAN,RM,MOUNTPOINTS \
    "$TARGET_DEVICE" >"$TARGET_BEFORE_REPORT"

}

run_base_image_builder() {
log "Writing official Radxa base image and Debian 13 root filesystem."
log "Target device: $TARGET_DEVICE"
log "Stock image: $STOCK_IMG_XZ"
log "Base image builder: $BASE_IMAGE_BUILDER"

run env \
    CONFIRM_WRITE=1 \
    TARGET_DEVICE="$TARGET_DEVICE" \
    WORKDIR="$BUILD_ROOT" \
    ROOTFS_DIR="$ROOTFS_DIR" \
    STOCK_IMG_XZ="$STOCK_IMG_XZ" \
    TARGET_HOSTNAME="$TARGET_HOSTNAME" \
    TIMEZONE="$TIMEZONE" \
    bash "$BASE_IMAGE_BUILDER"

}

refresh_partition_table() {
log "Refreshing the target partition table."

run sync

if command -v partprobe >/dev/null 2>&1; then
    run partprobe "$TARGET_DEVICE"
fi

if command -v partx >/dev/null 2>&1; then
    partx -u "$TARGET_DEVICE" 2>/dev/null || true
fi

if command -v udevadm >/dev/null 2>&1; then
    run udevadm settle
fi

sleep 2

}

validate_target_after_write() {
local before_identity="$1"
local after_identity
local target_size
local partition_count
local root_candidate_count=0
local boot_candidate_count=0
local probe_root="$BUILD_ROOT/mnt/base-image-probe"
local partition
local mount_dir

after_identity="$(device_identity "$TARGET_DEVICE")"

[[ -n "$after_identity" ]] ||
    die "Unable to identify target device after image writing."

[[ "$after_identity" == "$before_identity" ]] ||
    die "Target identity changed: before=$before_identity after=$after_identity"

target_size="$(blockdev --getsize64 "$TARGET_DEVICE")"

((target_size >= 4 * 1024 * 1024 * 1024)) ||
    die "Target became unexpectedly small after image writing."

mapfile -t target_partitions < <(
    lsblk -lnpo NAME,TYPE "$TARGET_DEVICE" |
        awk '$2 == "part" {print $1}'
)

partition_count="${#target_partitions[@]}"

((partition_count >= 3)) ||
    die "Expected at least three target partitions; found $partition_count"

mkdir -p -- "$probe_root"

for partition in "${target_partitions[@]}"; do
    [[ -b "$partition" ]] || continue

    mount_dir="$probe_root/$(basename -- "$partition")"
    mkdir -p -- "$mount_dir"

    if mountpoint -q "$mount_dir"; then
        umount "$mount_dir"
    fi

    if ! mount -o ro "$partition" "$mount_dir" 2>/dev/null; then
        continue
    fi

    if [[ -f "$mount_dir/etc/os-release" &&
          -d "$mount_dir/usr" &&
          -d "$mount_dir/boot" ]]; then
        root_candidate_count=$((root_candidate_count + 1))
    fi

    if [[ -f "$mount_dir/boot/extlinux/extlinux.conf" ||
          -f "$mount_dir/extlinux/extlinux.conf" ]]; then
        boot_candidate_count=$((boot_candidate_count + 1))
    fi

    umount "$mount_dir"
done

((root_candidate_count == 1)) ||
    die "Expected exactly one Debian root filesystem; found $root_candidate_count"

((boot_candidate_count == 1)) ||
    die "Expected exactly one extlinux filesystem; found $boot_candidate_count"

lsblk -o \
    NAME,PATH,MAJ:MIN,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,MODEL,SERIAL,TRAN,RM,MOUNTPOINTS \
    "$TARGET_DEVICE" >"$TARGET_AFTER_REPORT"

}

clear_stale_layout_state() {
rm -f -- \
    "$TARGET_LAYOUT_FILE" \
    "$LAYOUT_CANDIDATES_FILE"
}

write_report() {
local before_identity="$1"
local after_identity

after_identity="$(device_identity "$TARGET_DEVICE")"

{
    printf 'Cubie A5E base-image write report\n'
    printf '=================================\n'
    printf 'Status: PASS\n'
    printf 'Target device: %s\n' "$TARGET_DEVICE"
    printf 'Device identity before: %s\n' "$before_identity"
    printf 'Device identity after: %s\n' "$after_identity"
    printf 'Base image builder: %s\n' "$BASE_IMAGE_BUILDER"
    printf 'Stock Radxa image: %s\n' "$STOCK_IMG_XZ"
    printf 'Rootfs directory: %s\n' "$ROOTFS_DIR"
    printf 'Target hostname: %s\n' "$TARGET_HOSTNAME"
    printf 'Timezone: %s\n' "$TIMEZONE"
    printf 'Minimum partition count validated: 3\n'
    printf 'Debian root filesystem count: 1\n'
    printf 'Extlinux filesystem count: 1\n'
    printf 'Target layout cache cleared: yes\n'
    printf 'Before-write evidence: %s\n' "$TARGET_BEFORE_REPORT"
    printf 'After-write evidence: %s\n' "$TARGET_AFTER_REPORT"
} >"$BASE_IMAGE_REPORT"

}

main() {
local before_identity

need_cmd awk
need_cmd bash
need_cmd blockdev
need_cmd find
need_cmd lsblk
need_cmd mount
need_cmd mountpoint
need_cmd readlink
need_cmd sort
need_cmd sync
need_cmd umount

validate_target_before_write

before_identity="$(device_identity "$TARGET_DEVICE")"

[[ -n "$before_identity" ]] ||
    die "Unable to identify target device before image writing."

clear_stale_layout_state
run_base_image_builder
refresh_partition_table
validate_target_after_write "$before_identity"
clear_stale_layout_state
write_report "$before_identity"

log "Base image written and verified on $TARGET_DEVICE."
log "Target layout will be rediscovered from disk."
log "Base image report: $BASE_IMAGE_REPORT"

}

main "$@"
