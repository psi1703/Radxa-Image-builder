#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=config/source-pins.env
source "$SCRIPT_DIR/config/source-pins.env"

export STAGE_NAME="APT-REPOSITORY"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"

readonly UPDATE_VERSION_FILE="$BUILD_ROOT/.one-shot-update-version"
readonly UPDATE_BUNDLE_FILE="$BUILD_ROOT/.one-shot-update-bundle"
readonly UPDATE_PUBLIC_KEY_FILE="$BUILD_ROOT/.one-shot-update-public-key"
readonly APT_PACKAGE_FILE="$BUILD_ROOT/.one-shot-apt-package"
readonly BOARD_SUPPORT_PACKAGE_FILE="$BUILD_ROOT/.one-shot-board-support-package"
readonly APT_REPOSITORY_FILE="$BUILD_ROOT/.one-shot-apt-repository"
readonly APT_PUBLIC_KEY_FILE="$BUILD_ROOT/.one-shot-apt-public-key"
readonly APT_REPOSITORY_DIR="${APT_REPOSITORY_DIR:-$BUILD_ROOT/apt-repository}"
readonly APT_SIGNING_DIR="${APT_SIGNING_DIR:-$BUILD_ROOT/apt-signing}"
readonly GNUPG_HOME="$APT_SIGNING_DIR/gnupg"
readonly APT_PUBLIC_KEY="$APT_SIGNING_DIR/cubie-a5e-archive-keyring.gpg"
readonly KERNEL_PACKAGE_NAME="cubie-a5e-kernel-update"
readonly BOARD_SUPPORT_PACKAGE_NAME="cubie-a5e-board-support"
readonly KERNEL_PACKAGE_ARCH="arm64"
readonly BOARD_SUPPORT_PACKAGE_ARCH="all"
readonly CUBIE_BOARD_SUPPORT_VERSION="${CUBIE_BOARD_SUPPORT_VERSION:-1.0.0}"
readonly CUBIE_APT_REPO_URL="${CUBIE_APT_REPO_URL:-}"

readonly UPDATE_PROGRAM_SRC="$SCRIPT_DIR/assets/cubie-a5e-update"
readonly RSETUP_WRAPPER_SRC="$SCRIPT_DIR/assets/rsetup"
readonly NVME_INSTALLER_SRC="$SCRIPT_DIR/assets/cubie-a5e-install-nvme"
readonly UPDATE_SERVICE_SRC="$SCRIPT_DIR/assets/cubie-a5e-update-finalize.service"
readonly KERNEL_APT_GUARD_SRC="$SCRIPT_DIR/assets/99-cubie-a5e-managed-kernel"

UPDATE_VERSION=""
BUNDLE_PATH=""
UPDATE_PUBLIC_KEY=""
KERNEL_PACKAGE_VERSION=""
KERNEL_PACKAGE_PATH=""
BOARD_SUPPORT_PACKAGE_PATH=""
WORK_DIR=""
PACKAGE_ROOT=""
APT_SIGNING_FINGERPRINT=""

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command is missing: $1"
}

