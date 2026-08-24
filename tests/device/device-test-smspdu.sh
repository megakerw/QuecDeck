#!/bin/bash
# On-device check that the PDU-mode SMS rewrite holds against a REAL inbox.
# Run as root:
#   /tmp/device-test-smspdu.sh
# Dev tool, not deployed. Copy it to the device manually and delete it after.
# Read-only: never deletes, never sends.
#
# PRIVACY: prints STRUCTURE ONLY. PDU hex carries the body and sender in clear
# and is never echoed. Senders are relabelled S1, S2, ... The output is safe to
# paste back.
#
# Checks what only a real inbox can settle:
#   1. AT+CMGF=0 with AT+CMGL=4 is accepted by THIS firmware, and CMGL="ALL"
#      really does answer ERROR in PDU mode as cgi-bin/get_sms claims.
#   2. Header shape sms.js keys on: numeric status, empty alpha field.
#   3. The PDU sits on the next non-empty line after its header.
#   4. No bucket is missing parts. A repeated sequence is reference reuse, not
#      a fault - the split rule at the end separates those.
#   5. Non-adjacent storage slots, which broke the old adjacency heuristic.
#      Zero means it was not reproducible today, not that the heuristic was ok.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
skp()  { skip=$((skip+1)); echo "SKIP: $1"; }
note() { echo "NOTE: $1"; }

# ------------------------------------------------------- the AT chain -----
# The exact command cgi-bin/get_sms sends, same timeout: a bare CMGL would miss
# an earlier command leaving the modem in a state CMGL then trips over.
CHAIN='AT+CSMS=1;+CSDH=0;+CNMI=2,1,0,0,0;+CMGF=0;+CPMS="ME","ME","ME";+CMGL=4'

echo "--- the get_sms command chain"
raw=$(atcmd_run "$CHAIN" 5000) || { bad "atcmd_run failed outright"; raw=""; }
case "$raw" in
    *OK*)    ok "chain returns OK" ;;
    *ERROR*) bad "chain returns ERROR" "the modem rejected one of the commands" ;;
    *)       bad "chain returned no terminator" "truncated, or the 5000 ms budget is too tight" ;;
esac
echo "response: ${#raw} bytes"

# The claim in the get_sms comment, checked rather than assumed.
echo ""
echo "--- text-mode spelling in PDU mode"
alt=$(atcmd_run 'AT+CMGF=0;+CMGL="ALL"' 5000)
case "$alt" in
    *ERROR*) ok 'CMGL="ALL" answers ERROR in PDU mode, as get_sms comments' ;;
    *OK*)    note 'CMGL="ALL" is ACCEPTED in PDU mode here - the get_sms comment is wrong for this firmware' ;;
    *)       skp 'CMGL="ALL" gave no terminator' ;;
esac

# ------------------------------------------------------ header shapes -----
echo ""
echo "--- header shape"
# \r is already stripped at the atcli layer. Trim defensively anyway.
lines=$(printf '%s\n' "$raw" | tr -d '\r')
pdu_hdrs=$(printf '%s\n' "$lines" | grep -c '^+CMGL:[[:space:]]*[0-9]\+,[[:space:]]*[0-9]\+[[:space:]]*,')
txt_hdrs=$(printf '%s\n' "$lines" | grep -c '^+CMGL:[[:space:]]*[0-9]\+,[[:space:]]*"')
all_hdrs=$(printf '%s\n' "$lines" | grep -c '^+CMGL:')
echo "headers: $all_hdrs total, $pdu_hdrs PDU-shaped, $txt_hdrs text-shaped"
if [ "$all_hdrs" -eq 0 ]; then
    skp "inbox is empty - nothing below can be checked"
    echo ""; echo "pass=$pass fail=$fail skip=$skip"
    exit $(( fail > 0 ))
fi
[ "$pdu_hdrs" -eq "$all_hdrs" ] && ok "every header is PDU-shaped" \
    || bad "$(( all_hdrs - pdu_hdrs )) headers are not PDU-shaped" "sms.js would skip these"
# The empty alpha field: sms.js does not read it, but a quoted one here would
# mean CSDH=0 is not doing what the chain assumes.
odd_alpha=$(printf '%s\n' "$lines" | grep -c '^+CMGL:[[:space:]]*[0-9]\+,[[:space:]]*[0-9]\+,[^,]')
[ "$odd_alpha" -eq 0 ] && ok "alpha field is empty on every header" \
    || note "$odd_alpha headers carry a non-empty alpha field"

