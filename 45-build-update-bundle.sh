#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="BUNDLE"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${AIC_REPO:?AIC_REPO is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${LINUX_REF:?LINUX_REF is not set}"
: "${LINUX_EXPECTED_COMMIT:?LINUX_EXPECTED_COMMIT is not set}"
: "${AIC_REF:?AIC_REF is not set}"
: "${AIC_EXPECTED_COMMIT:?AIC_EXPECTED_COMMIT is not set}"

readonly KERNEL_RELEASE_FILE="$BUILD_ROOT/.one-shot-kernel-release"
readonly AIC_MODULE_LIST="$BUILD_ROOT/.one-shot-aic-modules"
readonly UPDATE_VERSION_FILE="$BUILD_ROOT/.one-shot-update-version"
readonly UPDATE_BUNDLE_FILE="$BUILD_ROOT/.one-shot-update-bundle"
readonly UPDATE_PUBLIC_KEY_FILE="$BUILD_ROOT/.one-shot-update-public-key"
readonly IMAGE_SRC="$KERNEL_DIR/arch/arm64/boot/Image"
readonly CONFIG_SRC="$KERNEL_DIR/.config"
readonly DTB_SRC="$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb"
readonly FIRMWARE_SRC="$AIC_REPO/src/SDIO/driver_fw/fw/aic8800D80"
readonly SIGNING_DIR="${SIGNING_DIR:-$BUILD_ROOT/update-signing}"
readonly PRIVATE_KEY="${UPDATE_PRIVATE_KEY:-$SIGNING_DIR/cubie-a5e-update-private.pem}"
readonly PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-$SIGNING_DIR/cubie-a5e-update-public.pem}"
readonly BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-$BUILD_ROOT/update-bundles}"
readonly BUNDLE_WORK_ROOT="${BUNDLE_WORK_ROOT:-$BUILD_ROOT/update-bundle-work}"
readonly CACHE_DIR="$BUILD_ROOT/cache"
readonly BUNDLE_CACHE_STATE="$CACHE_DIR/update-bundle.env"

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly BUNDLE_REPORT="$LOG_DIR/update-bundle-report.txt"
else
    readonly BUNDLE_REPORT="$BUILD_ROOT/.one-shot-update-bundle-report.txt"
fi

KERNEL_RELEASE=""
UPDATE_VERSION=""
BUNDLE_PATH=""
WORK_DIR=""
PAYLOAD_ROOT=""
BUNDLE_INPUT_FINGERPRINT=""
BUNDLE_CACHE_REUSED=0

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command is missing: $1"
}

require_nonempty_file() {
    [[ -s "$1" ]] ||
        die "Required file is missing or empty: $1"
}

cache_value() {
    local key="$1"

    awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$BUNDLE_CACHE_STATE" 2>/dev/null
}

public_key_fingerprint() {
    openssl pkey \
        -pubin \
        -in "$PUBLIC_KEY" \
        -outform DER |
        sha256sum |
        awk '{print $1}'
}

compute_bundle_fingerprint() {
    local firmware_file
    local module
    local safe_version

    BUNDLE_INPUT_FINGERPRINT="$({
        printf 'cache-format=2\n'
        printf 'update-version=%s\n' "$UPDATE_VERSION"
        printf 'kernel-release=%s\n' "$KERNEL_RELEASE"
        printf 'linux-ref=%s\n' "$LINUX_REF"
        printf 'linux-expected-commit=%s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'aic-ref=%s\n' "$AIC_REF"
        printf 'aic-expected-commit=%s\n' "$AIC_EXPECTED_COMMIT"
        printf 'kernel-tree-commit=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        printf 'aic-commit=%s\n' "$(git -C "$AIC_REPO" rev-parse HEAD)"
        printf 'public-key-fingerprint=%s\n' "$(public_key_fingerprint)"
        printf 'stage-script-sha256=%s\n' \
            "$(sha256sum -- "$SCRIPT_DIR/45-build-update-bundle.sh" | awk '{print $1}')"
        printf 'kernel-image-sha256=%s\n' \
            "$(sha256sum -- "$IMAGE_SRC" | awk '{print $1}')"
        printf 'kernel-config-sha256=%s\n' \
            "$(sha256sum -- "$CONFIG_SRC" | awk '{print $1}')"
        printf 'board-dtb-sha256=%s\n' \
            "$(sha256sum -- "$DTB_SRC" | awk '{print $1}')"

        while IFS= read -r module; do
            [[ -n "$module" ]] || continue
            printf 'module=%s:%s\n' \
                "$(basename -- "$module")" \
                "$(sha256sum -- "$module" | awk '{print $1}')"
        done <"$AIC_MODULE_LIST"

        while IFS= read -r -d '' firmware_file; do
            printf 'firmware=%s:%s\n' \
                "${firmware_file#"$FIRMWARE_SRC"/}" \
                "$(sha256sum -- "$firmware_file" | awk '{print $1}')"
        done < <(find "$FIRMWARE_SRC" -type f -print0 | sort -z)
    } | sha256sum | awk '{print $1}')"

    safe_version="${UPDATE_VERSION//+/_}"
    BUNDLE_PATH="$BUNDLE_OUTPUT_DIR/cubie-a5e-kernel-${safe_version}.tar.gz"
}

