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
    bandwidth: "Unknown Bandwidth",
    earfcns: "000",
    pccPCI: "0",
    sccPCI: "-",
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
            // find this example value from lines "+QTEMP:"cpuss-0-usr","50"
            try {
              this.temperature = lines
                .find((line) => line.includes('+QTEMP:"cpuss-0-usr"'))
                ?.split(",")[1]
                ?.replace(/"/g, "") ??
                lines
                  .find((line) => line.includes('+QTEMP:"cpu0-a7-usr"'))
                  ?.split(",")[1]
                  ?.replace(/"/g, "");
            } catch (error) {
              this.temperature = null;
            }

            // --- Network Mode ---
            // find this example value from lines "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",515,66,7000C4001,475,702000,620640,78,12,-83,-3,16,1,-\r"

            try {
              const network_mode = servingcell_line
                .split(",")[2]
                .replace(/"/g, "");

              const duplex_mode = servingcell_line
                .split(",")[3]
                .replace(/"/g, "");

              if (network_mode == "NR5G-SA") {
                if (duplex_mode == "TDD") {
                  this.networkMode = "5G SA TDD";
                } else if (duplex_mode == "FDD") {
                  this.networkMode = "5G SA FDD";
                }
              }

              if (network_mode == "LTE") {
                // get the FDD | TDD value
                const is_tdd = servingcell_line
                  .split(",")[3]
                  .replace(/"/g, "");

                if (is_tdd == "TDD") {
                  this.networkMode = "4G LTE TDD";
                } else if (is_tdd == "FDD") {
                  this.networkMode = "4G LTE FDD";
                }
              }
            } catch (error) {
              // find this example value from lines "+QENG: \"LTE\",\"FDD\",515,03,22AE76D,398,1350,3,4,4,BF82,-110,-13,-78,10,6,200,-\r"

              const network_mode_lte = lte_line
                ?.split(",")[0]
                ?.replace("+QENG: ", "")
                ?.replace(/"/g, "");

              try {
                // find this example value from lines "+QENG: \"NR5G-NSA\",515,03,843,-95,20,-11,528030,41,8,1\r"
                const network_mode_5g = nr5g_nsa_line
                  .split(",")[0]
                  .replace("+QENG: ", "")
                  .replace(/"/g, "");

                this.networkMode = "5G NSA";
              } catch (error) {
                if (network_mode_lte == "FDD") {
                  this.networkMode = "4G LTE FDD";
                } else if (network_mode_lte == "TDD") {
                  this.networkMode = "4G LTE TDD";
                }
              }
            }

            // --- Bands ---
            // Get all the values with LTE BAND n (for example, LTE BAND 3, LTE BAND 1) and then store them in an array
            const bands = lines.filter((line) =>
              line.includes("LTE BAND")
            );

            // since it includes the whole line, we need to extract the band part only
            for (let i = 0; i < bands.length; i++) {
              bands[i] = bands[i].split(",")[3]?.replace(/"/g, "");
            }

            // Get all the values with NR BAND n (for example, NR BAND 3, NR BAND 1) and then store them in an array
            const bands_5g = lines.filter((line) =>
              line.includes("NR5G BAND")
            );

            // since it includes the whole line, we need to extract the band number only
            for (let i = 0; i < bands_5g.length; i++) {
              bands_5g[i] = bands_5g[i].split(",")[3]?.replace(/"/g, "");
            }

            // Combine the bands and bands_5g arrays seperated by a comma. however, bands or bands_5g can be empty
            if (bands.length > 0 && bands_5g.length > 0) {
              this.bands = bands.join(", ") + ", " + bands_5g.join(", ");
            } else if (bands.length > 0) {
              this.bands = bands.join(", ");
            } else if (bands_5g.length > 0) {
              this.bands = bands_5g.join(", ");
            } else {
              this.bands = "No Bands";
            }

            // --- Bandwidth ---
            if (
              this.networkMode == "5G SA TDD" ||
              this.networkMode == "5G SA FDD"
            ) {

              const nr_bw = servingcell_line?.split(",")[11];
              const calculated_bandwidth = this.calculate_nr_bw(nr_bw);
              this.bandwidth = "NR " + calculated_bandwidth + " MHz";
            } else if (
              this.networkMode == "4G LTE FDD" ||
              this.networkMode == "4G LTE TDD"
            ) {
              const lte_bw_ul = servingcell_line?.split(",")[10];
              const lte_bw_dl = servingcell_line?.split(",")[11];
              const calculated_bandwidth_ul =
                this.calculate_lte_bw(lte_bw_ul);
              const calculated_bandwidth_dl =
                this.calculate_lte_bw(lte_bw_dl);
              this.bandwidth =
                calculated_bandwidth_ul +
                " UL / " +
                calculated_bandwidth_dl +
                " DL MHz";
            } else if (this.networkMode == "5G NSA") {
              const lte_bw_ul = lte_line?.split(",")[8];
              const lte_bw_dl = lte_line?.split(",")[9];

              const calculated_bandwidth_ul =
                this.calculate_lte_bw(lte_bw_ul);
              const calculated_bandwidth_dl =
                this.calculate_lte_bw(lte_bw_dl);

              const nr_bw = nr5g_nsa_line?.split(",")[9];
              const calculated_bandwidth = this.calculate_nr_bw(nr_bw);

              // combine the bandwidths
              this.bandwidth =
                calculated_bandwidth_ul +
                " UL / " +
                calculated_bandwidth_dl +
                " DL MHz" +
                " / NR " +
                calculated_bandwidth +
                " MHz";
            } else {
              this.bandwidth = "Unknown Bandwidth";
            }

            // --- E/ARFCN ---
            if (
              this.networkMode == "5G SA TDD" ||
              this.networkMode == "5G SA FDD"
            ) {
              // find this value from lines "+QCAINFO: \"PCC\"
              const nr_pcc_arfcn = pcc_line?.split(",")[1];

              try {
                // Look for all the lines with this value "+QCAINFO: \"SCC\" and store them in an array
                const nr_scc_arfcn = lines.filter((line) =>
                  line.includes('+QCAINFO: "SCC"')
                );

                // if empty, then proceed to error block
                if (nr_scc_arfcn.length == 0) {
                  throw "No SCC ARFCN";
                }

                // process all the values in the array and extract the ARFCN part only
                for (let i = 0; i < nr_scc_arfcn.length; i++) {
                  nr_scc_arfcn[i] = nr_scc_arfcn[i].split(",")[1];
                }

                // combine the PCC and SCC ARFCN values
                this.earfcns =
                  nr_pcc_arfcn + ", " + nr_scc_arfcn.join(", ");
              } catch (error) {
                this.earfcns = nr_pcc_arfcn?.replace(/,/g, "");
              }
            } else if (
              this.networkMode == "4G LTE FDD" ||
              this.networkMode == "4G LTE TDD"
            ) {
              const lte_pcc_arfcn = pcc_line?.split(",")[1];

              try {
                // Look for all the lines with this value "+QCAINFO: \"SCC\" and store them in an array
                const lte_scc_arfcn = lines.filter((line) =>
                  line.includes('+QCAINFO: "SCC"')
                );

                // if empty, then proceed to error block
                if (lte_scc_arfcn.length == 0) {
                  throw "No SCC ARFCN";
                }

                // process all the values in the array and extract the ARFCN part only
                for (let i = 0; i < lte_scc_arfcn.length; i++) {
                  lte_scc_arfcn[i] = lte_scc_arfcn[i].split(",")[1];
                }

                // combine the PCC and SCC ARFCN values
                this.earfcns =
                  lte_pcc_arfcn + ", " + lte_scc_arfcn.join(", ");
              } catch (error) {
                this.earfcns = lte_pcc_arfcn?.replace(/,/g, "");
              }
            } else if (this.networkMode == "5G NSA") {
              const lte_pcc_arfcn = pcc_line?.split(",")[1];

              try {
                // Look for all the lines with this value "+QCAINFO: \"SCC\" and store them in an array
                const lte_scc_arfcn = lines.filter((line) =>
                  line.includes('+QCAINFO: "SCC"')
                );

                // If empty, then proceed to error block
                if (lte_scc_arfcn.length == 0) {
                  throw "No SCC ARFCN";
                }

                // process all the values in the array and extract the ARFCN part only
                for (let i = 0; i < lte_scc_arfcn.length; i++) {
                  lte_scc_arfcn[i] = lte_scc_arfcn[i].split(",")[1];
                }

                // combine the PCC and SCC ARFCN values
                this.earfcns =
                  lte_pcc_arfcn + ", " + lte_scc_arfcn.join(", ");
              } catch (error) {
                this.earfcns = lte_pcc_arfcn?.replace(/,/g, "");
              }
            } else {
              this.earfcns = "Unknown E/ARFCN";
            }

            // --- PCI ---
            if (
              this.networkMode == "5G SA TDD" ||
              this.networkMode == "5G SA FDD"
            ) {
              const nr_pcc_pci = pcc_line?.split(",")[4]?.trim();

              try {
                // Look for all the lines with this value "+QCAINFO: \"SCC\" and store them in an array
                const nr_scc_pci = lines.filter((line) =>
                  line.includes('+QCAINFO: "SCC"')
                );

                // if empty, then proceed to error block
                if (nr_scc_pci.length == 0) {
                  throw "No SCC PCI";
                }

                // process all the values in the array and extract the PCI part only
                for (let i = 0; i < nr_scc_pci.length; i++) {
                  nr_scc_pci[i] = nr_scc_pci[i].split(",")[5].trim();
                }

                // combine the PCC and SCC PCI values
                this.pccPCI = nr_pcc_pci;
                this.sccPCI = nr_scc_pci.filter(Boolean).join(", ");
              } catch (error) {
                // remove comma if only one value
                this.pccPCI = nr_pcc_pci?.replace(/,/g, "");
                this.sccPCI = "-";
              }
            } else if (
              this.networkMode == "4G LTE FDD" ||
              this.networkMode == "4G LTE TDD"
            ) {
              const lte_pcc_pci = pcc_line?.split(",")[5]?.trim();
              try {
                // Look for all the lines with this value "+QCAINFO: \"SCC\" and store them in an array
                const lte_scc_pci = lines.filter((line) =>
                  line.includes('+QCAINFO: "SCC"')
                );

                // if empty, then proceed to error block
                if (lte_scc_pci.length == 0) {
                  throw "No SCC PCI";
                }

                // process all the values in the array and extract the PCI part only
                for (let i = 0; i < lte_scc_pci.length; i++) {
                  lte_scc_pci[i] = lte_scc_pci[i].split(",")[5].trim();
                }

                // combine the PCC and SCC PCI values
                this.pccPCI = lte_pcc_pci;
                this.sccPCI = lte_scc_pci.filter(Boolean).join(", ");
              } catch (error) {
                this.pccPCI = lte_pcc_pci;
                this.sccPCI = "-";
              }
            } else if (this.networkMode == "5G NSA") {
              const pccparts = pcc_line?.split(":")[1]?.split(",");
              const sccarr = lines.filter((m) => m.includes("QCAINFO: \"SCC\""));
              const sccpci = [];
              sccarr.forEach((s) => {
                const sccparts = s.split(":")[1].split(",");
                let sccIndex = 5;
                switch (sccparts.length) {
                  case 8: // length 8, PCI is at index 4, NR5G PCC and NR5G SCC Band when NR5G-NSA
                    sccIndex = 4;
                    break;
                  case 13: // length 13, PCI is at index 5, LTE SCC Band
                  case 12: // length 12, PCI is at index 5, NR5G SCC Band
                  case 10: // length 10, PCI is at index 5, LTE PCC Band
                  default:
                    sccIndex = 5;
                    break;
                }
                sccpci.push(sccparts[sccIndex]?.trim());
              });
              this.sccPCI = sccpci.filter(Boolean).join(', ');
              let pccIndex = 5;
              switch (pccparts.length) {
                case 8: // length 8, PCI is at index 4, NR5G PCC and NR5G SCC Band when NR5G-NSA
                  pccIndex = 4;
                  break;
                case 13: // length 13, PCI is at index 5, LTE SCC Band
                case 12: // length 12, PCI is at index 5, NR5G SCC Band
                case 10: // length 10, PCI is at index 5, LTE PCC Band
                default:
                  pccIndex = 5;
                  break;
              }
              this.pccPCI = pccparts[pccIndex]?.trim();
            } else {
              this.pccPCI = "0";
              this.sccPCI = "-";
            }

            // Traffic Stats
            // for NR traffic stats: +QGDNRCNT: 3263753367,109876105
            this.nrUpload = qgdnrcnt_line?.split(",")[0]?.replace("+QGDNRCNT: ", "");
            this.nrDownload = qgdnrcnt_line?.split(",")[1];

            // for non-NR traffic stats: +QGDCNT: 247357510,6864571506
            this.nonNrUpload = qgdcnt_line?.split(",")[0]?.replace("+QGDCNT: ", "");
            this.nonNrDownload = qgdcnt_line?.split(",")[1];

            // Add the nrDownload and nonNrDownload together
            this.downloadStat =
              (parseInt(this.nrDownload) || 0) + (parseInt(this.nonNrDownload) || 0);

            // Add the nrUpload and nonNrUpload together
            this.uploadStat =
              (parseInt(this.nrUpload) || 0) + (parseInt(this.nonNrUpload) || 0);

            // Convert the downloadStat and uploadStat bytes to readable size
            this.downloadStat = this.bytesToSize(this.downloadStat);
            this.uploadStat = this.bytesToSize(this.uploadStat);

            // Signal Informations

            const currentNetworkMode = this.networkMode;

            if (
              currentNetworkMode == "5G SA TDD" ||
              currentNetworkMode == "5G SA FDD" ||
              currentNetworkMode == "4G LTE FDD" ||
              currentNetworkMode == "4G LTE TDD"
            ) {
              // CellID
              const longCID = servingcell_line
                ?.split(",")[6]
                ?.replace(/"/g, "");

              if (!longCID) {
                this.eNBID = "Unknown";
                this.cellID = "Unknown";
              }

              // Get the eNBID. Its just Cell ID minus the last 2 characters
              const eNBIDStr = longCID?.substring(0, longCID.length - 2);
              this.eNBID = eNBIDStr ? parseInt(eNBIDStr, 16) : "Unknown";

              // Get the short Cell ID (Last 2 characters of the Cell ID)
              const shortCID = longCID?.substring(longCID.length - 2);

              if (
                currentNetworkMode == "5G SA TDD" ||
                currentNetworkMode == "5G SA FDD"
              ) {
                // TAC
                const localTac = servingcell_line?.split(",")[8]?.replace(/"/g, "");
                this.tac = localTac ? parseInt(localTac, 16) + " (" + localTac + ")" : "Unknown";
                // CSQ
                this.csq = "NR-SA Mode";

                // RSRP
                this.rsrpNR = servingcell_line?.split(",")[12]?.replace(/"/g, "");

                // RSRQ
                this.rsrqNR = servingcell_line?.split(",")[13]?.replace(/"/g, "");

                // SINR
                this.sinrNR = servingcell_line?.split(",")[14]?.replace(/"/g, "");

                // Calculate the RSRP Percentage
                this.rsrpNRPercentage = this.calculateRSRPPercentage(
                  parseInt(this.rsrpNR)
                );

                // Calculate the RSRQ Percentage
                this.rsrqNRPercentage = this.calculateRSRQPercentage(
                  parseInt(this.rsrqNR)
                );

                // Calculate the SINR Percentage
                this.sinrNRPercentage = this.calculateSINRPercentage(
                  parseInt(this.sinrNR)
                );

                // Calculate the Signal Percentage
                this.signalPercentage = this.calculateSignalPercentage(
                  this.rsrpNRPercentage,
                  this.sinrNRPercentage
                );

                // Calculate the Signal Assessment
                this.signalAssessment = this.signalQuality(
                  this.signalPercentage
                );
              } else {
                // LTE Only
                // TAC
                const localTac = servingcell_line?.split(",")[12]?.replace(/"/g, "");
                this.tac = localTac ? parseInt(localTac, 16) + " (" + localTac + ")" : "Unknown";
                // CSQ
                this.csq = lines
                  .find((line) => line.includes("+CSQ:"))
                  ?.split(" ")[1]
                  ?.replace("+CSQ: ", "")
                  ?.replace(/"/g, "");

                // RSRP
                this.rsrpLTE = servingcell_line?.split(",")[13]?.replace(/"/g, "");

                // RSRQ
                this.rsrqLTE = servingcell_line?.split(",")[14]?.replace(/"/g, "");

                // SINR
                this.sinrLTE = servingcell_line?.split(",")[16]?.replace(/"/g, "");

                // Calculate the RSRP Percentage
                this.rsrpLTEPercentage = this.calculateRSRPPercentage(
                  parseInt(this.rsrpLTE)
                );

                // Calculate the RSRQ Percentage
                this.rsrqLTEPercentage = this.calculateRSRQPercentage(
                  parseInt(this.rsrqLTE)
                );

                // Calculate the SINR Percentage
                this.sinrLTEPercentage = this.calculateSINRPercentage(
                  parseInt(this.sinrLTE)
                );

                // Calculate the Signal Percentage
                this.signalPercentage = this.calculateSignalPercentage(
                  this.rsrpLTEPercentage,
                  this.sinrLTEPercentage
                );

                // Calculate the Signal Assessment
                this.signalAssessment = this.signalQuality(
                  this.signalPercentage
                );
              }

              if (longCID && shortCID) {
                this.cellID =
                  "Short " +
                  shortCID +
                  "(" +
                  parseInt(shortCID, 16) +
                  ")" +
                  ", " +
                  "Long " +
                  longCID +
                  "(" +
                  parseInt(longCID, 16) +
                  ")";
              }
            } else if (currentNetworkMode == "5G NSA") {
              // LongCID
              const longCID = lte_line?.split(",")[4]?.replace(/"/g, "");

              // Get the eNBID. Its just Cell ID minus the last 2 characters
              const eNBIDStrNSA = longCID?.substring(0, longCID.length - 2);
              this.eNBID = eNBIDStrNSA ? parseInt(eNBIDStrNSA, 16) : "Unknown";

              // Get the short Cell ID (Last 2 characters of the Cell ID)
              const shortCID = longCID?.substring(longCID.length - 2);

              // TAC
              const localTac = lte_line?.split(",")[10]?.replace(/"/g, "");
              this.tac = localTac ? parseInt(localTac, 16) + " (" + localTac + ")" : "Unknown";

              if (longCID && shortCID) {
                this.cellID =
                  "Short " +
                  shortCID +
                  "(" +
                  parseInt(shortCID, 16) +
                  ")" +
                  ", " +
                  "Long " +
                  longCID +
                  "(" +
                  parseInt(longCID, 16) +
                  ")";
              }
              // CSQ
              this.csq = lines
                .find((line) => line.includes("+CSQ:"))
                ?.split(" ")[1]
                ?.replace("+CSQ: ", "")
                ?.replace(/"/g, "");

              // RSRP LTE
              this.rsrpLTE = lte_line?.split(",")[11]?.replace(/"/g, "");

              // RSRQ LTE
              this.rsrqLTE = lte_line?.split(",")[12]?.replace(/"/g, "");

              // SINR LTE
              this.sinrLTE = lte_line?.split(",")[14]?.replace(/"/g, "");

              // Calculate the RSRP LTE Percentage
              this.rsrpLTEPercentage = this.calculateRSRPPercentage(
                parseInt(this.rsrpLTE)
              );

              // Calculate the RSRQ LTE Percentage
              this.rsrqLTEPercentage = this.calculateRSRQPercentage(
                parseInt(this.rsrqLTE)
              );

              // Calculate the SINR LTE Percentage
              this.sinrLTEPercentage = this.calculateSINRPercentage(
                parseInt(this.sinrLTE)
              );

              // Calculate the Signal Percentage
              const lte_signal_percentage =
                this.calculateSignalPercentage(
                  this.rsrpLTEPercentage,
                  this.sinrLTEPercentage
                );

              // RSRP NR
              this.rsrpNR = nr5g_nsa_line?.split(",")[4]?.replace(/"/g, "");

              // SINR NR
              this.sinrNR = nr5g_nsa_line?.split(",")[5]?.replace(/"/g, "");

              // RSRQ NR
              this.rsrqNR = nr5g_nsa_line?.split(",")[6]?.replace(/"/g, "");

              // Calculate the RSRP NR Percentage
              this.rsrpNRPercentage = this.calculateRSRPPercentage(
                parseInt(this.rsrpNR)
              );

              // Calculate the RSRQ NR Percentage
              this.rsrqNRPercentage = this.calculateRSRQPercentage(
                parseInt(this.rsrqNR)
              );

              // Calculate the SINR NR Percentage
              this.sinrNRPercentage = this.calculateSINRPercentage(
                parseInt(this.sinrNR)
              );

              // Calculate the Signal Percentage
              const nr_signal_percentage = this.calculateSignalPercentage(
                this.rsrpNRPercentage,
                this.sinrNRPercentage
              );

              // Average the LTE and NR Signal Percentages
              this.signalPercentage =
                (lte_signal_percentage + nr_signal_percentage) / 2;

              // Calculate the Signal Assessment
              this.signalAssessment = this.signalQuality(
                this.signalPercentage
              );
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
              ?.split(",")[1];

            if (sim_status == 1) {
              this.simStatus = "Active";
            } else if (sim_status == 0) {
              this.simStatus = "No SIM";
            }

            // --- Active SIM ---
            const current_sim = lines
              .find((line) => line.includes("+QUIMSLOT:"))
              ?.split(" ")[1]
              ?.replace(/"/g, "");

            if (current_sim == 1) {
              this.activeSim = "SIM 1";
            } else if (current_sim == 2) {
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

            if (network_provider.match(/^[0-9]+$/) != null) {
              this.networkProvider = qspn_line?.split(",")[2]?.replace(/"/g, "") ?? "";
            } else {
              this.networkProvider = network_provider;
            }

            // --- MCCMNC ---
            this.mccmnc = qspn_line?.split(",")[4]?.replace(/"/g, "") ?? "";

            // --- APN ---
            this.apn = lines
              .find((line) => line.includes("+CGCONTRDP:"))
              ?.split(",")[2]
              ?.replace(/"/g, "") ?? "";

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
      if (bytes == 0) return "0 Byte";
      const i = parseInt(Math.floor(Math.log(bytes) / Math.log(1024)));
      return Math.round(bytes / Math.pow(1024, i), 2) + " " + sizes[i];
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
      let RSRP_min = -135;
      let RSRP_max = -65;

      // If rsrp is null, return 0%
      if (isNaN(rsrp) || rsrp < -140) {
        return 0;
      }

      let percentage = ((rsrp - RSRP_min) / (RSRP_max - RSRP_min)) * 100;

      if (percentage > 100) {
        percentage = 100;
      }

      // if percentage is less than 15%, make it 15%
      if (percentage < 15) {
        percentage = 15;
      }

      return Math.round(percentage);
    },

    calculateRSRQPercentage(rsrq) {
      let RSRQ_min = -20;
      let RSRQ_max = -8;

      // If rsrq is null, return 0%
      if (isNaN(rsrq) || rsrq < -20) {
        return 0;
      }

      let percentage = ((rsrq - RSRQ_min) / (RSRQ_max - RSRQ_min)) * 100;

      if (percentage > 100) {
        percentage = 100;
      }

      // if percentage is less than 15%, make it 15%
      if (percentage < 15) {
        percentage = 15;
      }

      return Math.round(percentage);
    },

    calculateSINRPercentage(sinr) {
      let SINR_min = -10;
      let SINR_max = 25;

      // If sinr is null, return 0%
      if (isNaN(sinr) || sinr < -10) {
        return 0;
      }

      let percentage = ((sinr - SINR_min) / (SINR_max - SINR_min)) * 100;

      if (percentage > 100) {
        percentage = 100;
      }

      // if percentage is less than 15%, make it 15%
      if (percentage < 15) {
        percentage = 15;
      }

      return Math.round(percentage);
    },

    // Calculate the overall signal assessment
    calculateSignalPercentage(rsrpPercentage, sinrPercentage) {
      // Get the average of the RSRP Percentage and SINR Percentage
      let average = (rsrpPercentage + sinrPercentage) / 2;
      return Math.round(average);
    },

    get tempColor() {
      const t = parseInt(this.temperature);
      if (isNaN(t))  return STATUS_COLOR_GREEN;
      if (t >= 75)   return STATUS_COLOR_RED;
      if (t >= 60)   return STATUS_COLOR_YELLOW;
      if (t >= 20)   return STATUS_COLOR_GREEN;
      return STATUS_COLOR_BLUE;
    },

    getProgressBarClass(pct) {
      const percentage = parseInt(pct);
      if (percentage >= 60) return 'progress-bar bg-success is-medium';
      if (percentage >= 40) return 'progress-bar bg-warning is-warning is-medium';
      return 'progress-bar bg-danger is-medium';
    },

    signalQuality(percentage) {
      if (percentage >= 80) {
        return "Excellent";
      } else if (percentage >= 60) {
        return "Good";
      } else if (percentage >= 40) {
        return "Fair";
      } else if (percentage >= 0) {
        return "Poor";
      } else {
        return "No Signal";
      }
    },

    fetchUpTime() {
      if (this.isUpTimeFetching) return;
      this.isUpTimeFetching = true;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 4000);
      authFetch("/cgi-bin/get_uptime", { signal: controller.signal })
        .then((response) => response.text())
        .then((data) => {
          // Example result
          // 01:17:02 up 3 days,  2:41,  load average: 0.65, 0.66, 0.60

          // Look for xx days in the result
          const days = data.match(/(\d+) day/);
          // Do the same for hours
          const hours = data.match(/(\d+) hour/);
          // Do the same for minutes
          const minutes = data.match(/(\d+) min/);
          // 2:41
          const hoursAndMinutes = data.match(/(\d+):(\d+),/);

          if (hoursAndMinutes != null) {
            if (days != null) {
              if (days[1] === "1") {
                if (hoursAndMinutes[1] === "1") {
                  this.uptime =
                    days[1] +
                    " day, " +
                    hoursAndMinutes[1] +
                    " hour " +
                    hoursAndMinutes[2] +
                    " minutes";
                } else if (hoursAndMinutes[2] === "1") {
                  this.uptime =
                    days[1] +
                    " day, " +
                    hoursAndMinutes[1] +
                    " hours " +
                    hoursAndMinutes[2] +
                    " minute";
                } else {
                  this.uptime =
                    days[1] +
                    " day, " +
                    hoursAndMinutes[1] +
                    " hours " +
                    hoursAndMinutes[2] +
                    " minutes";
                }
              } else {
                if (hoursAndMinutes[1] === "1") {
                  this.uptime =
                    days[1] +
                    " days, " +
                    hoursAndMinutes[1] +
                    " hour " +
                    hoursAndMinutes[2] +
                    " minutes";
                } else if (hoursAndMinutes[2] === "1") {
                  this.uptime =
                    days[1] +
                    " days, " +
                    hoursAndMinutes[1] +
                    " hours " +
                    hoursAndMinutes[2] +
                    " minute";
                } else {
                  this.uptime =
                    days[1] +
                    " days, " +
                    hoursAndMinutes[1] +
                    " hours " +
                    hoursAndMinutes[2] +
                    " minutes";
                }
              }
            } else {
              if (hoursAndMinutes[1] === "1") {
                this.uptime =
                  hoursAndMinutes[1] +
                  " hour " +
                  hoursAndMinutes[2] +
                  " minutes";
              } else if (hoursAndMinutes[2] === "1") {
                this.uptime =
                  hoursAndMinutes[1] +
                  " hours " +
                  hoursAndMinutes[2] +
                  " minute";
              } else {
                this.uptime =
                  hoursAndMinutes[1] +
                  " hours " +
                  hoursAndMinutes[2] +
                  " minutes";
              }
            }
          } else if (days != null) {
            if (hours != null) {
              if (days[1] === "1") {
                if (hours[1] === "1") {
                  this.uptime = days[1] + " day, " + hours[1] + " hour";
                } else {
                  this.uptime = days[1] + " day, " + hours[1] + " hours";
                }
              } else {
                if (hours[1] === "1") {
                  this.uptime = days[1] + " days, " + hours[1] + " hour";
                } else {
                  this.uptime = days[1] + " days, " + hours[1] + " hours";
                }
              }
            } else if (minutes != null) {
              if (days[1] === "1") {
                if (minutes[1] === "1") {
                  this.uptime =
                    days[1] + " day, " + minutes[1] + " minute";
                } else {
                  this.uptime =
                    days[1] + " day, " + minutes[1] + " minutes";
                }
              } else {
                if (minutes[1] === "1") {
                  this.uptime =
                    days[1] + " days, " + minutes[1] + " minute";
                } else {
                  this.uptime =
                    days[1] + " days, " + minutes[1] + " minutes";
                }
              }
            } else {
              if (days[1] === "1") {
                this.uptime = days[1] + " day";
              } else {
                this.uptime = days[1] + " days";
              }
            }
          } else if (hours != null) {
            if (hours[1] === "1") {
              this.uptime = hours[1] + " hour";
            } else {
              this.uptime = hours[1] + " hours";
            }
          } else if (minutes != null) {
            if (minutes[1] === "1") {
              this.uptime = minutes[1] + " minute";
            } else {
              this.uptime = minutes[1] + " minutes";
            }
          } else {
            this.uptime = "Unknown Time";
          }
        })
        .catch(() => {})
        .finally(() => { clearTimeout(timer); this.isUpTimeFetching = false; });
    },

    updateRefreshRate() {
      // Check if the refresh rate is less than 3
      if (this.newRefreshRate < 3) {
        this.newRefreshRate = 3;
      }

      // Clear the old interval
      clearInterval(this.intervalId);
      this.isFetching = false;

      // Set the refresh rate
      this.refreshRate = this.newRefreshRate;

      // Store the refresh rate in local storage or session storage
      localStorage.setItem("refreshRate", this.refreshRate);

      // Initialize with the new refresh rate
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
      // Fetch uptime
      this.fetchUpTime();

      // Retrieve the refresh rate from local storage or session storage
      const storedRefreshRate = localStorage.getItem("refreshRate");

      // If a refresh rate is stored, use it; otherwise, use a default value
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

      // Set the refresh rate for interval
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

      // Register resume handlers once only — re-registering on every init()
      // call caused duplicate/lost listeners on iOS Safari across multiple resumes.
      if (!this._handlersRegistered) {
        this._handlersRegistered = true;

        document.addEventListener('visibilitychange', () => {
          if (document.hidden) {
            clearInterval(this.intervalId);
            this.intervalId = null;
          } else {
            // Restart polling on resume. Reset flags in case Safari froze
            // the tab mid-request and the finally() block never ran.
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
