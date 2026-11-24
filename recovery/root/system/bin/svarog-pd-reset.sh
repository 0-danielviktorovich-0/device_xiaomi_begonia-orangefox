#!/system/bin/sh
# svarog-pd-reset.sh — software USB replug for begonia (MT6785, kernel 4.14 MTK)
#
# PROBLEM: reboot with cable attached keeps VBUS up -> CC negotiation is not
# replayed from the Mac's point of view -> Mac does not see a re-attach
# (device absent from the bus, charging may drop until a physical replug).
#
# FIX: replay the negotiation from the phone side (software replug), ladder:
#   L1  gadget rebind (configfs UDC)      — data only, does NOT touch PD/charging
#   L2  PD PR_SWAP (pd_test=1)            — power/data role swap over the live PD contract
#   L3  CC replay via role_def (SNK->Try.SRC) — electrical detach (CC open) + re-attach
# L3 is the kernel-proven path: tcpc_typec_change_role() forces CC=OPEN when the
# new role conflicts with local CC (tcpc_begonia/tcpci_typec.c, force_unattach).
#
# DISCIPLINE (hard rules, do not "optimize" away):
#   - AT MOST ONE rebind per invocation. Rebind loops broke charging when the
#     cable flapped (kbuild-31 lesson) and a blind rebind racing init caused a
#     kernel panic (do_usb_state_monitor_work NULL-deref, android0 EEXIST).
#   - >=5 s pause after every action before re-evaluating state.
#   - Always read the current state BEFORE unbind/bind.
#
# Exact nodes (kernel 4.14, saikrishna tree, CONFIG_MTK_CHARGER_BEGONIA=y):
#   /sys/class/tcpc/type_c_port0/pd_test  (0664)
#       1=PR_SWAP 2=DR_SWAP 3=VCONN_SWAP 4=PD soft reset 5=PD hard reset
#       (tcpc_begonia/tcpci_core.c, TCPC_DESC_PD_TEST store)
#   /sys/class/tcpc/type_c_port0/role_def (0444, root can write)
#       0=UNKNOWN 1=SNK 2=SRC 3=DRP 4=TRY_SRC 5=TRY_SNK (inc/tcpm.h);
#       DTS default for begonia = 4 (mt6360_pd.dtsi: mt-tcpc,role_def = <4>)
#   /config/usb_gadget/g1/UDC             — UDC name: musb-hdrc (mtu3 masquerade)
#   /sys/class/udc/musb-hdrc/state        — "configured" = healthy
# NOTE: /sys/class/typec/port0 does NOT exist on this kernel (CONFIG_TYPEC=n);
# the MTK tcpc class is the only Type-C interface.
#
# Usage:
#   svarog-pd-reset.sh            # full ladder, no-ops if already healthy
#   svarog-pd-reset.sh --check    # print state only
#   svarog-pd-reset.sh --rebind   # L1 only
#   svarog-pd-reset.sh --pr-swap  # L2 only
#   svarog-pd-reset.sh --cc       # L3 only
#   svarog-pd-reset.sh --boot     # wait for boot settle, then full ladder
# Exit code: 0 = healthy at the end, 1 = still broken.

G1=${G1:-/config/usb_gadget/g1}
UDC=${UDC:-musb-hdrc}
TCPC=""

LOG="${LOG:-/tmp/recovery/pd-reset.log}"  # /data may be unmounted in recovery; /tmp/recovery is tmpfs
LOCK=/dev/.svarog-pd-reset.lock

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() {
    echo "svarog-pd-reset[$$] $(ts): $1" >> "$LOG" 2>/dev/null
    echo "svarog-pd-reset: $1" > /dev/kmsg 2>/dev/null
}

# --- single-instance guard (KSU service.sh + manual run must not overlap) ---
if mkdir "$LOCK" 2>/dev/null; then
    trap 'rm -rf "$LOCK" 2>/dev/null' EXIT
else
    echo "svarog-pd-reset: another instance holds $LOCK, exiting" >&2
    exit 1
fi

