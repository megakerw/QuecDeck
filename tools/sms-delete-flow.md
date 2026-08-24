# SMS delete: how it works, and the caps that bound it

Traces a delete from the checkbox to the modem, and records what was measured
on an RM520N-GL rather than assumed. Written after a bug where deleting a large
selection erased nothing and reported nothing.

Read this before changing `cgi-bin/delete_sms`, `js/sms.js`, or the length
guard in `script/at-lib.sh`.

## The path

```
sms.html checkbox  ->  selectedMessages (row numbers, not slots)
js/sms.js           ->  message.indices (storage slots, one per PART)
POST indices=N,N,.. ->  cgi-bin/delete_sms
delete_sms          ->  one +CMGD per AT line, never chained
script/at-lib.sh    ->  atcmd_run, maps atcli's exit 65 to an ERROR body line
quecdeck/atcli      ->  refuses over CMD_MAX before connecting, then uses a unix socket
atcmd-daemon        ->  owns the AT port, serializes, enforces CMD_MAX
modem
```

## What an index actually is

An index is a **storage slot in the modem's message store**, taken from the
`+CMGL: <index>,...` header that `cgi-bin/get_sms` reads (`js/sms.js:71`,
assigned at `:86`). Three properties matter:

- **Slots are per storage.** A delete issued against a different storage would
  address different messages entirely, so `delete_sms` re-selects `ME` on every
  line rather than trusting that a previous command left it there. That is not
  paranoia: the daemon serializes single commands, not requests, so another
  CGI's `+CPMS` can land between two of ours. Measured: the modem already
  defaults to `ME` here, so it is insurance, not a fix.

  The two paths set **different scopes on purpose**. `get_sms` sends
  `+CPMS="ME","ME","ME"` because `<mem3>` is where arriving messages are
  stored, and the listing pins it to `ME` so new messages land where the page
  can see them. `delete_sms` sends `+CPMS="ME"` only: deleting a message must
  not relocate the receive store as a side effect. Device-verified 2026-08-06
  that omitting `<mem2>`/`<mem3>` preserves them rather than resetting them.
- **Slots are not chronological.** The modem reuses freed low slots for new
  messages, so the UI sorts by timestamp, never by index (`js/sms.js:140`).
- **One displayed message is usually several slots.** A concatenated SMS is
  stored one part per slot, so `message.indices` is a list
  (`js/sms.js:133`). Deleting "one message" can mean a dozen `+CMGD=`
  commands. This is the single most important fact here: the cost of a delete
  scales with **parts**, not with messages, and every cap below is a cap on
  parts.

### PDU mode is load-bearing for a second reason

`get_sms` uses `+CMGF=0` because only the PDU carries the User Data Header
that says which parts form one message. There is an independent reason not to
go back to text mode.

The AT layer decides a reply has ended by matching the **start of a line**
against a terminator table (`OK`, `ERROR`, `NO CARRIER`, ...). Nothing
distinguishes the modem saying `OK` from a line of reply content that happens
to read `OK`. In text mode an SMS body is delivered verbatim, so a message
whose text contains `NO CARRIER` on a line of its own ends the listing early,
and the truncation is indistinguishable from a complete short inbox.

In PDU mode bodies are hex, so no reply line can spell a terminator. Anyone
simplifying back to text mode reintroduces a listing that a sender can
truncate by choosing the right message text.

## One branch, removed 2026-08-06

`deleteSelectedSMS()` used to split on whether every message was selected,
sending `action=all` -> `AT+CMGD=1,4` for the whole-inbox case and
`indices=N,N,...` otherwise. It now always sends indices.

**That is a correctness change, not only a simplification.** `+CMGD=1,4` erases
the whole **store**. A message arriving between the page load and the click gets
wiped along with the ones on screen, unread and unseen. Sending the indices
deletes exactly what the user was looking at, which is what "delete all" in a
message list means.

It also deleted a path that had **never once been executed**: the 30 s timeout
on it was extrapolated, the `+CPMS` prefix was added from reading the code, and
the inert-`<index>` assumption below was never exercised. Removing untested code
beats testing code that is not needed.

The cost is N commands instead of one, about 2.5 s for a 117-part store and 5.4 s
for a full one. On a button press, behind a spinner, that is not a real cost.

