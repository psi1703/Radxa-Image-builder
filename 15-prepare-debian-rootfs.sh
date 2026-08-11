#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="ROOTFS"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${ROOTFS_DIR:?ROOTFS_DIR is not set}"

readonly DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
readonly DEBIAN_ARCH="${DEBIAN_ARCH:-arm64}"
readonly DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
readonly ROOTFS_REBUILD="${ROOTFS_REBUILD:-0}"
readonly EXPECTED_ROOTFS_DIR="$BUILD_ROOT/rootfs"
readonly ROOTFS_MARKER="$ROOTFS_DIR/etc/cubie-a5e-rootfs-release"
readonly QEMU_BINARY="/usr/bin/qemu-aarch64-static"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly ROOTFS_REPORT="$LOG_DIR/debian-rootfs-report.txt"
else
    readonly ROOTFS_REPORT="$BUILD_ROOT/.one-shot-debian-rootfs-report.txt"
fi

mounted_paths=()

cleanup() {
    local index

    for ((index = ${#mounted_paths[@]} - 1; index >= 0; index--)); do
        mountpoint -q "${mounted_paths[index]}" &&
            umount "${mounted_paths[index]}" 2>/dev/null || true
    done
}

trap cleanup EXIT INT TERM

validate_paths() {
    [[ "$(readlink -m -- "$ROOTFS_DIR")" == "$(readlink -m -- "$EXPECTED_ROOTFS_DIR")" ]] ||
        die "ROOTFS_DIR must be BUILD_ROOT/rootfs: $ROOTFS_DIR"

    [[ "$DEBIAN_ARCH" == "arm64" ]] ||
        die "This build supports only an arm64 Debian rootfs."

    case "$ROOTFS_REBUILD" in
        0 | 1) ;;
        *) die "ROOTFS_REBUILD must be 0 or 1." ;;
    esac
}

validate_existing_rootfs() {
    [[ -s "$ROOTFS_MARKER" ]] || return 1
    grep -Fxq "suite=$DEBIAN_SUITE" "$ROOTFS_MARKER" || return 1
    grep -Fxq "architecture=$DEBIAN_ARCH" "$ROOTFS_MARKER" || return 1
    [[ -x "$ROOTFS_DIR/usr/lib/systemd/systemd" ||
       -x "$ROOTFS_DIR/lib/systemd/systemd" ]] || return 1
    [[ -x "$ROOTFS_DIR/bin/bash" ]] || return 1
    [[ -s "$ROOTFS_DIR/etc/os-release" ]] || return 1
}

remove_generated_rootfs() {
    [[ "$(readlink -m -- "$ROOTFS_DIR")" == "$(readlink -m -- "$EXPECTED_ROOTFS_DIR")" ]] ||
        die "Refusing to remove unexpected path: $ROOTFS_DIR"

    if findmnt -Rno TARGET "$ROOTFS_DIR" 2>/dev/null | grep -q .; then
        die "Refusing to replace a rootfs that still has mounted paths: $ROOTFS_DIR"
    fi

    rm -rf -- "$ROOTFS_DIR"
}

install_policy_rc_d() {
    install -d -m 0755 -- "$ROOTFS_DIR/usr/sbin"
    install -m 0755 /dev/null "$ROOTFS_DIR/usr/sbin/policy-rc.d"
    printf '#!/bin/sh\nexit 101\n' >"$ROOTFS_DIR/usr/sbin/policy-rc.d"
}

run_arm64_chroot() {
    chroot "$ROOTFS_DIR" \
        /usr/bin/qemu-aarch64-static \
        /bin/bash -Eeuo pipefail -c "$1"
}

mount_chroot_filesystems() {
    install -d -m 0755 -- \
        "$ROOTFS_DIR/dev" \
        "$ROOTFS_DIR/dev/pts" \
        "$ROOTFS_DIR/proc" \
        "$ROOTFS_DIR/sys" \
        "$ROOTFS_DIR/run"

    mount --bind /dev "$ROOTFS_DIR/dev"
    mounted_paths+=("$ROOTFS_DIR/dev")
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    mounted_paths+=("$ROOTFS_DIR/dev/pts")
    mount -t proc proc "$ROOTFS_DIR/proc"
    mounted_paths+=("$ROOTFS_DIR/proc")
    mount -t sysfs sysfs "$ROOTFS_DIR/sys"
    mounted_paths+=("$ROOTFS_DIR/sys")
    mount -t tmpfs tmpfs "$ROOTFS_DIR/run"
    mounted_paths+=("$ROOTFS_DIR/run")
}

write_apt_sources() {
    install -d -m 0755 -- "$ROOTFS_DIR/etc/apt/sources.list.d"
    install -m 0644 /dev/null "$ROOTFS_DIR/etc/apt/sources.list"
    printf '%s\n' \
        "deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free-firmware" \
        "deb $DEBIAN_MIRROR ${DEBIAN_SUITE}-updates main contrib non-free-firmware" \
        "deb https://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free-firmware" \
        >"$ROOTFS_DIR/etc/apt/sources.list"
}

configure_rootfs() {
    cp -L -- /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
    write_apt_sources
    mount_chroot_filesystems

    run_arm64_chroot '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            bash-completion \
            ca-certificates \
            dbus \
            dialog \
            initramfs-tools \
            iproute2 \
            kmod \
            locales \
            nano \
            network-manager \
            openssh-server \
            procps \
            rsync \
            sudo \
            systemd-sysv \
            systemd-timesyncd \
            tzdata \
            udev \
            whiptail
        printf "%s\n" "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen
        update-locale LANG=en_US.UTF-8
        apt-get clean
    '

    systemctl --root="$ROOTFS_DIR" enable NetworkManager.service >/dev/null
    systemctl --root="$ROOTFS_DIR" enable ssh.service >/dev/null
    systemctl --root="$ROOTFS_DIR" enable systemd-timesyncd.service >/dev/null

    rm -f -- "$ROOTFS_DIR/usr/sbin/policy-rc.d"
    rm -f -- "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
    rm -rf -- "$ROOTFS_DIR/var/lib/apt/lists"/*

    install -d -m 0755 -- "$ROOTFS_DIR/etc"
    {
        printf 'suite=%s\n' "$DEBIAN_SUITE"
        printf 'architecture=%s\n' "$DEBIAN_ARCH"
        printf 'mirror=%s\n' "$DEBIAN_MIRROR"
    } >"$ROOTFS_MARKER"
}

create_rootfs() {
    local include_packages

    include_packages="ca-certificates,dbus,initramfs-tools,kmod,network-manager,openssh-server,sudo,systemd-sysv,udev"

    log "Creating a clean Debian $DEBIAN_SUITE arm64 rootfs."
    run debootstrap \
        --arch="$DEBIAN_ARCH" \
        --foreign \
        --include="$include_packages" \
        "$DEBIAN_SUITE" \
        "$ROOTFS_DIR" \
        "$DEBIAN_MIRROR"

    install -D -m 0755 -- "$QEMU_BINARY" "$ROOTFS_DIR$QEMU_BINARY"
    install_policy_rc_d

    run chroot "$ROOTFS_DIR" \
        /usr/bin/qemu-aarch64-static \
        /bin/sh \
        /debootstrap/debootstrap \
        --second-stage

    configure_rootfs
}

write_report() {
    {
        printf 'Cubie A5E Debian rootfs report\n'
        printf '================================\n'
        printf 'Status: PASS\n'
        printf 'Suite: %s\n' "$DEBIAN_SUITE"
        printf 'Architecture: %s\n' "$DEBIAN_ARCH"
        printf 'Mirror: %s\n' "$DEBIAN_MIRROR"
        printf 'Rootfs: %s\n' "$ROOTFS_DIR"
        printf 'OS release: %s\n' "$(grep '^PRETTY_NAME=' "$ROOTFS_DIR/etc/os-release")"
        printf 'PID1: %s\n' "$(readlink -m -- "$ROOTFS_DIR/sbin/init")"
    } >"$ROOTFS_REPORT"
}

main() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this stage as root."

    need_cmd chroot
    need_cmd debootstrap
    need_cmd findmnt
    need_cmd mount
    need_cmd mountpoint
    need_cmd qemu-aarch64-static
    need_cmd systemctl
    need_cmd umount

    validate_paths

    if validate_existing_rootfs && [[ "$ROOTFS_REBUILD" == "0" ]]; then
        log "Using the existing validated Debian rootfs: $ROOTFS_DIR"
    else
        if [[ -e "$ROOTFS_DIR" ]]; then
            [[ "$ROOTFS_REBUILD" == "1" ]] ||
                die "Incomplete or mismatched rootfs exists. Set ROOTFS_REBUILD=1 to replace it."
            remove_generated_rootfs
        fi
        create_rootfs
    fi

    validate_existing_rootfs || die "Prepared Debian rootfs failed validation."
    write_report
    log "Debian rootfs is ready: $ROOTFS_DIR"
    log "Rootfs report: $ROOTFS_REPORT"
}

main "$@"
