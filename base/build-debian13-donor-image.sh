#!/usr/bin/env bash
#
# build-cubie-a5e-official-boot-debian-rootfs.sh
#
# Radxa Cubie A5E hybrid image writer. v14q: verified syntax baseline with usr-merge/firmware fixes, official Radxa rsetup payload, PuTTY-safe dialog rendering, and u-boot/overlay support for rsetup Overlays menu.
#
# Purpose:
#   - Use the official Radxa CLI image as the known-good bootloader/kernel donor.
#   - Replace only partition 3 with our prepared Debian rootfs.
#   - Preserve the official /boot payload and DTB directory used by Radxa U-Boot.
#   - Preserve the official kernel modules and firmware needed by the Radxa
#     vendor kernel, including AIC8800 Wi-Fi/BT support.
#
# Why this exists:
#   The Cubie A5E official image boots, while a freshly built mainline
#   u-boot-sunxi-with-spl.bin produced no serial output on this board. Therefore
#   the safest base-image path is to keep Radxa's boot chain intact and replace
#   userspace only.
#
# Defaults are relative to the cloned repository:
#   STOCK_IMG_XZ=../build/downloads/radxa-cubie-a5e_bullseye_cli_r7.output_512.img.xz
#   WORKDIR=../build
#   ROOTFS_DIR=../build/rootfs
#   TARGET_DEVICE=/dev/sdb
#
# WARNING:
#   This wipes TARGET_DEVICE.
#

set -euo pipefail
IFS=$'\n\t'

BASE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$BASE_SCRIPT_DIR/.." && pwd)"

STOCK_IMG_XZ="${STOCK_IMG_XZ:-$PROJECT_ROOT/build/downloads/radxa-cubie-a5e_bullseye_cli_r7.output_512.img.xz}"
WORKDIR="${WORKDIR:-$PROJECT_ROOT/build}"
ROOTFS_DIR="${ROOTFS_DIR:-$WORKDIR/rootfs}"
TARGET_DEVICE="${TARGET_DEVICE:-${BOOT_DEVICE:-/dev/sdb}}"
OFFICIAL_KERNEL_VERSION="${OFFICIAL_KERNEL_VERSION:-5.15.147-20-aw2501}"
CONFIRM_WRITE="${CONFIRM_WRITE:-0}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-cubie-a5e}"
TIMEZONE="${TIMEZONE:-Asia/Dubai}"

BOOT_PAYLOAD_DIR="${BOOT_PAYLOAD_DIR:-$WORKDIR/official-boot-payload}"
RADXA_CLI_TAR="${RADXA_CLI_TAR:-$WORKDIR/radxa-cli-payload.tar}"
MNT_ROOT="${MNT_ROOT:-$WORKDIR/mnt/official-root}"
TARGET_APT_INSTALL="${TARGET_APT_INSTALL:-0}"
TARGET_RUNTIME_PRESEED="${TARGET_RUNTIME_PRESEED:-0}"
TARGET_RUNTIME_PRESEED_STRICT="${TARGET_RUNTIME_PRESEED_STRICT:-0}"
TARGET_RUNTIME_PACKAGES="${TARGET_RUNTIME_PACKAGES:-bash-completion dialog device-tree-compiler kmod ncurses-base ncurses-bin rfkill u-boot-menu whiptail wireless-regdb}"
RSETUP_TUI_TERM="${RSETUP_TUI_TERM:-xterm-256color}"
RSETUP_NEWT_COLORS="${RSETUP_NEWT_COLORS:-root=white,blue window=white,blue border=white,blue title=white,blue textbox=white,blue button=black,cyan actbutton=white,blue checkbox=white,blue actcheckbox=black,cyan entry=black,cyan label=white,blue listbox=white,blue actlistbox=black,cyan}"

log() {
    printf '\n[*] %s\n' "$*"
}

warn() {
    printf '\n[!] %s\n' "$*" >&2
}

fail() {
    printf '\n[x] %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command missing: $1"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Run as root, for example: sudo WORKDIR=$WORKDIR TARGET_DEVICE=$TARGET_DEVICE $0"
    fi
}

require_safe_target() {
    [ -b "$TARGET_DEVICE" ] || fail "Target block device not found: $TARGET_DEVICE"

    case "$TARGET_DEVICE" in
        /dev/sda|/dev/nvme0n1)
            fail "Refusing dangerous default host disk target: $TARGET_DEVICE"
            ;;
    esac

    if findmnt -n -S "$TARGET_DEVICE" >/dev/null 2>&1; then
        fail "$TARGET_DEVICE itself is mounted. Unmount it first."
    fi
}

show_target_summary() {
    log "Target device summary"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "$TARGET_DEVICE" || true
}

confirm_or_fail() {
    if [ "$CONFIRM_WRITE" = "1" ]; then
        return 0
    fi

    warn "This will overwrite $TARGET_DEVICE with the official Radxa image, then replace partition 3."
    read -r -p "Type I-UNDERSTAND to continue: " answer
    [ "$answer" = "I-UNDERSTAND" ] || fail "Confirmation not given."
}

install_host_deps() {
    local missing=()
    local packages=(xz-utils util-linux parted cloud-guest-utils e2fsprogs rsync kmod)
    local pkg

    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        log "Installing missing host packages: ${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

validate_inputs() {
    [ -f "$STOCK_IMG_XZ" ] || fail "Official image not found: $STOCK_IMG_XZ"
    [ -d "$ROOTFS_DIR" ] || fail "Prepared rootfs directory not found: $ROOTFS_DIR"
    [ -d "$ROOTFS_DIR/etc" ] || fail "Rootfs does not look valid, missing: $ROOTFS_DIR/etc"

    need_command xzcat
    need_command dd
    need_command lsblk
    need_command findmnt
    need_command partprobe
    need_command growpart
    need_command mkfs.ext4
    need_command blkid
    need_command rsync
    need_command tar
    need_command mount
    need_command umount
    need_command sed
    need_command awk
}

prepare_target_chroot_mounts() {
    install -d -m 0755 "$MNT_ROOT/dev" "$MNT_ROOT/dev/pts" "$MNT_ROOT/proc" "$MNT_ROOT/sys" "$MNT_ROOT/run"

    mountpoint -q "$MNT_ROOT/dev" || mount --bind /dev "$MNT_ROOT/dev"
    mountpoint -q "$MNT_ROOT/dev/pts" || mount --bind /dev/pts "$MNT_ROOT/dev/pts"
    mountpoint -q "$MNT_ROOT/proc" || mount -t proc proc "$MNT_ROOT/proc"
    mountpoint -q "$MNT_ROOT/sys" || mount -t sysfs sysfs "$MNT_ROOT/sys"
    mountpoint -q "$MNT_ROOT/run" || mount -t tmpfs tmpfs "$MNT_ROOT/run"

    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "$MNT_ROOT/etc/resolv.conf"
    fi

    if [ ! -e "$MNT_ROOT/usr/bin/qemu-aarch64-static" ] && command -v qemu-aarch64-static >/dev/null 2>&1; then
        install -d -m 0755 "$MNT_ROOT/usr/bin"
        cp "$(command -v qemu-aarch64-static)" "$MNT_ROOT/usr/bin/qemu-aarch64-static"
    fi
}

cleanup_target_chroot_mounts() {
    umount -R "$MNT_ROOT/run" 2>/dev/null || true
    umount -R "$MNT_ROOT/sys" 2>/dev/null || true
    umount -R "$MNT_ROOT/proc" 2>/dev/null || true
    umount -R "$MNT_ROOT/dev/pts" 2>/dev/null || true
    umount -R "$MNT_ROOT/dev" 2>/dev/null || true
}

run_target_chroot() {
    local command_text="$1"

    # Preferred path when binfmt_misc is available on the build host.
    if chroot "$MNT_ROOT" /bin/bash -c "$command_text"; then
        return 0
    fi

    # Fallback path for hosts where binfmt_misc is not registered/enabled.
    # qemu-aarch64-static is copied into the target rootfs by
    # prepare_target_chroot_mounts(). Executing qemu directly avoids depending
    # on host binfmt registration.
    if [ -x "$MNT_ROOT/usr/bin/qemu-aarch64-static" ]; then
        chroot "$MNT_ROOT" /usr/bin/qemu-aarch64-static /bin/bash -c "$command_text"
        return $?
    fi

    return 1
}

partition_path() {
    local disk="$1"
    local partno="$2"

    case "$disk" in
        /dev/nvme*n*|/dev/mmcblk*|/dev/loop*)
            printf '%sp%s\n' "$disk" "$partno"
            ;;
        *)
            printf '%s%s\n' "$disk" "$partno"
            ;;
    esac
}

unmount_target_partitions() {
    local part

    log "Unmounting any mounted target partitions"
    for part in "$(partition_path "$TARGET_DEVICE" 1)" "$(partition_path "$TARGET_DEVICE" 2)" "$(partition_path "$TARGET_DEVICE" 3)"; do
        if [ -e "$part" ]; then
            umount -R "$part" 2>/dev/null || true
        fi
    done

    umount -R "$MNT_ROOT" 2>/dev/null || true
}

