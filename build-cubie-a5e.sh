#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=config/source-pins.env
source "$SCRIPT_DIR/config/source-pins.env"

STAGE_NAME="WRAPPER"

BUILD_ROOT="${BUILD_ROOT:-$SCRIPT_DIR/build}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BUILD_ROOT/downloads}"
INPUT_DIR="${INPUT_DIR:-$DOWNLOAD_DIR}"
KERNEL_DIR="${KERNEL_DIR:-$BUILD_ROOT/linux-6.16-one-shot}"
AIC_REPO="${AIC_REPO:-$BUILD_ROOT/aic8800-radxa}"
ROOTFS_DIR="${ROOTFS_DIR:-$BUILD_ROOT/rootfs}"
BASE_IMAGE_BUILDER="${BASE_IMAGE_BUILDER:-$SCRIPT_DIR/base/build-debian13-donor-image.sh}"
STOCK_IMG_XZ="${STOCK_IMG_XZ:-$INPUT_DIR/radxa-cubie-a5e_bullseye_cli_r7.output_512.img.xz}"
REQUESTED_TARGET_DEVICE="${TARGET_DEVICE:-}"
TARGET_DEVICE="${TARGET_DEVICE:-/dev/sdb}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
CONFIRM_WRITE="${CONFIRM_WRITE:-0}"
BUILD_MODE="${BUILD_MODE:-image}"
OUTPUT_MODE="${OUTPUT_MODE:-device}"

BUILD_ID="${BUILD_ID:-$(date -u '+%Y%m%dT%H%M%SZ')}"
REQUESTED_KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-}"
KERNEL_CONFIG_SOURCE="${KERNEL_CONFIG_SOURCE:-}"
KERNEL_REBUILD="${KERNEL_REBUILD:-0}"
AIC_REBUILD="${AIC_REBUILD:-0}"
KERNEL_LOCALVERSION=""
KERNEL_INPUT_FINGERPRINT=""
AIC_INPUT_FINGERPRINT=""
IMAGE_SIZE_GIB="${IMAGE_SIZE_GIB:-4}"
IMAGE_XZ_LEVEL="${IMAGE_XZ_LEVEL:-6}"
IMAGE_XZ_THREADS="${IMAGE_XZ_THREADS:-0}"
IMAGE_OVERWRITE="${IMAGE_OVERWRITE:-0}"
IMAGE_OUTPUT_DIR="/home/psi"
IMAGE_OUTPUT="${IMAGE_OUTPUT:-$IMAGE_OUTPUT_DIR/cubie-a5e-debian13-linux6.16-${BUILD_ID}.img.xz}"
IMAGE_RAW="${IMAGE_OUTPUT%.xz}"
LOG_ROOT="${LOG_ROOT:-$BUILD_ROOT/logs}"
LOG_DIR="${LOG_DIR:-$LOG_ROOT/$BUILD_ID}"
BUILD_LOG="$LOG_DIR/build.log"
COMMAND_LOG="$LOG_DIR/commands.log"
ENVIRONMENT_LOG="$LOG_DIR/environment.txt"
STAGE_LOG="$LOG_DIR/stages.tsv"
FAILURE_LOG="$LOG_DIR/failure-context.txt"
TARGET_LOG="$LOG_DIR/target-before-write.txt"
SUMMARY_LOG="$LOG_DIR/build-summary.txt"
LOCK_FILE="${LOCK_FILE:-$BUILD_ROOT/.cubie-a5e-one-shot.lock}"

CURRENT_STAGE="startup"
CURRENT_STAGE_START=0
CURRENT_STAGE_STARTED_UTC=""
BUILD_START_EPOCH="$(date +%s)"
BUILD_SUCCEEDED=0
LOCK_FD=""
IMAGE_LOOP_DEVICE=""

readonly BUILD_ROOT
readonly DOWNLOAD_DIR
readonly INPUT_DIR
readonly KERNEL_DIR
readonly AIC_REPO
readonly ROOTFS_DIR
readonly BASE_IMAGE_BUILDER
readonly STOCK_IMG_XZ
readonly REQUESTED_TARGET_DEVICE
readonly CROSS_COMPILE
readonly JOBS
readonly CONFIRM_WRITE
readonly BUILD_MODE
readonly OUTPUT_MODE
readonly BUILD_ID
readonly REQUESTED_KERNEL_LOCALVERSION
readonly KERNEL_CONFIG_SOURCE
readonly KERNEL_REBUILD
readonly AIC_REBUILD
readonly IMAGE_SIZE_GIB
readonly IMAGE_XZ_LEVEL
readonly IMAGE_XZ_THREADS
readonly IMAGE_OVERWRITE
readonly IMAGE_OUTPUT_DIR
readonly IMAGE_OUTPUT
readonly IMAGE_RAW
readonly LOG_ROOT
readonly LOG_DIR
readonly BUILD_LOG
readonly COMMAND_LOG
readonly ENVIRONMENT_LOG
readonly STAGE_LOG
readonly FAILURE_LOG
readonly TARGET_LOG
readonly SUMMARY_LOG
readonly LOCK_FILE

