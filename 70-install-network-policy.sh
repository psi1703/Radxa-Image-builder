#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh

source "$SCRIPT_DIR/lib/common.sh"

export STAGE_NAME="NETWORK"

: "${BUILD_ROOT:?BUILD_ROOT is not set}"
: "${TARGET_DEVICE:?TARGET_DEVICE is not set}"

readonly TARGET_LAYOUT_FILE="$BUILD_ROOT/.one-shot-target-layout"
readonly LAYOUT_CANDIDATES_FILE="$BUILD_ROOT/.one-shot-layout-candidates"
readonly KERNEL_RELEASE_FILE="$BUILD_ROOT/.one-shot-kernel-release"

readonly ROOT_MNT="${ROOT_MNT:-$BUILD_ROOT/mnt/one-shot-root}"
readonly BOOT_MNT="${BOOT_MNT:-$BUILD_ROOT/mnt/one-shot-boot}"

readonly GMAC0_LINK="$ROOT_MNT/etc/systemd/network/10-cubie-gmac0.link"
readonly GMAC1_LINK="$ROOT_MNT/etc/systemd/network/11-cubie-gmac1.link"
readonly WLAN_LINK="$ROOT_MNT/etc/systemd/network/20-cubie-aic8800.link"

readonly MODULE_LOAD_FILE="$ROOT_MNT/etc/modules-load.d/cubie-a5e-aic8800.conf"
readonly MODULE_SOFTDEP_FILE="$ROOT_MNT/etc/modprobe.d/cubie-a5e-aic8800.conf"
readonly NM_POLICY_FILE="$ROOT_MNT/etc/NetworkManager/conf.d/10-cubie-a5e-mac.conf"
readonly NM_WLAN_READY_FILE="$ROOT_MNT/etc/NetworkManager/conf.d/20-initbox-wlan0-ready.conf"
readonly WLAN_READY_STATUS="$ROOT_MNT/usr/share/cubie-a5e/wlan0-hotspot-ready.status"

if [[ -n "${LOG_DIR:-}" ]]; then
mkdir -p -- "$LOG_DIR"
readonly NETWORK_REPORT="$LOG_DIR/network-policy-report.txt"
else
readonly NETWORK_REPORT="$BUILD_ROOT/.one-shot-network-policy-report.txt"
fi

ROOT_PART=""
BOOT_PART=""
EXTLINUX_REL=""
KERNEL_RELEASE=""
ROOT_MOUNTED_BY_STAGE=0

require_nonempty_file() {
local path="$1"

[[ -s "$path" ]] ||
    die "Required file is missing or empty: $path"

}

cleanup() {
set +e

if ((ROOT_MOUNTED_BY_STAGE == 1)) &&
   mountpoint -q "$ROOT_MNT"; then
    umount "$ROOT_MNT"
fi

}

trap cleanup EXIT

discover_target_layout() {
local probe_root="$BUILD_ROOT/mnt/layout-probe"
local part
local mount_dir
local root_count=0
local boot_count=0
local found_root=""
local found_boot=""
local found_extlinux=""

mkdir -p -- "$probe_root"
: >"$LAYOUT_CANDIDATES_FILE"

while IFS= read -r part; do
    [[ -b "$part" ]] || continue

    mount_dir="$probe_root/$(basename -- "$part")"
    mkdir -p -- "$mount_dir"

    if mountpoint -q "$mount_dir"; then
        umount "$mount_dir"
    fi

    if ! mount -o ro "$part" "$mount_dir" 2>/dev/null; then
        continue
    fi

    if [[ -f "$mount_dir/etc/os-release" &&
          -d "$mount_dir/usr" &&
          -d "$mount_dir/boot" ]]; then
        printf 'ROOT %s\n' "$part" >>"$LAYOUT_CANDIDATES_FILE"
        found_root="$part"
        root_count=$((root_count + 1))
    fi

    if [[ -f "$mount_dir/boot/extlinux/extlinux.conf" ]]; then
        printf 'BOOT %s boot/extlinux/extlinux.conf\n' \
            "$part" >>"$LAYOUT_CANDIDATES_FILE"

        found_boot="$part"
        found_extlinux="boot/extlinux/extlinux.conf"
        boot_count=$((boot_count + 1))
    elif [[ -f "$mount_dir/extlinux/extlinux.conf" ]]; then
        printf 'BOOT %s extlinux/extlinux.conf\n' \
            "$part" >>"$LAYOUT_CANDIDATES_FILE"

        found_boot="$part"
        found_extlinux="extlinux/extlinux.conf"
        boot_count=$((boot_count + 1))
    fi

    umount "$mount_dir"
done < <(
    lsblk -lnpo NAME,TYPE "$TARGET_DEVICE" |
        awk '$2 == "part" {print $1}'
)

((root_count == 1)) ||
    die "Expected exactly one Debian root filesystem; found $root_count"

((boot_count == 1)) ||
    die "Expected exactly one extlinux filesystem; found $boot_count"

{
    printf 'ROOT_PART=%q\n' "$found_root"
    printf 'BOOT_PART=%q\n' "$found_boot"
    printf 'EXTLINUX_REL=%q\n' "$found_extlinux"
} >"$TARGET_LAYOUT_FILE"

}