cleanup() {
    cleanup_target_chroot_mounts
    umount -R "$MNT_ROOT" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

write_official_image() {
    log "Writing full official Radxa image to $TARGET_DEVICE"
    xzcat "$STOCK_IMG_XZ" | dd of="$TARGET_DEVICE" bs=4M status=progress conv=fsync
    sync

    log "Asking kernel to reread partition table"
    partprobe "$TARGET_DEVICE" || true
    blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2

    log "Layout after official image write"
    lsblk -f "$TARGET_DEVICE"
}


copy_radxa_exact_path() {
    local rel_path
    local src_path
    local dst_path

    rel_path="${1#/}"
    [ -n "$rel_path" ] || return 0

    src_path="$MNT_ROOT/$rel_path"
    [ -e "$src_path" ] || [ -L "$src_path" ] || return 0

    dst_path="$BOOT_PAYLOAD_DIR/radxa-cli/files/$rel_path"
    mkdir -p "$(dirname "$dst_path")"

    if [ -d "$src_path" ] && [ ! -L "$src_path" ]; then
        mkdir -p "$dst_path"
        rsync -aHAX --numeric-ids "$src_path/" "$dst_path/"
    else
        rsync -aHAX --numeric-ids "$src_path" "$dst_path"
    fi
}

copy_radxa_package_payload_from_list() {
    local pkg="$1"
    local list_file="$MNT_ROOT/var/lib/dpkg/info/${pkg}.list"
    local rel_path
    local src_path

    [ -f "$list_file" ] || return 0

    log "Capturing official package payload paths from donor: ${pkg}"

    while IFS= read -r rel_path; do
        [ -n "$rel_path" ] || continue
        case "$rel_path" in
            /.|/usr|/usr/share|/usr/lib|/lib|/etc|/boot|/var|/var/lib|/var/lib/dpkg|/var/lib/dpkg/info)
                continue
                ;;
            /usr/share/doc/*|/usr/share/man/*|/usr/share/lintian/*|/usr/share/icons/*|/usr/share/applications/*)
                continue
                ;;
        esac

        src_path="$MNT_ROOT/${rel_path#/}"
        [ -e "$src_path" ] || [ -L "$src_path" ] || continue
        copy_radxa_exact_path "$rel_path"
    done < "$list_file"
}

capture_radxa_cli_payload() {
    local dpkg_info_dir
    local pkg
    local captured_count

    log "Capturing exact CLI-only Radxa rsetup payload from official rootfs"

    rm -rf "$BOOT_PAYLOAD_DIR/radxa-cli"
    mkdir -p "$BOOT_PAYLOAD_DIR/radxa-cli/files"
    mkdir -p "$BOOT_PAYLOAD_DIR/radxa-cli/package-lists"

    dpkg_info_dir="$MNT_ROOT/var/lib/dpkg/info"

    # Exact paths confirmed from the official Radxa Cubie A5E CLI donor image.
    # Keep this intentionally narrow and headless.
    copy_radxa_exact_path "/usr/bin/rsetup"
    copy_radxa_exact_path "/usr/lib/rsetup"
    copy_radxa_exact_path "/usr/lib/librtui"
    copy_radxa_exact_path "/lib/systemd/system/rsetup-aic8800-reset@.service"
    copy_radxa_exact_path "/lib/systemd/system/rsetup-hciattach@.service"
    copy_radxa_exact_path "/lib/systemd/system/rsetup.service"
    copy_radxa_exact_path "/usr/share/bash-completion/completions/rsetup"

    # rsetup Overlays menu depends on the same u-boot-menu/default config
    # environment used by the official image. Preserve it from the donor when
    # present instead of inventing board-specific values later.
    copy_radxa_exact_path "/etc/default/u-boot"
    copy_radxa_exact_path "/usr/sbin/u-boot-update"
    copy_radxa_exact_path "/usr/bin/u-boot-update"
    copy_radxa_exact_path "/usr/share/u-boot-menu"
    copy_radxa_exact_path "/etc/kernel/postinst.d/u-boot-menu"
    copy_radxa_exact_path "/etc/kernel/postrm.d/u-boot-menu"
    copy_radxa_exact_path "/boot/dtbo"
    copy_radxa_exact_path "/boot/dtb/overlay"
    copy_radxa_exact_path "/boot/overlays"

    # IMPORTANT BOOT-SAFETY RULE:
    # Do not copy broad Radxa package payloads from donor dpkg .list files.
    # Those lists can include boot-critical userspace files from the Bullseye
    # donor, such as systemd or libraries, and overwriting Debian 13 PID1
    # causes early kernel panic: Attempted to kill init, exitcode 127.
    # Keep the payload intentionally narrow: exact rsetup/librtui paths, exact
    # u-boot-menu helper/config paths, and exact overlay directories only.

    # These config packages are CLI/system support only. Copy their package
    # payloads from the official dpkg lists when present, but skip docs and
    # desktop launchers.
    if [ -d "$dpkg_info_dir" ]; then
        for pkg in \
            rsetup \
            rsetup-config-aic8800-ttyas1 \
            rsetup-config-first-boot \
            librtui \
            radxa-system-config-common \
            radxa-system-config-bullseye \
            radxa-system-config-allwinner; do
            if [ -f "$dpkg_info_dir/${pkg}.list" ]; then
                log "Saving official package metadata: ${pkg}"
                cp -a "$dpkg_info_dir/${pkg}.list" "$BOOT_PAYLOAD_DIR/radxa-cli/package-lists/${pkg}.list"
                [ -f "$dpkg_info_dir/${pkg}.md5sums" ] && cp -a "$dpkg_info_dir/${pkg}.md5sums" "$BOOT_PAYLOAD_DIR/radxa-cli/package-lists/${pkg}.md5sums"
            else
                warn "Radxa package list not present in donor: ${pkg}.list"
            fi
        done
    else
        warn "Official dpkg info directory not found at $dpkg_info_dir"
    fi

    captured_count="$(find "$BOOT_PAYLOAD_DIR/radxa-cli/files" \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$captured_count" -gt 0 ]; then
        log "Captured Radxa CLI payload file count: $captured_count"
        log "Captured Radxa CLI payload paths:"
        find "$BOOT_PAYLOAD_DIR/radxa-cli/files" -mindepth 1 -maxdepth 10 \
            \( -iname '*rsetup*' -o -iname '*librtui*' -o -path '*/usr/lib/rsetup/*' -o -path '*/usr/lib/librtui/*' \) \
            2>/dev/null | sed "s#^$BOOT_PAYLOAD_DIR/radxa-cli/files##" | sort | sed -n '1,300p'
        log "Creating durable Radxa CLI payload archive: $RADXA_CLI_TAR"
        tar -C "$BOOT_PAYLOAD_DIR/radxa-cli/files" -cpf "$RADXA_CLI_TAR" .
        log "Radxa CLI payload archive created"
    else
        warn "No Radxa CLI rsetup payload was captured from the official image"
    fi
}

install_radxa_cli_payload() {
    local payload_dir
    local target
    local found_cmd
    local rel_found

    payload_dir="$BOOT_PAYLOAD_DIR/radxa-cli/files"

    log "Installing CLI-only Radxa rsetup payload into target rootfs"
    if [ -f "$RADXA_CLI_TAR" ]; then
        log "Restoring Radxa CLI payload from archive: $RADXA_CLI_TAR"
        tar -C "$MNT_ROOT" -xpf "$RADXA_CLI_TAR"
    elif [ -d "$payload_dir" ] && find "$payload_dir" \( -type f -o -type l \) 2>/dev/null | grep -q .; then
        log "Restoring Radxa CLI payload from directory: $payload_dir"
        rsync -aHAX --numeric-ids "$payload_dir/" "$MNT_ROOT/"
    else
        warn "Skipping rsetup install: no Radxa CLI payload captured"
        return 0
    fi

    # Restore package metadata for the copied Radxa CLI packages when available.
    # This makes later dpkg inspection sane, but does not run postinst scripts.
    if [ -d "$BOOT_PAYLOAD_DIR/radxa-cli/package-lists" ]; then
        mkdir -p "$MNT_ROOT/var/lib/dpkg/info"
        rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/radxa-cli/package-lists/" "$MNT_ROOT/var/lib/dpkg/info/" || true
    fi

    for target in \
        "$MNT_ROOT/usr/bin/rsetup" \
        "$MNT_ROOT/usr/sbin/rsetup" \
        "$MNT_ROOT/usr/local/bin/rsetup" \
        "$MNT_ROOT/usr/local/sbin/rsetup"; do
        if [ -e "$target" ] || [ -L "$target" ]; then
            chmod 0755 "$target" 2>/dev/null || true
        fi
    done

    if [ ! -e "$MNT_ROOT/usr/bin/rsetup" ] \
        && [ ! -e "$MNT_ROOT/usr/sbin/rsetup" ] \
        && [ ! -e "$MNT_ROOT/usr/local/bin/rsetup" ] \
        && [ ! -e "$MNT_ROOT/usr/local/sbin/rsetup" ]; then
        found_cmd="$(find "$MNT_ROOT" -xdev \( -type f -o -type l \) -name 'rsetup' 2>/dev/null | sort | head -n 1 || true)"
        if [ -n "$found_cmd" ]; then
            rel_found="/${found_cmd#"$MNT_ROOT/"}"
            log "Creating /usr/local/bin/rsetup symlink to discovered command: $rel_found"
            mkdir -p "$MNT_ROOT/usr/local/bin"
            ln -sfn "$rel_found" "$MNT_ROOT/usr/local/bin/rsetup"
        fi
    fi

    if [ -e "$MNT_ROOT/usr/bin/rsetup" ] \
        || [ -e "$MNT_ROOT/usr/sbin/rsetup" ] \
        || [ -e "$MNT_ROOT/usr/local/bin/rsetup" ] \
        || [ -e "$MNT_ROOT/usr/local/sbin/rsetup" ]; then
        log "rsetup CLI present in target rootfs"
        find "$MNT_ROOT" -xdev \( -name 'rsetup' -o -name 'rsetup-*' -o -name 'librtui' -o -path '*/rsetup/*' -o -path '*/librtui/*' \) \
            2>/dev/null | sed "s#^$MNT_ROOT##" | sort | sed -n '1,260p'
    else
        warn "rsetup package payload copied, but no rsetup command was found in target"
        warn "Inspect $BOOT_PAYLOAD_DIR/radxa-cli/files for actual payload paths"
    fi

    # Keep the image headless: do not enable any rsetup GUI/session units here.
    log "rsetup payload installed. Runtime service enablement intentionally skipped."
}

capture_official_boot_payload() {
    local root_part
    local official_boot_dir
    local official_dtb_dir
    local official_modules_dir
    local official_firmware_dir
    local official_usr_firmware_dir

    root_part="$(partition_path "$TARGET_DEVICE" 3)"
    [ -b "$root_part" ] || fail "Expected root partition missing after official image write: $root_part"

    rm -rf "$BOOT_PAYLOAD_DIR"
    mkdir -p "$BOOT_PAYLOAD_DIR/boot"
    mkdir -p "$BOOT_PAYLOAD_DIR/usr-lib-linux-image"
    mkdir -p "$BOOT_PAYLOAD_DIR/lib-modules"
    mkdir -p "$BOOT_PAYLOAD_DIR/lib-firmware"
    mkdir -p "$BOOT_PAYLOAD_DIR/usr-lib-firmware"
    mkdir -p "$BOOT_PAYLOAD_DIR/radxa-cli/files"
    mkdir -p "$MNT_ROOT"

    log "Capturing official /boot and DTB payload from $root_part"
    mount "$root_part" "$MNT_ROOT"

    official_boot_dir="$MNT_ROOT/boot"
    official_dtb_dir="$MNT_ROOT/usr/lib/linux-image-$OFFICIAL_KERNEL_VERSION"
    official_modules_dir="$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION"
    official_firmware_dir="$MNT_ROOT/lib/firmware"
    official_usr_firmware_dir="$MNT_ROOT/usr/lib/firmware"

    [ -f "$official_boot_dir/extlinux/extlinux.conf" ] || fail "Official extlinux.conf not found at $official_boot_dir/extlinux/extlinux.conf"
    [ -d "$official_dtb_dir" ] || fail "Official DTB directory not found at $official_dtb_dir"
    [ -d "$official_modules_dir" ] || fail "Official kernel modules directory not found at $official_modules_dir"
    if [ ! -d "$official_firmware_dir" ] && [ ! -d "$official_usr_firmware_dir" ]; then
        fail "Official firmware directory not found at $official_firmware_dir or $official_usr_firmware_dir"
    fi

    ROOT_UUID="$(blkid -s UUID -o value "$root_part")"
    [ -n "$ROOT_UUID" ] || fail "Could not read official root UUID from $root_part"

    log "Official root UUID: $ROOT_UUID"
    log "Official extlinux.conf:"
    sed -n '1,160p' "$official_boot_dir/extlinux/extlinux.conf"

    log "Capturing official /boot"
    rsync -aHAX --numeric-ids "$official_boot_dir/" "$BOOT_PAYLOAD_DIR/boot/"

    log "Capturing official DTB directory used by extlinux fdtdir"
    rsync -aHAX --numeric-ids "$official_dtb_dir/" "$BOOT_PAYLOAD_DIR/usr-lib-linux-image/"

    log "Capturing official kernel modules for $OFFICIAL_KERNEL_VERSION"
    rsync -aHAX --numeric-ids "$official_modules_dir/" "$BOOT_PAYLOAD_DIR/lib-modules/"

    log "Capturing official firmware, including Wi-Fi/BT firmware"
    if [ -d "$official_firmware_dir" ]; then
        rsync -aHAX --numeric-ids "$official_firmware_dir/" "$BOOT_PAYLOAD_DIR/lib-firmware/"
    fi
    if [ -d "$official_usr_firmware_dir" ]; then
        rsync -aHAX --numeric-ids "$official_usr_firmware_dir/" "$BOOT_PAYLOAD_DIR/usr-lib-firmware/"
    fi
    if ! find "$BOOT_PAYLOAD_DIR/lib-firmware" "$BOOT_PAYLOAD_DIR/usr-lib-firmware" \( -path '*aic8800*' -o -path '*AIC8800*' -o -iname '*8800d80*' -o -iname '*fw_patch_table*' -o -iname '*aic*' \) -print -quit | grep -q .; then
        fail "AIC8800 firmware was not captured from official donor image"
    fi

    capture_radxa_cli_payload

    umount "$MNT_ROOT"
}

expand_root_partition() {
    log "Expanding partition 3 to fill $TARGET_DEVICE"
    growpart "$TARGET_DEVICE" 3 || warn "growpart reported no change or failed; continuing to format existing partition 3"
    partprobe "$TARGET_DEVICE" || true
    blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
}

format_root_partition_preserving_uuid() {
    local root_part

    root_part="$(partition_path "$TARGET_DEVICE" 3)"
    [ -b "$root_part" ] || fail "Root partition missing: $root_part"
    [ -n "${ROOT_UUID:-}" ] || fail "ROOT_UUID was not captured before formatting"

    log "Formatting $root_part as ext4 label=rootfs while preserving UUID=$ROOT_UUID"
    mkfs.ext4 -F -L rootfs -U "$ROOT_UUID" "$root_part"
}

copy_debian_rootfs() {
    local root_part

    root_part="$(partition_path "$TARGET_DEVICE" 3)"
    mkdir -p "$MNT_ROOT"

    log "Copying Debian rootfs from $ROOTFS_DIR to $root_part"
    mount "$root_part" "$MNT_ROOT"

    rsync -aHAX --numeric-ids --info=progress2 \
        --exclude='/proc/*' \
        --exclude='/sys/*' \
        --exclude='/dev/*' \
        --exclude='/run/*' \
        --exclude='/tmp/*' \
        "$ROOTFS_DIR/" "$MNT_ROOT/"

    normalize_target_usrmerge_links

    log "Restoring official Radxa /boot payload"
    mkdir -p "$MNT_ROOT/boot"
    rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/boot/" "$MNT_ROOT/boot/"

    log "Restoring official Radxa DTB directory used by fdtdir"
    mkdir -p "$MNT_ROOT/usr/lib/linux-image-$OFFICIAL_KERNEL_VERSION"
    rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/usr-lib-linux-image/" "$MNT_ROOT/usr/lib/linux-image-$OFFICIAL_KERNEL_VERSION/"

    log "Restoring official Radxa kernel modules"
    # Kernel/userspace module lookup is conservative here on purpose.
    # The running kernel and depmod use /lib/modules/<version>. Some usr-merged
    # Debian layouts also expose /usr/lib/modules/<version>. Restore to both
    # real locations when they are distinct so Wi-Fi drivers are available no
    # matter how the rootfs merge state was produced by debootstrap.
    mkdir -p "$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION"
    rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/lib-modules/" "$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION/"

    mkdir -p "$MNT_ROOT/usr/lib/modules/$OFFICIAL_KERNEL_VERSION"
    if [ "$(readlink -f "$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION" 2>/dev/null || true)" != "$(readlink -f "$MNT_ROOT/usr/lib/modules/$OFFICIAL_KERNEL_VERSION" 2>/dev/null || true)" ]; then
        rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/lib-modules/" "$MNT_ROOT/usr/lib/modules/$OFFICIAL_KERNEL_VERSION/"
    fi

    if [ ! -d "$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION" ]; then
        fail "Official kernel module restore failed for /lib/modules/$OFFICIAL_KERNEL_VERSION"
    fi

    restore_official_firmware_strict

    install_radxa_cli_payload
    install_target_runtime_packages
    install_rsetup_overlay_boot_config
    install_minimal_board_fixes
    install_radxa_wifi_module_autoload
    disable_non_required_failed_units
    validate_rsetup_and_runtime_tools

    if command -v depmod >/dev/null 2>&1; then
        log "Refreshing module dependency metadata inside target rootfs"
        depmod -b "$MNT_ROOT" "$OFFICIAL_KERNEL_VERSION" || warn "depmod failed; preserved official module metadata remains in place"
    else
        warn "Host depmod command missing; skipping module dependency refresh"
    fi

    log "Final official extlinux.conf inside new Debian rootfs"
    sed -n '1,160p' "$MNT_ROOT/boot/extlinux/extlinux.conf"

    sync
    umount "$MNT_ROOT"
}



normalize_target_usrmerge_links() {
    local path
    local link_target

    log "Normalizing Debian 13 merged-/usr layout"

    install -d -m 0755 "$MNT_ROOT/usr/bin" "$MNT_ROOT/usr/sbin" "$MNT_ROOT/usr/lib"

    # Convert absolute usr-merge symlinks to relative links so host-side copy
    # and validation never escape $MNT_ROOT.
    for path in bin sbin lib lib64; do
        if [ -L "$MNT_ROOT/$path" ]; then
            link_target="$(readlink "$MNT_ROOT/$path")"
            case "$path:$link_target" in
                bin:/usr/bin)
                    rm -f "$MNT_ROOT/bin"
                    ln -s usr/bin "$MNT_ROOT/bin"
                    ;;
                sbin:/usr/sbin)
                    rm -f "$MNT_ROOT/sbin"
                    ln -s usr/sbin "$MNT_ROOT/sbin"
                    ;;
                lib:/usr/lib)
                    rm -f "$MNT_ROOT/lib"
                    ln -s usr/lib "$MNT_ROOT/lib"
                    ;;
                lib64:/usr/lib64)
                    rm -f "$MNT_ROOT/lib64"
                    ln -s usr/lib64 "$MNT_ROOT/lib64"
                    ;;
            esac
        fi
    done

    # Debian 13 requires merged-/usr. If the prepared rootfs still has a real
    # /bin, /sbin, or /lib, move its contents into /usr and replace it with the
    # correct relative symlink. This also fixes apt warnings such as:
    #   W: /lib resolved to a different inode than /usr/lib
    if [ -d "$MNT_ROOT/bin" ] && [ ! -L "$MNT_ROOT/bin" ]; then
        rsync -aHAX --numeric-ids "$MNT_ROOT/bin/" "$MNT_ROOT/usr/bin/"
        rm -rf "${MNT_ROOT:?}/bin"
    fi
    ln -sfn usr/bin "$MNT_ROOT/bin"

    if [ -d "$MNT_ROOT/sbin" ] && [ ! -L "$MNT_ROOT/sbin" ]; then
        rsync -aHAX --numeric-ids "$MNT_ROOT/sbin/" "$MNT_ROOT/usr/sbin/"
        rm -rf "$MNT_ROOT/sbin"
    fi
    ln -sfn usr/sbin "$MNT_ROOT/sbin"

    if [ -d "$MNT_ROOT/lib" ] && [ ! -L "$MNT_ROOT/lib" ]; then
        # /lib/modules is special during this hybrid build. It may be a real
        # directory from the prepared rootfs or a symlink created by an earlier
        # helper. Copy real module payloads into /usr/lib/modules first, then
        # exclude modules from the generic /lib -> /usr/lib rsync so rsync does
        # not try to replace an existing non-empty /usr/lib/modules directory
        # with a symlink named modules.
        if [ -d "$MNT_ROOT/lib/modules" ] && [ ! -L "$MNT_ROOT/lib/modules" ]; then
            install -d -m 0755 "$MNT_ROOT/usr/lib/modules"
            rsync -aHAX --numeric-ids "$MNT_ROOT/lib/modules/" "$MNT_ROOT/usr/lib/modules/"
        fi
        if [ -L "$MNT_ROOT/lib/modules" ]; then
            rm -f "$MNT_ROOT/lib/modules"
        fi
        rsync -aHAX --numeric-ids --exclude='/modules' "$MNT_ROOT/lib/" "$MNT_ROOT/usr/lib/"
        rm -rf "${MNT_ROOT:?}/lib"
    fi
    ln -sfn usr/lib "$MNT_ROOT/lib"

    if [ -e "$MNT_ROOT/lib64" ] || [ -d "$MNT_ROOT/usr/lib64" ]; then
        install -d -m 0755 "$MNT_ROOT/usr/lib64"
        if [ -d "$MNT_ROOT/lib64" ] && [ ! -L "$MNT_ROOT/lib64" ]; then
            rsync -aHAX --numeric-ids "$MNT_ROOT/lib64/" "$MNT_ROOT/usr/lib64/"
            rm -rf "${MNT_ROOT:?}/lib64"
        fi
        ln -sfn usr/lib64 "$MNT_ROOT/lib64"
    fi

    [ "$(readlink "$MNT_ROOT/bin")" = "usr/bin" ] || fail "Target /bin is not merged to usr/bin"
    [ "$(readlink "$MNT_ROOT/sbin")" = "usr/sbin" ] || fail "Target /sbin is not merged to usr/sbin"
    [ "$(readlink "$MNT_ROOT/lib")" = "usr/lib" ] || fail "Target /lib is not merged to usr/lib"
}

restore_official_firmware_strict() {
    local required_fw

    log "Restoring official Radxa firmware"

    required_fw="aic8800_fw/SDIO/aic8800D80/fw_patch_table_8800d80_u02.bin"

    normalize_target_usrmerge_links

    install -d -m 0755 "$MNT_ROOT/usr/lib/firmware"

    if [ -d "$BOOT_PAYLOAD_DIR/lib-firmware" ]; then
        rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/lib-firmware/" "$MNT_ROOT/usr/lib/firmware/"
    fi

    if [ -d "$BOOT_PAYLOAD_DIR/usr-lib-firmware" ]; then
        rsync -aHAX --numeric-ids "$BOOT_PAYLOAD_DIR/usr-lib-firmware/" "$MNT_ROOT/usr/lib/firmware/"
    fi

    if [ ! -f "$MNT_ROOT/usr/lib/firmware/$required_fw" ]; then
        fail "AIC8800 firmware missing from final target path: /usr/lib/firmware/$required_fw"
    fi

    # The vendor AIC8800 driver asks the kernel firmware loader for
    # /lib/firmware/..., so /lib must be the Debian 13 merged-/usr symlink.
    # Do not keep a second real /lib tree.
    if [ ! -L "$MNT_ROOT/lib" ] || [ "$(readlink "$MNT_ROOT/lib")" != "usr/lib" ]; then
        fail "Target /lib is not the Debian 13 merged-/usr symlink: /lib -> usr/lib"
    fi

    if [ ! -f "$MNT_ROOT/lib/firmware/$required_fw" ]; then
        fail "AIC8800 firmware missing from runtime driver path via merged /lib: /lib/firmware/$required_fw"
    fi

    log "Final AIC/Radxa firmware examples from runtime /lib/firmware:"
    find "$MNT_ROOT/lib/firmware" \
        \( -path '*aic8800_fw*' -o -path '*AIC8800*' -o -iname '*8800d80*' -o -iname '*fw_patch_table*' -o -iname '*aic*' \) \
        2>/dev/null | sort | sed -n '1,80p'

    log "Required runtime firmware present: /lib/firmware/$required_fw"
}
preseed_runtime_packages_without_chroot() {
    local apt_state
    local apt_lists
    local apt_cache
    local status_file
    local deb
    local sources_list
    local source_parts
    local target_suite
    local deb_count
    local pkg_name
    local -a runtime_packages
    local -a apt_common_opts

    IFS=' ' read -r -a runtime_packages <<< "$TARGET_RUNTIME_PACKAGES"
    if [ "${#runtime_packages[@]}" -eq 0 ]; then
        fail "TARGET_RUNTIME_PACKAGES is empty; cannot preseed runtime tools"
    fi

    if [ "$TARGET_RUNTIME_PRESEED" != "1" ]; then
        warn "Skipping no-chroot runtime package preseed because TARGET_RUNTIME_PRESEED=$TARGET_RUNTIME_PRESEED"
        return 0
    fi

    if runtime_tools_present_in_target; then
        log "Required runtime tools already present in rootfs"
        return 0
    fi

    log "Preseeding runtime packages into target rootfs without ARM64 chroot"

    need_command dpkg-deb
    need_command apt-get

    status_file="$MNT_ROOT/var/lib/dpkg/status"
    if [ ! -s "$status_file" ]; then
        fail "Target dpkg status is missing or empty: $status_file"
    fi

    apt_state="$WORKDIR/apt-arm64-state"
    apt_lists="$apt_state/lists"
    apt_cache="$WORKDIR/apt-arm64-cache"
    sources_list="$apt_state/debian-runtime.sources.list"
    source_parts="$apt_state/empty-sourceparts"

    rm -rf "$apt_state" "$apt_cache"
    install -d -m 0755 "$apt_state" "$apt_lists" "$apt_lists/partial" "$apt_cache" "$apt_cache/partial" "$source_parts"
    chmod -R a+rX "$apt_state" "$apt_cache" 2>/dev/null || true

    # Use Debian runtime repositories only for Debian 13 package preseed.
    # The donor Radxa Bullseye repositories may be copied into the target for
    # rsetup metadata, but they require Radxa's archive key and are not needed
    # for whiptail/dialog/kmod/rfkill/ncurses/u-boot-menu runtime packages.
    # Point apt to this generated source list and an empty sourceparts dir so
    # copied donor files such as radxa-repo.github.io or local-apt-repository
    # cannot break the build.
    target_suite="trixie"
    if [ -r "$MNT_ROOT/etc/os-release" ]; then
        target_suite="$(sed -n 's/^VERSION_CODENAME=//p' "$MNT_ROOT/etc/os-release" | tr -d '"' | head -n 1)"
        [ -n "$target_suite" ] || target_suite="trixie"
    fi

    cat > "$sources_list" <<EOF
# Generated by InitBox Cubie A5E builder for no-chroot arm64 runtime preseed.
# Intentionally Debian-only. Do not include copied Radxa Bullseye donor repos here.
deb https://deb.debian.org/debian ${target_suite} main contrib non-free non-free-firmware
deb https://deb.debian.org/debian ${target_suite}-updates main contrib non-free non-free-firmware
deb https://deb.debian.org/debian-security ${target_suite}-security main contrib non-free non-free-firmware
EOF

    apt_common_opts=(
        -o APT::Architecture=arm64
        -o APT::Architectures::=arm64
        -o Dir::State="$apt_state"
        -o Dir::State::lists="$apt_lists"
        -o Dir::State::status="$status_file"
        -o Dir::Cache::archives="$apt_cache"
        -o Dir::Etc::sourcelist="$sources_list"
        -o Dir::Etc::sourceparts="$source_parts"
        -o Dir::Etc::main=/dev/null
        -o Dir::Etc::parts=/dev/null
        -o Debug::NoLocking=1
        -o APT::Sandbox::User=root
    )

    if ! apt-get "${apt_common_opts[@]}" update; then
        if [ "$TARGET_RUNTIME_PRESEED_STRICT" = "1" ]; then
            fail "arm64 apt index update failed; cannot preseed required runtime packages"
        fi
        warn "arm64 apt index update failed; cannot preseed runtime packages now."
        return 0
    fi

    if ! apt-get \
        "${apt_common_opts[@]}" \
        --yes \
        --download-only \
        --no-install-recommends \
        install "${runtime_packages[@]}"; then
        if [ "$TARGET_RUNTIME_PRESEED_STRICT" = "1" ]; then
            fail "arm64 runtime package download failed; cannot preseed required runtime packages"
        fi
        warn "arm64 runtime package download failed; cannot preseed runtime packages now."
        return 0
    fi

    deb_count="$(find "$apt_cache" "$apt_state" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$deb_count" -eq 0 ]; then
        if [ "$TARGET_RUNTIME_PRESEED_STRICT" = "1" ]; then
            fail "apt reported success but no arm64 .deb files were downloaded"
        fi
        warn "apt reported success but no arm64 .deb files were downloaded"
        return 0
    fi

    while IFS= read -r deb; do
        pkg_name="$(dpkg-deb -f "$deb" Package 2>/dev/null || basename "$deb" | sed 's/_.*//')"
        case "$pkg_name" in
            base-files|base-passwd|usrmerge|usr-is-merged|libc-bin|libc6|libcrypt1)
                warn "Skipping core filesystem/base package during no-chroot extraction: $(basename "$deb")"
                continue
                ;;
            systemd|systemd-*|libsystemd*|udev|libudev*|dbus|dbus-*|bash|dash|coreutils|login|passwd)
                warn "Skipping boot-critical package during no-chroot extraction: $(basename "$deb")"
                continue
                ;;
        esac

        log "Extracting runtime package: $(basename "$deb")"
        dpkg-deb -x "$deb" "$MNT_ROOT"
    done < <(find "$apt_cache" "$apt_state" -type f -name '*.deb' 2>/dev/null | sort)

    normalize_target_usrmerge_links
    restore_official_firmware_strict

    if [ -x "$MNT_ROOT/usr/bin/lsmod" ] && [ -d "$MNT_ROOT/bin" ] && [ ! -e "$MNT_ROOT/bin/lsmod" ]; then
        ln -sfn ../usr/bin/lsmod "$MNT_ROOT/bin/lsmod" || true
    fi

    if ! runtime_tools_present_in_target; then
        if [ "$TARGET_RUNTIME_PRESEED_STRICT" = "1" ]; then
            fail "Runtime package preseed completed, but required tools are still missing"
        fi
        warn "Runtime package preseed completed, but one or more tools are still missing."
        return 0
    fi

    log "Runtime package preseed completed"
}