find_tcpc() {
    if [ -d /sys/class/tcpc/type_c_port0 ]; then
        TCPC=/sys/class/tcpc/type_c_port0
    else
        # fallback: first tcpc class device (name comes from DTS mt-tcpc,name)
        local d
        for d in /sys/class/tcpc/*; do
            if [ -e "$d/pd_test" ]; then TCPC="$d"; break; fi
        done
    fi
    [ -n "$TCPC" ] && [ -d "$TCPC" ]
}

udc_state() { cat /sys/class/udc/"$UDC"/state 2>/dev/null; }
udc_bound() { [ "$(cat "$G1/UDC" 2>/dev/null)" = "$UDC" ]; }

healthy() {
    [ "$(udc_state)" = "configured" ] && udc_bound
}

report() {
    log "state: udc=[$(cat "$G1/UDC" 2>/dev/null)] udc_state=[$(udc_state)]" \
        "role_def=[$(cat "$TCPC/role_def" 2>/dev/null | tr -d '\n')]" \
        "pd_test_writable=$([ -w "$TCPC/pd_test" ] && echo yes || echo no)"
}

# --- L1: guarded gadget rebind. Data-only; PD contract untouched. ---
do_rebind() {
    local cur
    cur=$(cat "$G1/UDC" 2>/dev/null)
    log "L1 rebind: current UDC=[$cur] state=[$(udc_state)]"
    if ! [ -d "$G1" ]; then
        log "L1: $G1 missing (configfs not mounted); skip"
        return 1
    fi
    # never blind-unbind: if already unbound, bind directly
    if [ -n "$cur" ]; then
        echo none > "$G1/UDC" 2>/dev/null
        sleep 1
    fi
    echo "$UDC" > "$G1/UDC" 2>/dev/null
    # restart adbd if it died on unbind
    setprop ctl.restart adbd 2>/dev/null
    sleep 5
    log "L1 done: UDC=[$(cat "$G1/UDC" 2>/dev/null)] state=[$(udc_state)]"
}

# --- L2: PD PR_SWAP over the live contract (keeps VBUS per spec). ---
do_pr_swap() {
    if ! [ -w "$TCPC/pd_test" ]; then
        log "L2: $TCPC/pd_test not writable (PD framework off?); skip"
        return 1
    fi
    log "L2 PR_SWAP: echo 1 > $TCPC/pd_test"
    echo 1 > "$TCPC/pd_test" 2>/dev/null
    sleep 5
    log "L2 done: state=[$(udc_state)] role_def=[$(cat "$TCPC/role_def" 2>/dev/null | tr -d '\n')]"
}

# --- L3: CC replay. SNK forces CC=OPEN when attached with RP (guaranteed ---
# electrical detach), then restore the DTS default Try.SRC -> fresh attach.
do_cc_replug() {
    if ! [ -e "$TCPC/role_def" ]; then
        log "L3: $TCPC/role_def missing; skip"
        return 1
    fi
    log "L3 CC replay: role_def SNK -> Try.SRC"
    echo 1 > "$TCPC/role_def" 2>/dev/null   # SNK: force_unattach if local_cc=RP
    sleep 2
    echo 4 > "$TCPC/role_def" 2>/dev/null   # TRY_SRC: stock default (mt6360_pd.dtsi)
    sleep 5
    log "L3 done: state=[$(udc_state)] role_def=[$(cat "$TCPC/role_def" 2>/dev/null | tr -d '\n')]"
}

ladder() {
    if healthy; then
        log "healthy (udc_state=configured), no action"
        return 0
    fi
    report
    log "unhealthy -> ladder: L1 rebind, 5s, L2 PR_SWAP, 5s, L3 CC replay"
    do_rebind
    healthy && return 0
    do_pr_swap
    healthy && return 0
    do_cc_replug
    healthy && return 0
    log "ladder finished, still unhealthy"
    return 1
}

MODE="${1:---run}"
case "$MODE" in
    --check)
        find_tcpc || { echo "no tcpc class device" >&2; exit 1; }
        echo "TCPC=$TCPC"
        echo "UDC=[$(cat "$G1/UDC" 2>/dev/null)] state=[$(udc_state)]"
        echo "role_def=[$(cat "$TCPC/role_def" 2>/dev/null | tr -d '\n')]"
        echo "pd_test=$([ -w "$TCPC/pd_test" ] && echo writable || echo not-writable)"
        echo "healthy=$(healthy && echo yes || echo no)"
        ;;
    --rebind)
        find_tcpc; do_rebind; healthy && exit 0 || exit 1 ;;
    --pr-swap)
        find_tcpc || exit 1; do_pr_swap; healthy && exit 0 || exit 1 ;;
    --cc)
        find_tcpc || exit 1; do_cc_replug; healthy && exit 0 || exit 1 ;;
    --boot)
        # settle: let init/usb raise the composition first; PD reset only if stuck
        sleep 15
        find_tcpc || exit 1
        ladder
        ;;
    --run|"")
        find_tcpc || { log "no tcpc class device"; exit 1; }
        ladder
        ;;
    *)
        echo "usage: $0 [--check|--rebind|--pr-swap|--cc|--boot]" >&2
        exit 2
        ;;
esac
