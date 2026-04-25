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
    dnsPrimary: "-",
    dnsSecondary: "-",
    dnsIPv6Primary: "-",
    dnsIPv6Secondary: "-",
    phoneNumber: "Unknown",
    upnpEnabled: false,
    services: null,

    fetchATCommand() {
      authFetch("/cgi-bin/get_device_info", {
        method: "POST",
      })
        .then((res) => {
          return res.text();
        })
        .then((data) => {
          this.parseFetchedData(data);
        })
        .catch(() => {
          this.$store.errorModal.open('Failed to load device information. Please refresh the page.');
        });
    },

    parseFetchedData(atCommandResponse) {
      // Search for fields by prefix rather than fixed line offsets so that
      // any stale bytes at the start of the response (URCs, incomplete
      // previous response) don't shift every field and cause wrong data.
      //
      // Command order: CGMI, CGMM, QGMR (bare strings), CIMI (digits),
      // ICCID (prefixed), CGSN/IMEI (15-digit), QMAP (prefixed), CNUM (prefixed).
      //
      // +ICCID: is the preferred pivot. When no SIM is present, CIMI/ICCID/CNUM
      // all return ERROR, so we fall back to the IMEI line as the pivot instead.
      // This ensures manufacturer, model, and firmware still parse without a SIM.
      const lines = atCommandResponse.split("\n")
        .map(l => l.trim())
        .filter(l => l !== "");

      // --- Fields with known response prefixes ---
      const iccidLine = lines.find(l => l.startsWith("+ICCID:"));
      const cnumLine  = lines.find(l => l.startsWith("+CNUM:"));
      const qmapLines = lines.filter(l => l.startsWith("+QMAP:"));
      const imeiLine  = lines.find(l => /^\d{15}$/.test(l));

      if (iccidLine)    this.iccid = iccidLine.replace(/^\+ICCID:\s*/, "");
      if (imeiLine)     this.imei  = imeiLine;
      if (qmapLines[0]) this.wwanIpv4 = cleanIp(qmapLines[0].split(",")[4]?.replace(/"/g, ""));
      if (qmapLines[1]) this.wwanIpv6 = cleanIp(qmapLines[1].split(",")[4]?.replace(/"/g, ""));

      // --- Manufacturer, model, firmware: bare text lines before the pivot ---
      // Prefer +ICCID: as pivot; fall back to the IMEI line when no SIM is present.
      // Exclude echo (starts with AT), prefixed responses (+), digit-only lines,
      // OK, and ERROR — so stale or error data can't slip into these fields.
      const pivotLine = iccidLine ?? imeiLine;
      const pivotIdx  = pivotLine ? lines.indexOf(pivotLine) : -1;
      if (pivotIdx > 0) {
        const bareLines = lines
          .slice(0, pivotIdx)
          .filter(l => !l.startsWith("+") && !l.startsWith("AT") && !/^\d+$/.test(l) && l !== "OK" && l !== "ERROR");
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

      // --- Build time from +CVERSION: line matching "Mon DD YYYY HH:MM:SS" ---
      const buildTimeLine = lines.find(l => /^[A-Z][a-z]{2} +\d{1,2} +\d{4}/.test(l));
      if (buildTimeLine) this.buildTime = buildTimeLine.trim();

      // --- DNS from +CGCONTRDP: cid,bearer,apn,addr/mask,gw,dns1,dns2,... ---
      // On dual-stack bearers Quectel returns IPv6 addresses in 16-byte
      // dotted-decimal notation (e.g. "254.128.0.0...0.0.1") and may pack
      // both IPv4 and IPv6 into a single comma field separated by a space.
      // Extract only standard 4-octet IPv4 addresses by taking the first
      // whitespace-delimited token of each field from index 5 onwards.
      const cgcontrdpLine = lines.find(l => l.startsWith("+CGCONTRDP:"));
      if (cgcontrdpLine) {
        const parts = cgcontrdpLine.replace(/^\+CGCONTRDP:\s*/, "").split(",").map(p => p.replace(/"/g, "").trim());
        const ipv4Re    = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;
        const ipv6ByteRe = /^(\d{1,3}\.){15}\d{1,3}$/;
        const tokens = parts.slice(5).flatMap(p => p.split(/\s+/));
        const dnsAddrs    = tokens.filter(p => ipv4Re.test(p));
        const dnsIPv6Addrs = tokens.filter(p => ipv6ByteRe.test(p)).map(dotByteToIPv6).filter(Boolean);
        if (dnsAddrs[0])    this.dnsPrimary      = dnsAddrs[0];
        if (dnsAddrs[1])    this.dnsSecondary    = dnsAddrs[1];
        if (dnsIPv6Addrs[0]) this.dnsIPv6Primary   = dnsIPv6Addrs[0];
        if (dnsIPv6Addrs[1]) this.dnsIPv6Secondary = dnsIPv6Addrs[1];
      }

      // --- IMSI: bare digit-only line before the pivot ---
      try {
        if (pivotIdx > 0) {
          const imsiLine = lines
            .slice(0, pivotIdx)
            .find(l => /^\d{10,16}$/.test(l));
          if (imsiLine) this.imsi = imsiLine;
        }

        // --- Phone number from +CNUM: ---
        if (cnumLine) {
          const phone = cnumLine.split(",")[1]?.replace(/"/g, "");
          this.phoneNumber = (phone && phone !== "") ? phone : "Unknown";
        } else {
          this.phoneNumber = "No SIM Card Inserted or Detected";
          this.imsi = " ";
          this.iccid = " ";
        }
      } catch (error) {
        this.phoneNumber = "No SIM Card Inserted or Detected";
        this.imsi = " ";
        this.iccid = " ";
      }
    },

    fetchServiceStatus() {
      authFetch("/cgi-bin/get_service_status")
        .then((r) => r.json())
        .then((data) => { this.services = data; })
        .catch(() => {});
    },


    fetchUpnpStatus() {
      authFetch('/cgi-bin/get_upnp_status')
        .then((r) => r.json())
        .then((data) => { this.upnpEnabled = data.upnp === true; })
        .catch(() => {});
    },

    init() {
      this.fetchATCommand();
      authFetch('/cgi-bin/get_set_lanip').then(r => r.json()).then(data => { this.lanIp = data.lan_ip; }).catch(() => {});
      this.fetchUpnpStatus();
      this.fetchServiceStatus();
    },
  };
}
