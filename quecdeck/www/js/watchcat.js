// Watchcat parameter defaults: initial form state, fetch fallbacks, and the
// Defaults button all read from here.
const WATCHCAT_DEFAULTS = {
  ips: ['8.8.8.8', '1.1.1.1', '9.9.9.9'],
  pingInterval: 30,
  pingFailureCount: 3,
  disableOnNoSim: true,
  rebootBackoff: true,
  logRestarts: true,
};

// Reboot-window severity levels, each with its badge label and class. The
// severity getter maps the current window onto one of these.
const WATCHCAT_SEVERITY = Object.freeze({
  RECKLESS:   { label: 'Very frequent', cls: 'text-bg-danger' },
  AGGRESSIVE: { label: 'Frequent',      cls: 'text-bg-warning text-dark' },
  RELAXED:    { label: 'Slow recovery', cls: 'text-bg-primary' },
  BALANCED:   { label: 'Balanced',   cls: 'text-bg-success' },
});

// Failed attempts before a target is called unresponsive. Fixed rather than
// pingFailureCount, which is the mid-edit form value and governs
// rounds-to-reboot, a different question.
const WATCHCAT_STALE_MISSES = 3;

// Per-target reachability, each with its badge label and class. targetState()
// maps a stats row onto one of these. MISSING relabels itself with the count.
const WATCHCAT_TARGET_STATE = Object.freeze({
  UNTESTED:   { label: 'Not checked',    cls: 'text-bg-secondary' },
  RESPONDING: { label: 'Responding',     cls: 'text-bg-success' },
  MISSING:    { label: 'Missing',        cls: 'text-bg-warning text-dark' },
  STALE:      { label: 'Not responding', cls: 'text-bg-danger' },
});