The old branch relied on this, kept because it is the reason `AT+CMGD=,4` is
wrong if anyone reintroduces it: `<index>` sits OUTSIDE the brackets in
`AT+CMGD=<index>[,<delflag>]`, and the manual states "optional parameters,
unless explicitly stated, need to be provided up to the last entered
parameter". The `1` is inert: "if `<delflag>` is presented and not set to 0, ME
ignores `<index>`". The manual's own delete-all example is `AT+CMGD=1,4`.

Untick one message out of a full inbox and you get roughly every slot in the
store in one request. That is the case that broke originally.

## The three caps

A delete line WAS bounded by three separate limits from three different places.
Since 2026-08-06 only the third still applies, because nothing is chained. The
other two are kept here because they explain the original bug.

| Cap | Value | Whose | What exceeding it looks like |
|---|---|---|---|
| Command line length | 512 chars | **ours** (`atcmd-daemon` `CMD_MAX`) | total silence, empty reply |
| Something at ~80 commands | see caveat below | the modem | normal `ERROR` reply |
| Response time per `+CMGD` | 300 ms | the modem (documented) | timeout, partial delete |

Measured with `tests/device/device-test-atcaps.sh` and its predecessor:

```
+CGMM  79 commands / 475 chars -> OK
+CGMM  80 commands / 481 chars -> ERROR      (line was read, then refused)
+CMGD  51 commands / 511 chars -> +CMS ERROR (line was read)
+CMGD  52 commands / 521 chars -> silence    (line never reached the modem)
```

The two caps are independent, which is why neither number explains the other.
80 `+CGMM` is only 481 chars, under `CMD_MAX`, so that line cleared our daemon
and the ERROR came back from the modem. 52 `+CMGD` is only 52 commands, far
under 80, and still vanishes: that is our daemon's `CMD_MAX`.

**Caveat on the ~80 boundary: the limiting variable is NOT established.**
Treat it as "somewhere near 80 repeated commands the modem says ERROR", not as
a command count cap.

- It rests on **one unreplicated observation**. The bisect confirmed 60, 70,
  75, 77, 78 and 79 all answer OK, but it inherited `hi=80` from a single
  earlier sweep and never retested it.
- **Command count and response volume are confounded.** 80 `+CGMM` is also
  ~80 model-number lines, roughly 1600 chars of response. A cap on response
  size fits the data exactly as well as a cap on command count. The `+CMGD`
  series cannot break the tie: those chains abort at the first command, so the
  response stays tiny however long the line is.

