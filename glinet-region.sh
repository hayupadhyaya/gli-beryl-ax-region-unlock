#!/bin/sh
#
# glinet-region.sh - inspect and change the region lock on GL.iNet routers
#
# GL.iNet units sold in mainland China carry the country code "CN" in their
# Factory flash partition. The stock firmware reads that value and hides the
# VPN, Tor, Dynamic DNS and AstroWarp pages in the admin panel, and drops
# AdGuard Home's dedicated page (it stays reachable from Plugins).
# Every gate is a comparison against "CN", so any other value unlocks them.
#
# This script does NOT install anything and does NOT flash firmware. At most it
# changes two bytes of one flash partition, and it refuses to do that until it
# has verified the layout on your specific unit and taken a backup.
#
# Run it ON the router over SSH, as root. See README.md.
#
# SPDX-License-Identifier: MIT

set -u

VERSION="1.3.0"

# Offset of the 2-letter country code inside the Factory partition.
CC_OFFSET=136        # 0x88
CC_LEN=2

# Offset of the printed serial number ("GL-..." on the underside label).
# This is NOT the same value as /proc/gl-hw-info/device_sn, which is a
# different, internal identifier. The label serial exists only here.
SN_OFFSET=112        # 0x70
SN_LEN=16

DEFAULT_BACKUP="/tmp/factory_backup.bin"

# Wi-Fi commit-confirm: seconds to wait for confirmation before rolling back.
WIFI_TIMEOUT=120
WIFI_CONFIRM_FLAG="/tmp/.glinet-wifi-confirm"
WIFI_ROLLBACK="/tmp/.glinet-wifi-rollback.sh"

# ---------------------------------------------------------------- ui helpers

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*"; exit 1; }

hr() { echo "--------------------------------------------------------------"; }

# ------------------------------------------------------------ discovery

# Locate the Factory partition by LABEL, never by hardcoded number. The
# numbering differs between models and has changed between firmware releases.
find_factory() {
    [ -r /proc/mtd ] || return 1
    _f=$(awk -F'[:"]' 'tolower($3) ~ /^factory$/ { print $1; exit }' /proc/mtd)
    [ -n "$_f" ] || return 1
    echo "$_f"
}

factory_num() {
    _f=$(find_factory) || return 1
    echo "$_f" | tr -dc '0-9'
}

factory_mtdblock() {
    _n=$(factory_num) || return 1
    echo "/dev/mtdblock$_n"
}

# The code the firmware acts on.
read_proc_cc() {
    if [ -r /proc/gl-hw-info/country_code ]; then
        cat /proc/gl-hw-info/country_code
    else
        echo "?"
    fi
}

# The code stored in flash.
read_flash_cc() {
    _dev=$(factory_mtdblock) || return 1
    dd if="$_dev" bs=1 skip=$CC_OFFSET count=$CC_LEN 2>/dev/null
}

# Read the label serial out of a Factory image or partition.
#   read_serial            -> from this router's flash
#   read_serial <file>     -> from a backup image
# The field is padded with 0xff (and 0x00 on some units); LC_ALL=C keeps tr
# from choking on the non-UTF-8 bytes when this is run on a Mac against a file.
read_serial() {
    _src="${1:-}"
    if [ -z "$_src" ]; then
        _src=$(factory_mtdblock) || return 1
    fi
    [ -r "$_src" ] || return 1
    dd if="$_src" bs=1 skip=$SN_OFFSET count=$SN_LEN 2>/dev/null \
        | LC_ALL=C tr -d '\377\000'
}

read_uci_override() {
    uci -q get board_special.hardware.country_code || echo ""
}

# Exact-match on the mount source so "mtd3" cannot match "mtd30".
is_mounted() {
    _f=$(find_factory) || return 1
    _n=$(factory_num) || return 1
    mount | awk '{print $1}' | grep -qx -e "/dev/$_f" -e "/dev/mtdblock$_n"
}

valid_cc() {
    case "$1" in
        [A-Z][A-Z]) return 0 ;;
        *) return 1 ;;
    esac
}

# Fail closed: if we cannot determine the uid, do not assume root.
require_root() {
    _uid=$(id -u 2>/dev/null) || die "cannot determine user id"
    [ "$_uid" = "0" ] || die "must run as root"
}

confirm() {
    printf '%s ' "$1"
    read -r _answer || _answer=""
    [ "$_answer" = "YES" ] || die "aborted (you must type YES exactly)"
}

