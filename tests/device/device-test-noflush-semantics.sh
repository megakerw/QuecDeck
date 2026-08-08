#!/bin/sh
# iptables-restore --noflush semantics probe. GATES the iptables-restore
# based quecdeck/script/firewall.sh: it relies on a declared chain
# (":NAME - [0:0]") being FLUSHED and refilled under --noflush, which changed
# across iptables versions. Ran GO (3/3) on the device 2026-07-19; re-run
# after any modem firmware update that could change the iptables build.
#
#     sh device-test-noflush-semantics.sh
#
# Uses throwaway chains (QDTEST/QDTEST2) only; never touches QUECDECK, INPUT,
# or any QCMAP state. Cleans up after itself on any exit.
#
# Verdicts:
#   GO      declared chains are flushed under --noflush, new chains are
#           created, and -w is accepted: the draft works as written.
#   NO-GO   append semantics (stale rules would accumulate) or missing
#           option: the draft needs an explicit flush step or is off.

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

cleanup() {
    iptables -w 5 -F QDTEST  2>/dev/null
    iptables -w 5 -X QDTEST  2>/dev/null
    iptables -w 5 -F QDTEST2 2>/dev/null
    iptables -w 5 -X QDTEST2 2>/dev/null
}

[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
command -v iptables-restore >/dev/null 2>&1 || { echo "FATAL: iptables-restore not found."; exit 1; }
trap cleanup EXIT INT TERM
cleanup

echo "=================================================================="
echo " iptables-restore --noflush semantics probe"
echo " $(iptables --version 2>/dev/null)"
echo "=================================================================="

# ---- Probe 1: declared existing chain: flushed or appended? -------------
echo ""
echo "[Probe 1] --noflush on a DECLARED, pre-existing chain with old content"
iptables -w 5 -N QDTEST
iptables -w 5 -A QDTEST -p tcp --dport 9 -j RETURN    # marker: the OLD rule
if printf '*filter\n:QDTEST - [0:0]\n-A QDTEST -p tcp --dport 7 -j RETURN\nCOMMIT\n' \
        | iptables-restore --noflush -w 5; then
    ok "iptables-restore --noflush -w 5 accepted (options supported)"
else
    bad "iptables-restore --noflush -w 5 FAILED outright; draft is a NO-GO as written"
fi
_rules=$(iptables -w 5 -S QDTEST 2>/dev/null)
_has_old=$(printf '%s\n' "$_rules" | grep -c -- '--dport 9')
_has_new=$(printf '%s\n' "$_rules" | grep -c -- '--dport 7')
if [ "$_has_new" = "1" ] && [ "$_has_old" = "0" ]; then
    ok "FLUSH semantics: declared chain was flushed and refilled (draft-compatible)"
elif [ "$_has_new" = "1" ] && [ "$_has_old" = "1" ]; then
    bad "APPEND semantics: old rule survived alongside the new one; the draft would accumulate stale rules on every run and needs an explicit flush step"
else
    bad "unexpected chain state after restore (old=$_has_old new=$_has_new); inspect: iptables -S QDTEST"
fi

# ---- Probe 2: declared chain that does not exist yet --------------------
echo ""
echo "[Probe 2] --noflush creates a DECLARED chain that does not exist"
if printf '*filter\n:QDTEST2 - [0:0]\n-A QDTEST2 -p tcp --dport 7 -j RETURN\nCOMMIT\n' \
        | iptables-restore --noflush -w 5 \
        && iptables -w 5 -S QDTEST2 >/dev/null 2>&1; then
    ok "missing declared chain was created (first-boot path works)"
else
    bad "declared-but-missing chain was NOT created; first boot would fail"
fi

# ---- verdict ------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: GO -- device semantics match the draft; proceed to the"
    echo "          full device pass (coupling, fail-closed, SSH tests)."
else
    echo " VERDICT: NO-GO -- the draft's --noflush assumption does not hold"
    echo "          on this build; rework the flush strategy first."
fi
echo "=================================================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1
