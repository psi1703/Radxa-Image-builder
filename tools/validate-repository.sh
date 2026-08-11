#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT_ROOT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mapfile -d '' shell_files < <(
    find "$PROJECT_ROOT" \
        -path "$PROJECT_ROOT/build" -prune -o \
        -type f -name '*.sh' -print0 |
        sort -z
)

runtime_programs=(
    "$PROJECT_ROOT/assets/rsetup"
    "$PROJECT_ROOT/assets/cubie-a5e-update"
    "$PROJECT_ROOT/assets/ensure-radxa-trixie-repo"
)
readonly runtime_programs

program_files=("${shell_files[@]}" "${runtime_programs[@]}")
readonly program_files

((${#shell_files[@]} > 0)) || fail "No shell programs found."

for program_file in "${program_files[@]}"; do
    [[ -f "$program_file" ]] || fail "Required shell program is missing: ${program_file#$PROJECT_ROOT/}"
    bash -n "$program_file"
    [[ -x "$program_file" ]] || fail "Shell program is not executable: ${program_file#$PROJECT_ROOT/}"
done

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=warning "${program_files[@]}"
else
    printf 'WARN: shellcheck is not installed; static analysis skipped.\n' >&2
fi

mapfile -d '' env_files < <(
    find "$PROJECT_ROOT" \
        -path "$PROJECT_ROOT/build" -prune -o \
        -type f -name '*.env' -print0 |
        sort -z
)

source_scan_files=("${program_files[@]}" "${env_files[@]}")
readonly source_scan_files

forbidden_home_path="/home/"psi
if grep -Il -- "$forbidden_home_path" "${source_scan_files[@]}" |
    grep -q .; then
    fail "A host-specific legacy home path remains in an active source file."
fi

if find "$PROJECT_ROOT" \
    -path "$PROJECT_ROOT/build" -prune -o \
    -type f -size +10M -print -quit |
    grep -q .; then
    fail "A file larger than 10 MiB is present outside build/."
fi

if find "$PROJECT_ROOT" \
    -path "$PROJECT_ROOT/build" -prune -o \
    -type f \( -iname '*private*.pem' -o -iname '*.key' \) -print -quit |
    grep -q .; then
    fail "A possible private key is present in repository content."
fi

grep -Fxq \
    'LINUX_EXPECTED_COMMIT="${LINUX_EXPECTED_COMMIT:-038d61fd642278bab63ee8ef722c50d10ab01e8f}"' \
    "$PROJECT_ROOT/config/source-pins.env" || fail "Linux pin is missing."
grep -Fxq \
    'AIC_EXPECTED_COMMIT="${AIC_EXPECTED_COMMIT:-6e076049b719ac2ff7ce5c92786a680407b11cdb}"' \
    "$PROJECT_ROOT/config/source-pins.env" || fail "AIC8800 pin is missing."

grep -Fq 'OUTPUT_MODE="${OUTPUT_MODE:-device}"' \
    "$PROJECT_ROOT/build-cubie-a5e.sh" || fail "Direct-device output default is missing."
grep -Fq 'device | etcher-image)' \
    "$PROJECT_ROOT/build-cubie-a5e.sh" || fail "Dual output-mode validation is missing."
grep -Fq 'losetup --find --show --partscan' \
    "$PROJECT_ROOT/build-cubie-a5e.sh" || fail "Etcher-image loop setup is missing."
grep -Fq 'sha256sum -- "$output_name"' \
    "$PROJECT_ROOT/build-cubie-a5e.sh" || fail "Etcher-image checksum generation is missing."
grep -Fq '/dev/nvme*n*|/dev/mmcblk*|/dev/loop*)' \
    "$PROJECT_ROOT/base/build-debian13-donor-image.sh" || fail "Loop partition naming support is missing."

if [[ -s "$PROJECT_ROOT/MANIFEST.sha256" ]]; then
    (
        cd "$PROJECT_ROOT"
        sha256sum --check MANIFEST.sha256
    )
fi

printf 'PASS: repository source validation completed.\n'
