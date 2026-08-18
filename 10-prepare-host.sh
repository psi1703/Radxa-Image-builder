#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="PREPARE"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${DOWNLOAD_DIR:?DOWNLOAD_DIR is not set}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${AIC_REPO:?AIC_REPO is not set}"
: "${BASE_IMAGE_BUILDER:?BASE_IMAGE_BUILDER is not set}"
: "${STOCK_IMG_XZ:?STOCK_IMG_XZ is not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE is not set}"
: "${BUILD_MODE:=image}"
: "${KERNEL_LOCALVERSION:?KERNEL_LOCALVERSION is not set}"
: "${KERNEL_INPUT_FINGERPRINT:?KERNEL_INPUT_FINGERPRINT is not set}"
: "${AIC_INPUT_FINGERPRINT:?AIC_INPUT_FINGERPRINT is not set}"
: "${KERNEL_REBUILD:=0}"
: "${AIC_REBUILD:=0}"

readonly LINUX_REPOSITORY="${LINUX_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
readonly LINUX_REF="${LINUX_REF:-v6.16}"
readonly LINUX_EXPECTED_COMMIT="${LINUX_EXPECTED_COMMIT:-038d61fd642278bab63ee8ef722c50d10ab01e8f}"
readonly UPSTREAM_SINCE="${UPSTREAM_SINCE:-2025-06-01}"

readonly AIC_REPOSITORY="${AIC_REPOSITORY:-https://github.com/radxa-pkg/aic8800.git}"
readonly AIC_REF="${AIC_REF:-5.0+git20260123.5f7be68d-7}"
readonly AIC_EXPECTED_COMMIT="${AIC_EXPECTED_COMMIT:-6e076049b719ac2ff7ce5c92786a680407b11cdb}"

readonly STOCK_IMAGE_URL="${STOCK_IMAGE_URL:?STOCK_IMAGE_URL is not set}"
readonly STOCK_IMAGE_SHA512="${STOCK_IMAGE_SHA512:?STOCK_IMAGE_SHA512 is not set}"

readonly KERNEL_CONFIG_SOURCE="${KERNEL_CONFIG_SOURCE:-}"

readonly EXPECTED_KERNEL_DIR="$BUILD_ROOT/linux-6.16-one-shot"
readonly OLD_KERNEL_DIR="$BUILD_ROOT/linux"
readonly EXPECTED_AIC_REPO="$BUILD_ROOT/aic8800-radxa"
readonly EXPECTED_DOWNLOAD_DIR="$BUILD_ROOT/downloads"
readonly EXPECTED_BASE_IMAGE_BUILDER="$SCRIPT_DIR/base/build-debian13-donor-image.sh"
readonly CACHE_DIR="$BUILD_ROOT/cache"
readonly KERNEL_CACHE_STATE="$CACHE_DIR/kernel-build.env"
readonly AIC_CACHE_STATE="$CACHE_DIR/aic8800-build.env"

KERNEL_CACHE_REUSED=0
KERNEL_TREE_REUSED=0
AIC_CACHE_REUSED=0

if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p -- "$LOG_DIR"
    readonly PREPARE_REPORT="$LOG_DIR/host-preparation-report.txt"
    readonly PACKAGE_REPORT="$LOG_DIR/host-packages.txt"
    readonly SOURCE_REPORT="$LOG_DIR/source-revisions.txt"
else
    readonly PREPARE_REPORT="$BUILD_ROOT/.one-shot-host-preparation-report.txt"
    readonly PACKAGE_REPORT="$BUILD_ROOT/.one-shot-host-packages.txt"
    readonly SOURCE_REPORT="$BUILD_ROOT/.one-shot-source-revisions.txt"
fi

require_nonempty_file() {
    local path="$1"

    [[ -s "$path" ]] ||
        die "Required file is missing or empty: $path"
}

cache_value() {
    local cache_file="$1"
    local key="$2"

    awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$cache_file" 2>/dev/null
}

file_matches_cache_hash() {
    local cache_file="$1"
    local key="$2"
    local path="$3"
    local expected_hash
    local actual_hash

    [[ -s "$path" ]] || return 1
    expected_hash="$(cache_value "$cache_file" "$key")"
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash="$(sha256sum -- "$path" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]]
}

origin_matches() {
    local actual="$1"
    local expected="$2"

    [[ "$actual" == "$expected" ||
       "$actual" == "${expected%.git}" ||
       "${actual%.git}" == "${expected%.git}" ]]
}

