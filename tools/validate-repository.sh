#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT_ROOT

readonly SOURCE_PINS="$PROJECT_ROOT/config/source-pins.env"
readonly STAGE27="$PROJECT_ROOT/27-backport-spi.sh"
readonly STAGE60="$PROJECT_ROOT/60-install-linux-6.16.sh"
readonly STAGE80="$PROJECT_ROOT/80-validate-image.sh"
readonly NVME_INSTALLER="$PROJECT_ROOT/assets/cubie-a5e-install-nvme"
readonly BASE_WRITER="$PROJECT_ROOT/base/build-debian13-donor-image.sh"
readonly BUILD_WRAPPER="$PROJECT_ROOT/build-cubie-a5e.sh"
readonly RSETUP_WRAPPER="$PROJECT_ROOT/assets/rsetup"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "Required repository file is missing: ${1#$PROJECT_ROOT/}"
}

require_fixed_line() {
    local text="$1"
    local file="$2"
    local message="$3"

    grep -Fxq -- "$text" "$file" || fail "$message"
}

require_text() {
    local text="$1"
    local file="$2"
    local message="$3"

    grep -Fq -- "$text" "$file" || fail "$message"
}

reject_text() {
    local text="$1"
    local file="$2"
    local message="$3"

    if grep -Fq -- "$text" "$file"; then
        fail "$message"
    fi
}

for required in \
    "$SOURCE_PINS" \
    "$STAGE27" \
    "$STAGE60" \
    "$STAGE80" \
    "$NVME_INSTALLER" \
    "$BASE_WRITER" \
    "$BUILD_WRAPPER" \
    "$RSETUP_WRAPPER"; do
    require_file "$required"
done

mapfile -d '' shell_files < <(
    find "$PROJECT_ROOT" \
        -path "$PROJECT_ROOT/build" -prune -o \
        -type f -name '*.sh' -print0 |
        sort -z
)

runtime_programs=(
    "$PROJECT_ROOT/assets/rsetup"
    "$PROJECT_ROOT/assets/cubie-a5e-update"
    "$PROJECT_ROOT/assets/cubie-a5e-install-nvme"
    "$PROJECT_ROOT/assets/ensure-radxa-trixie-repo"
)
readonly runtime_programs

program_files=("${shell_files[@]}" "${runtime_programs[@]}")
readonly program_files

