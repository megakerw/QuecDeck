function setupWizard() {
  return {
    step: 1,
    adminPass: '',
    adminPassConfirm: '',
    devPass: '',
    devPassConfirm: '',
    error: '',
    submitting: false,

    nextStep() {
      this.error = '';
      if (this.adminPass.length < 8) {
        this.error = 'Password must be at least 8 characters.';
        return;
      }
      if (this.adminPass !== this.adminPassConfirm) {
        this.error = 'Passwords do not match.';
        return;
      }
      this.step = 2;
    },

    skipDev() {
      this.devPass = '';
      this.devPassConfirm = '';
      this.submit();
    },

    submit() {
      this.error = '';
      if (this.devPass) {
        if (this.devPass.length < 8) {
          this.error = 'Developer password must be at least 8 characters.';
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
