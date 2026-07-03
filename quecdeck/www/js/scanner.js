function cellScanner() {
  return {
    nr5g_cells: [],
    lte_cells: [],
    nr5g_cells_parsed: [],
    lte_cells_parsed: [],
    tableRows: [],
    nr5g_neighbourCells: [],
    lte_neighbourCells: [],
    nr5g_neighbourCellsParsed: [],
    lte_neighbourCellsParsed: [],
    neighbourCellsTableRows: [],
    cellScanMode: "Unspecified",
    neighbourCellsScanMode: "Unspecified",
    isLoading: false,
    resultDoneCell: false,
    resultDoneNeighbourCell: false,

    init() {
      this.generateNeighbourCellsTableRow();
      this.clearTableRowsBodyCellScan();
    },
    startCellScan() {
      // Make all arrays empty before starting a new scan
      this.nr5g_cells = [];
      this.lte_cells = [];
      this.nr5g_cells_parsed = [];
      this.lte_cells_parsed = [];
      this.tableRows = [];
      this.resultDoneCell = false;

      // Map UI mode to AT+QSCAN mode argument: 1=LTE, 2=NR5G, 3=both
      const atModeMap = { 'LTE Only': 1, 'NR5G Only': 2, 'Full Scan': 3 };
      const atMode = atModeMap[this.cellScanMode] || 3;

      this.isLoading = true;
      this.$store.scanBanner.ownScan = true;
      this.$store.waitModal.start('Scanning for cells...', 215, () => {
        this.isLoading = false;
      });

      authFetch("/cgi-bin/run_cell_scan", {
        method: "POST",
        body: new URLSearchParams({ mode: atMode }),
      })
        .then((res) => {
          return res.text();
        })
        .then((data) => {
          const lines = data.split("\n");

          // AT+QSCAN streams +QSCAN: URCs as cells are found, then sends OK
          // when the scan is complete. Filter by content, not position.
          for (let i = 0; i < lines.length; i++) {
            if (
              lines[i] !== "OK" &&
              lines[i] !== "" &&
              lines[i] !== "\r"
            ) {
              if (lines[i].match(/NR5G/g)) {
                this.nr5g_cells.push(lines[i]);
              } else if (lines[i].match(/LTE/g)) {
                this.lte_cells.push(lines[i]);
              }
            }
          }
        })
        .then(() => {
          this.parseNr5gCells();
        })
        .then(() => {
          this.parseLTECells();
        })
        .then(() => {
          this.generateTableRow();
          this.$store.waitModal.stop();
          this.isLoading = false;
          this.$store.scanBanner.ownScan = false;
          this.$store.scanBanner.active = false;
          this.resultDoneCell = true;
        })
        .catch(() => {
          this.$store.waitModal.stop();
          this.isLoading = false;
          this.$store.scanBanner.ownScan = false;
          this.$store.scanBanner.active = false;
          this.$store.errorModal.open('Cell scan failed. Please try again.');
        });
    },
    parseNr5gCells() {
      // Parse the NR5G cells
      for (let i = 0; i < this.nr5g_cells.length; i++) {
        let mcc, mnc, freq, pci, rsrp, band, provider;
        mcc = this.nr5g_cells[i].split(":")[1].split(",")[1];
        mnc = this.nr5g_cells[i].split(":")[1].split(",")[2];
        freq = this.nr5g_cells[i].split(":")[1].split(",")[3];
        pci = this.nr5g_cells[i].split(":")[1].split(",")[4];
        rsrp = this.nr5g_cells[i].split(":")[1].split(",")[5];
        band = this.nr5g_cells[i].split(":")[1].split(",")[12];

        provider = this.convertMCCMNCtoNetworkName(mcc, mnc);

        /// Append the value to lte_cells_parsed with this layout:
        // mcc mnc, band, freq, pci, rsrp
        this.nr5g_cells_parsed.push(
          `${provider}, ${band}, ${freq}, ${pci}, ${rsrp}`
        );
      }
    },

    parseLTECells() {
      for (let i = 0; i < this.lte_cells.length; i++) {
        let mcc, mnc, freq, pci, rsrp, band, provider;
        mcc = this.lte_cells[i].split(":")[1].split(",")[1];
        mnc = this.lte_cells[i].split(":")[1].split(",")[2];
        freq = this.lte_cells[i].split(":")[1].split(",")[3];
        pci = this.lte_cells[i].split(":")[1].split(",")[4];
        rsrp = this.lte_cells[i].split(":")[1].split(",")[5];
        band = this.lte_cells[i].split(":")[1].split(",")[12];

        provider = this.convertMCCMNCtoNetworkName(mcc, mnc);

        // Append the value to lte_cells_parsed with this layout:
        // mcc mnc, band, freq, pci, rsrp
        this.lte_cells_parsed.push(
          `${provider}, ${band}, ${freq}, ${pci}, ${rsrp}`
        );
      }
    },

    // Build and append a data row using DOM methods so modem data is
    // never interpreted as HTML. The svgHtml argument is always our own
    // hardcoded markup (from signalIconSVG), not modem data.
    _appendRow(tableBody, type, dataCells, svgHtml) {
      const tr = document.createElement('tr');
      const th = document.createElement('th');
      th.scope = 'row';
      th.textContent = type;
      tr.appendChild(th);
      for (const val of dataCells) {
        const td = document.createElement('td');
        td.textContent = val.trim();
        tr.appendChild(td);
      }
      const svgTd = document.createElement('td');
      svgTd.innerHTML = svgHtml;
      tr.appendChild(svgTd);
      tableBody.appendChild(tr);
    },

    generateTableRow() {
      const tableBody = document.getElementById("cellScanTableBody");
      tableBody.innerHTML = "";
      this.tableRows = [];

      if (this.cellScanMode === "Full Scan") {
        for (const row of this.nr5g_cells_parsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "NR5G", [f[0], f[1], f[2], f[3], f[4]], this.signalIconSVG(f[4]));
        }
        for (const row of this.lte_cells_parsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "LTE", [f[0], f[1], f[2], f[3], f[4]], this.signalIconSVG(f[4]));
        }
      } else if (this.cellScanMode === "NR5G Only") {
        for (const row of this.nr5g_cells_parsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "NR5G", [f[0], f[1], f[2], f[3], f[4]], this.signalIconSVG(f[4]));
        }
      } else if (this.cellScanMode === "LTE Only") {
        for (const row of this.lte_cells_parsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "LTE", [f[0], f[1], f[2], f[3], f[4]], this.signalIconSVG(f[4]));
        }
      }
    },

    convertMCCMNCtoNetworkName(mcc, mnc) {
      const mccmnc = mcc + mnc;
      return NETWORK_NAMES[mccmnc] || `${mcc} ${mnc}`;
    },

    getNeighbourcellLTEandNR5G() {
      // Reset the arrays before generating new rows
      this.lte_neighbourCells = [];
      this.nr5g_neighbourCells = [];
      this.lte_neighbourCellsParsed = [];
      this.nr5g_neighbourCellsParsed = [];
      this.neighbourCellsTableRows = [];
      this.resultDoneNeighbourCell = false;
      this.isLoading = true;
      this.$store.scanBanner.ownScan = true;
      this.$store.waitModal.start('Scanning neighbour cells... This may take up to 1 minute.', 60, () => {
        this.isLoading = false;
      });

      authFetch("/cgi-bin/get_neighbour_cells", {
        method: "POST",
      })
        .then((res) => {
          return res.text();
        })
        .then((data) => {
          let lines = data.split("\n");

          lines.splice(0, 1);
          lines.splice(lines.length - 3, 3);
          lines = lines.filter(l => l !== "" && l !== "\r");

          for (let i = 0; i < lines.length; i++) {
            if (lines[i].match(/LTE/g)) {
              this.lte_neighbourCells.push(lines[i]);
            } else if (lines[i].match(/NR5G/g)) {
              this.nr5g_neighbourCells.push(lines[i]);
            }
          }
        })
        .then(() => {
          this.lteNeighbourCellsParse();
        })
        .then(() => {
          this.nr5gNeighbourCellsParse();
        })
        .then(() => {
          this.generateNeighbourCellsTableRow();
          this.$store.waitModal.stop();
          this.isLoading = false;
          this.$store.scanBanner.ownScan = false;
          this.$store.scanBanner.active = false;
          this.resultDoneNeighbourCell = true;
        })
        .catch(() => {
          this.$store.waitModal.stop();
          this.isLoading = false;
          this.$store.scanBanner.ownScan = false;
          this.$store.scanBanner.active = false;
          this.$store.errorModal.open('Neighbour cell scan failed. Please try again.');
        });
    },

    lteNeighbourCellsParse() {
      for (let i = 0; i < this.lte_neighbourCells.length; i++) {
        let freq, pci, rsrp;
        freq = this.lte_neighbourCells[i].split(":")[1].split(",")[2];
        pci = this.lte_neighbourCells[i].split(":")[1].split(",")[3];
        rsrp = this.lte_neighbourCells[i].split(":")[1].split(",")[5];
        this.lte_neighbourCellsParsed.push(`${freq}, ${pci}, ${rsrp}`);
      }
    },

    nr5gNeighbourCellsParse() {
      for (let i = 0; i < this.nr5g_neighbourCells.length; i++) {
        let freq, pci, rsrp;
        freq = this.nr5g_neighbourCells[i].split(":")[1].split(",")[2];
        pci = this.nr5g_neighbourCells[i].split(":")[1].split(",")[3];
        rsrp = this.nr5g_neighbourCells[i].split(":")[1].split(",")[4];
        this.nr5g_neighbourCellsParsed.push(`${freq}, ${pci}, ${rsrp}`);
      }
    },

    generateNeighbourCellsTableRow() {
      this.neighbourCellsTableRows = [];
      const tableBody = document.getElementById("neighbourCellTableBody");
      tableBody.innerHTML = "";

      if (this.neighbourCellsScanMode === "LTE and NR5G") {
        for (const row of this.lte_neighbourCellsParsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "LTE", [f[0], f[1], f[2]], this.signalIconSVG(f[2]));
        }
        for (const row of this.nr5g_neighbourCellsParsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "NR5G", [f[0], f[1], f[2]], this.signalIconSVG(f[2]));
        }
      } else if (this.neighbourCellsScanMode === "LTE") {
        for (const row of this.lte_neighbourCellsParsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "LTE", [f[0], f[1], f[2]], this.signalIconSVG(f[2]));
        }
      } else if (this.neighbourCellsScanMode === "NR5G") {
        for (const row of this.nr5g_neighbourCellsParsed) {
          const f = row.split(",");
          this._appendRow(tableBody, "NR5G", [f[0], f[1], f[2]], this.signalIconSVG(f[2]));
        }
      }

      if (tableBody.rows.length === 0) {
        tableBody.innerHTML = '<tr><th scope="row">Empty</th><td>Empty</td><td>Empty</td><td>Empty</td><td>Empty</td></tr>';
      }
    },

    signalIconSVG(rsrp) {
      // If rsrp is -55 and above then use this svg
      if (parseInt(rsrp) >= -55) {
        return `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-signal-high"><path d="M2 20h.01"/><path d="M7 20v-4"/><path d="M12 20v-8"/><path d="M17 20V8"/></svg>`;
      } else if (parseInt(rsrp) >= -85) {
        return `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-signal-medium"><path d="M2 20h.01"/><path d="M7 20v-4"/><path d="M12 20v-8"/></svg>`;
      } else if (parseInt(rsrp) >= -95) {
        return `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-signal-low"><path d="M2 20h.01"/><path d="M7 20v-4"/></svg>`;
      } else {
        return `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-signal-zero"><path d="M2 20h.01"/></svg>`;
      }
    },

    clearTableRowsBodyCellScan() {
      this.lte_cells = [];
      this.nr5g_cells = [];
      this.lte_cells_parsed = [];
      this.nr5g_cells_parsed = [];
      this.tableRows = [];
      this.resultDoneCell = false;

      const tableBody = document.getElementById("cellScanTableBody");
      tableBody.innerHTML = '<tr><th scope="row">Empty</th><td>Empty</td><td>Empty</td><td>Empty</td><td>Empty</td><td>Empty</td><td>Empty</td></tr>';
    },

    clearTableRowsBodyNeighbourCells() {
      this.lte_neighbourCells = [];
      this.nr5g_neighbourCells = [];
      this.lte_neighbourCellsParsed = [];
      this.nr5g_neighbourCellsParsed = [];
      this.neighbourCellsTableRows = [];
      this.resultDoneNeighbourCell = false;

      const tableBody = document.getElementById("neighbourCellTableBody");
      tableBody.innerHTML = '<tr><th scope="row">Empty</th><td>Empty</td><td>Empty</td><td>Empty</td><td>Empty</td></tr>';
    },
  };
}