wifi_radios() {
    uci show wireless 2>/dev/null | grep '\.country=' | cut -d. -f2 | cut -d= -f1
}

# The address the user reaches this router on, so printed scp commands are
# copy-pasteable instead of assuming the 192.168.8.1 default.
lan_ip() {
    uci -q get network.lan.ipaddr || echo "192.168.8.1"
}

# ------------------------------------------------------------ commands

cmd_status() {
    bold "GL.iNet region status"
    hr
    printf '%-26s %s\n' "model"            "$(cat /proc/gl-hw-info/model 2>/dev/null || echo '?')"
    printf '%-26s %s\n' "serial (label)"   "$(read_serial 2>/dev/null || echo '?')"
    printf '%-26s %s\n' "firmware"         "$(cat /etc/glversion 2>/dev/null || echo '?')"
    printf '%-26s %s\n' "kernel"           "$(uname -r)"
    printf '%-26s %s\n' "arch"             "$(uname -m)"
    hr
    _fact=$(find_factory) || _fact=""
    if [ -z "$_fact" ]; then
        red "Factory partition: NOT FOUND"
        echo "/proc/mtd contents:"
        cat /proc/mtd 2>/dev/null
        echo
        red "This script cannot operate on this device. Do not attempt a patch."
        return 1
    fi
    printf '%-26s %s\n' "factory partition" "/dev/$_fact  ->  $(factory_mtdblock)"
    printf '%-26s %s\n' "  size/erasesize"  "$(grep "^${_fact}:" /proc/mtd | awk '{print $2" / "$3}')"
    if is_mounted; then
        printf '%-26s ' "  mounted"; red "YES - unsafe to write"
    else
        printf '%-26s %s\n' "  mounted" "no (safe)"
    fi
    hr
    printf '%-26s [%s]\n' "country code (flash)"    "$(read_flash_cc)"
    printf '%-26s [%s]\n' "country code (/proc)"    "$(read_proc_cc)"
    _ov=$(read_uci_override)
    printf '%-26s [%s]\n' "uci override"            "${_ov:-none}"
    hr
    for _r in $(wifi_radios); do
        printf '%-26s [%s]\n' "wifi country ($_r)" "$(uci -q get "wireless.$_r.country")"
    done
    hr
    _cc=$(read_proc_cc)
    if [ "$_cc" = "CN" ]; then
        warn "Region is CN - the VPN, Tor, Dynamic DNS and AstroWarp pages are"
        warn "hidden in the admin panel, and AdGuard Home loses its own page"
        warn "(it stays reachable from Plugins)."
    else
        green "Region is '$_cc' - not CN, so the region gates are open."
    fi
}

