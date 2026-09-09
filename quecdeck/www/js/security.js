function securityController() {
  return {
    busy: false,
    // Which action is in flight. busy alone disables every button, so the label
    // must key on this or an idle form claims to be working too.
    busyAction: '',
    saveMessage: '',
    saveTimer: null,
    currentPassword: '',
    newPassword: '',
    confirmPassword: '',
    currentDeveloperPassword: '',
    newDeveloperPassword: '',
    confirmDeveloperPassword: '',

    flashSaved(message) {
      this.saveMessage = message;
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => { this.saveMessage = ''; }, 4000);
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
      postSecurityAction({
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
      postSecurityAction({
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
  };
}