export BUILD_ROOT DOWNLOAD_DIR INPUT_DIR KERNEL_DIR AIC_REPO ROOTFS_DIR
export BASE_IMAGE_BUILDER STOCK_IMG_XZ
export LINUX_REPOSITORY LINUX_REF LINUX_EXPECTED_COMMIT
export AIC_REPOSITORY AIC_REF AIC_EXPECTED_COMMIT
export STOCK_IMAGE_URL STOCK_IMAGE_SHA512
export TARGET_DEVICE
export CROSS_COMPILE JOBS CONFIRM_WRITE BUILD_ID LOG_ROOT LOG_DIR
export BUILD_LOG COMMAND_LOG ENVIRONMENT_LOG STAGE_LOG FAILURE_LOG
export TARGET_LOG SUMMARY_LOG CURRENT_STAGE STAGE_NAME BUILD_MODE OUTPUT_MODE
export KERNEL_CONFIG_SOURCE KERNEL_REBUILD AIC_REBUILD
export KERNEL_LOCALVERSION KERNEL_INPUT_FINGERPRINT AIC_INPUT_FINGERPRINT

stages=("10-prepare-host.sh")

if [[ "$BUILD_MODE" == "image" ]]; then
    stages+=("15-prepare-debian-rootfs.sh")
fi

stages+=(
    "20-backport-gmac1.sh"
    "25-apply-hardware-dts.sh"
    "30-build-kernel.sh"
    "40-build-aic8800.sh"
    "45-build-update-bundle.sh"
)

if [[ "$BUILD_MODE" == "image" ]]; then
    stages+=(
        "50-write-base-image.sh"
        "60-install-linux-6.16.sh"
        "70-install-network-policy.sh"
        "80-validate-image.sh"
    )
fi

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

duration_text() {
    local total_seconds="$1"
    local hours
    local minutes
    local seconds

    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}

safe_realpath() {
    local path="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$path"
    else
        readlink -m -- "$path"
    fi
}

initialize_logging() {
    mkdir -p -- "$LOG_DIR"

    : >"$BUILD_LOG"
    : >"$COMMAND_LOG"
    : >"$STAGE_LOG"

    printf 'stage\tstatus\tstarted_utc\tfinished_utc\tduration_seconds\n' >"$STAGE_LOG"

    exec 9>>"$COMMAND_LOG"
    export BASH_XTRACEFD=9

    PS4='+ ${EPOCHREALTIME} ${BASH_SOURCE##*/}:${LINENO}: '
    export PS4

    exec > >(tee -a "$BUILD_LOG") 2>&1
}

capture_environment() {
    {
        printf 'Build ID: %s\n' "$BUILD_ID"
        printf 'Started UTC: %s\n' "$(timestamp)"
        printf 'Script: %s\n' "$SCRIPT_DIR/$SCRIPT_NAME"
        printf 'Build root: %s\n' "$BUILD_ROOT"
        printf 'Download directory: %s\n' "$DOWNLOAD_DIR"
        printf 'Input directory: %s\n' "$INPUT_DIR"
        printf 'Kernel directory: %s\n' "$KERNEL_DIR"
        printf 'AIC repository: %s\n' "$AIC_REPO"
        printf 'Debian rootfs: %s\n' "$ROOTFS_DIR"
        printf 'Base image builder: %s\n' "$BASE_IMAGE_BUILDER"
        printf 'Stock Radxa image: %s\n' "$STOCK_IMG_XZ"
        printf 'Output mode: %s\n' "$OUTPUT_MODE"
        printf 'Target device: %s\n' "$TARGET_DEVICE"
        if [[ "$BUILD_MODE" == "image" && "$OUTPUT_MODE" == "etcher-image" ]]; then
            printf 'Image output: %s\n' "$IMAGE_OUTPUT"
            printf 'Raw image working file: %s\n' "$IMAGE_RAW"
            printf 'Image size GiB: %s\n' "$IMAGE_SIZE_GIB"
            printf 'Image xz level: %s\n' "$IMAGE_XZ_LEVEL"
            printf 'Image xz threads: %s\n' "$IMAGE_XZ_THREADS"
        fi
        printf 'Cross compiler: %s\n' "$CROSS_COMPILE"
        printf 'Jobs: %s\n' "$JOBS"
        printf 'Confirmation mode: %s\n' "$CONFIRM_WRITE"
        printf 'Build mode: %s\n' "$BUILD_MODE"
        printf 'Kernel local version: %s\n' "$KERNEL_LOCALVERSION"
        printf 'Kernel input fingerprint: %s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'AIC8800 input fingerprint: %s\n' "$AIC_INPUT_FINGERPRINT"
        printf 'Forced kernel rebuild: %s\n' "$KERNEL_REBUILD"
        printf 'Forced AIC8800 rebuild: %s\n' "$AIC_REBUILD"
        printf 'Hostname: %s\n' "$(hostname)"
        printf 'Kernel: %s\n' "$(uname -a)"
        printf 'User: %s\n' "$(id)"
        printf 'Working directory: %s\n' "$PWD"
        printf 'PATH: %s\n' "$PATH"
    } >"$ENVIRONMENT_LOG"
}

