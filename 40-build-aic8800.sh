#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh

source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="AIC8800"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${AIC_REPO:?AIC_REPO is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${JOBS:?JOBS is not set}"
: "${AIC_INPUT_FINGERPRINT:?AIC_INPUT_FINGERPRINT is not set}"
: "${KERNEL_REBUILD:=0}"
: "${AIC_REBUILD:=0}"

readonly AIC_DRIVER="$AIC_REPO/src/SDIO/driver_fw/driver/aic8800"
readonly AIC_BSP_DIR="$AIC_DRIVER/aic8800_bsp"
readonly AIC_FDRV_DIR="$AIC_DRIVER/aic8800_fdrv"

readonly KERNEL_RELEASE_FILE="$BUILD_ROOT/.one-shot-kernel-release"
readonly AIC_MODULE_LIST="$BUILD_ROOT/.one-shot-aic-modules"

readonly AIC_BSP_MODULE="$AIC_BSP_DIR/aic8800_bsp.ko"
readonly AIC_FDRV_MODULE="$AIC_FDRV_DIR/aic8800_fdrv.ko"

readonly AIC_BSP_SYMVERS="$AIC_BSP_DIR/Module.symvers"
readonly AIC_BSP_COMMAND="$AIC_BSP_DIR/.aicsdio.o.cmd"
readonly CACHE_DIR="$BUILD_ROOT/cache"
readonly AIC_CACHE_STATE="$CACHE_DIR/aic8800-build.env"

KERNEL_RELEASE=""
AIC_CACHE_REUSED=0

if [[ -n "${LOG_DIR:-}" ]]; then
mkdir -p -- "$LOG_DIR"

readonly AIC_BUILD_REPORT="$LOG_DIR/aic8800-build-report.txt"
readonly AIC_SYMBOL_REPORT="$LOG_DIR/aic8800-symbols.txt"
readonly AIC_VERMAGIC_REPORT="$LOG_DIR/aic8800-vermagic.txt"
readonly AIC_COMPILER_FLAGS_REPORT="$LOG_DIR/aic8800-compiler-flags.txt"

else
readonly AIC_BUILD_REPORT="$BUILD_ROOT/.one-shot-aic-build-report.txt"
readonly AIC_SYMBOL_REPORT="$BUILD_ROOT/.one-shot-aic-symbols.txt"
readonly AIC_VERMAGIC_REPORT="$BUILD_ROOT/.one-shot-aic-vermagic.txt"
readonly AIC_COMPILER_FLAGS_REPORT="$BUILD_ROOT/.one-shot-aic-compiler-flags.txt"
fi

require_command() {
local command_name="$1"

command -v "$command_name" >/dev/null 2>&1 ||
    die "Required command is missing: $command_name"

}

require_regular_file() {
local path="$1"

[[ -f "$path" ]] ||
    die "Required file was not produced: $path"

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

cache_value() {
local key="$1"

awk -F= -v wanted="$key" '
    $1 == wanted {
        sub(/^[^=]*=/, "")
        print
        exit
    }
' "$AIC_CACHE_STATE" 2>/dev/null
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

validated_aic_cache_available() {
[[ "$KERNEL_REBUILD" == "0" && "$AIC_REBUILD" == "0" ]] || return 1
[[ -s "$AIC_CACHE_STATE" ]] || return 1
[[ "$(cache_value cache_format)" == "1" ]] || return 1
[[ "$(cache_value fingerprint)" == "$AIC_INPUT_FINGERPRINT" ]] || return 1
[[ "$(cache_value kernel_release)" == "$KERNEL_RELEASE" ]] || return 1
[[ "$(cache_value aic_commit)" == \
   "$(git -C "$AIC_REPO" rev-parse HEAD 2>/dev/null || true)" ]] || return 1

file_matches_cache_hash bsp_module_sha256 "$AIC_BSP_MODULE" || return 1
file_matches_cache_hash fdrv_module_sha256 "$AIC_FDRV_MODULE" || return 1
file_matches_cache_hash bsp_symvers_sha256 "$AIC_BSP_SYMVERS" || return 1
file_matches_cache_hash bsp_command_sha256 "$AIC_BSP_COMMAND" || return 1

return 0
}

write_aic_cache_state() {
local temporary_state

mkdir -p -- "$CACHE_DIR"
temporary_state="$(mktemp "$CACHE_DIR/.aic8800-build.XXXXXX")"

{
    printf 'cache_format=1\n'
    printf 'fingerprint=%s\n' "$AIC_INPUT_FINGERPRINT"
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'aic_commit=%s\n' "$(git -C "$AIC_REPO" rev-parse HEAD)"
    printf 'bsp_module_sha256=%s\n' "$(sha256sum -- "$AIC_BSP_MODULE" | awk '{print $1}')"
    printf 'fdrv_module_sha256=%s\n' "$(sha256sum -- "$AIC_FDRV_MODULE" | awk '{print $1}')"
    printf 'bsp_symvers_sha256=%s\n' "$(sha256sum -- "$AIC_BSP_SYMVERS" | awk '{print $1}')"
    printf 'bsp_command_sha256=%s\n' "$(sha256sum -- "$AIC_BSP_COMMAND" | awk '{print $1}')"
} >"$temporary_state"

chmod 0644 "$temporary_state"
mv -f -- "$temporary_state" "$AIC_CACHE_STATE"
}

validate_module_release() {
local module_path="$1"
local module_name
local vermagic

module_name="$(basename -- "$module_path")"
vermagic="$(module_vermagic "$module_path")"

[[ -n "$vermagic" ]] ||
    die "Could not read vermagic from $module_path"

case "$vermagic" in
    "$KERNEL_RELEASE"*)
        ;;
    *)
        die "$module_name vermagic does not match kernel $KERNEL_RELEASE: $vermagic"
        ;;
esac

}


reset_aic_patch_state() {
local rejected_file

log "Resetting AIC8800 source and stale quilt state."

run git -C "$AIC_REPO" reset --hard HEAD
run git -C "$AIC_REPO" clean -ffdx

rm -rf -- "$AIC_REPO/.pc"

while IFS= read -r -d '' rejected_file; do
    rm -f -- "$rejected_file"
done < <(
    find "$AIC_REPO" \
        -type f \
        \( -name '*.rej' -o -name '*.orig' \) \
        -print0
)
}

normalize_quilt_patch_line_endings() {
local patch_file
local relative_path
local source_path

log "Normalizing line endings in files referenced by Debian patches."

while IFS= read -r -d '' patch_file; do
    while IFS= read -r relative_path; do
        [[ -n "$relative_path" ]] || continue

        source_path="$AIC_REPO/$relative_path"

        if [[ -f "$source_path" ]] &&
           grep -q $'\r$' "$source_path"; then
            sed -i 's/\r$//' "$source_path"
            log "Converted CRLF to LF: $relative_path"
        fi
    done < <(
        awk '
            /^\+\+\+ b\// {
                path = $2
                sub(/^b\//, "", path)
                print path
            }
        ' "$patch_file" | sort -u
    )
done < <(
    find "$AIC_REPO/debian/patches" \
        -maxdepth 1 \
        -type f \
        -name '*.patch' \
        -print0
)
}

validate_usb_patch_inputs() {
local usb_loader
local usb_btusb

usb_loader="$AIC_REPO/src/USB/driver_fw/drivers/aic8800/aic_load_fw/aicbluetooth.c"
usb_btusb="$AIC_REPO/src/USB/driver_fw/drivers/aic_btusb/aic_btusb.c"

require_nonempty_file "$usb_loader"
require_nonempty_file "$usb_btusb"

if grep -q $'\r$' "$usb_loader"; then
    die "USB firmware loader still contains CRLF line endings: $usb_loader"
fi

if grep -q $'\r$' "$usb_btusb"; then
    die "USB BTUSB source still contains CRLF line endings: $usb_btusb"
fi
}

apply_radxa_sdio_patches() {
local next_patch

log "Applying applicable Radxa SDIO packaging patches."

(
    cd "$AIC_REPO"

    export QUILT_PATCHES="debian/patches"

    if ! command -v quilt >/dev/null 2>&1; then
        log "quilt is unavailable; using the current AIC8800 source state."
        exit 0
    fi

    while :; do
        next_patch="$(quilt next 2>/dev/null || true)"
        [[ -n "$next_patch" ]] || break

        case "$next_patch" in
            *fix-usb-build.patch | \
            *fix-aic_btusb-use-bluez-by-default.patch | \
            *fix-usbc1-controller-wifi-rate-of-sun60iw2p1.patch | \
            *fix-linux-6.17-build.patch | \
            *fix-linux-6.19-build.patch | \
            *fix-build-on-low-memory-devices*.patch | \
            *fix-Lower-the-debugging-log-level.patch | \
            *fix-vmalloc-not-include.patch | \
            *fix-linux-7.1-build.patch)
                log "Stopping quilt before unrelated or post-6.16 patch: $next_patch"
                break
                ;;
        esac

        log "Applying quilt patch: $next_patch"
        quilt push

        if [[ "$next_patch" == *fix-linux-6.16-build.patch ]]; then
            log "Reached Linux 6.16 compatibility patch."
            break
        fi
    done
)

}