runtime_tools_present_in_target() {
    [ -x "$MNT_ROOT/usr/bin/whiptail" ] || return 1
    [ -x "$MNT_ROOT/usr/bin/dialog" ] || return 1
    { [ -x "$MNT_ROOT/usr/bin/lsmod" ] || [ -x "$MNT_ROOT/bin/lsmod" ]; } || return 1
    { [ -x "$MNT_ROOT/usr/sbin/rfkill" ] || [ -x "$MNT_ROOT/usr/bin/rfkill" ] || [ -x "$MNT_ROOT/sbin/rfkill" ]; } || return 1
    return 0
}

install_target_runtime_packages() {
    preseed_runtime_packages_without_chroot

    # v14b: never block image creation on ARM64 chroot/qemu. The build host in
    # the current lab cannot run the target chroot reliably. Keep this as an
    # optional optimization only; first-boot services below install the same
    # runtime packages on the board when network is available.
    if [ "$TARGET_APT_INSTALL" != "1" ]; then
        warn "Skipping target apt install because TARGET_APT_INSTALL=$TARGET_APT_INSTALL"
        warn "Runtime extras will be handled by first-boot helper services."
        return 0
    fi

    log "Attempting optional runtime package install inside target rootfs"
    prepare_target_chroot_mounts

    if ! run_target_chroot 'true' >/dev/null 2>&1; then
        cleanup_target_chroot_mounts
        warn "Cannot run target chroot even with qemu fallback; continuing image build."
        warn "Install on board after boot if needed: apt-get install -y $TARGET_RUNTIME_PACKAGES"
        return 0
    fi

    if ! run_target_chroot "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends $TARGET_RUNTIME_PACKAGES
"; then
        cleanup_target_chroot_mounts
        warn "Optional target apt install failed; continuing image build."
        warn "First-boot helper services remain installed for runtime dependency repair."
        return 0
    fi

    cleanup_target_chroot_mounts
}


