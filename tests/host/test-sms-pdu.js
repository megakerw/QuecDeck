// Unit test for the SMS PDU decoder in quecdeck/www/js/sms.js.
//   node tests/host/test-sms-pdu.js
// Run by tests/host/ci-checks.sh where node exists. It loads the shipped file, so
// what is tested is what is served.
//
// Fixtures are hand-built, not captured: a capture would carry real messages,
// and these cover cases an inbox may not contain.
const fs = require('fs');
const path = require('path');

// eval returns the bindings explicitly: a `const` inside eval is not visible
// outside it, unlike the function declaration. The parse path touches no DOM.
// Renamed on the way out, or they collide with eval's own declarations.
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'quecdeck', 'www', 'js', 'sms.js'), 'utf8');
const { fetchSMS: makeSMS, SMS_GSM7_BASIC: gsm7Table,
        deleteFailureText: failureText } =
  eval(`${src}\n;({ fetchSMS, SMS_GSM7_BASIC, deleteFailureText })`);

// Shared prefix for every fixture below:
//   00        no SMSC address supplied
//   <type>    04 = SMS-DELIVER, 44 = the same with UDHI set
//   08 D0     address: 8 semi-octets, alphanumeric (TON 101)
//   D4E2940A  "TEST" packed as GSM-7 septets
//   00 <dcs>  protocol identifier, then data coding scheme
//   6270132100 0080  2026-07-31 12:00:00, +8 quarter-hours = +02:00
const ADDR = '08D0D4E2940A';
const SCTS = '62701321000080';
const deliver = (dcs, udl, ud, udhi) =>
  `00${udhi ? '44' : '04'}${ADDR}00${dcs}${SCTS}${udl}${ud}`;

// Concatenation UDH: UDHL=05, IEI=00 (8-bit reference), length 3, ref/total/seq.
const udh = (ref, total, seq) =>
  '050003' + [ref, total, seq].map(n => n.toString(16).padStart(2, '0')).join('');

// "AB<U+1F600>CD" in UTF-16BE. The surrogate pair is split down the middle
// across the two parts: decoded per part it yields two U+FFFD.
const ucs2Part1 = deliver('08', '0C', udh(0x2a, 2, 1) + '00410042D83D', true);
const ucs2Part2 = deliver('08', '0C', udh(0x2a, 2, 2) + 'DE0000430044', true);

// GSM-7 with a UDH: the body starts on the septet boundary after 6 UDH octets,
// so it is offset by fill bits. "Hi" = septets 0x48 0x69, packed from bit 49.
const gsm7Concat = deliver('00', '09', udh(0x2b, 2, 1) + '9069', true);
// GSM-7 with no UDH at all: "Hi" packed from bit 0.
const gsm7Single = deliver('00', '02', 'C834', false);

// Per 27.005 <length> counts the TPDU only, excluding the SMSC octets. The
// decoder ignores the field; the fixtures state it right to stay a reference.
const tpduLength = pdu => pdu.length / 2 - (1 + parseInt(pdu.slice(0, 2), 16));

const listing = entries => entries
  .map(([index, pdu]) => `+CMGL: ${index},1,,${tpduLength(pdu)}\n${pdu}`)
  .join('\n');

