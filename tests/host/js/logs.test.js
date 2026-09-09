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
  path.join(__dirname, '..', '..', '..', 'quecdeck', 'www', 'js', 'logs.js'),
  'utf8',
);
const { makeLogsPage, accessEvents } = eval(
  `${src}\n;({ makeLogsPage: logsPage, accessEvents: ACCESS_EVENTS })`,
);
const logs = makeLogsPage();

const manageSecurity = fs.readFileSync(
  path.join(__dirname, '..', '..', '..', 'quecdeck', 'www', 'cgi-bin', 'manage_security'),
  'utf8',
);
const emittedSecurityEvents = [...manageSecurity.matchAll(/\bevent=((?:security|ssh)_[a-z_]+)/g)]
  .map((match) => match[1]);

check('the security endpoint emits audited event types', emittedSecurityEvents.length > 0);
for (const type of emittedSecurityEvents) {
  check(`${type} has an access-log presentation`, Boolean(accessEvents[type]));
}

check(
  'developer password changes use a readable badge label',
  logs.accessLabel('security_developer_password_changed') === 'Developer Password Changed',
);
check(
  'developer password changes use the success badge colour',
  logs.accessBadgeClass('security_developer_password_changed') === 'bg-success',
);

process.exitCode = failures ? 1 : 0;