install_rsetup_overlay_boot_config() {
    local overlay_dir=""
    local linux_image_dir="$MNT_ROOT/usr/lib/linux-image-$OFFICIAL_KERNEL_VERSION"
    local candidate

    log "Installing rsetup overlay/u-boot support configuration"

    install -d -m 0755 "$MNT_ROOT/etc/default" "$MNT_ROOT/boot" "$MNT_ROOT/usr/sbin"

    # Pick the official donor value if it was captured. If it is absent or
    # empty, use a stable managed overlay directory under /boot. rsetup's
    # overlay-menu path requires U_BOOT_FDT_OVERLAYS_DIR to initialize
    # FDT_OVERLAYS_DIR before it scans overlays.
    if [ -f "$MNT_ROOT/etc/default/u-boot" ]; then
        overlay_dir="$(sed -n -E 's/^U_BOOT_FDT_OVERLAYS_DIR="?([^"# ]+)"?.*$/\1/p' "$MNT_ROOT/etc/default/u-boot" | tail -n 1 || true)"
    fi

    if [ -z "$overlay_dir" ]; then
        overlay_dir="/boot/dtbo"
    fi

    install -d -m 0755 "$MNT_ROOT${overlay_dir}"

    # Seed the managed overlay directory from the official kernel image overlay
    # payload if the donor did not already provide /boot/dtbo. rsetup expects
    # disabled overlays to be available as *.dtbo.disabled.
    if ! find "$MNT_ROOT${overlay_dir}" -maxdepth 1 \( -name '*.dtbo' -o -name '*.dtbo.disabled' \) -print -quit 2>/dev/null | grep -q .; then
        if [ -d "$linux_image_dir" ]; then
            while IFS= read -r candidate; do
                [ -f "$candidate" ] || continue
                cp -a "$candidate" "$MNT_ROOT${overlay_dir}/$(basename "$candidate").disabled" || true
            done < <(find "$linux_image_dir" -type f -path '*/overlays/*.dtbo' 2>/dev/null | sort)
        fi
    fi

    # Ensure /etc/default/u-boot exists and contains the variables rsetup and
    # u-boot-menu need. Preserve existing donor settings and only append safe
    # defaults when missing.
    if [ ! -f "$MNT_ROOT/etc/default/u-boot" ]; then
        cat > "$MNT_ROOT/etc/default/u-boot" <<EOF
# InitBox/Radxa Cubie A5E u-boot-menu configuration preserved for rsetup overlays.
U_BOOT_UPDATE="true"
U_BOOT_ALTERNATIVES="default"
U_BOOT_MENU_LABEL="Debian GNU/Linux"
U_BOOT_TIMEOUT="10"
U_BOOT_FDT_OVERLAYS_DIR="$overlay_dir"
EOF
    else
        if ! grep -q '^U_BOOT_FDT_OVERLAYS_DIR=' "$MNT_ROOT/etc/default/u-boot"; then
            printf '\nU_BOOT_FDT_OVERLAYS_DIR="%s"\n' "$overlay_dir" >> "$MNT_ROOT/etc/default/u-boot"
        fi
        if ! grep -q '^U_BOOT_UPDATE=' "$MNT_ROOT/etc/default/u-boot"; then
            printf 'U_BOOT_UPDATE="true"\n' >> "$MNT_ROOT/etc/default/u-boot"
        fi
        if ! grep -q '^U_BOOT_TIMEOUT=' "$MNT_ROOT/etc/default/u-boot"; then
            printf 'U_BOOT_TIMEOUT="10"\n' >> "$MNT_ROOT/etc/default/u-boot"
        fi
    fi

    # Some Debian u-boot-menu variants provide read-config but not a usable
    # u-boot-update in minimal roots until the package is fully configured. The
    # package preseed normally supplies it; fail here if still absent because
    # rsetup's overlay functions intentionally require command -v u-boot-update.
    if [ ! -x "$MNT_ROOT/usr/sbin/u-boot-update" ] && [ ! -x "$MNT_ROOT/usr/bin/u-boot-update" ]; then
        warn "u-boot-update missing after donor/runtime preseed; rsetup overlays cannot update boot entries."
    fi

    log "rsetup overlay directory configured: ${overlay_dir}"
    find "$MNT_ROOT${overlay_dir}" -maxdepth 1 \( -name '*.dtbo' -o -name '*.dtbo.disabled' \) -print 2>/dev/null | sed -n '1,40p' || true
}

disable_non_required_failed_units() {
    log "Masking non-required failed units for this headless hybrid image"

    install -d -m 0755 "$MNT_ROOT/etc/systemd/system"

    # The Radxa boot chain is preserved outside the Debian userspace rootfs.
    # Do not let Debian's generic EFI automount create a permanent failed unit.
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/efi.mount"

    # binfmt_misc is not required on the board for normal operation and failed
    # on the current runtime log. Mask it to keep systemctl --failed clean.
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/proc-sys-fs-binfmt_misc.mount"
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/systemd-binfmt.service"

    rm -f "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/systemd-binfmt.service" 2>/dev/null || true
    rm -f "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/proc-sys-fs-binfmt_misc.mount" 2>/dev/null || true
}


validate_pid1_runtime_linkage() {
    local systemd_bin
    local interpreter
    local needed
    local lib
    local found
    local linkage_missing=0
    local wrong
    local candidate
    local -a normal_library_roots
    local -a private_systemd_roots

    log "Validating PID1/systemd runtime linkage"

    if [ -x "$MNT_ROOT/usr/lib/systemd/systemd" ]; then
        systemd_bin="$MNT_ROOT/usr/lib/systemd/systemd"
    elif [ -x "$MNT_ROOT/lib/systemd/systemd" ]; then
        systemd_bin="$MNT_ROOT/lib/systemd/systemd"
    else
        fail "PID1 target missing or not executable: /usr/lib/systemd/systemd"
    fi

    if ! file "$systemd_bin" 2>/dev/null | grep -q 'ELF 64-bit'; then
        fail "PID1 target is not a 64-bit ELF binary: ${systemd_bin#$MNT_ROOT}"
    fi

    interpreter="$(readelf -l "$systemd_bin" 2>/dev/null | awk -F': ' '/Requesting program interpreter/ {gsub(/]/, "", $2); print $2; exit}')"
    if [ -z "$interpreter" ]; then
        fail "Missing ARM64 dynamic linker interpreter in ${systemd_bin#$MNT_ROOT}"
    fi

    log "PID1 ELF interpreter: $interpreter"

    case "$interpreter" in
        /lib/ld-linux-aarch64.so.1|/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1|/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1)
            ;;
        *)
            fail "Unexpected ARM64 dynamic linker interpreter in ${systemd_bin#$MNT_ROOT}: $interpreter"
            ;;
    esac

    # Do not rely on host-side absolute symlink resolution here. In a mounted
    # target rootfs, /lib may be a relative usr-merge symlink, and the dynamic
    # linker may also be an absolute target-root symlink. Accept any valid
    # target-side location that can satisfy the interpreter at boot.
    if [ -e "$MNT_ROOT$interpreter" ] || [ -L "$MNT_ROOT$interpreter" ]; then
        :
    elif [ -e "$MNT_ROOT/lib/ld-linux-aarch64.so.1" ] || [ -L "$MNT_ROOT/lib/ld-linux-aarch64.so.1" ]; then
        :
    elif [ -x "$MNT_ROOT/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" ]; then
        :
    else
        fail "Runtime dynamic linker missing for PID1: $interpreter"
    fi

    needed="$(readelf -d "$systemd_bin" 2>/dev/null | sed -n 's/^.*Shared library: \[\([^]]*\)\].*$/\1/p' | sort -u)"
    if [ -z "$needed" ]; then
        fail "Could not read PID1 shared-library requirements from ${systemd_bin#$MNT_ROOT}"
    fi

    log "PID1 direct shared library requirements:"
    printf '%s\n' "$needed" | sed 's/^/[PID1-NEEDED] /'

    if printf '%s\n' "$needed" | grep -Eq 'libsystemd-(core|shared)-247\.so'; then
        fail "Bullseye systemd private library dependency detected in PID1"
    fi

    if printf '%s\n' "$needed" | grep -Eq 'libsystemd-(core|shared)-252\.so'; then
        fail "Bookworm systemd private library dependency detected in PID1"
    fi

    if ! printf '%s\n' "$needed" | grep -q 'libsystemd-core-257\.so'; then
        warn "PID1 does not directly list libsystemd-core-257.so"
        linkage_missing=1
    fi

    if ! printf '%s\n' "$needed" | grep -q 'libsystemd-shared-257\.so'; then
        warn "PID1 does not directly list libsystemd-shared-257.so"
        linkage_missing=1
    fi

    normal_library_roots=(
        "$MNT_ROOT/usr/lib/aarch64-linux-gnu"
        "$MNT_ROOT/lib/aarch64-linux-gnu"
        "$MNT_ROOT/usr/lib"
        "$MNT_ROOT/lib"
    )

    private_systemd_roots=(
        "$MNT_ROOT/usr/lib/aarch64-linux-gnu/systemd"
        "$MNT_ROOT/lib/aarch64-linux-gnu/systemd"
        "$MNT_ROOT/usr/lib/systemd"
        "$MNT_ROOT/lib/systemd"
    )

    find_systemd_private_library() {
        local name="$1"
        local search_root
        local result=""

        for search_root in "${private_systemd_roots[@]}"; do
            [ -d "$search_root" ] || continue
            result="$(find -L "$search_root" -maxdepth 1 -type f -name "$name" -print -quit 2>/dev/null || true)"
            if [ -n "$result" ]; then
                printf '%s\n' "$result"
                return 0
            fi
        done

        # Fallback for package layout changes: still keep it constrained below
        # usr/lib or lib and require a systemd directory component.
        result="$(find -L "$MNT_ROOT/usr/lib" "$MNT_ROOT/lib" -path '*/systemd/*' -type f -name "$name" -print -quit 2>/dev/null || true)"
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        return 1
    }

    find_normal_library() {
        local name="$1"
        local search_root

        for search_root in "${normal_library_roots[@]}"; do
            [ -d "$search_root" ] || continue
            if [ -e "$search_root/$name" ] || [ -L "$search_root/$name" ]; then
                printf '%s\n' "$search_root/$name"
                return 0
            fi
        done

        return 1
    }

    while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        found=""

        case "$lib" in
            libsystemd-core-*.so|libsystemd-shared-*.so)
                found="$(find_systemd_private_library "$lib" || true)"
                ;;
            *)
                found="$(find_normal_library "$lib" || true)"
                ;;
        esac

        if [ -z "$found" ]; then
            warn "Missing PID1 shared library: $lib"
            linkage_missing=1
        else
            log "PID1 shared library found: ${found#$MNT_ROOT}"
        fi
    done <<< "$needed"

    for lib in libsystemd-core-257.so libsystemd-shared-257.so; do
        found="$(find_systemd_private_library "$lib" || true)"
        if [ -z "$found" ]; then
            warn "Missing Debian 13 PID1 private systemd library: $lib"
            linkage_missing=1
        else
            log "Debian 13 PID1 private systemd library present: ${found#$MNT_ROOT}"
        fi
    done

    for wrong in \
        libsystemd-core-247.so \
        libsystemd-shared-247.so \
        libsystemd-core-252.so \
        libsystemd-shared-252.so; do
        found="$(find_systemd_private_library "$wrong" || true)"
        if [ -n "$found" ]; then
            warn "Wrong-generation systemd private library present: ${found#$MNT_ROOT}"
            linkage_missing=1
        fi
    done

    # Guard against the previous donor-pollution failure mode. A copied
    # Bullseye PID1 normally exposes PACKAGE_VERSION=247 metadata or requires
    # private systemd 247 libraries. Keep this as a soft metadata check because
    # some stripped/minimal package layouts may omit the file.
    candidate="$(grep -Rhs '^PACKAGE_VERSION=' \
        "$MNT_ROOT/usr/lib/systemd" \
        "$MNT_ROOT/usr/lib/"*-linux-gnu/systemd \
        "$MNT_ROOT/lib/systemd" \
        "$MNT_ROOT/lib/"*-linux-gnu/systemd \
        2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"' || true)"

    if [ -n "$candidate" ]; then
        log "systemd package version metadata: $candidate"
        case "$candidate" in
            257*)
                ;;
            247*|252*)
                warn "Wrong-generation systemd metadata detected: $candidate"
                linkage_missing=1
                ;;
            *)
                warn "Unexpected systemd metadata version detected: $candidate"
                ;;
        esac
    fi

    if [ "$linkage_missing" -ne 0 ]; then
        fail "PID1/systemd runtime linkage validation failed"
    fi

    log "PID1/systemd runtime linkage validation passed"
}

