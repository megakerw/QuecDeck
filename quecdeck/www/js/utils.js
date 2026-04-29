// Seconds from AT+CFUN=1,1 being sent until the modem is reachable again.
const REBOOT_WAIT_SECS = 55;

// Auth-aware fetch wrapper — redirects to login if the session has expired.
// auth.lua returns a 302 to /login.html which fetch() follows silently;
// response.redirected lets us detect this and navigate instead of parsing HTML.
//
// On session expiry: navigates to login preserving the current page as ?next=
// so the user lands back where they were after re-authenticating. Throws a
// SessionExpiredError so callers' finally() blocks still run (e.g. to reset
// isFetching flags) — important on iOS Safari where BFCache can keep a page
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

  Alpine.store('confirmModal', {
    show: false,
    title: 'Are you sure?',
    message: '',
    detail: '',
    _onConfirm: null,
    open(message, onConfirm, title = 'Are you sure?', detail = '') {
      this.title = title;
      this.message = message;
      this.detail = detail;
      this._onConfirm = onConfirm;
      this.show = true;
    },
    confirm() {
      this.show = false;
      if (this._onConfirm) this._onConfirm();
      this._onConfirm = null;
      this.detail = '';
    },
    cancel() {
      this.show = false;
      this._onConfirm = null;
      this.detail = '';
    }
  });

  Alpine.store('waitModal', {
    show: false,
    title: '',
    countdown: 0,
    _interval: null,
    start(title, seconds, onDone) {
      this.show = true;
      this.title = title;
      this.countdown = seconds;
      this._interval = setInterval(() => {
        this.countdown--;
        if (this.countdown === 0) {
          clearInterval(this._interval);
          this._interval = null;
          this.show = false;
          if (onDone) onDone();
        }
      }, 1000);
    },
    stop() {
      if (this._interval) {
        clearInterval(this._interval);
        this._interval = null;
      }
      this.show = false;
    }
  });
});

// Inject confirm modal HTML into every page that includes this script
document.addEventListener('DOMContentLoaded', () => {
  const confirmModal = document.createElement('div');
  confirmModal.setAttribute('x-data', '');
  confirmModal.setAttribute('x-show', '$store.confirmModal.show');
  confirmModal.className = 'modal-overlay';
  confirmModal.style.display = 'none';
  confirmModal.innerHTML = `
    <div class="loading-modal text-start">
      <div class="mb-3">
        <h5 class="mb-0 fw-semibold" x-text="$store.confirmModal.title"></h5>
      </div>
      <p class="mb-2 text-muted" x-text="$store.confirmModal.message"></p>
      <p x-show="$store.confirmModal.detail" class="mb-3 font-monospace small rounded px-2 py-1" style="background:var(--bs-secondary-bg)" x-text="$store.confirmModal.detail"></p>
      <div class="d-flex justify-content-end gap-2">
        <button type="button" class="btn btn-secondary btn-sm" @click="$store.confirmModal.cancel()">Cancel</button>
        <button type="button" class="btn btn-primary btn-sm" @click="$store.confirmModal.confirm()">Confirm</button>
      </div>
    </div>
  `;
  document.body.appendChild(confirmModal);
});

// Inject error modal HTML into every page that includes this script
document.addEventListener('DOMContentLoaded', () => {
  const errorModal = document.createElement('div');
  errorModal.setAttribute('x-data', '');
  errorModal.setAttribute('x-show', '$store.errorModal.show');
  errorModal.className = 'modal-overlay';
  errorModal.style.display = 'none';
  errorModal.innerHTML = `
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
  `;
  document.body.appendChild(errorModal);
});

// Inject wait modal HTML into every page that includes this script
document.addEventListener('DOMContentLoaded', () => {
  const modal = document.createElement('div');
  modal.setAttribute('x-data', '');
  modal.setAttribute('x-show', '$store.waitModal.show');
  modal.className = 'modal-overlay';
  modal.style.display = 'none';
  modal.innerHTML = `
    <div class="loading-modal">
      <div class="loader"></div>
      <div class="loading-text d-flex flex-column">
        <h3 x-text="$store.waitModal.title"></h3>
        <p class="mt-2">
          Refreshing in
          <span x-text="$store.waitModal.countdown" class="fw-medium"></span>
          seconds...
        </p>
      </div>
    </div>
  `;
  document.body.appendChild(modal);
});

// Inject scan-in-progress banner and start polling
document.addEventListener('DOMContentLoaded', () => {
  const banner = document.createElement('div');
  banner.setAttribute('x-data', '');
  banner.setAttribute('x-show', '$store.scanBanner.active && !$store.scanBanner.ownScan');
  banner.style.display = 'none';
  banner.className = 'alert alert-warning rounded-0 border-start-0 border-end-0 border-top-0 mb-0 py-2 text-center small';
  banner.textContent = 'Cell scan in progress — live data is paused, showing cached values.';

  const main = document.querySelector('main');
  if (main) main.parentNode.insertBefore(banner, main);

  let scanFetching = false;
  let scanIntervalId = null;

  function pollScanStatus() {
    if (scanFetching) return;
    scanFetching = true;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    authFetch('/cgi-bin/get_scan_status', { signal: controller.signal })
      .then(r => r.json())
      .then(data => { Alpine.store('scanBanner').active = !!data.scanning; })
      .catch(() => {})
      .finally(() => { clearTimeout(timer); scanFetching = false; });
  }

  function startScanPoll() {
    if (scanIntervalId) return;
    pollScanStatus();
    scanIntervalId = setInterval(pollScanStatus, 5000);
  }

  function stopScanPoll() {
    clearInterval(scanIntervalId);
    scanIntervalId = null;
  }

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopScanPoll(); else startScanPoll();
  });

  startScanPoll();
});

// Returns "-" for unassigned IP addresses (0.0.0.0 or all-zero IPv6 like ::)
function cleanIp(ip) {
  if (!ip) return '-';
  if (ip === '0.0.0.0') return '-';
  if (/^[0:]+$/.test(ip)) return '-'; // covers ::, 0:0:0:0:0:0:0:0, etc.
  return ip;
}

// On BFCache restore (iOS Safari backgrounding), in-flight fetches are
// cancelled and their rejections are delivered when the page resumes. This
// leaves loading flags set and status values null, disabling buttons. A
// forced reload restores clean state — same effect as the user refreshing.
window.addEventListener('pageshow', (event) => {
  if (event.persisted) window.location.reload();
});