validate_paths() {
    local build_root_real
    local kernel_dir_real
    local expected_kernel_real
    local old_kernel_real
    local aic_repo_real
    local download_dir_real
    local base_image_builder_real
    local script_dir_real

    build_root_real="$(readlink -m -- "$BUILD_ROOT")"
    kernel_dir_real="$(readlink -m -- "$KERNEL_DIR")"
    expected_kernel_real="$(readlink -m -- "$EXPECTED_KERNEL_DIR")"
    old_kernel_real="$(readlink -m -- "$OLD_KERNEL_DIR")"
    aic_repo_real="$(readlink -m -- "$AIC_REPO")"
    download_dir_real="$(readlink -m -- "$DOWNLOAD_DIR")"
    base_image_builder_real="$(readlink -m -- "$BASE_IMAGE_BUILDER")"
    script_dir_real="$(readlink -m -- "$SCRIPT_DIR")"

    [[ "$build_root_real" == "$script_dir_real/build" ]] ||
        die "BUILD_ROOT must be the repository build directory: $build_root_real"

    [[ "$kernel_dir_real" == "$expected_kernel_real" ]] ||
        die "Unexpected KERNEL_DIR: $kernel_dir_real"

    [[ "$kernel_dir_real" != "$old_kernel_real" ]] ||
        die "Refusing old modified kernel tree: $kernel_dir_real"

    [[ "$aic_repo_real" == "$(readlink -m -- "$EXPECTED_AIC_REPO")" ]] ||
        die "Unexpected AIC_REPO: $aic_repo_real"

    [[ "$download_dir_real" == "$(readlink -m -- "$EXPECTED_DOWNLOAD_DIR")" ]] ||
        die "Unexpected DOWNLOAD_DIR: $download_dir_real"

    [[ "$base_image_builder_real" == "$(readlink -m -- "$EXPECTED_BASE_IMAGE_BUILDER")" ]] ||
        die "Unexpected BASE_IMAGE_BUILDER: $base_image_builder_real"

    [[ "$kernel_dir_real" != "$aic_repo_real" ]] ||
        die "KERNEL_DIR and AIC_REPO must be different directories."
}

install_required_packages() {
    local packages=(
        bc
        binutils-aarch64-linux-gnu
        bison
        build-essential
        ca-certificates
        cpio
        curl
        debootstrap
        device-tree-compiler
        dwarves
        flex
        file
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
        u-boot-tools
        util-linux
        xz-utils
    )
    local missing=()
    local package

    log "Checking required host packages."

    for package in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -qx 'install ok installed'; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log "Installing missing host packages: ${missing[*]}"

        run apt-get update

        run env DEBIAN_FRONTEND=noninteractive \
            apt-get install \
            -y \
            --no-install-recommends \
            "${missing[@]}"
    else
        log "All required host packages are already installed."
    fi

    {
        for package in "${packages[@]}"; do
            dpkg-query -W \
                -f='${binary:Package}\t${Version}\t${Status}\n' \
                "$package"
        done
    } >"$PACKAGE_REPORT"
}

validate_host_commands() {
    local commands=(
        aarch64-linux-gnu-gcc
        apt-get
        awk
        blkid
        chroot
        curl
        debootstrap
        depmod
        dpkg-query
        dtc
        find
        findmnt
        file
        flock
        git
        grep
        head
        lsblk
        make
        mount
        mountpoint
        nm
        openssl
        parted
        patch
        python3
        qemu-aarch64-static
        quilt
        readlink
        readelf
        rsync
        sed
        sha256sum
        sha512sum
        strings
        sync
        tar
        udevadm
        umount
        update-binfmts
        xz
    )
    local command_name

    for command_name in "${commands[@]}"; do
        need_cmd "$command_name"
    done

    need_cmd "${CROSS_COMPILE}gcc"
}

validate_project_inputs() {
    if [[ "$BUILD_MODE" == "update-bundle" ]]; then
        return 0
    fi

    need_file "$BASE_IMAGE_BUILDER"
    [[ -x "$BASE_IMAGE_BUILDER" ]] ||
        die "Base image builder is not executable: $BASE_IMAGE_BUILDER"

}