validate_rsetup_and_runtime_tools() {
    local hard_missing=0
    local item
    local overlay_dir

    log "Validating rsetup payload, firmware, and runtime tools before finalizing image"

    validate_pid1_runtime_linkage

    # Final pass: keep Debian 13 merged-/usr intact after all helper files were
    # added, then re-copy firmware into /usr/lib/firmware. This prevents a late
    # validation false-negative on /lib/firmware while preserving the boot-safe
    # no-preseed policy.
    normalize_target_usrmerge_links
    restore_official_firmware_strict

    for item in \
        "$MNT_ROOT/usr/bin/rsetup" \
        "$MNT_ROOT/usr/lib/rsetup" \
        "$MNT_ROOT/usr/lib/librtui"; do
        if [ ! -e "$item" ]; then
            warn "Missing required copied item: ${item#$MNT_ROOT}"
            hard_missing=1
        fi
    done

    if [ ! -f "$MNT_ROOT/usr/lib/firmware/aic8800_fw/SDIO/aic8800D80/fw_patch_table_8800d80_u02.bin" ]; then
        warn "Missing AIC8800 firmware below /usr/lib/firmware"
        hard_missing=1
    fi

    if [ -L "$MNT_ROOT/lib" ]; then
        log "Target /lib is symlinked; runtime /lib/firmware resolves through usr-merge."
    elif [ ! -f "$MNT_ROOT/lib/firmware/aic8800_fw/SDIO/aic8800D80/fw_patch_table_8800d80_u02.bin" ]; then
        warn "Missing AIC8800 firmware below runtime /lib/firmware"
        hard_missing=1
    fi

    for item in \
        "$MNT_ROOT/usr/bin/whiptail" \
        "$MNT_ROOT/usr/bin/dialog" \
        "$MNT_ROOT/usr/bin/lsmod" \
        "$MNT_ROOT/bin/lsmod" \
        "$MNT_ROOT/usr/sbin/rfkill" \
        "$MNT_ROOT/usr/bin/rfkill" \
        "$MNT_ROOT/sbin/rfkill"; do
        if [ -e "$item" ]; then
            log "Runtime tool present: ${item#$MNT_ROOT}"
        fi
    done

    for item in         "$MNT_ROOT/etc/default/locale"         "$MNT_ROOT/etc/profile.d/initbox-terminal-defaults.sh"         "$MNT_ROOT/etc/profile.d/initbox-rsetup-tui.sh"; do
        if [ ! -e "$item" ]; then
            warn "Missing rsetup TUI default file: ${item#$MNT_ROOT}"
            hard_missing=1
        else
            log "rsetup TUI default present: ${item#$MNT_ROOT}"
        fi
    done

    if [ -e "$MNT_ROOT/usr/local/bin/rsetup" ]; then
        warn "Forbidden rsetup wrapper exists at /usr/local/bin/rsetup"
        hard_missing=1
    fi
    if [ -e "$MNT_ROOT/usr/bin/rsetup.real" ]; then
        warn "Forbidden rsetup.real wrapper state exists"
        hard_missing=1
    fi

    if [ ! -x "$MNT_ROOT/usr/local/bin/whiptail" ]; then
        warn "PuTTY-safe whiptail compatibility wrapper missing at /usr/local/bin/whiptail"
        hard_missing=1
    fi
    if [ ! -f "$MNT_ROOT/etc/initbox/dialogrc" ]; then
        warn "dialog color theme missing at /etc/initbox/dialogrc"
        hard_missing=1
    fi

    if [ ! -f "$MNT_ROOT/etc/default/u-boot" ]; then
        warn "Missing /etc/default/u-boot; rsetup Overlays menu will not initialize FDT_OVERLAYS_DIR."
        hard_missing=1
    elif ! grep -q '^U_BOOT_FDT_OVERLAYS_DIR=' "$MNT_ROOT/etc/default/u-boot"; then
        warn "Missing U_BOOT_FDT_OVERLAYS_DIR in /etc/default/u-boot; rsetup Overlays menu will fail."
        hard_missing=1
    fi

    if [ ! -x "$MNT_ROOT/usr/sbin/u-boot-update" ] && [ ! -x "$MNT_ROOT/usr/bin/u-boot-update" ]; then
        warn "u-boot-update missing; rsetup Overlays menu cannot apply overlay changes until u-boot-menu is installed."
    fi

    overlay_dir="$(grep -E '^U_BOOT_FDT_OVERLAYS_DIR=' "$MNT_ROOT/etc/default/u-boot" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//; s/^"//; s/"$//; s/[[:space:]]*$//' || true)"
    if [ -z "${overlay_dir:-}" ] || [ ! -d "$MNT_ROOT${overlay_dir}" ]; then
        warn "Configured overlay directory missing: ${overlay_dir:-<unset>}"
        hard_missing=1
    fi

    if ! grep -q 'NEWT_COLORS' "$MNT_ROOT/etc/profile.d/initbox-terminal-defaults.sh" 2>/dev/null; then
        warn "rsetup TUI color theme is missing NEWT_COLORS"
        hard_missing=1
    fi
    if ! grep -q 'NCURSES_NO_UTF8_ACS' "$MNT_ROOT/etc/profile.d/initbox-terminal-defaults.sh" 2>/dev/null; then
        warn "rsetup TUI ACS compatibility setting is missing"
        hard_missing=1
    fi

    if [ ! -x "$MNT_ROOT/usr/bin/whiptail" ]; then
        warn "whiptail missing; first-boot dependency service will install it when network is available."
    fi
    if [ ! -x "$MNT_ROOT/usr/bin/dialog" ]; then
        warn "dialog missing; first-boot dependency service will install it when network is available."
    fi
    if [ ! -x "$MNT_ROOT/usr/bin/lsmod" ] && [ ! -x "$MNT_ROOT/bin/lsmod" ]; then
        warn "lsmod/kmod missing; first-boot dependency service will install it when network is available."
    fi
    if [ ! -x "$MNT_ROOT/usr/sbin/rfkill" ] && [ ! -x "$MNT_ROOT/usr/bin/rfkill" ] && [ ! -x "$MNT_ROOT/sbin/rfkill" ]; then
        warn "rfkill missing; first-boot dependency service will install it when network is available."
    fi
    if [ ! -e "$MNT_ROOT/usr/share/terminfo/l/linux" ]; then
        warn "linux terminfo missing; first-boot dependency service will install ncurses-base when network is available."
    fi
    if [ ! -e "$MNT_ROOT/usr/share/terminfo/x/xterm-256color" ]; then
        warn "xterm-256color terminfo missing; first-boot dependency service will install ncurses-base when network is available."
    fi

    if [ "$hard_missing" -ne 0 ]; then
        fail "Final copied-payload/runtime validation failed"
    fi

    log "Copied payload and runtime validation passed"
}

