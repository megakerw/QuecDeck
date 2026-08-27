function setupWizard() {
  return {
    step: 1,
    adminPass: '',
    adminPassConfirm: '',
    devPass: '',
    devPassConfirm: '',
    error: '',
    submitting: false,
    developerConfigured: false,
    setupReady: false,

    init() {
      fetch('/cgi-bin/init_setup')
        .then((response) => {
          if (!response.ok) throw new Error('Setup status request failed');
          return response.json();
        })
        .then((data) => {
          this.developerConfigured = data.developer_configured === true;
          this.setupReady = true;
        })
        .catch(() => {
          this.error = 'Could not determine the current setup state. Please reload the page.';
        });
    },

    nextStep() {
      if (this.submitting) return;
      this.error = '';
      if (!this.setupReady) {
        this.error = 'Could not determine the current setup state. Please reload the page.';
        return;
      }
      if (this.adminPass.length < 12) {
        this.error = 'Password must be at least 12 characters.';
        return;
      }
      if (this.adminPass !== this.adminPassConfirm) {
        this.error = 'Passwords do not match.';
        return;
      }
      if (this.developerConfigured) {
        this.submitExistingDev();
      } else {
        this.step = 2;
      }
    },

    // Developer access already exists, so the wizard is only resetting the
    // administrator password. The developer fields must stay blank.
    submitExistingDev() {
      this.devPass = '';
      this.devPassConfirm = '';
      this.submit();
    },

    submit() {
      if (this.submitting) return;
      this.error = '';
      if (!this.developerConfigured) {
        if (this.devPass.length < 12) {
          this.error = 'Developer password must be at least 12 characters.';
          return;
        }
        if (this.devPass !== this.devPassConfirm) {
          this.error = 'Passwords do not match.';
          return;
        }
      }

      this.submitting = true;
      const body = new URLSearchParams({ admin_pass: this.adminPass });
      if (this.devPass) body.append('dev_pass', this.devPass);

      fetch('/cgi-bin/init_setup', { method: 'POST', body })
        .then(r => r.json())
        .then(data => {
          if (data.ok) {
            window.location.href = '/login.html';
          } else {
            this.error = data.error || 'Setup failed. Please try again.';
          }
        })
        .catch(() => {
          this.error = 'Request failed. Please try again.';
        })
        .finally(() => {
          this.submitting = false;
        });
    },
  };
}
