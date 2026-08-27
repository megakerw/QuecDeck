function securitySettings() {
  return {
    busy: false,
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
    publicKey: '',
    keyPassword: '',
    keyDeveloperPassword: '',

    get sshLabel() {
      if (!this.loaded) return 'Loading';
      if (!this.sshInstalled) return 'Not installed';
      if (!this.sshSettingsReady) return 'SSH state unreadable';
      if (!this.sshEnabled) return 'SSH disabled';
      return this.sshActive ? 'SSH active' : 'SSH enabled, inactive';
    },

    get sshSettingsChanged() {
      return this.sshEnabled !== this.savedSshEnabled || Number(this.sshPort) !== this.savedSshPort;
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
      this.busy = true;
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
      }).finally(() => { this.busy = false; });
    },

    readKeyFile(event) {
      const file = event.target.files && event.target.files[0];
      if (!file) return;
      if (file.size > 8192) {
        event.target.value = '';
        this.$store.errorModal.open('The public key file is too large.');
        return;
      }
      file.text().then((text) => {
        this.publicKey = text.trim();
      }).catch(() => this.$store.errorModal.open('The public key file could not be read.'));
    },

    addKey() {
      const publicKey = this.publicKey.trim();
      if (this.sshSettingsChanged) {
        this.$store.errorModal.open('Save the SSH settings before managing public keys.');
        return;
      }
      if (!this.rootHomeReady) {
        this.$store.errorModal.open('The root home permissions are incompatible. Re-run the QuecDeck installer.');
        return;
      }
      if (!this.developerConfigured) {
        this.$store.errorModal.open('Run /usrdata/root/bin/quecdeckdevpasswd through ADB or root SSH before managing SSH keys.');
        return;
      }
      if (!publicKey || !this.keyPassword || !this.keyDeveloperPassword) {
        this.$store.errorModal.open('Enter a public key, your administrator password, and your developer access password.');
        return;
      }
      this.busy = true;
      this.securityAction({
        action: 'add_key',
        current_password: this.keyPassword,
        developer_password: this.keyDeveloperPassword,
        public_key: publicKey,
      }).then((data) => {
        if (!data.ok) throw new Error(data.error || 'The key could not be added.');
        this.publicKey = '';
        this.keyPassword = '';
        this.keyDeveloperPassword = '';
        const input = document.getElementById('public-key-file');
        if (input) input.value = '';
        return this.loadSecurity();
      }).catch((error) => {
        this.$store.errorModal.open(error.message || 'The key could not be added.');
      }).finally(() => { this.busy = false; });
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
      if (!this.developerConfigured) {
        this.$store.errorModal.open('Run /usrdata/root/bin/quecdeckdevpasswd through ADB or root SSH before changing SSH settings.');
        return;
      }
      if (!Number.isInteger(port) || (port !== 22 && (port < 1024 || port > 65535))) {
        this.$store.errorModal.open('Use port 22 or a port between 1024 and 65535.');
        return;
      }
      if (!this.keyPassword || !this.keyDeveloperPassword) {
        this.$store.errorModal.open('Enter your administrator and developer access passwords before changing SSH settings.');
        return;
      }
      this.busy = true;
      this.securityAction({
        action: 'ssh_settings',
        current_password: this.keyPassword,
        developer_password: this.keyDeveloperPassword,
        ssh_enabled: this.sshEnabled ? '1' : '0',
        ssh_port: String(port),
      }).then((data) => {
        if (!data.ok) throw new Error(data.error || 'The SSH settings could not be saved.');
        this.keyPassword = '';
        this.keyDeveloperPassword = '';
        return this.loadSecurity();
      }).catch((error) => {
        this.$store.errorModal.open(error.message || 'The SSH settings could not be saved.');
      }).finally(() => { this.busy = false; });
    },

    confirmRemove(key) {
      if (this.sshSettingsChanged) {
        this.$store.errorModal.open('Save the SSH settings before managing public keys.');
        return;
      }
      if (!this.rootHomeReady) {
        this.$store.errorModal.open('The root home permissions are incompatible. Re-run the QuecDeck installer.');
        return;
      }
      if (!this.developerConfigured) {
        this.$store.errorModal.open('Run /usrdata/root/bin/quecdeckdevpasswd through ADB or root SSH before managing SSH keys.');
        return;
      }
      if (!this.keyPassword || !this.keyDeveloperPassword) {
        this.$store.errorModal.open('Enter your administrator and developer access passwords before removing a key.');
        return;
      }
      this.$store.confirmModal.open(
        'This SSH public key will no longer be accepted.',
        () => this.removeKey(key),
        'Remove SSH key?',
        key.comment || key.fingerprint
      );
    },

    removeKey(key) {
      this.busy = true;
      this.securityAction({
        action: 'remove_key',
        current_password: this.keyPassword,
        developer_password: this.keyDeveloperPassword,
        fingerprint: key.fingerprint,
      }).then((data) => {
        if (!data.ok) throw new Error(data.error || 'The key could not be removed.');
        this.keyPassword = '';
        this.keyDeveloperPassword = '';
        return this.loadSecurity();
      }).catch((error) => {
        this.$store.errorModal.open(error.message || 'The key could not be removed.');
      }).finally(() => { this.busy = false; });
    },

    init() {
      this.loadSecurity();
    },
  };
}
