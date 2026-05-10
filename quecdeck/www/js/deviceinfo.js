function dotByteToIPv6(str) {
  const bytes = str.split('.').map(Number);
  if (bytes.length !== 16 || bytes.some(b => isNaN(b) || b < 0 || b > 255)) return null;
  const groups = [];
  for (let i = 0; i < 16; i += 2) groups.push((bytes[i] << 8 | bytes[i + 1]).toString(16));
  let best = { start: -1, len: 0 }, cur = { start: -1, len: 0 };
  for (let i = 0; i < 8; i++) {
    if (groups[i] === '0') {
      if (cur.start === -1) cur = { start: i, len: 1 }; else cur.len++;
      if (cur.len > best.len) best = { ...cur };
    } else { cur = { start: -1, len: 0 }; }
  }
  if (best.len > 1) {
    const left = groups.slice(0, best.start).join(':');
    const right = groups.slice(best.start + best.len).join(':');
    return (left ? left + '::' : '::') + right;
  }
  return groups.join(':');
}

function fetchDeviceInfo() {
  return {
    manufacturer: "-",
    modelName: "-",
    firmwareVersion: "-",
    buildTime: "-",
    imsi: "-",
    iccid: "-",
    imei: "-",
    lanIp: "-",
    wwanIpv4: "-",
    wwanIpv6: "-",
    dnsIPv4Primary: "-",
    dnsIPv4Secondary: "-",
    dnsIPv6Primary: "-",
    dnsIPv6Secondary: "-",
    phoneNumber: "Unknown",
    upnpEnabled: false,
    services: null,

    fetchATCommand() {
      fetchText("/cgi-bin/get_device_info", { method: "POST" })
        .then(data => this.parseDeviceData(data))
        .catch(() => this.$store.errorModal.open('Failed to load device information. Please refresh the page.'));

      fetchText("/cgi-bin/get_device_sim", { method: "POST" })
        .then(data => this.parseSimData(data))
        .catch(() => {});

      fetchText("/cgi-bin/get_device_conn", { method: "POST" })
        .then(data => this.parseConnData(data))
        .catch(() => {});
    },

    parseDeviceData(atCommandResponse) {
      const lines = atCommandResponse.split("\n")
        .map(l => l.trim())
        .filter(l => l !== "");

      const imeiLine = lines.find(l => /^\d{15}$/.test(l));
      if (imeiLine) this.imei = imeiLine;

      const buildTimeLine = lines.find(l => /^[A-Z][a-z]{2} +\d{1,2} +\d{4}/.test(l));
      if (buildTimeLine) this.buildTime = buildTimeLine.trim();

      const pivotIdx = imeiLine ? lines.indexOf(imeiLine) : -1;
      if (pivotIdx > 0) {
        const bareLines = lines
          .slice(0, pivotIdx)
          .filter(l => !l.startsWith("+") && !l.startsWith("AT") && !/^\d+$/.test(l) && l !== "OK" && l !== "ERROR" && !/^[A-Z][a-z]{2} +\d/.test(l));
        if (bareLines.length >= 3) {
          this.manufacturer    = bareLines[bareLines.length - 3];
          this.modelName       = bareLines[bareLines.length - 2];
          this.firmwareVersion = bareLines[bareLines.length - 1];
        } else if (bareLines.length === 2) {
          this.manufacturer = bareLines[0];
          this.modelName    = bareLines[1];
        } else if (bareLines.length === 1) {
          this.manufacturer = bareLines[0];
        }
      }
    },

    parseSimData(data) {
      const lines = data.split("\n").map(l => l.trim()).filter(l => l !== "");
      const iccidLine = lines.find(l => l.startsWith("+ICCID:"));
      const cnumLine  = lines.find(l => l.startsWith("+CNUM:"));

      if (cnumLine) {
        if (iccidLine) this.iccid = iccidLine.replace(/^\+ICCID:\s*/, "");
        const phone = cnumLine.split(",")[1]?.replace(/"/g, "");
        this.phoneNumber = (phone && phone !== "") ? phone : "Unknown";
        const imsiLine = lines.find(l => /^\d{10,16}$/.test(l));
        if (imsiLine) this.imsi = imsiLine;
      } else {
        this.phoneNumber = "No SIM Card Inserted or Detected";
        this.imsi = " ";
        this.iccid = " ";
      }
    },

    parseConnData(data) {
      const lines = data.split("\n").map(l => l.trim()).filter(l => l !== "");

      const qmapLines = lines.filter(l => l.startsWith("+QMAP:"));
      if (qmapLines[0]) this.wwanIpv4 = cleanIp(qmapLines[0].split(",")[4]?.replace(/"/g, ""));
      if (qmapLines[1]) this.wwanIpv6 = cleanIp(qmapLines[1].split(",")[4]?.replace(/"/g, ""));

      const cgcontrdpLine = lines.find(l => l.startsWith("+CGCONTRDP:"));
      if (cgcontrdpLine) {
        const parts = cgcontrdpLine.replace(/^\+CGCONTRDP:\s*/, "").split(",").map(p => p.replace(/"/g, "").trim());
        const ipv4Re     = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;
        const ipv6ByteRe = /^(\d{1,3}\.){15}\d{1,3}$/;
        const tokens = parts.slice(5).flatMap(p => p.split(/\s+/));
        const dnsIPv4Addrs = tokens.filter(p => ipv4Re.test(p));
        const dnsIPv6Addrs = tokens.filter(p => ipv6ByteRe.test(p)).map(dotByteToIPv6).filter(
          addr => addr && !/^fe[89ab][0-9a-f]:/i.test(addr)
        );
        if (dnsIPv4Addrs[0]) this.dnsIPv4Primary   = dnsIPv4Addrs[0];
        if (dnsIPv4Addrs[1]) this.dnsIPv4Secondary = dnsIPv4Addrs[1];
        if (dnsIPv6Addrs[0]) this.dnsIPv6Primary   = dnsIPv6Addrs[0];
        if (dnsIPv6Addrs[1]) this.dnsIPv6Secondary = dnsIPv6Addrs[1];
      }
    },

    fetchServiceStatus() {
      fetchJSON("/cgi-bin/get_service_status")
        .then((data) => { this.services = data; })
        .catch(() => {});
    },

    fetchUpnpStatus() {
      fetchJSON('/cgi-bin/get_upnp_status')
        .then((data) => { this.upnpEnabled = data.upnp === true; })
        .catch(() => {});
    },

    init() {
      this.fetchATCommand();
      fetchJSON('/cgi-bin/get_set_lanip').then(data => { this.lanIp = data.lan_ip; }).catch(() => {});
      this.fetchUpnpStatus();
      this.fetchServiceStatus();
    },
  };
}