acquire_build_lock() {
    mkdir -p -- "$BUILD_ROOT"
    exec {LOCK_FD}>"$LOCK_FILE"

    if ! flock -n "$LOCK_FD"; then
        die "Another one-shot Cubie A5E build owns lock: $LOCK_FILE"
    fi

    printf '%s\n' "$$" 1>&"$LOCK_FD"
}

release_build_lock() {
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
    fi
}

detach_image_loop() {
    local strict="${1:-0}"
    local mountpoint_path
    local remaining_mounts

    [[ -n "$IMAGE_LOOP_DEVICE" ]] || return 0

    while IFS= read -r mountpoint_path; do
        [[ -n "$mountpoint_path" ]] || continue
        umount "$mountpoint_path" 2>/dev/null || true
    done < <(
        lsblk -lnpo MOUNTPOINTS "$IMAGE_LOOP_DEVICE" 2>/dev/null |
            awk 'NF > 0 && $1 != "" {print $1}' |
            sort -r
    )

    sync

    remaining_mounts="$(
        lsblk -lnpo MOUNTPOINTS "$IMAGE_LOOP_DEVICE" 2>/dev/null |
            awk 'NF > 0 && $1 != "" {print $1}'
    )"

    if [[ -n "$remaining_mounts" ]]; then
        if [[ "$strict" == "1" ]]; then
            printf '%s\n' "$remaining_mounts" >&2
            die "Image loop still has mounted filesystems: $IMAGE_LOOP_DEVICE"
        fi
        return 0
    fi

    if ! losetup -d "$IMAGE_LOOP_DEVICE" 2>/dev/null; then
        if [[ "$strict" == "1" ]]; then
            die "Failed to detach image loop device: $IMAGE_LOOP_DEVICE"
        fi
        return 0
    fi

    udevadm settle 2>/dev/null || true
    IMAGE_LOOP_DEVICE=""
}

finish_current_stage() {
    local status="$1"
    local now_epoch
    local elapsed

    if ((CURRENT_STAGE_START == 0)); then
        return 0
    fi

    now_epoch="$(date +%s)"
    elapsed=$((now_epoch - CURRENT_STAGE_START))

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$CURRENT_STAGE" \
        "$status" \
        "${CURRENT_STAGE_STARTED_UTC:-unknown}" \
        "$(timestamp)" \
        "$elapsed" >>"$STAGE_LOG"

    CURRENT_STAGE_START=0
}

write_failure_context() {
    local exit_code="$1"
    local line_no="$2"
    local command="$3"

    {
        printf 'Build ID: %s\n' "$BUILD_ID"
        printf 'Failed UTC: %s\n' "$(timestamp)"
        printf 'Stage: %s\n' "$CURRENT_STAGE"
        printf 'Exit code: %s\n' "$exit_code"
        printf 'Line: %s\n' "$line_no"
        printf 'Command: %s\n' "$command"
        printf 'Target device: %s\n' "$TARGET_DEVICE"
        printf 'Kernel directory: %s\n' "$KERNEL_DIR"
        printf 'AIC repository: %s\n' "$AIC_REPO"
        printf '\nLast 100 build-log lines:\n'
        tail -n 100 "$BUILD_LOG" 2>/dev/null || true
    } >"$FAILURE_LOG"
}

on_error() {
    local exit_code="$?"
    local line_no="${1:-unknown}"
    local command="${2:-unknown}"

    trap - ERR
    finish_current_stage "FAILED"
    write_failure_context "$exit_code" "$line_no" "$command"

    printf '\n[x] Build failed.\n' >&2
    printf '[x] Stage: %s\n' "$CURRENT_STAGE" >&2
    printf '[x] Exit code: %s\n' "$exit_code" >&2
    printf '[x] Command: %s\n' "$command" >&2
    printf '[x] Build log: %s\n' "$BUILD_LOG" >&2
    printf '[x] Command log: %s\n' "$COMMAND_LOG" >&2
    printf '[x] Failure context: %s\n' "$FAILURE_LOG" >&2

    exit "$exit_code"
}

on_signal() {
    local signal_name="$1"

    trap - ERR
    finish_current_stage "INTERRUPTED"

    {
        printf 'Build ID: %s\n' "$BUILD_ID"
        printf 'Interrupted UTC: %s\n' "$(timestamp)"
        printf 'Signal: %s\n' "$signal_name"
        printf 'Stage: %s\n' "$CURRENT_STAGE"
    } >"$FAILURE_LOG"

    printf '\n[x] Build interrupted by %s during %s.\n' "$signal_name" "$CURRENT_STAGE" >&2
    exit 130
}

on_exit() {
    local exit_code="$?"
    local elapsed

    detach_image_loop 0
    release_build_lock
    elapsed=$(($(date +%s) - BUILD_START_EPOCH))

    if ((BUILD_SUCCEEDED == 1)); then
        return 0
    fi

    if ((exit_code != 0)); then
        printf '[x] Total elapsed time: %s\n' "$(duration_text "$elapsed")" >&2
    fi
}

start_stage() {
    local stage="$1"

    CURRENT_STAGE="$stage"
    CURRENT_STAGE_START="$(date +%s)"
    CURRENT_STAGE_STARTED_UTC="$(timestamp)"

    export CURRENT_STAGE
    export STAGE_NAME="$stage"

    log "============================================================"
    log "Starting stage: $stage"
    log "Stage log directory: $LOG_DIR"
    log "============================================================"
}

