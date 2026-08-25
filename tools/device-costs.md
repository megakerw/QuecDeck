# What things cost on the device

One place for the measured cost of primitives on the target hardware, so code
comments can cite a number instead of carrying a copy of it. Cite as
`tools/device-costs.md`.

Everything here was measured on the real device, not estimated. If you change a
number, say how you measured it.

**Hardware:** Quectel RM520N (sdxlemur), single-core `armv7l`, bash 3.2.57,
busybox userland. Governor `ondemand`, **345 MHz to 1805 MHz**.

---

## Read this before you measure anything

**Bursts lie by about 3.5x.** Back-to-back requests hold the governor at its
top clock. Anything a user actually triggers at intervals runs at a low clock
and is much slower. `get_dashboard` measured **43 ms** in a burst and **115 ms**
polled every 3 s, same code, same reused connection.

Measure at the real cadence:

```
curl.exe -k -s --rate 20/m -b "session=$TOK" -w '%{time_starttransfer}\n' \
    -o out.bin -d '' https://192.168.225.1/cgi-bin/get_dashboard   # x N
```

**Timings at cadence are noisy. Counters are not.** With n=10 the spread
swallows a ~10 ms difference. For anything about cache hit rate, read the
daemon's own counter instead and compare deltas:

```
adb shell "/usrdata/quecdeck/atcli -s /run/quecdeck-web/atcli.sock --status"
```

**Keep-alive is real** (`server.max-keep-alive-idle = 45`), so a polling page
pays the TLS handshake once, not per request. Confirm with
`%{time_appconnect}` being 0 on requests after the first.

**A/B properly.** Install one version, measure, install the other, measure, in
the same session. Comparing a fresh measurement against a number from earlier in
the day compares CPU states, not code. Get the "before" from git if the file is
otherwise unmodified: `git show HEAD:path > /tmp/old`.

Better still, **alternate rounds** rather than measuring each variant once, so
drift cancels instead of landing on whichever variant you timed second.
`tests/device/device-test-authforkbench.sh` does this properly and is the pattern to
copy for anything marginal.

---

## Primitives

Boosted clock (tight loop, 200 iterations). Multiply by roughly 3.5 for what a
user's first request after an idle period pays.

| Operation | Cost | Notes |
|---|---|---|
| `read -r var < file` (builtin) | **150 us** | one line |
| passing a large string to a function | **~10 ms per 49 KB** | bash copies it. Window instead |
| whole-file read via `read -r -d ''` | **400-450 us** | includes the open |
| `_epoch_now` (two procfs reads) | **800-1000 us** | no fork |
| `var=$(<file)` | **1750-1800 us** | subshell, no exec |
| `mkdir -p` | **3150-3300 us** | fork + exec |
| `chmod` | **3150-3200 us** | fork + exec |
| `date +%s` | **3600 us** | fork + exec |
| `stat -c %Y` | **3700-4100 us** | fork + exec |
| `grep` over a 462-line file, in `$( )` | **7400 us** | subshell + exec + heredoc |
| bash `read` loop | **~82 us per line** | see the threshold below |

### The threshold that decides these calls

**A fork costs about the same as 40 lines of bash line-processing.**

3200 us per fork against ~82 us per line. So replacing a `grep`/`awk` with a
pure-bash scan is a *loss* on anything bigger than a few dozen lines. Measured
directly on `mobileap_read` over the real 462-line `/etc/data/mobileap_cfg.xml`,
all variants returning identical values:

| Variant | Cost |
|---|---|
| `grep` + heredoc (what ships) | **7400 us** |
| pure bash, full scan | 37800 us (5.1x worse) |
| pure bash, stopping at the last tag (~23% of the file) | 11900 us (1.6x worse) |

Every fork removed successfully in this codebase was a single operation on a
handful of lines. Don't generalise the wins to bulk text processing.

---

## Request path

| Layer | Cost | Avoidable? |
|---|---|---|
| Static asset, warm connection | 2.8 ms | - |
| TLS handshake | ~42 ms | once per connection, not per request |
| CGI floor: fork + bash + source `cgi-lib.sh` + Lua auth | **19 ms** | only by leaving bash |
| `atcli` spawn + socket round trip, no AT | 2 ms | - |
| `systemctl is-active` for 7 units | **~24 ms** | already one batched D-Bus call |
| a Lua `os.execute` fork in `auth.lua` | **~3 ms** | removed, see below |

The CGI floor is why fewer requests beats faster requests: see
`get_dashboard`/`get_deviceinfo` bundling several sources into one response.

**Not all forks are a CGI spawn.** Removing `auth.lua`'s per-request
`os.execute` setup check took a keep-alive request from **27.4 ms to 24.2 ms**,
i.e. ~3 ms, where a full CGI spawn is several times that. Measured by
`tests/device/device-test-authforkbench.sh`. Size a fork by what it spawns.

The `systemctl` batching premise (one D-Bus round trip per unit was the cost)
is validated by `tests/device/device-test-system-status.sh`, which also compares
batched against one-call-per-unit.

## AT commands

Via the daemon, boosted clock. The port is serialised, so these are also the
cost every other page pays while one is in flight.

| Batch | Commands | Cost |
|---|---|---|
| `AT+CSQ` | 1 | 2 ms |
| `device_sim` (`+CIMI;+ICCID;+CNUM`) | 3 | 2 ms |
| `modem_conn` (`+QMAP="WWANIP";+CGCONTRDP`) | 2 | 5 ms |
| `modem_stats` (`+QTEMP;+QENG;+QCAINFO;+CSQ;...`) | 9 | **18 ms** |
| `get_sms` full listing (`+CMGL=4`, 128 parts, ~49 KB) | 6 | **127-136 ms** |