download_stock_image() {
    local partial_image="$STOCK_IMG_XZ.part"
    local actual_sha512

    [[ "$BUILD_MODE" == "image" ]] || return 0

    mkdir -p -- "$DOWNLOAD_DIR"

    if [[ -s "$STOCK_IMG_XZ" ]]; then
        actual_sha512="$(sha512sum "$STOCK_IMG_XZ" | awk '{print $1}')"
        [[ "$actual_sha512" == "$STOCK_IMAGE_SHA512" ]] ||
            die "Existing donor image checksum is wrong: $STOCK_IMG_XZ"
        log "Using verified cached Radxa donor image."
        return 0
    fi

    log "Downloading the official Radxa r7 donor image."
    run curl \
        --fail \
        --location \
        --retry 3 \
        --continue-at - \
        --output "$partial_image" \
        "$STOCK_IMAGE_URL"

    actual_sha512="$(sha512sum "$partial_image" | awk '{print $1}')"
    [[ "$actual_sha512" == "$STOCK_IMAGE_SHA512" ]] || {
        rm -f -- "$partial_image"
        die "Downloaded donor image failed SHA-512 verification."
    }

    mv -f -- "$partial_image" "$STOCK_IMG_XZ"
    log "Verified donor image: $STOCK_IMG_XZ"
}

validate_kernel_cache() {
    local actual_kernel_release
    local cached_kernel_release
    local tag_commit

    [[ "$KERNEL_REBUILD" == "0" ]] || return 1
    [[ -s "$KERNEL_CACHE_STATE" ]] || return 1
    [[ "$(cache_value "$KERNEL_CACHE_STATE" cache_format)" == "1" ]] || return 1
    [[ "$(cache_value "$KERNEL_CACHE_STATE" fingerprint)" == "$KERNEL_INPUT_FINGERPRINT" ]] || return 1
    [[ -d "$KERNEL_DIR/.git" ]] || return 1
    [[ -s "$KERNEL_DIR/Makefile" ]] || return 1
    [[ -s "$KERNEL_DIR/.config" ]] || return 1
    [[ -s "$KERNEL_DIR/.cubie-a5e-gmac1-upstream-backports" ]] || return 1

    tag_commit="$(git -C "$KERNEL_DIR" rev-parse "$LINUX_REF^{commit}" 2>/dev/null || true)"
    [[ "$tag_commit" == "$LINUX_EXPECTED_COMMIT" ]] || return 1

    git -C "$KERNEL_DIR" merge-base --is-ancestor \
        "$LINUX_EXPECTED_COMMIT" HEAD 2>/dev/null || return 1

    grep -Fxq "CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\"" \
        "$KERNEL_DIR/.config" || return 1
    grep -Fxq '# CONFIG_LOCALVERSION_AUTO is not set' \
        "$KERNEL_DIR/.config" || return 1

    cached_kernel_release="$(cache_value "$KERNEL_CACHE_STATE" kernel_release)"
    actual_kernel_release="$(
        make -s -C "$KERNEL_DIR" \
            ARCH=arm64 \
            CROSS_COMPILE="$CROSS_COMPILE" \
            kernelrelease 2>/dev/null || true
    )"

    [[ -n "$cached_kernel_release" &&
       "$actual_kernel_release" == "$cached_kernel_release" ]] || return 1
    [[ "$(cache_value "$KERNEL_CACHE_STATE" linux_commit)" == \
       "$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || true)" ]] || return 1

    file_matches_cache_hash \
        "$KERNEL_CACHE_STATE" image_sha256 \
        "$KERNEL_DIR/arch/arm64/boot/Image" || return 1
    file_matches_cache_hash \
        "$KERNEL_CACHE_STATE" board_dtb_sha256 \
        "$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb" || return 1
    file_matches_cache_hash \
        "$KERNEL_CACHE_STATE" config_sha256 \
        "$KERNEL_DIR/.config" || return 1
    file_matches_cache_hash \
        "$KERNEL_CACHE_STATE" module_symvers_sha256 \
        "$KERNEL_DIR/Module.symvers" || return 1
    file_matches_cache_hash \
        "$KERNEL_CACHE_STATE" vmlinux_sha256 \
        "$KERNEL_DIR/vmlinux" || return 1

    return 0
}