run_stage() {
    local stage="$1"
    local stage_path="$SCRIPT_DIR/$stage"
    local stage_start
    local stage_end
    local elapsed

    need_file "$stage_path"

    [[ -x "$stage_path" ]] || die "Stage is not executable: $stage_path"

    start_stage "$stage"
    stage_start="$(date +%s)"

    set -x
    "$stage_path"
    set +x

    stage_end="$(date +%s)"
    elapsed=$((stage_end - stage_start))

    finish_current_stage "SUCCESS"
    log "Completed stage: $stage"
    log "Stage duration: $(duration_text "$elapsed")"
}

validate_integer() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        die "$name must be a positive integer, got: $value"
}

validate_paths() {
    local normalized_build_root
    local normalized_input_dir
    local normalized_kernel_dir
    local normalized_aic_repo
    local normalized_rootfs_dir
    local normalized_base_image_builder
    local normalized_stock_img
    local normalized_script_dir

    normalized_build_root="$(safe_realpath "$BUILD_ROOT")"
    normalized_input_dir="$(safe_realpath "$INPUT_DIR")"
    normalized_kernel_dir="$(safe_realpath "$KERNEL_DIR")"
    normalized_aic_repo="$(safe_realpath "$AIC_REPO")"
    normalized_rootfs_dir="$(safe_realpath "$ROOTFS_DIR")"
    normalized_base_image_builder="$(safe_realpath "$BASE_IMAGE_BUILDER")"
    normalized_stock_img="$(safe_realpath "$STOCK_IMG_XZ")"
    normalized_script_dir="$(safe_realpath "$SCRIPT_DIR")"

    [[ "$normalized_build_root" == "$normalized_script_dir/build" ]] ||
        die "BUILD_ROOT must be the repository build directory: $normalized_build_root"

    [[ "$normalized_input_dir" == "$normalized_build_root/downloads" ]] ||
        die "INPUT_DIR must be BUILD_ROOT/downloads: $normalized_input_dir"

    [[ "$normalized_kernel_dir" == "$normalized_build_root/linux-6.16-one-shot" ]] ||
        die "Unexpected KERNEL_DIR: $normalized_kernel_dir"

    [[ "$normalized_aic_repo" == "$normalized_build_root/aic8800-radxa" ]] ||
        die "Unexpected AIC_REPO: $normalized_aic_repo"

    [[ "$normalized_rootfs_dir" == "$normalized_build_root/rootfs" ]] ||
        die "Unexpected ROOTFS_DIR: $normalized_rootfs_dir"

    [[ "$normalized_base_image_builder" == "$normalized_script_dir/base/build-debian13-donor-image.sh" ]] ||
        die "Unexpected BASE_IMAGE_BUILDER: $normalized_base_image_builder"

    [[ "$normalized_stock_img" == "$normalized_input_dir/radxa-cubie-a5e_bullseye_cli_r7.output_512.img.xz" ]] ||
        die "STOCK_IMG_XZ must be inside INPUT_DIR: $normalized_stock_img"
}

install_required_host_packages() {
    local packages=(
        bc
        binfmt-support
        binutils-aarch64-linux-gnu
        bison
        build-essential
        ca-certificates
        cloud-guest-utils
        cpio
        curl
        debootstrap
        device-tree-compiler
        diffutils
        dwarves
        e2fsprogs
        file
        flex
        gcc-aarch64-linux-gnu
        git
        kmod
        libelf-dev
        libssl-dev
        make
        openssl
        parted
        patch
        python3
        qemu-user-static
        quilt
        rsync
        tar
        u-boot-tools
        udev
        util-linux
        xz-utils
    )
    local missing=()
    local command_name
    local package

    for command_name in apt-get dpkg-query grep; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required Debian package-manager command is missing: $command_name"
    done

    log "Checking required Debian host packages before starting build stages."

    for package in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -qx 'install ok installed'; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]} == 0)); then
        log "All required Debian host packages are already installed."
        return 0
    fi

    log "Installing ${#missing[@]} missing Debian host package(s):"
    printf '  - %s\n' "${missing[@]}"

    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive \
        apt-get install \
        -y \
        --no-install-recommends \
        "${missing[@]}"

    for package in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -qx 'install ok installed' ||
            die "Required Debian host package is still unavailable after installation: $package"
    done

    log "Required Debian host package installation passed."
}

require_host_commands() {
    local commands=(
        awk bash blockdev date df dtc findmnt flock grep head lsblk make
        mountpoint nproc pahole readlink sed sha256sum sort sync tee udevadm umount
    )
    local command_name

    if [[ "$BUILD_MODE" == "image" && "$OUTPUT_MODE" == "etcher-image" ]]; then
        commands+=(losetup truncate xz)
    fi

    for command_name in "${commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required host command is missing: $command_name"
    done

}

validate_cache_settings() {
    case "$KERNEL_REBUILD" in
        0 | 1) ;;
        *) die "KERNEL_REBUILD must be 0 or 1, got: $KERNEL_REBUILD" ;;
    esac

    case "$AIC_REBUILD" in
        0 | 1) ;;
        *) die "AIC_REBUILD must be 0 or 1, got: $AIC_REBUILD" ;;
    esac
}

