// Seconds from AT+CFUN=1,1 being sent until the modem is reachable again.
const REBOOT_WAIT_SECS = 55;

// Auth-aware fetch wrapper. Redirects to login if the session has expired.
// auth.lua returns a 302 to /login.html which fetch() follows silently.
// response.redirected lets us detect this and navigate instead of parsing HTML.
//
// On session expiry: navigates to login preserving the current page as ?next=
// so the user lands back where they were after re-authenticating. Throws a
// SessionExpiredError so callers' finally() blocks still run (e.g. to reset
// isFetching flags), important on iOS Safari where BFCache can keep a page
// alive after window.location.replace() is called.
function authFetch(url, options) {
  return Promise.resolve()
    .then(() => fetch(url, { cache: "no-store", ...options }))
    .then(response => {
      if (response.redirected && response.url.includes('/login.html')) {
        const here = window.location.pathname;
        const next = (here && here !== '/login.html') ? here : '/';
        window.location.replace('/login.html?next=' + encodeURIComponent(next));
        const err = new Error('Session expired');
        err.name = 'SessionExpiredError';
        throw err;
      }
      return response;
    });
}

// Register global stores
document.addEventListener('alpine:init', () => {
  Alpine.store('scanBanner', {
    active: false,
    ownScan: false,
  });
  Alpine.store('errorModal', {
    show: false,
    title: 'Error',
    message: '',
    open(message, title = 'Error') {
      if (Alpine.store('waitModal').show) return;
      this.title = title;
      this.message = message;
      this.show = true;
    },
    close() {
      this.show = false;
    }
  });

  // Collects both passwords for an action that grants root, and owns the whole
  // attempt. A failure keeps the dialog open with what was typed still in it, so
  // a mistyped character costs one keystroke rather than a dismissed error
  // modal and a full retype. Closes only on success or a deliberate cancel, and
  // zeroes both fields either way.
  Alpine.store('credentialModal', {
    show: false,
    title: '',
    message: '',
    detail: '',
    action: 'Confirm',
    admin: '',
    developer: '',
    // Adding or removing a key grants root, so it asks for both. Changes that
    // grant nothing on their own ask for the administrator password alone.
    developerRequired: true,
    error: '',
    busy: false,
    locked: false,
    onSubmit: null,
    open({ title, message, detail = '', action = 'Confirm', developerRequired = true, onSubmit }) {
      this.title = title;
      this.message = message;
      this.detail = detail;
      this.action = action;
      this.developerRequired = developerRequired;
      this.admin = '';
      this.developer = '';
      this.error = '';
      this.busy = false;
      this.locked = false;
      this.onSubmit = onSubmit;
      this.show = true;
      // Alpine paints on the next tick, so focus after it exists.
      setTimeout(() => document.getElementById('cred-admin')?.focus(), 0);
    },
    submit() {
      if (this.busy || this.locked) return;
      if (!this.admin || (this.developerRequired && !this.developer)) {
        this.error = this.developerRequired
          ? 'Enter both passwords.'
          : 'Enter your administrator password.';
        return;
      }
      this.busy = true;
      this.error = '';
      Promise.resolve(this.onSubmit(this.admin, this.developer))
        .then(() => this.close())
        .catch((err) => {
          this.error = err.message || 'The change could not be completed.';
          // A lockout is server-enforced, so stop offering a retry that cannot win.
          this.locked = err.locked === true;
          this.busy = false;
        });
    },
    // Never while busy: the request is in flight and the change may already have
    // been made, so "cancelled" would be a lie.
    cancel() {
      if (this.busy) return;
      this.close();
    },
    close() {
      // Blank the live inputs first. A password field that still holds a value
      // when it leaves the DOM is read as a completed submission, which is what
      // raises the "save this login?" prompt. Clearing the store alone is not
      // enough: Alpine writes that back on its own schedule, and the element can
      // be gone by then.
      ['cred-admin', 'cred-dev'].forEach((id) => {
        const el = document.getElementById(id);
        if (el) el.value = '';
      });
      this.admin = '';
      this.developer = '';
      this.show = false;
      this.error = '';
      this.busy = false;
      this.locked = false;
      this.onSubmit = null;
    }
  });

  Alpine.store('confirmModal', {
    show: false,
    title: 'Are you sure?',
    message: '',
    detail: '',
    onConfirm: null,
    open(message, onConfirm, title = 'Are you sure?', detail = '') {
      this.title = title;
      this.message = message;
      this.detail = detail;
      this.onConfirm = onConfirm;
      this.show = true;
    },
    confirm() {
      this.show = false;
      if (this.onConfirm) this.onConfirm();
      this.onConfirm = null;
      this.detail = '';
    },
    cancel() {
      this.show = false;
      this.onConfirm = null;
      this.detail = '';
    }
  });

  Alpine.store('waitModal', {
    show: false,
    title: '',
    subtitle: '',
    countdown: 0,
    interval: null,
    start(title, seconds, onDone, subtitle = '') {
      this.show = true;
      this.title = title;
      this.subtitle = subtitle;
      this.countdown = seconds;
      this.interval = setInterval(() => {
        this.countdown--;
        if (this.countdown === 0) {
          clearInterval(this.interval);
          this.interval = null;
          this.show = false;
          if (onDone) onDone();
        }
      }, 1000);
    },
    stop() {
      if (this.interval) {
        clearInterval(this.interval);
        this.interval = null;
      }
      this.show = false;
    }
  });
});

