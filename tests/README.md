# Tests

Tests are grouped by the environment they require:

- `host/` contains pure, mocked, and repository-integrity tests. From the
  repository root, run `bash tests/host/run-tests.sh`; pass `--slow`
  for timing-dependent cases. CI also runs `ci-checks.sh` and the Linux-only
  `host-test-authlua.sh` integration harness.
- `device/` contains tests that must run on a Quectel modem. Read each script's
  header before use: some are disruptive, some require a configured device,
  and several deliberately restart services or cellular connectivity. Copy an
  individual script to the device and run it as documented.

`device-test-dns-proxy-settings.sh` is read-only. Onboard DNS proxy changes do
not become active until the modem has rebooted, so configure and reboot first,
then run it with `--require-enabled` to inspect the resulting addresses,
listeners, resolver, and firewall hooks. It intentionally does not automate a
setting change or reboot.

Operational monitors, diagnostics, performance probes, and release notes remain
in `tools/`; they are not part of the pass/fail test suites.