require_nonempty_file() {
    [[ -s "$1" ]] ||
        die "Required file is missing or empty: $1"
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

validate_inputs() {
    require_nonempty_file "$UPDATE_VERSION_FILE"
    require_nonempty_file "$UPDATE_BUNDLE_FILE"
    require_nonempty_file "$UPDATE_PUBLIC_KEY_FILE"
    require_nonempty_file "$UPDATE_PROGRAM_SRC"
    require_nonempty_file "$RSETUP_WRAPPER_SRC"
    require_nonempty_file "$NVME_INSTALLER_SRC"
    require_nonempty_file "$UPDATE_SERVICE_SRC"
    require_nonempty_file "$KERNEL_APT_GUARD_SRC"

    UPDATE_VERSION="$(tr -d '[:space:]' <"$UPDATE_VERSION_FILE")"
    BUNDLE_PATH="$(<"$UPDATE_BUNDLE_FILE")"
    UPDATE_PUBLIC_KEY="$(<"$UPDATE_PUBLIC_KEY_FILE")"

    [[ "$UPDATE_VERSION" =~ ^[0-9A-Za-z.+:~-]+$ ]] ||
        die "Update version is not a valid Debian-version candidate: $UPDATE_VERSION"
    [[ "$CUBIE_BOARD_SUPPORT_VERSION" =~ ^[0-9A-Za-z.+:~-]+$ ]] ||
        die "CUBIE_BOARD_SUPPORT_VERSION is invalid: $CUBIE_BOARD_SUPPORT_VERSION"
    if [[ -n "$CUBIE_APT_REPO_URL" ]]; then
        [[ "$CUBIE_APT_REPO_URL" == https://* ]] ||
            die "CUBIE_APT_REPO_URL must use HTTPS."
        [[ "$CUBIE_APT_REPO_URL" != *[$'\r\n\t ']* ]] ||
            die "CUBIE_APT_REPO_URL must not contain whitespace."
    fi

    require_nonempty_file "$BUNDLE_PATH"
    require_nonempty_file "$UPDATE_PUBLIC_KEY"
    tar -tzf "$BUNDLE_PATH" >/dev/null ||
        die "Signed update bundle is not a valid tar.gz archive: $BUNDLE_PATH"
    openssl pkey -pubin -in "$UPDATE_PUBLIC_KEY" -noout >/dev/null ||
        die "Signed-update public key is invalid: $UPDATE_PUBLIC_KEY"

    KERNEL_PACKAGE_VERSION="$UPDATE_VERSION"
    KERNEL_PACKAGE_PATH="$APT_REPOSITORY_DIR/${KERNEL_PACKAGE_NAME}_${KERNEL_PACKAGE_VERSION}_${KERNEL_PACKAGE_ARCH}.deb"
    BOARD_SUPPORT_PACKAGE_PATH="$APT_REPOSITORY_DIR/${BOARD_SUPPORT_PACKAGE_NAME}_${CUBIE_BOARD_SUPPORT_VERSION}_${BOARD_SUPPORT_PACKAGE_ARCH}.deb"
}

ensure_apt_signing_key() {
    local batch_file

    install -d -m 0700 -- "$GNUPG_HOME"
    chmod 0700 "$GNUPG_HOME"

    APT_SIGNING_FINGERPRINT="$(
        GNUPGHOME="$GNUPG_HOME" gpg \
            --batch \
            --with-colons \
            --list-secret-keys 2>/dev/null |
            awk -F: '$1 == "fpr" { print $10; exit }'
    )"

    if [[ -z "$APT_SIGNING_FINGERPRINT" ]]; then
        log "Generating the persistent Cubie A5E APT archive signing key."
        batch_file="$(mktemp "$APT_SIGNING_DIR/.gpg-key.XXXXXX")"
        cat >"$batch_file" <<'KEY'
%no-protection
Key-Type: RSA
Key-Length: 3072
Name-Real: Radxa Cubie A5E Update Archive
Name-Email: cubie-a5e-updates@localhost
Expire-Date: 0
%commit
KEY
        GNUPGHOME="$GNUPG_HOME" gpg \
            --batch \
            --generate-key "$batch_file"
        rm -f -- "$batch_file"

        APT_SIGNING_FINGERPRINT="$(
            GNUPGHOME="$GNUPG_HOME" gpg \
                --batch \
                --with-colons \
                --list-secret-keys |
                awk -F: '$1 == "fpr" { print $10; exit }'
        )"
    fi

    [[ "$APT_SIGNING_FINGERPRINT" =~ ^[0-9A-F]{40}$ ]] ||
        die "Could not determine the APT archive signing-key fingerprint."

    GNUPGHOME="$GNUPG_HOME" gpg \
        --batch \
        --yes \
        --output "$APT_PUBLIC_KEY" \
        --export "$APT_SIGNING_FINGERPRINT"

    chmod 0644 "$APT_PUBLIC_KEY"
    require_nonempty_file "$APT_PUBLIC_KEY"
    printf '%s\n' "$APT_PUBLIC_KEY" >"$APT_PUBLIC_KEY_FILE"
}

prepare_package_root() {
    local name="$1"

    WORK_DIR="$(mktemp -d -p "$BUILD_ROOT" "${name}.XXXXXX")"
    PACKAGE_ROOT="$WORK_DIR/package"
    install -d -m 0755 -- "$PACKAGE_ROOT/DEBIAN"
    chmod 0755 "$PACKAGE_ROOT/DEBIAN"
    chmod g-s "$PACKAGE_ROOT/DEBIAN"
}

finish_package_root() {
    rm -rf -- "$WORK_DIR"
    WORK_DIR=""
    PACKAGE_ROOT=""
}

build_board_support_package() {
    local package_root
    local control_dir
    local source_target
    local channel_state

    install -d -m 0755 -- "$APT_REPOSITORY_DIR"
    prepare_package_root board-support
    package_root="$PACKAGE_ROOT"
    control_dir="$package_root/DEBIAN"

    install -D -m 0755 -- "$UPDATE_PROGRAM_SRC" \
        "$package_root/usr/local/sbin/cubie-a5e-update"
    install -D -m 0755 -- "$RSETUP_WRAPPER_SRC" \
        "$package_root/usr/local/bin/rsetup"
    install -D -m 0755 -- "$NVME_INSTALLER_SRC" \
        "$package_root/usr/local/sbin/cubie-a5e-install-nvme"
    install -D -m 0644 -- "$UPDATE_SERVICE_SRC" \
        "$package_root/usr/lib/systemd/system/cubie-a5e-update-finalize.service"
    install -D -m 0644 -- "$KERNEL_APT_GUARD_SRC" \
        "$package_root/etc/apt/preferences.d/99-cubie-a5e-managed-kernel"
    install -D -m 0644 -- "$UPDATE_PUBLIC_KEY" \
        "$package_root/etc/cubie-a5e-update/trusted-public.pem"
    install -D -m 0644 -- "$APT_PUBLIC_KEY" \
        "$package_root/usr/share/keyrings/cubie-a5e-archive-keyring.gpg"

    source_target="$package_root/etc/apt/sources.list.d/cubie-a5e-updates.sources"
    channel_state="$package_root/etc/cubie-a5e-update/apt-channel.env"
    install -d -m 0755 -- \
        "$(dirname -- "$source_target")" \
        "$(dirname -- "$channel_state")"

    if [[ -n "$CUBIE_APT_REPO_URL" ]]; then
        cat >"$source_target" <<EOF_SOURCE
Types: deb
URIs: $CUBIE_APT_REPO_URL
Suites: ./
Architectures: arm64
Signed-By: /usr/share/keyrings/cubie-a5e-archive-keyring.gpg
EOF_SOURCE
        chmod 0644 "$source_target"
    fi

    {
        printf 'REPOSITORY_URL=%q\n' "$CUBIE_APT_REPO_URL"
        printf 'KEYRING=%q\n' '/usr/share/keyrings/cubie-a5e-archive-keyring.gpg'
        printf 'PACKAGE=%q\n' "$KERNEL_PACKAGE_NAME"
        printf 'CONFIGURED=%q\n' "$([[ -n "$CUBIE_APT_REPO_URL" ]] && printf 1 || printf 0)"
    } >"$channel_state"
    chmod 0644 "$channel_state"

    cat >"$control_dir/control" <<EOF_CONTROL
Package: $BOARD_SUPPORT_PACKAGE_NAME
Version: $CUBIE_BOARD_SUPPORT_VERSION
Section: admin
Priority: optional
Architecture: $BOARD_SUPPORT_PACKAGE_ARCH
Maintainer: Radxa Cubie A5E Image Builder <cubie-a5e-updates@localhost>
Depends: bash, binutils, coreutils, device-tree-compiler, dpkg, e2fsprogs, findutils, gdisk, initramfs-tools, kmod, openssl, parted, rsync, sudo, tar, udev, util-linux, whiptail
Description: Radxa Cubie A5E managed board-support runtime
 Owns the Cubie A5E updater, rsetup wrapper, guarded NVMe installer,
 kernel-protection policy and signing trust material. Updating this package can
 deliver board-management fixes independently of the managed Linux kernel.
EOF_CONTROL

    cat >"$control_dir/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -eu

case "${1:-}" in
    configure)
        ;;
    *)
        exit 0
        ;;
