// GSM 03.38 default alphabet: 128 septet values, position = value. 0x1B escapes
// into the extension table; an escape code missing there renders as a space.
// Escape slot is String.fromCharCode(0x1B), not a raw control byte: editors and
// encoding conversions eat those, and losing it shifts every later entry.
const SMS_GSM7_BASIC =
  "@£$¥èéùìòÇ\nØø\rÅå" +
  "Δ_ΦΓΛΩΠΨΣΘΞ" + String.fromCharCode(0x1B) + "ÆæßÉ" +
  " !\"#¤%&'()*+,-./0123456789:;<=>?" +
  "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§" +
  "¿abcdefghijklmnopqrstuvwxyzäöñüà";

const SMS_GSM7_EXTENDED = {
  0x0A: "\f", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
  0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€"
};

// The delete CGI answers with a counted failure ("ERROR: 3 of 40 message parts
// could not be deleted", or the time-budget wording), and postForm carries that
// body in err.message. Show it, with the ERROR: prefix stripped and a hint that
// the refreshed list is authoritative. Falls back to a generic line if the
// rejection came from somewhere without a body, e.g. a network drop.
function deleteFailureText(err) {
  var body = (err && err.message ? String(err.message) : '').trim();
  if (!body || body.indexOf('ERROR') === -1) {
    return 'The messages could not be deleted.';
  }
  // "shows what is left" would read as "...parts left. ...what is left" against
  // the time-budget wording, which already says it.
  return body.replace(/^ERROR:\s*/, '').replace(/^./, function (c) {
    return c.toUpperCase();
  }) + '. The list below has been refreshed.';
}