cmd_backup() {
    require_root
    _out="${1:-$DEFAULT_BACKUP}"
    _dev=$(factory_mtdblock) || die "no Factory partition found"

    bold "Backing up $_dev -> $_out"
    dd if="$_dev" of="$_out" bs=4096 2>/dev/null || die "dump failed"
    _size=$(wc -c < "$_out" | tr -d ' ')
    _md5=$(md5sum "$_out" | awk '{print $1}')
    _sn=$(read_serial 2>/dev/null)
    green "wrote $_size bytes"
    echo "md5:    $_md5"
    echo "serial: ${_sn:-unknown}"
    echo
    warn "This partition holds your MAC addresses, serial numbers and Wi-Fi RF"
    warn "calibration data. It is the ONLY thing that can undo a bad write."
    echo
    warn "It belongs to THIS router and no other. If you own more than one of"
    warn "these, name the file after the serial so you can never mix them up -"
    warn "restoring another unit's image gives you duplicate MACs on your"
    warn "network and the wrong radio calibration."

    case "$_out" in
        /tmp/*)
            echo
            red "It is currently in /tmp, which is a RAMDISK - it will be GONE"
            red "after the next reboot, and patching requires a reboot."
            echo
            echo "Either keep a copy on the router's flash as well:"
            echo "    $0 backup /root/factory_backup.bin"
            echo "or copy it to your computer now (below). Ideally both."
            ;;
    esac

    echo
    bold "############ RUN THIS ON YOUR COMPUTER, NOT HERE ############"
    echo
    echo "Open a SECOND terminal on your own machine - do not paste this into"
    echo "this SSH session, it would just copy the router to itself. It will"
    echo "ask for the same router password you logged in with."
    echo
    _name="factory-${_sn:-backup}.bin"
    echo "    scp -O root@$(lan_ip):$_out ~/$_name"
    echo
    echo "Then confirm the copy is intact:"
    echo "    md5 -q ~/$_name        # macOS"
    echo "    md5sum ~/$_name        # Linux / WSL"
    echo
    echo "It must print exactly:"
    echo "    $_md5"
    echo
    echo "Store it somewhere permanent and backed up - not Downloads, not a"
    echo "temp folder. If you lose it you cannot undo a bad write."
    bold "############################################################"
}

cmd_soft() {
    require_root
    _cc="${1:-}"
    [ -n "$_cc" ] || die "usage: $0 soft <CC>   e.g. $0 soft CA"
    valid_cc "$_cc" || die "'$_cc' is not a 2-letter uppercase country code"

    bold "Applying reversible UCI override: country_code=$_cc"
    echo
    echo "This writes to /etc/config/board_special only. Flash is NOT touched."
    echo "get_country_code() prefers this value over the flash value:"
    echo
    echo "    get_country_code() {"
    echo "        uci -q get board_special.hardware.country_code || cat /proc/gl-hw-info/country_code"
    echo "    }"
    echo
    uci set board_special.hardware.country_code="$_cc" || die "uci set failed"
    uci commit board_special || die "uci commit failed"
    sync

    _now=$(. /lib/functions/gl_util.sh 2>/dev/null; get_country_code 2>/dev/null)
    if [ "$_now" = "$_cc" ]; then
        green "OK - get_country_code() now returns [$_now]"
    else
        red "unexpected: get_country_code() returns [$_now]"
    fi
    echo
    warn "Reload the admin panel (hard refresh) to pick up the change."
    warn "This does NOT survive a factory reset or a firmware upgrade that does"
    warn "not keep settings. Use '$0 patch $_cc' if you want it permanent."
    echo
    echo "Undo with:               $0 soft-undo"
    echo "Wi-Fi regulatory domain: $0 wifi $_cc     (separate setting)"
}

cmd_soft_undo() {
    require_root
    bold "Removing UCI override"
    uci -q delete board_special.hardware.country_code
    uci commit board_special
    sync
    green "removed - firmware falls back to the flash value [$(read_flash_cc)]"
}

cmd_patch() {
    require_root
    _cc="${1:-}"
    [ -n "$_cc" ] || die "usage: $0 patch <CC>   e.g. $0 patch CA"
    valid_cc "$_cc" || die "'$_cc' is not a 2-letter uppercase country code"

    _backup="${2:-$DEFAULT_BACKUP}"
    _dev=$(factory_mtdblock) || die "no Factory partition found"
    _cur=$(read_flash_cc)

    bold "Permanent flash patch"
    hr
    printf '%-22s %s\n' "target device"  "$_dev"
    printf '%-22s %s (0x%x)\n' "offset"  "$CC_OFFSET" "$CC_OFFSET"
    printf '%-22s [%s] -> [%s]\n' "country code" "$_cur" "$_cc"
    printf '%-22s %s\n' "backup"         "$_backup"
    hr

    # ---- safety gates -------------------------------------------------
    is_mounted && die "Factory partition is MOUNTED - refusing to write"
    valid_cc "$_cur" || die "current value [$_cur] is not a country code - layout differs, refusing"
    [ "$_cur" = "$_cc" ] && { green "already set to $_cc - nothing to do"; return 0; }
    [ -f "$_backup" ] || die "no backup at $_backup - run '$0 backup' first"

    # The backup must match what is on flash RIGHT NOW, otherwise it is stale
    # and useless as a recovery image.
    _live_md5=$(dd if="$_dev" bs=4096 2>/dev/null | md5sum | awk '{print $1}')
    _bak_md5=$(md5sum "$_backup" | awk '{print $1}')
    [ "$_live_md5" = "$_bak_md5" ] || die "backup is stale (md5 $_bak_md5 != live $_live_md5) - re-run '$0 backup'"

    green "all safety gates passed"
    echo
    red   "############################ WARNING ############################"
    red   "# Writing to the Factory partition does a read-modify-erase-    #"
    red   "# write of an entire erase block. That block also holds your    #"
    red   "# MAC addresses, serial numbers and Wi-Fi RF calibration data.  #"
    red   "# If power is lost during the write you may end up with a       #"
    red   "# router whose radios do not work. This is the risky step.      #"
    red   "#                                                               #"
    red   "# Do not unplug. Do not touch the reset or mode switch.         #"
    red   "############################ WARNING ############################"
    echo
    confirm "Type YES to write, anything else to abort:"

    echo
    bold "writing..."
    printf '%s' "$_cc" | dd of="$_dev" bs=1 seek=$CC_OFFSET 2>/dev/null || die "write failed"
    sync

    # ---- verification -------------------------------------------------
    echo
    bold "verifying"
    _new=$(read_flash_cc)
    printf '%-22s [%s]\n' "flash now reads" "$_new"
    [ "$_new" = "$_cc" ] || { red "MISMATCH - restore immediately: $0 restore $_backup"; exit 1; }

    _after=/tmp/factory_after.$$
    dd if="$_dev" of="$_after" bs=4096 2>/dev/null
    if command -v cmp >/dev/null 2>&1; then
        _ndiff=$(cmp -l "$_backup" "$_after" 2>/dev/null | wc -l | tr -d ' ')
        printf '%-22s %s\n' "bytes changed" "$_ndiff"
        echo "  (expect 1 or 2 - only the country code bytes should differ)"
        if [ "$_ndiff" -gt "$CC_LEN" ]; then
            red "MORE BYTES CHANGED THAN EXPECTED - the partition may be damaged."
            red "Restore now:  $0 restore $_backup"
            rm -f "$_after"
            exit 1
        fi
        echo "  differing bytes (offset old new, octal):"
        cmp -l "$_backup" "$_after" 2>/dev/null | sed 's/^/    /'
    fi
    rm -f "$_after"

    echo
    green "patch complete and verified"
    echo
    warn "Reboot to make the kernel re-read it:  reboot"
    warn "After reboot check:  cat /proc/gl-hw-info/country_code   (should be $_cc)"
    echo
    bold "Do not forget the Wi-Fi regulatory domain - it is a SEPARATE setting"
    echo "and is still whatever it was before:"
    for _r in $(wifi_radios); do
        printf '    %-14s currently [%s]\n' "$_r" "$(uci -q get "wireless.$_r.country")"
    done
    echo
    echo "    $0 wifi $_cc"
    echo
    echo "To undo this patch later, write the old code back - also a 1-2 byte"
    echo "change, and safer than restoring the whole partition:"
    echo "    $0 patch $_cur"
}

cmd_wifi() {
    require_root
    _cc="${1:-}"
    _mode="${2:-}"
    [ -n "$_cc" ] || die "usage: $0 wifi <CC> [--now]"
    valid_cc "$_cc" || die "'$_cc' is not a 2-letter uppercase country code"

    _radios=$(wifi_radios)
    [ -n "$_radios" ] || die "no wireless radios with a country setting found"

    bold "Wi-Fi regulatory domain"
    hr
    echo "This is SEPARATE from the region code that gates the admin panel."
    echo "It controls which channels and transmit powers the radios may use."
    hr
    for _r in $_radios; do
        printf '  %-14s [%s] -> [%s]   channel=%s\n' \
            "$_r" "$(uci -q get "wireless.$_r.country")" "$_cc" \
            "$(uci -q get "wireless.$_r.channel")"
    done
    hr

    # Nothing to do? Do not reload the radios and disconnect everyone for free.
    _changed=0
    for _r in $_radios; do
        [ "$(uci -q get "wireless.$_r.country")" = "$_cc" ] || _changed=1
    done
    if [ "$_changed" = "0" ]; then
        green "all radios are already set to $_cc - nothing to do"
        return 0
    fi

    warn "Applying this reloads the radios. If you are connected over Wi-Fi you"
    warn "WILL be disconnected for a few seconds."
    echo

    if [ "$_mode" = "--now" ]; then
        for _r in $_radios; do
            uci set "wireless.$_r.country=$_cc" || die "uci set failed for $_r"
        done
        uci commit wireless || die "uci commit failed"
        wifi reload
        green "applied - no rollback armed (--now)"
        return 0
    fi

    # ---- commit-confirm ------------------------------------------------
    # Arm a detached watcher BEFORE reloading, so it survives losing the
    # session. If it is not confirmed within WIFI_TIMEOUT it puts the old
    # values back and reloads again, so a bad regulatory domain cannot lock
    # you out of a router you only reach over Wi-Fi.
    rm -f "$WIFI_CONFIRM_FLAG"
    {
        echo '#!/bin/sh'
        echo "i=0"
        echo "while [ \$i -lt $WIFI_TIMEOUT ]; do"
        echo "    if [ -f $WIFI_CONFIRM_FLAG ]; then"
        echo "        rm -f $WIFI_CONFIRM_FLAG $WIFI_ROLLBACK"
        echo "        exit 0"
        echo "    fi"
        echo "    sleep 2"
        echo "    i=\$((i+2))"
        echo "done"
        for _r in $_radios; do
            echo "uci set wireless.$_r.country='$(uci -q get "wireless.$_r.country")'"
        done
        echo "uci commit wireless"
        echo "wifi reload"
        echo "rm -f $WIFI_ROLLBACK"
    } > "$WIFI_ROLLBACK"
    chmod +x "$WIFI_ROLLBACK"

    # Point -x at the script itself. Pointing it at /bin/sh makes
    # start-stop-daemon match the shell we are already running in and refuse
    # to start ("/bin/sh is already running").
    _armed=0
    if command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon -S -b -x "$WIFI_ROLLBACK" >/dev/null 2>&1 && _armed=1
    fi
    if [ "$_armed" = "0" ]; then
        # Portable nohup equivalent: ignore SIGHUP so it survives the session.
        ( trap '' HUP; /bin/sh "$WIFI_ROLLBACK" >/dev/null 2>&1 & )
    fi

    # Never take the risk on an unverified assumption that it is running.
    sleep 1
    _rbname=$(basename "$WIFI_ROLLBACK")
    if ! ps w 2>/dev/null | grep -v grep | grep -q "$_rbname"; then
        rm -f "$WIFI_ROLLBACK"
        die "could not arm the rollback watcher - nothing was changed.
       Connect over Ethernet and use '$0 wifi $_cc --now' instead."
    fi
    green "rollback armed - reverts in ${WIFI_TIMEOUT}s unless confirmed"

    for _r in $_radios; do
        uci set "wireless.$_r.country=$_cc" || die "uci set failed for $_r"
    done
    uci commit wireless || die "uci commit failed"
    echo
    bold "reloading radios..."
    wifi reload

    echo
    green "applied"
    echo
    red "NOT PERMANENT YET. Reconnect, then run this within ${WIFI_TIMEOUT} seconds:"
    echo
    echo "    $0 wifi-confirm"
    echo
    echo "If you do not, the previous values are restored automatically."
}

cmd_wifi_confirm() {
    require_root
    if [ ! -f "$WIFI_ROLLBACK" ]; then
        warn "no pending Wi-Fi change to confirm"
        for _r in $(wifi_radios); do
            printf '  %-14s [%s]\n' "$_r" "$(uci -q get "wireless.$_r.country")"
        done
        return 0
    fi
    touch "$WIFI_CONFIRM_FLAG"
    green "confirmed - rollback cancelled"
    for _r in $(wifi_radios); do
        printf '  %-14s [%s]\n' "$_r" "$(uci -q get "wireless.$_r.country")"
    done
}

cmd_restore() {
    require_root
    _backup="${1:-$DEFAULT_BACKUP}"
    _force="${2:-}"
    _dev=$(factory_mtdblock) || die "no Factory partition found"
    [ -f "$_backup" ] || die "backup not found: $_backup"

    _size=$(wc -c < "$_backup" | tr -d ' ')
    _fact=$(find_factory)
    _psize=$((0x$(grep "^${_fact}:" /proc/mtd | awk '{print $2}')))
    [ "$_size" = "$_psize" ] || die "backup is $_size bytes but partition is $_psize - refusing"

    # Refuse an image that belongs to a DIFFERENT unit. Each image carries its
    # own MACs, serials and RF calibration, so restoring the wrong one gives you
    # duplicate MACs and calibration data for someone else's radio.
    #
    # Only block when BOTH serials are readable and they disagree - if this
    # partition is already damaged its serial may be unreadable, and that is
    # exactly when a legitimate restore is most needed.
    _img_sn=$(read_serial "$_backup" 2>/dev/null)
    _dev_sn=$(read_serial 2>/dev/null)
    if [ -n "$_img_sn" ] && [ -n "$_dev_sn" ] && [ "$_img_sn" != "$_dev_sn" ]; then
        red "WRONG UNIT - refusing to restore."
        printf '  %-18s %s\n' "image serial"  "$_img_sn"
        printf '  %-18s %s\n' "this router"   "$_dev_sn"
        echo
        echo "This image was taken from a different router. Writing it here would"
        echo "give this unit that one's MAC addresses and the wrong Wi-Fi RF"
        echo "calibration, and the damage is not undoable without the correct image."
        echo
        echo "Find the backup whose serial is $_dev_sn and use that instead."
        echo "If you are certain you want to proceed anyway:"
        echo "    $0 restore $_backup --force"
        exit 1
    fi
    if [ "$_force" = "--force" ] && [ "$_img_sn" != "$_dev_sn" ]; then
        warn "--force given: skipping the unit-match check"
    fi

    bold "Restoring $_backup -> $_dev  ($_size bytes)"
    printf '%-22s %s\n' "image serial" "${_img_sn:-unreadable}"
    red "This overwrites the whole Factory partition. Do not lose power."
    confirm "Type YES to restore:"

    dd if="$_backup" of="$_dev" bs=4096 2>/dev/null || die "restore failed"
    sync

    # Verify. This is the emergency path - whoever is running it is already
    # recovering from something, so confirm the partition actually matches the
    # image rather than just reporting that dd exited 0.
    echo
    bold "verifying"
    _live_md5=$(dd if="$_dev" bs=4096 2>/dev/null | md5sum | awk '{print $1}')
    _bak_md5=$(md5sum "$_backup" | awk '{print $1}')
    printf '%-22s %s\n' "image md5"     "$_bak_md5"
    printf '%-22s %s\n' "partition md5" "$_live_md5"
    if [ "$_live_md5" != "$_bak_md5" ]; then
        red "MISMATCH - the partition does not match the image."
        red "Do NOT reboot yet - try the restore again while you still have a shell."
        red "If it keeps failing, see docs/RECOVERY.md section 4 (U-Boot recovery)."
        exit 1
    fi
    green "verified - partition matches the image byte for byte"
    printf '%-22s [%s]\n' "country code" "$(read_flash_cc)"
    warn "reboot now"
}

usage() {
    cat <<USAGE
glinet-region.sh v$VERSION

Inspect and change the region lock on GL.iNet routers.
Run this ON the router, as root, over SSH.

  $0 status              Show model, serial, firmware, Factory partition, region
                         code and Wi-Fi regulatory domain. Read-only. Always run
                         this first.

  $0 backup [file]       Dump the Factory partition (default: $DEFAULT_BACKUP).
                         Does not modify flash. Do this before patching. Prints
                         the router's serial - name the file after it if you own
                         more than one of these.

  $0 soft <CC>           Reversible UCI override. Unlocks the hidden pages without
                         touching flash. Lost on factory reset / clean upgrade.

  $0 soft-undo           Remove the UCI override.

  $0 patch <CC> [backup] PERMANENT. Writes <CC> into the Factory partition.
                         Survives factory reset and firmware upgrades.
                         Requires a fresh backup. Can brick the radios.

  $0 restore [backup] [--force]
                         Write a backup image back to the Factory partition and
                         verify it byte for byte. Refuses an image whose serial
                         belongs to a different router; --force overrides that.

  $0 wifi <CC> [--now]   Set the Wi-Fi regulatory domain (a SEPARATE setting from
                         the region code). Reloads the radios, so it disconnects
                         Wi-Fi clients. By default it arms a ${WIFI_TIMEOUT}s rollback
                         and you must run 'wifi-confirm' to keep the change.
                         Use --now to skip the rollback (do this only on Ethernet).

  $0 wifi-confirm        Keep a pending 'wifi' change and cancel the rollback.

<CC> is a 2-letter uppercase ISO 3166-1 code, e.g. CA, US, DE.
Any value other than "CN" opens the region gates - pick the one where you
actually are, because the Wi-Fi domain must match your real location.

Note: /tmp is a ramdisk. After a reboot you must re-upload this script and
re-take any backup you left there.
USAGE
}

case "${1:-}" in
    status)       shift; cmd_status "$@" ;;
    backup)       shift; cmd_backup "$@" ;;
    soft)         shift; cmd_soft "$@" ;;
    soft-undo)    shift; cmd_soft_undo "$@" ;;
    patch)        shift; cmd_patch "$@" ;;
    restore)      shift; cmd_restore "$@" ;;
    wifi)         shift; cmd_wifi "$@" ;;
    wifi-confirm) shift; cmd_wifi_confirm "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '${1}' (try: $0 help)" ;;
esac