# ------------------------------------------------- header/PDU pairing -----
# sms.js takes the next NON-EMPTY line after a header. Measure how far away
# the PDU actually is, so a firmware that pads differently is visible.
echo ""
echo "--- header to PDU pairing"
gap_report=$(printf '%s\n' "$lines" | awk '
    /^\+CMGL:[[:space:]]*[0-9]+,[[:space:]]*[0-9]+[[:space:]]*,/ { want=1; gap=0; next }
    want && $0 == "" { gap++; next }
    want {
        if ($0 ~ /^[0-9A-Fa-f]+$/ && length($0) % 2 == 0) hits[gap]++
        else nonhex++
        want=0
    }
    END {
        for (g in hits) printf "gap%s=%s ", g, hits[g]
        printf "nonhex=%s", nonhex+0
    }')
echo "$gap_report"
case "$gap_report" in
    *nonhex=0) ok "a valid hex PDU follows every header" ;;
    *)         bad "some headers are not followed by hex" "sms.js logs and skips these" ;;
esac
case "$gap_report" in
    gap0=*[0-9]*" "*gap[1-9]*) note "some PDUs are separated from their header by a blank line - the non-empty-line scan is load-bearing here" ;;
esac

# --------------------------------------------------- per-PDU structure -----
# Decode only the envelope, never the user data. Fields printed: message type,
# UDH flag, sender type-of-number, DCS, UDL, and the concatenation triple.
echo ""
echo "--- PDU envelope (no bodies, no sender digits)"
printf '%s\n' "$lines" | awk '
    /^\+CMGL:[[:space:]]*[0-9]+,[[:space:]]*[0-9]+[[:space:]]*,/ {
        split($0, f, /[:,]/); idx=f[2]+0; want=1; next
    }
    want && $0 == "" { next }
    want { want=0; if ($0 ~ /^[0-9A-Fa-f]+$/) print idx "\t" toupper($0) }
' | while IFS=$'\t' read -r idx pdu; do
    hx() { printf '%d' "0x${pdu:$1:2}"; }              # octet at hex offset $1
    p=0
    smsc=$(hx $p);            p=$(( p + 2 + smsc*2 ))
    ptype=$(hx $p);           p=$(( p + 2 ))
    mti=$(( ptype & 3 )); udhi=$(( (ptype & 64) != 0 ))
    adig=$(hx $p);            p=$(( p + 2 ))
    aton=$(hx $p);            p=$(( p + 2 ))
    # Sender digits are read only to advance past them and to build a stable
    # anonymous label. They are never printed.
    aoct=$(( (adig + 1) / 2 ))
    asender=${pdu:$p:$(( aoct*2 ))}; p=$(( p + aoct*2 ))
    p=$(( p + 2 ))                                     # protocol identifier
    dcs=$(hx $p);             p=$(( p + 2 ))
    # Service centre timestamp as a sortable key only, never a printed date:
    # swap each semi-octet pair, since the low nibble is the tens digit.
    tkey=""
    for o in 0 2 4 6 8 10; do
        tkey="$tkey${pdu:$(( p + o + 1 )):1}${pdu:$(( p + o )):1}"
    done
    p=$(( p + 14 ))
    udl=$(hx $p);             p=$(( p + 2 ))

    ref=-1; tot=0; seq=0
    if [ "$udhi" -eq 1 ]; then
        udhl=$(hx $p)
        q=$(( p + 2 )); stop=$(( p + 2 + udhl*2 ))
        while [ "$q" -lt "$stop" ]; do
            iei=$(hx $q); ilen=$(printf '%d' "0x${pdu:$(( q+2 )):2}")
            v=$(( q + 4 ))
            if [ "$iei" -eq 0 ] && [ "$ilen" -ge 3 ]; then
                ref=$(printf '%d' "0x${pdu:$v:2}")
                tot=$(printf '%d' "0x${pdu:$(( v+2 )):2}")
                seq=$(printf '%d' "0x${pdu:$(( v+4 )):2}")
            elif [ "$iei" -eq 8 ] && [ "$ilen" -ge 4 ]; then
                ref=$(printf '%d' "0x${pdu:$v:4}")
                tot=$(printf '%d' "0x${pdu:$(( v+4 )):2}")
                seq=$(printf '%d' "0x${pdu:$(( v+6 )):2}")
            fi
            q=$(( v + ilen*2 ))
        done
    fi
    # Anonymous but stable per sender, so grouping stays checkable.
    echo "$idx $mti $udhi $(( (aton >> 4) & 7 )) $dcs $udl $ref $tot $seq $asender $tkey"
done > /tmp/smspdu.$$