To separate them, repeat a command with a much shorter response (`AT+CMEE?`
answers about 9 chars against `+CGMM`'s ~20) and find its boundary. Same count
means the cap counts commands. A roughly doubled count means it counts
response bytes. Neither outcome threatens a single-slot line, which answers in
one line, so this was left unresolved on purpose.

**The 512 cap is ours, not the modem's.** `tests/device/device-test-atclid.sh:234`
has said so all along: "a command past CMD_MAX (512) is refused by the daemon,
and atcli sends it happily." The daemon drops the command locally and answers
nothing. The modem never sees it and is not at fault.

The authority is the atcli repo, `src/daemon.rs`:

The daemon defines `CMD_MAX` as 512 bytes near line 35. Near line 941 it
rejects commands that are empty or longer than that limit.

**Enforcement lives in atcli, not here.** The client refuses an over-`CMD_MAX`
command before it connects, exits `65`, and names the byte count on stderr.
`at-lib.sh` translates that status into an `ERROR` line in the body, because
atcli's stderr is discarded by its `2>/dev/null` and a page can only see the
body. QuecDeck deliberately does not keep its own copy of `512`, so the limit
has one home. If the exit code here ever drifts from atcli's, the cost is only
the body line going missing, leaving the generic "no response from the modem".

Two properties of that check are worth knowing, since both were once wrong
here: the test is `>`, so exactly 512 is still sent. And `cmd.len()` is
**bytes**, measured after `flatten_framing`, which substitutes tab, newline
and CR one-for-one and so never changes the length.

**512 is nowhere motivated**, in either repo. Every mention states the value or
its consequence, and the number originates in a test comment. `REQUEST_MAX`
(1024) bounds the whole request line and sits above `CMD_MAX`, so it is not
reachable through `at-lib.sh`.

The `~80` cap below is **not** atcli's: its only response-side limit is
`LINE_MAX` (4096) and that is per line, far above these replies.

The 300 ms figure is the manual's stated maximum response time for `+CMGD`.
It is a budget, not a measurement: 10 slots is worst case 3 s inside the CGI's
10 s allowance, where 120 chained would have been up to 36 s.

## Chunking: removed 2026-08-06

`delete_sms` no longer chains. It sends **one `+CMGD` per line**, about 30
characters, so two of the three caps above cannot bind at all: `CMD_MAX` is 512
and the modem's limit is near 80 commands. Only the 300 ms per `+CMGD` still
applies, and it applies per command rather than per line.

It chained until now because batching looked obviously cheaper. Measured, it
is not: **21 ms per slot chained against 20 ms for a single slot**. The flash
write dominates so completely that batching the round trips buys nothing.

What chaining did buy was a chunk size to tune, abort-at-first-error semantics,
a retry loop, and a race in that retry (below). Removing it took
`delete_sms_indices` from 78 lines to 46 and deleted about ten tests whose
subject no longer exists.

The failure count also became exact rather than inferred: each slot answers for
itself, so nothing has to be deduced from where a chain stopped.

### The race that went with it

While a chain was retried slot by slot, it re-sent `+CMGD=` for slots the chain
had **already emptied**. `CNMI=2,1` means arriving messages are stored, and the
modem reuses the lowest free index, so a message arriving in that window could
land in a just-freed slot and be deleted unread. Per-slot there is no retry, so
the window does not exist.

### What is left: the think-time race

Deleting by index is inherently racy over the user's think-time, and this is
NOT fixed by anything above. `get_sms` lists indices. The user reads the page,
decides, and clicks minutes later. If a message was deleted elsewhere and a new
one arrived into that slot, the delete removes the new message.

Nothing at the AT layer distinguishes a reused slot from the original: `+CMGD=?`
reports occupancy, not identity. Mitigations all still race (re-list and
intersect narrows the window. `+CMGR` before each delete doubles the traffic and
still races), so this is documented rather than defended against.

A chained AT line **stops dead at its first error**, so slots after a bad one
are never attempted. This was confirmed non-destructively with
`AT+CMGD=<unused>;+CGMM`. The batch
returns `+CMS ERROR: 321` (invalid memory index) with no `+CGMM` output
following. A failed chunk is therefore retried one slot at a time, which
salvages the rest.

### 321 on a retry is a success, not a failure

The slots *before* the one that aborted the chain **were deleted**. Retrying the
whole chunk therefore re-issues `+CMGD=` for slots that are now empty, and an
empty slot answers `+CMS ERROR: 321`, the same code a slot that never held a
message gives. Counting that as failure reports the chain's own successes as
failures: a chunk of 10 with a stale 5th slot deletes 9 of them and then claims
5 failed, which opens the error modal on what was very nearly a clean run.

So the retry treats 321 as done. `$failed` means **"still holds a message"**,
which is the only reading that is actionable. The visible consequence is that
deleting a slot the listing no longer matches is no longer an error, and that is
correct: the message is gone either way.

This is not reachable with a stub that answers `OK` to any well-formed line. The
suite's stub models the store, remembering what it deleted and aborting at the
first bad slot. The earlier wire-level stub could not represent deleting the same
slot twice, so it could not see this.

### The one that still binds: a 45 s wall-clock budget

The caps above bound one *line*. Nothing bounded the *request*, and per-command
timeouts do not compose. A fault that is global rather than per-slot (daemon
restarting, store busy) fails every command in turn, so a 128-slot store at a
2 s timeout each would hold the serialized AT port for over four minutes, and
every other page fails for the duration.

`delete_sms` therefore takes a deadline at entry and checks it before each
slot. **45 s** clears a healthy full store even at the manual's 300 ms ceiling
(128 x 300 ms = 38 s), against the 2.5 s it actually takes. Slots left
unattempted when it expires are counted as failed and reported, not silently
dropped.

A slot is started only if its **own timeout** still fits in what is left, not
merely if the deadline has not passed. Testing the deadline alone lets a command
start just inside it and then run its full timeout past it. `budget` and
`slot_tmo` are named constants so the amount reserved cannot drift from the
amount passed to `atcmd_run`.

The budget is a backstop for the pathological case, not a tuning knob: if a
healthy delete ever approaches it, the per-command timeout is the wrong thing,
not the budget.

## Failure semantics

Every layer now states failure instead of implying it by silence:

- `at-lib.sh` refuses an over-length command before the socket write, printing
  `ERROR:` to **stdout** (so `at_result`, `at_response_ok` and the CGI
  "error goes in the body" convention surface it) and to **stderr** (so it
  reaches the web server log). Exit code 65, distinct from atcli's own
  statuses.
- `delete_sms` returns `OK`, or `ERROR: N of M message parts could not be
  deleted`. Note it counts **parts**, so the number can exceed what the user
  thinks of as messages, and it counts only parts that still hold a message
  (see "321 on a retry" above).
- Exhausting the 45 s budget below reports `ERROR: hit the 45s time budget with
  N of M message parts left` instead, so a run cut short is distinguishable from
  one where individual slots were refused. It says "budget" rather than a
  measured elapsed time on purpose: the run stops at or before 45 s, but it does
  not necessarily use all of it.
- `js/sms.js` uses `postForm`, which rejects on `ERROR` in the body, and opens
  the error modal.

## The bug, and the diagnosis that was wrong twice

Symptom: select all, untick a few, delete. Nothing was deleted and nothing was
reported. Deleting one or two short messages always worked.

Cause: about 120 slots became a single ~1200-char AT line. That is past
`CMD_MAX`, so **our own daemon dropped it** before the modem saw it, returning
an empty reply. `delete_sms` passed the empty reply through, and `js/sms.js`
discarded the response in `.finally()`. A total failure and a success were
byte-for-byte indistinguishable in the UI.

Two diagnoses were wrong along the way, both recorded here because the wrong
version is the intuitive one:

1. **"The storage selection is wrong."** Plausible, but a single-message delete
   would have failed too, and it did not. Ruled out by one user observation.
2. **"The modem's input buffer overruns, and the modem violates V.250 by
   answering nothing."** Wrong on both halves. The 512 cap is our daemon's,
   documented in our own test suite, and the modem is not involved in that
   failure at all, so it violates nothing. The measurement was right. The
   attribution was not. Every probe ran through `atcli` -> daemon -> modem,
   and nothing in the first round of testing controlled for the two nearer
   layers.

The lesson worth keeping: when a probe crosses layers you own, a limit found
at the far end is not evidence about the far end.

Diagnostics that existed the whole time and nobody read: the daemon counts
every refusal in its `malformed` counter, visible via `atcli --status`, and
logs the first of them (rate limited). Nothing in QuecDeck surfaces either.

That counter is also the only direct evidence of the original failure. The
diagnosis above is otherwise built from probes run after the fact. The counter
recorded the real delete attempts as they were rejected, which is what ties the
reported symptom to CMD_MAX rather than to the modem.

**That counter stops being the acceptance test once the new atcli lands.** The
client refuses an over-length command before connecting, so the daemon never
sees it and `malformed` never moves. Watching it would then pass even if the
chunking broke again, which is a false pass and worse than no test at all. It
remains the right thing to read for the historical record, and for anything
that reaches the daemon by another route.

What to check after the fix, in order of strength:

1. The UI shows no error and the selected messages are actually gone.
2. The web server error log carries no `ERROR: AT command too long` line.
   `at-lib.sh` writes that to stderr precisely so a refusal leaves a trace: the
   `2>/dev/null` on atcli discards its stderr, and the daemon's counter no
   longer moves, so this line is the only device-side evidence there is.
3. `atcli --status` counters: `timeouts` and `malformed` both unchanged. These
   no longer catch an over-length command, but they do catch the failures that
   would look similar from the UI.

## Testing

Deletes write to NVM and destroy the only realistic fixture, so prefer the
non-destructive probes. Both take care to address only slots **above** the
capacity `AT+CPMS?` reports, where no message can exist.

```
adb push tests/device/device-test-smsdelete.sh /tmp/
adb shell /tmp/device-test-smsdelete.sh     # storage, abort-on-error, timing
adb push tests/device/device-test-atcaps.sh /tmp/
adb shell /tmp/device-test-atcaps.sh        # CMD_MAX drift, what the ~80 counts
```

Delete both from the device afterwards.

`at-lib.sh`'s exit-code mapping has a host test that stubs `atcli` via the
`_ATCLI` override, so it needs no device. That stub returns 65 because the
test says so, which does not prove atcli returns it: only the atcli repo's own
`host-test-atclid.sh` closes that gap. `js/sms.js` cannot be executed on the
dev machine (no JS runtime). Verify it by diff review.

**Real delete wall time, measured 2026-08-05.** One occupied slot was deleted
deliberately to settle it (store went 128 used to 127, confirmed):

| | |
|---|---|
| Empty slot, errors 321, no flash write (20 samples) | **3 ms** |
| **Occupied slot, real delete** | **20 ms** |

So a live `+CMGD` costs about 20 ms, of which 3 ms is the round trip and the
rest the flash write. That is **15x under the manual's 300 ms**.

The timeouts are still sized on the manual's figure rather than this one: 300 ms
is the vendor's worst case over flash conditions a single sample cannot
reproduce, and a cold CPU clock runs ~3.5x slower (see
`tools/device-costs.md`). Current values are `budget=45` and `slot_tmo=2`,
which clear a full 128-slot store even at the manual's ceiling
(128 x 300 ms = 38 s) while capping a stuck request at 45 s. Before any of this
was measured they were 90 s with a 10 s per-chunk and 5 s per-slot timeout,
i.e. 250x the measured cost of a single slot.

**Chained deletes scale linearly, measured 2026-08-06.** Ten occupied slots on
one line cost **210 ms**, i.e. 21 ms per slot against the 20 ms a single slot
costs, and the store dropped by exactly ten so the chain executed all of them.
Per-slot cost does not change with chain length, which is what settled that
chaining was not worth its machinery.

That also settles the margins. A full 128-slot store is 2.5 s against a 45 s
budget, or 38 s at the manual's ceiling. The current values hold.

**Verified end to end, 2026-08-06:** the chunking loop, the chain aborting at
its first bad slot, the retry-one-at-a-time path, and 321-as-done, all driven
through the live CGI over HTTPS against ten EMPTY slots (a no-op that still
exercises every branch: chain aborts, all ten retried singly, all answer 321,
response is `OK`). Validation was checked the same way, including a
`1;+CMGD=5` injection attempt.

### Still unmeasured: `AT+CMGD=1,4`

Delete-all has never been run. It carries a **10 s timeout** in `delete_sms`,
and if erasing a full store exceeds that, `at_result` reports "no response from
the modem" while the modem carries on erasing: the user sees an error on the
most visible button, refreshes, and finds the inbox empty anyway.

Linear scaling predicts ~2.7 s for 128 parts, comfortably inside 10 s. But
delete-all may be a different NVM operation entirely (a bulk erase, or block by
block with garbage collection), so the extrapolation is not evidence.

Measuring it costs the whole inbox, so **do it the next time you actually want
to clear the store** rather than spending the fixture deliberately. Run this
instead of pressing the button:

```sh
# On device, as root. Erases EVERY message.
. /usrdata/quecdeck/script/at-lib.sh
now_cs() {
    read -r u _ < /proc/uptime
    echo "${u%.*}${u#*.}"
}
atcmd_run 'AT+CPMS="ME","ME","ME"' 3000        # note <used> before
t0=$(now_cs)
reply=$(atcmd_run 'AT+CMGD=1,4' 30000)
t1=$(now_cs)
echo "delete-all: $(( (t1 - t0) * 10 )) ms, reply: $reply"
```

Note the 30 s timeout there, deliberately larger than the CGI's 10 s: the point
is to learn the real cost, not to reproduce the cap. If it comes back above
about 8 s, `delete_sms`'s `AT+CMGD=1,4` timeout needs raising and the figure
belongs in `tools/device-costs.md`.

## References

- Quectel RG520N/RG525F/RG5x0F/RM5x0N/RM521F Series AT Commands Manual v1.0,
  section 8.5 `AT+CMGD` (syntax, `<delflag>`, 300 ms), section 1.3 (semicolon
  concatenation, optional-parameter rule), section 13.6 (`+CMS ERROR: 321` is
  "Invalid memory index"). The manual states **no** maximum command line
  length and **no** limit on concatenated commands: both caps above are
  undocumented and were found only by measurement.
- 3GPP TS 27.005: `+CMGD` and `<delflag>` semantics.
- ITU-T V.250: semicolon concatenation, and the rule that exceeding the
  accepted character count "shall" produce ERROR. Not applicable to the 512
  cap, which never reaches the DCE.
- `tests/device/device-test-atclid.sh` for daemon behavior, `CMD_MAX`, and the
  `malformed` counter.
- `tools/device-costs.md` for what an AT batch, a fork and a CGI request
  actually cost on this hardware, and for how to measure without the CPU
  governor making a burst look three times faster than reality.