ensure_vmalloc_headers() {
local source_file

log "Ensuring vmalloc users include linux/vmalloc.h directly."

while IFS= read -r -d '' source_file; do
    if ! grep -qF '#include <linux/vmalloc.h>' "$source_file"; then
        sed -i '1i#include <linux/vmalloc.h>' "$source_file"
        log "Added linux/vmalloc.h to: $source_file"
    fi
done < <(
    grep -RIlZ \
        --include='*.c' \
        -E '\b(vmalloc|vfree)[[:space:]]*\(' \
        "$AIC_DRIVER"
)

}

clean_module_tree() {
local module_dir="$1"
local label="$2"

log "Cleaning $label module tree."

run make -C "$KERNEL_DIR" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    M="$module_dir" \
    clean

}

build_aic8800_bsp() {
log "Building AIC8800 BSP with the generic Linux SDIO platform path."

clean_module_tree "$AIC_BSP_DIR" "AIC8800 BSP"

run make -C "$KERNEL_DIR" \
    -j"$JOBS" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    M="$AIC_BSP_DIR" \
    CONFIG_PLATFORM_ALLWINNER=n \
    CONFIG_PLATFORM_UBUNTU=y \
    CONFIG_AW_BSP=n \
    KCFLAGS=-Wno-error \
    modules

require_regular_file "$AIC_BSP_MODULE"
require_nonempty_file "$AIC_BSP_SYMVERS"

validate_module_release "$AIC_BSP_MODULE"

}

