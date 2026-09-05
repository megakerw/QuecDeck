function securityController(sshPage = false) {
  return {
    busy: false,
    // Which action is in flight. busy alone disables every button, so the label
    // must key on this or an idle form claims to be working too.
    busyAction: '',
    // Transient confirmation, cleared on the next attempt and after a few
    // seconds. Same shape as watchcat's response field.
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
    currentPassword: '',
    newPassword: '',
    confirmPassword: '',
    currentDeveloperPassword: '',
    newDeveloperPassword: '',
    confirmDeveloperPassword: '',
    publicKey: '',
    keyError: '',

    // SSH component lifecycle. Progress is read from the shared update log, so
    // a reload during the firewall restart re-enters the running view rather
    // than losing it, and the view is reproducible from the device alone.
    sshdAction: '',
    sshdRunning: false,
    sshdOutcome: '',
    sshdCode: 0,
    sshdStep: '',
    sshdLog: '',
    sshdLogOffset: 0,
    sshdDecoder: null,
    sshdReconnecting: false,
    sshdPollTimer: null,
    sshdDoneTimer: null,
    sshdFetching: false,
    sshdInstallPort: 22,
    updateChecked: false,
    updateAvailable: false,
    updateVersion: '',
    updateCheckedAt: 0,
    credentialOpen: false,
    credentialTitle: '',
    credentialMessage: '',
    credentialDetail: '',
    // For an action with no single identifier to echo back. A removal is a list
    // of things that go away, and a sentence in the detail strip only restates
    // the message above it.
    credentialDetailList: [],
    credentialAction: 'Confirm',
    credentialAdmin: '',
    credentialDeveloper: '',
    credentialDeveloperRequired: true,
    credentialError: '',
    credentialBusy: false,
    credentialLocked: false,
    credentialSubmit: null,

    // Whether the daemon is running, and nothing else. The toggle and its
    // caption already say whether SSH is enabled, and the alerts cover an
    // unreadable state, so repeating either here only competes with them. The
    // three states map straight onto serviceBadge's contract.
    get sshBadge() {
      if (!this.loaded) return serviceBadge(undefined);
      if (!this.sshInstalled) return serviceBadge(null);
      return serviceBadge(this.sshActive);
    },

    get sshSettingsChanged() {
      return this.sshEnabled !== this.savedSshEnabled || Number(this.sshPort) !== this.savedSshPort;
    },

    flashSaved(message) {
      this.saveMessage = message;
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => { this.saveMessage = ''; }, 4000);
    },

    securityAction(params) {
      return fetchJSON('/cgi-bin/manage_security', {
        method: 'POST',
        body: new URLSearchParams(params),
      });
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

    changePassword() {
      if (!this.currentPassword) {
        this.$store.errorModal.open('Enter your current password.');
        return;
      }
      if (this.newPassword.length < 12 || this.newPassword.length > 256) {
        this.$store.errorModal.open('The new password must be between 12 and 256 characters.');
        return;
      }
      if (this.newPassword !== this.confirmPassword) {
        this.$store.errorModal.open('The new passwords do not match.');
        return;
      }
      // The developer password is not requested here. The root helper rejects a
      // replacement that matches the other stored credential, so the two stay
      // distinct without this form handling both.
      this.busy = true;
      this.busyAction = 'password';
      this.securityAction({
        action: 'change_password',
        current_password: this.currentPassword,
        new_password: this.newPassword,
        confirm_password: this.confirmPassword,
      }).then((data) => {
        if (!data.ok) throw new Error(data.error || 'Password change failed.');
        const warning = data.warning === 'session_invalidation' ? '&session_warning=1' : '';
        window.location.replace(`/login.html?password_changed=1${warning}`);
      }).catch((error) => {
        this.$store.errorModal.open(error.message || 'Password change failed.');
      }).finally(() => { this.busy = false; this.busyAction = ''; });
    },

    changeDeveloperPassword() {
      if (!this.currentDeveloperPassword) {
        this.$store.errorModal.open('Enter your current developer password.');
        return;
      }
      if (this.newDeveloperPassword.length < 12 || this.newDeveloperPassword.length > 256) {
        this.$store.errorModal.open('The new developer password must be between 12 and 256 characters.');
        return;
      }
      if (this.newDeveloperPassword !== this.confirmDeveloperPassword) {
        this.$store.errorModal.open('The new developer passwords do not match.');
        return;
      }
      // The administrator password is not requested here. The root helper
      // rejects a replacement that matches the other stored credential, so the
      // two stay distinct without this form handling both.
      this.busy = true;
      this.busyAction = 'developer';
      this.saveMessage = '';
      clearTimeout(this.saveTimer);
      this.securityAction({
        action: 'change_developer_password',
        current_password: this.currentDeveloperPassword,
        new_password: this.newDeveloperPassword,
        confirm_password: this.confirmDeveloperPassword,
      }).then((data) => {
        if (!data.ok) throw new Error(data.error || 'Developer password change failed.');
        this.currentDeveloperPassword = '';
        this.newDeveloperPassword = '';
        this.confirmDeveloperPassword = '';
        this.flashSaved('Password changed.');
      }).catch((error) => {
        this.$store.errorModal.open(error.message || 'Developer password change failed.');
      }).finally(() => { this.busy = false; this.busyAction = ''; });
    },

    // The textarea remains the source of truth after a file is read. Resetting
    // the picker also allows the same file to be selected again.
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

    // Catch only mistakes that are obvious without parsing a public key. The
    // root helper remains the single authority for syntax and duplication.
    validateKey() {
      const line = this.publicKey.trim();
      this.keyError = '';
      if (!line) return;
      if (line.length > 8192) {
        this.keyError = 'That key is longer than 8192 characters.';
        return;
      }
      if (/BEGIN [A-Z ]*PRIVATE KEY/.test(line)) {
        this.keyError = 'That is a private key. Paste the matching .pub file instead.';
      }
    },

    get keyReady() {
      return this.publicKey.trim() !== '' && !this.keyError;
    },

    // The listing gives a raw algorithm ("ssh-ed25519", "ecdsa-sha2-nistp256").
    // The row shows it as a chip, so shorten it to the part that distinguishes
    // one key from another.
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
      ['cred-admin', 'cred-dev'].forEach((id) => {
        const el = document.getElementById(id);
        if (el) el.value = '';
      });
      this.credentialAdmin = '';
      this.credentialDeveloper = '';
      this.credentialOpen = false;
      this.credentialError = '';
      this.credentialLocked = false;
      this.credentialSubmit = null;
      this.credentialDetailList = [];
    },

    submitCredentials() {
      if (this.credentialBusy || this.credentialLocked) return;
      if (!this.credentialAdmin || (this.credentialDeveloperRequired && !this.credentialDeveloper)) {
        this.credentialError = this.credentialDeveloperRequired
          ? 'Enter both passwords.'
          : 'Enter your administrator password.';
        return;
      }
      this.credentialBusy = true;
      this.credentialError = '';
      Promise.resolve(this.credentialSubmit(this.credentialAdmin, this.credentialDeveloper))
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

    promptCredentials({ title, message, detail, detailList, action, developerRequired = true, run, onSuccess }) {
      this.credentialTitle = title;
      this.credentialMessage = message;
      this.credentialDetail = detail || '';
      this.credentialDetailList = detailList || [];
      this.credentialAction = action;
      this.credentialDeveloperRequired = developerRequired;
      this.credentialAdmin = '';
      this.credentialDeveloper = '';
      this.credentialError = '';
      this.credentialBusy = false;
      this.credentialLocked = false;
      this.credentialSubmit = (admin, developer) =>
        run(admin, developer).then((data) => {
          if (!data.ok) {
            const err = new Error(data.error || 'The change could not be completed.');
            err.locked = /Too many failed attempts/i.test(data.error || '');
            throw err;
          }
          if (onSuccess) onSuccess();
          return this.loadSecurity().then(() => {
            if (data.warning === 'ssh_key_activation') {
              this.$store.errorModal.open('The key was saved, but SSH could not be activated and remains stopped.');
            }
          });
        });
      this.credentialOpen = true;
      setTimeout(() => document.getElementById('cred-admin')?.focus(), 0);
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
      // The button is already disabled at the limit. This covers reaching the
      // action any other way, so the cost is not two passwords and a round trip
      // to be told the store is full.
      if (this.keys.length >= 5) {
        this.$store.errorModal.open('The maximum of 5 SSH keys has been reached. Remove one first.');
        return;
      }
      this.promptCredentials({
        title: 'Add this key?',
        message: 'A key grants root access over SSH, so both passwords are required.',
        detail: publicKey.length > 90 ? publicKey.slice(0, 90) + '…' : publicKey,
        action: 'Add key',
        run: (admin, developer) =>
          this.securityAction({
            action: 'add_key',
            current_password: admin,
            developer_password: developer,
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
        message: 'Every change on this page asks for both passwords.',
        action: 'Save settings',
        run: (admin, developer) => this.securityAction({
          action: 'ssh_settings',
          current_password: admin,
          developer_password: developer,
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
        message: 'This public key will no longer be accepted for SSH login.',
        detail: key.comment ? key.comment + '  ' + key.fingerprint : key.fingerprint,
        action: 'Remove key',
        run: (admin, developer) =>
          this.securityAction({
            action: 'remove_key',
            current_password: admin,
            developer_password: developer,
            fingerprint: key.fingerprint,
          }),
      });
    },


    // Exit codes from install_sshd.sh. A code earns a message when the remedy
    // differs, not merely because the step does. The rest leave the previous
    // installation in place and are a retry, so they share one message and the
    // log names the step that declined.
    sshdFailureMessage() {
      switch (this.sshdCode) {
        case 10: return 'SSH is no longer installed. Reload the page.';
        case 11: return 'SSH is already installed. Reload the page.';
        case 13: return 'Entware is missing. Re-run the QuecDeck installer.';
        case 14: return 'The bundled SSH files failed integrity verification. Update QuecDeck and try again.';
        case 20: return 'SSH was removed, but one or more packages could not be uninstalled. The daemon is stopped and your keys are already deleted. Check opkg before reinstalling.';
        case 21: return 'Another SSH change is already running. Wait for it to finish and try again.';
        case 22: return 'The packages were installed, but sshd could not be started. Check the SSH server panel.';
        case 24: return 'SSH was removed, but the firewall rules could not be reapplied. Check the firewall and the web server.';
        // Settings, account, packages, config, unit, firewall, index. Listed
        // rather than left to the default so every code the installer can
        // return is visibly accounted for, and an unmapped one falls below.
        case 12: case 15: case 16: case 17: case 18: case 19: case 23:
          return 'Nothing was changed. Open the log for the step that declined.';
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

    // A success has nothing left to act on, so it clears itself the way
    // saveMessage does. Failures stay: they are the ones asking for something.
    // A removal stays too: the page changed shape underneath it, and its log is
    // the only record left of what happened.
    scheduleSshdDismiss() {
      if (this.sshdAction === 'uninstall') return;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = setTimeout(() => {
        if (this.sshdOutcome === 'done') this.resetSshdView();
      }, 6000);
    },

    // Both removal outcomes completed: the keys are gone either way, so
    // refreshing into a half-true view is worse than making the reader reload.
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

    // Same wording and locale options as the QuecDeck update page. The time
    // comes from the answer file's mtime rather than the clock at check time,
    // so it survives a reload.
    checkedAtText() {
      if (!this.updateCheckedAt) return '';
      return 'Last checked: ' + new Date(this.updateCheckedAt * 1000).toLocaleString([], { hour12: false });
    },

    beginSshdView(action) {
      // A pending dismissal from the previous run would otherwise fire mid-run
      // and clear this one.
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = null;
      this.sshdAction = action;
      this.sshdRunning = true;
      this.sshdOutcome = '';
      this.sshdCode = 0;
      // Seeded, not empty: the first poll is three seconds out, and the runner
      // has to start its unit before it marks a step, so the line would
      // otherwise be blank for the first few seconds of every action.
      this.sshdStep = 'Starting...';
      this.sshdLog = '';
      this.sshdLogOffset = 0;
      this.sshdReconnecting = false;
      // A fresh decoder per run, so a multi-byte sequence split across two
      // poll chunks is buffered rather than mangled.
      this.sshdDecoder = new TextDecoder('utf-8');
    },

    appendSshdLog(b64, finalFlush) {
      this.sshdLog += decodeLogChunk(this.sshdDecoder, b64, finalFlush);
      // The installer marks its real steps. Everything else in the log is
      // package-manager detail that would flicker as a status line.
      const steps = this.sshdLog.split('\n').filter((line) => line.startsWith('==> '));
      if (steps.length) this.sshdStep = steps[steps.length - 1].slice(4);
    },

    startSshdPolling() {
      clearInterval(this.sshdPollTimer);
      this.sshdPollTimer = setInterval(() => {
        // Skip while the previous tick is in flight: it would read the same
        // not-yet-advanced offset and duplicate the chunk.
        if (this.sshdFetching) return;
        this.sshdFetching = true;
        fetchWithTimeout(fetchJSON, '/cgi-bin/get_update_log?offset=' + this.sshdLogOffset, 8000)
          .then((data) => {
            this.sshdReconnecting = false;
            // A QuecDeck update owns the same log. Showing its progress here
            // would attribute it to SSH.
            if (data.kind && data.kind.indexOf('sshd:') !== 0) return;
            const finished = data.status === 'done' || data.status === 'failed';
            try {
              this.appendSshdLog(data.log, finished);
            } catch (e) {
              this.sshdLog += '\n[Could not decode log chunk]';
            }
            if (typeof data.offset === 'number') this.sshdLogOffset = data.offset;
            if (!finished) return;
            this.sshdRunning = false;
            this.sshdOutcome = data.status;
            this.sshdCode = typeof data.code === 'number' ? data.code : 0;
            clearInterval(this.sshdPollTimer);
            this.sshdPollTimer = null;
            fetch('/cgi-bin/get_update_log?ack=1').catch(() => {});
            this.loadSshdCheck();
            // A partial removal leaves the page describing keys that are gone,
            // so it is the one outcome that must not silently refresh into a
            // half-true view.
            if (!this.sshdNeedsReload()) this.loadSecurity();
            if (data.status === 'done') this.scheduleSshdDismiss();
          })
          .catch(() => { this.sshdReconnecting = true; })
          .finally(() => { this.sshdFetching = false; });
      }, 3000);
    },

    triggerSshdAction(action, admin, developer) {
      const params = { action };
      if (action === 'install') params.port = this.sshdInstallPort;
      if (admin) params.admin_password = admin;
      if (developer) params.developer_password = developer;
      // Busy on click, not on the reply. The trigger writes a unit, reloads
      // systemd and waits a second to catch one that dies at once, so the reply
      // is over a second away. Rolled back below if the start fails.
      this.beginSshdView(action);
      return fetchJSON('/cgi-bin/trigger_sshd_action', {
        method: 'POST',
        body: new URLSearchParams(params),
      })
        .then((data) => {
          if (data.ok) this.startSshdPolling();
          else this.resetSshdView();
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

    // An unset developer password is a missing precondition, not a wrong one:
    // without this the check fails on an empty credential and reads as a bad
    // password. Not keyActionBlocked, which also requires root_home_ready, and
    // get_security reports that false whenever SSH is absent.
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
        message: 'Installing SSH opens a root login path on this modem, so it needs both passwords.',
        detail: 'Port ' + port + ', key-only, idle until a key is added',
        action: 'Install',
        run: (admin, developer) => this.triggerSshdAction('install', admin, developer),
      });
    },

    promptSshdUpdate() {
      if (this.sshdLifecycleBlocked()) return;
      this.promptCredentials({
        title: 'Update SSH server',
        message: 'The SSH server restarts, which ends active SSH sessions. Your port, keys and enabled state are kept.',
        action: 'Update',
        run: (admin, developer) => this.triggerSshdAction('update', admin, developer),
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
        run: (admin, developer) => this.triggerSshdAction('uninstall', admin, developer),
      });
    },

    // Back to idle. Also the rollback when a trigger never started, so the
    // optimistic busy state cannot strand the page with disabled buttons.
    resetSshdView() {
      clearInterval(this.sshdPollTimer);
      this.sshdPollTimer = null;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = null;
      this.sshdAction = '';
      this.sshdRunning = false;
      this.sshdOutcome = '';
      this.sshdCode = 0;
      this.sshdLog = '';
      this.sshdStep = '';
      this.sshdReconnecting = false;
    },

    dismissSshdOutcome() {
      this.resetSshdView();
    },

    // Resumes a run that was already going when the page loaded, which is the
    // normal case after the firewall restart drops the connection.
    resumeSshdAction() {
      return fetchJSON('/cgi-bin/get_update_log')
        .then((data) => {
          if (!data.kind || data.kind.indexOf('sshd:') !== 0) return;
          const action = data.kind.slice(5);
          if (data.status === 'running') {
            this.beginSshdView(action);
            this.appendSshdLog(data.log, false);
            if (typeof data.offset === 'number') this.sshdLogOffset = data.offset;
            this.startSshdPolling();
            return;
          }
          if (data.status === 'done' || data.status === 'failed') {
            this.beginSshdView(action);
            this.sshdRunning = false;
            this.sshdOutcome = data.status;
            this.sshdCode = typeof data.code === 'number' ? data.code : 0;
            this.appendSshdLog(data.log, true);
            fetch('/cgi-bin/get_update_log?ack=1').catch(() => {});
            if (data.status === 'done') this.scheduleSshdDismiss();
          }
        })
        .catch(() => {});
    },

    init() {
      if (!sshPage) return;
      this.loadSecurity();
      this.loadSshdCheck();
      this.resumeSshdAction();
    },
  };
}