function quecdeckWatchCat() {
  return {
    // Watchcat
    enabled: false,
    ips: [...WATCHCAT_DEFAULTS.ips],
    pingInterval: WATCHCAT_DEFAULTS.pingInterval,
    pingFailureCount: WATCHCAT_DEFAULTS.pingFailureCount,
    // The running daemon's failure-evidence threshold. Reboot frequency is
    // limited separately by retryAfter once an attempt has been made.
    failureThreshold: WATCHCAT_DEFAULTS.pingFailureCount,
    disableOnNoSim: WATCHCAT_DEFAULTS.disableOnNoSim,
    rebootBackoff: WATCHCAT_DEFAULTS.rebootBackoff,
    logRestarts: WATCHCAT_DEFAULTS.logRestarts,
    serviceActive: false,
    isLoading: false,
    response: '',
    stats: [],
    consecutiveFailures: 0,
    paused: false,
    rebootCount: 0,
    retryAfter: 0,
    statsUpdatedAt: '',
    statsTimer: null,
    statsFetching: false,
    responseTimer: null,

    // Guaranteed minimum from the first failed round to the reboot attempt.
    // A failed ping can return immediately (for example, network unreachable),
    // so only the configured gaps between rounds are a dependable safety bound.
    get rebootWindowSec() {
      return Math.max(0, this.pingFailureCount - 1) * this.pingInterval;
    },

    // Human-readable reboot window, e.g. "90 sec" or "3 min".
    get rebootWindowLabel() {
      const s = this.rebootWindowSec;
      return s >= 60 ? Math.round(s / 60) + ' min' : s + ' sec';
    },

    get retryAfterLabel() {
      const seconds = Math.max(0, Number(this.retryAfter) || 0);
      if (seconds < 60) return `${seconds} sec`;
      if (seconds < 3600) return `${Math.ceil(seconds / 60)} min`;
      const hours = Math.floor(seconds / 3600);
      const minutes = Math.ceil((seconds % 3600) / 60);
      return minutes > 0 ? `${hours} hr ${minutes} min` : `${hours} hr`;
    },

    // Under 40s from the first failed round to reboot.
    get reckless() {
      return this.rebootWindowSec < 40;
    },

    // Under a minute (reckless or aggressive): shows the warning bullet.
    get tooAggressive() {
      return this.rebootWindowSec < 60;
    },

    // 10 minutes or more before rebooting: slow to recover from a real outage.
    get relaxed() {
      return this.rebootWindowSec >= 600;
    },

    // Smallest interval that reaches a full 60s window at the current failure
    // count and target list, so the warning can point at a concrete safer
    // value. Never below the form's own floor, or it would suggest a setting
    // that cannot be saved.
    get safeInterval() {
      const rounds = this.pingFailureCount;
      const gaps = Math.max(1, rounds - 1);
      return Math.max(10, Math.ceil(60 / gaps));
    },

    // Severity badge shown beside the summary heading.
    get severity() {
      if (this.reckless)      return WATCHCAT_SEVERITY.RECKLESS;
      if (this.tooAggressive) return WATCHCAT_SEVERITY.AGGRESSIVE;
      if (this.relaxed)       return WATCHCAT_SEVERITY.RELAXED;
      return WATCHCAT_SEVERITY.BALANCED;
    },

    // Reachability of one stats row. STALE requires the link to be up now
    // (consecutiveFailures 0), so a real outage marks no target dead and the
    // reboot path owns it. A single configured target therefore never reaches
    // STALE: if it is down, the whole round is down.
    targetState(row) {
      const miss = Number(row.miss);
      // Negative is the daemon's "not contacted yet" sentinel, and a value we
      // cannot read is equally not evidence. Neither may claim Responding.
      if (!Number.isFinite(miss) || miss < 0) return WATCHCAT_TARGET_STATE.UNTESTED;
      if (miss === 0) return WATCHCAT_TARGET_STATE.RESPONDING;
      if (this.consecutiveFailures === 0 && miss >= WATCHCAT_STALE_MISSES) {
        return WATCHCAT_TARGET_STATE.STALE;
      }
      return WATCHCAT_TARGET_STATE.MISSING;
    },

    // Only MISSING carries its count: there it says how close the target is to
    // the cutoff. Once a target is declared unresponsive the number stops being
    // actionable, so the badge stands alone.
    targetLabel(row) {
      const state = this.targetState(row);
      if (state !== WATCHCAT_TARGET_STATE.MISSING) return state.label;
      const miss = Number(row.miss) || 0;
      return miss === 1 ? '1 miss' : `${miss} misses`;
    },

    isValidIp(ip) {
      const parts = ip.trim().split('.');
      return parts.length === 4 && parts.every((part) => (
        part !== '' && /^\d+$/.test(part) && Number(part) <= 255
      ));
    },

    get validIps() {
      return this.ips.filter((ip) => this.isValidIp(ip));
    },

    get allIpsValid() {
      return this.ips.every((ip) => ip.trim() === '' || this.isValidIp(ip));
    },

    canAddIp() {
      if (this.ips.length >= 6) return false;
      return this.isValidIp(this.ips[this.ips.length - 1]);
    },

    get canSave() {
      if (!this.enabled) return true;
      return (
        this.validIps.length > 0 &&
        this.allIpsValid &&
        this.pingInterval >= 10 &&
        this.pingInterval <= 600 &&
        this.pingFailureCount >= 3 &&
        this.pingFailureCount <= 10
      );
    },

    addIp() {
      if (this.ips.length < 6) this.ips.push('');
    },

    // Resets the form fields only. The enable switch is untouched and nothing
    // is applied until Save.
    restoreDefaults() {
      this.ips = [...WATCHCAT_DEFAULTS.ips];
      this.pingInterval = WATCHCAT_DEFAULTS.pingInterval;
      this.pingFailureCount = WATCHCAT_DEFAULTS.pingFailureCount;
      this.disableOnNoSim = WATCHCAT_DEFAULTS.disableOnNoSim;
      this.rebootBackoff = WATCHCAT_DEFAULTS.rebootBackoff;
      this.logRestarts = WATCHCAT_DEFAULTS.logRestarts;
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
            // The streak is not zeroed here. The maker only clears it when the
            // config actually changed, so a re-save of identical settings (the
            // repair path) would blank a count the daemon still holds. The stats
            // poll is the one source of truth for it.
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
            this.serviceActive = data.service_active === true;
            this.ips = data.track_ips && data.track_ips.length > 0 ? data.track_ips : [...WATCHCAT_DEFAULTS.ips];
            this.pingInterval = data.ping_interval || WATCHCAT_DEFAULTS.pingInterval;
            this.pingFailureCount = data.ping_failure_count || WATCHCAT_DEFAULTS.pingFailureCount;
            // Seed until the first stats poll reports the daemon's live value.
            this.failureThreshold = this.pingFailureCount;
            this.disableOnNoSim = data.disable_on_no_sim !== false;
            this.rebootBackoff = data.reboot_backoff !== false;
            this.logRestarts = data.log_restarts !== false;
          }
        });
    },

    fetchStats() {
      if (this.statsFetching) return;
      this.statsFetching = true;
      fetchWithTimeout(fetchJSON, '/cgi-bin/get_watchcat_stats', 4000)
        .then((data) => {
          // The daemon holds off while a cell scan or APN reconnect has the
          // connection down on purpose. Without this the panel just freezes
          // mid-scan with no explanation for the stalled counters.
          // Assigned outside the guard below: the maker deletes the stats file on
          // every config change, so an absent payload means no round has finished
          // yet, not that a pause is still in force. Left inside, a save made
          // during a scan would strand the banner until the next round lands.
          this.paused = !!(data && data.paused === true);
          // A config change removes the old stats file. Clear the displayed
          // deadline with that empty payload instead of carrying a stale block
          // notice until the daemon finishes its first new round.
          this.retryAfter = (data && data.retry_after) || 0;
          if (data && data.stats) {
            this.stats = data.stats;
            this.consecutiveFailures = data.consecutive_failures || 0;
            this.rebootCount = data.reboot_count || 0;
            this.failureThreshold = data.failure_threshold || this.pingFailureCount;
            this.statsUpdatedAt = new Date().toLocaleString([], { hour12: false });
          }
        })
        .catch(() => {})
        .finally(() => { this.statsFetching = false; });
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

    init() {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 4000);
      this.fetchSettings(controller.signal).then(() => {
        clearTimeout(timer);
        if (this.serviceActive) this.startStatsPolling();
      }).catch(() => {
        clearTimeout(timer);
        this.$store.errorModal.open('Failed to load settings.');
      });
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