install_rsetup_tui_defaults() {
    log "Installing global rsetup/whiptail terminal defaults without wrapping Radxa rsetup"

    install -d -m 0755 "$MNT_ROOT/etc/default" "$MNT_ROOT/etc/profile.d" "$MNT_ROOT/root"

    # IMPORTANT:
    # Keep the official Radxa /usr/bin/rsetup exactly at /usr/bin/rsetup.
    # Do not rename it, do not move it to rsetup.real, and do not shadow it
    # with /usr/local/bin/rsetup. Radxa rsetup uses its own executable name
    # for internal function dispatch, so wrappers/renames can break it.
    rm -f "$MNT_ROOT/usr/local/bin/rsetup" 2>/dev/null || true
    rm -f "$MNT_ROOT/etc/profile.d/initbox-rsetup-path.sh" 2>/dev/null || true

    if [ -x "$MNT_ROOT/usr/bin/rsetup.real" ]; then
        rm -f "$MNT_ROOT/usr/bin/rsetup"
        mv "$MNT_ROOT/usr/bin/rsetup.real" "$MNT_ROOT/usr/bin/rsetup"
        chmod 0755 "$MNT_ROOT/usr/bin/rsetup"
    fi

    [ -x "$MNT_ROOT/usr/bin/rsetup" ] || fail "Original Radxa /usr/bin/rsetup missing after payload restore"

    cat > "$MNT_ROOT/etc/default/locale" <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF

    cat > "$MNT_ROOT/etc/profile.d/initbox-terminal-defaults.sh" <<EOF
# InitBox/Radxa Cubie A5E terminal defaults.
# Applies globally. Does not wrap, rename, or replace official Radxa rsetup.

export LANG="\${LANG:-C.UTF-8}"
export LC_ALL="\${LC_ALL:-C.UTF-8}"
export NCURSES_NO_UTF8_ACS=1

case "\${TERM:-}" in
    ''|dumb|unknown|ansi)
        export TERM="$RSETUP_TUI_TERM"
        ;;
    vt100|vt220)
        export TERM=linux
        ;;