((${#shell_files[@]} > 0)) || fail "No shell programs found."

for program_file in "${program_files[@]}"; do
    [[ -f "$program_file" ]] ||
        fail "Required shell program is missing: ${program_file#$PROJECT_ROOT/}"
    bash -n "$program_file"
    [[ -x "$program_file" ]] ||
        fail "Shell program is not executable: ${program_file#$PROJECT_ROOT/}"
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

legacy_user="psi"
forbidden_legacy_path="/home/${legacy_user}/cubie-a5e-build"
if grep -Il -- "$forbidden_legacy_path" "${source_scan_files[@]}" |
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

# ---------------------------------------------------------------------------
# Reproducible source pins
# ---------------------------------------------------------------------------
require_fixed_line \
    'LINUX_EXPECTED_COMMIT="${LINUX_EXPECTED_COMMIT:-038d61fd642278bab63ee8ef722c50d10ab01e8f}"' \
    "$SOURCE_PINS" \
    "Linux pin is missing."
require_fixed_line \
    'AIC_EXPECTED_COMMIT="${AIC_EXPECTED_COMMIT:-6e076049b719ac2ff7ce5c92786a680407b11cdb}"' \
    "$SOURCE_PINS" \
    "AIC8800 pin is missing."
require_fixed_line \
    'BSP_EXPECTED_COMMIT="${BSP_EXPECTED_COMMIT:-2045a3ca2a01f088c0314dc924bda59d154e363e}"' \
    "$SOURCE_PINS" \
    "Radxa BSP pin is missing."

require_fixed_line \
    'RADXA_UBOOT_VERSION="${RADXA_UBOOT_VERSION:-2018.07-17}"' \
    "$SOURCE_PINS" \
    "Validated Radxa U-Boot 2018.07-17 pin is missing."
require_text \
    'u-boot-aw2501_${RADXA_UBOOT_VERSION}_all.deb' \
    "$SOURCE_PINS" \
    "Radxa u-boot-aw2501 release asset URL is missing."
require_text \
    'u-boot-radxa-cubie-a5e_${RADXA_UBOOT_VERSION}_all.deb' \
    "$SOURCE_PINS" \
    "Radxa Cubie A5E U-Boot release asset URL is missing."

# shellcheck disable=SC1090
source "$SOURCE_PINS"
[[ "$RADXA_UBOOT_VERSION" == "2018.07-17" ]] ||
    fail "RADXA_UBOOT_VERSION does not resolve to the validated 2018.07-17 release."
[[ "$RADXA_UBOOT_COMMON_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    fail "RADXA_UBOOT_COMMON_SHA256 is missing or malformed."
[[ "$RADXA_UBOOT_BOARD_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    fail "RADXA_UBOOT_BOARD_SHA256 is missing or malformed."
[[ "$RADXA_UBOOT_COMMON_SHA256" != "${RADXA_UBOOT_BOARD_SHA256}" ]] ||
    fail "Radxa common and board U-Boot SHA256 pins unexpectedly match."

# ---------------------------------------------------------------------------
# Pipeline wiring
# ---------------------------------------------------------------------------
require_text '"22-backport-pcie.sh"' \
    "$BUILD_WRAPPER" \
    "PCIe backport stage is missing."

require_text 'Install the current Cubie A5E system to NVMe' \
    "$RSETUP_WRAPPER" \
    "rsetup NVMe migration menu is missing."
require_text '"$CUBIE_NVME_INSTALL" --tui' \
    "$RSETUP_WRAPPER" \
    "rsetup does not invoke the managed NVMe installer."

# ---------------------------------------------------------------------------
# Stage 27: proven SPI-NOR timing
# ---------------------------------------------------------------------------
require_text \
    'readonly SPI_REVISION="a523-spi-mainline-backport-v3-pio-spi-nor-20mhz"' \
    "$STAGE27" \
    "Stage 27 revision does not invalidate the old 50 MHz cache."
require_text \
    'spi-max-frequency = <20000000>;' \
    "$STAGE27" \
    "Stage 27 does not enforce the field-validated 20 MHz SPI-NOR frequency."
reject_text \
    'spi-max-frequency = <50000000>;' \
    "$STAGE27" \
    "Stage 27 still contains the known-bad 50 MHz SPI-NOR setting."
require_text \
    'r"(^[ \t]*spi-max-frequency\s*=\s*)<[^>]+>(;)"' \
    "$STAGE27" \
    "Stage 27 does not normalize an already-existing cached SPI-NOR frequency."

# ---------------------------------------------------------------------------
# Stage 60: SPI maintenance and NVMe runtime provisioning
# ---------------------------------------------------------------------------
require_text \
    'readonly NVME_INSTALLER_SRC="$SCRIPT_DIR/assets/cubie-a5e-install-nvme"' \
    "$STAGE60" \
    "Stage 60 NVMe installer source wiring is missing."
require_text 'install_nvme_installer' \
    "$STAGE60" \
    "Stage 60 NVMe installer installation step is missing."
require_text 'mtd-utils' \
    "$STAGE60" \
    "Stage 60 does not install mtd-utils."
require_text 'u-boot-aw2501' \
    "$STAGE60" \
    "Stage 60 does not provision the Radxa aw2501 U-Boot package."
require_text 'u-boot-radxa-cubie-a5e' \
    "$STAGE60" \
    "Stage 60 does not provision the Cubie A5E U-Boot package."
require_text 'stage60-runtime-rootfs-v2-spi-maintenance' \
    "$STAGE60" \
    "Stage 60 cache schema was not bumped for the SPI-maintenance runtime."
require_text 'NVME_INSTALLER_SELF_TEST=PASS' \
    "$STAGE60" \
    "Stage 60 does not persist the NVMe installer self-test result."
require_text 'RADXA_UBOOT_BACKEND=PASS' \
    "$STAGE60" \
    "Stage 60 does not persist the Radxa U-Boot backend validation result."

# ---------------------------------------------------------------------------
# NVMe installer: proven boot-chain and rootfs invariants
# ---------------------------------------------------------------------------
require_text 'iflag=count_bytes' \
    "$NVME_INSTALLER" \
    "NVMe installer boot-chain prefix copy is missing."
require_text 'sgdisk -A 3:set:2 "$TARGET_DISK"' \
    "$NVME_INSTALLER" \
    "NVMe installer partition-3 bootable-attribute restore is missing."
require_text \
    'Target partition 3 is missing the GPT legacy bootable attribute required by SPI U-Boot.' \
    "$NVME_INSTALLER" \
    "NVMe installer bootable-attribute validation is missing."
require_text 'mkfs.ext4 -F -L rootfs -U random' \
    "$NVME_INSTALLER" \
    "NVMe installer fresh root UUID creation is missing."
require_text 'EXPECTED_SPI_FREQUENCY="20000000"' \
    "$NVME_INSTALLER" \
    "NVMe installer does not enforce the field-validated 20 MHz SPI setting."
require_text 'validate_spi_bootloader' \
    "$NVME_INSTALLER" \
    "NVMe installer lacks the live SPI/U-Boot preflight."
require_text \
    'dpkg --compare-versions "$aw2501_version" ge "$MINIMUM_UBOOT_VERSION"' \
    "$NVME_INSTALLER" \
    "NVMe installer lacks the minimum validated SPI U-Boot version check."
require_text \
    'On-board SPI firmware does not contain the installed Cubie A5E U-Boot' \
    "$NVME_INSTALLER" \
    "NVMe installer does not reject an outdated on-board SPI image."
require_text 'normalize_target_runtime_layout' \
    "$NVME_INSTALLER" \
    "NVMe installer lacks target runtime mountpoint normalization."
require_text 'validate_runtime_root_layout "$TARGET_ROOT_MNT" "Target"' \
    "$NVME_INSTALLER" \
    "NVMe installer does not validate target runtime mountpoints and PID1."
require_text 'install -d -m 1777 -- "$TARGET_ROOT_MNT/tmp"' \
    "$NVME_INSTALLER" \
    "NVMe installer does not enforce target /tmp mode 1777."

for exclusion in dev proc run sys tmp mnt media; do
    require_text \
        "--exclude='/${exclusion}/*'" \
        "$NVME_INSTALLER" \
        "NVMe installer does not preserve the /$exclusion mountpoint directory."
    reject_text \
        "--exclude='/${exclusion}/***'" \
        "$NVME_INSTALLER" \
        "NVMe installer still removes the /$exclusion mountpoint directory itself."
done

# ---------------------------------------------------------------------------
# Base donor writer: every generated image gets a unique root UUID
# ---------------------------------------------------------------------------
require_text 'format_root_partition_with_fresh_uuid' \
    "$BASE_WRITER" \
    "Base writer does not use the fresh-root-UUID formatting path."
require_text 'mkfs.ext4 -F -L rootfs -U random "$root_part"' \
    "$BASE_WRITER" \
    "Base writer does not generate a fresh root filesystem UUID."
require_text 'DONOR_ROOT_UUID' \
    "$BASE_WRITER" \
    "Base writer does not retain the donor UUID solely for collision checking."
reject_text 'format_root_partition_preserving_uuid' \
    "$BASE_WRITER" \
    "Base writer still contains the obsolete donor-UUID-preserving formatter."
require_text '/dev/nvme*n*|/dev/mmcblk*|/dev/loop*)' \
    "$BASE_WRITER" \
    "Loop partition naming support is missing."

# ---------------------------------------------------------------------------
# Stage 80: final-image gates for every proven field failure
# ---------------------------------------------------------------------------
require_text \
    'readonly EXPECTED_SPI_FREQUENCY="20000000"' \
    "$STAGE80" \
    "Stage 80 does not validate the proven 20 MHz SPI-NOR setting."
require_text 'validate_spi_maintenance_runtime' \
    "$STAGE80" \
    "Stage 80 lacks SPI-maintenance runtime validation."
require_text 'validate_runtime_root_layout' \
    "$STAGE80" \
    "Stage 80 lacks persistent runtime mountpoint/PID1 validation."
require_text 'storage-nvme-spi-hardening-v2-20260821' \
    "$STAGE80" \
    "Stage 80 revision does not identify the storage/SPI hardening pass."
require_text 'for exclusion in dev proc run sys tmp mnt media; do' \
    "$STAGE80" \
    "Stage 80 does not inspect the full corrected NVMe rsync exclusion set."
require_text 'NVME_INSTALLER_SELF_TEST=PASS' \
    "$STAGE80" \
    "Stage 80 does not validate the Stage 60 NVMe self-test marker."
require_text 'RADXA_UBOOT_BACKEND=PASS' \
    "$STAGE80" \
    "Stage 80 does not validate the Stage 60 U-Boot backend marker."

# ---------------------------------------------------------------------------
# Output modes / Etcher artifact generation
# ---------------------------------------------------------------------------
require_text 'OUTPUT_MODE="${OUTPUT_MODE:-device}"' \
    "$BUILD_WRAPPER" \
    "Direct-device output default is missing."
require_text 'device | etcher-image)' \
    "$BUILD_WRAPPER" \
    "Dual output-mode validation is missing."
require_text 'losetup --find --show --partscan' \
    "$BUILD_WRAPPER" \
    "Etcher-image loop setup is missing."
require_text 'sha256sum -- "$output_name"' \
    "$BUILD_WRAPPER" \
    "Etcher-image checksum generation is missing."

if [[ -s "$PROJECT_ROOT/MANIFEST.sha256" ]]; then
    (
        cd "$PROJECT_ROOT"
        sha256sum --check MANIFEST.sha256
    )
fi

printf 'PASS: repository source validation completed.\n'