esac

install -d -m 0755 \
    /etc/cubie-a5e-update \
    /var/lib/cubie-a5e-update/inbox \
    /etc/systemd/system/multi-user.target.wants

ln -sfn \
    /usr/lib/systemd/system/cubie-a5e-update-finalize.service \
    /etc/systemd/system/multi-user.target.wants/cubie-a5e-update-finalize.service

exit 0
EOF_POSTINST
    chmod 0755 "$control_dir/postinst"

    find "$package_root" -type d -exec chmod g-s {} +

    rm -f -- "$BOARD_SUPPORT_PACKAGE_PATH"
    dpkg-deb --build --root-owner-group "$package_root" "$BOARD_SUPPORT_PACKAGE_PATH" >/dev/null
    require_nonempty_file "$BOARD_SUPPORT_PACKAGE_PATH"
    dpkg-deb --info "$BOARD_SUPPORT_PACKAGE_PATH" >/dev/null ||
        die "Generated board-support package failed dpkg-deb validation."

    printf '%s\n' "$BOARD_SUPPORT_PACKAGE_PATH" >"$BOARD_SUPPORT_PACKAGE_FILE"
    finish_package_root
}

build_kernel_update_package() {
    local package_root
    local control_dir
    local bundle_target

    prepare_package_root kernel-update
    package_root="$PACKAGE_ROOT"
    control_dir="$package_root/DEBIAN"
    bundle_target="$package_root/usr/share/cubie-a5e-kernel-update/update-bundle.tar.gz"

    install -D -m 0644 -- "$BUNDLE_PATH" "$bundle_target"

    cat >"$control_dir/control" <<EOF_CONTROL
Package: $KERNEL_PACKAGE_NAME
Version: $KERNEL_PACKAGE_VERSION
Section: kernel
Priority: optional
Architecture: $KERNEL_PACKAGE_ARCH
Maintainer: Radxa Cubie A5E Image Builder <cubie-a5e-updates@localhost>
Depends: $BOARD_SUPPORT_PACKAGE_NAME (>= $CUBIE_BOARD_SUPPORT_VERSION), initramfs-tools, kmod, openssl, rsync, tar
Description: Radxa Cubie A5E managed kernel update $KERNEL_PACKAGE_VERSION
 Delivers a signed Cubie A5E kernel and board-support payload through APT.
 The package post-install step delegates activation to cubie-a5e-update so
 boot rollback and post-boot finalization remain under the board updater.
EOF_CONTROL

    cat >"$control_dir/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -eu

UPDATER=/usr/local/sbin/cubie-a5e-update
STATE_FILE=/var/lib/cubie-a5e-update/active.env
BUNDLE=/usr/share/cubie-a5e-kernel-update/update-bundle.tar.gz

case "${1:-}" in
    configure)
        ;;
    *)
        exit 0
        ;;
