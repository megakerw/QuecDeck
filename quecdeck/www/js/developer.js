function developerPage() {
  return {
    isLoading: false,
    isClean: true,
    atcmd: "",
    atTimeout: 5,
    atCommandResponse: "",
    ttydRunning: false,
    devUnlocked: false,
    devConfigured: true,
    devStatusLoaded: false,
    devPassword: '',
    devAuthError: '',
    devUnlocking: false,
    networkModeCell: '-',
    cells: Array.from({ length: 10 }, () => ({ earfcn: null, pci: null })),
    scs: null,
    band: null,
    cellNum: null,
    cellLockStatus: 'Unknown',
    cellLockLoading: false,

    sendSetting(action) {
      return authFetch('/cgi-bin/set_setting', { method: 'POST', body: new URLSearchParams({ action }) })
        .then(r => r.text())
        .then(text => {
          if (text.includes('ERROR')) throw new Error(text.trim());
          return text;
        });
    },


    fetchCellLockStatus() {
      authFetch('/cgi-bin/user_atcommand', {
        method: 'POST',
        body: new URLSearchParams({ atcmd: 'AT+QNWLOCK="common/4g";+QNWLOCK="common/5g"' }),
      })
        .then(r => r.text())
        .then(data => {
          const get4g = data.match(/\+QNWLOCK: "common\/4g",(\d+)/);
          const get5g = data.match(/\+QNWLOCK: "common\/5g",(\d+)/);
          const locked4g = get4g && get4g[1] === '1';
          const locked5g = get5g && get5g[1] === '1';
          if (locked4g && locked5g) this.cellLockStatus = 'Locked to 4G and 5G';
          else if (locked4g) this.cellLockStatus = 'Locked to 4G';
          else if (locked5g) this.cellLockStatus = 'Locked to 5G';
          else this.cellLockStatus = 'Not Locked';
        })
        .catch(() => {});
    },

    cellLockEnableLTE() {
      const cellNum = this.cellNum;
      const isInt = (v) => /^\d+$/.test(String(v).trim());
      if (cellNum === null || !isInt(cellNum)) {
        this.$store.errorModal.open('Please enter a valid number of cells to lock');
        return;
      }
      const earfcnPciPairs = this.cells.slice(0, parseInt(cellNum));
      const validPairs = earfcnPciPairs.filter(
        (pair) => pair.earfcn && pair.pci && isInt(pair.earfcn) && isInt(pair.pci)
      );
      if (validPairs.length === 0) {
        this.$store.errorModal.open('Please enter at least one valid EARFCN and PCI pair (integers only)');
        return;
      }
      const pairs = validPairs.map((pair) => `${pair.earfcn},${pair.pci}`).join(',');
      this.$store.confirmModal.open(
        'Locking cells may briefly interrupt your connection.',
        () => {
          this.cellLockLoading = true;
          this.postCellLockAction({ type: 'lte', count: cellNum, pairs })
            .then(() => this.fetchCellLockStatus())
            .catch(err => this.$store.errorModal.open(err.message || 'Failed to apply cell lock settings.'))
            .finally(() => { this.cellLockLoading = false; });
        },
        'Lock LTE Cells?'
      );
    },

    cellLockEnableNR() {
      const earfcn = this.cells[0].earfcn;
      const pci = this.cells[0].pci;
      const scs = this.scs;
      const band = this.band;
      if (!earfcn || !pci || !scs || scs === 'SCS' || !band) {
        this.$store.errorModal.open('Please enter all the required fields');
        return;
      }
      if (!/^\d+$/.test(String(earfcn)) || !/^\d+$/.test(String(pci))) {
        this.$store.errorModal.open('EARFCN and PCI must be integers');
        return;
      }
      this.$store.confirmModal.open(
        'Locking cells may briefly interrupt your connection.',
        () => {
          this.cellLockLoading = true;
          this.postCellLockAction({ type: 'nr', earfcn, pci, scs, band })
            .then(() => this.fetchCellLockStatus())
            .catch(err => this.$store.errorModal.open(err.message || 'Failed to apply cell lock settings.'))
            .finally(() => { this.cellLockLoading = false; });
        },
        'Lock NR5G-SA Cell?'
      );
    },

    cellLockDisableLTE() {
      this.cellLockLoading = true;
      this.postCellLockAction({ type: 'unlock_lte' })
        .then(() => this.fetchCellLockStatus())
        .catch(err => this.$store.errorModal.open(err.message || 'Failed to unlock LTE cells.'))
        .finally(() => { this.cellLockLoading = false; });
    },

    cellLockDisableNR() {
      this.cellLockLoading = true;
      this.postCellLockAction({ type: 'unlock_nr' })
        .then(() => this.fetchCellLockStatus())
        .catch(err => this.$store.errorModal.open(err.message || 'Failed to unlock NR5G-SA cells.'))
        .finally(() => { this.cellLockLoading = false; });
    },

    postCellLockAction(params) {
      return authFetch('/cgi-bin/set_cell_lock', {
        method: 'POST',
        body: new URLSearchParams(params),
      })
        .then(r => r.text())
        .then(text => {
          if (text.includes('ERROR')) throw new Error(text.trim());
          return text;
        });
    },

    checkDevStatus() {
      authFetch('/cgi-bin/auth_dev')
        .then((r) => r.json())
        .then((data) => {
          this.devUnlocked = data.unlocked === true;
          this.devConfigured = data.configured !== false;
          if (this.devUnlocked) {
            this.fetchTtydStatus();
            this.fetchCellLockStatus();
          }
        })
        .catch(() => {})
        .finally(() => { this.devStatusLoaded = true; });
    },

    unlockDev() {
      if (!this.devPassword || this.devUnlocking) return;
      this.devUnlocking = true;
      this.devAuthError = '';
      authFetch('/cgi-bin/auth_dev', {
        method: 'POST',
        body: new URLSearchParams({ password: this.devPassword }),
      })
        .then((r) => r.json())
        .then((data) => {
          this.devUnlocking = false;
          if (data.unlocked) {
            this.devUnlocked = true;
            this.devPassword = '';
            this.fetchTtydStatus();
            this.fetchCellLockStatus();
          } else if (data.error === 'locked') {
            this.devAuthError = 'Too many failed attempts. Try again in 15 minutes.';
            this.devPassword = '';
          } else {
            this.devAuthError = 'Wrong password. Please try again.';
            this.devPassword = '';
          }
        })
        .catch(() => {
          this.devUnlocking = false;
          this.devAuthError = 'Failed to contact server. Please try again.';
        });
    },

    sendATCommand() {
      if (!this.atcmd) this.atcmd = "ATI";
      this.isLoading = true;
      authFetch('/cgi-bin/user_atcommand', { method: 'POST', body: new URLSearchParams({ atcmd: this.atcmd, timeout: (this.atTimeout || 5) * 1000 }) })
        .then((res) => {
          if (!res.ok) throw new Error(`HTTP error! status: ${res.status}`);
          return res.text();
        })
        .then((data) => {
          this.atCommandResponse = data;
          this.isLoading = false;
          this.isClean = false;
        })
        .catch((error) => {
          this.atCommandResponse = 'Error: ' + (error?.message || 'Request failed');
          this.isLoading = false;
          this.isClean = false;
        });
    },

    clearResponses() {
      this.atCommandResponse = "";
      this.isClean = true;
    },

    fetchTtydStatus() {
      authFetch('/cgi-bin/toggle_ttyd')
        .then((r) => r.json())
        .then((data) => { this.ttydRunning = data.running === true; })
        .catch(() => {});
    },

    toggleTtyd(action) {
      this.isLoading = true;
      this.$store.waitModal.start(
        action === 'start' ? 'Starting ttyd...' : 'Stopping ttyd...',
        15,
        () => {}
      );
      authFetch('/cgi-bin/toggle_ttyd', { method: 'POST', body: new URLSearchParams({ action }) })
        .then((r) => r.json())
        .then((data) => {
          this.$store.waitModal.stop();
          this.ttydRunning = data.running === true;
          this.isLoading = false;
        })
        .catch(() => {
          this.$store.waitModal.stop();
          this.isLoading = false;
          this.$store.errorModal.open('Failed to toggle ttyd. Please try again.');
        });
    },

    init() {
      this.checkDevStatus();
    },
  };
}