load_target_layout() {
if [[ ! -s "$TARGET_LAYOUT_FILE" ]]; then
discover_target_layout
fi

# shellcheck disable=SC1090
source "$TARGET_LAYOUT_FILE"

[[ -b "$ROOT_PART" ]] ||
    die "Recorded root partition is unavailable: $ROOT_PART"

[[ -b "$BOOT_PART" ]] ||
    die "Recorded boot partition is unavailable: $BOOT_PART"

[[ -n "$EXTLINUX_REL" ]] ||
    die "Recorded extlinux path is empty."

}

mount_root_filesystem() {
local mounted_source

mkdir -p -- "$ROOT_MNT"

if mountpoint -q "$ROOT_MNT"; then
    mounted_source="$(
        findmnt -nro SOURCE --target "$ROOT_MNT"
    )"

    [[ "$(readlink -f -- "$mounted_source")" == \
       "$(readlink -f -- "$ROOT_PART")" ]] ||
        die "$ROOT_MNT is mounted from $mounted_source; expected $ROOT_PART"

    return 0
fi

run mount "$ROOT_PART" "$ROOT_MNT"
ROOT_MOUNTED_BY_STAGE=1

}

install_interface_naming_policy() {
install -d -m 0755 -- "$ROOT_MNT/etc/systemd/network"

cat >"$GMAC0_LINK" <<'EOF'

[Match]
Path=platform-4500000.ethernet

[Link]
Name=eth0
MACAddressPolicy=persistent
EOF

cat >"$GMAC1_LINK" <<'EOF'

[Match]
Path=platform-4510000.ethernet

[Link]
Name=eth1
MACAddressPolicy=persistent
EOF

cat >"$WLAN_LINK" <<'EOF'

[Match]
Type=wlan
Driver=aic8800_fdrv

[Link]
Name=wlan0
EOF

chmod 0644 \
    "$GMAC0_LINK" \
    "$GMAC1_LINK" \
    "$WLAN_LINK"

}

install_networkmanager_policy() {
local connection_file

install -d -m 0755 -- \
    "$ROOT_MNT/etc/NetworkManager/conf.d" \
    "$ROOT_MNT/etc/NetworkManager/system-connections"

cat >"$NM_POLICY_FILE" <<'EOF'

[device]
wifi.scan-rand-mac-address=no

[connection]
ethernet.cloned-mac-address=preserve
wifi.cloned-mac-address=preserve
EOF

cat >"$NM_WLAN_READY_FILE" <<'EOF'

[device-wlan0]
match-device=interface-name:wlan0
managed=true
EOF

chmod 0644 \
    "$NM_POLICY_FILE" \
    "$NM_WLAN_READY_FILE"

while IFS= read -r -d '' connection_file; do
    if grep -Eqs \
        '^[[:space:]]*type[[:space:]]*=[[:space:]]*(wifi|802-11-wireless)[[:space:]]*$|^[[:space:]]*\[wifi\][[:space:]]*$' \
        "$connection_file"; then
        rm -f -- "$connection_file"
    fi
done < <(
    find "$ROOT_MNT/etc/NetworkManager/system-connections" \
        -maxdepth 1 \
        -type f \
        -print0
)

install -D -m 0644 /dev/null "$WLAN_READY_STATUS"
{
    printf 'INTERFACE=wlan0\n'
    printf 'NETWORKMANAGER_MANAGED=yes\n'
    printf 'SAVED_WIFI_CONNECTIONS=0\n'
    printf 'INTENDED_ROLE=unconfigured-hotspot-ready\n'
} >"$WLAN_READY_STATUS"

}

