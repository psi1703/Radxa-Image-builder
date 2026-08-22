#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly BUILD_WRAPPER="$SCRIPT_DIR/build-cubie-a5e.sh"
readonly SOURCE_PINS="$SCRIPT_DIR/config/source-pins.env"

need_file() {
    [[ -s "$1" ]] || {
        printf 'ERROR: required file is missing or empty: %s\n' "$1" >&2
        exit 1
    }
}

pause() {
    printf '\nPress Enter to return to the menu...' >&2
    IFS= read -r _
}

show_header() {
    local linux_ref="unknown"
    local aic_ref="unknown"
    local bsp_ref="unknown"

    if [[ -r "$SOURCE_PINS" ]]; then
        # shellcheck disable=SC1090
        source "$SOURCE_PINS"
        linux_ref="${LINUX_REF:-unknown}"
        aic_ref="${AIC_REF:-unknown}"
        bsp_ref="${BSP_REF:-unknown}"
    fi

    clear 2>/dev/null || true
    cat <<EOF_HEADER
============================================================
             Radxa Cubie A5E Build Manager
============================================================
Kernel pin : $linux_ref
AIC8800    : $aic_ref
Radxa BSP  : $bsp_ref
Repo       : $SCRIPT_DIR
============================================================
EOF_HEADER
}

run_build() {
    local description="$1"
    shift

    printf '\n%s\n\n' "$description"
    sudo env "$@" "$BUILD_WRAPPER"
}

build_etcher_image() {
    run_build \
        'Building complete compressed Balena Etcher image.' \
        BUILD_MODE=image \
        OUTPUT_MODE=etcher-image
}

build_direct_image() {
    local target

    printf '\nEnter the whole target block device (example: /dev/sdb): '
    IFS= read -r target
    [[ "$target" == /dev/* ]] || {
        printf 'Invalid target device: %s\n' "$target" >&2
        return 1
    }

    run_build \
        "Building complete image directly to $target." \
        BUILD_MODE=image \
        OUTPUT_MODE=device \
        TARGET_DEVICE="$target"
}

build_update_bundle() {
    run_build \
        'Building signed kernel/board update bundle from the currently pinned sources.' \
        BUILD_MODE=update-bundle
}

force_kernel_update_bundle() {
    run_build \
        'Forcing a clean kernel and AIC8800 rebuild, then creating a signed update bundle.' \
        BUILD_MODE=update-bundle \
        KERNEL_REBUILD=1 \
        AIC_REBUILD=1
}

rebuild_rootfs_image() {
    run_build \
        'Rebuilding the Debian rootfs and creating a complete compressed image.' \
        BUILD_MODE=image \
        OUTPUT_MODE=etcher-image \
        ROOTFS_REBUILD=1
}

show_source_pins() {
    printf '\nCurrent reproducible source pins:\n\n'
    sed -n \
        -e '/^LINUX_/p' \
        -e '/^BSP_/p' \
        -e '/^AIC_/p' \
        -e '/^RADXA_UBOOT_VERSION=/p' \
        "$SOURCE_PINS"
}

validate_repository() {
    local failed=0
    local script
    local -a scripts=(
        "$BUILD_WRAPPER"
        "$SCRIPT_DIR/cubie-build-menu.sh"
        "$SCRIPT_DIR/10-prepare-host.sh"
        "$SCRIPT_DIR/15-prepare-debian-rootfs.sh"
        "$SCRIPT_DIR/20-backport-gmac1.sh"
        "$SCRIPT_DIR/22-backport-pcie.sh"
        "$SCRIPT_DIR/25-apply-hardware-dts.sh"
        "$SCRIPT_DIR/27-backport-spi.sh"
        "$SCRIPT_DIR/30-build-kernel.sh"
        "$SCRIPT_DIR/40-build-aic8800.sh"
        "$SCRIPT_DIR/45-build-update-bundle.sh"
        "$SCRIPT_DIR/50-write-base-image.sh"
        "$SCRIPT_DIR/60-install-linux-6.16.sh"
        "$SCRIPT_DIR/70-install-network-policy.sh"
        "$SCRIPT_DIR/80-validate-image.sh"
        "$SCRIPT_DIR/assets/cubie-a5e-install-nvme"
        "$SCRIPT_DIR/assets/cubie-a5e-update"
        "$SCRIPT_DIR/assets/ensure-radxa-trixie-repo"
        "$SCRIPT_DIR/assets/rsetup"
    )

    printf '\nRunning Bash syntax validation.\n'
    for script in "${scripts[@]}"; do
        if [[ ! -f "$script" ]]; then
            printf 'MISSING  %s\n' "${script#"$SCRIPT_DIR/"}"
            failed=1
            continue
        fi
        if bash -n "$script"; then
            printf 'PASS     %s\n' "${script#"$SCRIPT_DIR/"}"
        else
            printf 'FAIL     %s\n' "${script#"$SCRIPT_DIR/"}"
            failed=1
        fi
    done

    if command -v shellcheck >/dev/null 2>&1; then
        printf '\nRunning ShellCheck on the build menu and NVMe installer.\n'
        shellcheck "$SCRIPT_DIR/cubie-build-menu.sh" "$SCRIPT_DIR/assets/cubie-a5e-install-nvme" || failed=1
    else
        printf '\nShellCheck is not installed; static ShellCheck pass skipped.\n'
    fi

    ((failed == 0)) || return 1
    printf '\nRepository script validation: PASS\n'
}

main() {
    local choice

    need_file "$BUILD_WRAPPER"
    need_file "$SOURCE_PINS"

    while true; do
        show_header
        cat <<'MENU'
1. Build complete Balena Etcher image
2. Build complete image directly to a device
3. Build signed kernel / board update bundle
4. Force clean kernel + AIC8800 rebuild and update bundle
5. Rebuild Debian rootfs and complete Etcher image
6. Validate repository scripts
7. Show source pins
8. Exit
MENU
        printf '\nSelect an option [1-8]: '
        IFS= read -r choice

        case "$choice" in
            1) build_etcher_image; pause ;;
            2) build_direct_image; pause ;;
            3) build_update_bundle; pause ;;
            4) force_kernel_update_bundle; pause ;;
            5) rebuild_rootfs_image; pause ;;
            6) validate_repository; pause ;;
            7) show_source_pins; pause ;;
            8) exit 0 ;;
            *) printf 'Invalid selection: %s\n' "$choice" >&2; sleep 1 ;;
        esac
    done
}

main "$@"