esac

export NEWT_COLORS='${RSETUP_NEWT_COLORS}'
EOF
    chmod 0644 "$MNT_ROOT/etc/profile.d/initbox-terminal-defaults.sh"

    # Keep compatibility with earlier generated images that referenced this name.
    ln -sfn initbox-terminal-defaults.sh "$MNT_ROOT/etc/profile.d/initbox-rsetup-tui.sh"

    if [ -f "$MNT_ROOT/etc/bash.bashrc" ]; then
        if ! grep -q 'initbox-terminal-defaults.sh' "$MNT_ROOT/etc/bash.bashrc"; then
            cat >> "$MNT_ROOT/etc/bash.bashrc" <<'EOF'

# InitBox/Radxa Cubie A5E terminal defaults for whiptail/rsetup.
if [ -f /etc/profile.d/initbox-terminal-defaults.sh ]; then
    . /etc/profile.d/initbox-terminal-defaults.sh
fi
EOF
        fi
    fi

    cat > "$MNT_ROOT/root/.bashrc" <<'EOF'
# ~/.bashrc for root on InitBox/Radxa Cubie A5E.

if [ -f /etc/profile.d/initbox-terminal-defaults.sh ]; then
    . /etc/profile.d/initbox-terminal-defaults.sh
fi
EOF
    chmod 0644 "$MNT_ROOT/root/.bashrc"

    if [ -f "$MNT_ROOT/etc/login.defs" ]; then
        sed -i 's#^ENV_SUPATH.*#ENV_SUPATH PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin#' "$MNT_ROOT/etc/login.defs" || true
        sed -i 's#^ENV_PATH.*#ENV_PATH PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games#' "$MNT_ROOT/etc/login.defs" || true
    fi
}


install_whiptail_putty_compat_wrapper() {
    log "Installing PuTTY-safe whiptail compatibility wrapper for clean rsetup TUI"

    # Keep official Radxa /usr/bin/rsetup untouched. Only shadow whiptail through
    # /usr/local/bin so rsetup/librtui calls render through dialog with ASCII
    # borders on serial consoles that display newt ACS as lqqq/x/k.
    # This wrapper is installed even when /usr/bin/dialog is not present yet;
    # first-boot dependency setup installs dialog before rsetup is expected to
    # be used interactively.
    [ -x "$MNT_ROOT/usr/bin/rsetup" ] || fail "Original Radxa /usr/bin/rsetup missing"

    install -d -m 0755 "$MNT_ROOT/usr/local/bin"

    cat > "$MNT_ROOT/usr/local/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
# InitBox/Radxa Cubie A5E whiptail compatibility shim.
# Purpose: keep official Radxa rsetup untouched, but render its whiptail menus
# through dialog with ASCII borders. This avoids PuTTY serial showing newt ACS
# line-drawing as lqqq/x/k while keeping colors and menu behavior usable.

set -u

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export TERM="${TERM:-xterm-256color}"
export NCURSES_NO_UTF8_ACS=1

case "${TERM:-}" in
    ''|dumb|unknown|ansi)
        export TERM=xterm-256color
        ;;
esac

export DIALOGRC=/etc/initbox/dialogrc

args=()
for arg in "$@"; do
    case "$arg" in
        --notags)
            args+=(--no-tags)
            ;;
        --fb)
            # whiptail full-button option; dialog does not need it.
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

exec /usr/bin/dialog --ascii-lines "${args[@]}"
EOF
    chmod 0755 "$MNT_ROOT/usr/local/bin/whiptail"

    install -d -m 0755 "$MNT_ROOT/etc/initbox"
    cat > "$MNT_ROOT/etc/initbox/dialogrc" <<'EOF'
# InitBox dialog theme used by /usr/local/bin/whiptail compatibility wrapper.
# Format follows dialog(1) rc color entries: screen, shadow, dialog, title, border,
# button active/inactive, listbox, item, tag, etc.
use_shadow = OFF
use_colors = ON
screen_color = (WHITE,BLUE,ON)
shadow_color = (BLACK,BLACK,OFF)
dialog_color = (WHITE,BLUE,ON)
title_color = (YELLOW,BLUE,ON)
border_color = (CYAN,BLUE,ON)
border2_color = (CYAN,BLUE,ON)
button_active_color = (BLACK,CYAN,ON)
button_inactive_color = (BLACK,WHITE,OFF)
button_key_active_color = (BLACK,CYAN,ON)
button_key_inactive_color = (BLACK,WHITE,OFF)
button_label_active_color = (BLACK,CYAN,ON)
button_label_inactive_color = (BLACK,WHITE,ON)
inputbox_color = (WHITE,BLUE,ON)
inputbox_border_color = (CYAN,BLUE,ON)
searchbox_color = (WHITE,BLUE,ON)
searchbox_title_color = (YELLOW,BLUE,ON)
searchbox_border_color = (CYAN,BLUE,ON)
position_indicator_color = (YELLOW,BLUE,ON)
menubox_color = (WHITE,BLUE,ON)
menubox_border_color = (CYAN,BLUE,ON)
item_color = (WHITE,BLUE,ON)
item_selected_color = (WHITE,RED,ON)
tag_color = (WHITE,BLUE,ON)
tag_selected_color = (YELLOW,RED,ON)
tag_key_color = (WHITE,BLUE,ON)
tag_key_selected_color = (YELLOW,RED,ON)
check_color = (WHITE,BLUE,ON)
check_selected_color = (WHITE,RED,ON)
uarrow_color = (YELLOW,BLUE,ON)
darrow_color = (YELLOW,BLUE,ON)
itemhelp_color = (WHITE,BLUE,ON)
form_active_text_color = (WHITE,RED,ON)
form_text_color = (WHITE,BLUE,ON)
form_item_readonly_color = (CYAN,BLUE,ON)
gauge_color = (WHITE,BLUE,ON)
border_color = (CYAN,BLUE,ON)
EOF
    chmod 0644 "$MNT_ROOT/etc/initbox/dialogrc"
}


install_radxa_wifi_module_autoload() {
    log "Installing Radxa Wi-Fi module autoload helper"

    install -d -m 0755 "$MNT_ROOT/etc/modules-load.d" "$MNT_ROOT/etc/systemd/system" "$MNT_ROOT/usr/local/sbin"

    # Debian 13 usr-merge variants can expose modules through either
    # /lib/modules or /usr/lib/modules. Ensure /lib/modules resolves because
    # modprobe/depmod and many vendor scripts still expect that path.
    if [ ! -e "$MNT_ROOT/lib/modules" ] && [ -d "$MNT_ROOT/usr/lib/modules" ]; then
        install -d -m 0755 "$MNT_ROOT/lib"
        ln -s ../usr/lib/modules "$MNT_ROOT/lib/modules"
    fi

    module_roots=()
    [ -d "$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION" ] && module_roots+=("$MNT_ROOT/lib/modules/$OFFICIAL_KERNEL_VERSION")
    [ -d "$MNT_ROOT/usr/lib/modules/$OFFICIAL_KERNEL_VERSION" ] && module_roots+=("$MNT_ROOT/usr/lib/modules/$OFFICIAL_KERNEL_VERSION")

    # Seed modules-load.d with any AIC/AIC8800 module names present in existing
    # module roots only. Do not let a missing alternate module path trip
    # set -e/pipefail and abort the image build.
    {
        printf '%s\n' '# InitBox/Radxa Cubie A5E Wi-Fi modules'
        printf '%s\n' 'aic8800_bsp'
        printf '%s\n' 'aic8800_fdrv'
        printf '%s\n' 'aicwf_sdio'
        printf '%s\n' 'aic8800_sdio'
        if [ "${#module_roots[@]}" -gt 0 ]; then
            while IFS= read -r module_file; do
                module_name="${module_file##*/}"
                module_name="${module_name%%.ko*}"
                printf '%s\n' "$module_name"
            done < <(
                find "${module_roots[@]}" \
                    -type f \( -iname '*aic*.ko' -o -iname '*aic*.ko.*' -o -iname '*8800*.ko' -o -iname '*8800*.ko.*' \) \
                    2>/dev/null
            ) | sort -u || true
        fi
    } | awk 'NF && !seen[$0]++' > "$MNT_ROOT/etc/modules-load.d/initbox-radxa-wifi.conf"

    cat > "$MNT_ROOT/usr/local/sbin/initbox-radxa-wifi-modprobe.sh" <<'EOF'
#!/usr/bin/env bash
set -u

if [ ! -e /lib/modules ] && [ -d /usr/lib/modules ]; then
    ln -s ../usr/lib/modules /lib/modules 2>/dev/null || true
fi

depmod -a "$(uname -r)" 2>/dev/null || true

if ip link show wlan0 >/dev/null 2>&1; then
    exit 0
fi

# Try known Radxa AIC8800 module names first, then anything captured in
# modules-load.d. This service is non-fatal: failure must not block boot.
for module in \
    aic8800_bsp \
    aic8800_fdrv \
    aicwf_sdio \
    aic8800_sdio; do
    modprobe "$module" 2>/dev/null || true
done

if [ -f /etc/modules-load.d/initbox-radxa-wifi.conf ]; then
    while IFS= read -r module; do
        case "$module" in
            ''|'#'*) continue ;;
        esac
        modprobe "$module" 2>/dev/null || true
    done < /etc/modules-load.d/initbox-radxa-wifi.conf
fi

exit 0
EOF
    chmod 0755 "$MNT_ROOT/usr/local/sbin/initbox-radxa-wifi-modprobe.sh"

    cat > "$MNT_ROOT/etc/systemd/system/initbox-radxa-wifi-modprobe.service" <<'EOF'
[Unit]
Description=InitBox Radxa AIC8800 Wi-Fi module loader
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Before=network-pre.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/initbox-radxa-wifi-modprobe.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    install -d -m 0755 "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sfn ../initbox-radxa-wifi-modprobe.service "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/initbox-radxa-wifi-modprobe.service"

    log "Wi-Fi modules-load list:"
    sed -n '1,80p' "$MNT_ROOT/etc/modules-load.d/initbox-radxa-wifi.conf"
}