build_aic8800_fdrv() {
log "Building AIC8800 full Wi-Fi driver."

clean_module_tree "$AIC_FDRV_DIR" "AIC8800 Wi-Fi driver"

run make -C "$KERNEL_DIR" \
    -j"$JOBS" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    M="$AIC_FDRV_DIR" \
    CONFIG_PLATFORM_ALLWINNER=n \
    CONFIG_PLATFORM_UBUNTU=y \
    CONFIG_AW_BSP=n \
    KCFLAGS=-Wno-error \
    KBUILD_EXTRA_SYMBOLS="$AIC_BSP_SYMVERS" \
    modules

require_regular_file "$AIC_FDRV_MODULE"

validate_module_release "$AIC_FDRV_MODULE"

}

validate_aic_compiler_flags() {
local command_file="$AIC_BSP_DIR/.aicsdio.o.cmd"

require_nonempty_file "$command_file"

grep -q -- '-DCONFIG_PLATFORM_UBUNTU' "$command_file" ||
    die "AIC8800 BSP was not compiled with CONFIG_PLATFORM_UBUNTU"

if grep -q -- '-DCONFIG_PLATFORM_ALLWINNER' "$command_file"; then
    die "AIC8800 BSP was incorrectly compiled with CONFIG_PLATFORM_ALLWINNER"
fi

}

validate_aic_imports() {
local undefined_symbols

undefined_symbols="$(nm -u "$AIC_BSP_MODULE")"

if grep -Eq \
    '[[:space:]]U (sunxi_mmc_rescan_card|sunxi_wlan_get_bus_index|sunxi_wlan_set_power|sunxi_wlan_get_oob_irq)$' \
    <<<"$undefined_symbols"; then
    die "Generic AIC8800 BSP still imports obsolete Allwinner RFKill/rescan symbols."
fi

}

validate_no_bluetooth_module() {
local bluetooth_module

bluetooth_module="$AIC_DRIVER/aic8800_btlpm/aic8800_btlpm.ko"

if [[ -f "$bluetooth_module" ]]; then
    log "Removing stale Bluetooth module from an older build: $bluetooth_module"
    rm -f -- "$bluetooth_module"
fi

}

write_module_manifests() {
printf '%s\n' \
    "$AIC_BSP_MODULE" \
    "$AIC_FDRV_MODULE" \
    >"$AIC_MODULE_LIST"

require_nonempty_file "$AIC_MODULE_LIST"

}