esac

if [ ! -x "$UPDATER" ]; then
    echo "cubie-a5e-kernel-update: missing updater: $UPDATER" >&2
    exit 1
fi

if [ ! -s "$BUNDLE" ]; then
    echo "cubie-a5e-kernel-update: missing signed bundle: $BUNDLE" >&2
    exit 1
fi

bundle_version="$(
    tar -xOf "$BUNDLE" manifest.env 2>/dev/null |
        sed -n 's/^UPDATE_VERSION=//p' |
        head -n 1
)"

if [ -z "$bundle_version" ]; then
    echo "cubie-a5e-kernel-update: bundle has no UPDATE_VERSION" >&2
    exit 1
fi

active_version=""
if [ -r "$STATE_FILE" ]; then
    active_version="$(
        sed -n 's/^ACTIVE_UPDATE_VERSION=//p' "$STATE_FILE" |
            head -n 1 |
            sed "s/^'//; s/'$//; s/^\"//; s/\"$//"
    )"
fi

if [ "$active_version" = "$bundle_version" ]; then
    echo "cubie-a5e-kernel-update: $bundle_version is already active; registering package only."
    exit 0
fi

echo "cubie-a5e-kernel-update: activating signed update $bundle_version"
exec "$UPDATER" --install "$BUNDLE"
EOF_POSTINST
    chmod 0755 "$control_dir/postinst"

    find "$package_root" -type d -exec chmod g-s {} +

    rm -f -- "$KERNEL_PACKAGE_PATH"
    dpkg-deb --build --root-owner-group "$package_root" "$KERNEL_PACKAGE_PATH" >/dev/null
    require_nonempty_file "$KERNEL_PACKAGE_PATH"
    dpkg-deb --info "$KERNEL_PACKAGE_PATH" >/dev/null ||
        die "Generated Debian kernel-update package failed dpkg-deb validation."

    printf '%s\n' "$KERNEL_PACKAGE_PATH" >"$APT_PACKAGE_FILE"
    finish_package_root
}