validate_legacy_kernel_tree() {
    local tag_commit

    [[ "$KERNEL_REBUILD" == "0" ]] || return 1
    [[ ! -e "$KERNEL_CACHE_STATE" ]] || return 1
    [[ -d "$KERNEL_DIR/.git" ]] || return 1
    [[ ! -f "$KERNEL_DIR/.git/CHERRY_PICK_HEAD" ]] || return 1
    [[ ! -f "$KERNEL_DIR/.git/MERGE_HEAD" ]] || return 1
    [[ ! -d "$KERNEL_DIR/.git/rebase-merge" ]] || return 1
    [[ ! -d "$KERNEL_DIR/.git/rebase-apply" ]] || return 1
    [[ -s "$KERNEL_DIR/.config" ]] || return 1
    [[ -s "$KERNEL_DIR/.cubie-a5e-gmac1-upstream-backports" ]] || return 1
    grep -Fxq 'status=complete' \
        "$KERNEL_DIR/.cubie-a5e-gmac1-upstream-backports" || return 1

    tag_commit="$(git -C "$KERNEL_DIR" rev-parse "$LINUX_REF^{commit}" 2>/dev/null || true)"
    [[ "$tag_commit" == "$LINUX_EXPECTED_COMMIT" ]] || return 1
    git -C "$KERNEL_DIR" merge-base --is-ancestor \
        "$LINUX_EXPECTED_COMMIT" HEAD 2>/dev/null || return 1

    [[ -s "$KERNEL_DIR/arch/arm64/boot/Image" ]] || return 1
    [[ -s "$KERNEL_DIR/arch/arm64/boot/dts/allwinner/sun55i-a527-cubie-a5e.dtb" ]] || return 1
    [[ -s "$KERNEL_DIR/Module.symvers" ]] || return 1
    [[ -s "$KERNEL_DIR/vmlinux" ]] || return 1

    make -s -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        kernelrelease >/dev/null 2>&1 || return 1

    return 0
}

module_vermagic() {
    local module_path="$1"

    strings "$module_path" |
        sed -n 's/^vermagic=//p' |
        head -n 1
}

validate_aic_cache() {
    local actual_kernel_release
    local bsp_module="$AIC_REPO/src/SDIO/driver_fw/driver/aic8800/aic8800_bsp/aic8800_bsp.ko"
    local fdrv_module="$AIC_REPO/src/SDIO/driver_fw/driver/aic8800/aic8800_fdrv/aic8800_fdrv.ko"

    [[ "$KERNEL_REBUILD" == "0" && "$AIC_REBUILD" == "0" ]] || return 1
    [[ -s "$AIC_CACHE_STATE" ]] || return 1
    [[ "$(cache_value "$AIC_CACHE_STATE" cache_format)" == "1" ]] || return 1
    [[ "$(cache_value "$AIC_CACHE_STATE" fingerprint)" == "$AIC_INPUT_FINGERPRINT" ]] || return 1
    [[ "$(git -C "$AIC_REPO" rev-parse HEAD 2>/dev/null || true)" == "$AIC_EXPECTED_COMMIT" ]] || return 1

    actual_kernel_release="$(
        make -s -C "$KERNEL_DIR" \
            ARCH=arm64 \
            CROSS_COMPILE="$CROSS_COMPILE" \
            kernelrelease 2>/dev/null || true
    )"

    [[ -n "$actual_kernel_release" ]] || return 1
    [[ "$(cache_value "$AIC_CACHE_STATE" kernel_release)" == "$actual_kernel_release" ]] || return 1

    file_matches_cache_hash \
        "$AIC_CACHE_STATE" bsp_module_sha256 "$bsp_module" || return 1
    file_matches_cache_hash \
        "$AIC_CACHE_STATE" fdrv_module_sha256 "$fdrv_module" || return 1
    file_matches_cache_hash \
        "$AIC_CACHE_STATE" bsp_symvers_sha256 \
        "$AIC_REPO/src/SDIO/driver_fw/driver/aic8800/aic8800_bsp/Module.symvers" || return 1
    file_matches_cache_hash \
        "$AIC_CACHE_STATE" bsp_command_sha256 \
        "$AIC_REPO/src/SDIO/driver_fw/driver/aic8800/aic8800_bsp/.aicsdio.o.cmd" || return 1

    case "$(module_vermagic "$bsp_module")" in
        "$actual_kernel_release"*) ;;
        *) return 1 ;;
    esac

    case "$(module_vermagic "$fdrv_module")" in
        "$actual_kernel_release"*) ;;
        *) return 1 ;;
    esac

    return 0
}

