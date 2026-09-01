# Tests

Tests are grouped by the environment they require:

- `host/suites/` contains the mocked shell tests grouped by domain. The shared
  assertions and source helpers live in `host/testlib.sh`. From the repository
  root, run `bash tests/host/run-tests.sh` for every suite or name one or more
  suites such as `bash tests/host/run-tests.sh monitoring`. Pass `--slow` for
  timing-dependent cases. The available suites are `libraries`, `sms`,
  `monitoring`, `connection-logger`, `updater`, `security`, `firewall`, and
  `structure`. The SMS suite automatically includes its `libraries`
  prerequisite.
- `host/integration/` contains environment-backed host tests. `host/js/`
  contains JavaScript unit tests. `host/guards/` contains definitions shared
  by the pre-commit hook and CI, while `host/support/` contains test utilities.
- `host/ci-checks.sh` contains repository-integrity checks. CI also runs the
  Linux-only auth.lua integration harness.
- `device/` contains tests that must run on a Quectel modem. Read each script's
  header before use: some are disruptive, some require a configured device,
  and several deliberately restart services or cellular connectivity. Copy an
  individual script to the device and run it as documented. Host tests only
  syntax-check these scripts. They do not claim that a device test ran or that
  its device-side assertions passed. Before a release, record the device tests
  that were actually run and their results.

`device-test-dns-proxy-settings.sh` is read-only. Onboard DNS proxy changes do
not become active until the modem has rebooted, so configure and reboot first,
then run it with `--require-enabled` to inspect the resulting addresses,
listeners, resolver, and firewall hooks. It intentionally does not automate a
setting change or reboot.

`device-test-watchcat-states.sh` covers the properties the host suite can only
assert against source: the not-contacted target sentinel, rotation of the first
ping target, clean disabled exit, pause markers written by the web tier, and
the monitoring sudoers entries. It drives the real `watchcat_maker` CGI to
verify that every explicit Save reloads the worker, an identical disabled Save
terminates a stale enabled process, and rapid identical or changed saves do not
leave the unit start-limited. It sets the failure count to its maximum so no
section can reach a reboot and restores the original configuration by hash.

`device-test-watchcat-scan-pause.sh` is **disruptive**: it runs a real
`AT+QSCAN`, which drops the cellular connection for roughly a minute and can
take up to the CGI's 215s timeout. Do not run it on a modem anyone depends on.
It covers the one property no host test can reach, that a real scan pauses the
running daemon and that the pause survives a settings save restarting the unit
mid-scan, which stopping the unit could not. Targets are real internet
addresses so the scan genuinely makes them fail, and the failure count is its
maximum, putting the reboot threshold at 370s against a 215s worst-case scan.

`device-test-scheduled-startup.sh` briefly stops the AT daemon and restarts
Scheduled Restart with a schedule matching the current minute. With modem
commands safely unavailable, it checks the journal for the startup-minute skip
and confirms no reboot dispatch was attempted, then restores the original
schedule and daemon state.

`device-test-update-monitoring.sh` is a two-phase manual release acceptance
test. Run `prepare`, perform a normal update, then run `verify`. Its observer
checks that neither monitoring worker returns between the release-tree swap and
terminal update status, and verification checks the boot ID, status, exact
configuration hashes, final enabled/disabled states, boot links and read-only
root filesystem. Repeat once with both features enabled and once with both
disabled.

Operational monitors, diagnostics, performance probes, and release notes remain
in `tools/`. They are not part of the pass/fail test suites.