generate_repository_indexes() {
    local packages_sha
    local packages_size
    local packages_gz_sha
    local packages_gz_size
    local release_tmp

    log "Generating the signed flat APT repository index."

    (
        cd "$APT_REPOSITORY_DIR"
        dpkg-scanpackages --multiversion . /dev/null >Packages
        gzip -9c Packages >Packages.gz
    )

    packages_sha="$(sha256sum "$APT_REPOSITORY_DIR/Packages" | awk '{print $1}')"
    packages_size="$(stat -c '%s' "$APT_REPOSITORY_DIR/Packages")"
    packages_gz_sha="$(sha256sum "$APT_REPOSITORY_DIR/Packages.gz" | awk '{print $1}')"
    packages_gz_size="$(stat -c '%s' "$APT_REPOSITORY_DIR/Packages.gz")"
    release_tmp="$APT_REPOSITORY_DIR/Release.tmp"

    {
        printf 'Origin: Radxa Cubie A5E\n'
        printf 'Label: Cubie A5E Managed Updates\n'
        printf 'Suite: stable\n'
        printf 'Codename: cubie-a5e\n'
        printf 'Date: %s\n' "$(LC_ALL=C date -Ru)"
        printf 'Architectures: all arm64\n'
        printf 'Description: Signed Radxa Cubie A5E kernel and board-support updates\n'
        printf 'SHA256:\n'
        printf ' %s %16s Packages\n' "$packages_sha" "$packages_size"
        printf ' %s %16s Packages.gz\n' "$packages_gz_sha" "$packages_gz_size"
    } >"$release_tmp"

    mv -f -- "$release_tmp" "$APT_REPOSITORY_DIR/Release"

    GNUPGHOME="$GNUPG_HOME" gpg \
        --batch \
        --yes \
        --local-user "$APT_SIGNING_FINGERPRINT" \
        --clearsign \
        --output "$APT_REPOSITORY_DIR/InRelease" \
        "$APT_REPOSITORY_DIR/Release"

    GNUPGHOME="$GNUPG_HOME" gpg \
        --batch \
        --yes \
        --local-user "$APT_SIGNING_FINGERPRINT" \
        --armor \
        --detach-sign \
        --output "$APT_REPOSITORY_DIR/Release.gpg" \
        "$APT_REPOSITORY_DIR/Release"

    require_nonempty_file "$APT_REPOSITORY_DIR/Packages"
    require_nonempty_file "$APT_REPOSITORY_DIR/Packages.gz"
    require_nonempty_file "$APT_REPOSITORY_DIR/Release"
    require_nonempty_file "$APT_REPOSITORY_DIR/InRelease"
    require_nonempty_file "$APT_REPOSITORY_DIR/Release.gpg"

    GNUPGHOME="$GNUPG_HOME" gpg \
        --batch \
        --verify "$APT_REPOSITORY_DIR/Release.gpg" "$APT_REPOSITORY_DIR/Release" >/dev/null 2>&1 ||
        die "APT Release signature self-verification failed."

    printf '%s\n' "$APT_REPOSITORY_DIR" >"$APT_REPOSITORY_FILE"
}

write_report() {
    local report

    if [[ -n "${LOG_DIR:-}" ]]; then
        mkdir -p -- "$LOG_DIR"
        report="$LOG_DIR/apt-repository-report.txt"
    else
        report="$BUILD_ROOT/.one-shot-apt-repository-report.txt"
    fi

    {
        printf 'Cubie A5E APT update repository report\n'
        printf '=======================================\n'
        printf 'Status: PASS\n'
        printf 'Board-support package: %s\n' "$BOARD_SUPPORT_PACKAGE_PATH"
        printf 'Board-support version: %s\n' "$CUBIE_BOARD_SUPPORT_VERSION"
        printf 'Board-support SHA256: %s\n' "$(sha256sum "$BOARD_SUPPORT_PACKAGE_PATH" | awk '{print $1}')"
        printf 'Kernel update package: %s\n' "$KERNEL_PACKAGE_PATH"
        printf 'Kernel package version: %s\n' "$KERNEL_PACKAGE_VERSION"
        printf 'Kernel package SHA256: %s\n' "$(sha256sum "$KERNEL_PACKAGE_PATH" | awk '{print $1}')"
        printf 'Repository: %s\n' "$APT_REPOSITORY_DIR"
        printf 'Archive key: %s\n' "$APT_PUBLIC_KEY"
        printf 'Archive key fingerprint: %s\n' "$APT_SIGNING_FINGERPRINT"
        printf 'Configured remote URL: %s\n' "${CUBIE_APT_REPO_URL:-<none>}"
        printf 'Signed kernel bundle retained inside package: yes\n'
        printf 'APT Release signature: PASS\n'
    } >"$report"

    log "APT repository report: $report"
}

main() {
    local command_name

    for command_name in \
        awk \
        date \
        dirname \
        dpkg-deb \
        dpkg-scanpackages \
        find \
        gpg \
        gzip \
        head \
        install \
        mktemp \
        mv \
        openssl \
        rm \
        sed \
        sha256sum \
        stat \
        tar \
        tr; do
        require_command "$command_name"
    done

    [[ "$(id -u)" -eq 0 ]] ||
        die "Run this stage as root."

    need_dir "$BUILD_ROOT"
    validate_inputs
    ensure_apt_signing_key
    build_board_support_package
    build_kernel_update_package
    generate_repository_indexes
    write_report

    log "Board-support package created: $BOARD_SUPPORT_PACKAGE_PATH"
    log "Kernel update package created: $KERNEL_PACKAGE_PATH"
    log "Signed flat APT repository: $APT_REPOSITORY_DIR"
    log "APT archive public key: $APT_PUBLIC_KEY"
}

main "$@"