prepare_kernel_source() {
    local actual_ref
    local kernel_commit
    local kernel_status
    local remote_url

    [[ "$KERNEL_DIR" == "$EXPECTED_KERNEL_DIR" ]] ||
        die "Refusing to remove unexpected kernel directory: $KERNEL_DIR"

    if [[ -e "$KERNEL_DIR" && ! -d "$KERNEL_DIR/.git" ]]; then
        die "KERNEL_DIR exists but is not a Git repository: $KERNEL_DIR"
    fi

    if [[ "$KERNEL_REBUILD" == "1" ]]; then
        rm -f -- "$KERNEL_CACHE_STATE" "$AIC_CACHE_STATE"

        if [[ -d "$KERNEL_DIR/.git" ]]; then
            log "KERNEL_REBUILD=1; discarding the validated kernel cache."
            rm -rf -- "$KERNEL_DIR"
        fi
    fi

    if [[ -d "$KERNEL_DIR/.git" ]]; then
        remote_url="$(git -C "$KERNEL_DIR" remote get-url origin)"
        origin_matches "$remote_url" "$LINUX_REPOSITORY" ||
            die "Unexpected Linux origin: $remote_url"

        log "Refreshing the declared Linux tag and pinned upstream history."
        run git -C "$KERNEL_DIR" fetch \
            --force \
            origin \
            "refs/tags/$LINUX_REF:refs/tags/$LINUX_REF"

        run git -C "$KERNEL_DIR" fetch \
            --no-tags \
            --shallow-since="$UPSTREAM_SINCE" \
            origin \
            master:refs/remotes/origin/master

        kernel_commit="$(git -C "$KERNEL_DIR" rev-parse "$LINUX_REF^{commit}")"
        [[ "$kernel_commit" == "$LINUX_EXPECTED_COMMIT" ]] ||
            die "Kernel tag moved: expected $LINUX_EXPECTED_COMMIT, found $kernel_commit"

        if validate_kernel_cache; then
            KERNEL_CACHE_REUSED=1
            KERNEL_TREE_REUSED=1
            log "Reusing validated kernel tree and compiled outputs."
            log "Kernel cache fingerprint: $KERNEL_INPUT_FINGERPRINT"
            return 0
        fi

        if validate_legacy_kernel_tree; then
            KERNEL_CACHE_REUSED=0
            KERNEL_TREE_REUSED=1
            rm -f -- "$AIC_CACHE_STATE"
            log "Adopting the completed pre-cache kernel tree for one incremental migration build."
            log "Stage 30 will validate and publish the first guarded cache state."
            return 0
        fi

        warn "Kernel cache is absent, stale, forced, or failed validation."
        warn "Recreating the kernel tree from the declared pin."
        rm -rf -- "$KERNEL_DIR"
        rm -f -- "$KERNEL_CACHE_STATE" "$AIC_CACHE_STATE"
    fi

    log "Creating clean Linux $LINUX_REF source tree."

    run git clone \
        --depth 1 \
        --branch "$LINUX_REF" \
        "$LINUX_REPOSITORY" \
        "$KERNEL_DIR"

    actual_ref="$(
        git -C "$KERNEL_DIR" \
            describe \
            --tags \
            --exact-match \
            HEAD 2>/dev/null || true
    )"

    [[ "$actual_ref" == "$LINUX_REF" ]] ||
        die "Expected kernel tag $LINUX_REF, found ${actual_ref:-unknown}"

    kernel_commit="$(git -C "$KERNEL_DIR" rev-parse HEAD)"

    [[ "$kernel_commit" == "$LINUX_EXPECTED_COMMIT" ]] ||
        die "Kernel tag moved: expected $LINUX_EXPECTED_COMMIT, found $kernel_commit"

    log "Fetching upstream history since $UPSTREAM_SINCE for selected backports."

    run git -C "$KERNEL_DIR" fetch \
        --no-tags \
        --shallow-since="$UPSTREAM_SINCE" \
        origin \
        master:refs/remotes/origin/master

    kernel_status="$(git -C "$KERNEL_DIR" status --porcelain)"

    if [[ -n "$kernel_status" ]]; then
        printf '%s\n' "$kernel_status" >&2
        die "Fresh kernel tree is unexpectedly dirty."
    fi

    KERNEL_CACHE_REUSED=0
    KERNEL_TREE_REUSED=0
    return 0
}

