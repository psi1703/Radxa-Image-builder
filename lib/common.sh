#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

stage_name() {
    printf '%s' "${STAGE_NAME:-BUILD}"
}

log() {
    printf '\n[%s] [%s] %s\n' "$(timestamp)" "$(stage_name)" "$*"
}

warn() {
    printf '\n[%s] [%s] WARNING: %s\n' "$(timestamp)" "$(stage_name)" "$*" >&2
}

die() {
    printf '\n[%s] [%s] ERROR: %s\n' "$(timestamp)" "$(stage_name)" "$*" >&2
    exit 1
}

need_cmd() {
    local command_name="${1:?Command name is required}"
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
}

need_file() {
    local path="${1:?File path is required}"
    [[ -f "$path" ]] || die "Required file not found: $path"
}

need_nonempty_file() {
    local path="${1:?File path is required}"
    [[ -s "$path" ]] || die "Required file is missing or empty: $path"
}

need_dir() {
    local path="${1:?Directory path is required}"
    [[ -d "$path" ]] || die "Required directory not found: $path"
}

need_block_device() {
    local path="${1:?Block-device path is required}"
    [[ -b "$path" ]] || die "Required block device not found: $path"
}

part_path() {
    local disk="${1:?Disk path is required}"
    local part="${2:?Partition number is required}"

    [[ "$part" =~ ^[1-9][0-9]*$ ]] || die "Invalid partition number: $part"

    case "$disk" in
        /dev/mmcblk* | /dev/nvme*n* | /dev/loop*) printf '%sp%s\n' "$disk" "$part" ;;
        /dev/*) printf '%s%s\n' "$disk" "$part" ;;
        *) die "Invalid disk path: $disk" ;;
    esac
}

format_command() {
    local argument
    local output=""
    local quoted=""

    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        [[ -z "$output" ]] || output+=" "
        output+="$quoted"
    done

    printf '%s' "$output"
}

run() {
    local command_text
    local status

    (($# > 0)) || die "run() called without a command."
    command_text="$(format_command "$@")"
    log "+ $command_text"

    set +e
    "$@"
    status=$?
    set -e

    if ((status != 0)); then
        printf '\n[%s] [%s] COMMAND FAILED (%d): %s\n' \
            "$(timestamp)" "$(stage_name)" "$status" "$command_text" >&2
        return "$status"
    fi
}

run_capture() {
    local output_variable="${1:?Output variable name is required}"
    shift
    local command_text
    local output
    local status

    (($# > 0)) || die "run_capture() called without a command."
    command_text="$(format_command "$@")"
    log "+ $command_text"

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e

    printf -v "$output_variable" '%s' "$output"

    if ((status != 0)); then
        printf '%s\n' "$output" >&2
        printf '\n[%s] [%s] COMMAND FAILED (%d): %s\n' \
            "$(timestamp)" "$(stage_name)" "$status" "$command_text" >&2
        return "$status"
    fi
}

write_atomic() {
    local target="${1:?Target path is required}"
    local target_dir
    local target_name
    local temporary
    local mode=""
    local owner=""
    local group=""

    target_dir="$(dirname -- "$target")"
    target_name="$(basename -- "$target")"
    [[ -d "$target_dir" ]] || die "Atomic-write destination directory does not exist: $target_dir"

    temporary="$(mktemp "$target_dir/.${target_name}.tmp.XXXXXX")"

    if [[ -e "$target" ]]; then
        mode="$(stat -c '%a' "$target" 2>/dev/null || true)"
        owner="$(stat -c '%u' "$target" 2>/dev/null || true)"
        group="$(stat -c '%g' "$target" 2>/dev/null || true)"
    fi

    if ! cat >"$temporary"; then
        rm -f -- "$temporary"
        die "Failed writing temporary file for: $target"
    fi

    chmod "${mode:-0644}" "$temporary"
    if [[ -n "$owner" && -n "$group" && "$(id -u)" -eq 0 ]]; then
        chown "$owner:$group" "$temporary"
    fi

    sync "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$target"
}

ensure_unmounted() {
    local path="${1:?Mount path is required}"
    mountpoint -q "$path" && run umount "$path"
    return 0
}

safe_mkdir() {
    local path="${1:?Directory path is required}"
    local mode="${2:-0755}"
    install -d -m "$mode" -- "$path"
}
