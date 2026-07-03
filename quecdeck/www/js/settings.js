function quecdeckSettings() {
  return {
    isLoading: false,
    dnsV4ProxyStatus: null,
    dnsV6ProxyStatus: null,
    ipptEnabled: null,
    autoConnectEnabled: null,
    gnssEnabled: null,
    simDetEnabled: null,
    lanIp: "",
    dhcpStart: "",
    dhcpEnd: "",
    syncDhcpPrefix() {
      const parts = this.lanIp.split('.');
      if (parts.length === 4 && parts.slice(0, 3).every(p => p !== '' && !isNaN(p) && +p <= 255)) {
        const prefix = parts.slice(0, 3).join('.');
        const startLast = this.dhcpStart.split('.').pop();
        const endLast = this.dhcpEnd.split('.').pop();
        this.dhcpStart = prefix + '.' + (startLast || '20');
        this.dhcpEnd = prefix + '.' + (endLast || '170');
      }
    },

    sendSetting(action) {
      return postForm('/cgi-bin/set_setting', { action });
    },

    // Simple on/off settings: action name is "<key>_enable" / "<key>_disable",
    // prop is the state flag to set on success, label appears in error text.
    toggles: {
      dns_v4: { prop: 'dnsV4ProxyStatus', label: 'DNS proxy' },
      dns_v6: { prop: 'dnsV6ProxyStatus', label: 'IPv6 DNS proxy' },
      autoconnect: { prop: 'autoConnectEnabled', label: 'auto-connect' },
      gnss: { prop: 'gnssEnabled', label: 'GNSS' },
      simdet: { prop: 'simDetEnabled', label: 'SIM hot swap' },
    },

    toggleSetting(key) {
      const t = this.toggles[key];
      const enable = !this[t.prop];
      this.sendSetting(`${key}_${enable ? 'enable' : 'disable'}`)
        .then(() => { this[t.prop] = enable; })
        .catch(() => this.$store.errorModal.open(
          `Failed to ${enable ? 'enable' : 'disable'} ${t.label}. Please try again.`
        ));
    },

    rebootDevice() {
      this.$store.confirmModal.open(
        'This will reboot the modem.',
        () => {
          this.sendSetting('reboot').catch(() => {});
          this.$store.waitModal.start("Rebooting...", REBOOT_WAIT_SECS, () => this.init());
        },
        'Reboot'
      );
    },

    applyIpptChange(action) {
      this.isLoading = true;
      this.$store.waitModal.start('Rebooting modem...', REBOOT_WAIT_SECS + 5, () => {
        this.isLoading = false;
        this.fetchCurrentSettings();
      });
      // The QMAP command resets the network stack, so the HTTP connection may
      // drop before a response arrives. The CGI schedules AT+CFUN=1,1 server-side
      // so the modem reboots regardless. Swallow any network error here.
      this.sendSetting(action).catch(() => {});
    },

    ipptEnable() {
      this.$store.confirmModal.open(
        'Enabling IPPT will reboot the modem.',
        () => this.applyIpptChange('ippt_enable'),
        'Enable IPPT?'
      );
    },

    ipptDisable() {
      this.$store.confirmModal.open(
        'Disabling IPPT will reboot the modem.',
        () => this.applyIpptChange('ippt_disable'),
        'Disable IPPT?'
      );
    },

    fetchCurrentSettings() {
      fetchText("/cgi-bin/get_settings", { method: "POST" })
        .then((data) => {
          const currentData = data.split("\n");

          const dnsV4Line = currentData.find(l => l.includes('+QMAP: "DHCPV4DNS"'));
          this.dnsV4ProxyStatus = !!(dnsV4Line && dnsV4Line.includes('"enable"'));

          const dnsV6Line = currentData.find(l => l.includes('+QMAP: "DHCPV6DNS"'));
          this.dnsV6ProxyStatus = !!(dnsV6Line && dnsV6Line.includes('"enable"'));

          const autoConnectLine = currentData.find(line => line.includes('+QMAPWAC:'));
          this.autoConnectEnabled = !!(autoConnectLine && autoConnectLine.trim().split(":")[1]?.trim() === '1');

          const gnssLine = currentData.find(line => line.includes('+QGPS:'));
          this.gnssEnabled = !!(gnssLine && gnssLine.trim().split(":")[1]?.trim() === '1');

          const simDetLine = currentData.find(line => line.includes('+QSIMDET:'));
          this.simDetEnabled = !!(simDetLine && simDetLine.split(':')[1]?.trim().split(',')[1]?.trim() === '1');

        })
        .catch(() => {
          this.$store.errorModal.open('Failed to load settings. Please refresh the page.');
        });
    },

    fetchLanConfig() {
      fetchJSON('/cgi-bin/get_set_lanip')
        .then((data) => {
          this.lanIp = data.lan_ip;
          this.dhcpStart = data.dhcp_start;
          this.dhcpEnd = data.dhcp_end;
        })
        .catch(() => {
          this.$store.errorModal.open('Failed to load settings. Please refresh the page.');
        });
      fetchJSON('/cgi-bin/get_ippt_status')
        .then((data) => { this.ipptEnabled = data.ippt_enabled === true; })
        .catch(() => { this.ipptEnabled = false; });
    },

    confirmLanChange() {
      this.$store.confirmModal.open(
        'The modem will reboot. You will be redirected to:',
        () => this.setLanConfig(),
        'Change LAN IP?',
        `https://${this.lanIp}`
      );
    },

    setLanConfig() {
      this.isLoading = true;
      const newIp = this.lanIp;
      this.$store.waitModal.start('Rebooting...', REBOOT_WAIT_SECS + 5, () => {
        window.location.href = 'https://' + newIp + '/';
      }, `Redirecting to https://${newIp}`);
      fetchJSON('/cgi-bin/get_set_lanip', {
        method: 'POST',
        body: new URLSearchParams({
          lan_ip: this.lanIp,
          dhcp_start: this.dhcpStart,
          dhcp_end: this.dhcpEnd,
        }),
      })
        .then((data) => {
          if (!data.ok) {
            this.$store.waitModal.stop();
            this.isLoading = false;
            this.$store.errorModal.open(data.error || 'Failed to apply LAN configuration.');
          }
        })
        .catch(() => {
          // Connection drop here is expected: the device reboots when
          // the LAN IP changes. Only surface an error if the wait modal
          // isn't already running (i.e. something failed before the
          // reboot was triggered).
          if (!this.$store.waitModal.show) {
            this.isLoading = false;
            this.$store.errorModal.open('Request failed. Check your connection and try again.');
          }
        });
    },

    init() {
      this.fetchCurrentSettings();
      this.fetchLanConfig();
    },
  };
}
