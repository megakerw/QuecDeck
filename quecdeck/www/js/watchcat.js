function quecdeckWatchCat() {
  return {
    // Watchcat
    enabled: false,
    ips: ['8.8.8.8', '1.1.1.1', '9.9.9.9'],
    pingInterval: 30,
    pingFailureCount: 3,
    disableOnNoSim: true,
    rebootBackoff: true,
    logRestarts: true,
    serviceActive: false,
    isLoading: false,
    response: '',
    stats: [],
    consecutiveFailures: 0,
    rebootCount: 0,
    backoffUntil: 0,
    statsUpdatedAt: '',
    statsTimer: null,
    statsFetching: false,
    now: Date.now(),
    nowTimer: null,
    responseTimer: null,

    // Scheduled restart
    srEnabled: false,
    srType: 'daily',
    srDay: 1,
    srHour: 3,
    srMinute: 0,
    srLoading: false,
    srResponse: '',
    srServiceActive: false,
    srDeviceTzOffsetMins: 0,
    srResponseTimer: null,

    get capExceeded() {
      return this.pingInterval * this.pingFailureCount > 3600;
    },

    get backoffActive() {
      return this.rebootCount > 0 && this.backoffUntil * 1000 > this.now;
    },

    get backoffRemainingText() {
      const remaining = Math.max(0, this.backoffUntil - this.now / 1000);
      const m = Math.floor(remaining / 60);
      const s = Math.floor(remaining % 60);
      return m > 0 ? `${m}m ${s}s` : `${s}s`;
    },

    get validIps() {
      return this.ips.filter((ip) => /^(\d{1,3}\.){3}\d{1,3}$/.test(ip.trim()));
    },

    canAddIp() {
      if (this.ips.length >= 6) return false;
      const parts = this.ips[this.ips.length - 1].trim().split('.');
      return parts.length === 4 && parts.every(o => o !== '' && +o >= 0 && +o <= 255);
    },

    get canSave() {
      if (!this.enabled) return true;
      return (
        this.validIps.length > 0 &&
        this.pingInterval >= 10 &&
        this.pingInterval <= 600 &&
        this.pingFailureCount >= 2 &&
        this.pingFailureCount <= 10
      );
    },

    // Parse "+0530" or "-0500" → offset in minutes from UTC
    parseTzOffset(str) {
      if (!str || str.length < 5) return 0;
      const sign = str[0] === '-' ? -1 : 1;
      const h = parseInt(str.slice(1, 3), 10);
      const m = parseInt(str.slice(3, 5), 10);
      return sign * (h * 60 + m);
    },

    // Convert device-local (hour, minute, day) → browser-local
    deviceToLocal(hour, minute, day) {
      const userOffsetMins = -new Date().getTimezoneOffset();
      const delta = userOffsetMins - this.srDeviceTzOffsetMins;
      let total = hour * 60 + minute + delta;
      let dayShift = 0;
      if (total < 0)    { total += 1440; dayShift = -1; }
      if (total >= 1440) { total -= 1440; dayShift = 1; }
      return {
        hour: Math.floor(total / 60),
        minute: total % 60,
        day: ((day - 1 + dayShift + 7) % 7) + 1,
      };
    },

    // Convert browser-local (hour, minute, day) → device-local
    localToDevice(hour, minute, day) {
      const userOffsetMins = -new Date().getTimezoneOffset();
      const delta = this.srDeviceTzOffsetMins - userOffsetMins;
      let total = hour * 60 + minute + delta;
      let dayShift = 0;
      if (total < 0)    { total += 1440; dayShift = -1; }
      if (total >= 1440) { total -= 1440; dayShift = 1; }
      return {
        hour: Math.floor(total / 60),
        minute: total % 60,
        day: ((day - 1 + dayShift + 7) % 7) + 1,
      };
    },

    get srCanSave() {
      return (
        this.srHour >= 0 && this.srHour <= 23 &&
        this.srMinute >= 0 && this.srMinute <= 59
      );
    },

    get srTime() {
      return String(this.srHour).padStart(2, '0') + ':' + String(this.srMinute).padStart(2, '0');
    },

    set srTime(val) {
      if (!val) return;
      const [h, m] = val.split(':').map(Number);
      this.srHour = isNaN(h) ? 0 : h;
      this.srMinute = isNaN(m) ? 0 : m;
    },

    addIp() {
      if (this.ips.length < 6) this.ips.push('');
    },

    removeIp(index) {
      if (this.ips.length > 1) this.ips.splice(index, 1);
    },

    buildParams() {
      const params = {
        WATCHCAT_ENABLED: this.enabled ? 'enable' : 'disable',
        PING_INTERVAL: this.pingInterval,
        PING_FAILURE_COUNT: this.pingFailureCount,
        DISABLE_ON_NO_SIM: this.disableOnNoSim ? '1' : '0',
        REBOOT_BACKOFF: this.rebootBackoff ? '1' : '0',
        LOG_RESTARTS: this.logRestarts ? '1' : '0',
      };
      this.validIps.forEach((ip, i) => {
        params[`TRACK_IP_${i + 1}`] = ip.trim();
      });
      return params;
    },

    saveSettings() {
      this.isLoading = true;
      this.response = '';
      clearTimeout(this.responseTimer);
      authFetch('/cgi-bin/watchcat_maker', { method: 'POST', body: new URLSearchParams(this.buildParams()) })
        .then((response) => response.text().then((text) => {
          this.isLoading = false;
          if (response.ok) {
            this.response = this.enabled ? 'Saved.' : 'Disabled.';
            this.rebootCount = 0;
            this.backoffUntil = 0;
            this.fetchSettings();
            this.responseTimer = setTimeout(() => { this.response = ''; }, 4000);
          } else {
            this.$store.errorModal.open(text.trim());
          }
        }))
        .catch((err) => {
          this.isLoading = false;
          this.$store.errorModal.open('Failed to save watchcat settings: ' + err);
        });
    },

    fetchSettings(signal) {
      return fetchJSON('/cgi-bin/get_watchcat_status', signal ? { signal } : {})
        .then((data) => {
          if (data && Object.keys(data).length > 0) {
            this.enabled = data.enabled === true;
            this.serviceActive = data.enabled === true;
            this.ips = data.track_ips && data.track_ips.length > 0 ? data.track_ips : ['8.8.8.8', '1.1.1.1', '9.9.9.9'];
            this.pingInterval = data.ping_interval || 30;
            this.pingFailureCount = data.ping_failure_count || 3;
            this.disableOnNoSim = data.disable_on_no_sim !== false;
            this.rebootBackoff = data.reboot_backoff !== false;
            if (this.capExceeded) this.rebootBackoff = false;
            this.logRestarts = data.log_restarts !== false;
          }
        });
    },

    fetchStats() {
      if (this.statsFetching) return;
      this.statsFetching = true;
      fetchWithTimeout(fetchJSON, '/cgi-bin/get_watchcat_stats', 4000)
        .then((data) => {
          if (data && data.stats) {
            this.stats = data.stats;
            this.consecutiveFailures = data.consecutive_failures || 0;
            this.rebootCount = data.reboot_count || 0;
            this.backoffUntil = data.backoff_until || 0;
            const now = new Date();
            this.statsUpdatedAt = now.toLocaleString([], { hour12: false });
          }
        })
        .catch(() => {})
        .finally(() => { this.statsFetching = false; });
    },

    startStatsPolling() {
      this.stopStatsPolling();
      this.fetchStats();
      this.statsTimer = setInterval(() => this.fetchStats(), 2000);
      this.nowTimer = setInterval(() => { this.now = Date.now(); }, 1000);
    },

    stopStatsPolling() {
      if (this.statsTimer) {
        clearInterval(this.statsTimer);
        this.statsTimer = null;
      }
      if (this.nowTimer) {
        clearInterval(this.nowTimer);
        this.nowTimer = null;
      }
    },

    fetchScheduledRestart(signal) {
      return fetchJSON('/cgi-bin/get_scheduled_restart', signal ? { signal } : {})
        .then((data) => {
          if (data) {
            this.srEnabled = data.enabled === true;
            this.srServiceActive = data.enabled === true;
            this.srType = data.type || 'daily';
            this.srDeviceTzOffsetMins = this.parseTzOffset(data.device_tz_offset || '+0000');
            const local = this.deviceToLocal(
              data.hour !== undefined ? data.hour : 3,
              data.minute !== undefined ? data.minute : 0,
              data.day || 1
            );
            this.srHour = local.hour;
            this.srMinute = local.minute;
            this.srDay = local.day;
          }
        });
    },

    saveScheduledRestart() {
      this.srLoading = true;
      this.srResponse = '';
      clearTimeout(this.srResponseTimer);
      const device = this.localToDevice(this.srHour, this.srMinute, this.srDay);
      const params = {
        ENABLED: this.srEnabled ? 'enable' : 'disable',
        TYPE: this.srType,
        DAY: device.day,
        HOUR: device.hour,
        MINUTE: device.minute,
      };
      authFetch('/cgi-bin/scheduled_restart_maker', { method: 'POST', body: new URLSearchParams(params) })
        .then((response) => response.text().then((text) => {
          this.srLoading = false;
          if (response.ok) {
            this.srResponse = this.srEnabled ? 'Saved.' : 'Disabled.';
            this.fetchScheduledRestart();
            this.srResponseTimer = setTimeout(() => { this.srResponse = ''; }, 4000);
          } else {
            this.$store.errorModal.open(text.trim());
          }
        }))
        .catch(() => {
          this.srLoading = false;
          this.$store.errorModal.open('Failed to save scheduled restart settings. Please try again.');
        });
    },

    init() {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 4000);
      Promise.all([
        this.fetchSettings(controller.signal),
        this.fetchScheduledRestart(controller.signal),
      ]).then(() => {
        clearTimeout(timer);
        if (this.serviceActive) this.startStatsPolling();
      }).catch(() => {
        clearTimeout(timer);
        this.$store.errorModal.open('Failed to load settings.');
      });
      this.$watch('pingInterval', () => { if (this.capExceeded) this.rebootBackoff = false; });
      this.$watch('pingFailureCount', () => { if (this.capExceeded) this.rebootBackoff = false; });
      this.$watch('serviceActive', (value) => {
        if (value) {
          this.startStatsPolling();
        } else {
          this.stopStatsPolling();
        }
      });
      if (this._visibilityHandler) {
        document.removeEventListener('visibilitychange', this._visibilityHandler);
      }
      this._visibilityHandler = () => {
        if (document.hidden) {
          this.stopStatsPolling();
        } else if (this.serviceActive) {
          this.startStatsPolling();
        }
      };
      document.addEventListener('visibilitychange', this._visibilityHandler);
    },
  };
}