// Inject the shared modal overlays into every page that includes this script.
document.addEventListener('DOMContentLoaded', () => {
  const injectOverlay = (showExpr, innerHTML) => {
    const el = document.createElement('div');
    el.setAttribute('x-data', '');
    el.setAttribute('x-show', showExpr);
    el.className = 'modal-overlay';
    el.setAttribute('x-cloak', '');
    el.innerHTML = innerHTML;
    document.body.appendChild(el);
  };

  injectOverlay('$store.confirmModal.show', `
    <div class="loading-modal text-start">
      <div class="mb-3">
        <h5 class="mb-0 fw-semibold" x-text="$store.confirmModal.title"></h5>
      </div>
      <p class="mb-3 text-muted" x-text="$store.confirmModal.message"></p>
      <p x-show="$store.confirmModal.detail" class="mb-3 font-monospace small rounded px-2 py-1 surface-muted" x-text="$store.confirmModal.detail"></p>
      <div class="d-flex justify-content-end gap-2">
        <button type="button" class="btn btn-secondary btn-sm" @click="$store.confirmModal.cancel()">Cancel</button>
        <button type="button" class="btn btn-primary btn-sm" @click="$store.confirmModal.confirm()">Confirm</button>
      </div>
    </div>
  `);

  // Credential prompt for actions that need both passwords. Kept separate from
  // confirmModal because it owns the whole attempt: it awaits the request and
  // stays open until that resolves, where confirmModal fires its callback and
  // closes immediately. Ten pages rely on that synchronous behaviour, and a
  // password field must never surface in an unrelated confirmation.
  // x-if, not x-show. This overlay is injected into every page, and password
  // inputs that are merely hidden still sit in the DOM, where Firefox's password
  // manager treats neighbouring text inputs as the matching username field and
  // starts offering to fill them. Rendering the fields only while the dialog is
  // open keeps ordinary pages free of any password input.
  injectOverlay('$store.credentialModal.show', `
    <template x-if="$store.credentialModal.show">
    <div class="loading-modal text-start">
      <h5 class="mb-1 fw-semibold" x-text="$store.credentialModal.title"></h5>
      <p class="mb-3 text-muted small" x-text="$store.credentialModal.message"></p>
      <p x-show="$store.credentialModal.detail" class="mb-3 font-monospace small rounded px-2 py-1 surface-muted text-break" x-text="$store.credentialModal.detail"></p>
      <div x-show="$store.credentialModal.error" x-cloak class="alert alert-danger py-2 px-3 small mb-3" x-text="$store.credentialModal.error"></div>
      <!-- A real form, so the browser's password manager looks for a matching
           username field INSIDE it and finds none. Unscoped password inputs make
           Firefox scan the whole document and pair them with whatever text input
           is nearest, which is how the SSH port ended up offered as a login. -->
      <form autocomplete="off" @submit.prevent="$store.credentialModal.submit()">
      <!-- A lone field sits directly above the buttons, so it takes a wider gap
           than it needs when the developer field follows it. -->
      <div :class="$store.credentialModal.developerRequired ? 'mb-2' : 'mb-4'">
        <label class="form-label fw-semibold" for="cred-admin">Administrator Password</label>
        <input id="cred-admin" type="password" class="form-control" maxlength="256"
               autocomplete="current-password"
               x-model="$store.credentialModal.admin"
               :disabled="$store.credentialModal.busy || $store.credentialModal.locked"
               @keydown.enter="$store.credentialModal.submit()">
      </div>
      <!-- x-if, not x-show: an unused password field left in the DOM is what
           the browser pairs with unrelated inputs and offers to save. -->
      <template x-if="$store.credentialModal.developerRequired">
        <div class="mb-4">
          <label class="form-label fw-semibold" for="cred-dev">Developer Password</label>
          <input id="cred-dev" type="password" class="form-control" maxlength="256"
                 autocomplete="current-password"
                 x-model="$store.credentialModal.developer"
                 :disabled="$store.credentialModal.busy || $store.credentialModal.locked"
                 @keydown.enter="$store.credentialModal.submit()">
        </div>
      </template>
      <div class="d-flex justify-content-end gap-2">
        <button type="button" class="btn btn-secondary btn-sm"
                :disabled="$store.credentialModal.busy"
                @click="$store.credentialModal.cancel()"
                x-text="$store.credentialModal.locked ? 'Close' : 'Cancel'"></button>
        <button type="button" class="btn btn-primary btn-sm"
                :disabled="$store.credentialModal.busy || $store.credentialModal.locked"
                @click="$store.credentialModal.submit()"
                x-text="$store.credentialModal.busy ? 'Verifying...' : $store.credentialModal.action"></button>
      </div>
      </form>
    </div>
    </template>
  `);

  injectOverlay('$store.errorModal.show', `
    <div class="loading-modal text-start">
      <div class="d-flex justify-content-between align-items-center mb-3">
        <h5 class="mb-0 fw-semibold" x-text="$store.errorModal.title"></h5>
        <button type="button" class="btn-close" @click="$store.errorModal.close()"></button>
      </div>
      <p class="mb-3 text-muted" x-text="$store.errorModal.message"></p>
      <div class="text-end">
        <button type="button" class="btn btn-primary btn-sm" @click="$store.errorModal.close()">OK</button>
      </div>
    </div>
  `);

  // The three <i> are the spinner's dots, sized and animated by .loader in
  // styles.css. Removing them leaves the spinner rendering nothing, silently.
  injectOverlay('$store.waitModal.show', `
    <div class="loading-modal">
      <div class="loader"><i></i><i></i><i></i></div>
      <div class="loading-text d-flex flex-column">
        <h3 x-text="$store.waitModal.title"></h3>
        <p x-show="$store.waitModal.subtitle" x-text="$store.waitModal.subtitle" class="text-muted small mt-1 mb-0"></p>
        <p class="mt-2">
          Refreshing in
          <span x-text="$store.waitModal.countdown" class="fw-medium"></span>
          seconds...
        </p>
      </div>
    </div>
  `);
});

