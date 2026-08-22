#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT_ROOT

readonly SOURCE_PINS="$PROJECT_ROOT/config/source-pins.env"
readonly STAGE20="$PROJECT_ROOT/20-backport-gmac1.sh"
readonly STAGE22="$PROJECT_ROOT/22-backport-pcie.sh"
readonly STAGE25="$PROJECT_ROOT/25-apply-hardware-dts.sh"
readonly STAGE27="$PROJECT_ROOT/27-backport-spi.sh"
readonly STAGE30="$PROJECT_ROOT/30-build-kernel.sh"
readonly STAGE40="$PROJECT_ROOT/40-build-aic8800.sh"
readonly STAGE45="$PROJECT_ROOT/45-build-update-bundle.sh"
readonly STAGE60="$PROJECT_ROOT/60-install-managed-kernel.sh"
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
    "$STAGE20" \
    "$STAGE22" \
    "$STAGE25" \
    "$STAGE27" \
    "$STAGE30" \
    "$STAGE40" \
    "$STAGE45" \
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
if [[ -n "$(grep -Il -- "$forbidden_legacy_path" "${source_scan_files[@]}" || true)" ]]; then
    fail "A host-specific legacy home path remains in an active source file."
fi

if [[ -n "$(find "$PROJECT_ROOT" \
    -path "$PROJECT_ROOT/build" -prune -o \
    -type f -size +10M -print -quit)" ]]; then
    fail "A file larger than 10 MiB is present outside build/."
fi

if [[ -n "$(find "$PROJECT_ROOT" \
    -path "$PROJECT_ROOT/build" -prune -o \
    -type f \( -iname '*private*.pem' -o -iname '*.key' \) -print -quit)" ]]; then
    fail "A possible private key is present in repository content."
fi

# ---------------------------------------------------------------------------
# Reproducible source pins
# ---------------------------------------------------------------------------
require_fixed_line \
    'LINUX_REPOSITORY="${LINUX_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git}"' \
    "$SOURCE_PINS" \
    "Official linux-stable repository pin is missing."
require_fixed_line \
    'LINUX_REF="${LINUX_REF:-v6.18.45}"' \
    "$SOURCE_PINS" \
    "Linux 6.18.45 LTS ref pin is missing."
require_fixed_line \
    'LINUX_EXPECTED_COMMIT="${LINUX_EXPECTED_COMMIT:-bf3be28f6721e24961992ebb9e61c0cf21a56806}"' \
    "$SOURCE_PINS" \
    "Linux 6.18.45 LTS commit pin is missing."
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
# Abandoned custom Cubie APT delivery must stay removed
# ---------------------------------------------------------------------------
[[ ! -e "$PROJECT_ROOT/46-build-apt-update-repository.sh" ]] ||
    fail "Obsolete Stage 46 custom APT repository builder is still present."
[[ ! -e "$PROJECT_ROOT/cubie-build-menu.sh" ]] ||
    fail "Standalone cubie-build-menu.sh is obsolete; the menu belongs in build-cubie-a5e.sh."

for apt_removed_file in "$SOURCE_PINS" "$STAGE60" "$STAGE80" "$RSETUP_WRAPPER" "$BUILD_WRAPPER"; do
    reject_text 'CUBIE_APT_REPO_URL' "$apt_removed_file" \
        "Custom Cubie APT repository URL logic remains in ${apt_removed_file#$PROJECT_ROOT/}."
    reject_text 'CUBIE_BOARD_SUPPORT_VERSION' "$apt_removed_file" \
        "Custom Cubie board-support package logic remains in ${apt_removed_file#$PROJECT_ROOT/}."
done
reject_text 'cubie-a5e-board-support' "$STAGE60" \
    "Stage 60 still contains the abandoned custom board-support package bootstrap."
reject_text 'cubie-a5e-kernel-update' "$STAGE60" \
    "Stage 60 still contains the abandoned custom kernel-update package bootstrap."

# ---------------------------------------------------------------------------
# Pipeline wiring
# ---------------------------------------------------------------------------
require_text '"22-backport-pcie.sh"' \
    "$BUILD_WRAPPER" \
    "PCIe backport stage is missing."
require_text '"45-build-update-bundle.sh"' \
    "$BUILD_WRAPPER" \
    "Signed kernel/board update-bundle stage is missing."
require_text 'cleanup_failed_image_output' \
    "$BUILD_WRAPPER" \
    "Build wrapper does not remove failed Etcher-image artifacts."
require_text 'Radxa Cubie A5E Build Manager' \
    "$BUILD_WRAPPER" \
    "Integrated build menu is missing from build-cubie-a5e.sh."
