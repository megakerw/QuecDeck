// Connection-log event types: badge label and class per type. connDetail
// builds the per-event detail string separately (it is not a simple lookup).
const CONN_EVENTS = Object.freeze({
  connected:       { label: 'Connected',       cls: 'bg-success' },
  disconnected:    { label: 'Disconnected',    cls: 'bg-danger' },
  cell_change:     { label: 'Cell Change',     cls: 'bg-info text-dark' },
  operator_change: { label: 'Operator Change', cls: 'bg-warning text-dark' },
  mode_change:     { label: 'Mode Change',     cls: 'bg-warning text-dark' },
  band_change:     { label: 'Band Change',     cls: 'bg-primary' },
  cell_scan_start: { label: 'Scan Start',      cls: 'bg-secondary' },
  cell_scan_end:   { label: 'Scan End',        cls: 'bg-secondary' },
});

// Access-log event types: badge label and class per type.
const ACCESS_EVENTS = Object.freeze({
  login_success:      { label: 'Login',             cls: 'bg-success' },
  login_failure:      { label: 'Failed Login',      cls: 'bg-warning text-dark' },
  login_locked:       { label: 'Lockout',           cls: 'bg-danger' },
  logout:             { label: 'Logout',            cls: 'bg-secondary' },
  dev_unlock_success: { label: 'Dev Unlock',        cls: 'bg-success' },
  dev_unlock_failure: { label: 'Failed Dev Unlock', cls: 'bg-warning text-dark' },
  dev_unlock_locked:  { label: 'Dev Lockout',       cls: 'bg-danger' },
});