prepare_kernel_config() {
    if [[ "$KERNEL_CACHE_REUSED" == "1" ]]; then
        require_nonempty_file "$KERNEL_DIR/.config"
        grep -Fxq "CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\"" "$KERNEL_DIR/.config" ||
            die "Cached kernel LOCALVERSION does not match $KERNEL_LOCALVERSION."
        grep -Fxq '# CONFIG_LOCALVERSION_AUTO is not set' "$KERNEL_DIR/.config" ||
            die "Cached kernel unexpectedly enables CONFIG_LOCALVERSION_AUTO."
        log "Keeping the validated cached kernel configuration and build objects."
        return 0
    fi

    if [[ "$KERNEL_TREE_REUSED" == "1" ]]; then
        if [[ -n "$KERNEL_CONFIG_SOURCE" ]]; then
            require_nonempty_file "$KERNEL_CONFIG_SOURCE"
            log "Applying explicitly selected kernel configuration to the reusable tree: $KERNEL_CONFIG_SOURCE"
            cp -a -- "$KERNEL_CONFIG_SOURCE" "$KERNEL_DIR/.config"
        else
            log "Keeping the existing validated kernel configuration for incremental cache migration."
        fi
    elif [[ -n "$KERNEL_CONFIG_SOURCE" ]]; then
        require_nonempty_file "$KERNEL_CONFIG_SOURCE"

        log "Using explicitly selected kernel configuration: $KERNEL_CONFIG_SOURCE"
        cp -a -- "$KERNEL_CONFIG_SOURCE" "$KERNEL_DIR/.config"
    else
        log "Creating clean arm64 defconfig."

        run make -C "$KERNEL_DIR" \
            ARCH=arm64 \
            CROSS_COMPILE="$CROSS_COMPILE" \
            defconfig
    fi

    run "$KERNEL_DIR/scripts/config" \
        --file "$KERNEL_DIR/.config" \
        --set-str LOCALVERSION "$KERNEL_LOCALVERSION"

    run "$KERNEL_DIR/scripts/config" \
        --file "$KERNEL_DIR/.config" \
        --disable LOCALVERSION_AUTO

    run make -C "$KERNEL_DIR" \
        ARCH=arm64 \
        CROSS_COMPILE="$CROSS_COMPILE" \
        olddefconfig

    require_nonempty_file "$KERNEL_DIR/.config"

    grep -Fxq "CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\"" "$KERNEL_DIR/.config" ||
        die "Kernel LOCALVERSION does not match $KERNEL_LOCALVERSION."

    grep -Fxq '# CONFIG_LOCALVERSION_AUTO is not set' "$KERNEL_DIR/.config" ||
        die "CONFIG_LOCALVERSION_AUTO was not disabled."
}