Dropping `+CSCA?` and `+CSMP` from the SMS listing chain took it from 136 ms to
127 ms over 12 rounds at the same 128 parts: a query nothing read, and
text-mode send parameters with no send path.

Command count does not predict cost: 3 commands at 2 ms against 2 commands at
5 ms. Which commands you chain matters far more than how many, so trim a
specific expensive query rather than splitting a batch.

### Commands that write flash

| Operation | Cost |
|---|---|
| `+CMGD` on an empty slot (errors 321, no write) | **3 ms** |
| `+CMGD` on an occupied slot (real delete) | **20 ms** |
| 10 occupied slots chained on one line | **210 ms** (21 ms/slot) |

Chained deletes scale **linearly**: 21 ms per slot chained against 20 ms for a
single slot, so batching the round trips buys nothing. QuecDeck therefore does
**not** chain (see `tools/sms-delete-flow.md`). The chained figure is kept
because it is what settled that question. Both are one-shot measurements against
real messages, which is why they were not taken sooner.

The manual's stated maximum for `+CMGD` is **300 ms**, i.e. 15x the observed
cost. Size timeouts on the manual's figure, not this one: it is the vendor's
worst case over flash conditions a single sample cannot reproduce, and a cold
clock is ~3.5x slower. `delete_sms` uses `budget=45 slot_tmo=2` on that basis.

---

## Endpoints, at a real 3 s cadence

The honest numbers. Burst figures for the same endpoints are roughly a third of
these.

| Endpoint | Cost | Note |
|---|---|---|
| `get_dashboard` | **106 ms** | every poll is a cache miss by design, ttl 2 |
| `get_dashboard`, before the cache rework | 115 ms | served a stale tick ~half the time |
| `get_system_status` | **77 ms** | after the builtin swaps |
| `get_system_status`, before | 88 ms | three `cat`/`tr` forks |

`get_dashboard` got faster while doing strictly *more* AT work: the fork
trimming more than paid for honouring the refresh rate.

---

## Cache specifics

Reproduce with `tools/device-perf-cache.sh`. Boosted clock, as everywhere here.

| Operation | Cost |
|---|---|
| `_cache_load` (one open, no fork) | 450 us |
| `cache_read` (load + emit) | 550 us |
| `cache_is_fresh` (load + `_epoch_now` + compare) | 1750 us |
| **`cache_write` (temp + mv)** | **4900 us** |
| `cache_get_or_fetch` HIT | **3900 us** |
| `cache_get_or_fetch` MISS, `modem_stats` | **35500 us** |
| `cache_get_or_fetch` MISS, `modem_conn` | 15500 us |

After the chmod removal, `modem_stats` is 20500 us raw against 35500 us through
the cache, and `modem_conn` is 5000 against 15500. The wrapper adds roughly
10-15 ms to a miss, including validation, time-header work and the atomic write.

**Removing the `chmod` fork cut `cache_write` from 7750 us to 4900 us.** Files
now land `0600` from `cgi-lib.sh`'s `umask 077`. www-data is the only application
consumer and root can still inspect them through its DAC override. `mv` remains
because it is the atomic replace that prevents torn reads.

`cache_is_fresh` reads a centisecond epoch header rather than calling `stat`:
the complete load-and-age check is 1750 us, while `stat -c %Y` alone is 4350 us.

A hit is 3900 us against a 35500 us `modem_stats` miss, so the cache saves
roughly 32 ms per avoided fetch. At ttl 2 against a 3 s poll a single client
avoids none: the saving is for concurrent readers in the same tick.

At a 3 s dashboard cadence with ttl 2, every poll misses: **~24 AT commands per
11 polls**. That is the price of the page refreshing at the rate it claims.
Second-granularity comparison was cheaper (~19) only because its +-1 s error
sometimes served stale data.

---

## Where the measurements live

This file is the index. Domain detail stays in its own document. Don't copy
numbers here that already have a home.

| Harness | Measures |
|---|---|
| `tools/device-perf-atcli.sh` | atcli client exec and round-trip time, per binary |
| `tests/device/device-test-authforkbench.sh` | auth.lua fork removal, alternating-round A/B |
| `tests/device/device-test-system-status.sh` | systemctl batching, positional mapping, mobileap parsers |
| `tests/device/device-test-atcaps.sh` | `CMD_MAX` drift and the ~80-command modem cap |
| `tests/device/device-test-atclid.sh` | daemon, socket, privilege drop, resync window |
| `tests/device/device-test-smsdelete.sh` | SMS storage and abort-on-error, non-destructive |
| `tools/sms-delete-flow.md` | the three caps bounding an AT line, and the 300 ms/`+CMGD` budget |

Host suite, no device needed: `tests/host/run-tests.sh`.

## Reproducing

Device scripts: copy to `/tmp`, run as root, delete afterwards.

Ad-hoc timing loops use `/proc/uptime` for a fork-free clock. BusyBox `date`
has no `%N`, so resolution is 10 ms and anything short must be timed over
N iterations and divided:

```sh
now_cs() {
    read -r u _ < /proc/uptime
    echo "${u%.*}${u#*.}"
}
t0=$(now_cs)
i=0
while [ "$i" -lt 200 ]; do
    thing_under_test >/dev/null 2>&1
    i=$((i + 1))
done
t1=$(now_cs)
echo "$(( (t1 - t0) * 10 * 1000 / 200 )) us each"
```

Check correctness before timing: a faster variant that returns different values
is not a candidate, and two of the variants compared above were rejected that
way before their timings mattered.
