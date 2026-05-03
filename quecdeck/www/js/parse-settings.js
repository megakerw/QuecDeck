function parseCurrentSettings(rawdata) {
  const lines = rawdata.split("\n");

  const safeParse = (predicate, splitChar, index, fallback = "-") => {
    try {
      const line = lines.find(predicate);
      if (!line) return fallback;
      return line.split(splitChar)[index].replace(/\"/g, "").trim();
    } catch {
      return fallback;
    }
  };

  const sim = safeParse(
    (line) => line.includes("QUIMSLOT: 1") || line.includes("QUIMSLOT: 2"),
    ":", 1, "-"
  ).replace(/\s/g, "");

  let apn;
  try {
    apn = lines
      .find((line) => line.includes("+CGDCONT: 1"))
      .split(",")[2]
      .replace(/\"/g, "")
      .trim();
  } catch (error) {
    apn = "Failed fetching APN";
  }

  const cellLock4GStatus = safeParse(
    (line) => line.includes('+QNWLOCK: "common/4g"'), ",", 1, "0"
  );

  const cellLock5GStatus = safeParse(
    (line) => line.includes('+QNWLOCK: "common/5g"'), ",", 1, "0"
  );

  const prefNetwork = safeParse(
    (line) => line.includes('+QNWPREFCFG: "mode_pref"'), ",", 1
  );

  const nrModeControlStatus = safeParse(
    (line) => line.includes('+QNWPREFCFG: "nr5g_disable_mode"'), ",", 1, "0"
  );

  const ratAcqOrder = safeParse(
    (line) => line.includes('+QNWPREFCFG: "rat_acq_order"'), ",", 1
  );

  const roamPref = safeParse(
    (line) => line.includes('+QNWPREFCFG: "roam_pref"'), ",", 1
  );

  const mbnAutoSel = safeParse(
    (line) => line.includes('+QMBNCFG: "AutoSel"'), ",", 1
  );

  const apnIP = safeParse(
    (line) => line.includes("+CGDCONT: 1"), ",", 1
  );

  const formatBand = (raw) => {
    const lte = raw.match(/LTE BAND (\d+)/);
    if (lte) return "B" + lte[1];
    const nr = raw.match(/NR5G BAND (\d+)/);
    if (nr) return "N" + nr[1];
    return raw;
  };

  let bands;
  try {
    const pccRaw = lines
      .find((line) => line.includes('+QCAINFO: "PCC"'))
      .split(",")[3]
      .replace(/\"/g, "")
      .trim();
    const pccFormatted = formatBand(pccRaw) + " (PCC)";

    const sccFormatted = lines
      .filter((line) => line.includes('+QCAINFO: "SCC"'))
      .map((line) => formatBand(line.split(",")[3].replace(/\"/g, "").trim()))
      .filter(Boolean)
      .join(", ");

    bands = sccFormatted ? `${pccFormatted}, ${sccFormatted}` : pccFormatted;
  } catch (error) {
    bands = "Failed fetching bands";
  }

  let cellLockStatus;
  if (cellLock4GStatus === "1" && cellLock5GStatus === "1") {
    cellLockStatus = "Locked to 4G and 5G";
  } else if (cellLock4GStatus === "1") {
    cellLockStatus = "Locked to 4G";
  } else if (cellLock5GStatus === "1") {
    cellLockStatus = "Locked to 5G";
  } else {
    cellLockStatus = "Not Locked";
  }

  const nrModeControlDisplayMap = { "0": "NSA & SA", "1": "NR5G-SA Disabled", "2": "NR5G-NSA Disabled" };
  const nrModeControlDisplay = nrModeControlDisplayMap[nrModeControlStatus] || nrModeControlStatus;

  return {
    sim,
    apn,
    apnIP,
    cellLockStatus,
    prefNetwork,
    nrModeControl: nrModeControlStatus,
    nrModeControlDisplay,
    ratAcqOrder,
    roamPref,
    mbnAutoSel,
    bands,
  };
}
