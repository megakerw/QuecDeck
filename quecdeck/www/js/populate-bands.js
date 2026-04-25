function populateBands(lte_band, nsa_nr5g_band, nr5g_band, locked_lte_bands, locked_nsa_bands, locked_sa_bands) {
  var bandForm = document.getElementById("bandForm");
  var selectedMode = document.getElementById("networkModeBand").value;
  var bands;
  var prefix;

  // Determine bands and prefix based on selected network mode
  if (selectedMode === "LTE") {
    bands = lte_band;
    prefix = "B";
  } else if (selectedMode === "NSA") {
    bands = nsa_nr5g_band;
    prefix = "N";
  } else if (selectedMode === "SA") {
    bands = nr5g_band;
    prefix = "N";
  }

  bandForm.innerHTML = ""; // Clear existing buttons

  // Store the locked bands in arrays
  var locked_lte_bands_array = locked_lte_bands.split(":");
  var locked_nsa_bands_array = locked_nsa_bands.split(":");
  var locked_sa_bands_array = locked_sa_bands.split(":");

  var isBandLocked = function(band) {
    if (selectedMode === "LTE" && locked_lte_bands_array.includes(band)) {
      return true;
    }
    if (selectedMode === "NSA" && locked_nsa_bands_array.includes(band)) {
      return true;
    }
    if (selectedMode === "SA" && locked_sa_bands_array.includes(band)) {
      return true;
    }
    return false;
  };

  var fragment = document.createDocumentFragment();

  if (bands !== null && bands !== "0") {
    var bandsArray = bands.split(":");
    var wrapRow = document.createElement("div");
    wrapRow.className = "d-flex flex-wrap gap-2 mb-2";
    fragment.appendChild(wrapRow);

    bandsArray.forEach(function(band) {
      var bandInput = document.createElement("input");
      bandInput.className = "btn-check";
      bandInput.type = "checkbox";
      bandInput.id = "bandBtn" + band;
      bandInput.value = band;
      bandInput.autocomplete = "off";
      bandInput.checked = isBandLocked(band);

      var bandLabel = document.createElement("label");
      bandLabel.className = "btn btn-sm btn-outline-primary";
      bandLabel.htmlFor = "bandBtn" + band;
      bandLabel.innerText = prefix + band;

      wrapRow.appendChild(bandInput);
      wrapRow.appendChild(bandLabel);
    });
  } else {
    // Create a text saying that no bands are available
    var noBandsText = document.createElement("p");
    noBandsText.className = "text-center";
    noBandsText.innerText = "No supported bands available";
    fragment.appendChild(noBandsText);
  }

  bandForm.appendChild(fragment);
}
