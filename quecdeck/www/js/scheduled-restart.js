function quecdeckScheduledRestart() {
  return {
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


    // Parse "+0530" or "-0500" → offset in minutes from UTC
    parseTzOffset(str) {
      if (!str || str.length < 5) return 0;
      const sign = str[0] === '-' ? -1 : 1;
      const h = parseInt(str.slice(1, 3), 10);
      const m = parseInt(str.slice(3, 5), 10);
      return sign * (h * 60 + m);
    },

    // Shift (hour, minute, day) by deltaMins, wrapping across midnight.
    shiftTime(hour, minute, day, deltaMins) {
      let total = hour * 60 + minute + deltaMins;
      const dayShift = Math.floor(total / 1440);
      total = ((total % 1440) + 1440) % 1440;
      return {
        hour: Math.floor(total / 60),
        minute: total % 60,
        day: ((day - 1 + dayShift + 7) % 7) + 1,
      };
    },

    // Convert device-local (hour, minute, day) → browser-local
    deviceToLocal(hour, minute, day) {
      const userOffsetMins = -new Date().getTimezoneOffset();
      return this.shiftTime(hour, minute, day, userOffsetMins - this.srDeviceTzOffsetMins);
    },

    // Convert browser-local (hour, minute, day) → device-local
    localToDevice(hour, minute, day) {
      const userOffsetMins = -new Date().getTimezoneOffset();
      return this.shiftTime(hour, minute, day, this.srDeviceTzOffsetMins - userOffsetMins);
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


    fetchScheduledRestart(signal) {
      return fetchJSON('/cgi-bin/get_scheduled_restart', signal ? { signal } : {})
        .then((data) => {
          if (data) {
            this.srEnabled = data.enabled === true;
            this.srServiceActive = data.service_active === true;
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
      this.fetchScheduledRestart(controller.signal)
        .then(() => {
          clearTimeout(timer);
        })
        .catch(() => {
          clearTimeout(timer);
          this.$store.errorModal.open('Failed to load scheduled restart settings.');
        });
    },
  };
}
