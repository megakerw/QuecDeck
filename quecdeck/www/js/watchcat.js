function quecdeckWatchCat() {
  return {
    // Watchcat
    enabled: false,
    ips: ['8.8.8.8', '1.1.1.1', '9.9.9.9'],
    pingInterval: 30,
    pingFailureCount: 3,
    disableOnNoSim: true,
    serviceActive: false,
    isLoading: false,
    response: '',
    stats: [],
    consecutiveFailures: 0,
    statsUpdatedAt: '',
    statsTimer: null,
    statsFetching: false,

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

    get validIps() {
      return this.ips.filter((ip) => /^(\d{1,3}\.){3}\d{1,3}$/.test(ip.trim()));
    },

    canAddIp() {
      if (this.ips.length >= 6) return false;
      const parts = this.ips[this.ips.length - 1].trim().split('.');
      return parts.length === 4 && parts.every(o => o !== '' && +o >= 0 && +o <= 255);
    },

    get canSave() {
      return (
        this.validIps.length > 0 &&
        this.pingInterval >= 10 &&
        this.pingInterval <= 600 &&
        this.pingFailureCount >= 1 &&
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
      };
      this.validIps.forEach((ip, i) => {
        params[`TRACK_IP_${i + 1}`] = ip.trim();
      });
      return params;
    },

    saveSettings() {
      this.isLoading = true;
      this.response = '';
      authFetch('/cgi-bin/watchcat_maker', { method: 'POST', body: new URLSearchParams(this.buildParams()) })
        .then((r) => r.text())
        .then((data) => {
          this.response = this.enabled ? 'Saved.' : 'Disabled.';
          this.isLoading = false;
          this.fetchSettings();
        })
        .catch((err) => {
          this.response = 'Error: ' + err;
          this.isLoading = false;
        });
    },

    fetchSettings() {
      return authFetch('/cgi-bin/get_watchcat_status')
        .then((r) => r.json())
        .then((data) => {
          if (data && Object.keys(data).length > 0) {
            this.enabled = data.enabled === true;
            this.serviceActive = data.enabled === true;
            this.ips = data.track_ips && data.track_ips.length > 0 ? data.track_ips : ['8.8.8.8', '1.1.1.1', '9.9.9.9'];
            this.pingInterval = data.ping_interval || 30;
            this.pingFailureCount = data.ping_failure_count || 3;
            this.disableOnNoSim = data.disable_on_no_sim !== false;
          }
        })
        .catch(() => this.$store.errorModal.open('Failed to load watchcat settings.'));
    },

    fetchStats() {
      if (this.statsFetching) return;
      this.statsFetching = true;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 4000);
      authFetch('/cgi-bin/get_watchcat_stats', { signal: controller.signal })
        .then((r) => r.json())
        .then((data) => {
          if (data && data.stats) {
            this.stats = data.stats;
            this.consecutiveFailures = data.consecutive_failures || 0;
            const now = new Date();
            this.statsUpdatedAt = now.toLocaleString([], { hour12: false });
          }
        })
        .catch(() => {})
        .finally(() => { clearTimeout(timer); this.statsFetching = false; });
    },

    startStatsPolling() {
      this.stopStatsPolling();
      this.fetchStats();
      this.statsTimer = setInterval(() => this.fetchStats(), 2000);
    },

    stopStatsPolling() {
      if (this.statsTimer) {
        clearInterval(this.statsTimer);
        this.statsTimer = null;
      }
    },

    fetchScheduledRestart() {
      return authFetch('/cgi-bin/get_scheduled_restart')
        .then((r) => r.json())
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
        })
        .catch(() => this.$store.errorModal.open('Failed to load scheduled restart settings.'));
    },

    saveScheduledRestart() {
      this.srLoading = true;
      this.srResponse = '';
      const device = this.localToDevice(this.srHour, this.srMinute, this.srDay);
      const params = {
        ENABLED: this.srEnabled ? 'enable' : 'disable',
        TYPE: this.srType,
        DAY: device.day,
        HOUR: device.hour,
        MINUTE: device.minute,
      };
      authFetch('/cgi-bin/scheduled_restart_maker', { method: 'POST', body: new URLSearchParams(params) })
        .then((r) => r.text())
        .then((data) => {
          this.srResponse = this.srEnabled ? 'Saved.' : 'Disabled.';
          this.srLoading = false;
          this.fetchScheduledRestart();
        })
        .catch(() => {
          this.srLoading = false;
          this.$store.errorModal.open('Failed to save scheduled restart settings. Please try again.');
        });
    },

    init() {
      this.fetchSettings().then(() => {
        if (this.serviceActive) this.startStatsPolling();
      });
      this.fetchScheduledRestart();
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