let failures = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}${ok ? '' : ` (${detail})`}`);
  if (!ok) failures++;
};

// Parts listed out of order and in non-adjacent slots: exactly what defeated
// the old storage-adjacency heuristic.
const sms = makeSMS();
sms.parseSMSData(listing([[7, ucs2Part2], [3, gsm7Single], [1, ucs2Part1], [9, gsm7Concat]]));

check('one message per concatenation reference', sms.messages.length === 3, `${sms.messages.length}`);

const ucs2 = sms.messages.find(m => m.text.startsWith('AB'));
check('split surrogate pair survives reassembly', ucs2 && ucs2.text === 'AB\u{1F600}CD',
  ucs2 && JSON.stringify(ucs2.text));
check('parts ordered by sequence, not by listing order', ucs2 && ucs2.indices.join(',') === '1,7',
  ucs2 && ucs2.indices.join(','));
check('alphanumeric sender decoded', ucs2 && ucs2.sender === 'TEST', ucs2 && ucs2.sender);
check('timestamp read with its zone offset',
  ucs2 && ucs2.date.toISOString() === '2026-07-31T10:00:00.000Z',
  ucs2 && ucs2.date.toISOString());

const withUdh = sms.messages.find(m => m.indices.includes(9));
check('GSM-7 body after a UDH skips the fill bits', withUdh && withUdh.text === 'Hi',
  withUdh && JSON.stringify(withUdh.text));

const noUdh = sms.messages.find(m => m.indices.includes(3));
check('GSM-7 with no UDH decodes', noUdh && noUdh.text === 'Hi', noUdh && JSON.stringify(noUdh.text));
check('an unconcatenated message stands alone', noUdh && noUdh.indices.length === 1);

// The alphabet table must stay positionally exact: a lost entry shifts every
// character after it, and 0x1B is an invisible escape that is easy to drop.
check('GSM-7 alphabet is 128 entries', gsm7Table.length === 128, `${gsm7Table.length}`);
check('escape slot is at 0x1B', gsm7Table.charCodeAt(0x1B) === 0x1B);
check('entries after the escape are not shifted', gsm7Table[0x1F] === 'É',
  gsm7Table[0x1F]);

// Reference reuse: two messages sharing one (sender, ref, total), seen on a
// real inbox as 12 parts under one reference with sequences 1-6 twice. They
// must not join into one interleaved message.
// Times are semi-octet BCD, low nibble is the tens digit: 12h = 0x21, 13h =
// 0x31. UDL 8 = 6 UDH octets + 2 body, since UCS2 counts octets.
const scts = hhmmss => `627013${hhmmss}80`;
const reuse = (seq, letter, at) =>
  `0044${ADDR}0008${scts(at)}08${udh(0x5e, 2, seq)}00${letter}`;
const reuseA1 = reuse(1, '41', '210000');  // "A", 12:00:00
const reuseA2 = reuse(2, '42', '211000');  // "B", 12:01:00
const reuseB1 = reuse(1, '43', '310000');  // "C", 13:00:00
const reuseB2 = reuse(2, '44', '311000');  // "D", 13:01:00

const collided = makeSMS();
collided.parseSMSData(listing([[20, reuseB2], [11, reuseA1], [21, reuseB1], [12, reuseA2]]));
check('a reused reference yields two messages, not one',
  collided.messages.length === 2, `${collided.messages.length}`);
check('reused-reference messages keep their own parts',
  collided.messages.map(m => m.text).sort().join('|') === 'AB|CD',
  JSON.stringify(collided.messages.map(m => m.text)));

// Real listings are separated by blank lines and wrapped in the echoed command
// and its terminator; none of that may displace the PDU that follows a header.
const framed = makeSMS();
framed.parseSMSData(`AT+CMGL=4\n\n+CSCA: "+99900000000",145\n\n+CMGL: 4,1,,${tpduLength(gsm7Single)}\n\n${gsm7Single}\n\nOK\n`);
check('blank lines and surrounding output do not lose the PDU',
  framed.messages.length === 1 && framed.messages[0].text === 'Hi',
  JSON.stringify(framed.messages));

// A text-mode listing must not be decoded as PDUs during an upgrade.
const logged = [];
const realError = console.error;
console.error = msg => logged.push(msg);
const stale = makeSMS();
stale.parseSMSData('+CMGL: 1,"REC READ","0036",,"26/07/29,10:14:26+08"\n004800610072');
console.error = realError;
check('text-mode listing yields no messages', stale.messages.length === 0, `${stale.messages.length}`);
check('text-mode listing is reported', logged.some(m => /text-mode/.test(m)));

// A concatenated message whose parts change alphabet mid-way, which happens
// when an aggregator escalates to UCS2 after the first part. Choosing the join
// strategy from the first part alone hands a null body to Uint8Array.set: the
// throw escapes parseSMSData, so the page shows an empty inbox and an error
// instead of one message. Caught here rather than asserted on, so a regression
// reports as a failed check and not as a crashed test run.
const mixedGsm7 = deliver('00', '09', udh(0x6a, 2, 1) + '9069', true);      // "Hi"
const mixedUcs2 = deliver('08', '0A', udh(0x6a, 2, 2) + '00430044', true);  // "CD"
const mixed = makeSMS();
let mixedError = null;
try {
  mixed.parseSMSData(listing([[30, mixedGsm7], [31, mixedUcs2]]));
} catch (e) {
  mixedError = e;
}
check('a concat message that changes alphabet does not throw',
  mixedError === null, mixedError && mixedError.message);
check('mixed-alphabet parts join in sequence order',
  mixed.messages.length === 1 && mixed.messages[0].text === 'HiCD',
  JSON.stringify(mixed.messages.map(m => m.text)));

// A PDU declaring more user data than it carries. The septet unpacker reads
// past the end as 0, which is "@" in GSM-7, so without the length check this
// decodes as the real text followed by a run of @ - wrong text, no error.
// UDL 6 septets needs ceil(6 * 7 / 8) = 6 octets; the fixture supplies 2.
const shortUd = deliver('00', '06', 'C834', false);
const shortLog = [];
const realErrorShort = console.error;
console.error = msg => shortLog.push(msg);
const short = makeSMS();
short.parseSMSData(listing([[40, shortUd]]));
console.error = realErrorShort;
check('a PDU shorter than its UDL is rejected', short.messages.length === 0,
  JSON.stringify(short.messages.map(m => m.text)));
check('a short PDU is reported', shortLog.some(m => /user data/.test(m)),
  JSON.stringify(shortLog));

// DCS 0x0C: general group, alphabet bits 3-2 = 3, which 23.038 reserves. There
// is no alphabet to decode it with, and falling through to GSM-7 would unpack
// an octet-sized slice as septets - plausible text, silently wrong.
const reservedDcs = deliver('0C', '02', 'C834', false);
const reservedLog = [];
const realErrorReserved = console.error;
console.error = msg => reservedLog.push(msg);
const reserved = makeSMS();
reserved.parseSMSData(listing([[50, reservedDcs]]));
console.error = realErrorReserved;
check('a reserved alphabet is rejected', reserved.messages.length === 0,
  JSON.stringify(reserved.messages.map(m => m.text)));
check('a reserved alphabet is reported', reservedLog.some(m => /reserved alphabet/.test(m)),
  JSON.stringify(reservedLog));

// ---- deleteFailureText -------------------------------------------------
// cgi-bin/delete_sms answers with a COUNTED failure, and the whole point of
// surfacing it is that "3 of 40" tells the user the scale. A fixed string
// would hide it, which is what this used to do.
const dft = msg => failureText(new Error(msg));

check('a counted failure keeps its numbers',
  dft('ERROR: 3 of 40 message parts could not be deleted') ===
    '3 of 40 message parts could not be deleted. The list below has been refreshed.',
  dft('ERROR: 3 of 40 message parts could not be deleted'));

check('the time-budget wording survives',
  dft('ERROR: hit the 45s time budget with 88 of 128 message parts left') ===
    'Hit the 45s time budget with 88 of 128 message parts left. The list below has been refreshed.',
  dft('ERROR: hit the 45s time budget with 88 of 128 message parts left'));

// at_result hands back the modem's own line for a write that failed.
check("a modem error line is shown as-is",
  dft('+CMS ERROR: 500').startsWith('+CMS ERROR: 500'),
  dft('+CMS ERROR: 500'));

// A rejection with no CGI body at all (network drop, abort) has nothing to
// count, so it must fall back rather than print "undefined" at the user.
check('a body-less rejection falls back',
  failureText(new Error('Failed to fetch')) === 'The messages could not be deleted.',
  failureText(new Error('Failed to fetch')));
check('a null rejection falls back',
  failureText(null) === 'The messages could not be deleted.',
  String(failureText(null)));
check('an empty message falls back',
  failureText(new Error('')) === 'The messages could not be deleted.',
  failureText(new Error('')));

console.log(`\nfailures: ${failures}`);
process.exit(failures ? 1 : 0);