prepare_aic_source() {
    local remote_url
    local requested_ref
    local remote_head_ref
    local selected_ref
    local aic_commit
    local aic_status

    log "Preparing deterministic AIC8800 source tree."

    if [[ -e "$AIC_REPO" && ! -d "$AIC_REPO/.git" ]]; then
        die "AIC_REPO exists but is not a Git repository: $AIC_REPO"
    fi

    if [[ ! -d "$AIC_REPO/.git" ]]; then
        run git clone "$AIC_REPOSITORY" "$AIC_REPO"
    fi

    remote_url="$(git -C "$AIC_REPO" remote get-url origin)"

    origin_matches "$remote_url" "$AIC_REPOSITORY" ||
        die "Unexpected AIC8800 origin: $remote_url"

    run git -C "$AIC_REPO" fetch \
        --prune \
        origin

    requested_ref="$AIC_REF"

    if [[ -z "$requested_ref" ]]; then
        remote_head_ref="$(
            git -C "$AIC_REPO" symbolic-ref \
                --quiet \
                --short \
                refs/remotes/origin/HEAD 2>/dev/null || true
        )"

        [[ -n "$remote_head_ref" ]] ||
            die "Could not determine the AIC8800 origin HEAD branch."

        requested_ref="${remote_head_ref#origin/}"
        log "Using AIC8800 origin HEAD branch: $requested_ref"
    else
        log "Using explicitly requested AIC8800 ref: $requested_ref"
    fi

    if git -C "$AIC_REPO" show-ref \
        --verify \
        --quiet \
        "refs/remotes/origin/$requested_ref"; then
        selected_ref="refs/remotes/origin/$requested_ref"
    elif git -C "$AIC_REPO" rev-parse \
        --verify \
        --quiet \
        "$requested_ref^{commit}" >/dev/null; then
        selected_ref="$requested_ref"
    else
        die "Requested AIC_REF does not exist: $requested_ref"
    fi

    aic_commit="$(git -C "$AIC_REPO" rev-parse "$selected_ref^{commit}")"

    [[ "$aic_commit" == "$AIC_EXPECTED_COMMIT" ]] ||
        die "AIC8800 ref moved: expected $AIC_EXPECTED_COMMIT, found $aic_commit"

    if [[ "$AIC_REBUILD" == "1" ]]; then
        log "AIC_REBUILD=1; discarding the validated AIC8800 cache."
        rm -f -- "$AIC_CACHE_STATE"
    fi

    if validate_aic_cache; then
        AIC_CACHE_REUSED=1
        log "Reusing validated AIC8800 source state and compiled modules."
        log "AIC8800 cache fingerprint: $AIC_INPUT_FINGERPRINT"
        return 0
    fi

    warn "AIC8800 cache is absent, stale, forced, or failed validation."
    log "Resetting AIC8800 source to the declared pin."
    run git -C "$AIC_REPO" reset --hard "$selected_ref"
    run git -C "$AIC_REPO" clean -ffdx
    rm -f -- "$AIC_CACHE_STATE"

    aic_commit="$(git -C "$AIC_REPO" rev-parse HEAD)"

    aic_status="$(git -C "$AIC_REPO" status --porcelain)"

    if [[ -n "$aic_status" ]]; then
        printf '%s\n' "$aic_status" >&2
        die "AIC8800 source tree remains dirty after reset."
    fi

    AIC_CACHE_REUSED=0

    need_dir "$AIC_REPO/src/SDIO/driver_fw/driver/aic8800"
    need_dir "$AIC_REPO/src/SDIO/driver_fw/driver/aic8800/aic8800_bsp"
    need_dir "$AIC_REPO/src/SDIO/driver_fw/driver/aic8800/aic8800_fdrv"
    need_dir "$AIC_REPO/debian/patches"

    return 0
}

clear_previous_run_state() {
    local cleanup_files=(
        "$BUILD_ROOT/.one-shot-kernel-release"
        "$BUILD_ROOT/.one-shot-aic-modules"
        "$BUILD_ROOT/.one-shot-update-version"
        "$BUILD_ROOT/.one-shot-update-bundle"
        "$BUILD_ROOT/.one-shot-update-public-key"
        "$BUILD_ROOT/.one-shot-rfkill-modules"
        "$BUILD_ROOT/.one-shot-target-layout"
        "$BUILD_ROOT/.one-shot-layout-candidates"
        "$BUILD_ROOT/.one-shot-aic-build-report.txt"
        "$BUILD_ROOT/.one-shot-aic-symbols.txt"
        "$BUILD_ROOT/.one-shot-aic-vermagic.txt"
        "$BUILD_ROOT/.one-shot-kernel-build-report.txt"
        "$BUILD_ROOT/.one-shot-kernel-symbols.txt"
        "$BUILD_ROOT/.one-shot-kernel-required-config.txt"
        "$BUILD_ROOT/.one-shot-hardware-dts-report.txt"
        "$BUILD_ROOT/.one-shot-compiled-board.dts"
        "$BUILD_ROOT/.one-shot-linux-install-report.txt"
        "$BUILD_ROOT/.one-shot-installed-modules.txt"
        "$BUILD_ROOT/.one-shot-extlinux-after-install.conf"
        "$BUILD_ROOT/.one-shot-image-validation-report.txt"
        "$BUILD_ROOT/.one-shot-validated-extlinux.conf"
        "$BUILD_ROOT/.one-shot-validated-modules.txt"
        "$BUILD_ROOT/.one-shot-validated-board.dts"
        "$BUILD_ROOT/.one-shot-resolv.conf.backup"
        "$BUILD_ROOT/.one-shot-resolv.conf.link"
    )

    rm -f -- "${cleanup_files[@]}"
}

