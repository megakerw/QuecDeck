function securitySettings(sshPage = false) {
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
    keyDuplicate: false,
    pastedFingerprint: '',

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

    // The picker loads a key into the box. It is not a second place a key can
    // live, so it resets itself once read: the textarea is then the only source
    // of truth, editing or clearing it cannot leave a stale filename behind, and
    // picking the same file twice still fires a change event.
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

    // Mirrors valid_key_syntax in ssh_keys.sh. The root helper stays the
    // authority and re-checks everything; this only spares the round trip and,
    // more to the point, spares typing both passwords to be told the key was
    // never usable. Keep the two in step: the helper's rules are the spec.
    validateKey() {
      const line = this.publicKey.trim();
      this.keyError = '';
      this.keyDuplicate = false;
      this.pastedFingerprint = '';
      if (!line) return;
      if (line.length > 8192) {
        this.keyError = 'That key is longer than 8192 characters.';
        return;
      }
      if (/BEGIN [A-Z ]*PRIVATE KEY/.test(line)) {
        this.keyError = 'That is a private key. Paste the matching .pub file instead.';
        return;
      }
      const parts = line.split(/\s+/);
      const type = parts[0];
      const blob = parts[1];
      const allowed = [
        'ssh-ed25519', 'ssh-rsa',
        'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521',
      ];
      // The algorithm must be the first field, which is also what rejects a
      // line carrying authorized_keys options such as command= or permitopen=.
      if (!allowed.includes(type)) {
        this.keyError = 'Unsupported or malformed key. Use an Ed25519, ECDSA, or RSA public key with no options.';
        return;
      }
      if (!blob || !/^[A-Za-z0-9+/=]+$/.test(blob)) {
        this.keyError = 'The key data is missing or malformed.';
        return;
      }
      const comment = parts.slice(2).join(' ');
      if (comment.length > 80) {
        this.keyError = 'The comment is longer than 80 characters.';
        return;
      }
      if (comment && !/^[ -~]+$/.test(comment)) {
        this.keyError = 'The comment contains characters that are not allowed.';
        return;
      }
      this.fingerprintOf(blob).then((fingerprint) => {
        // The field may have changed while the digest was computing.
        if (this.publicKey.trim() !== line) return;
        this.pastedFingerprint = fingerprint;
        if (fingerprint && this.keys.some((k) => k.fingerprint === fingerprint)) {
          this.keyDuplicate = true;
          this.keyError = 'This key is already authorized.';
        }
      });
    },

    // Same value ssh-keygen prints: SHA-256 of the decoded blob, base64, with
    // the padding stripped. Returns '' where SubtleCrypto is unavailable, and
    // the server-side duplicate check then does the work as before.
    fingerprintOf(blob) {
      if (!window.crypto || !window.crypto.subtle) return Promise.resolve('');
      let bytes;
      try {
        const binary = atob(blob);
        bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
      } catch (e) {
        return Promise.resolve('');
      }
      return crypto.subtle.digest('SHA-256', bytes)
        .then((digest) => {
          const b64 = btoa(String.fromCharCode.apply(null, new Uint8Array(digest)));
          return 'SHA256:' + b64.replace(/=+$/, '');
        })
        .catch(() => '');
    },

    get keyReady() {
      return this.publicKey.trim() !== '' && !this.keyError && !this.keyDuplicate;
    },

    // The listing gives a raw algorithm ("ssh-ed25519", "ecdsa-sha2-nistp256").
    // The row shows it as a chip, so shorten it to the part that distinguishes
    // one key from another.
    keyAlgorithm(type) {
      if (!type) return 'KEY';
      if (type.startsWith('ecdsa-')) return 'ECDSA';
      return type.replace(/^ssh-/, '').toUpperCase();
    },

    // A key with no comment used to fall back to its algorithm, which then
    // appeared twice in the same row: once as the title and again beneath it.
    keyTitle(key) {
      return key.comment || 'No comment';
    },

    // Both key operations grant or revoke root access, so both ask for the two
    // passwords at the moment they are taken rather than from fields parked on
    // the card. The dialog stays open on failure with the entry intact.
    promptCredentials({ title, message, detail, action, developerRequired = true, run, onSuccess }) {
      this.$store.credentialModal.open({
        title,
        message,
        detail,
        action,
        developerRequired,
        onSubmit: (admin, developer) =>
          run(admin, developer).then((data) => {
            if (!data.ok) {
              const err = new Error(data.error || 'The change could not be completed.');
              // A per-client lockout cannot be retried away, so the dialog stops
              // offering the attempt rather than letting it fail repeatedly.
              err.locked = /Too many failed attempts/i.test(data.error || '');
              throw err;
            }
            if (onSuccess) onSuccess();
            return this.loadSecurity();
          }),
      });
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
        detail: this.pastedFingerprint || (publicKey.length > 90 ? publicKey.slice(0, 90) + '…' : publicKey),
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

    // Not credential gated: enabling SSH grants nothing without an authorized
    // key, and a key still needs both passwords. See the settings arm of
    // ssh_keys.sh for the reasoning and the accepted consequence.
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
      this.saveMessage = '';
      clearTimeout(this.saveTimer);
      // Administrator password only. Enabling SSH or moving its port grants no
      // access on its own, and the key that would make it useful already needed
      // both passwords to install.
      this.promptCredentials({
        title: 'Confirm SSH settings',
        message: 'Enter your administrator password to save the SSH server settings.',
        action: 'Save settings',
        developerRequired: false,
        run: (admin) => this.securityAction({
          action: 'ssh_settings',
          current_password: admin,
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


    init() {
      if (sshPage) this.loadSecurity();
    },
  };
}