# ---------------------------------------------------------- summary -----
awk '
    { idx=$1; mti=$2; udh=$3; ton=$4; dcs=$5; ref=$7; tot=$8; seq=$9; snd=$10
      n++
      if (mti != 0) nondeliver++
      if (!(snd in label)) label[snd] = "S" (++senders)
      alpha = (int(dcs/64)==0) ? int(dcs/4)%4 : (int(dcs/16)==15 ? (int(dcs/4)%2) : int(dcs/4)%4)
      alph[alpha]++
      tonc[ton]++
      if (udh && ref >= 0) {
          key = label[snd] " ref" ref " of" tot
          grp[key] = grp[key] " " seq
          slots[key] = slots[key] " " idx
          if (!(key in seen)) order[++groups] = key
          seen[key]++
      } else singles++
    }
    END {
      printf "\nstored parts: %d   distinct senders: %d\n", n, senders
      printf "%d standalone + %d concatenation buckets (a bucket can hold more than one message, as shown by the split rule replay below)\n", singles, groups
      if (nondeliver) printf "NOTE: %d entries are not SMS-DELIVER. sms.js skips these by design\n", nondeliver
      printf "alphabets: GSM7=%d 8bit=%d UCS2=%d other=%d\n", alph[0]+0, alph[1]+0, alph[2]+0, alph[3]+0
      printf "sender type-of-number: alphanumeric=%d international=%d national/other=%d\n", tonc[5]+0, tonc[1]+0, n-(tonc[5]+0)-(tonc[1]+0)

      print "\n--- concatenation groups"
      bad=0; scattered=0
      for (i=1; i<=groups; i++) {
          k = order[i]; split(grp[k], s, " "); split(slots[k], sl, " ")
          split(k, kf, "of"); total = kf[2]+0
          # complete = each of 1..total present exactly once. Counts are keyed
          # per group in one array rather than cleared between groups: busybox
          # awk does not reliably support deleting a whole array.
          cnt=0
          for (j in s) if (s[j] != "") { have[i SUBSEP s[j]]++; cnt++ }
          missing=""; dup=""
          for (q=1; q<=total; q++) {
              c = have[i SUBSEP q] + 0
              if (c == 0) missing = missing " " q
              else if (c > 1) dup = dup " " q
          }
          # non-adjacent storage slots?
          lo=99999; hi=-1
          for (j in sl) if (sl[j] != "") { v=sl[j]+0; if (v<lo) lo=v; if (v>hi) hi=v }
          gap = (hi - lo + 1 != cnt)
          if (gap) scattered++
          # A repeated sequence is reference reuse, not corruption: the 8-bit
          # reference gets recycled. Counted apart from missing parts so a
          # healthy inbox does not report a failure.
          status = "complete"
          if (dup != "")     { status = "REUSED reference (splits into " int(cnt/total) ")"; reused++ }
          if (missing != "") { status = "MISSING parts" missing; bad++ }
          printf "  %-24s %d/%d parts  %-34s slots %d..%d%s\n", k, cnt, total, status, lo, hi, (gap ? "  (NON-ADJACENT)" : "")
      }
      printf "\n%s: %d buckets have parts missing\n", (bad ? "FAIL" : "PASS"), bad
      if (reused)
          printf "NOTE: %d buckets reuse one reference for several messages - the split rule must separate these\n", reused
      if (groups)
          printf "%s: %d of %d groups have non-adjacent slots%s\n",
                 (scattered ? "NOTE" : "NOTE"), scattered, groups,
                 (scattered ? " - the old adjacency heuristic would have split these" : " - the old heuristic happened not to break on this inbox today")
    }
' /tmp/smspdu.$$

# -------------------------------------------------- split-rule replay -----
# A bucket is not a message: the 8-bit reference gets reused. Replays the
# sms.js rule (oldest first, close on a repeated sequence or when full) and
# reports the resulting count. Sorted here because busybox awk has no asort.
echo ""
echo "--- split rule replay (what sms.js will produce)"
sort -k10,10 -k7,7n -k8,8n -k11,11 -k1,1n /tmp/smspdu.$$ | awk '
    { udh=$3; ref=$7; tot=$8; seq=$9; snd=$10
      if (!udh || ref < 0) { singles++; next }
      key = snd " " ref " " tot
      if (key != cur) { if (n) msgs++; cur = key; n = 0; split("", have) }
      if (seq in have) { msgs++; n = 0; split("", have) }
      have[seq] = 1; n++
      if (n == tot) { msgs++; n = 0; split("", have) }
    }
    END {
      if (n) msgs++
      printf "messages after the split rule: %d (%d standalone + %d from concatenated parts)\n",
             singles + msgs, singles, msgs
    }'

rm -f /tmp/smspdu.$$
echo ""
echo "pass=$pass fail=$fail skip=$skip  (plus the group check above)"
echo "Delete this script from the device when done."
