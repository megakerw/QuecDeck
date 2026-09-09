const fs = require('fs');
const path = require('path');

let failures = 0;
function check(name, condition) {
  if (!condition) {
    failures += 1;
    console.error(`FAIL: ${name}`);
  }
}

let timers = [];
let responses = [];
let requests = [];
let now = 1000;
function setTimeout(fn, delay) {
  const timer = { delay, cleared: false };
  timer.run = () => {
    timer.cleared = true;
    fn();
  };
  timers.push(timer);
  return timer;
}
function clearTimeout(timer) {
  if (timer) timer.cleared = true;
}
function fetchWithTimeout(_fetchFn, url) {
  requests.push({ url, options: null });
  const response = responses.shift();
  return response instanceof Promise ? response : Promise.resolve(response);
}
function fetchJSON(url, options) {
  requests.push({ url, options });
  return Promise.resolve({ ok: true });
}
function decodeLogChunk(_decoder, value) {
  if (value === 'invalid') throw new Error('invalid base64');
  return Buffer.from(value || '', 'base64').toString('utf8');
}

const source = fs.readFileSync(
  path.join(__dirname, '..', '..', '..', 'quecdeck', 'www', 'js', 'operation-monitor.js'),
  'utf8',
);
const createMonitor = eval(`${source}\n;createOperationMonitor`);
const realDateNow = Date.now;
Date.now = () => now;

const ID_A = '0123456789abcdef0123456789abcdef';
const ID_B = 'fedcba9876543210fedcba9876543210';
const encoded = (value) => Buffer.from(value).toString('base64');
const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};
const activeTimers = () => timers.filter((timer) => !timer.cleared);

function observer() {
  const state = { snapshots: [], disconnects: [], reconnects: 0, mismatches: [] };
  state.monitor = createMonitor({
    intervalMs: 1000,
    onSnapshot: (data, chunk) => state.snapshots.push({ data, chunk }),
    onDisconnect: (elapsed) => state.disconnects.push(elapsed),
    onReconnect: () => { state.reconnects += 1; },
    onMismatch: (data) => state.mismatches.push(data),
  });
  return state;
}

(async () => {
  let state = observer();
  responses.push({ operation_id: ID_A, kind: 'sshd:update', status: 'running', offset: 4, log: encoded('step') });
  state.monitor.start({ id: ID_A, expectedKind: 'sshd:update' });
  check('first poll is immediate', activeTimers().at(-1).delay === 0);
  activeTimers().at(-1).run();
  await flush();
  check('matching snapshots are decoded', state.snapshots.length === 1 && state.snapshots[0].chunk === 'step');
  check('the next poll uses the returned offset', activeTimers().at(-1).delay === 1000);
  responses.push({ operation_id: ID_A, kind: 'sshd:update', status: 'done', offset: 6, log: encoded('ok') });
  activeTimers().at(-1).run();
  await flush();
  check('terminal snapshots stop polling', state.snapshots.at(-1).data.status === 'done' && activeTimers().length === 0);
  check('poll offsets advance', requests[1].url === '/cgi-bin/get_update_log?offset=4');

  timers = [];
  state = observer();
  state.monitor.start({
    id: ID_A,
    expectedKind: 'quecdeck',
    initial: { operation_id: ID_A, kind: 'quecdeck', status: 'done', offset: 2, log: encoded('ok') },
  });
  check('an initial terminal snapshot needs no request', state.snapshots.length === 1 && activeTimers().length === 0);

  timers = [];
  state = observer();
  responses.push({ operation_id: ID_B, kind: 'quecdeck', status: 'running', offset: 0, log: '' });
  state.monitor.start({ id: ID_A, expectedKind: 'quecdeck' });
  activeTimers().at(-1).run();
  await flush();
  check('a different operation ID is rejected', state.mismatches.length === 1 && state.snapshots.length === 0);

  timers = [];
  state = observer();
  responses.push({ operation_id: ID_A, kind: 'sshd:install', status: 'running', offset: 0, log: '' });
  state.monitor.start({ id: ID_A, expectedKind: 'sshd:update' });
  activeTimers().at(-1).run();
  await flush();
  check('a different operation kind is rejected', state.mismatches.length === 1);

  timers = [];
  state = observer();
  responses.push(Promise.reject(new Error('offline')));
  state.monitor.start({ id: ID_A, expectedKind: 'quecdeck' });
  activeTimers().at(-1).run();
  await flush();
  check('disconnect starts at zero elapsed time', state.disconnects.length === 1 && state.disconnects[0] === 0);
  now += 3000;
  responses.push({ operation_id: ID_A, kind: 'quecdeck', status: 'running', offset: 0, log: '' });
  activeTimers().at(-1).run();
  await flush();
  check('a successful retry reports reconnection', state.reconnects === 1 && state.snapshots.length === 1);

  timers = [];
  state = observer();
  let resolveOld;
  responses.push(new Promise((resolve) => { resolveOld = resolve; }));
  state.monitor.start({ id: ID_A, expectedKind: 'quecdeck' });
  activeTimers().at(-1).run();
  state.monitor.start({ id: ID_B, expectedKind: 'sshd:update' });
  resolveOld({ operation_id: ID_A, kind: 'quecdeck', status: 'done', offset: 1, log: encoded('old') });
  await flush();
  check('a response from a stopped generation is ignored', state.snapshots.length === 0 && activeTimers().length === 1);

  timers = [];
  state = observer();
  responses.push({ operation_id: ID_A, kind: 'quecdeck', status: 'failed', offset: 0, log: 'invalid' });
  state.monitor.start({ id: ID_A, expectedKind: 'quecdeck' });
  activeTimers().at(-1).run();
  await flush();
  check('a malformed log chunk preserves the terminal result', state.snapshots[0].data.status === 'failed' && state.snapshots[0].chunk.includes('Could not decode'));

  await state.monitor.acknowledge(ID_A);
  const acknowledgement = requests.at(-1);
  check('acknowledgement is an ID-scoped POST', acknowledgement.url === '/cgi-bin/get_update_log'
    && acknowledgement.options.method === 'POST'
    && acknowledgement.options.body.get('operation_id') === ID_A);
  check('malformed IDs are not submitted', await state.monitor.acknowledge('bad') === false && requests.at(-1) === acknowledgement);

  Date.now = realDateNow;
  process.exitCode = failures ? 1 : 0;
})();
