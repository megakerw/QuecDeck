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
  path.join(__dirname, '..', '..', '..', 'quecdeck', 'www', 'js', 'watchcat.js'),
  'utf8',
);
const { makeWatchcat } = eval(`${src}\n;({ makeWatchcat: quecdeckWatchCat })`);

const watchcat = makeWatchcat();
watchcat.enabled = true;
watchcat.ips = ['8.8.8.8'];
watchcat.pingInterval = 30;
watchcat.pingFailureCount = 2;
check('two failed rounds cannot be saved', watchcat.canSave === false);

watchcat.pingFailureCount = 3;
check('three failed rounds can be saved', watchcat.canSave === true);

watchcat.ips = ['1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4', '5.5.5.5', '6.6.6.6'];
check('six valid ping targets remain valid', watchcat.validIps.length === 6);
check('a seventh ping target is not offered', watchcat.canAddIp() === false);

watchcat.ips = ['999.1.1.1'];
check('out-of-range IPv4 octets cannot be saved', watchcat.canSave === false);

watchcat.ips = ['8.8.8.8', '999.1.1.1'];
check('an invalid non-empty target is not silently omitted', watchcat.canSave === false);

watchcat.ips = [' 8.8.8.8 '];
check('surrounding IPv4 whitespace is accepted and trimmed', watchcat.canSave === true);
check('saved targets are trimmed', watchcat.buildParams().TRACK_IP_1 === '8.8.8.8');

watchcat.ips = ['8.8.8.8', ''];
check('a blank final row cannot add another target', watchcat.canAddIp() === false);

// Per-target reachability. "Not responding" requires the link to be up right
// now, so a real outage never relabels every target as dead.
const wc = makeWatchcat();
wc.consecutiveFailures = 0;
check('a target that answered reads as responding',
  wc.targetLabel({ ip: '8.8.8.8', miss: 0 }) === 'Responding');
check('one miss is not yet unresponsive',
  wc.targetLabel({ ip: '9.9.9.9', miss: 1 }) === '1 miss');
check('a single miss is singular, not "1 misses"',
  wc.targetLabel({ ip: '9.9.9.9', miss: 1 }).endsWith('1 miss'));
check('two misses stay below the cutoff',
  wc.targetLabel({ ip: '9.9.9.9', miss: 2 }) === '2 misses');
check('three failed attempts is the cutoff',
  wc.targetLabel({ ip: '192.0.2.55', miss: 3 }) === 'Not responding');
check('the unresponsive badge is the danger colour',
  wc.targetState({ ip: '192.0.2.55', miss: 412 }).cls === 'text-bg-danger');
check('an unresponsive target does not carry a raw count',
  /^Not responding$/.test(wc.targetLabel({ ip: '192.0.2.55', miss: 412 })));

// During a real outage every target is failing, so none of them is singled out
// as dead: the reboot path owns that case.
wc.consecutiveFailures = 2;
check('a real outage does not mark targets unresponsive',
  wc.targetLabel({ ip: '192.0.2.55', miss: 412 }) === '412 misses');
check('a real outage keeps targets at the warning colour',
  wc.targetState({ ip: '192.0.2.55', miss: 412 }).cls.startsWith('text-bg-warning'));

// A round stops at the first target that answers, so early rounds leave later
// targets uncontacted. Claiming they respond would assert a packet never sent.
wc.consecutiveFailures = 0;
check('an uncontacted target does not claim to be responding',
  wc.targetLabel({ ip: '9.9.9.9', miss: -1 }) === 'Not checked');
check('an uncontacted target is not coloured as healthy',
  wc.targetState({ ip: '9.9.9.9', miss: -1 }).cls === 'text-bg-secondary');
check('a target that answered is still distinct from an uncontacted one',
  wc.targetState({ ip: '8.8.8.8', miss: 0 })
  !== wc.targetState({ ip: '9.9.9.9', miss: -1 }));
check('an unreadable miss count is treated as no evidence, not as healthy',
  wc.targetLabel({ ip: '8.8.8.8' }) === 'Not checked'
  && wc.targetLabel({ ip: '8.8.8.8', miss: 'x' }) === 'Not checked');

// Reboot-window safety maths. Ping failures can return immediately, so only the
// configured gaps between rounds are a guaranteed lower bound.
function windowFor(interval, targets, count) {
  const w = makeWatchcat();
  w.ips = Array.from({ length: targets }, (_, i) => `10.0.0.${i + 1}`);
  w.pingInterval = interval;
  w.pingFailureCount = count;
  return w;
}

let w = windowFor(30, 3, 3);
check('the minimum window contains only gaps between failed rounds', w.rebootWindowSec === 60);
check('a normal configuration reads as balanced', w.severity.label === 'Balanced');

w = windowFor(10, 1, 3);
check('a 20s minimum window is very frequent', w.rebootWindowSec === 20 && w.severity.label === 'Very frequent');

w = windowFor(20, 1, 3);
check('a 40s minimum window is frequent but not very frequent',
  w.rebootWindowSec === 40 && w.severity.label === 'Frequent');

w = windowFor(600, 6, 10);
check('a slow configuration reads as relaxed',
  w.rebootWindowSec === 5400 && w.severity.label === 'Slow recovery');

// More targets can lengthen a real round, but cannot increase the guaranteed
// minimum because every ping may fail immediately.
w = windowFor(30, 3, 3);
const before = w.rebootWindowSec;
w.ips = [...w.ips, '10.0.0.4'];
check('adding a target does not dilute the safety bound', w.rebootWindowSec === before);

// The suggestion has to actually reach 60s, and has to be a value the form
// will accept: below 10 it could not be saved.
function reaches60(interval, targets, count) {
  const s = windowFor(interval, targets, count).safeInterval;
  return s >= 10 && (count - 1) * s >= 60;
}
check('the safer interval reaches a 60s window at one target', reaches60(10, 1, 3));
check('the safer interval reaches a 60s window at six targets', reaches60(10, 6, 3));
check('the safer interval never drops below the form floor',
  windowFor(10, 6, 10).safeInterval === 10);

check('the pause flag starts clear', makeWatchcat().paused === false);

const retry = makeWatchcat();
retry.retryAfter = 59;
check('a short retry delay is shown in seconds', retry.retryAfterLabel === '59 sec');
retry.retryAfter = 61;
check('a retry delay rounds up to whole minutes', retry.retryAfterLabel === '2 min');
retry.retryAfter = 3661;
check('a long retry delay includes hours and minutes', retry.retryAfterLabel === '1 hr 2 min');
retry.retryAfter = 7200;
check('an exact-hour retry delay omits zero minutes', retry.retryAfterLabel === '2 hr');

console.log(`\nfailures: ${failures}`);
process.exitCode = failures === 0 ? 0 : 1;