install_minimal_board_fixes() {
    log "Installing minimal non-invasive board fixes"

    install -d -m 0755 "$MNT_ROOT/etc"
    install -d -m 0755 "$MNT_ROOT/etc/systemd/system"
    install -d -m 0755 "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
    install -d -m 0755 "$MNT_ROOT/etc/systemd/timesyncd.conf.d"
    install -d -m 0755 "$MNT_ROOT/usr/local/sbin"
    install -d -m 0755 "$MNT_ROOT/proc" "$MNT_ROOT/sys" "$MNT_ROOT/dev" "$MNT_ROOT/run" "$MNT_ROOT/tmp"
    chmod 1777 "$MNT_ROOT/tmp"

    log "Setting hostname and /etc/hosts: $TARGET_HOSTNAME"
    printf '%s\n' "$TARGET_HOSTNAME" > "$MNT_ROOT/etc/hostname"
    cat > "$MNT_ROOT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $TARGET_HOSTNAME

# IPv6 defaults
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    log "Writing /etc/fstab with preserved official root UUID"
    cat > "$MNT_ROOT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
tmpfs /tmp tmpfs defaults,nosuid,nodev,mode=1777 0 0
EOF

    log "Checking systemd init path"
    if [ ! -x "$MNT_ROOT/usr/lib/systemd/systemd" ] && [ ! -x "$MNT_ROOT/lib/systemd/systemd" ]; then
        fail "Could not find systemd binary in target rootfs"
    fi

    # Do not replace a valid Debian init link from the prepared rootfs. Earlier
    # versions rewrote /sbin/init after package extraction; keep PID1 stable and
    # only repair it when it is missing.
    if [ ! -e "$MNT_ROOT/sbin/init" ] && [ ! -e "$MNT_ROOT/usr/sbin/init" ]; then
        if [ -L "$MNT_ROOT/sbin" ]; then
            ln -sfn ../lib/systemd/systemd "$MNT_ROOT/usr/sbin/init"
        else
            install -d -m 0755 "$MNT_ROOT/sbin"
            ln -sfn ../lib/systemd/systemd "$MNT_ROOT/sbin/init"
        fi
    fi

    if [ -L "$MNT_ROOT/usr/sbin/init" ]; then
        log "systemd init link: /usr/sbin/init -> $(readlink "$MNT_ROOT/usr/sbin/init")"
    elif [ -L "$MNT_ROOT/sbin/init" ]; then
        log "systemd init link: /sbin/init -> $(readlink "$MNT_ROOT/sbin/init")"
    elif [ -x "$MNT_ROOT/sbin/init" ] || [ -x "$MNT_ROOT/usr/sbin/init" ]; then
        log "systemd init executable exists"
    else
        fail "No executable /sbin/init or /usr/sbin/init found after init check"
    fi

    log "Checking arm64 dynamic linker"
    if [ -e "$MNT_ROOT/lib/ld-linux-aarch64.so.1" ]; then
        :
    elif [ -e "$MNT_ROOT/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" ]; then
        ln -sfn /usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 "$MNT_ROOT/lib/ld-linux-aarch64.so.1"
    elif [ -e "$MNT_ROOT/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" ]; then
        ln -sfn /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 "$MNT_ROOT/lib/ld-linux-aarch64.so.1"
    else
        fail "arm64 dynamic linker not found in target rootfs"
    fi

    if [ -d "$MNT_ROOT/usr/share/zoneinfo/$TIMEZONE" ] || [ -f "$MNT_ROOT/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$MNT_ROOT/etc/localtime"
        printf '%s\n' "$TIMEZONE" > "$MNT_ROOT/etc/timezone"
    else
        warn "Timezone data for $TIMEZONE not found in target rootfs"
    fi

    install_rsetup_tui_defaults
    install_whiptail_putty_compat_wrapper

    cat > "$MNT_ROOT/etc/systemd/timesyncd.conf.d/initbox.conf" <<'EOF'
[Time]
NTP=time.google.com time.cloudflare.com pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
EOF

    if [ -f "$MNT_ROOT/lib/systemd/system/systemd-timesyncd.service" ] || [ -f "$MNT_ROOT/usr/lib/systemd/system/systemd-timesyncd.service" ]; then
        install -d -m 0755 "$MNT_ROOT/etc/systemd/system/sysinit.target.wants"
        ln -sfn /lib/systemd/system/systemd-timesyncd.service "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" 2>/dev/null || true
    fi

    cat > "$MNT_ROOT/usr/local/sbin/initbox-timesync-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -u

export DEBIAN_FRONTEND=noninteractive

# Do not block boot. If apt/network is unavailable, exit successfully and allow
# manual repair. This service is only a convenience for lab images.
if ! command -v timedatectl >/dev/null 2>&1; then
    exit 0
fi

if command -v systemd-timesyncd >/dev/null 2>&1 || [ -x /lib/systemd/systemd-timesyncd ] || [ -x /usr/lib/systemd/systemd-timesyncd ]; then
    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd.service 2>/dev/null || true
    exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/var/log/initbox-timesync-apt.log 2>&1 && \
        apt-get install -y systemd-timesyncd kmod iw rfkill wireless-tools whiptail dialog bash-completion >>/var/log/initbox-timesync-apt.log 2>&1 || true
    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd.service 2>/dev/null || true
fi

exit 0
EOF
    chmod 0755 "$MNT_ROOT/usr/local/sbin/initbox-timesync-setup.sh"

    cat > "$MNT_ROOT/etc/systemd/system/initbox-timesync-setup.service" <<'EOF'
[Unit]
Description=InitBox first-boot time sync package/service setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/initbox/timesync-setup.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/initbox-timesync-setup.sh
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib/initbox && touch /var/lib/initbox/timesync-setup.done'
TimeoutStartSec=180
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    ln -sfn ../initbox-timesync-setup.service "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/initbox-timesync-setup.service"

    cat > "$MNT_ROOT/usr/local/sbin/initbox-led-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -u

# Radxa Cubie A5E exposes LED triggers such as timer/cpu/mmc/panic, not always
# heartbeat/default-on. Prefer a visible timer blink; fall back to brightness=1.
for led in /sys/class/leds/*; do
    [ -d "$led" ] || continue

    case "$(basename "$led")" in
        *power*)
            # Keep power LED steady when possible.
            if [ -w "$led/trigger" ] && grep -qw none "$led/trigger" 2>/dev/null; then
                printf 'none\n' > "$led/trigger" 2>/dev/null || true
            fi
            if [ -w "$led/brightness" ]; then
                printf '1\n' > "$led/brightness" 2>/dev/null || true
            fi
            ;;
        *)
            if [ -w "$led/trigger" ] && grep -qw timer "$led/trigger" 2>/dev/null; then
                printf 'timer\n' > "$led/trigger" 2>/dev/null || true
                [ -w "$led/delay_on" ] && printf '500\n' > "$led/delay_on" 2>/dev/null || true
                [ -w "$led/delay_off" ] && printf '500\n' > "$led/delay_off" 2>/dev/null || true
            elif [ -w "$led/trigger" ] && grep -qw heartbeat "$led/trigger" 2>/dev/null; then
                printf 'heartbeat\n' > "$led/trigger" 2>/dev/null || true
            elif [ -w "$led/brightness" ]; then
                printf '1\n' > "$led/brightness" 2>/dev/null || true
            fi
            ;;
    esac
done

exit 0
EOF
    chmod 0755 "$MNT_ROOT/usr/local/sbin/initbox-led-setup.sh"

    cat > "$MNT_ROOT/etc/systemd/system/initbox-led.service" <<'EOF'
[Unit]
Description=InitBox board LED heartbeat/default trigger
After=multi-user.target
ConditionPathExists=/sys/class/leds

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/initbox-led-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    ln -sfn ../initbox-led.service "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/initbox-led.service"


    cat > "$MNT_ROOT/usr/local/sbin/initbox-rsetup-deps-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -u

export DEBIAN_FRONTEND=noninteractive

mkdir -p /var/lib/initbox

if command -v whiptail >/dev/null 2>&1; then
    touch /var/lib/initbox/rsetup-deps-setup.done
    exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/var/log/initbox-rsetup-deps-apt.log 2>&1 && \
        apt-get install -y whiptail dialog bash-completion ncurses-base ncurses-bin kmod rfkill wireless-regdb device-tree-compiler u-boot-menu >>/var/log/initbox-rsetup-deps-apt.log 2>&1 || true
fi

if command -v whiptail >/dev/null 2>&1; then
    touch /var/lib/initbox/rsetup-deps-setup.done
fi

exit 0
EOF
    chmod 0755 "$MNT_ROOT/usr/local/sbin/initbox-rsetup-deps-setup.sh"

    cat > "$MNT_ROOT/etc/systemd/system/initbox-rsetup-deps-setup.service" <<'EOF'
[Unit]
Description=InitBox first-boot rsetup TUI dependency setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/initbox/rsetup-deps-setup.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/initbox-rsetup-deps-setup.sh
TimeoutStartSec=180
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    install -d -m 0755 "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sfn ../initbox-rsetup-deps-setup.service "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/initbox-rsetup-deps-setup.service"

    log "Minimal board fixes installed"
    if [ -e "$MNT_ROOT/usr/bin/rsetup" ] || [ -e "$MNT_ROOT/usr/sbin/rsetup" ]; then
        log "rsetup CLI present in target rootfs"
    else
        warn "rsetup CLI is still not present after payload restore"
    fi
}

final_check() {
    log "Final target layout"
    lsblk -f "$TARGET_DEVICE"

    log "Hybrid image complete"
    log "Preserved: official Radxa bootloader, config partition, EFI partition, official kernel/initrd/extlinux/DTBs/modules/firmware"
    log "Replaced: partition 3 userspace rootfs with $ROOTFS_DIR"
    log "Next: boot the Cubie A5E and check serial/SSH/Wi-Fi/rsetup. v14x keeps official Radxa rsetup untouched, copies only narrow Radxa payload paths, preserves Debian PID1, validates systemd shared-library linkage, validates runtime /lib/firmware through /lib -> usr/lib, installs PuTTY-safe dialog/whiptail compatibility without wrapping rsetup, and restores u-boot/overlay support for the rsetup Overlays menu."
}

main() {
    require_root
    install_host_deps
    validate_inputs
    require_safe_target
    show_target_summary
    confirm_or_fail
    unmount_target_partitions
    write_official_image
    capture_official_boot_payload
    expand_root_partition
    format_root_partition_preserving_uuid
    copy_debian_rootfs
    final_check
}

main "$@"