compute_build_fingerprints() {
    local compiler_command="${CROSS_COMPILE}gcc"
    local compiler_path
    local compiler_version
    local linker_command="${CROSS_COMPILE}ld"
    local linker_path
    local linker_version
    local assembler_command="${CROSS_COMPILE}as"
    local assembler_path
    local assembler_version
    local dtc_version
    local make_version
    local pahole_version
    local config_hash="arm64-defconfig"
    local kernel_base_fingerprint
    local input_file
    local kernel_input_files=(
        "$SCRIPT_DIR/10-prepare-host.sh"
        "$SCRIPT_DIR/20-backport-gmac1.sh"
        "$SCRIPT_DIR/25-apply-hardware-dts.sh"
        "$SCRIPT_DIR/30-build-kernel.sh"
    )

    command -v "$compiler_command" >/dev/null 2>&1 ||
        die "Cross compiler is unavailable after host package installation: $compiler_command"
    command -v "$linker_command" >/dev/null 2>&1 ||
        die "Cross linker is unavailable after host package installation: $linker_command"
    command -v "$assembler_command" >/dev/null 2>&1 ||
        die "Cross assembler is unavailable after host package installation: $assembler_command"

    compiler_path="$(command -v "$compiler_command")"
    compiler_version="$("$compiler_command" --version | sed -n '1p')"
    linker_path="$(command -v "$linker_command")"
    linker_version="$("$linker_command" --version | sed -n '1p')"
    assembler_path="$(command -v "$assembler_command")"
    assembler_version="$("$assembler_command" --version | sed -n '1p')"
    dtc_version="$(dtc --version | sed -n '1p')"
    make_version="$(make --version | sed -n '1p')"
    pahole_version="$(pahole --version | sed -n '1p')"

    [[ -n "$compiler_version" &&
       -n "$linker_version" &&
       -n "$assembler_version" &&
       -n "$dtc_version" &&
       -n "$make_version" &&
       -n "$pahole_version" ]] ||
        die "Could not determine the complete kernel build-tool identity."

    if [[ -n "$KERNEL_CONFIG_SOURCE" ]]; then
        need_nonempty_file "$KERNEL_CONFIG_SOURCE"
        config_hash="$(sha256sum -- "$KERNEL_CONFIG_SOURCE" | awk '{print $1}')"
    fi

    for input_file in "${kernel_input_files[@]}"; do
        need_nonempty_file "$input_file"
    done

    kernel_base_fingerprint="$({
        printf 'cache-format=1\n'
        printf 'linux-repository=%s\n' "$LINUX_REPOSITORY"
        printf 'linux-ref=%s\n' "$LINUX_REF"
        printf 'linux-commit=%s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'compiler-path=%s\n' "$compiler_path"
        printf 'compiler-version=%s\n' "$compiler_version"
        printf 'compiler-machine=%s\n' "$("$compiler_command" -dumpmachine)"
        printf 'linker-path=%s\n' "$linker_path"
        printf 'linker-version=%s\n' "$linker_version"
        printf 'assembler-path=%s\n' "$assembler_path"
        printf 'assembler-version=%s\n' "$assembler_version"
        printf 'dtc-version=%s\n' "$dtc_version"
        printf 'make-version=%s\n' "$make_version"
        printf 'pahole-version=%s\n' "$pahole_version"
        printf 'kernel-config-source=%s\n' "${KERNEL_CONFIG_SOURCE:-arm64-defconfig}"
        printf 'kernel-config-sha256=%s\n' "$config_hash"

        for input_file in "${kernel_input_files[@]}"; do
            printf 'input=%s\n' "${input_file#"$SCRIPT_DIR"/}"
            sha256sum -- "$input_file"
        done
    } | sha256sum | awk '{print $1}')"

    if [[ -n "$REQUESTED_KERNEL_LOCALVERSION" ]]; then
        KERNEL_LOCALVERSION="$REQUESTED_KERNEL_LOCALVERSION"
    else
        KERNEL_LOCALVERSION="+cubie-a5e.k${kernel_base_fingerprint:0:12}"
    fi

    [[ "$KERNEL_LOCALVERSION" =~ ^\+[A-Za-z0-9._+-]+$ ]] ||
        die "KERNEL_LOCALVERSION must start with + and contain only kernel-safe characters."

    KERNEL_INPUT_FINGERPRINT="$({
        printf 'kernel-base=%s\n' "$kernel_base_fingerprint"
        printf 'kernel-localversion=%s\n' "$KERNEL_LOCALVERSION"
    } | sha256sum | awk '{print $1}')"

    AIC_INPUT_FINGERPRINT="$({
        printf 'cache-format=1\n'
        printf 'kernel-fingerprint=%s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'aic-repository=%s\n' "$AIC_REPOSITORY"
        printf 'aic-ref=%s\n' "$AIC_REF"
        printf 'aic-commit=%s\n' "$AIC_EXPECTED_COMMIT"
        printf 'compiler-path=%s\n' "$compiler_path"
        printf 'compiler-version=%s\n' "$compiler_version"
        sha256sum -- "$SCRIPT_DIR/40-build-aic8800.sh"
    } | sha256sum | awk '{print $1}')"

    export KERNEL_LOCALVERSION KERNEL_INPUT_FINGERPRINT AIC_INPUT_FINGERPRINT

    log "Kernel cache fingerprint: $KERNEL_INPUT_FINGERPRINT"
    log "Stable kernel local version: $KERNEL_LOCALVERSION"
    log "AIC8800 cache fingerprint: $AIC_INPUT_FINGERPRINT"
}

