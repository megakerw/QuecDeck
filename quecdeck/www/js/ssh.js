function sshController() {
  return {
    busy: false,
    saveMessage: '',
    saveTimer: null,
    loaded: false,
    sshInstalled: false,
    sshEnabled: false,
    savedSshEnabled: false,
    sshActive: false,
    sshVersion: '',
    sshPort: 22,
    savedSshPort: 22,
    sshSettingsReady: true,
    developerConfigured: false,
    rootHomeReady: true,
    keys: [],
    publicKey: '',
    keyError: '',

    // Device-owned operation state survives the firewall restart.
    sshdAction: '',
    sshdRunning: false,
    sshdOutcome: '',
    sshdCode: 0,
    sshdStep: '',
    sshdLog: '',
    sshdOperationId: '',
    sshdOperationMonitor: null,
    sshdReconnecting: false,
    sshdFinishTimer: null,
    sshdDoneTimer: null,
    sshdInstallPort: 22,
    updateChecked: false,
    updateAvailable: false,
    updateVersion: '',
    updateCheckedAt: 0,
    credentialOpen: false,
    credentialTitle: '',
    credentialMessage: '',
    credentialDetail: '',
    credentialDetailList: [],
    credentialAction: 'Confirm',
    credentialDeveloper: '',
    credentialError: '',
    credentialBusy: false,
    credentialLocked: false,
    credentialSubmit: null,

    // Unsaved form state must not change the reported server status.
    get sshBadge() {
      if (this.serverView === 'loading') return serviceBadge(undefined);
      if (this.serverView === 'removing') return { label: 'Removing', cls: 'text-bg-primary' };
      if (this.serverView !== 'manage') return serviceBadge(null);
      if (!this.sshActive && this.sshSettingsReady && !this.savedSshEnabled) {
        return { label: 'Disabled', cls: 'text-bg-secondary' };
      }
      return serviceBadge(this.sshActive);
    },

    get keysStandDown() {
      if (!this.loaded) {
        return { badge: 'Checking', message: 'Waiting for the SSH server status.' };
      }
      if (this.sshdRunning) {
        return { badge: 'Locked', message: 'Key management is unavailable while the SSH server is being changed.' };
      }
      return {
        badge: 'Unavailable',
        message: 'Public keys are the only SSH login method. This becomes available once the SSH server is installed.',
      };
    },

    get sshSettingsChanged() {
      return this.sshEnabled !== this.savedSshEnabled || Number(this.sshPort) !== this.savedSshPort;
    },

    get sshdRemovalInProgress() {
      return this.sshdRunning && this.sshdAction === 'uninstall';
    },

    get sshdRemovalComplete() {
      return !this.sshdRunning && this.sshdOutcome === 'done' &&
        this.sshdAction === 'uninstall';
    },

    // Removal state leads because the security refresh completes later.
    get serverView() {
      if (!this.loaded) return 'loading';
      if (this.sshdRemovalInProgress) return 'removing';
      if (this.sshdRemovalComplete) return 'removed';
      return this.sshInstalled ? 'manage' : 'install';
    },

    get sshdRemovalView() {
      return this.serverView === 'removing' || this.serverView === 'removed';
    },

    get keysManageable() {
      return this.serverView === 'manage' && !this.sshdRunning;
    },

    get sshdProgressVisible() {
      return this.sshdRunning && this.sshdAction !== 'check';
    },

    get sshdStepVisible() {
      return this.sshdProgressVisible && !!this.sshdStep && !this.sshdReconnecting;
    },

    get enableHint() {
      if (this.sshEnabled !== this.savedSshEnabled) {
        return {
          cls: 'text-muted',
          text: this.sshEnabled
            ? 'SSH will be enabled after you save settings.'
            : 'SSH will be disabled after you save settings.',
        };
      }
      if (!this.sshEnabled) return { cls: 'text-muted', text: 'Currently disabled.' };
      if (this.sshActive) {
        return {
          cls: 'text-muted',
          text: 'Accepting key-only connections on the configured port. Changing the port or disabling SSH ends active sessions.',
        };
      }
      return {
        cls: 'text-warning',
        text: this.keys.length === 0
          ? 'Enabled, but waiting for an authorized key before the server can start.'
          : 'Enabled with a key, but the server is not running. Check the server status before connecting.',
      };
    },

    flashSaved(message) {
      this.saveMessage = message;
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => { this.saveMessage = ''; }, 4000);
    },

    loadSecurity() {
      return fetchJSON('/cgi-bin/get_security')
        .then((data) => {
          if (data.ok === false) throw new Error(data.error || 'SSH security status could not be read.');
          this.sshInstalled = data.ssh_installed === true;
          this.sshEnabled = data.ssh_enabled === true;
          this.savedSshEnabled = this.sshEnabled;
          this.sshActive = data.ssh_active === true;
          this.sshVersion = typeof data.ssh_version === 'string' ? data.ssh_version : '';
          this.sshPort = Number.isInteger(data.ssh_port) ? data.ssh_port : 22;
          this.savedSshPort = this.sshPort;
          this.sshSettingsReady = data.ssh_settings_ready !== false;
          this.developerConfigured = data.developer_configured === true;
          this.rootHomeReady = data.root_home_ready !== false;
          this.keys = Array.isArray(data.keys) ? data.keys : [];
          this.loaded = true;
        })
        .catch((err) => {
          if (isSessionExpired(err)) return;
          this.$store.errorModal.open(err.message || 'Failed to load security settings.');
        });
    },

    // Reset the picker so selecting the same file fires another change event.
    readKeyFile(event) {
      const input = event.target;
      const file = input.files && input.files[0];
      if (!file) return;
      if (file.size > 8192) {
        input.value = '';
        this.$store.errorModal.open('The public key file is too large.');
        return;
      }
      file.text().then((text) => {
        this.publicKey = text.trim();
        this.validateKey();
      }).catch(() => {
        this.$store.errorModal.open('The public key file could not be read.');
      }).finally(() => {
        input.value = '';
      });
    },

    // The root helper owns full key parsing and duplicate detection.
    validateKey() {
      const line = this.publicKey.trim();
      this.keyError = '';
      if (!line) return;
      if (line.length > 8192) {
        this.keyError = 'That key is longer than 8192 characters.';
        return;
      }
      if (/BEGIN [A-Z0-9 ]*PRIVATE KEY/.test(line)) {
        this.keyError = 'That is a private key. Paste the matching .pub file instead.';
        return;
      }
      // PuTTYgen can export this container format from "Save public key".
      if (/BEGIN SSH2 PUBLIC KEY/.test(line)) {
        this.keyError = 'This file uses SSH2 public-key format. Export it in OpenSSH authorized_keys format, then paste the resulting single line.';
      }
    },

    get keyReady() {
      return this.publicKey.trim() !== '' && !this.keyError;
    },

    keyAlgorithm(type) {
      if (!type) return 'KEY';
      if (type.startsWith('ecdsa-')) return 'ECDSA';
      return type.replace(/^ssh-/, '').toUpperCase();
    },

    keyTitle(key) {
      return key.comment || 'No comment';
    },

    closeCredentials() {
      if (this.credentialBusy) return;
      // Chromium may offer to save a password when a filled field disappears.
      const el = document.getElementById('cred-dev');
      if (el) el.value = '';
      this.credentialDeveloper = '';
      this.credentialOpen = false;
      this.credentialError = '';
      this.credentialLocked = false;
      this.credentialSubmit = null;
      this.credentialDetailList = [];
    },

    submitCredentials() {
      if (this.credentialBusy || this.credentialLocked) return;
      if (!this.credentialDeveloper) {
        this.credentialError = 'Enter your developer password.';
        return;
      }
      this.credentialBusy = true;
      this.credentialError = '';
      Promise.resolve(this.credentialSubmit(this.credentialDeveloper))
        .then(() => {
          this.credentialBusy = false;
          this.closeCredentials();
        })
        .catch((err) => {
          this.credentialError = err.message || 'The change could not be completed.';
          this.credentialLocked = err.locked === true;
          this.credentialBusy = false;
        });
    },

    promptCredentials({ title, message, detail, detailList, action, refreshOnSuccess = true, run, onSuccess }) {
      this.credentialTitle = title;
      this.credentialMessage = message;
      this.credentialDetail = detail || '';
      this.credentialDetailList = detailList || [];
      this.credentialAction = action;
      this.credentialDeveloper = '';
      this.credentialError = '';
      this.credentialBusy = false;
      this.credentialLocked = false;
      this.credentialSubmit = (developer) =>
        run(developer).then((data) => {
          if (!data.ok) {
            const err = new Error(data.error || 'The change could not be completed.');
            err.locked = /Too many failed attempts/i.test(data.error || '');
            throw err;
          }
          if (onSuccess) onSuccess();
          if (!refreshOnSuccess) return;
          return this.loadSecurity().then(() => {
            if (data.warning === 'ssh_key_activation') {
              this.$store.errorModal.open('The key was saved, but SSH could not be activated and remains stopped.');
            }
          });
        });
      this.credentialOpen = true;
      setTimeout(() => document.getElementById('cred-dev')?.focus(), 0);
    },

    keyActionBlocked() {
      if (!this.rootHomeReady) {
        this.$store.errorModal.open('The root home permissions are incompatible. Re-run the QuecDeck installer.');
        return true;
      }
      if (!this.developerConfigured) {
        this.$store.errorModal.open('Set a developer password on the Security page before managing SSH keys.');
        return true;
      }
      return false;
    },

    addKey() {
      const publicKey = this.publicKey.trim();
      if (this.keyActionBlocked()) return;
      if (!publicKey) {
        this.$store.errorModal.open('Paste a public key, or choose a .pub file.');
        return;
      }
      if (this.keys.length >= 5) {
        this.$store.errorModal.open('The maximum of 5 SSH keys has been reached. Remove one first.');
        return;
      }
      this.promptCredentials({
        title: 'Add this key?',
        message: 'A key grants root access over SSH, so it needs your developer password.',
        detail: publicKey.length > 90 ? publicKey.slice(0, 90) + '…' : publicKey,
        action: 'Add key',
        run: (developer) =>
          postSecurityAction({
            action: 'add_key',
            current_password: developer,
            public_key: publicKey,
          }).then((data) => {
            if (data.ok) {
              this.publicKey = '';
              this.validateKey();
            }
            return data;
          }),
      });
    },

    saveSshSettings() {
      const port = Number(this.sshPort);
      if (!this.sshSettingsReady) {
        this.$store.errorModal.open('The current SSH settings could not be read. Check /opt/etc/ssh/sshd_config before changing them.');
        return;
      }
      if (!this.rootHomeReady) {
        this.$store.errorModal.open('The root home permissions are incompatible. Re-run the QuecDeck installer.');
        return;
      }
      if (!Number.isInteger(port) || (port !== 22 && (port < 1024 || port > 65535))) {
        this.$store.errorModal.open('Use port 22, or a port between 1024 and 65535.');
        return;
      }
      if (this.sshdLifecycleBlocked()) return;
      this.saveMessage = '';
      clearTimeout(this.saveTimer);
      this.promptCredentials({
        title: 'Confirm SSH settings',
        message: 'Every change on this page asks for your developer password.',
        action: 'Save settings',
        run: (developer) => postSecurityAction({
          action: 'ssh_settings',
          current_password: developer,
          ssh_enabled: this.sshEnabled ? '1' : '0',
          ssh_port: String(port),
        }),
        onSuccess: () => this.flashSaved('Saved.'),
      });
    },

    confirmRemove(key) {
      if (this.keyActionBlocked()) return;
      this.promptCredentials({
        title: 'Remove this key?',
        message: 'This public key will stop being accepted for SSH login.',
        detail: key.comment ? key.comment + '  ' + key.fingerprint : key.fingerprint,
        action: 'Remove key',
        run: (developer) =>
          postSecurityAction({
            action: 'remove_key',
            current_password: developer,
            fingerprint: key.fingerprint,
          }),
      });
    },


    // Distinct messages are reserved for failures with distinct remedies.
    sshdFailureMessage() {
      switch (this.sshdCode) {
        case 10: return 'SSH is not installed. Reload the page.';
        case 11: return 'SSH is already installed. Reload the page.';
        case 13: return 'Entware is unavailable or its package metadata is not trusted. Sshd was left stopped. Open the log for the check that declined.';
        case 14: return 'The bundled SSH files failed integrity verification. Update QuecDeck and try again.';
        case 20: return 'SSH was removed, but one or more packages could not be uninstalled. The daemon is stopped and your keys are already deleted. Check opkg before reinstalling.';
        case 21: return 'Another SSH change is already running. Wait for it to finish and try again.';
        case 22: return 'The packages were installed, but sshd could not be started. Check the SSH server panel.';
        case 24: return 'SSH was removed, but the firewall rules could not be reapplied. Check the firewall and the web server.';
        case 25: return 'The SSH server could not be stopped, so the action stopped at that step. Open the log to see how far it got.';
        case 12: case 15: case 16: case 17: case 18: case 19: case 23:
          return 'SSH was left stopped or unchanged. Open the log for the step that declined.';
        default: return 'The SSH action could not be completed.';
      }
    },

    sshdBadgeClass() {
      if (this.sshdRunning) return 'text-bg-primary';
      if (this.sshdOutcome === 'failed') return 'text-bg-danger';
      if (this.updateAvailable) return 'text-bg-warning text-dark';
      if (this.updateChecked) return 'text-bg-success';
      return 'text-bg-secondary';
    },

    sshdBadgeLabel() {
      if (this.sshdRunning) {
        return this.sshdAction === 'check' ? 'Checking'
          : this.sshdAction === 'uninstall' ? 'Removing'
          : this.sshdAction === 'install' ? 'Installing' : 'Updating';
      }
      if (this.sshdOutcome === 'failed') return this.sshdCode === 20 ? 'Removal incomplete' : 'Failed';
      if (this.updateAvailable) return 'Update available';
      if (this.updateChecked) return 'Up to date';
      return 'Not checked';
    },

    // Failures and removals require an explicit dismissal or reload.
    scheduleSshdDismiss() {
      if (this.sshdAction === 'uninstall') return;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = setTimeout(() => {
        if (this.sshdOutcome === 'done') this.resetSshdView();
      }, 6000);
    },

    // Partial removals require a reload because key storage is already gone.
    sshdNeedsReload() {
      return this.sshdOutcome === 'failed' && (this.sshdCode === 20 || this.sshdCode === 24);
    },

    loadSshdCheck() {
      return fetchJSON('/cgi-bin/get_sshd_check')
        .then((data) => {
          this.updateChecked = data.checked === true;
          this.updateAvailable = data.available === true;
          this.updateVersion = typeof data.version === 'string' ? data.version : '';
          this.updateCheckedAt = Number.isInteger(data.checked_at) ? data.checked_at : 0;
        })
        .catch(() => {});
    },

    checkedAtText() {
      if (!this.updateCheckedAt) return '';
      return 'Last checked: ' + new Date(this.updateCheckedAt * 1000).toLocaleString([], { hour12: false });
    },

    beginSshdView(action) {
      // Timers from an earlier operation must not mutate this operation.
      clearTimeout(this.sshdFinishTimer);
      this.sshdFinishTimer = null;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = null;
      this.sshdAction = action;
      this.sshdRunning = true;
      this.sshdOutcome = '';
      this.sshdCode = 0;
      this.sshdStep = 'Starting...';
      this.sshdLog = '';
      this.sshdOperationId = '';
      this.sshdReconnecting = false;
      if (this.sshdOperationMonitor) this.sshdOperationMonitor.stop();
    },

    appendSshdLog(chunk) {
      this.sshdLog += chunk;
      // Only installer step markers are stable enough for the status line.
      const steps = this.sshdLog.split('\n').filter((line) => line.startsWith('==> '));
      if (steps.length) this.sshdStep = steps[steps.length - 1].slice(4);
    },

    ensureSshdOperationMonitor() {
      if (this.sshdOperationMonitor) return;
      this.sshdOperationMonitor = createOperationMonitor({
        intervalMs: 1000,
        onSnapshot: (data, chunk) => this.handleSshdSnapshot(data, chunk),
        onDisconnect: () => { this.sshdReconnecting = true; },
        onReconnect: () => { this.sshdReconnecting = false; },
        onMismatch: () => {
          this.resetSshdView();
          this.loadSshdCheck();
          this.loadSecurity();
        },
      });
    },

    startSshdPolling(initial = null) {
      this.ensureSshdOperationMonitor();
      const expectedAction = this.sshdAction;
      const expectedKind = 'sshd:' + expectedAction;
      this.sshdOperationMonitor.start({
        id: this.sshdOperationId,
        expectedKind,
        initial,
      });
    },

    handleSshdSnapshot(data, chunk) {
      this.appendSshdLog(chunk);
      if (data.status !== 'done' && data.status !== 'failed') return;
      // Keep the final step visible when an action finishes within one poll.
      const finish = () => {
        this.sshdFinishTimer = null;
        this.sshdRunning = false;
        this.sshdOutcome = data.status;
        this.sshdCode = typeof data.code === 'number' ? data.code : 0;
        this.sshdOperationMonitor.acknowledge(this.sshdOperationId);
        this.loadSshdCheck();
        if (!this.sshdNeedsReload()) this.loadSecurity();
        if (data.status === 'done') this.scheduleSshdDismiss();
      };
      this.sshdFinishTimer = setTimeout(finish, 750);
    },

    triggerSshdAction(action, developer) {
      const params = { action };
      if (action === 'install') params.port = this.sshdInstallPort;
      if (developer) params.developer_password = developer;
      this.beginSshdView(action);
      return fetchJSON('/cgi-bin/trigger_sshd_action', {
        method: 'POST',
        body: new URLSearchParams(params),
      })
        .then((data) => {
          if (data.ok) {
            if (!/^[a-f0-9]{32}$/.test(data.operation_id || '')) {
              throw new Error('The SSH action did not return an operation ID.');
            }
            this.sshdOperationId = data.operation_id;
            this.startSshdPolling();
          } else {
            this.resetSshdView();
          }
          return data;
        })
        .catch((err) => {
          this.resetSshdView();
          throw err;
        });
    },

    checkForSshdUpdate() {
      this.triggerSshdAction('check')
        .then((data) => {
          if (!data.ok) this.$store.errorModal.open(data.error || 'The check could not be started.');
        })
        .catch(() => {
          this.$store.errorModal.open('The check could not be started. Check the connection and try again.');
        });
    },

    // SSH installation has no root-home precondition, unlike key management.
    sshdLifecycleBlocked() {
      if (!this.developerConfigured) {
        this.$store.errorModal.open('Set a developer password on the Security page before installing or removing SSH.');
        return true;
      }
      return false;
    },

    promptSshdInstall() {
      if (this.sshdLifecycleBlocked()) return;
      const port = Number(this.sshdInstallPort);
      if (port !== 22 && (!Number.isInteger(port) || port < 1024 || port > 65535)) {
        this.$store.errorModal.open('Use port 22, or a port between 1024 and 65535.');
        return;
      }
      this.promptCredentials({
        title: 'Install SSH server',
        message: 'Installing SSH opens a root login path on this modem, so it needs your developer password.',
        detail: 'Port ' + port + ', key-only, idle until a key is added',
        action: 'Install',
        refreshOnSuccess: false,
        run: (developer) => this.triggerSshdAction('install', developer),
      });
    },

    promptSshdUpdate() {
      if (this.sshdLifecycleBlocked()) return;
      this.promptCredentials({
        title: 'Update SSH server',
        message: 'The SSH server restarts, which ends active SSH sessions. Your port, keys and enabled state are kept.',
        action: 'Update',
        refreshOnSuccess: false,
        run: (developer) => this.triggerSshdAction('update', developer),
      });
    },

    promptSshdUninstall() {
      if (this.sshdLifecycleBlocked()) return;
      this.promptCredentials({
        title: 'Uninstall SSH server',
        message: 'Permanently removes the following:',
        detailList: [
          'The OpenSSH packages and /opt/etc/ssh',
          'The firewall opening on port ' + this.savedSshPort,
          this.keys.length === 1 ? '1 authorized key' : this.keys.length + ' authorized keys',
        ],
        action: 'Uninstall',
        refreshOnSuccess: false,
        run: (developer) => this.triggerSshdAction('uninstall', developer),
      });
    },

    resetSshdView() {
      if (this.sshdOperationMonitor) this.sshdOperationMonitor.stop();
      clearTimeout(this.sshdFinishTimer);
      this.sshdFinishTimer = null;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = null;
      this.sshdAction = '';
      this.sshdRunning = false;
      this.sshdOutcome = '';
      this.sshdCode = 0;
      this.sshdLog = '';
      this.sshdStep = '';
      this.sshdOperationId = '';
      this.sshdReconnecting = false;
    },

    dismissSshdOutcome() {
      this.resetSshdView();
    },

    resumeSshdAction() {
      return fetchJSON('/cgi-bin/get_update_log')
        .then((data) => {
          if (!/^[a-f0-9]{32}$/.test(data.operation_id || '') ||
              !data.kind || data.kind.indexOf('sshd:') !== 0) return;
          const action = data.kind.slice(5);
          if (data.status === 'running') {
            this.beginSshdView(action);
            this.sshdOperationId = data.operation_id;
            this.startSshdPolling(data);
            return;
          }
          if (data.status === 'done' || data.status === 'failed') {
            this.beginSshdView(action);
            this.sshdOperationId = data.operation_id;
            this.startSshdPolling(data);
          }
        })
        .catch(() => {});
    },

    init() {
      this.loadSecurity();
      this.loadSshdCheck();
      this.resumeSshdAction();
    },
  };
}
