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
    sshdFinishTimer: null,
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
    // For an action with no single identifier to echo back, such as a removal
    // that takes several things away at once.
    credentialDetailList: [],
    credentialAction: 'Confirm',
    credentialDeveloper: '',
    credentialError: '',
    credentialBusy: false,
    credentialLocked: false,
    credentialSubmit: null,

    // Use the saved setting so an unsaved toggle does not change server status.
    // A running daemon still takes precedence over a disabled setting.
    get sshBadge() {
      if (this.serverView === 'loading') return serviceBadge(undefined);
      if (this.serverView === 'removing') return { label: 'Removing', cls: 'text-bg-primary' };
      if (this.serverView !== 'manage') return serviceBadge(null);
      if (!this.sshActive && this.sshSettingsReady && !this.savedSshEnabled) {
        return { label: 'Disabled', cls: 'text-bg-secondary' };
      }
      return serviceBadge(this.sshActive);
    },

    // Words for the stood-down Authorized Keys card. An action in flight
    // outranks the installed flag, so an uninstall that cleared it still reads
    // Locked while it runs.
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

    // The one predicate the server card branches on, so its layout and its
    // contents cannot disagree. Order matters: a finished removal outranks
    // sshInstalled, which stays true until the get_security refresh lands.
    // Every state renders a body, so the card never paints as a bare header.
    get serverView() {
      if (!this.loaded) return 'loading';
      if (this.sshdRemovalInProgress) return 'removing';
      if (this.sshdRemovalComplete) return 'removed';
      return this.sshInstalled ? 'manage' : 'install';
    },

    get sshdRemovalView() {
      return this.serverView === 'removing' || this.serverView === 'removed';
    },

    // Keys belong to an installed server that nothing is currently changing.
    get keysManageable() {
      return this.serverView === 'manage' && !this.sshdRunning;
    },

    // The progress bar and the step line share one condition. A check has a
    // single step and its button already names it.
    get sshdProgressVisible() {
      return this.sshdRunning && this.sshdAction !== 'check';
    },

    get sshdStepVisible() {
      return this.sshdProgressVisible && !!this.sshdStep && !this.sshdReconnecting;
    },

    // Pending toggle first, then why an enabled server may not be running.
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
      // The developer password is not requested here. The root helper rejects
      // a replacement that matches the other stored credential.
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
      // rejects a replacement that matches the other stored credential.
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
      if (/BEGIN [A-Z0-9 ]*PRIVATE KEY/.test(line)) {
        this.keyError = 'That is a private key. Paste the matching .pub file instead.';
        return;
      }
      // PuTTYgen's "Save public key" writes this instead of the OpenSSH line.
      if (/BEGIN SSH2 PUBLIC KEY/.test(line)) {
        this.keyError = 'This file uses SSH2 public-key format. Export it in OpenSSH authorized_keys format, then paste the resulting single line.';
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
      // Cleared before the node is removed: Chromium reads a filled password
      // field disappearing as a successful credential update and offers to
      // save it.
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
      // The button is already disabled at the limit. This catches the action
      // reached any other way, before it costs a password and a round trip.
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
          this.securityAction({
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
        run: (developer) => this.securityAction({
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
        message: 'This public key will no longer be accepted for SSH login.',
        detail: key.comment ? key.comment + '  ' + key.fingerprint : key.fingerprint,
        action: 'Remove key',
        run: (developer) =>
          this.securityAction({
            action: 'remove_key',
            current_password: developer,
            fingerprint: key.fingerprint,
          }),
      });
    },


    // Exit codes from install_sshd.sh. A code gets its own message only when
    // the remedy differs. The remaining failures are safe to inspect and retry.
    sshdFailureMessage() {
      switch (this.sshdCode) {
        case 10: return 'SSH is no longer installed. Reload the page.';
        case 11: return 'SSH is already installed. Reload the page.';
        case 13: return 'Entware is unavailable or its package metadata is not trusted. Sshd was left stopped. Open the log for the check that declined.';
        case 14: return 'The bundled SSH files failed integrity verification. Update QuecDeck and try again.';
        case 20: return 'SSH was removed, but one or more packages could not be uninstalled. The daemon is stopped and your keys are already deleted. Check opkg before reinstalling.';
        case 21: return 'Another SSH change is already running. Wait for it to finish and try again.';
        case 22: return 'The packages were installed, but sshd could not be started. Check the SSH server panel.';
        case 24: return 'SSH was removed, but the firewall rules could not be reapplied. Check the firewall and the web server.';
        case 25: return 'The SSH server could not be stopped, so the action stopped at that step. Open the log to see how far it got.';
        // Settings, account, packages, config, unit, firewall, index. Listed so
        // every code the installer can return is accounted for here.
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

    // Only a success clears itself. A failure still needs acting on, and a
    // removal changed the shape of the page, with its log the only record of
    // what happened.
    scheduleSshdDismiss() {
      if (this.sshdAction === 'uninstall') return;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = setTimeout(() => {
        if (this.sshdOutcome === 'done') this.resetSshdView();
      }, 6000);
    },

    // Both removal outcomes completed and the keys are gone either way, so a
    // refresh would show a half-true view. Make the reader reload instead.
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
      // A pending completion or dismissal from the previous run would
      // otherwise fire mid-run and clear this one.
      clearTimeout(this.sshdFinishTimer);
      this.sshdFinishTimer = null;
      clearTimeout(this.sshdDoneTimer);
      this.sshdDoneTimer = null;
      this.sshdAction = action;
      this.sshdRunning = true;
      this.sshdOutcome = '';
      this.sshdCode = 0;
      // Seeded for the short window before the first immediate poll returns.
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
      const expectedAction = this.sshdAction;
      const expectedKind = 'sshd:' + expectedAction;
      const poll = () => {
        // Skip while the previous tick is in flight: it would read the same
        // not-yet-advanced offset and duplicate the chunk.
        if (this.sshdFetching) return;
        this.sshdFetching = true;
        const requestedOffset = this.sshdLogOffset;
        fetchWithTimeout(fetchJSON, '/cgi-bin/get_update_log?offset=' + requestedOffset, 8000)
          .then((data) => {
            if (this.sshdAction !== expectedAction) return;
            // A late request from an earlier polling cycle may finish after a
            // newer one has advanced the log. Its chunk starts at the old
            // offset and must not be appended a second time.
            if (requestedOffset !== this.sshdLogOffset) return;
            this.sshdReconnecting = false;
            // Another tab may acknowledge this result first, or a later action
            // may replace it. Stop presenting this action as live and reconcile
            // with the device instead of polling an absent status forever.
            if (data.kind !== expectedKind) {
              this.resetSshdView();
              this.loadSshdCheck();
              this.loadSecurity();
              return;
            }
            const finished = data.status === 'done' || data.status === 'failed';
            try {
              this.appendSshdLog(data.log, finished);
            } catch (e) {
              this.sshdLog += '\n[Could not decode log chunk]';
            }
            if (typeof data.offset === 'number') this.sshdLogOffset = data.offset;
            if (!finished) return;
            clearInterval(this.sshdPollTimer);
            this.sshdPollTimer = null;
            // A quick action may finish before the first status request returns.
            // Its final log still contains the real steps, so keep the progress
            // view up long enough for the last one to be readable.
            const finish = () => {
              this.sshdFinishTimer = null;
              this.sshdRunning = false;
              this.sshdOutcome = data.status;
              this.sshdCode = typeof data.code === 'number' ? data.code : 0;
              fetch('/cgi-bin/get_update_log?ack=1').catch(() => {});
              this.loadSshdCheck();
              if (!this.sshdNeedsReload()) this.loadSecurity();
              if (data.status === 'done') this.scheduleSshdDismiss();
            };
            this.sshdFinishTimer = setTimeout(finish, 750);
          })
          .catch(() => { this.sshdReconnecting = true; })
          .finally(() => { this.sshdFetching = false; });
      };
      // Read once now, then frequently enough to expose short package actions.
      poll();
      this.sshdPollTimer = setInterval(poll, 1000);
    },

    triggerSshdAction(action, developer) {
      const params = { action };
      if (action === 'install') params.port = this.sshdInstallPort;
      if (developer) params.developer_password = developer;
      // Busy on click, then the credential dialog closes as soon as systemd
      // accepts the background job. Progress and early unit failures both come
      // from the status poll.
      this.beginSshdView(action);
      return fetchJSON('/cgi-bin/trigger_sshd_action', {
        method: 'POST',
        body: new URLSearchParams(params),
      })
        .then((data) => {
          if (data.ok) {
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

    // Back to idle. Also the rollback when a trigger never started, so the
    // optimistic busy state cannot strand the page with disabled buttons.
    resetSshdView() {
      clearInterval(this.sshdPollTimer);
      this.sshdPollTimer = null;
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
