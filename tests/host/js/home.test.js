const fs = require('fs');
const path = require('path');

let failures = 0;
function check(name, condition) {
  if (!condition) {
    failures += 1;
    console.error(`FAIL: ${name}`);
  }
}

const src = fs.readFileSync(
  path.join(__dirname, '..', '..', '..', 'quecdeck', 'www', 'js', 'home.js'),
  'utf8',
);
const homeHelpers = eval(
  `${src}\n;({ qengNsaActive, splitServingCellId })`,
);

check(
  'valid NSA allocation is active',
  homeHelpers.qengNsaActive('+QENG: "NR5G-NSA",240,01,123,-95,20,-11,640000,78,8,1'),
);
check(
  'NSA line with unavailable channel is inactive',
  !homeHelpers.qengNsaActive('+QENG: "NR5G-NSA",240,01,123,-95,20,-11,-,78,8,1'),
);
check(
  'NSA line with unavailable band is inactive',
  !homeHelpers.qengNsaActive('+QENG: "NR5G-NSA",240,01,123,-95,20,-11,640000,-,8,1'),
);
check('missing NSA line is inactive', !homeHelpers.qengNsaActive(undefined));
const nrCell = homeHelpers.splitServingCellId('7000C4001', true);
check('36-bit NR node ID is not truncated to 32 bits', nrCell?.node === 1835057);
check('36-bit NR sector ID is preserved', nrCell?.sector === 1);
const lteCell = homeHelpers.splitServingCellId('22AE76D', false);
check('LTE node and sector split remains correct',
  lteCell?.node === 142055 && lteCell?.sector === 109);
check('invalid cell ID is rejected', homeHelpers.splitServingCellId('not-hex', true) === null);
check('partially hexadecimal cell ID is rejected', homeHelpers.splitServingCellId('ABCZ', true) === null);

process.exitCode = failures ? 1 : 0;