validate_output_settings() {
    local image_output_dir_real
    local image_output_real
    local image_raw_real

    case "$OUTPUT_MODE" in
        device | etcher-image) ;;
        *) die "OUTPUT_MODE must be device or etcher-image, got: $OUTPUT_MODE" ;;
    esac

    case "$IMAGE_OVERWRITE" in
        0 | 1) ;;
        *) die "IMAGE_OVERWRITE must be 0 or 1, got: $IMAGE_OVERWRITE" ;;
    esac

    [[ "$IMAGE_XZ_LEVEL" =~ ^[0-9]$ ]] ||
        die "IMAGE_XZ_LEVEL must be one digit from 0 through 9."
    [[ "$IMAGE_XZ_THREADS" =~ ^[0-9]+$ ]] ||
        die "IMAGE_XZ_THREADS must be zero or a positive integer."

    if [[ "$BUILD_MODE" != "image" ]]; then
        return 0
    fi

    if [[ "$OUTPUT_MODE" == "device" ]]; then
        return 0
    fi

    [[ -z "$REQUESTED_TARGET_DEVICE" ]] ||
        die "Do not set TARGET_DEVICE when OUTPUT_MODE=etcher-image."

    validate_integer "IMAGE_SIZE_GIB" "$IMAGE_SIZE_GIB"
    ((IMAGE_SIZE_GIB >= 4)) ||
        die "IMAGE_SIZE_GIB must be at least 4."

    [[ "$IMAGE_OUTPUT" == *.img.xz ]] ||
        die "IMAGE_OUTPUT must end in .img.xz: $IMAGE_OUTPUT"
    [[ "$IMAGE_RAW" == *.img ]] ||
        die "The raw image working path must end in .img: $IMAGE_RAW"

    image_output_dir_real="$(safe_realpath "$IMAGE_OUTPUT_DIR")"
    image_output_real="$(safe_realpath "$IMAGE_OUTPUT")"
    image_raw_real="$(safe_realpath "$IMAGE_RAW")"

    [[ "$(dirname -- "$image_output_real")" == "$image_output_dir_real" ]] ||
        die "IMAGE_OUTPUT must be directly inside $IMAGE_OUTPUT_DIR: $image_output_real"
    [[ "$(dirname -- "$image_raw_real")" == "$image_output_dir_real" ]] ||
        die "Raw image must be directly inside $IMAGE_OUTPUT_DIR: $image_raw_real"
    [[ ! -L "$IMAGE_OUTPUT" && ! -L "$IMAGE_RAW" ]] ||
        die "Image output paths must not be symbolic links."

    if [[ "$IMAGE_OVERWRITE" == "0" ]]; then
        [[ ! -e "$IMAGE_OUTPUT" ]] ||
            die "Image output already exists: $IMAGE_OUTPUT"
        [[ ! -e "$IMAGE_RAW" ]] ||
            die "Raw image working file already exists: $IMAGE_RAW"
        [[ ! -e "$IMAGE_OUTPUT.sha256" ]] ||
            die "Image checksum already exists: $IMAGE_OUTPUT.sha256"
    fi
}

prepare_image_target() {
    local expected_size
    local actual_size
    local backing_file

    mkdir -p -- "$(dirname -- "$IMAGE_OUTPUT")"

    if [[ "$IMAGE_OVERWRITE" == "1" ]]; then
        rm -f -- "$IMAGE_OUTPUT" "$IMAGE_OUTPUT.sha256" "$IMAGE_RAW"
    fi

    expected_size=$((IMAGE_SIZE_GIB * 1024 * 1024 * 1024))
    log "Creating sparse $IMAGE_SIZE_GIB GiB raw image: $IMAGE_RAW"
    truncate -s "$expected_size" -- "$IMAGE_RAW"

    IMAGE_LOOP_DEVICE="$(losetup --find --show --partscan "$IMAGE_RAW")"
    [[ -b "$IMAGE_LOOP_DEVICE" ]] ||
        die "Failed to create loop device for: $IMAGE_RAW"

    TARGET_DEVICE="$IMAGE_LOOP_DEVICE"
    export TARGET_DEVICE

    actual_size="$(blockdev --getsize64 "$TARGET_DEVICE")"
    [[ "$actual_size" == "$expected_size" ]] ||
        die "Loop device size mismatch: expected=$expected_size actual=$actual_size"

    [[ "$(lsblk -dnro TYPE "$TARGET_DEVICE" 2>/dev/null || true)" == "loop" ]] ||
        die "Image target is not a loop device: $TARGET_DEVICE"

    backing_file="$(losetup -nO BACK-FILE "$TARGET_DEVICE" | sed -n '1p')"
    [[ "$(safe_realpath "$backing_file")" == "$(safe_realpath "$IMAGE_RAW")" ]] ||
        die "Loop backing file mismatch: $backing_file"

    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS \
        "$TARGET_DEVICE" >"$TARGET_LOG"

    log "Etcher image loop target: $TARGET_DEVICE"
}

