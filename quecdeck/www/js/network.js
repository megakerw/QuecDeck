function cellLocking() {
  return {
    isLoading: false,
    networkModeCell: "-",
    cells: Array.from({ length: 10 }, () => ({ earfcn: null, pci: null })),
    scs: null,
    band: null,
    apn: "-",
    apnIP: "-",
    newApnIP: null,
    newApn: null,
    prefNetwork: "-",
    autoMode: false,
    networkModes: [
      { id: "LTE", label: "LTE (4G)", enabled: true },
      { id: "NR5G", label: "NR5G (5G)", enabled: true },
    ],
    mbnAutoSel: "-",
    mbnAutoSelFetched: "-",
    nrModeControl: "-",
    nrModeControlFetched: "-",
    nrModeControlDisplay: "-",
    ratAcqOrder: "-",
    ratAcqOrderFetched: "-",
    roamPref: "-",
    roamPrefFetched: "-",
    ratAcqModes: [
      { id: "NR5G", label: "NR5G (5G)" },
      { id: "LTE", label: "LTE (4G)" },
      { id: "WCDMA", label: "WCDMA (3G)" },
    ],
    cellNum: null,
    lte_bands: null,
    nsa_bands: null,
    sa_bands: null,
    locked_lte_bands: null,
    locked_nsa_bands: null,
    locked_sa_bands: null,
    sim: "-",
    newSim: null,
    cellLockStatus: "Unknown",
    bands: "Fetching Bands...",
    isGettingBands: false,
    allBandsChecked: false,

    toggleAllBands() {
      const checkboxes = document.querySelectorAll('#bandForm input[type="checkbox"]');
      const allChecked = Array.from(checkboxes).every((cb) => cb.checked);
      checkboxes.forEach((cb) => { cb.checked = !allChecked; });
      this.allBandsChecked = !allChecked;
    },

    syncBandToggleState() {
      const checkboxes = document.querySelectorAll('#bandForm input[type="checkbox"]');
      this.allBandsChecked = checkboxes.length > 0 && Array.from(checkboxes).every((cb) => cb.checked);
    },

    getModePrefString() {
      if (this.autoMode) return "AUTO";
      const enabled = this.networkModes.filter((m) => m.enabled).map((m) => m.id);
      return enabled.length ? enabled.join(":") : "AUTO";
    },

    disableAllNetworkModes() {
      if (this.autoMode) this.networkModes.forEach(m => { m.enabled = false; });
    },

    onNetworkModeChange(mode) {
      if (mode.enabled) {
        this.autoMode = false;
      } else if (!this.networkModes.some(m => m.enabled)) {
        this.autoMode = true;
      }
    },

    get nr5gEnabled() {
      return this.autoMode || !!this.networkModes.find(m => m.id === 'NR5G' && m.enabled);
    },

    setNetworkModesFromPref(pref) {
      const allModes = [
        { id: "LTE", label: "LTE (4G)" },
        { id: "NR5G", label: "NR5G (5G)" },
      ];
      if (!pref || pref === "-" || pref === "AUTO") {
        this.autoMode = pref === "AUTO";
        this.networkModes = allModes.map((m) => ({ ...m, enabled: !this.autoMode }));
        return;
      }
      this.autoMode = false;
      const parts = pref.split(":");
      const ordered = parts
        .map((id) => {
          const m = allModes.find((m) => m.id === id);
          return m ? { ...m, enabled: true } : { id, label: id, enabled: true };
        });
      allModes.forEach((m) => {
        if (!ordered.find((o) => o.id === m.id)) {
          ordered.push({ ...m, enabled: false });
        }
      });
      this.networkModes = ordered;
    },


    getRatAcqString() {
      return this.ratAcqModes.map((r) => r.id).join(":");
    },


    setRatAcqFromFetched(pref) {
      const allRats = [
        { id: "NR5G", label: "NR5G (5G)" },
        { id: "LTE", label: "LTE (4G)" },
        { id: "WCDMA", label: "WCDMA (3G)" },
      ];
      if (!pref || pref === "-") {
        this.ratAcqModes = allRats.map((r) => ({ ...r }));
        return;
      }
      const parts = pref.split(":");
      this.ratAcqModes = parts.map((id) => {
        const r = allRats.find((r) => r.id === id);
        return r ? { ...r } : { id, label: id };
      });
    },

    moveRatAcqUp(index) {
      if (index > 0) {
        const tmp = this.ratAcqModes[index - 1];
        this.ratAcqModes[index - 1] = this.ratAcqModes[index];
        this.ratAcqModes[index] = tmp;
        this.ratAcqModes = [...this.ratAcqModes];
      }
    },

    moveRatAcqDown(index) {
      if (index < this.ratAcqModes.length - 1) {
        const tmp = this.ratAcqModes[index + 1];
        this.ratAcqModes[index + 1] = this.ratAcqModes[index];
        this.ratAcqModes[index] = tmp;
        this.ratAcqModes = [...this.ratAcqModes];
      }
    },


    parseSupportedBands(rawdata) {
      const regex = /"([^"]+)",([0-9:]+)/g;

      // Object to store the results
      const bands = {};

      let match;
      while ((match = regex.exec(rawdata)) !== null) {
        const bandType = match[1];
        const numbers = match[2].split(":").map(Number);
        bands[bandType] = numbers;
      }

      // Separate the bands for each network mode
      this.lte_bands = bands.lte_band.join(":");
      this.nsa_bands = bands.nsa_nr5g_band.join(":");
      this.sa_bands = bands.nr5g_band.join(":");

      // Show checkboxes immediately with no locked state — parseLockedBands
      // will call populateBands again once locked bands are fetched.
      populateBands(
        this.lte_bands,
        this.nsa_bands,
        this.sa_bands,
        "",
        "",
        ""
      );
      this.syncBandToggleState();
    },


    parseLockedBands(rawdata) {
      const regex = /"([^"]+)",([0-9:]+)/g;

      // Object to store the results
      const bands = {};

      let match;
      while ((match = regex.exec(rawdata)) !== null) {
        const bandType = match[1];
        const numbers = match[2].split(":").map(Number);
        bands[bandType] = numbers;
      }

      // Separate the bands for each network mode
      this.locked_lte_bands = bands.lte_band.join(":");
      this.locked_nsa_bands = bands.nsa_nr5g_band.join(":");
      this.locked_sa_bands = bands.nr5g_band.join(":");

      populateBands(
        this.lte_bands,
        this.nsa_bands,
        this.sa_bands,
        this.locked_lte_bands,
        this.locked_nsa_bands,
        this.locked_sa_bands
      );
      this.syncBandToggleState();
    },

    getAllNetworkInfo() {
      return this.fetchNetworkInfo()
        .then((rawdata) => {
          // Split combined AT response into policy vs locked band sections.
          // policy_band comes first (3 lines), locked bands follow (3 lines).
          // Both use the same +QNWPREFCFG: "bandtype",digits format, so we
          // distinguish them by first vs second occurrence of each band name.
          const bandNames = ['lte_band', 'nsa_nr5g_band', 'nr5g_band'];
          const seen = {};
          const policyLines = [];
          const lockedLines = [];
          for (const line of rawdata.split('\n')) {
            const m = line.match(/^\+QNWPREFCFG: "([^"]+)",([0-9:]+)/);
            if (m && bandNames.includes(m[1])) {
              seen[m[1]] = (seen[m[1]] || 0) + 1;
              (seen[m[1]] === 1 ? policyLines : lockedLines).push(line);
            }
          }
          this.parseSupportedBands(policyLines.join('\n'));
          this.parseLockedBands(lockedLines.join('\n'));
          const settings = parseCurrentSettings(rawdata);
          this.sim = settings.sim;
          this.apn = settings.apn;
          this.apnIP = settings.apnIP;
          this.newApn = settings.apn;
          this.newApnIP = settings.apnIP;
          this.cellLockStatus = settings.cellLockStatus;
          this.prefNetwork = settings.prefNetwork;
          this.setNetworkModesFromPref(settings.prefNetwork);
          this.nrModeControl = settings.nrModeControl;
          this.nrModeControlFetched = settings.nrModeControl;
          this.nrModeControlDisplay = settings.nrModeControlDisplay;
          this.ratAcqOrder = settings.ratAcqOrder;
          this.ratAcqOrderFetched = settings.ratAcqOrder;
          this.setRatAcqFromFetched(settings.ratAcqOrder);
          this.roamPref = settings.roamPref;
          this.roamPrefFetched = settings.roamPref;
          this.mbnAutoSel = settings.mbnAutoSel;
          this.mbnAutoSelFetched = settings.mbnAutoSel;
          this.bands = settings.bands;
          this.isGettingBands = false;
          if (settings.bands === "Failed fetching bands" && rawdata.includes("+CGCONTRDP:")) {
            // Only retry if there is an active data connection — QCAINFO only
            // returns band info when connected. Without a SIM or without a
            // connection, retrying would loop forever.
            setTimeout(() => this.init(), 6000);
          }
        })
        .catch(() => this.$store.errorModal.open('Failed to load network information. Please refresh the page.'));
    },

    init() {
      // Fetch all network data in a single request and populate the page.
      const loadNetworkData = () => {
        this.isGettingBands = true;
        Promise.resolve(this.getAllNetworkInfo()).finally(() => {
          this.isGettingBands = false;
        });
      };

      loadNetworkData();
      if (!this._networkModeHandler) {
        this._networkModeHandler = () => {
          if (this.lte_bands !== null) {
            // Band data already in memory — repopulate for the new mode instantly.
            populateBands(
              this.lte_bands,
              this.nsa_bands,
              this.sa_bands,
              this.locked_lte_bands ?? '',
              this.locked_nsa_bands ?? '',
              this.locked_sa_bands ?? ''
            );
            this.syncBandToggleState();
          } else {
            loadNetworkData();
          }
        };
        document.getElementById("networkModeBand")
          .addEventListener("change", this._networkModeHandler);
      }
    },
    lockSelectedBands() {
      const selectedMode = document.getElementById("networkModeBand").value;
      const checkedBands = [];
      document.querySelectorAll('#bandForm input[type="checkbox"]').forEach(cb => {
        if (cb.checked) checkedBands.push(cb.value);
      });

      if (!["LTE", "NSA", "SA"].includes(selectedMode)) {
        this.$store.errorModal.open("Invalid network mode selected");
        return;
      }

      const params = { mode: selectedMode };
      const bandStr = checkedBands.join(":");
      if (bandStr) params.bands = bandStr;

      this.postNetworkAction("/cgi-bin/set_bands", params);
      this.$store.waitModal.start("Applying Settings...", 10, () => this.init());
    },
    resetBandLocking() {
      this.postNetworkAction("/cgi-bin/set_bands", { mode: "restore" });
      this.$store.waitModal.start("Resetting Bands...", 5, () => this.init());
    },
    saveApnSettings() {
      const newApn = this.newApn;
      const newSim = this.newSim;
      const roamPref = this.roamPref;
      const mbnAutoSel = this.mbnAutoSel;

      const changes = {};

      const apnTextChanged = newApn !== null && newApn !== this.apn;
      const apnIPChanged = this.newApnIP !== null && this.newApnIP !== this.apnIP;
      if (apnTextChanged || apnIPChanged) {
        changes.apn = newApn !== null ? newApn : this.apn;
        changes.ip_type = this.newApnIP || this.apnIP || "IP";
      }

      if (newSim !== null) changes.sim = newSim;
      if (roamPref !== this.roamPrefFetched) changes.roam_pref = roamPref;
      if (mbnAutoSel !== this.mbnAutoSelFetched) changes.mbn = mbnAutoSel;

      if (Object.keys(changes).length === 0) {
        this.$store.errorModal.open("No changes made");
        return;
      }

      this.$store.confirmModal.open(
        'The modem will reboot to apply the new APN settings.',
        () => this.applySaveChanges(changes)
      );
    },
    saveNetworkPreferences() {
      const modePref = this.getModePrefString();
      const nrModeControl = this.nrModeControl;
      const ratAcqStr = this.getRatAcqString();

      const params = {};

      if (modePref !== this.prefNetwork) params.mode_pref = modePref;
      if (nrModeControl !== this.nrModeControlFetched) params.nr5g_mode = nrModeControl;
      if (ratAcqStr !== this.ratAcqOrderFetched) params.rat_acq = ratAcqStr;

      if (Object.keys(params).length === 0) {
        this.$store.errorModal.open("No changes made");
        return;
      }

      this.postNetworkAction("/cgi-bin/save_network_pref", params);
      this.$store.waitModal.start("Applying Network Preferences...", 10, () => this.init());
    },
    applySaveChanges(changes) {
      this.postNetworkAction("/cgi-bin/save_apn", changes);
      setTimeout(() => {
        authFetch("/cgi-bin/set_setting", { method: "POST", body: new URLSearchParams({ action: "reboot" }) }).catch(() => {});
      }, 5000);
      this.$store.waitModal.start("Rebooting...", 55, () => this.init());
    },
    cellLockEnableLTE() {
      const cellNum = this.cellNum;

      const isInt = (v) => /^\d+$/.test(String(v).trim());

      if (cellNum === null || !isInt(cellNum)) {
        this.$store.errorModal.open("Please enter a valid number of cells to lock");
        return;
      }

      const earfcnPciPairs = this.cells.slice(0, parseInt(cellNum));

      // Filter out pairs where either earfcn or pci is missing or non-integer
      const validPairs = earfcnPciPairs.filter(
        (pair) => pair.earfcn && pair.pci && isInt(pair.earfcn) && isInt(pair.pci)
      );

      if (validPairs.length === 0) {
        this.$store.errorModal.open("Please enter at least one valid EARFCN and PCI pair (integers only)");
        return;
      }

      const pairs = validPairs.map((pair) => `${pair.earfcn},${pair.pci}`).join(",");
      this.postNetworkAction("/cgi-bin/set_cell_lock", { type: "lte", count: cellNum, pairs });
      this.$store.waitModal.start("Applying Settings...", 3, () => this.init());
    },
    cellLockEnableNR() {
      const earfcn = this.cells[0].earfcn;
      const pci = this.cells[0].pci;
      const scs = this.scs;
      const band = this.band;

      if (!earfcn || !pci || !scs || scs === "SCS" || !band) {
        this.$store.errorModal.open("Please enter all the required fields");
        return;
      }

      if (!/^\d+$/.test(String(earfcn)) || !/^\d+$/.test(String(pci))) {
        this.$store.errorModal.open("EARFCN and PCI must be integers");
        return;
      }

      this.postNetworkAction("/cgi-bin/set_cell_lock", { type: "nr", earfcn, pci, scs, band });
      this.$store.waitModal.start("Applying Settings...", 3, () => this.init());
    },
    cellLockDisableLTE() {
      this.postNetworkAction("/cgi-bin/set_cell_lock", { type: "unlock_lte" });
      this.$store.waitModal.start("Applying Settings...", 3, () => this.init());
    },
    cellLockDisableNR() {
      this.postNetworkAction("/cgi-bin/set_cell_lock", { type: "unlock_nr" });
      this.$store.waitModal.start("Applying Settings...", 3, () => this.init());
    },
    fetchNetworkInfo() {
      return authFetch("/cgi-bin/get_network_info", {
        method: "POST",
      }).then((response) => response.text())
        .catch((error) => { console.error("Error:", error); throw error; });
    },

    postNetworkAction(endpoint, params) {
      return authFetch(endpoint, {
        method: "POST",
        body: new URLSearchParams(params),
      }).then((response) => response.text())
        .catch(() => this.$store.errorModal.open('Failed to apply network changes. Please try again.'));
    },
  };
}



