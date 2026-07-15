# Release gate: on-device updater checklist

Run this on the RM520N-GL before tagging any release that touches
`update_quecdeck.sh`, `run_update.sh`, `get_update_log`, `auth_login`, or the
health-probe/service-restart behavior. The web UI cannot test working-tree
updater code (it fetches `update_quecdeck.sh` fresh from a release tag), so the
gate runs the working-tree file directly:

```
adb push update_quecdeck.sh /tmp/test_update.sh
adb shell
```

**Automation:** `tools/device-test-updategate.sh` runs steps 1-5 (plus the
downgrade-block half of the guard) unattended and asserts every outcome,
including landing the SIGTERM inside the swap window for step 5:

```
adb push update_quecdeck.sh /tmp/test_update.sh
adb push tools/device-test-updategate.sh /tmp/
adb shell sh /tmp/device-test-updategate.sh <current> [<older>]
```

Still manual after a script pass: the browser checks in step 4 (login,
session survival, update-page ack), the downgrade OVERRIDE in step 6 (not
automated on purpose -- it parks the device on an older release mid-run), and
step 7. Use the manual steps below when the script is unavailable or when
diagnosing a script failure.

**Pushing working-tree scripts over installed ones** (e.g. testing a changed
`run_update.sh` via the real web path): `adb push` drops ownership and mode,
leaving the file `rw-rw-rw- root` -- sudo then fails with a generic error
before the script runs, and a world-writable sudoers-listed root script is a
privilege-escalation hole for as long as it sits there. Always follow the
push with:

```
adb shell "chown root:root <path> && chmod 700 <path>"
```

Conventions below: `<current>` is the tag matching the installed version
(`cat /usrdata/quecdeck/version`), `<older>` is any earlier published tag.
Run the steps in the order given: the non-mutating checks come first, and the
device ends the session on `<current>`.

Between runs, reset state so the next test starts clean:

```
systemctl reset-failed install_quecdeck 2>/dev/null
rm -f /tmp/quecdeck_update.status
```

## 1. Health probe, standalone

The post-swap health check hangs entirely off this one request; prove it in
isolation before any test that depends on it.

```
IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g'); IP=${IP:-192.168.225.1}
/opt/bin/wget -q -O /dev/null --no-check-certificate "https://$IP/cgi-bin/auth_login"; echo rc=$?
```

- [ ] `rc=0` (wget followed the 303 chain to a 200)
- [ ] No new entry in `/tmp/quecdeck/logs/access_events.jsonl` and no lockout
      counter created (the GET branch must be side-effect free)

## 2. Preflight failure path (nonexistent tag)

```
bash /tmp/test_update.sh v9.9.9
```

- [ ] FATAL: could not download release files; nothing staged, site untouched
- [ ] `cat /tmp/quecdeck_update.status` is `failed`
- [ ] `/usrdata/quecdeck_last_update.log` exists, `root` owner, mode `600`,
      content matches `/tmp/install_quecdeck.log`
- [ ] `mount | grep ' / '` shows `ro`

## 3. Downgrade guard blocks

```
bash /tmp/test_update.sh <older>
```

- [ ] FATAL names both versions and the `QUECDECK_ALLOW_DOWNGRADE=1` override
- [ ] Status `failed`; no `.new`/`.old` dirs under /usrdata; site still serving
- [ ] `/` back to `ro`

## 4. Happy-path reinstall (equal version passes the guard)

```
bash /tmp/test_update.sh <current>
```

- [ ] Guard allows the equal version (no FATAL)
- [ ] Checksum verify: `All checksums verified OK.`
- [ ] Content-only run takes the stays-up branch: log shows
      `Verifying CGIs respond on <ip>...` then
      `lighttpd stayed up through the swap` (no lighttpd restart)
- [ ] ttyd verifies against the LOCAL manifest: log has NO
      "download checksums" step between the ttyd.bash/ttyd.service fetches
- [ ] Summary: Stage/Switch/QuecDeck/Firewall/ttyd all OK; no Rollback line
- [ ] Status `done`; `/usrdata/quecdeck/version` correct (no leading `v`)
- [ ] Manifest retained: `/usrdata/quecdeck/checksums.sha256` present
- [ ] Persisted log updated (mtime) and matches this run
- [ ] Browser: login works, dashboard AT data populates, session survived
- [ ] Update page: shows the terminal state, ack clears it

## 5. TERM mid-swap (trap rollback -- the path that otherwise never runs)

Two shells (or `tail -f` in one, trigger from a second):

```
# shell A
tail -f /tmp/install_quecdeck.log
# shell B
bash /tmp/test_update.sh <current> &
# the moment shell A prints "Preparing for swap...":
systemctl stop install_quecdeck
```

The swap window is seconds wide; if the stop lands too early (before
"Preparing for swap"), expect a plain `failed` with the site untouched --
reset and retry until the stop lands inside the swap.

- [ ] Log: `Install interrupted mid-swap; attempting rollback.` followed by
      `Rollback complete. Previous version restored.`
- [ ] Status `failed:rollback_ok`
- [ ] Site serving, version unchanged, `systemctl is-active lighttpd
      atcmd-daemon firewall` all active
- [ ] `/` back to `ro`; no `.new`/`.old` leftovers under /usrdata

## 6. Downgrade override, then return to current

```
QUECDECK_ALLOW_DOWNGRADE=1 bash /tmp/test_update.sh <older>
```

- [ ] `grep Environment /run/systemd/system/install_quecdeck.service` shows the
      var while the unit exists; install proceeds past the guard
- [ ] Lands on `<older>` (version file, login page works)

Then re-run step 4 with `<current>` to restore, and confirm it lands.

- [ ] Back on `<current>`, status `done`

## 7. Web-path smoke test (after tagging only)

The steps above all drive the console/bootstrap path. After the release is
tagged, run one real update from the previous release via the web UI (this is
the only way `run_update.sh` + `trigger_update` + the UI polling exercise the
new tag):

- [ ] Update page: log streams, terminal state shown, ack clears
- [ ] If updating FROM a release that already ships the version-aware
      update.js: done screen reflects the new version without a manual check

## Recording

Note the tag tested, date, and any deviations in the update-system memory /
release notes. A step that cannot be run (e.g. no older tag available) must be
listed as skipped, not silently passed.
