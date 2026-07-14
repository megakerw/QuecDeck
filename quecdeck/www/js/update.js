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
    log: '',
    logOffset: 0,
    logDecoder: null,
    pollTimer: null,
    logFetching: false,
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
          // Raw exception text (e.g. a JSON parse error from a captive
          // portal's HTML reply) is meaningless to the user; log it instead.
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
            this.startPolling();
          })
          .catch((err) => {
            console.error('trigger_update failed:', err);
            this.$store.errorModal.open('Failed to start the update. Check the connection and try again.');
            this.updating = false;
          });
      });
    },

    // Resets state for a freshly-triggered run, or for resuming one that was
    // already running when the page loaded (e.g. after a reload mid-update).
    beginUpdatingView() {
      this.updating = true;
      this.done = false;
      this.failed = false;
      this.rollback = 'none';
      this.log = '';
      this.logOffset = 0;
      this.lastProgressAt = null;
      this.stallWarning = false;
      this.reconnectingSince = null;
      this.reconnectingTimeout = false;
      clearInterval(this.reloadTimer);
      this.reloadTimer = null;
      this.reloadCountdown = 0;
      // A fresh streaming decoder per run: it buffers any multi-byte UTF-8
      // sequence that gets split across two poll chunks instead of mangling it.
      this.logDecoder = new TextDecoder('utf-8');
    },

    appendLogChunk(b64, finalFlush) {
      if (b64) {
        const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
        this.log += this.logDecoder.decode(bytes, { stream: true });
      }
      if (finalFlush) this.log += this.logDecoder.decode();
      this.$nextTick(() => {
        const box = this.$refs.logbox;
        if (box) box.scrollTop = box.scrollHeight;
      });
    },

    ackUpdate() {
      fetch('/cgi-bin/get_update_log?ack=1').catch(() => {});
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

    startPolling() {
      this.lastProgressAt = Date.now();
      this.pollTimer = setInterval(() => {
        // Skip if the previous tick's request is still in flight: it would
        // read the same not-yet-advanced logOffset and duplicate the chunk.
        // The paired timeout keeps a hung request from leaving this stuck
        // true forever.
        if (this.logFetching) return;
        this.logFetching = true;
        fetchWithTimeout(fetchJSON, '/cgi-bin/get_update_log?offset=' + this.logOffset, 8000)
          .then((data) => {
            if (this.reconnecting) {
              this.reconnecting = false;
              this.reconnectingSince = null;
              this.reconnectingTimeout = false;
            }
            const finished = data.status === 'done' || data.status === 'failed';
            const prevLen = this.log.length;
            try {
              this.appendLogChunk(data.log, finished);
            } catch (e) {
              this.log += '\n[Could not decode log chunk]';
            }
            if (this.log.length > prevLen) {
              this.lastProgressAt = Date.now();
              this.stallWarning = false;
            } else if (Date.now() - this.lastProgressAt > 180000) {
              this.stallWarning = true;
            }
            if (typeof data.offset === 'number') this.logOffset = data.offset;

            if (data.status === 'done') {
              this.done = true;
              // get_update_log reports the installed version file, which is
              // authoritative after the swap; it keeps the cached version
              // correct even if check_update is unreachable.
              if (data.version) {
                this.currentVersion = data.version;
                localStorage.setItem('quecdeck_version', data.version);
              }
              this.updating = false;
              clearInterval(this.pollTimer);
              this.ackUpdate();
              this.$nextTick(() => { const b = this.$refs.logboxDone; if (b) b.scrollTop = b.scrollHeight; });
              this.startReloadCountdown();
            } else if (data.status === 'failed') {
              this.failed = true;
              this.rollback = data.rollback || 'none';
              this.updating = false;
              clearInterval(this.pollTimer);
              this.ackUpdate();
              this.$nextTick(() => { const b = this.$refs.logboxFailed; if (b) b.scrollTop = b.scrollHeight; });
            }
          })
          .catch(() => {
            if (!this.reconnecting) {
              this.reconnectingSince = Date.now();
            } else if (Date.now() - this.reconnectingSince > 60000) {
              this.reconnectingTimeout = true;
            }
            this.reconnecting = true;
          })
          .finally(() => { this.logFetching = false; });
      }, 3000);
    },

    init() {
      fetchJSON('/cgi-bin/get_update_log')
        .then((data) => {
          if (data.status === 'running') {
            this.beginUpdatingView();
            this.appendLogChunk(data.log, false);
            if (typeof data.offset === 'number') this.logOffset = data.offset;
            this.startPolling();
            this.checkForUpdates();
            return;
          }
          if (data.status === 'done') {
            // "done" on fresh load is stale (ack race with "Reload now"); go straight to idle.
            this.ackUpdate();
            this.checkForUpdates();
            return;
          }
          if (data.status === 'failed') {
            this.logDecoder = new TextDecoder('utf-8');
            this.appendLogChunk(data.log, true);
            this.ackUpdate();
            this.failed = true;
            this.rollback = data.rollback || 'none';
            this.$nextTick(() => { const b = this.$refs.logboxFailed; if (b) b.scrollTop = b.scrollHeight; });
            this.checkForUpdates();
            return;
          }
          this.checkForUpdates();
        })
        .catch(() => { this.checkForUpdates(); });
    },
  };
}