require_text '--menu)' \
    "$BUILD_WRAPPER" \
    "build-cubie-a5e.sh does not expose the explicit --menu entry point."
require_text '--validate)' \
    "$BUILD_WRAPPER" \
    "build-cubie-a5e.sh does not expose repository validation through --validate."
require_text 'BUILD_REQUEST_ENV_PRESENT' \
    "$BUILD_WRAPPER" \
    "Build wrapper does not preserve environment-driven non-interactive automation."
require_text 'Full Debian/Radxa system upgrade' \
    "$RSETUP_WRAPPER" \
    "rsetup does not expose the normal Debian/Radxa full-upgrade path."
require_text 'Cubie A5E signed kernel and board updates' \
    "$RSETUP_WRAPPER" \
    "rsetup does not expose the separate signed Cubie kernel/board updater."

require_text 'Install the current Cubie A5E system to NVMe' \
    "$RSETUP_WRAPPER" \
    "rsetup NVMe migration menu is missing."
require_text '"$CUBIE_NVME_INSTALL" --tui' \
    "$RSETUP_WRAPPER" \
    "rsetup does not invoke the managed NVMe installer."

# ---------------------------------------------------------------------------
# Linux 6.18 LTS migration invariants
# ---------------------------------------------------------------------------
[[ "$LINUX_REPOSITORY" == "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git" ]] ||
    fail "LINUX_REPOSITORY does not resolve to the official linux-stable tree."
[[ "$LINUX_REF" == "v6.18.45" ]] ||
    fail "LINUX_REF does not resolve to the approved v6.18.45 LTS release."
[[ "$LINUX_EXPECTED_COMMIT" == "bf3be28f6721e24961992ebb9e61c0cf21a56806" ]] ||
    fail "LINUX_EXPECTED_COMMIT does not resolve to the approved v6.18.45 commit."

require_text '.cubie-a5e-gmac1-dts-backport' "$STAGE20" \
    "Stage 20 does not use the Linux 6.18 GMAC1 DTS-only backport marker."
require_text 'driver_source=upstream-linux-6.18-lts' "$STAGE20" \
    "Stage 20 still appears to carry the obsolete pre-6.18 GMAC driver backport."
require_text 'pck600_source=upstream-linux-6.18-lts' "$STAGE20" \
    "Stage 20 still appears to carry the obsolete PCK600 backport."
require_text 'regulator-enable-ramp-delay = <150000>;' "$STAGE20" \
    "Stage 20 does not preserve the upstream GMAC1 PHY power ramp delay."

require_text '.cubie-a5e-pcie-vendor-port-lts' "$STAGE22" \
    "Stage 22 does not use the Linux 6.18 LTS PCIe vendor-port marker."
require_text 'dt_layout=mainline-soc-one-cell-v4' "$STAGE22" \
    "Stage 22 PCIe DT layout cache marker is stale."
require_text 'driver_mode=initramfs-modules-v4' "$STAGE22" \
    "Stage 22 PCIe driver-mode cache marker is stale."
require_text '[[ "$LINUX_REF" == v6.18.* ]]' "$STAGE22" \
    "Stage 22 is not explicitly constrained to the reviewed Linux 6.18.y line."

require_text 'regulator-always-on;' "$STAGE25" \
    "Stage 25 does not preserve the always-on Wi-Fi regulator policy."
require_text 'Compiled DTB does not retain the tested 30 mA mmc1 pin drive strength.' "$STAGE25" \
    "Stage 25 does not validate the tested 30 mA SDIO drive strength."

require_text 'merge-base --is-ancestor' "$STAGE30" \
    "Stage 30 does not validate the pinned 6.18.45 commit as the kernel-tree ancestor."
reject_text 'HEAD must equal' "$STAGE30" \
    "Stage 30 still contains the obsolete pristine-HEAD source-pin assumption."

require_text 'fix-linux-6.17-build.patch' "$STAGE40" \
    "Stage 40 does not apply the AIC8800 Linux 6.17+ compatibility patch required by 6.18."
require_text 'fix-linux-6.19-build.patch' "$STAGE40" \
    "Stage 40 does not explicitly identify the 6.19 patch boundary."

require_text 'cache-format=2' "$STAGE45" \
    "Stage 45 bundle cache format was not bumped for the LTS migration."
require_text 'KERNEL_BASE_REF=%s' "$STAGE45" \
    "Stage 45 signed manifest does not record the kernel base ref."
require_text 'KERNEL_BASE_COMMIT=%s' "$STAGE45" \
    "Stage 45 signed manifest does not record the kernel base commit."
