function quecdeckSettings() {
  return {
    isLoading: false,
    dnsV4ProxyStatus: null,
    dnsV6ProxyStatus: null,
    ipptEnabled: null,
    autoConnectEnabled: null,
    gnssEnabled: null,
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
      return authFetch('/cgi-bin/set_setting', { method: 'POST', body: new URLSearchParams({ action }) })
        .then(r => r.text())
        .then(text => {
          if (text.includes('ERROR')) throw new Error(text.trim());
          return text;
        });
    },

    rebootDevice() {
      this.$store.confirmModal.open(
        'This will reboot the modem. Continue?',
        () => {
          this.sendSetting('reboot').catch(() => {});
          this.$store.waitModal.start("Rebooting...", REBOOT_WAIT_SECS, () => this.init());
        },
        'Reboot'
      );
    },

    onBoardDNSV4ProxyEnable() {
      this.sendSetting('dns_v4_enable').then(() => { this.dnsV4ProxyStatus = true; }).catch(() => this.$store.errorModal.open('Failed to enable DNS proxy. Please try again.'));
    },

    onBoardDNSV4ProxyDisable() {
      this.sendSetting('dns_v4_disable').then(() => { this.dnsV4ProxyStatus = false; }).catch(() => this.$store.errorModal.open('Failed to disable DNS proxy. Please try again.'));
    },

    onBoardDNSV6ProxyEnable() {
      this.sendSetting('dns_v6_enable').then(() => { this.dnsV6ProxyStatus = true; }).catch(() => this.$store.errorModal.open('Failed to enable IPv6 DNS proxy. Please try again.'));
    },

    onBoardDNSV6ProxyDisable() {
      this.sendSetting('dns_v6_disable').then(() => { this.dnsV6ProxyStatus = false; }).catch(() => this.$store.errorModal.open('Failed to disable IPv6 DNS proxy. Please try again.'));
    },

    applyIpptChange(action) {
      this.isLoading = true;
      this.$store.waitModal.start('Rebooting modem...', REBOOT_WAIT_SECS + 5, () => {
        this.isLoading = false;
        this.fetchCurrentSettings();
      });
      // The QMAP command resets the network stack, so the HTTP connection may
      // drop before a response arrives. The CGI schedules AT+CFUN=1,1 server-side
      // so the modem reboots regardless — swallow any network error here.
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

    autoConnectEnable() {
      this.sendSetting('autoconnect_enable').then(() => { this.autoConnectEnabled = true; }).catch(() => this.$store.errorModal.open('Failed to enable auto-connect. Please try again.'));
    },

    autoConnectDisable() {
      this.sendSetting('autoconnect_disable').then(() => { this.autoConnectEnabled = false; }).catch(() => this.$store.errorModal.open('Failed to disable auto-connect. Please try again.'));
    },

    gnssEnable() {
      this.sendSetting('gnss_enable').then(() => { this.gnssEnabled = true; }).catch(() => this.$store.errorModal.open('Failed to enable GNSS. Please try again.'));
    },

    gnssDisable() {
      this.sendSetting('gnss_disable').then(() => { this.gnssEnabled = false; }).catch(() => this.$store.errorModal.open('Failed to disable GNSS. Please try again.'));
    },

    fetchCurrentSettings() {
      authFetch("/cgi-bin/get_settings", {
        method: "POST",
      })
        .then((res) => {
          return res.text();
        })
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

        })
        .catch(() => {
          this.$store.errorModal.open('Failed to load settings. Please refresh the page.');
        });
    },

    fetchLanConfig() {
      authFetch('/cgi-bin/get_set_lanip')
        .then((r) => r.json())
        .then((data) => {
          this.lanIp = data.lan_ip;
          this.dhcpStart = data.dhcp_start;
          this.dhcpEnd = data.dhcp_end;
        })
        .catch(() => {
        this.$store.errorModal.open('Failed to load settings. Please refresh the page.');
      });
      authFetch('/cgi-bin/get_ippt_status')
        .then((r) => r.json())
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
      this.$store.waitModal.start(`Rebooting... Please wait, you will be automatically redirected to https://${newIp}`, REBOOT_WAIT_SECS + 5, () => {
        window.location.href = 'https://' + newIp + '/';
      });
      authFetch('/cgi-bin/get_set_lanip', {
        method: 'POST',
        body: new URLSearchParams({
          lan_ip: this.lanIp,
          dhcp_start: this.dhcpStart,
          dhcp_end: this.dhcpEnd,
        }),
      })
        .then((r) => r.json())
        .then((data) => {
          if (!data.ok) {
            this.$store.waitModal.stop();
            this.isLoading = false;
            this.$store.errorModal.open(data.error || 'Failed to apply LAN configuration.');
          }
        })
        .catch(() => {
          // Connection drop here is expected — the device reboots when
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