validate_module_policy_untouched() {
require_nonempty_file "$MODULE_LOAD_FILE"
require_nonempty_file "$MODULE_SOFTDEP_FILE"

diff -u \
    <(
        printf '%s\n' \
            aic8800_bsp \
            aic8800_fdrv
    ) \
    "$MODULE_LOAD_FILE" ||
    die "Wi-Fi module load order was changed unexpectedly."

diff -u \
    <(
        printf '%s\n' \
            'softdep aic8800_fdrv pre: aic8800_bsp' \
            'options aic8800_bsp aic_fw_path=/lib/firmware/aic8800_fw/SDIO/aic8800D80' \
            'options aic8800_fdrv aicwf_dbg_level=0 custregd=0 ps_on=0'
    ) \
    "$MODULE_SOFTDEP_FILE" ||
    die "AIC8800 module options were changed unexpectedly."

if grep -Eq 'sunxi_rfkill_compat|sunxi_mmc_rescan_card' \
    "$MODULE_LOAD_FILE" "$MODULE_SOFTDEP_FILE"; then
    die "Obsolete Sunxi RFKill/rescan policy is still installed."
fi

}

validate_interface_naming_policy() {
require_nonempty_file "$GMAC0_LINK"
require_nonempty_file "$GMAC1_LINK"
require_nonempty_file "$WLAN_LINK"
require_nonempty_file "$NM_POLICY_FILE"
require_nonempty_file "$NM_WLAN_READY_FILE"
require_nonempty_file "$WLAN_READY_STATUS"

grep -Fxq 'Path=platform-4500000.ethernet' "$GMAC0_LINK" ||
    die "GMAC0 link policy has the wrong platform path."

grep -Fxq 'Name=eth0' "$GMAC0_LINK" ||
    die "GMAC0 link policy does not assign eth0."

grep -Fxq 'Path=platform-4510000.ethernet' "$GMAC1_LINK" ||
    die "GMAC1 link policy has the wrong platform path."

grep -Fxq 'Name=eth1' "$GMAC1_LINK" ||
    die "GMAC1 link policy does not assign eth1."

grep -Fxq 'Type=wlan' "$WLAN_LINK" ||
    die "Wi-Fi link policy does not match WLAN interfaces."

grep -Fxq 'Driver=aic8800_fdrv' "$WLAN_LINK" ||
    die "Wi-Fi link policy does not match the AIC8800 driver."

grep -Fxq 'Name=wlan0' "$WLAN_LINK" ||
    die "Wi-Fi link policy does not assign wlan0."

grep -Fxq 'wifi.scan-rand-mac-address=no' "$NM_POLICY_FILE" ||
    die "NetworkManager Wi-Fi scan MAC policy is missing."

grep -Fxq 'ethernet.cloned-mac-address=preserve' "$NM_POLICY_FILE" ||
    die "NetworkManager Ethernet MAC preservation is missing."

grep -Fxq 'wifi.cloned-mac-address=preserve' "$NM_POLICY_FILE" ||
    die "NetworkManager Wi-Fi MAC preservation is missing."

grep -Fxq 'match-device=interface-name:wlan0' "$NM_WLAN_READY_FILE" ||
    die "NetworkManager wlan0 device match is missing."

grep -Fxq 'managed=true' "$NM_WLAN_READY_FILE" ||
    die "NetworkManager does not explicitly manage wlan0."

if [[ -d "$ROOT_MNT/etc/NetworkManager/system-connections" ]]; then
    if find "$ROOT_MNT/etc/NetworkManager/system-connections" \
        -maxdepth 1 \
        -type f \
        -exec grep -Els \
            '^[[:space:]]*type[[:space:]]*=[[:space:]]*(wifi|802-11-wireless)[[:space:]]*$|^[[:space:]]*\[wifi\][[:space:]]*$' \
            {} + |
        grep -q .; then
        die "A saved Wi-Fi connection remains in the base image."
    fi
fi

grep -Fxq 'INTENDED_ROLE=unconfigured-hotspot-ready' "$WLAN_READY_STATUS" ||
    die "The wlan0 hotspot-ready status marker is invalid."

}

