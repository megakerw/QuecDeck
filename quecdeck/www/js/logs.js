function logsPage() {
  return {
    connectionEvents: [],
    accessEvents: [],
    loadingConn: false,
    loadingAccess: false,
    connUpdatedAt: '',
    accessUpdatedAt: '',
    refreshTimer: null,

    formatTs(ts) {
      return new Date(ts * 1000).toLocaleString([], { hour12: false });
    },

    connBadgeClass(type) {
      switch (type) {
        case 'connected':      return 'bg-success';
        case 'disconnected':   return 'bg-danger';
        case 'cell_change':    return 'bg-info text-dark';
        case 'mode_change':    return 'bg-warning text-dark';
        case 'band_change':    return 'bg-primary';
        case 'cell_scan_start':
        case 'cell_scan_end':  return 'bg-secondary';
        default:               return 'bg-secondary';
      }
    },

    connLabel(type) {
      switch (type) {
        case 'connected':      return 'Connected';
        case 'disconnected':   return 'Disconnected';
        case 'cell_change':    return 'Cell Change';
        case 'mode_change':    return 'Mode Change';
        case 'band_change':    return 'Band Change';
        case 'cell_scan_start': return 'Scan Start';
        case 'cell_scan_end':   return 'Scan End';
        default:               return type;
      }
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
        case 'band_change':
          return (ev.mode || '') + ' | Cell: ' + ev.cell_id + ' | PCI: ' + ev.pci + ' | Band ' + ev.from + ' → ' + ev.to;
        case 'cell_scan_start':
          return 'Cell scan started' + (ev.watchcat_paused ? ' — watchcat paused' : '');
        case 'cell_scan_end':
          return 'Cell scan complete' + (ev.watchcat_paused ? ' — watchcat resumed' : '');
        default:
          return '';
      }
    },

    accessBadgeClass(type) {
      switch (type) {
        case 'login_success':      return 'bg-success';
        case 'login_failure':      return 'bg-warning text-dark';
        case 'login_locked':       return 'bg-danger';
        case 'logout':             return 'bg-secondary';
        case 'dev_unlock_success': return 'bg-success';
        case 'dev_unlock_failure': return 'bg-warning text-dark';
        case 'dev_unlock_locked':  return 'bg-danger';
        default:                   return 'bg-secondary';
      }
    },

    accessLabel(type) {
      switch (type) {
        case 'login_success':      return 'Login';
        case 'login_failure':      return 'Failed Login';
        case 'login_locked':       return 'Lockout';
        case 'logout':             return 'Logout';
        case 'dev_unlock_success': return 'Dev Unlock';
        case 'dev_unlock_failure': return 'Failed Dev Unlock';
        case 'dev_unlock_locked':  return 'Dev Lockout';
        default:                   return type;
      }
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

    refreshConnection() {
      this.loadingConn = true;
      authFetch('/cgi-bin/get_logs')
        .then((r) => r.json())
        .then((data) => {
          this.connectionEvents = (data.connection_events || []).slice().reverse();
          this.connUpdatedAt = new Date().toLocaleString([], { hour12: false });
        })
        .catch(() => this.$store.errorModal.open('Failed to load connection events.'))
        .finally(() => { this.loadingConn = false; });
    },

    refreshAccess() {
      this.loadingAccess = true;
      authFetch('/cgi-bin/get_logs')
        .then((r) => r.json())
        .then((data) => {
          this.accessEvents = (data.access_events || []).slice().reverse();
          this.accessUpdatedAt = new Date().toLocaleString([], { hour12: false });
        })
        .catch(() => this.$store.errorModal.open('Failed to load access events.'))
        .finally(() => { this.loadingAccess = false; });
    },

    refresh() {
      this.loadingConn = true;
      this.loadingAccess = true;
      authFetch('/cgi-bin/get_logs')
        .then((r) => r.json())
        .then((data) => {
          this.connectionEvents = (data.connection_events || []).slice().reverse();
          this.accessEvents     = (data.access_events     || []).slice().reverse();
          const ts = new Date().toLocaleString([], { hour12: false });
          this.connUpdatedAt   = ts;
          this.accessUpdatedAt = ts;
        })
        .catch(() => this.$store.errorModal.open('Failed to load logs.'))
        .finally(() => { this.loadingConn = false; this.loadingAccess = false; });
    },

    init() {
      this.refresh();
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
