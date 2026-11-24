#!/system/bin/sh
# svarog-gadget.sh — USB-gadget watchdog for begonia recovery (MT6785/Svarog kernel)
#
# Root cause it papers over: sys.usb.controller is only set from
# ro.boot.usbcontroller (passed by LK). On warm reboots into recovery LK may
# not pass it, so every "write UDC ${sys.usb.controller}" writes nothing, the
# gadget stays unbound and the phone shows up as "charging only". This
# watchdog guarantees the controller name and re-raises the adb composition
# through the stock init triggers.
#
# Runs as a oneshot service: 45 iterations x 1s. No HID on start.
# Identity: 0x18d1/0x4ee7 (adb) — matches init.recovery.usb.rc.
# Log: /tmp/recovery/gadget.log (tmpfs mounted by recovery init).
#
# Escalation ladder (usb-replug-fix-2026-11-24 discipline):
#   - L1 point rebind + composition re-raise (this script's kick)
#   - after 2 consecutive failed kick cycles -> svarog-pd-reset.sh
#     (L2 PD PR_SWAP, L3 CC replay via role_def) — software replug for the
#     host side when VBUS never drops (Mac does not see the re-attach).
# Anti-EEXIST rule: ALWAYS read UDC/state before unbind (blind rebind racing
# init's usb state machine = kernel panic, kbuild-31 lesson #19).
# At most one rebind per kick; >= 1s pause between unbind and bind.

G1=/config/usb_gadget/g1
STATE=/sys/class/udc/musb-hdrc/state
LOGDIR=/tmp/recovery
LOG=$LOGDIR/gadget.log
PDRESET=/system/bin/svarog-pd-reset.sh

log() {
    echo "svarog-gadget: $1" >> "$LOG" 2>/dev/null
    echo "svarog-gadget: $1" > /dev/kmsg 2>/dev/null
}

mkdir -p "$LOGDIR" 2>/dev/null

# Wait for configfs gadget (mounted in the `on fs` phase of init.recovery.usb.rc)
i=0
while [ "$i" -lt 10 ] && [ ! -d "$G1" ]; do
    sleep 1
    i=$((i + 1))
done
if [ ! -d "$G1" ]; then
    log "FATAL: $G1 missing (configfs not mounted); giving up"
    exit 1
fi

# Fix the controller name unconditionally — the whole point of this script.
setprop sys.usb.controller musb-hdrc

kick() {
    log "kick: udc_state=[$(cat "$STATE" 2>/dev/null)] config=$(getprop sys.usb.config) ffs.ready=$(getprop sys.usb.ffs.ready)"
    # Point rebind: unbind (only if bound), then rebind musb-hdrc.
    if [ -n "$(cat "$G1/UDC" 2>/dev/null)" ]; then
        echo none > "$G1/UDC" 2>/dev/null
        sleep 1
    fi
    # Full composition re-raise through the stock triggers (none -> adb).
    setprop sys.usb.config none
    sleep 1
    # adb identity, no HID on start.
    setprop sys.usb.config adb
    # If adbd died on unbind, restart it.
    setprop ctl.restart adbd 2>/dev/null
    sleep 2
    # Belt and braces: bind directly in case the trigger raced us.
    echo musb-hdrc > "$G1/UDC" 2>/dev/null
    echo 0 > /sys/devices/platform/mt_usb/saving 2>/dev/null
    log "kick done: udc_state=[$(cat "$STATE" 2>/dev/null)] udc=[$(cat "$G1/UDC" 2>/dev/null)]"
}

# L2/L3 software replug (PD PR_SWAP + CC replay) for the stuck-host case.
pd_escalate() {
    if [ ! -x "$PDRESET" ]; then
        log "pd-escalate: $PDRESET missing; skip"
        return
    fi
    log "2 kicks failed; escalating to PD reset (PR_SWAP / CC replay)"
    LOG=/tmp/recovery/pd-reset.log "$PDRESET" >> "$LOG" 2>&1
    log "pd-escalate done: udc_state=[$(cat "$STATE" 2>/dev/null)] udc=[$(cat "$G1/UDC" 2>/dev/null)]"
}

i=0
kick_failures=0
pd_done=0
while [ "$i" -lt 45 ]; do
    ST=$(cat "$STATE" 2>/dev/null)
    # Empty state = UDC not bound at all. "not attached"/"powered" = bound
    # but the gadget composition is not up. "configured" = healthy.
    if [ -z "$ST" ] || [ "$ST" = "not attached" ] || [ "$ST" = "powered" ]; then
        if [ "$(getprop sys.usb.config)" = "adb" ]; then
            kick
            kick_failures=$((kick_failures + 1))
            # Two failed kick cycles in a row -> the host side is stuck
            # (VBUS up, no CC replay). Escalate once, then fall back to kicks.
            if [ "$kick_failures" -ge 2 ] && [ "$pd_done" -eq 0 ]; then
                pd_escalate
                pd_done=1
                kick_failures=0
            fi
        else
            log "sys.usb.config=$(getprop sys.usb.config) != adb with udc_state=[$ST]; forcing adb"
            setprop sys.usb.config adb
        fi
    else
        kick_failures=0
    fi
    sleep 1
    i=$((i + 1))
done

log "exit: udc_state=[$(cat "$STATE" 2>/dev/null)] udc=[$(cat "$G1/UDC" 2>/dev/null)] config=$(getprop sys.usb.config)"