write_source_report() {
    {
        printf 'Kernel repository: %s\n' "$LINUX_REPOSITORY"
        printf 'Kernel requested ref: %s\n' "$LINUX_REF"
        printf 'Kernel declared tag commit: %s\n' \
            "$(git -C "$KERNEL_DIR" rev-parse "$LINUX_REF^{commit}")"
        printf 'Kernel working-tree HEAD: %s\n' \
            "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        printf 'Kernel expected commit: %s\n' "$LINUX_EXPECTED_COMMIT"
        printf 'Kernel input fingerprint: %s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'Kernel validated cache reused: %s\n' "$KERNEL_CACHE_REUSED"
        printf 'Kernel tree/build objects reused: %s\n' "$KERNEL_TREE_REUSED"

        if [[ "$KERNEL_TREE_REUSED" == "0" ]]; then
            printf 'Kernel status:\n'
            git -C "$KERNEL_DIR" status --short
        else
            printf 'Kernel status: validated patched source and build objects retained\n'
        fi

        printf '\nAIC repository: %s\n' "$AIC_REPOSITORY"
        printf 'AIC requested ref override: %s\n' "${AIC_REF:-origin HEAD}"
        printf 'AIC commit: %s\n' \
            "$(git -C "$AIC_REPO" rev-parse HEAD)"
        printf 'AIC expected commit: %s\n' "$AIC_EXPECTED_COMMIT"
        printf 'AIC input fingerprint: %s\n' "$AIC_INPUT_FINGERPRINT"
        printf 'AIC validated cache reused: %s\n' "$AIC_CACHE_REUSED"
        if [[ "$BUILD_MODE" == "image" ]]; then
            printf '\nRadxa donor URL: %s\n' "$STOCK_IMAGE_URL"
            printf 'Radxa donor SHA-512: %s\n' "$STOCK_IMAGE_SHA512"
        fi
        if [[ "$AIC_CACHE_REUSED" == "0" ]]; then
            printf 'AIC status:\n'
            git -C "$AIC_REPO" status --short
        else
            printf 'AIC status: validated patched source and module outputs retained\n'
        fi
    } >"$SOURCE_REPORT"
}

write_prepare_report() {
    {
        printf 'Cubie A5E host preparation report\n'
        printf '=================================\n'
        printf 'Status: PASS\n'
        printf 'Build mode: %s\n' "$BUILD_MODE"
        printf 'Build root: %s\n' "$BUILD_ROOT"
        printf 'Kernel directory: %s\n' "$KERNEL_DIR"
        printf 'Kernel ref: %s\n' "$LINUX_REF"
        printf 'Kernel local version: %s\n' "$KERNEL_LOCALVERSION"
        printf 'Kernel input fingerprint: %s\n' "$KERNEL_INPUT_FINGERPRINT"
        printf 'Kernel validated cache reused: %s\n' "$KERNEL_CACHE_REUSED"
        printf 'Kernel tree/build objects reused: %s\n' "$KERNEL_TREE_REUSED"
        printf 'Kernel config source: %s\n' \
            "${KERNEL_CONFIG_SOURCE:-arm64 defconfig}"
        printf 'AIC repository: %s\n' "$AIC_REPO"
        printf 'AIC ref: %s\n' "$AIC_REF"
        printf 'AIC input fingerprint: %s\n' "$AIC_INPUT_FINGERPRINT"
        printf 'AIC validated cache reused: %s\n' "$AIC_CACHE_REUSED"
        printf 'AIC driver platform path: generic Linux SDIO\n'
        printf 'External RFKill/MMC rescan compatibility required: no\n'
        if [[ "$BUILD_MODE" == "image" ]]; then
            printf 'Base image builder: %s\n' "$BASE_IMAGE_BUILDER"
        else
            printf 'Base image builder required: no\n'
        fi
        printf 'Package report: %s\n' "$PACKAGE_REPORT"
        printf 'Source report: %s\n' "$SOURCE_REPORT"
    } >"$PREPARE_REPORT"
}

main() {
    [[ "$(id -u)" -eq 0 ]] ||
        die "Run this stage as root."

    case "$KERNEL_REBUILD" in
        0 | 1) ;;
        *) die "KERNEL_REBUILD must be 0 or 1, got: $KERNEL_REBUILD" ;;
    esac

    case "$AIC_REBUILD" in
        0 | 1) ;;
        *) die "AIC_REBUILD must be 0 or 1, got: $AIC_REBUILD" ;;
    esac

    mkdir -p -- "$BUILD_ROOT" "$CACHE_DIR"

    validate_paths
    install_required_packages
    validate_host_commands
    validate_project_inputs
    download_stock_image
    clear_previous_run_state
    prepare_kernel_source
    prepare_kernel_config
    prepare_aic_source
    write_source_report
    write_prepare_report

    log "Host preparation passed."
    log "Preparation report: $PREPARE_REPORT"
    log "Source revisions: $SOURCE_REPORT"
}

main "$@"
