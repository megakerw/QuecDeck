const fs = require('fs');
const path = require('path');

let failures = 0;
function check(name, condition) {
  if (condition) {
    console.log(`PASS: ${name}`);
  } else {
    failures += 1;
    console.error(`FAIL: ${name}`);
  }
}

const src = fs.readFileSync(
  path.join(__dirname, '..', '..', '..', 'quecdeck', 'www', 'js', 'scheduled-restart.js'),
  'utf8',
);
const { makeScheduledRestart } = eval(
  `${src}\n;({ makeScheduledRestart: quecdeckScheduledRestart })`,
);

const schedule = makeScheduledRestart();
check('default scheduled restart is daily', schedule.srType === 'daily');
check('positive timezone offsets parse', schedule.parseTzOffset('+0530') === 330);
check('negative timezone offsets parse', schedule.parseTzOffset('-0500') === -300);

const previousDay = schedule.shiftTime(0, 15, 1, -30);
check(
  'time conversion wraps to the previous week',
  previousDay.hour === 23 && previousDay.minute === 45 && previousDay.day === 7,
);
const nextDay = schedule.shiftTime(23, 45, 7, 30);
check(
  'time conversion wraps to the next week',
  nextDay.hour === 0 && nextDay.minute === 15 && nextDay.day === 1,
);
const twoDaysForward = schedule.shiftTime(23, 0, 1, 1560);
check(
  'time conversion handles offsets more than a day ahead',
  twoDaysForward.hour === 1 && twoDaysForward.minute === 0 && twoDaysForward.day === 3,
);
const twoDaysBack = schedule.shiftTime(1, 0, 1, -1560);
check(
  'time conversion handles offsets more than a day behind',
  twoDaysBack.hour === 23 && twoDaysBack.minute === 0 && twoDaysBack.day === 6,
);

schedule.srTime = '18:42';
check('time input updates hour and minute', schedule.srHour === 18 && schedule.srMinute === 42);
check('valid schedule can be saved', schedule.srCanSave === true);
schedule.srHour = 24;
check('invalid schedule cannot be saved', schedule.srCanSave === false);

console.log(`\nfailures: ${failures}`);
process.exitCode = failures === 0 ? 0 : 1;