function fetchSMS() {
  return {
    isLoading: false,
    messages: [],
    selectedMessages: [],

    clearData() {
      this.messages = [];
      this.selectedMessages = [];
      const selectAllCheckbox = document.getElementById('selectAllCheckbox');
      if (selectAllCheckbox) {
        selectAllCheckbox.checked = false;
      }
    },

    requestSMS() {
      this.isLoading = true;
      fetchText("/cgi-bin/get_sms", { method: "POST" })
        .then(data => {
          // get_sms reports a failed listing in the body (the CGI convention;
          // authFetch only rejects on the login redirect). Throwing keeps what
          // is on screen, since a partial listing parses as a complete shorter
          // inbox. +CMS/+CME match too: they terminate the command, so the CGI
          // exits 0 and passes them through. No false positives, as headers are
          // +CMGL: and bodies are hex.
          if (/^(\+CM[SE] )?ERROR/m.test(data)) throw new Error(data.trim());
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

    // Parse the PDU-mode listing (AT+CMGF=0, AT+CMGL=4): a
    // "+CMGL: <index>,<stat>,,<length>" header followed by one line of PDU hex.
    // PDU mode because only the UDH says which parts form one message and in
    // what order; text mode gives the decoded body alone.
    parseSMSData(data) {
      // Tests call this directly and reuse one instance across listings.
      this.messages = [];
      const lines = data.split('\n').map(line => line.trim());
      const parts = [];
      let textModeHeaders = 0;
      for (let i = 0; i < lines.length; i++) {
        // PDU-mode headers are all numeric; text mode quotes the status.
        // Distinguishes an upgrade mismatch (cached page vs new CGI) from data,
        // instead of decoding a text-mode body as a PDU.
        const header = /^\+CMGL:\s*(\d+),\s*\d+\s*,/.exec(lines[i]);
        if (!header) {
          if (/^\+CMGL:\s*\d+,\s*"/.test(lines[i])) textModeHeaders++;
          continue;
        }
        // Next non-empty line, not literally the next: requestSMS already
        // strips blanks, direct callers (the tests) do not.
        let j = i + 1;
        while (j < lines.length && lines[j] === '') j++;
        const hex = lines[j] ?? '';
        if (!/^[0-9A-Fa-f]+$/.test(hex) || hex.length % 2 !== 0) {
          console.error(`SMS index ${header[1]}: no PDU after its header`);
          continue;
        }
        const pdu = this.decodePDU(hex);
        if (pdu) parts.push(Object.assign(pdu, { index: parseInt(header[1], 10) }));
      }

      if (textModeHeaders > 0) {
        console.error(`get_sms returned ${textModeHeaders} text-mode entries; this page decodes PDUs. Reload after an update.`);
      }

      // Bucket by the sender's concatenation reference; a part with no UDH
      // stands alone.
      const buckets = new Map();
      for (const part of parts) {
        const key = part.concat
          ? `${part.sender} ${part.concat.ref} ${part.concat.total}`
          : `single ${part.index}`;
        if (!buckets.has(key)) buckets.set(key, []);
        buckets.get(key).push(part);
      }

      // A bucket is not a message: the 8-bit reference gets reused, so one
      // bucket can hold several (seen on a real inbox, 12 parts under one
      // reference, sequences 1-6 twice). Walk oldest first and close the open
      // message on a repeated sequence or when it is full; a repeat means the
      // next message started, complete or not.
      const groups = [];
      for (const bucket of buckets.values()) {
        bucket.sort((a, b) => a.date - b.date || a.index - b.index);
        let open = [];
        const close = () => { if (open.length) groups.push(open); open = []; };
        for (const part of bucket) {
          if (part.concat && open.some(p => p.concat.seq === part.concat.seq)) close();
          open.push(part);
          if (part.concat && open.length === part.concat.total) close();
        }
        close();
      }

      for (const group of groups) {
        group.sort((a, b) => (a.concat ? a.concat.seq : 0) - (b.concat ? b.concat.seq : 0));
        // Earliest part dates the message: parts of one message can carry
        // timestamps a second or two apart.
        const date = new Date(Math.min(...group.map(part => part.date.getTime())));
        this.messages.push({
          text: this.joinParts(group),
          sender: group[0].sender,
          date: date,
          displayDate: this.formatDate(date),
          // Every part's slot, so deleting the message deletes all of it.
          indices: group.map(part => part.index)
        });
      }

      // Sort newest-first by timestamp. Storage index is NOT reliably
      // chronological: the modem reuses freed low slots for new messages, so
      // reversing by index would misplace a recent message stored in a low slot.
      this.messages.sort((a, b) => b.date - a.date);
    },

    // Join a message's parts, already in sequence order. Runs of UCS2 parts are
    // joined as bytes and decoded once so a surrogate pair split across two
    // parts survives; text parts pass through. Per run and not one alphabet for
    // the whole group, because an aggregator can escalate to UCS2 mid-message.
    joinParts(group) {
      let out = '';
      let pending = [];
      const flushUcs2 = () => {
        if (pending.length === 0) return;
        const merged = new Uint8Array(pending.reduce((total, b) => total + b.length, 0));
        let offset = 0;
        for (const bytes of pending) {
          merged.set(bytes, offset);
          offset += bytes.length;
        }
        out += new TextDecoder('utf-16be').decode(merged);
        pending = [];
      };
      for (const part of group) {
        if (part.body === null) {
          flushUcs2();
          out += part.text;
        } else {
          pending.push(part.body);
        }
      }
      flushUcs2();
      return out;
    },

    // One SMS-DELIVER PDU (3GPP 23.040) -> { sender, date, text, body, concat }.
    // Null for anything else in the store, rather than reading another layout
    // as a DELIVER.
    decodePDU(hex) {
      const bytes = new Uint8Array((hex.match(/.{2}/g) ?? []).map(byte => parseInt(byte, 16)));
      let p = 0;
      p += 1 + bytes[0];                                  // service centre address
      const pduType = bytes[p++];
      if ((pduType & 0x03) !== 0x00) return null;         // not SMS-DELIVER
      const hasUDH = (pduType & 0x40) !== 0;

      const addrDigits = bytes[p++];
      const addrType = bytes[p++];
      const addrOctets = Math.ceil(addrDigits / 2);
      const sender = this.decodeAddress(addrType, bytes.slice(p, p + addrOctets), addrDigits);
      p += addrOctets;

      p += 1;                                             // protocol identifier
      const dcs = bytes[p++];
      const date = this.decodeTimestamp(bytes.slice(p, p + 7));
      p += 7;
      const udl = bytes[p++];

      // A truncated PDU reads past the end as undefined, giving an Invalid Date
      // that turns Math.min and the sort NaN and reorders good messages.
      // isFinite too: p itself can be NaN, and NaN comparisons are all false.
      if (!Number.isFinite(p) || p > bytes.length || isNaN(date.getTime())) {
        console.error('SMS: malformed or truncated PDU, skipped');
        return null;
      }

      // Alphabet is DCS bits 3-2 for the general groups only. The message
      // waiting groups reuse those bits: 0xCx/0xDx are always GSM-7 with bit 2
      // the indication flag (0xC4 is waiting-active, not 8-bit), 0xEx is the
      // UCS2 one. 0xFx uses bit 2 alone as the alphabet.
      const group = dcs & 0xF0;
      const alphabet = group === 0xF0 ? ((dcs & 0x04) ? 1 : 0)
        : group === 0xE0 ? 2
          : (group === 0xC0 || group === 0xD0) ? 0
            : (dcs >> 2) & 0x03;

      // 23.038 reserves value 3, and the sizing below assumes 0, 1 or 2: UDL
      // counts septets for alphabet 0 and octets otherwise, so a reserved value
      // unpacks an octet-sized slice as septets and decodes to plausible text.
      if (alphabet === 3) {
        console.error('SMS: PDU declares a reserved alphabet, skipped');
        return null;
      }

      // UDL counts septets for GSM-7 and octets for the rest, so it bounds the
      // user data only in the non-GSM-7 case. Unbounded, UCS2 would append
      // trailing padding.
      const ud = alphabet === 0 ? bytes.slice(p) : bytes.slice(p, p + udl);

      // Reject a PDU carrying less user data than its UDL declares. The septet
      // unpacker reads past the end as 0, which is "@" in GSM-7, so a short PDU
      // would decode as the real text plus a run of @ rather than as an error.
      // GSM-7 packs udl septets into ceil(udl * 7 / 8) octets; the others are
      // one octet per unit.
      const udOctets = alphabet === 0 ? Math.ceil((udl * 7) / 8) : udl;
      if (ud.length < udOctets) {
        console.error('SMS: PDU carries less user data than its UDL declares, skipped');
        return null;
      }

      let concat = null;
      const udhOctets = hasUDH ? ud[0] + 1 : 0;
      if (hasUDH) {
        for (let q = 1; q < udhOctets;) {
          const iei = ud[q], len = ud[q + 1], value = ud.slice(q + 2, q + 2 + len);
          if (iei === 0x00 && len >= 3) concat = { ref: value[0], total: value[1], seq: value[2] };
          else if (iei === 0x08 && len >= 4) concat = { ref: (value[0] << 8) | value[1], total: value[2], seq: value[3] };
          q += 2 + len;
        }
      }

      // UCS2 returns bytes, not text: a surrogate pair split across two parts
      // decodes to two U+FFFD if each part is decoded alone, so the caller
      // joins bytes and decodes once. GSM-7 is one septet per character.
      let text = null, body = null;
      if (alphabet === 2) {
        body = ud.slice(udhOctets);
      } else if (alphabet === 1) {
        text = Array.from(ud.slice(udhOctets), byte => String.fromCharCode(byte)).join('');
      } else {
        // Body starts on the septet boundary after the UDH. Counting the UDH in
        // septets rather than octets is what accounts for the fill bits.
        const udhSeptets = Math.ceil((udhOctets * 8) / 7);
        text = this.decodeGSM7(this.unpackSeptets(ud, udhSeptets * 7, udl - udhSeptets));
      }
      return { sender: sender, date: date, text: text, body: body, concat: concat };
    },

    // Semi-octet digits, or a GSM-7 packed alphanumeric sender - which is what
    // a short code or an operator brand name arrives as.
    decodeAddress(type, bytes, digits) {
      if ((type & 0x70) === 0x50) {
        return this.decodeGSM7(this.unpackSeptets(bytes, 0, Math.floor((digits * 4) / 7)));
      }
      let out = '';
      for (const byte of bytes) {
        out += (byte & 0x0F).toString(16) + ((byte >> 4) & 0x0F).toString(16);
      }
      out = out.slice(0, digits).replace(/f/gi, '');
      return ((type & 0x70) === 0x10 ? '+' : '') + out;
    },

    // Service centre timestamp: semi-octet BCD, then a quarter-hour offset with
    // its sign in bit 3 of the first semi-octet. Applying the offset gives a
    // real instant, so ordering survives a change of time zone.
    decodeTimestamp(bytes) {
      const bcd = i => (bytes[i] & 0x0F) * 10 + ((bytes[i] >> 4) & 0x0F);
      const tz = bytes[6];
      const quarters = (tz & 0x07) * 10 + ((tz >> 4) & 0x0F);
      const offsetMinutes = ((tz & 0x08) ? -1 : 1) * quarters * 15;
      return new Date(Date.UTC(2000 + bcd(0), bcd(1) - 1, bcd(2), bcd(3), bcd(4), bcd(5)) - offsetMinutes * 60000);
    },

    // Seven-bit values packed across octet boundaries. Takes a bit offset, not
    // an octet one, so a caller can skip a UDH and its fill bits in one step.
    unpackSeptets(bytes, startBit, count) {
      const septets = [];
      for (let i = 0; i < Math.max(0, count); i++) {
        const bit = startBit + i * 7;
        const index = bit >> 3, shift = bit & 7;
        let value = (bytes[index] ?? 0) >> shift;
        if (shift > 1) value |= (bytes[index + 1] ?? 0) << (8 - shift);
        septets.push(value & 0x7F);
      }
      return septets;
    },

    decodeGSM7(septets) {
      let out = '';
      for (let i = 0; i < septets.length; i++) {
        if (septets[i] === 0x1B) out += SMS_GSM7_EXTENDED[septets[++i]] ?? ' ';
        else out += SMS_GSM7_BASIC[septets[i]] ?? '';
      }
      return out;
    },

    formatDate(date) {
      return date.toLocaleString([], { hour12: false });
    },

    // Always by index, even when everything is selected. A "delete all" call
    // would erase the whole store, including messages that arrived while the
    // page was open; these indices are exactly what the user saw.
    deleteSelectedSMS() {
      if (this.selectedMessages.length === 0) return;
      if (this.messages.length === 0) return;

      const indicesToDelete = [];
      this.selectedMessages.forEach(index => {
        indicesToDelete.push(...this.messages[index].indices);
      });
      if (indicesToDelete.length === 0) return;

      // postForm rejects on ERROR in the body (the CGI convention), which is
      // what separates a delete that erased nothing from one that worked.
      // A session that expires mid-delete rejects with SessionExpiredError
      // while authFetch is already redirecting to login. Reporting a delete
      // failure there is wrong, and refreshing against a dead session is
      // pointless, so the flag skips both. Same guard as js/network.js.
      // isLoading drives the spinner AND disables the button. A delete of many
      // parts can run for seconds, and without this the page looks idle, so a
      // second click re-POSTs every index and queues behind the first on the
      // serialized AT port.
      this.isLoading = true;
      let expired = false;
      postForm("/cgi-bin/delete_sms", { indices: indicesToDelete.join(',') })
        .catch((err) => {
          if (isSessionExpired(err)) { expired = true; return; }
          // postForm rejects with the CGI's own body, which counts the parts
          // that still hold a message or were left when the budget expired.
          // Surfacing it is the point: a fixed string would hide the scale.
          this.$store.errorModal.open(deleteFailureText(err));
        })
        .finally(() => {
          this.isLoading = false;
          if (expired) return;
          this.selectedMessages = [];
          this.requestSMS();
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