validate_extlinux_untouched() {
local extlinux_mount
local extlinux_file
local mounted_boot_by_stage=0

if [[ "$(readlink -f -- "$ROOT_PART")" == \
      "$(readlink -f -- "$BOOT_PART")" ]]; then
    extlinux_mount="$ROOT_MNT"
else
    mkdir -p -- "$BOOT_MNT"

    if ! mountpoint -q "$BOOT_MNT"; then
        mount -o ro "$BOOT_PART" "$BOOT_MNT"
        mounted_boot_by_stage=1
    fi

    extlinux_mount="$BOOT_MNT"
fi

extlinux_file="$extlinux_mount/$EXTLINUX_REL"
require_nonempty_file "$extlinux_file"

grep -Eq \
    '^[[:space:]]*default[[:space:]]+cubie-a5e[[:space:]]*$' \
    "$extlinux_file" ||
    die "Stage 60 extlinux default is missing or was changed."

grep -Eq \
    '^[[:space:]]*label[[:space:]]+cubie-a5e[[:space:]]*$' \
    "$extlinux_file" ||
    die "Stage 60 managed Cubie A5E entry is missing."

[[ "$(grep -Ec '^[[:space:]]*label[[:space:]]+' "$extlinux_file")" -eq 1 ]] ||
    die "Stage 60 extlinux does not contain exactly one entry."

if grep -Eq '5\.15\.147-20-aw2501|^[[:space:]]*label[[:space:]]+(l0|l0r)[[:space:]]*$' \
    "$extlinux_file"; then
    die "Stage 60 extlinux still contains Linux 5.15 recovery references."
fi

if ((mounted_boot_by_stage == 1)); then
    umount "$BOOT_MNT"
fi

}

write_report() {
{
printf 'Cubie A5E network policy report\n'
printf '================================\n'
printf 'Status: PASS\n'
printf 'Kernel release: %s\n' "$KERNEL_RELEASE"
printf 'Root partition: %s\n' "$ROOT_PART"
printf 'GMAC0 platform path: platform-4500000.ethernet\n'
printf 'GMAC0 interface name: eth0\n'
printf 'GMAC1 platform path: platform-4510000.ethernet\n'
printf 'GMAC1 interface name: eth1\n'
printf 'Wi-Fi driver match: aic8800_fdrv\n'
printf 'Wi-Fi interface name: wlan0\n'
printf 'Wi-Fi load order preserved: yes\n'
printf 'NetworkManager MAC preservation installed: yes\n'
printf 'NetworkManager manages wlan0: yes\n'
printf 'Saved Wi-Fi connection count: 0\n'
printf 'wlan0 role: unconfigured-hotspot-ready\n'
printf 'Extlinux rewritten by this stage: no\n'
printf 'Single managed extlinux entry preserved: yes\n'
printf 'Official Linux 5.15 recovery entries preserved: no\n'
} >"$NETWORK_REPORT"
}

main() {
log "Stage 70 revision: deterministic-network-cleanlog-v2-20260821"

need_cmd awk
need_cmd diff
need_cmd findmnt
need_cmd grep
need_cmd install
need_cmd lsblk
need_cmd mount
need_cmd mountpoint
need_cmd readlink
need_cmd sync
need_cmd umount

[[ "$(id -u)" -eq 0 ]] ||
    die "Run this stage as root."

[[ -b "$TARGET_DEVICE" ]] ||
    die "Target device is not a block device: $TARGET_DEVICE"

require_nonempty_file "$KERNEL_RELEASE_FILE"

KERNEL_RELEASE="$(
    tr -d '[:space:]' <"$KERNEL_RELEASE_FILE"
)"

[[ -n "$KERNEL_RELEASE" ]] ||
    die "Kernel release file is empty."

load_target_layout
mount_root_filesystem

install_interface_naming_policy
install_networkmanager_policy

validate_module_policy_untouched
validate_interface_naming_policy
validate_extlinux_untouched

sync
write_report

log "Installed deterministic interface naming."
log "Expected names: GMAC0=eth0, GMAC1=eth1, AIC8800=wlan0"
log "Validated that no saved Wi-Fi profiles remain in the base image."
log "Left wlan0 managed, disconnected and free of saved Wi-Fi profiles for later hotspot setup."
log "Extlinux and Wi-Fi module load order were left unchanged."
log "Network policy report: $NETWORK_REPORT"

}

main "$@"