validated_bundle_cache_available() {
    local actual_bundle_hash
    local cached_bundle_hash

    [[ -s "$BUNDLE_CACHE_STATE" ]] || return 1
    [[ "$(cache_value cache_format)" == "2" ]] || return 1
    [[ "$(cache_value fingerprint)" == "$BUNDLE_INPUT_FINGERPRINT" ]] || return 1
    [[ "$(cache_value bundle_path)" == "$BUNDLE_PATH" ]] || return 1
    [[ "$(cache_value public_key_fingerprint)" == "$(public_key_fingerprint)" ]] || return 1
    [[ -s "$BUNDLE_PATH" ]] || return 1

    cached_bundle_hash="$(cache_value bundle_sha256)"
    [[ "$cached_bundle_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_bundle_hash="$(sha256sum -- "$BUNDLE_PATH" | awk '{print $1}')"
    [[ "$actual_bundle_hash" == "$cached_bundle_hash" ]] || return 1

    local manifest_content

    tar -tzf "$BUNDLE_PATH" >/dev/null 2>&1 || return 1
    manifest_content="$(tar -xOf "$BUNDLE_PATH" manifest.env 2>/dev/null)" || return 1

    grep -Fx -- "UPDATE_VERSION=$UPDATE_VERSION" <<<"$manifest_content" >/dev/null || return 1
    grep -Fx -- "KERNEL_RELEASE=$KERNEL_RELEASE" <<<"$manifest_content" >/dev/null || return 1
    grep -Fx -- "KERNEL_BASE_REF=$LINUX_REF" <<<"$manifest_content" >/dev/null || return 1
    grep -Fx -- "KERNEL_BASE_COMMIT=$LINUX_EXPECTED_COMMIT" <<<"$manifest_content" >/dev/null || return 1
    grep -Fx -- "KERNEL_TREE_COMMIT=$(git -C "$KERNEL_DIR" rev-parse HEAD)" <<<"$manifest_content" >/dev/null || return 1
    grep -Fx -- "AIC_SOURCE_REF=$AIC_REF" <<<"$manifest_content" >/dev/null || return 1
    grep -Fx -- "AIC_SOURCE_COMMIT=$AIC_EXPECTED_COMMIT" <<<"$manifest_content" >/dev/null || return 1

    openssl dgst \
        -sha256 \
        -verify "$PUBLIC_KEY" \
        -signature <(tar -xOf "$BUNDLE_PATH" SHA256SUMS.sig 2>/dev/null) \
        <(tar -xOf "$BUNDLE_PATH" SHA256SUMS 2>/dev/null) \
        >/dev/null 2>&1 || return 1

    return 0
}

write_bundle_cache_state() {
    local temporary_state

    mkdir -p -- "$CACHE_DIR"
    temporary_state="$(mktemp "$CACHE_DIR/.update-bundle.XXXXXX")"

    {
        printf 'cache_format=2\n'
        printf 'fingerprint=%s\n' "$BUNDLE_INPUT_FINGERPRINT"
        printf 'bundle_path=%s\n' "$BUNDLE_PATH"
        printf 'bundle_sha256=%s\n' "$(sha256sum -- "$BUNDLE_PATH" | awk '{print $1}')"
        printf 'public_key_fingerprint=%s\n' "$(public_key_fingerprint)"
    } >"$temporary_state"

    chmod 0644 "$temporary_state"
    mv -f -- "$temporary_state" "$BUNDLE_CACHE_STATE"
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT

validate_inputs() {
    local firmware_name
    local module
    local module_count=0

    require_nonempty_file "$KERNEL_RELEASE_FILE"
    require_nonempty_file "$AIC_MODULE_LIST"
    require_nonempty_file "$IMAGE_SRC"
    require_nonempty_file "$CONFIG_SRC"
    require_nonempty_file "$DTB_SRC"
    need_dir "$FIRMWARE_SRC"

    for firmware_name in \
        fw_patch_table_8800d80_u02.bin \
        fw_adid_8800d80_u02.bin \
        fw_patch_8800d80_u02.bin \
        fmacfw_8800d80_u02.bin; do
        require_nonempty_file "$FIRMWARE_SRC/$firmware_name"
    done

    KERNEL_RELEASE="$(tr -d '[:space:]' <"$KERNEL_RELEASE_FILE")"

    [[ "$KERNEL_RELEASE" =~ ^[A-Za-z0-9._+-]+$ ]] ||
        die "Invalid kernel release: $KERNEL_RELEASE"

    [[ "$LINUX_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "LINUX_REF must pin an exact point release, got: $LINUX_REF"
    [[ "$LINUX_EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
        die "LINUX_EXPECTED_COMMIT is not a full 40-character Git commit."
    [[ "$AIC_EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
        die "AIC_EXPECTED_COMMIT is not a full 40-character Git commit."

    git -C "$KERNEL_DIR" rev-parse "$LINUX_EXPECTED_COMMIT^{commit}" >/dev/null 2>&1 ||
        die "Pinned kernel base commit is unavailable: $LINUX_EXPECTED_COMMIT"
    git -C "$KERNEL_DIR" merge-base --is-ancestor "$LINUX_EXPECTED_COMMIT" HEAD ||
        die "Kernel tree is not based on pinned source commit $LINUX_EXPECTED_COMMIT."
    [[ "$(git -C "$AIC_REPO" rev-parse HEAD)" == "$AIC_EXPECTED_COMMIT" ]] ||
        die "AIC8800 source no longer matches pinned commit $AIC_EXPECTED_COMMIT."

    case "$KERNEL_RELEASE" in
        "${LINUX_REF#v}" | "${LINUX_REF#v}"+*) ;;
        *)
            die "Kernel release $KERNEL_RELEASE does not belong to pinned source $LINUX_REF."
            ;;
    esac

    while IFS= read -r module; do
        [[ -n "$module" ]] || continue
        local module_vermagic

        require_nonempty_file "$module"
        module_vermagic="$(modinfo -F vermagic "$module" | awk '{print $1}')"
        [[ "$module_vermagic" == "$KERNEL_RELEASE" ]] ||
            die "AIC module $(basename -- "$module") vermagic $module_vermagic does not match $KERNEL_RELEASE."
        module_count=$((module_count + 1))
    done <"$AIC_MODULE_LIST"

    ((module_count == 2)) ||
        die "AIC module manifest must contain exactly two modules."

    grep -E '/aic8800_bsp\.ko$' "$AIC_MODULE_LIST" >/dev/null ||
        die "AIC module manifest lacks aic8800_bsp.ko"
    grep -E '/aic8800_fdrv\.ko$' "$AIC_MODULE_LIST" >/dev/null ||
        die "AIC module manifest lacks aic8800_fdrv.ko"
}

ensure_signing_key() {
    install -d -m 0700 -- "$SIGNING_DIR"

    if [[ ! -s "$PRIVATE_KEY" ]]; then
        log "Generating the persistent Cubie A5E update signing key."
        openssl genpkey \
            -algorithm RSA \
            -pkeyopt rsa_keygen_bits:3072 \
            -out "$PRIVATE_KEY"
        chmod 0600 "$PRIVATE_KEY"
    fi

    openssl pkey \
        -in "$PRIVATE_KEY" \
        -pubout \
        -out "$PUBLIC_KEY"

    chmod 0600 "$PRIVATE_KEY"
    chmod 0644 "$PUBLIC_KEY"
    printf '%s\n' "$PUBLIC_KEY" >"$UPDATE_PUBLIC_KEY_FILE"

    openssl pkey -in "$PRIVATE_KEY" -noout -check >/dev/null ||
        die "The update private key failed validation."
    openssl pkey -pubin -in "$PUBLIC_KEY" -noout >/dev/null ||
        die "The update public key failed validation."
}

derive_update_version() {
    local kernel_commit
    local aic_commit

    kernel_commit="$(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD)"
    aic_commit="$(git -C "$AIC_REPO" rev-parse --short=12 HEAD)"

    [[ "$kernel_commit" =~ ^[0-9a-f]{12}$ ]] ||
        die "Could not derive the kernel source revision."
    [[ "$aic_commit" =~ ^[0-9a-f]{12}$ ]] ||
        die "Could not derive the AIC8800 source revision."

    UPDATE_VERSION="${KERNEL_RELEASE}+k${kernel_commit}.a${aic_commit}"
    printf '%s\n' "$UPDATE_VERSION" >"$UPDATE_VERSION_FILE"
}

prepare_payload() {
    local module
    local module_destination
    local firmware_source
    local firmware_target

    install -d -m 0755 -- "$BUNDLE_WORK_ROOT" "$BUNDLE_OUTPUT_DIR"
    WORK_DIR="$(mktemp -d -p "$BUNDLE_WORK_ROOT" bundle.XXXXXX)"
    PAYLOAD_ROOT="$WORK_DIR/payload/rootfs"

    install -d -m 0755 -- "$PAYLOAD_ROOT"

    log "Staging in-tree modules for signed update bundle."
    make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        INSTALL_MOD_PATH="$PAYLOAD_ROOT" \
        modules_install

    rm -f -- \
        "$PAYLOAD_ROOT/lib/modules/$KERNEL_RELEASE/build" \
        "$PAYLOAD_ROOT/lib/modules/$KERNEL_RELEASE/source"

    module_destination="$PAYLOAD_ROOT/lib/modules/$KERNEL_RELEASE/updates/aic8800"
    install -d -m 0755 -- "$module_destination"

    while IFS= read -r module; do
        [[ -n "$module" ]] || continue
        install -m 0644 -- "$module" "$module_destination/"
    done <"$AIC_MODULE_LIST"

    install -D -m 0644 \
        "$IMAGE_SRC" \
        "$PAYLOAD_ROOT/boot/vmlinuz-$KERNEL_RELEASE"
    install -D -m 0644 \
        "$CONFIG_SRC" \
        "$PAYLOAD_ROOT/boot/config-$KERNEL_RELEASE"
    install -D -m 0644 \
        "$DTB_SRC" \
        "$PAYLOAD_ROOT/usr/lib/linux-image-$KERNEL_RELEASE/allwinner/sun55i-a527-cubie-a5e.dtb"

    firmware_source="$FIRMWARE_SRC"
    firmware_target="$PAYLOAD_ROOT/lib/firmware/aic8800_fw/SDIO/aic8800D80"
    need_dir "$firmware_source"
    install -d -m 0755 -- "$firmware_target"
    rsync -a "$firmware_source/" "$firmware_target/"
}

write_manifest() {
    {
        printf 'FORMAT_VERSION=1\n'
        printf 'BOARD_ID=radxa-cubie-a5e\n'
        printf 'UPDATE_TYPE=kernel\n'
        printf 'UPDATE_VERSION=%s\n' "$UPDATE_VERSION"
        printf 'KERNEL_RELEASE=%s\n' "$KERNEL_RELEASE"
        printf 'MIN_UPDATER_VERSION=1\n'
        printf 'KERNEL_BASE_REF=%s\n' "$LINUX_REF"
        printf 'KERNEL_BASE_COMMIT=%s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'KERNEL_TREE_COMMIT=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        printf 'AIC_SOURCE_REF=%s\n' "$AIC_REF"
        printf 'AIC_SOURCE_COMMIT=%s\n' "$AIC_EXPECTED_COMMIT"
    } >"$WORK_DIR/manifest.env"
}

sign_and_package() {
    local safe_version
    local temporary_bundle

    (
        cd "$WORK_DIR"
        find manifest.env payload \
            -type f \
            -print0 |
            sort -z |
            xargs -0 sha256sum >SHA256SUMS
    )

    openssl dgst \
        -sha256 \
        -sign "$PRIVATE_KEY" \
        -out "$WORK_DIR/SHA256SUMS.sig" \
        "$WORK_DIR/SHA256SUMS"

    openssl dgst \
        -sha256 \
        -verify "$PUBLIC_KEY" \
        -signature "$WORK_DIR/SHA256SUMS.sig" \
        "$WORK_DIR/SHA256SUMS" >/dev/null ||
        die "Generated bundle signature failed self-verification."

    (
        cd "$WORK_DIR"
        sha256sum -c SHA256SUMS >/dev/null
    ) || die "Generated bundle checksums failed self-verification."

    safe_version="${UPDATE_VERSION//+/_}"
    BUNDLE_PATH="$BUNDLE_OUTPUT_DIR/cubie-a5e-kernel-${safe_version}.tar.gz"
    temporary_bundle="$BUNDLE_PATH.tmp"

    tar -C "$WORK_DIR" \
        -czf "$temporary_bundle" \
        manifest.env \
        SHA256SUMS \
        SHA256SUMS.sig \
        payload

    tar -tzf "$temporary_bundle" >/dev/null ||
        die "Generated update bundle failed archive validation."

    mv -f -- "$temporary_bundle" "$BUNDLE_PATH"
    printf '%s\n' "$BUNDLE_PATH" >"$UPDATE_BUNDLE_FILE"
}

write_report() {
    local key_fingerprint

    key_fingerprint="$(public_key_fingerprint)"

    {
        printf 'Cubie A5E signed update bundle report\n'
        printf '=====================================\n'
        printf 'Status: PASS\n'
        printf 'Update version: %s\n' "$UPDATE_VERSION"
        printf 'Kernel release: %s\n' "$KERNEL_RELEASE"
        printf 'Kernel source ref: %s\n' "$LINUX_REF"
        printf 'Kernel base commit: %s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'Kernel patched tree commit: %s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        printf 'AIC source ref: %s\n' "$AIC_REF"
        printf 'AIC source commit: %s\n' "$AIC_EXPECTED_COMMIT"
        printf 'Bundle input fingerprint: %s\n' "$BUNDLE_INPUT_FINGERPRINT"
        printf 'Validated bundle cache reused: %s\n' "$BUNDLE_CACHE_REUSED"
        printf 'Bundle: %s\n' "$BUNDLE_PATH"
        printf 'Bundle SHA256: %s\n' "$(sha256sum "$BUNDLE_PATH" | awk '{print $1}')"
        printf 'Signing public key: %s\n' "$PUBLIC_KEY"
        printf 'Signing key fingerprint: %s\n' "$key_fingerprint"
        printf 'Private key: %s\n' "$PRIVATE_KEY"
        printf 'Private key installed in image: no\n'
        printf 'Signature verification: PASS\n'
        printf 'Checksum verification: PASS\n'
    } >"$BUNDLE_REPORT"
}

main() {
    local command_name

    for command_name in \
        awk \
        basename \
        chmod \
        find \
        git \
        grep \
        install \
        make \
        mktemp \
        modinfo \
        mv \
        openssl \
        rsync \
        sha256sum \
        sort \
        tar \
        xargs; do
        require_command "$command_name"
    done

    [[ "$(id -u)" -eq 0 ]] ||
        die "Run this stage as root."

    need_dir "$BUILD_ROOT"
    need_dir "$KERNEL_DIR"
    need_dir "$AIC_REPO"
    need_file "$SCRIPT_DIR/assets/cubie-a5e-update"
    need_file "$SCRIPT_DIR/assets/rsetup"
    need_file "$SCRIPT_DIR/assets/cubie-a5e-update-finalize.service"
    need_file "$SCRIPT_DIR/assets/99-cubie-a5e-managed-kernel"

    validate_inputs
    ensure_signing_key
    derive_update_version
    compute_bundle_fingerprint

    if validated_bundle_cache_available; then
        BUNDLE_CACHE_REUSED=1
        printf '%s\n' "$BUNDLE_PATH" >"$UPDATE_BUNDLE_FILE"
        write_report

        log "Reusing validated signed update bundle: $BUNDLE_PATH"
        log "Bundle cache fingerprint: $BUNDLE_INPUT_FINGERPRINT"
        log "Bundle report: $BUNDLE_REPORT"
        return 0
    fi

    BUNDLE_CACHE_REUSED=0
    rm -f -- "$BUNDLE_CACHE_STATE"
    log "Update-bundle cache miss; staging and signing a fresh bundle."

    prepare_payload
    write_manifest
    sign_and_package
    write_report
    write_bundle_cache_state

    log "Signed update bundle created: $BUNDLE_PATH"
    log "Update-bundle cache state: $BUNDLE_CACHE_STATE"
    log "Back up the private signing key securely: $PRIVATE_KEY"
    log "Bundle report: $BUNDLE_REPORT"
}

main "$@"