require_text 'AIC_SOURCE_COMMIT=%s' "$STAGE45" \
    "Stage 45 signed manifest does not record the AIC source commit."

require_text 'managed-kernel-lts-ready-v1-20260822' "$STAGE60" \
    "Stage 60 is not the version-neutral managed-kernel installer."
reject_text '60-install-linux-6.16.sh' "$BUILD_WRAPPER" \
    "Build wrapper still calls the obsolete Linux-6.16-specific Stage 60 filename."
require_text '"60-install-managed-kernel.sh"' "$BUILD_WRAPPER" \
    "Build wrapper does not call 60-install-managed-kernel.sh."
reject_text 'linux-6.16-one-shot' "$BUILD_WRAPPER" \
    "Build wrapper still hardcodes the old Linux 6.16 workspace."
require_text 'KERNEL_REF_LABEL="${LINUX_REF#v}"' "$BUILD_WRAPPER" \
    "Build wrapper does not derive kernel workspace/artifact naming from LINUX_REF."

# ---------------------------------------------------------------------------
# Stage 27: proven SPI-NOR timing
# ---------------------------------------------------------------------------
require_text \
    'readonly SPI_REVISION="a523-spi-linux-6.18-lts-v4-pio-spi-nor-20mhz"' \
    "$STAGE27" \
    "Stage 27 revision is not the reviewed Linux 6.18 LTS SPI backport."
require_text \
    'spi-max-frequency = <20000000>;' \
    "$STAGE27" \
    "Stage 27 does not enforce the field-validated 20 MHz SPI-NOR frequency."
reject_text \
    'spi-max-frequency = <50000000>;' \
    "$STAGE27" \
    "Stage 27 still contains the known-bad 50 MHz SPI-NOR setting."
require_text \
    'if re.search(r"^[ \t]*spi-max-frequency\s*=", flash_node, flags=re.MULTILINE):' \
    "$STAGE27" \
    "Stage 27 does not detect an already-existing SPI-NOR frequency property."
require_text \
    'r"^([ \t]*spi-max-frequency\s*=\s*)<[^>]+>;"' \
    "$STAGE27" \
    "Stage 27 does not replace an already-existing SPI-NOR frequency property."
require_text \
    'r"\g<1><20000000>;"' \
    "$STAGE27" \
    "Stage 27 does not normalize an existing SPI-NOR frequency to 20 MHz."

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
    "Stage 60 runtime cache schema is missing."
require_text 'NVME_INSTALLER_SELF_TEST=PASS' \
    "$STAGE60" \
    "Stage 60 does not persist the NVMe installer self-test result."
require_text 'RADXA_UBOOT_BACKEND=PASS' \
    "$STAGE60" \
    "Stage 60 does not persist the Radxa U-Boot backend validation result."
require_text '99-cubie-a5e-managed-kernel' \
    "$STAGE60" \
    "Stage 60 does not install the generic-kernel replacement guard."
require_text 'install_update_manager' \
    "$STAGE60" \
    "Stage 60 does not install the signed Cubie update manager."

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
require_text 'grep -F -- "$expected_marker" >/dev/null' \
    "$NVME_INSTALLER" \
    "NVMe installer is missing the pipefail-safe SPI U-Boot marker check."
reject_text 'grep -Fq -- "$expected_marker"' \
    "$NVME_INSTALLER" \
    "NVMe installer has regressed to grep -q in the streaming SPI validation pipeline."
require_text "grep -E '^Attribute flags:" \
    "$NVME_INSTALLER" \
    "NVMe installer is missing the GPT attribute validation."
reject_text "grep -Eq '^Attribute flags:" \
    "$NVME_INSTALLER" \
    "NVMe installer has regressed to grep -q in the sgdisk validation pipeline."
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
require_text 'linux-6.18-lts-validation-v1-20260822' \
    "$STAGE80" \
    "Stage 80 revision does not identify the Linux 6.18 LTS validation pass."
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
require_text 'REQUESTED_TARGET_DEVICE="${TARGET_DEVICE:-}"' \
    "$BUILD_WRAPPER" \
    "Build wrapper does not retain explicit-target detection for safe device writes."
require_text 'device | etcher-image)' \
    "$BUILD_WRAPPER" \
    "Dual output-mode validation is missing."
require_text 'losetup --find --show --partscan' \
    "$BUILD_WRAPPER" \
    "Etcher-image loop setup is missing."
require_text 'sha256sum -- "$output_name"' \
    "$BUILD_WRAPPER" \
    "Etcher-image checksum generation is missing."

printf 'PASS: repository source validation completed.\n'