finalize_image_output() {
    local output_dir
    local output_name

    [[ "$OUTPUT_MODE" == "etcher-image" ]] || return 0

    sync
    detach_image_loop 1

    log "Compressing validated image to: $IMAGE_OUTPUT"
    xz \
        --threads="$IMAGE_XZ_THREADS" \
        "-$IMAGE_XZ_LEVEL" \
        --check=crc64 \
        --force \
        -- "$IMAGE_RAW"

    need_nonempty_file "$IMAGE_OUTPUT"

    output_dir="$(dirname -- "$IMAGE_OUTPUT")"
    output_name="$(basename -- "$IMAGE_OUTPUT")"
    (
        cd -- "$output_dir"
        sha256sum -- "$output_name" >"$output_name.sha256"
    )

    need_nonempty_file "$IMAGE_OUTPUT.sha256"
    log "Etcher image: $IMAGE_OUTPUT"
    log "Image checksum: $IMAGE_OUTPUT.sha256"
}

validate_target_device() {
    local target_type
    local target_real
    local target_size
    local removable
    local transport
    local mounted_children

    [[ "$TARGET_DEVICE" == /dev/* ]] ||
        die "TARGET_DEVICE must be a /dev path: $TARGET_DEVICE"

    [[ -b "$TARGET_DEVICE" ]] ||
        die "Target block device not found: $TARGET_DEVICE"

    target_type="$(lsblk -dnro TYPE "$TARGET_DEVICE" 2>/dev/null || true)"
    [[ "$target_type" == "disk" ]] ||
        die "TARGET_DEVICE must be an entire disk, not a partition: $TARGET_DEVICE"

    case "$TARGET_DEVICE" in
        /dev/sda | /dev/vda | /dev/xvda | /dev/nvme0n1 | /dev/mmcblk0)
            die "Refusing dangerous host-disk target: $TARGET_DEVICE"
            ;;
    esac

    target_real="$(readlink -f -- "$TARGET_DEVICE")"
    target_size="$(blockdev --getsize64 "$TARGET_DEVICE")"

    ((target_size >= 4 * 1024 * 1024 * 1024)) ||
        die "Target device is unexpectedly small: $TARGET_DEVICE"

    removable="$(lsblk -dnro RM "$TARGET_DEVICE" 2>/dev/null || true)"
    transport="$(lsblk -dnro TRAN "$TARGET_DEVICE" 2>/dev/null || true)"

    if [[ "$removable" != "1" && "$transport" != "usb" && "$transport" != "mmc" ]]; then
        die "Target does not appear removable: device=$TARGET_DEVICE transport=${transport:-unknown} removable=${removable:-unknown}"
    fi

    mounted_children="$(
        lsblk -nrpo NAME,MOUNTPOINTS "$TARGET_DEVICE" |
            awk 'NF > 1 && $2 != "" {print}'
    )"

    if [[ -n "$mounted_children" ]]; then
        printf '%s\n' "$mounted_children" >&2
        die "Target or one of its partitions is mounted."
    fi

    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MODEL,SERIAL,TRAN,RM,MOUNTPOINTS \
        "$TARGET_DEVICE" >"$TARGET_LOG"

    [[ -e "/sys/class/block/$(basename "$target_real")" ]] ||
        die "Target sysfs entry is missing: $TARGET_DEVICE"
}

validate_source_inputs() {
    local stage

    if [[ "$BUILD_MODE" == "image" ]]; then
        [[ -f "$BASE_IMAGE_BUILDER" ]] ||
            die "Base image builder not found: $BASE_IMAGE_BUILDER"

        [[ -x "$BASE_IMAGE_BUILDER" ]] ||
            die "Base image builder is not executable: $BASE_IMAGE_BUILDER"

        need_file "$SCRIPT_DIR/config/source-pins.env"
    fi

    [[ -f "$SCRIPT_DIR/lib/common.sh" ]] ||
        die "Missing common library: $SCRIPT_DIR/lib/common.sh"

    for stage in "${stages[@]}"; do
        need_file "$SCRIPT_DIR/$stage"
        [[ -x "$SCRIPT_DIR/$stage" ]] ||
            die "Stage is not executable: $SCRIPT_DIR/$stage"
    done
}

confirm_target_destruction() {
    local answer=""

    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS \
        "$TARGET_DEVICE" || true

    printf '\nWARNING: this build will erase the entire target device.\n' >&2
    printf 'Device path: %s\n\n' "$TARGET_DEVICE" >&2

    if [[ "$CONFIRM_WRITE" == "1" ]]; then
        log "Non-interactive destructive-write confirmation accepted."
        return 0
    fi

    read -r -p "Type I-UNDERSTAND to continue: " answer
    [[ "$answer" == "I-UNDERSTAND" ]] || die "Confirmation not given."
}

write_summary() {
    local finish_epoch
    local elapsed

    finish_epoch="$(date +%s)"
    elapsed=$((finish_epoch - BUILD_START_EPOCH))

    {
        printf 'Build ID: %s\n' "$BUILD_ID"
        printf 'Completed UTC: %s\n' "$(timestamp)"
        printf 'Status: SUCCESS\n'
        printf 'Build mode: %s\n' "$BUILD_MODE"
        printf 'Output mode: %s\n' "$OUTPUT_MODE"
        printf 'Duration: %s\n' "$(duration_text "$elapsed")"
        printf 'Kernel source: %s\n' "$KERNEL_DIR"
        printf 'AIC repository: %s\n' "$AIC_REPO"
        printf 'Kernel release: %s\n' "$(<"$BUILD_ROOT/.one-shot-kernel-release")"
        printf 'Kernel input fingerprint: %s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'AIC8800 input fingerprint: %s\n' "$AIC_INPUT_FINGERPRINT"
        printf 'Forced kernel rebuild: %s\n' "$KERNEL_REBUILD"
        printf 'Forced AIC8800 rebuild: %s\n' "$AIC_REBUILD"
        printf 'Signed update bundle: %s\n' \
            "$(<"$BUILD_ROOT/.one-shot-update-bundle")"
        printf 'Single-kernel steady state: yes\n'
        printf 'Persistent Linux 5.15 recovery entry retained: no\n'

        if [[ "$BUILD_MODE" == "image" && "$OUTPUT_MODE" == "device" ]]; then
            printf 'Target device: %s\n' "$TARGET_DEVICE"
        elif [[ "$BUILD_MODE" == "image" ]]; then
            printf 'Etcher image: %s\n' "$IMAGE_OUTPUT"
            printf 'Etcher image SHA-256: %s\n' "$IMAGE_OUTPUT.sha256"
            printf 'Uncompressed image size GiB: %s\n' "$IMAGE_SIZE_GIB"
        fi

        printf 'Expected GMAC0 interface: eth0\n'
        printf 'Expected GMAC1 interface: eth1\n'
        printf 'Expected AIC8800 interface: wlan0\n'
        printf 'Build log: %s\n' "$BUILD_LOG"
        printf 'Command log: %s\n' "$COMMAND_LOG"
        printf 'Stage timing: %s\n' "$STAGE_LOG"
    } >"$SUMMARY_LOG"
}

main() {
    local total_elapsed
    local stage

    initialize_logging

    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    trap on_exit EXIT

    log "Cubie A5E one-shot build starting"
    log "Build ID: $BUILD_ID"
    log "Build log: $BUILD_LOG"

    [[ "$(id -u)" -eq 0 ]] || die "Run this wrapper with sudo/root."

    validate_integer "JOBS" "$JOBS"

    case "$CONFIRM_WRITE" in
        0 | 1) ;;
        *) die "CONFIRM_WRITE must be 0 or 1, got: $CONFIRM_WRITE" ;;
    esac

    case "$BUILD_MODE" in
        image | update-bundle) ;;
        *) die "BUILD_MODE must be image or update-bundle, got: $BUILD_MODE" ;;
    esac

    validate_cache_settings
    validate_output_settings
    validate_paths
    install_required_host_packages
    require_host_commands
    validate_source_inputs
    compute_build_fingerprints
    acquire_build_lock

    if [[ "$BUILD_MODE" == "image" ]]; then
        if [[ "$OUTPUT_MODE" == "device" ]]; then
            validate_target_device
            confirm_target_destruction
        else
            prepare_image_target
        fi
        sync
        udevadm settle
    fi

    capture_environment

    for stage in "${stages[@]}"; do
        run_stage "$stage"
    done

    sync

    if [[ "$BUILD_MODE" == "image" ]]; then
        udevadm settle
        finalize_image_output
    fi

    write_summary
    BUILD_SUCCEEDED=1

    total_elapsed=$(($(date +%s) - BUILD_START_EPOCH))

    log "============================================================"
    log "ONE-SHOT BUILD COMPLETED"
    log "Build ID: $BUILD_ID"
    log "Total duration: $(duration_text "$total_elapsed")"
    log "Build mode: $BUILD_MODE"
    log "Output mode: $OUTPUT_MODE"
    log "Kernel source: $KERNEL_DIR"
    log "Kernel release: $(<"$BUILD_ROOT/.one-shot-kernel-release")"
    log "Kernel cache fingerprint: $KERNEL_INPUT_FINGERPRINT"
    log "AIC8800 cache fingerprint: $AIC_INPUT_FINGERPRINT"
    log "Signed update bundle: $(<"$BUILD_ROOT/.one-shot-update-bundle")"
    log "Expected interfaces: GMAC0=eth0, GMAC1=eth1, AIC8800=wlan0"

    if [[ "$BUILD_MODE" == "image" && "$OUTPUT_MODE" == "device" ]]; then
        log "Target device: $TARGET_DEVICE"
        log "Image contains one managed kernel and no Linux 5.15 recovery entry."
    elif [[ "$BUILD_MODE" == "image" ]]; then
        log "Etcher image: $IMAGE_OUTPUT"
        log "Etcher image SHA-256: $IMAGE_OUTPUT.sha256"
        log "Image contains one managed kernel and no Linux 5.15 recovery entry."
    fi

    log "Build summary: $SUMMARY_LOG"
    log "Build log: $BUILD_LOG"
    log "Command log: $COMMAND_LOG"
    log "============================================================"
}

main "$@"
