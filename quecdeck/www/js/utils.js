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
    _onConfirm: null,
    open(message, onConfirm, title = 'Are you sure?') {
      this.title = title;
      this.message = message;
      this._onConfirm = onConfirm;
      this.show = true;
    },
    confirm() {
      this.show = false;
      if (this._onConfirm) this._onConfirm();
      this._onConfirm = null;
    },
    cancel() {
      this.show = false;
      this._onConfirm = null;
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
      <p class="mb-3 text-muted" x-text="$store.confirmModal.message"></p>
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
  function pollScanStatus() {
    if (document.hidden || scanFetching) return;
    scanFetching = true;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    fetch('/cgi-bin/get_scan_status', { cache: 'no-store', signal: controller.signal })
      .then(r => r.json())
      .then(data => { Alpine.store('scanBanner').active = !!data.scanning; })
      .catch(() => {})
      .finally(() => { clearTimeout(timer); scanFetching = false; });
  }

  pollScanStatus();
  setInterval(pollScanStatus, 5000);
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

// Inject a "Log out" link into the navbar on every page
document.addEventListener('DOMContentLoaded', () => {
  const navbarText = document.querySelector('.navbar-text');
  if (!navbarText) return;

  navbarText.classList.add('d-flex', 'align-items-center', 'gap-2');

  const link = document.createElement('button');
  link.type = 'button';
  link.className = 'btn btn-link text-reset p-0';
  link.title = 'Log out';
  link.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="currentColor" viewBox="0 0 16 16" aria-hidden="true"><path fill-rule="evenodd" d="M10 12.5a.5.5 0 0 1-.5.5h-8a.5.5 0 0 1-.5-.5v-9a.5.5 0 0 1 .5-.5h8a.5.5 0 0 1 .5.5v2a.5.5 0 0 0 1 0v-2A1.5 1.5 0 0 0 9.5 2h-8A1.5 1.5 0 0 0 0 3.5v9A1.5 1.5 0 0 0 1.5 14h8a1.5 1.5 0 0 0 1.5-1.5v-2a.5.5 0 0 0-1 0z"/><path fill-rule="evenodd" d="M15.854 8.354a.5.5 0 0 0 0-.708l-3-3a.5.5 0 0 0-.708.708L14.293 7.5H5.5a.5.5 0 0 0 0 1h8.793l-2.147 2.146a.5.5 0 0 0 .708.708z"/></svg>';
  link.addEventListener('click', () => {
    fetch('/cgi-bin/auth_logout', { method: 'POST' }).finally(() => {
      window.location.href = '/login.html';
    });
  });
  navbarText.appendChild(link);
});