// Inject scan-in-progress banner
document.addEventListener('DOMContentLoaded', () => {
  const banner = document.createElement('div');
  banner.setAttribute('x-data', '');
  banner.setAttribute('x-show', '$store.scanBanner.active && !$store.scanBanner.ownScan');
  banner.setAttribute('x-cloak', '');
  banner.className = 'alert alert-warning rounded-0 border-start-0 border-end-0 border-top-0 mb-0 py-2 text-center small';
  banner.textContent = 'Cell scan in progress. Live data is paused, showing cached values.';

  const main = document.querySelector('main');
  if (main) main.parentNode.insertBefore(banner, main);

  // Poll scan status so the banner clears when the scan ends. The flag is only
  // read once at load otherwise, and nothing flips it back on non-scanner
  // pages, so a banner shown mid-scan would stick forever. Re-poll only while a
  // scan is running, so idle pages make no steady-state requests. The scanner
  // page owns its own scan (ownScan), so leave its state alone.
  const pollScanStatus = () => {
    fetchWithTimeout(fetchJSON, '/cgi-bin/get_scan_status', 4000)
      .then(data => {
        const scanning = !!data.scanning;
        const store = Alpine.store('scanBanner');
        if (!store.ownScan) store.active = scanning;
        if (scanning) setTimeout(pollScanStatus, 5000);
      })
      .catch(() => {
        // Keep polling through a transient failure while a scan is believed
        // running, so the banner still clears once the endpoint recovers.
        if (Alpine.store('scanBanner').active) setTimeout(pollScanStatus, 5000);
      });
  };
  pollScanStatus();
});

