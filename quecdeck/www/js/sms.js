function fetchSMS() {
  return {
    isLoading: false,
    messages: [],
    senders: [],
    dates: [],
    selectedMessages: [],
    messageIndices: [],

    clearData() {
      this.messages = [];
      this.senders = [];
      this.dates = [];
      this.selectedMessages = [];
      this.messageIndices = [];
      const selectAllCheckbox = document.getElementById('selectAllCheckbox');
      if (selectAllCheckbox) {
        selectAllCheckbox.checked = false;
      }
    },

    requestSMS() {
      this.isLoading = true;
      authFetch("/cgi-bin/get_sms", { method: "POST" })
        .then(response => response.text())
        .then(data => {
          const filtered = data.split('\n')
            .filter(line => line.trim() !== "OK" && line.trim() !== "")
            .join('\n');
          this.clearData();
          this.parseSMSData(filtered);
        })
        .catch(() => {
          this.$store.errorModal.open('Failed to load messages. Please refresh the page.');
        })
        .finally(() => {
          this.isLoading = false;
        });
    },

    parseSMSData(data) {
      const cmglRegex = /^\s*\+CMGL:\s*(\d+),"[^"]*","([^"]*)"[^"]*,"([^"]*)"/gm;
      this.messageIndices = [];
      this.dates = [];
      this.senders = [];
      this.messages = [];
      let match;
      let lastIndex = null;
      while ((match = cmglRegex.exec(data)) !== null) {
        const index = parseInt(match[1]);
        const senderHex = match[2];
         // Maximum world wide phone number length is 17 (North Korea), UTF-16BE Hex string comes back at 48+ for US Number, min length is 3. 
         // When 3 digit SMS short code is used the result is a 12 length string (which we then need to check if the sender hex starts with 003 or 002B(+))
         // This check is probably completely unnecessary but I have no data on how the modems behave with different firmware (whether support for CSCS="UCS2" is available).
        const sender = senderHex.length > 11 && (senderHex.startsWith('002B') || senderHex.startsWith('003')) ? this.convertHexToText(senderHex) : senderHex;
        const dateStr = match[3].replace(/\+\d{2}$/, "");
        const date = this.parseCustomDate(dateStr);
        if (isNaN(date)) {
          console.error(`Invalid Date: ${dateStr}`);
          continue;
        }
        const startIndex = cmglRegex.lastIndex;
        const endIndex = data.indexOf("+CMGL:", startIndex) !== -1 ? data.indexOf("+CMGL:", startIndex) : data.length;
        const messageHex = data.substring(startIndex, endIndex).trim();
        const message = /^[0-9a-fA-F]+$/.test(messageHex) ? this.convertHexToText(messageHex) : messageHex;
        if (lastIndex !== null && this.messages[lastIndex].sender === sender && (date - this.messages[lastIndex].date) / 1000 <= 1) {
          this.messages[lastIndex].text += " " + message;
          this.messages[lastIndex].indices.push(index);
          this.dates[lastIndex] = this.formatDate(date);
        } else {
          this.messageIndices.push([index]);
          this.senders.push(sender);
          this.dates.push(this.formatDate(date));
          this.messages.push({ text: message, sender: sender, date: date, indices: [index] });
          lastIndex = this.messages.length - 1;
        }
      }
    },

    convertHexToText(hex) {
      const bytes = new Uint8Array((hex.match(/.{1,2}/g) ?? []).map(byte => parseInt(byte, 16)));
      return new TextDecoder('utf-16be').decode(bytes);
    },

    parseCustomDate(dateStr) {
      const [datePart, timePart] = dateStr.split(',');
      const [day, month, year] = datePart.split('/').map(part => parseInt(part, 10));
      const [hour, minute, second] = timePart.split(':').map(part => parseInt(part, 10));
      return new Date(Date.UTC(2000 + year, month - 1, day, hour, minute, second));
    },

    formatDate(date) {
      return date.toLocaleString([], { hour12: false });
    },

    deleteSelectedSMS() {
      if (this.selectedMessages.length === 0) return;
      if (!this.messageIndices || this.messageIndices.length === 0) return;

      const isAllSelected = this.selectedMessages.length === this.messages.length;

      if (isAllSelected) {
        this.deleteAllSMS();
      } else {
        const indicesToDelete = [];
        this.selectedMessages.forEach(index => {
          indicesToDelete.push(...this.messages[index].indices);
        });
        if (indicesToDelete.length === 0) return;

        authFetch("/cgi-bin/delete_sms", { method: "POST", body: new URLSearchParams({ indices: indicesToDelete.join(',') }) })
          .finally(() => {
            this.selectedMessages = [];
            this.requestSMS();
          });
      }
    },

    deleteAllSMS() {
      authFetch("/cgi-bin/delete_sms", { method: "POST", body: new URLSearchParams({ action: "all" }) })
        .finally(() => {
          this.init();
        });
    },

    init() {
      this.clearData();
      this.requestSMS();
    },

    toggleAll(event) {
      this.selectedMessages = event.target.checked ? this.messages.map((_, index) => index) : [];
    }
  };
}
