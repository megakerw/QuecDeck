const _css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();

const STATUS_COLOR_GREEN  = _css('--status-color-green');
const STATUS_COLOR_YELLOW = _css('--status-color-yellow');
const STATUS_COLOR_RED    = _css('--status-color-red');
const STATUS_COLOR_GREY   = _css('--status-color-grey');
const STATUS_COLOR_BLUE   = _css('--status-color-blue');

function fitStatCardTexts() {
  document.querySelectorAll('.stat-card .card-body').forEach(body => {
    const text = body.querySelector('.card-text');
    if (!text) return;
    text.style.fontSize = '';
    const available = body.clientWidth - 32;
    if (available <= 0) return;
    let size = Math.min(parseFloat(getComputedStyle(text).fontSize), 22.4);
    text.style.fontSize = size + 'px';
    while (text.scrollWidth > available && size > 10) {
      size--;
      text.style.fontSize = size + 'px';
    }
  });
}

document.addEventListener('alpine:initialized', () => {
  fitStatCardTexts();
  const _statCardObservers = [];
  document.querySelectorAll('.stat-card .card-text').forEach(el => {
    const obs = new MutationObserver(fitStatCardTexts);
    obs.observe(el, { childList: true, characterData: true, subtree: true });
    _statCardObservers.push(obs);
  });
  window.addEventListener('resize', fitStatCardTexts);
});