function fetchJSON(url, options) {
  return authFetch(url, options).then(r => r.json());
}

function fetchText(url, options) {
  return authFetch(url, options).then(r => r.text());
}

// POSTs form-encoded params and resolves with the response text.
// Rejects if the body contains ERROR (the CGI convention for AT failures).
function postForm(url, params) {
  return fetchText(url, { method: "POST", body: new URLSearchParams(params) })
    .then(text => {
      if (text.includes("ERROR")) throw new Error(text.trim());
      return text;
    });
}

// Wraps a fetch-style call (fetchJSON, fetchText, authFetch, ...) with an
// AbortController that fires after timeoutMs, so callers don't each have to
// create/wire/clear their own controller and timer.
function fetchWithTimeout(fetchFn, url, timeoutMs, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetchFn(url, { ...options, signal: controller.signal }).finally(() => clearTimeout(timer));
}

// Retries a fetch-returning call once on rejection. A fetch that rejects right
// after an idle wait usually died with its pooled keep-alive connection (QCMAP
// rebuilds connection state on WWAN changes, and a reboot kills sockets without
// a FIN). The retry opens a fresh connection. Session redirects pass through:
// navigation to the login page is already underway.
function fetchWithRetry(fetchFn, delayMs = 1500) {
  return fetchFn().catch((err) => {
    if (isSessionExpired(err)) throw err;
    return new Promise(resolve => setTimeout(resolve, delayMs)).then(fetchFn);
  });
}

// A rejected fetch is a session expiry when authFetch caught a login redirect
// and is already navigating away. Callers should stay silent in that case.
function isSessionExpired(err) {
  return !!err && err.name === 'SessionExpiredError';
}

// Standard .catch handler for a fetch that may run while a session-expiry
// redirect is underway: it stays silent for that (navigation is happening) and
// otherwise shows the error modal. Pass stopWaitModal for actions that opened a
// wait modal, so the error can surface (errorModal is a no-op while it shows).
function reportFetchError(message, stopWaitModal = false) {
  return (err) => {
    if (isSessionExpired(err)) return;
    if (stopWaitModal) Alpine.store('waitModal').stop();
    Alpine.store('errorModal').open(message);
  };
}

// Splits a delimiter-framed snapshot response (get_dashboard / get_deviceinfo)
// into named sections keyed by their ===name=== marker (alone on a line).
// A section may be "" if its source produced no output (e.g. a failed fetch).
function parseEnvelope(text) {
  const sections = {};
  let current = null, buf = [];
  const flush = () => { if (current !== null) sections[current] = buf.join("\n"); };
  for (const line of text.split("\n")) {
    const m = line.match(/^===(\w+)===$/);
    if (m) { flush(); current = m[1]; buf = []; }
    else if (current !== null) { buf.push(line); }
  }
  flush();
  return sections;
}

// Comma-separated AT response field with quotes stripped. Undefined if absent.
const atField = (line, i) => line?.split(",")[i]?.replace(/"/g, "");

// Returns "-" for unassigned IP addresses (0.0.0.0 or all-zero IPv6 like ::)
function cleanIp(ip) {
  if (!ip) return '-';
  if (ip === '0.0.0.0') return '-';
  if (/^[0:]+$/.test(ip)) return '-'; // covers ::, 0:0:0:0:0:0:0:0, etc.
  return ip;
}

// One shape for every service status badge, so pages bind
// `:class="x.cls"` and `x-text="x.label"` instead of repeating a ternary chain.
// Four pages had drifted to four different spellings of two states before this
// existed ("Not Installed" against "Not installed", "..." against "Loading").
//
//   undefined  the snapshot has not loaded yet
//   null       the component is not installed
//   boolean    running or not
//
// offCls separates a service meant to run always, where inactive is a fault, from
// one driven by configuration, where inactive is the normal resting state.
function serviceBadge(running, offCls = 'text-bg-secondary') {
  if (running === undefined) return { cls: 'text-bg-secondary', label: 'Loading' };
  if (running === null) return { cls: 'text-bg-secondary', label: 'Not installed' };
  return running
    ? { cls: 'text-bg-success', label: 'Active' }
    : { cls: offCls, label: 'Inactive' };
}
