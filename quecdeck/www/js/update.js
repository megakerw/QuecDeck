function updatePage() {
  return {
    currentVersion: localStorage.getItem('quecdeck_version') || '',
    latestVersion: '',
    latestTag: '',
    updateAvailable: false,
    checked: false,
    checking: false,
    checkedAt: '',
    checkError: '',
    updating: false,
    reconnecting: false,
    reconnectingSince: null,
    reconnectingTimeout: false,
    done: false,
    failed: false,
    rollback: 'none',
    operationId: '',
    operationMonitor: null,
    log: '',
    lastProgressAt: null,
    stallWarning: false,
    reloadCountdown: 0,
    reloadTimer: null,

    checkForUpdates() {
      this.checking = true;
      this.checkError = '';
      return fetchJSON('/cgi-bin/check_update')
        .then((data) => {
          if (data.current) {
            this.currentVersion = data.current;
            localStorage.setItem('quecdeck_version', data.current);
          }
          if (data.error) {
            this.checkError = data.error;
            return;
          }
          this.latestVersion  = data.latest;
          this.latestTag      = data.tag;
          this.updateAvailable = data.update_available;
          this.checked  = true;
          this.checkedAt = new Date().toLocaleString([], { hour12: false });
        })
        .catch((err) => {
          // Network parser errors do not give the user an actionable remedy.
          console.error('check_update failed:', err);
          this.checkError = 'Could not reach the update server.';
        })
        .finally(() => { this.checking = false; });
    },

    triggerUpdate(force) {
      const msg = force
        ? 'This will force-reinstall ' + this.latestVersion + '. The web UI may be briefly unavailable.'
        : 'This will update to ' + this.latestVersion + '. The web UI may be briefly unavailable.';

      this.$store.confirmModal.open(msg, () => {
        this.beginUpdatingView();

        fetchJSON('/cgi-bin/trigger_update', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: 'tag=' + encodeURIComponent(this.latestTag),
        })
          .then((data) => {
            if (!data.ok) {
              this.$store.errorModal.open(data.error || 'Failed to start update.');
              this.updating = false;
              return;
            }
            if (!/^[a-f0-9]{32}$/.test(data.operation_id || '')) {
              throw new Error('The updater did not return an operation ID.');
            }
            this.operationId = data.operation_id;
            this.startPolling();
          })
          .catch((err) => {
            console.error('trigger_update failed:', err);
            this.$store.errorModal.open('Failed to start the update. Check the connection and try again.');
            this.updating = false;
          });
      });
    },

    beginUpdatingView() {
      this.updating = true;
      this.done = false;
      this.failed = false;
      this.rollback = 'none';
      this.log = '';
      this.operationId = '';
      this.lastProgressAt = null;
      this.stallWarning = false;
      this.reconnectingSince = null;
      this.reconnectingTimeout = false;
      clearInterval(this.reloadTimer);
      this.reloadTimer = null;
      this.reloadCountdown = 0;
      if (this.operationMonitor) this.operationMonitor.stop();
    },

    // Hidden result boxes have no scroll height until the next layout pass.
    scrollLogBox(refName) {
      this.$nextTick(() => {
        requestAnimationFrame(() => {
          const box = this.$refs[refName];
          if (box) box.scrollTop = box.scrollHeight;
        });
      });
    },

    appendLogText(chunk) {
      this.log += chunk;
      this.scrollLogBox('logbox');
    },

    ackUpdate() {
      if (this.operationMonitor) this.operationMonitor.acknowledge(this.operationId);
    },

    startReloadCountdown() {
      this.reloadCountdown = 10;
      this.reloadTimer = setInterval(() => {
        this.reloadCountdown--;
        if (this.reloadCountdown <= 0) {
          clearInterval(this.reloadTimer);
          location.reload();
        }
      }, 1000);
    },

    ensureOperationMonitor() {
      if (this.operationMonitor) return;
      this.operationMonitor = createOperationMonitor({
        intervalMs: 3000,
        onSnapshot: (data, chunk) => this.handleOperationSnapshot(data, chunk),
        onDisconnect: (elapsed) => {
          if (!this.reconnecting) this.reconnectingSince = Date.now();
          this.reconnecting = true;
          this.reconnectingTimeout = elapsed > 60000;
        },
        onReconnect: () => {
          this.reconnecting = false;
          this.reconnectingSince = null;
          this.reconnectingTimeout = false;
        },
        onMismatch: () => {
          this.updating = false;
          this.checkForUpdates();
        },
      });
    },

    startPolling(initial = null) {
      this.ensureOperationMonitor();
      this.lastProgressAt = Date.now();
      this.operationMonitor.start({ id: this.operationId, expectedKind: 'quecdeck', initial });
    },

    handleOperationSnapshot(data, chunk) {
      const prevLen = this.log.length;
      this.appendLogText(chunk);
      if (this.log.length > prevLen) {
        this.lastProgressAt = Date.now();
        this.stallWarning = false;
      } else if (Date.now() - this.lastProgressAt > 180000) {
        this.stallWarning = true;
      }
      if (data.status === 'done') {
        this.done = true;
        // The installed version file remains authoritative when GitHub is unavailable.
        if (data.version) {
          this.currentVersion = data.version;
          localStorage.setItem('quecdeck_version', data.version);
        }
        this.updating = false;
        this.ackUpdate();
        this.scrollLogBox('logboxDone');
        this.startReloadCountdown();
      } else if (data.status === 'failed') {
        this.failed = true;
        this.rollback = data.rollback || 'none';
        this.updating = false;
        this.ackUpdate();
        this.scrollLogBox('logboxFailed');
      }
    },

    init() {
      fetchJSON('/cgi-bin/get_update_log')
        .then((data) => {
          // Only the owning page may acknowledge an operation.
          if (data.kind && data.kind !== 'quecdeck') {
            this.checkForUpdates();
            return;
          }
          const validOperation = /^[a-f0-9]{32}$/.test(data.operation_id || '');
          if (data.status === 'running' && validOperation) {
            this.beginUpdatingView();
            this.operationId = data.operation_id;
            this.startPolling(data);
            this.checkForUpdates();
            return;
          }
          if (data.status === 'done' && validOperation) {
            // A completed update requires no progress view after a fresh load.
            this.operationId = data.operation_id;
            this.ensureOperationMonitor();
            this.ackUpdate();
            this.checkForUpdates();
            return;
          }
          if (data.status === 'failed' && validOperation) {
            this.operationId = data.operation_id;
            this.ensureOperationMonitor();
            this.startPolling(data);
            this.checkForUpdates();
            return;
          }
          this.checkForUpdates();
        })
        .catch(() => { this.checkForUpdates(); });
    },
  };
}