function processAllInfos() {
  return {
    isFetching: false,
    isPinging: false,
    isUpTimeFetching: false,
    isStatsFetching: false,
    internetConnectionStatus: "Disconnected",
    temperature: "0",
    simStatus: "No SIM",
    activeSim: "No SIM",
    networkProvider: "N/A",
    mccmnc: "00000",
    apn: "Unknown",
    networkMode: "Disconnected",
    bands: "Unknown Bands",
    bandDisplay: "-",
    bandwidth: "Unknown Bandwidth",
    earfcns: "000",
    pciDisplay: "-",
    ipv4: null,
    ipv6: null,
    cellID: "Unknown",
    eNBID: "Unknown",
    tac: "Unknown",
    csq: "-",
    rsrpLTE: "-",
    rsrpNR: "-",
    rsrpLTEPercentage: "0%",
    rsrpNRPercentage: "0%",
    rsrqLTE: "-",
    rsrqNR: "-",
    rsrqLTEPercentage: "0%",
    rsrqNRPercentage: "0%",
    sinrLTE: "-",
    sinrNR: "-",
    sinrLTEPercentage: "0%",
    sinrNRPercentage: "0%",
    signalPercentage: "0",
    signalAssessment: "Unknown",
    uptime: "Unknown",
    cpuLoad: "-",
    get signalColor() {
      const v = parseFloat(this.signalPercentage);
      if (isNaN(v) || v === 0) return STATUS_COLOR_GREY;
      if (v >= 70) return STATUS_COLOR_GREEN;
      if (v >= 40) return STATUS_COLOR_YELLOW;
      return STATUS_COLOR_RED;
    },
    get cpuLoadColor() {
      const v = parseFloat(this.cpuLoad);
      if (isNaN(v)) return STATUS_COLOR_GREY;
      if (v < 0.5) return STATUS_COLOR_GREEN;
      if (v < 1.0) return STATUS_COLOR_YELLOW;
      return STATUS_COLOR_RED;
    },
    ramPercent: "-",
    ramUsed: "-",
    ramTotal: "-",
    lastUpdate: new Date().toLocaleString([], { hour12: false }),
    newRefreshRate: null,
    refreshRate: 3,
    nrDownload: "0",
    nrUpload: "0",
    nonNrDownload: "0",
    nonNrUpload: "0",
    downloadStat: "0",
    uploadStat: "0",

    fetchModemInfo() {
      if (this.isFetching) return;
      this.isFetching = true;

      const _atController = new AbortController();
      const _atTimeout = setTimeout(() => _atController.abort(), 2000);

      authFetch("/cgi-bin/get_modem_stats", {
        method: "POST",
        signal: _atController.signal,
      }).then((response) => {
        clearTimeout(_atTimeout);
        return response.text();
      }).then((data) => {
            const lines = data.split("\n");

            // Cache repeated line lookups
            const servingcell_line = lines.find((l) => l.includes('+QENG: "servingcell"'));
            const lte_line = lines.find((l) => l.includes('+QENG: "LTE"'));
            const nr5g_nsa_line = lines.find((l) => l.includes('+QENG: "NR5G-NSA"'));
            const pcc_line = lines.find((l) => l.includes('+QCAINFO: "PCC"'));
            const qgdnrcnt_line = lines.find((l) => l.includes("+QGDNRCNT:"));
            const qgdcnt_line = lines.find((l) => l.includes("+QGDCNT:"));

            // --- Temperature ---
            // +QTEMP:"cpuss-0-usr","50"
            this.temperature = lines
              .find((line) => line.includes('+QTEMP:"cpuss-0-usr"'))
              ?.split(",")[1]
              ?.replace(/"/g, "") ??
              lines
                .find((line) => line.includes('+QTEMP:"cpu0-a7-usr"'))
                ?.split(",")[1]
                ?.replace(/"/g, "") ??
              null;

            // --- Network Mode ---
            // +QENG: "servingcell","NOCONN","NR5G-SA","TDD",515,66,7000C4001,...
            try {
              const network_mode = servingcell_line
                .split(",")[2]
                .replace(/"/g, "");

              const duplex_mode = servingcell_line
                .split(",")[3]
                .replace(/"/g, "");

              if (network_mode === "NR5G-SA") {
                if (duplex_mode === "TDD") {
                  this.networkMode = "5G SA TDD";
                } else if (duplex_mode === "FDD") {
                  this.networkMode = "5G SA FDD";
                }
              }

              if (network_mode === "LTE") {
                if (duplex_mode === "TDD") {
                  this.networkMode = "4G LTE TDD";
                } else if (duplex_mode === "FDD") {
                  this.networkMode = "4G LTE FDD";
                }
              }
            } catch (error) {
              // +QENG: "LTE","FDD",515,03,22AE76D,...
              const duplex_mode_lte = lte_line
                ?.split(",")[1]
                ?.replace(/"/g, "");

              try {
                // +QENG: "NR5G-NSA",515,03,843,-95,20,-11,528030,41,8,1
                nr5g_nsa_line
                  .split(",")[0]
                  .replace("+QENG: ", "")
                  .replace(/"/g, "");

                this.networkMode = "5G NSA";
              } catch (error) {
                if (duplex_mode_lte === "FDD") {
                  this.networkMode = "4G LTE FDD";
                } else if (duplex_mode_lte === "TDD") {
                  this.networkMode = "4G LTE TDD";
                }
              }
            }

            // --- Bands ---
            const bands = lines
              .filter((line) => line.includes("LTE BAND"))
              .map((line) => {
                const num = line.split(",")[3]?.replace(/"/g, "")?.replace("LTE BAND", "")?.trim();
                return num ? "B" + num : null;
              })
              .filter(Boolean);

            const bands_5g = lines
              .filter((line) => line.includes("NR5G BAND"))
              .map((line) => {
                const num = line.split(",")[3]?.replace(/"/g, "")?.replace("NR5G BAND", "")?.trim();
                return num ? "N" + num : null;
              })
              .filter(Boolean);

            this.bands = [...bands, ...bands_5g].join(", ") || "No Bands";

            // --- PCC / SCC band split ---
            {
              const trim = (b) => b?.trim() ?? "";
              let pcc, scc;
              if (this.networkMode === "5G SA TDD" || this.networkMode === "5G SA FDD") {
                pcc = trim(bands_5g[0]) || null;
                scc = bands_5g.slice(1).map(trim).filter(Boolean).join(", ") || null;
              } else if (this.networkMode === "5G NSA") {
                pcc = trim(bands[0]) || null;
                scc = [...bands.slice(1), ...bands_5g].map(trim).filter(Boolean).join(", ") || null;
              } else {
                pcc = trim(bands[0]) || null;
                scc = bands.slice(1).map(trim).filter(Boolean).join(", ") || null;
              }
              this.bandDisplay = pcc ? pcc + " (PCC)" + (scc ? ", " + scc : "") : "-";
            }

            // --- Bandwidth ---
            // Helper: sum LTE DL bandwidth across QCAINFO component carriers.
            // QCAINFO index 2 for LTE is resource blocks (6/15/25/50/75/100), not the QENG code.
            const sumLteDL = (caLines) =>
              caLines.reduce((sum, l) => sum + (this.lte_rb_to_mhz(l.split(",")[2]) ?? 0), 0) || null;

            if (
              this.networkMode === "5G SA TDD" ||
              this.networkMode === "5G SA FDD"
            ) {
              const nr_bw = servingcell_line?.split(",")[11];
              const calculated_bandwidth = this.calculate_nr_bw(nr_bw);
              this.bandwidth = (calculated_bandwidth ?? "?") + " MHz";
            } else if (
              this.networkMode === "4G LTE FDD" ||
              this.networkMode === "4G LTE TDD"
            ) {
              const lte_bw_ul = servingcell_line?.split(",")[10];
              const ul = this.calculate_lte_bw(lte_bw_ul);
              const scc_lines = lines.filter(l => l.includes('+QCAINFO: "SCC"') && l.includes("LTE BAND"));
              const dl = pcc_line
                ? sumLteDL([pcc_line, ...scc_lines])
                : this.calculate_lte_bw(servingcell_line?.split(",")[11]);
              this.bandwidth = (dl ?? "?") + " MHz DL / " + (ul ?? "?") + " MHz UL";
            } else if (this.networkMode === "5G NSA") {
              const lte_bw_ul = lte_line?.split(",")[8];
              const ul = this.calculate_lte_bw(lte_bw_ul);
              const lte_scc_lines = lines.filter(l => l.includes('+QCAINFO: "SCC"') && l.includes("LTE BAND"));
              const lte_dl = pcc_line
                ? sumLteDL([pcc_line, ...lte_scc_lines])
                : this.calculate_lte_bw(lte_line?.split(",")[9]);
              const nr_scc_lines = lines.filter(l => l.includes('+QCAINFO: "SCC"') && l.includes("NR5G BAND"));
              const nr = nr_scc_lines.length > 0
                ? nr_scc_lines.reduce((sum, l) => sum + (this.calculate_nr_bw(l.split(",")[2]) ?? 0), 0) || null
                : this.calculate_nr_bw(nr5g_nsa_line?.split(",")[9]);
              this.bandwidth =
                (lte_dl ?? "?") + " MHz (LTE) + " +
                (nr ?? "?") + " MHz (NR) DL / " +
                (ul ?? "?") + " MHz UL";
            } else {
              this.bandwidth = "Unknown Bandwidth";
            }

            // --- E/ARFCN ---
            {
              const pcc_arfcn = pcc_line?.split(",")[1];
              const scc_arfcn = lines.filter((line) => line.includes('+QCAINFO: "SCC"'));
              if (!pcc_arfcn) {
                this.earfcns = "Unknown E/ARFCN";
              } else if (scc_arfcn.length === 0) {
                this.earfcns = pcc_arfcn;
              } else {
                this.earfcns = pcc_arfcn + ", " + scc_arfcn.map(l => l.split(",")[1]).join(", ");
              }
            }

            // --- PCI ---
            // PCI is always at index 4 in +QCAINFO lines regardless of line length or mode.
            {
              const pcc_pci = pcc_line?.split(",")[4]?.trim();
              const scc_lines = lines.filter((line) => line.includes('+QCAINFO: "SCC"'));
              const scc = scc_lines.map(l => l.split(",")[4]?.trim()).filter(Boolean).join(", ") || null;
              if (this.networkMode === "Disconnected") {
                this.pciDisplay = "-";
              } else {
                this.pciDisplay = pcc_pci ? pcc_pci + " (PCC)" + (scc ? ", " + scc : "") : "-";
              }
            }

            // Traffic Stats
            // +QGDNRCNT: upload,download  /  +QGDCNT: upload,download
            this.nrUpload = qgdnrcnt_line?.split(",")[0]?.replace("+QGDNRCNT: ", "");
            this.nrDownload = qgdnrcnt_line?.split(",")[1];
            this.nonNrUpload = qgdcnt_line?.split(",")[0]?.replace("+QGDCNT: ", "");
            this.nonNrDownload = qgdcnt_line?.split(",")[1];

            this.downloadStat =
              (parseInt(this.nrDownload, 10) || 0) + (parseInt(this.nonNrDownload, 10) || 0);
            this.uploadStat =
              (parseInt(this.nrUpload, 10) || 0) + (parseInt(this.nonNrUpload, 10) || 0);

            this.downloadStat = this.bytesToSize(this.downloadStat);
            this.uploadStat = this.bytesToSize(this.uploadStat);

            // --- Signal ---
            if (
              this.networkMode === "5G SA TDD" ||
              this.networkMode === "5G SA FDD" ||
              this.networkMode === "4G LTE FDD" ||
              this.networkMode === "4G LTE TDD"
            ) {
              const longCID = servingcell_line
                ?.split(",")[6]
                ?.replace(/"/g, "");

              if (!longCID) {
                this.eNBID = "Unknown";
                this.cellID = "Unknown";
              }

              const eNBIDStr = longCID && longCID.length > 2 ? longCID.substring(0, longCID.length - 2) : null;
              this.eNBID = eNBIDStr ? parseInt(eNBIDStr, 16) : "Unknown";

              const shortCID = longCID && longCID.length >= 2 ? longCID.substring(longCID.length - 2) : null;

              if (
                this.networkMode === "5G SA TDD" ||
                this.networkMode === "5G SA FDD"
              ) {
                const localTac = servingcell_line?.split(",")[8]?.replace(/"/g, "");
                this.tac = localTac ? localTac + " (" + parseInt(localTac, 16) + ")" : "Unknown";
                this.csq = "NR-SA Mode";

                this.signalPercentage = this.computeSignalMetrics(
                  servingcell_line?.split(",")[12]?.replace(/"/g, ""),
                  servingcell_line?.split(",")[13]?.replace(/"/g, ""),
                  servingcell_line?.split(",")[14]?.replace(/"/g, ""),
                  "NR"
                );
                this.signalAssessment = this.signalQuality(this.signalPercentage);
              } else {
                // LTE Only
                const localTac = servingcell_line?.split(",")[12]?.replace(/"/g, "");
                this.tac = localTac ? localTac + " (" + parseInt(localTac, 16) + ")" : "Unknown";
                this.csq = lines
                  .find((line) => line.includes("+CSQ:"))
                  ?.split(" ")[1]
                  ?.split(",")[0];

                this.signalPercentage = this.computeSignalMetrics(
                  servingcell_line?.split(",")[13]?.replace(/"/g, ""),
                  servingcell_line?.split(",")[14]?.replace(/"/g, ""),
                  servingcell_line?.split(",")[16]?.replace(/"/g, ""),
                  "LTE"
                );
                this.signalAssessment = this.signalQuality(this.signalPercentage);
              }

              if (longCID && shortCID) {
                this.cellID =
                  "Short " + parseInt(shortCID, 16) +
                  ", Long " + parseInt(longCID, 16);
              }
            } else if (this.networkMode === "5G NSA") {
              const longCID = lte_line?.split(",")[4]?.replace(/"/g, "");

              const eNBIDStr = longCID && longCID.length > 2 ? longCID.substring(0, longCID.length - 2) : null;
              this.eNBID = eNBIDStr ? parseInt(eNBIDStr, 16) : "Unknown";

              const shortCID = longCID && longCID.length >= 2 ? longCID.substring(longCID.length - 2) : null;

              const localTac = lte_line?.split(",")[10]?.replace(/"/g, "");
              this.tac = localTac ? localTac + " (" + parseInt(localTac, 16) + ")" : "Unknown";

              if (longCID && shortCID) {
                this.cellID =
                  "Short " + parseInt(shortCID, 16) +
                  ", Long " + parseInt(longCID, 16);
              }

              this.csq = lines
                .find((line) => line.includes("+CSQ:"))
                ?.split(" ")[1]
                ?.replace("+CSQ: ", "")
                ?.replace(/"/g, "")
                ?.split(",")[0];

              // +QENG: "NR5G-NSA",MCC,MNC,RSRP,SINR,RSRQ,...
              const lte_sig = this.computeSignalMetrics(
                lte_line?.split(",")[11]?.replace(/"/g, ""),
                lte_line?.split(",")[12]?.replace(/"/g, ""),
                lte_line?.split(",")[14]?.replace(/"/g, ""),
                "LTE"
              );
              const nr_sig = this.computeSignalMetrics(
                nr5g_nsa_line?.split(",")[4]?.replace(/"/g, ""),
                nr5g_nsa_line?.split(",")[6]?.replace(/"/g, ""),
                nr5g_nsa_line?.split(",")[5]?.replace(/"/g, ""),
                "NR"
              );
              this.signalPercentage = (lte_sig + nr_sig) / 2;
              this.signalAssessment = this.signalQuality(this.signalPercentage);
            } else {
              this.signalAssessment = "No Signal";
              this.signalPercentage = 0;
              this.rsrpLTE = "-";
              this.rsrqLTE = "-";
              this.sinrLTE = "-";
              this.rsrpLTEPercentage = 0;
              this.rsrqLTEPercentage = 0;
              this.sinrLTEPercentage = 0;
              this.rsrpNR = "-";
              this.rsrqNR = "-";
              this.sinrNR = "-";
              this.rsrpNRPercentage = 0;
              this.rsrqNRPercentage = 0;
              this.sinrNRPercentage = 0;
              this.csq = "-";
              this.cellID = "Unknown";
              this.eNBID = "Unknown";
              this.tac = "Unknown";
            }

            // --- SIM Status ---
            const sim_status = lines
              .find((line) => line.includes("+QSIMSTAT:"))
              ?.split(" ")[1]
              ?.replace(/"/g, "")
              ?.split(",")[1]
              ?.trim();

            if (parseInt(sim_status, 10) === 1) {
              this.simStatus = "Active";
            } else if (parseInt(sim_status, 10) === 0) {
              this.simStatus = "No SIM";
            }

            // --- Active SIM ---
            const current_sim = lines
              .find((line) => line.includes("+QUIMSLOT:"))
              ?.split(" ")[1]
              ?.replace(/"/g, "")
              ?.trim();

            if (parseInt(current_sim, 10) === 1) {
              this.activeSim = "SIM 1";
            } else if (parseInt(current_sim, 10) === 2) {
              this.activeSim = "SIM 2";
            } else {
              this.activeSim = "No SIM";
            }

            // --- Network Provider ---
            const qspn_line = lines.find((line) => line.includes("+QSPN:"));
            const network_provider = qspn_line
              ?.split(",")[0]
              ?.replace("+QSPN: ", "")
              ?.replace(/"/g, "")
              ?.replace(/ /g, "") ?? "";

            if (network_provider.match(/^[0-9]+$/) !== null) {
              this.networkProvider = qspn_line?.split(",")[2]?.replace(/"/g, "") || "N/A";
            } else {
              this.networkProvider = network_provider || "N/A";
            }

            // --- MCCMNC ---
            this.mccmnc = qspn_line?.split(",")[4]?.replace(/"/g, "") || "00000";

            // --- APN ---
            this.apn = lines
              .find((line) => line.includes("+CGCONTRDP:"))
              ?.split(",")[2]
              ?.replace(/"/g, "") || "Unknown";

            // --- IPv4 and IPv6 ---
            this.ipv4 = cleanIp(lines
              .find((line) => line.includes("IPV4"))
              ?.split(",")[4]
              ?.replace(/"/g, ""));

            this.ipv6 = cleanIp(lines
              .find((line) => line.includes("IPV6"))
              ?.split(",")[4]
              ?.replace(/"/g, ""));

      }).catch((error) => {
        clearTimeout(_atTimeout);
        if (error.name !== 'AbortError') console.error("fetchModemInfo error:", error);
      }).finally(() => {
        this.isFetching = false;
      });
    },

    bytesToSize(bytes) {
      const sizes = ["Bytes", "KB", "MB", "GB", "TB"];
      if (bytes === 0) return "0 Byte";
      const i = parseInt(Math.floor(Math.log(bytes) / Math.log(1024)));
      return Math.round(bytes / Math.pow(1024, i) * 10) / 10 + " " + sizes[i];
    },

    requestPing() {
      if (this.isPinging) return Promise.resolve(null);
      this.isPinging = true;
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 3000);
      return authFetch("/cgi-bin/get_ping", { signal: controller.signal })
        .then((response) => response.text())
        .then((data) => {
          clearTimeout(timeout);
          return data;
        })
        .catch((error) => {
          clearTimeout(timeout);
          console.error("Error:", error);
          throw error;
        })
        .finally(() => { this.isPinging = false; });
    },

    calculate_lte_bw(lte_bw) {
      const BANDWIDTH_MAP = {
        0: 1.4,
        1: 3,
        2: 5,
        3: 10,
        4: 15,
        5: 20,
        6: 40,
        7: 80,
        8: 100,
        9: 200,
      };
      return BANDWIDTH_MAP[lte_bw];
    },

    lte_rb_to_mhz(rb) {
      const MAP = { 6: 1.4, 15: 3, 25: 5, 50: 10, 75: 15, 100: 20 };
      return MAP[parseInt(rb, 10)];
    },

    calculate_nr_bw(nr_bw) {
      const NR_BANDWIDTH_MAP = {
        0: 5,
        1: 10,
        2: 15,
        3: 20,
        4: 25,
        5: 30,
        6: 40,
        7: 50,
        8: 60,
        9: 70,
        10: 80,
        11: 90,
        12: 100,
        13: 200,
        14: 400,
      };
      return NR_BANDWIDTH_MAP[nr_bw];
    },

    calculateRSRPPercentage(rsrp) {
      if (isNaN(rsrp) || rsrp < -140) return 0;
      let percentage = ((rsrp - (-135)) / ((-65) - (-135))) * 100;
      return Math.round(Math.min(Math.max(percentage, 15), 100));
    },

    calculateRSRQPercentage(rsrq) {
      if (isNaN(rsrq) || rsrq < -20) return 0;
      let percentage = ((rsrq - (-20)) / ((-8) - (-20))) * 100;
      return Math.round(Math.min(Math.max(percentage, 15), 100));
    },

    calculateSINRPercentage(sinr) {
      if (isNaN(sinr) || sinr < -10) return 0;
      let percentage = ((sinr - (-10)) / (25 - (-10))) * 100;
      return Math.round(Math.min(Math.max(percentage, 15), 100));
    },

    calculateSignalPercentage(rsrpPercentage, sinrPercentage) {
      return Math.round((rsrpPercentage + sinrPercentage) / 2);
    },

    computeSignalMetrics(rsrp, rsrq, sinr, prefix) {
      this["rsrp" + prefix] = rsrp;
      this["rsrq" + prefix] = rsrq;
      this["sinr" + prefix] = sinr;
      const rp  = this.calculateRSRPPercentage(parseInt(rsrp, 10));
      const rqp = this.calculateRSRQPercentage(parseInt(rsrq, 10));
      const sp  = this.calculateSINRPercentage(parseInt(sinr, 10));
      this["rsrp" + prefix + "Percentage"] = rp;
      this["rsrq" + prefix + "Percentage"] = rqp;
      this["sinr" + prefix + "Percentage"] = sp;
      return this.calculateSignalPercentage(rp, sp);
    },

    get tempColor() {
      const t = parseInt(this.temperature, 10);
      if (isNaN(t))  return STATUS_COLOR_GREEN;
      if (t >= 75)   return STATUS_COLOR_RED;
      if (t >= 60)   return STATUS_COLOR_YELLOW;
      if (t >= 20)   return STATUS_COLOR_GREEN;
      return STATUS_COLOR_BLUE;
    },

    getProgressBarClass(pct) {
      const percentage = parseInt(pct, 10);
      if (percentage >= 60) return 'progress-bar bg-success is-medium';
      if (percentage >= 40) return 'progress-bar bg-warning is-warning is-medium';
      return 'progress-bar bg-danger is-medium';
    },

    signalQuality(percentage) {
      if (percentage >= 80) return "Excellent";
      if (percentage >= 60) return "Good";
      if (percentage >= 40) return "Fair";
      if (percentage >= 0)  return "Poor";
      return "No Signal";
    },

    formatUptime(data) {
      const plural = (n, word) => `${n} ${word}${n === "1" ? "" : "s"}`;
      const days = data.match(/(\d+) day/);
      const hours = data.match(/(\d+) hour/);
      const minutes = data.match(/(\d+) min/);
      const hm = data.match(/(\d+):(\d+),/);
      const parts = [];
      if (days) parts.push(plural(days[1], "day"));
      if (hm) {
        parts.push(plural(hm[1], "hour"));
        parts.push(plural(String(parseInt(hm[2], 10)), "minute"));
      } else {
        if (hours) parts.push(plural(hours[1], "hour"));
        if (minutes) parts.push(plural(minutes[1], "minute"));
      }
      return parts.length > 0 ? parts.join(", ") : "Unknown Time";
    },

    fetchUpTime() {
      if (this.isUpTimeFetching) return;
      this.isUpTimeFetching = true;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 4000);
      authFetch("/cgi-bin/get_uptime", { signal: controller.signal })
        .then((response) => response.text())
        .then((data) => {
          // Example: 01:17:02 up 3 days,  2:41,  load average: 0.65, 0.66, 0.60
          this.uptime = this.formatUptime(data);
        })
        .catch(() => {})
        .finally(() => { clearTimeout(timer); this.isUpTimeFetching = false; });
    },

    updateRefreshRate() {
      if (this.newRefreshRate < 3) {
        this.newRefreshRate = 3;
      }

      clearInterval(this.intervalId);
      this.isFetching = false;

      this.refreshRate = this.newRefreshRate;

      localStorage.setItem("refreshRate", this.refreshRate);

      this.init();
    },

    fetchSystemStats() {
      if (this.isStatsFetching) return;
      this.isStatsFetching = true;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 4000);
      authFetch("/cgi-bin/get_system_stats", { signal: controller.signal })
        .then((r) => r.json())
        .then((data) => {
          this.cpuLoad = data.load_avg;
          this.ramPercent = data.mem_percent;
          this.ramUsed = data.mem_used_mb;
          this.ramTotal = data.mem_total_mb;
        })
        .catch(() => {})
        .finally(() => { clearTimeout(timer); this.isStatsFetching = false; });
    },

    init() {
      this.fetchUpTime();

      const storedRefreshRate = localStorage.getItem("refreshRate");
      this.refreshRate = Math.max(3, parseInt(storedRefreshRate) || 3);

      this.fetchModemInfo();
      this.fetchSystemStats();

      this.requestPing()
        .then((data) => {
          if (data === null) return;
          if (data.trim() === "OK") {
            this.internetConnectionStatus = "Connected";
          } else {
            this.internetConnectionStatus = "Disconnected";
          }
        })
        .catch((error) => {
          console.error("Error:", error);
          this.internetConnectionStatus = "Disconnected";
        });

      this.lastUpdate = new Date().toLocaleString([], { hour12: false });

      this.intervalId = setInterval(() => {
        this.fetchUpTime();
        this.fetchModemInfo();
        this.fetchSystemStats();

        this.requestPing()
          .then((data) => {
            if (data === null) return;
            if (data.trim() === "OK") {
              this.internetConnectionStatus = "Connected";
            } else {
              this.internetConnectionStatus = "Disconnected";
            }
          })
          .catch((error) => {
            console.error("Error:", error);
            this.internetConnectionStatus = "Disconnected";
          });

        this.lastUpdate = new Date().toLocaleString([], { hour12: false });
      }, this.refreshRate * 1000);

      // Re-registering on every init() call caused duplicate/lost listeners
      // on iOS Safari across multiple resumes.
      if (!this._handlersRegistered) {
        this._handlersRegistered = true;

        document.addEventListener('visibilitychange', () => {
          if (document.hidden) {
            clearInterval(this.intervalId);
            this.intervalId = null;
          } else {
            // Reset flags in case Safari froze the tab mid-request
            // and the finally() block never ran.
            clearInterval(this.intervalId);
            this.intervalId = null;
            this.isFetching = false;
            this.isPinging = false;
            this.isUpTimeFetching = false;
            this.isStatsFetching = false;
            this.init();
          }
        });

      }
    },
  };
}