write_validation_reports() {
{
printf 'AIC8800 build report\n'
printf '====================\n'
printf 'Kernel release: %s\n' "$KERNEL_RELEASE"
printf 'AIC input fingerprint: %s\n' "$AIC_INPUT_FINGERPRINT"
printf 'Validated AIC cache reused: %s\n' "$AIC_CACHE_REUSED"
printf 'Kernel directory: %s\n' "$KERNEL_DIR"
printf 'AIC repository: %s\n' "$AIC_REPO"
printf 'AIC driver directory: %s\n' "$AIC_DRIVER"
printf 'AIC platform path: generic Linux SDIO\n'
printf 'External RFKill/rescan module built: no\n'
printf 'Bluetooth module built: no\n'
printf 'Bluetooth exclusion reason: Linux 6.16 API incompatibility in vendor aic8800_btlpm source\n'
printf '\nProduced modules:\n'
printf '%s\n' \
    "$AIC_BSP_MODULE" \
    "$AIC_FDRV_MODULE"
} >"$AIC_BUILD_REPORT"

{
    printf '\n===== AIC BSP imported symbols =====\n'
    nm -u "$AIC_BSP_MODULE"

    printf '\n===== AIC FDRV BSP imports =====\n'
    nm -u "$AIC_FDRV_MODULE" |
        grep -E 'aicbsp|aicwf|sunxi_' ||
        true
} >"$AIC_SYMBOL_REPORT"

{
    printf '%s: %s\n' \
        "$(basename -- "$AIC_BSP_MODULE")" \
        "$(module_vermagic "$AIC_BSP_MODULE")"

    printf '%s: %s\n' \
        "$(basename -- "$AIC_FDRV_MODULE")" \
        "$(module_vermagic "$AIC_FDRV_MODULE")"
} >"$AIC_VERMAGIC_REPORT"

{
    printf 'AIC8800 compiler platform flags\n'
    printf '===============================\n'

    grep 'savedcmd_.*aicsdio.o' \
        "$AIC_BSP_DIR/.aicsdio.o.cmd" |
        grep -oE -- '-DCONFIG_PLATFORM_(ALLWINNER|UBUNTU)' ||
        true
} >"$AIC_COMPILER_FLAGS_REPORT"

}

main() {
require_command make
require_command grep
require_command chmod
require_command sed
require_command find
require_command strings
require_command mktemp
require_command mv
require_command nm
require_command sha256sum
require_command sort
require_command head
require_command git
require_command awk

case "$KERNEL_REBUILD" in
    0 | 1) ;;
    *) die "KERNEL_REBUILD must be 0 or 1, got: $KERNEL_REBUILD" ;;
esac

case "$AIC_REBUILD" in
    0 | 1) ;;
    *) die "AIC_REBUILD must be 0 or 1, got: $AIC_REBUILD" ;;
esac

need_dir "$KERNEL_DIR"
need_dir "$AIC_REPO"
need_dir "$AIC_DRIVER"
need_dir "$AIC_BSP_DIR"
need_dir "$AIC_FDRV_DIR"

require_nonempty_file "$KERNEL_RELEASE_FILE"

KERNEL_RELEASE="$(tr -d '[:space:]' <"$KERNEL_RELEASE_FILE")"

[[ -n "$KERNEL_RELEASE" ]] ||
    die "Kernel release file is empty: $KERNEL_RELEASE_FILE"

local actual_kernel_release
actual_kernel_release="$(
    make -s -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        kernelrelease
)"

[[ "$actual_kernel_release" == "$KERNEL_RELEASE" ]] ||
    die "Kernel release mismatch: recorded=$KERNEL_RELEASE actual=$actual_kernel_release"

log "AIC8800 automated Wi-Fi build starting with generic Linux SDIO binding."
log "Kernel release: $KERNEL_RELEASE"
log "Bluetooth module will not be built in this stage."

if validated_aic_cache_available; then
    AIC_CACHE_REUSED=1
    log "Reusing validated AIC8800 BSP and Wi-Fi modules."
    log "AIC8800 cache fingerprint: $AIC_INPUT_FINGERPRINT"

    validate_module_release "$AIC_BSP_MODULE"
    validate_module_release "$AIC_FDRV_MODULE"
    validate_aic_compiler_flags
    validate_aic_imports
    validate_no_bluetooth_module
    write_module_manifests
    write_validation_reports

    log "AIC8800 cache validation passed for $KERNEL_RELEASE."
    log "BSP module: $AIC_BSP_MODULE"
    log "Wi-Fi driver module: $AIC_FDRV_MODULE"
    return 0
fi

AIC_CACHE_REUSED=0
rm -f -- "$AIC_CACHE_STATE"
log "AIC8800 cache miss; rebuilding the external modules."

reset_aic_patch_state
normalize_quilt_patch_line_endings
validate_usb_patch_inputs
apply_radxa_sdio_patches
ensure_vmalloc_headers

build_aic8800_bsp
build_aic8800_fdrv

validate_aic_compiler_flags
validate_aic_imports
validate_no_bluetooth_module

write_module_manifests
write_validation_reports
write_aic_cache_state

log "AIC8800 Wi-Fi module build passed for $KERNEL_RELEASE."
log "AIC8800 cache state: $AIC_CACHE_STATE"
log "BSP module: $AIC_BSP_MODULE"
log "Wi-Fi driver module: $AIC_FDRV_MODULE"
log "Symbol report: $AIC_SYMBOL_REPORT"
log "Vermagic report: $AIC_VERMAGIC_REPORT"

}

main "$@"