function logsPage() {
  return {
    connectionEvents: [],
    accessEvents: [],
    restartEvents: [],
    atcmdEvents: [],
    loadingConn: false,
    loadingAccess: false,
    loadingRestart: false,
    loadingAtcmd: false,
    connUpdatedAt: '',
    accessUpdatedAt: '',
    refreshTimer: null,

    formatTs(ts) {
      return new Date(ts * 1000).toLocaleString([], { hour12: false });
    },

    // Timestamps below come from the device's own clock, which may never
    // have synced (e.g. no tower for NITZ/NTP). Flag anything implausibly
    // old as a sign the clock isn't synced, so the UI can warn the user.
    get clockUnsynced() {
      const MIN_PLAUSIBLE_TS = 1700000000; // 2023-11-14, well before this feature existed
      return [...this.connectionEvents, ...this.accessEvents, ...this.restartEvents, ...this.atcmdEvents]
        .some((ev) => ev.ts && ev.ts < MIN_PLAUSIBLE_TS);
    },

    // Daemon log lines are plain text: "<epoch> atclid: <message>".
    parseAtcmdLine(line) {
      const m = line.match(/^(\d+) atclid: (.*)$/);
      if (m) return { ts: parseInt(m[1], 10), msg: m[2] };
      return { ts: 0, msg: line };
    },

    connBadgeClass(type) {
      return (CONN_EVENTS[type] || {}).cls || 'bg-secondary';
    },

    connLabel(type) {
      return (CONN_EVENTS[type] || {}).label || type;
    },

    connDetail(ev) {
      switch (ev.type) {
        case 'connected':
          if (ev.cell_id) {
            return ev.mode + ' | Cell: ' + ev.cell_id + ' | PCI: ' + ev.pci + ' | Band: ' + ev.band + ' | EARFCN: ' + ev.earfcn;
          }
          return ev.mode || '';
        case 'disconnected':
          return 'Last mode: ' + (ev.prev_mode || '—');
        case 'cell_change': {
          const cellRef = c => c.cell_id ? c.cell_id + ':' + c.pci : '—';
          const modePrefix = ev.mode ? ev.mode + ' | ' : '';
          const cellStr = cellRef(ev.from) + ' → ' + cellRef(ev.to);
          const radioStr = ev.to.cell_id ? ' | Band: ' + ev.to.band + ' | EARFCN: ' + ev.to.earfcn : '';
          return modePrefix + cellStr + radioStr;
        }
        case 'mode_change': {
          const fromMode = ev.from || '—';
          const toMode   = ev.to   || '—';
          const cellPci  = ev.cell_id ? ' | Cell: ' + ev.cell_id + ' | PCI: ' + ev.pci : '';
          return fromMode + ' → ' + toMode + cellPci;
        }
        case 'operator_change': {
          const modePrefix = ev.mode ? ev.mode + ' | ' : '';
          const cellPci    = ev.cell_id ? ' | Cell: ' + ev.cell_id + ' | PCI: ' + ev.pci : '';
          return modePrefix + ev.from + ' → ' + ev.to + cellPci;
        }
        case 'band_change':
          return (ev.mode || '') + ' | Cell: ' + ev.cell_id + ' | PCI: ' + ev.pci + ' | Band ' + ev.from + ' → ' + ev.to;
        case 'cell_scan_start':
          return 'Cell scan started' + (ev.watchcat_paused ? ' (watchcat paused)' : '');
        case 'cell_scan_end':
          return 'Cell scan complete' + (ev.watchcat_paused ? ' (watchcat resumed)' : '');
        default:
          return '';
      }
    },

    accessBadgeClass(type) {
      return (ACCESS_EVENTS[type] || {}).cls || 'bg-secondary';
    },

    accessLabel(type) {
      return (ACCESS_EVENTS[type] || {}).label || type;
    },

    accessDetail(ev) {
      const parts = [];
      if (ev.user) parts.push('User: ' + ev.user);
      if (ev.ip) {
        const isPrivate = /^10\./.test(ev.ip)
          || /^192\.168\./.test(ev.ip)
          || /^172\.(1[6-9]|2\d|3[01])\./.test(ev.ip)
          || /^127\./.test(ev.ip);
        const local = isPrivate || (ev.wan_ip && ev.ip === ev.wan_ip);
        parts.push((local ? 'Local' : 'External') + ' (' + ev.ip + ')');
      }
      return parts.join(' | ');
    },

    refreshRestart() {
      this.loadingRestart = true;
      fetchJSON('/cgi-bin/get_restart_log')
        .then((data) => { this.restartEvents = data.slice().reverse(); })
        .catch(() => this.$store.errorModal.open('Failed to load restart log.'))
        .finally(() => { this.loadingRestart = false; });
    },

    clearRestartLog() {
      this.$store.confirmModal.open(
        'Clear the restart history?',
        () => {
          authFetch('/cgi-bin/clear_restart_log', { method: 'POST' })
            .then(() => { this.restartEvents = []; })
            .catch(() => this.$store.errorModal.open('Failed to clear restart log.'));
        }
      );
    },

    // One fetch serves all panels; the flags pick which parts to apply so a
    // per-panel Refresh doesn't clobber the other panels' timestamps.
    refreshLogs(conn, access, atcmd) {
      if (conn) this.loadingConn = true;
      if (access) this.loadingAccess = true;
      if (atcmd) this.loadingAtcmd = true;
      fetchJSON('/cgi-bin/get_logs')
        .then((data) => {
          const ts = new Date().toLocaleString([], { hour12: false });
          if (conn) {
            this.connectionEvents = (data.connection_events || []).slice().reverse();
            this.connUpdatedAt = ts;
          }
          if (access) {
            this.accessEvents = (data.access_events || []).slice().reverse();
            this.accessUpdatedAt = ts;
          }
          if (atcmd) {
            this.atcmdEvents = (data.atcmd_log || []).map((l) => this.parseAtcmdLine(l)).reverse();
          }
        })
        .catch(() => this.$store.errorModal.open('Failed to load logs.'))
        .finally(() => {
          if (conn) this.loadingConn = false;
          if (access) this.loadingAccess = false;
          if (atcmd) this.loadingAtcmd = false;
        });
    },

    refreshConnection() { this.refreshLogs(true, false, false); },
    refreshAccess()     { this.refreshLogs(false, true, false); },
    refreshAtcmd()      { this.refreshLogs(false, false, true); },
    refresh()           { this.refreshLogs(true, true, true); },

    init() {
      this.refresh();
      this.refreshRestart();
      this.refreshTimer = setInterval(() => this.refresh(), 30000);
      if (this._visibilityHandler) {
        document.removeEventListener('visibilitychange', this._visibilityHandler);
      }
      this._visibilityHandler = () => {
        if (document.hidden) {
          clearInterval(this.refreshTimer);
          this.refreshTimer = null;
        } else {
          this.refresh();
          this.refreshTimer = setInterval(() => this.refresh(), 30000);
        }
      };
      document.addEventListener('visibilitychange', this._visibilityHandler);
    },
  };
}
