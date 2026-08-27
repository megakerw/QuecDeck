(function () {
  const script = document.currentScript;

  // One stroked 16px set at weight 1.5, so the rail's glyphs read as a family
  // with each other rather than competing with the filled stat-card icons.
  function icon(shapes) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"'
      + ' fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"'
      + ' stroke-linejoin="round" aria-hidden="true">' + shapes + '</svg>';
  }

  const groups = [
    { label: '', links: [
      { href: '/', label: 'Overview', icon: icon(
        '<rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/>'
        + '<rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/>') },
    ] },
    { label: 'Network', links: [
      { href: '/network.html', label: 'Cellular Network', icon: icon(
        '<circle cx="8" cy="12.2" r="1"/><path d="M5.5 9.7a3.5 3.5 0 0 1 5 0"/>'
        + '<path d="M3.2 7.4a6.8 6.8 0 0 1 9.6 0"/>') },
      { href: '/scanner.html', label: 'Cell Scan', icon: icon(
        '<circle cx="7" cy="7" r="4.3"/><path d="M10.2 10.2 14 14"/>') },
      { href: '/settings.html', label: 'LAN & Utilities', icon: icon(
        '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.6v1.6M8 12.8v1.6M1.6 8h1.6M12.8 8h1.6'
        + 'M3.5 3.5l1.1 1.1M11.4 11.4l1.1 1.1M12.5 3.5l-1.1 1.1M4.6 11.4l-1.1 1.1"/>') },
    ] },
    { label: 'Services', links: [
      { href: '/watchcat.html', label: 'Watchcat', icon: icon(
        '<path d="M1.8 9.6h2.6l2-5.2 2.8 8 1.9-3.4h3.1"/>') },
      { href: '/scheduled-restart.html', label: 'Scheduled Restart', icon: icon(
        '<circle cx="8" cy="8" r="5.7"/><path d="M8 4.8v3.5l2.4 1.4"/>') },
      { href: '/sms.html', label: 'SMS', icon: icon(
        '<path d="M2.2 3.6h11.6v7.2H6.6L3.6 13.6v-2.8H2.2z"/>') },
    ] },
    { label: 'System', links: [
      { href: '/security.html', label: 'Security', icon: icon(
        '<path d="M8 1.7 13 3.8v3.7c0 3.1-2 5.5-5 6.8-3-1.3-5-3.7-5-6.8V3.8z"/>'
        + '<path d="M5.8 8 7.3 9.5l3-3"/>') },
      { href: '/deviceinfo.html', label: 'Device Information', icon: icon(
        '<circle cx="8" cy="8" r="6"/><path d="M8 7.4v3.8"/><path d="M8 4.9v.7"/>') },
      { href: '/update.html', label: 'Update', icon: icon(
        '<path d="M8 2.2v7.2"/><path d="M5.2 6.6 8 9.4l2.8-2.8"/>'
        + '<path d="M2.6 11.4v1.2a1.2 1.2 0 0 0 1.2 1.2h8.4a1.2 1.2 0 0 0 1.2-1.2v-1.2"/>') },
      { href: '/logs.html', label: 'Logs', icon: icon(
        '<path d="M3.6 2.2h5.6l3.2 3.2v8.4H3.6z"/><path d="M9.2 2.2v3.2h3.2"/>'
        + '<path d="M5.8 8.6h4.4M5.8 10.9h4.4"/>') },
      { href: '/developer.html', label: 'Developer', icon: icon(
        '<path d="M5.4 4.8 2.2 8l3.2 3.2"/><path d="M10.6 4.8 13.8 8l-3.2 3.2"/>') },
    ] },
  ];
  const path = window.location.pathname;

  function isActive(href) {
    if (href === '/') return path === '/' || path === '/index.html';
    return path === href;
  }

  // Labels are stored as plain text because document.title needs the real
  // characters, so they have to be escaped on the way into innerHTML.
  function escapeText(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  }

  // Every page ships the same <title>QuecDeck</title>, which leaves tabs,
  // history and bookmarks indistinguishable. The nav already knows the page.
  for (let groupIndex = 0; groupIndex < groups.length; groupIndex += 1) {
    const found = groups[groupIndex].links.find(function (link) {
      return isActive(link.href);
    });
    if (found) {
      // Escaped rather than a literal middle dot: lighttpd sends no charset for
      // .js, so the raw byte would rely on the page's encoding carrying over.
      document.title = found.label + ' \u00b7 QuecDeck';
      break;
    }
  }

  function renderItem(link, cls) {
    const active = isActive(link.href);
    return '<a class="' + cls + (active ? ' active' : '') + '"'
      + (active ? ' aria-current="page"' : '')
      + ' href="' + link.href + '">' + link.icon
      + '<span>' + escapeText(link.label) + '</span></a>';
  }

  // Above 992px each labelled group is a dropdown. Below it the menu is forced
  // open and static (see styles.css) so the drawer still shows all eleven.
  function renderLinks() {
    return groups.map(function (group) {
      if (!group.label) {
        return group.links.map(function (link) {
          return '<li class="nav-item">' + renderItem(link, 'nav-link') + '</li>';
        }).join('');
      }

      const items = group.links.map(function (link) {
        return '<li>' + renderItem(link, 'dropdown-item') + '</li>';
      }).join('');
      const open = group.links.some(function (link) { return isActive(link.href); });

      return '<li class="nav-item dropdown">'
        + '<button type="button" class="nav-link dropdown-toggle app-nav-group-label'
        + (open ? ' active' : '') + '" data-bs-toggle="dropdown" aria-expanded="false">'
        + escapeText(group.label) + '</button>'
        + '<ul class="dropdown-menu">' + items + '</ul></li>';
    }).join('');
  }

  const logoutIcon = icon(
    '<path d="M6.2 2.4H3.4a1.2 1.2 0 0 0-1.2 1.2v8.8a1.2 1.2 0 0 0 1.2 1.2h2.8"/>'
    + '<path d="M10.4 5.2 13.2 8l-2.8 2.8"/><path d="M13.2 8H5.8"/>');
  // One element for both breakpoints: .navbar-expand-lg renders the inner
  // .offcanvas inline and horizontal above 992px, and as a real drawer below it.
  const navigation = '<nav class="navbar navbar-expand-lg app-bar" aria-label="Primary navigation">'
    + '<div class="app-bar-inner">'
    + '<button class="navbar-toggler" type="button" data-bs-toggle="offcanvas" data-bs-target="#appNav" aria-controls="appNav" aria-label="Open navigation">'
    + '<span class="navbar-toggler-icon" aria-hidden="true"></span></button>'
    + '<a class="navbar-brand app-brand" href="/">QuecDeck</a>'
    + '<div class="offcanvas offcanvas-start app-nav-panel" tabindex="-1" id="appNav" aria-label="Navigation">'
    + '<a class="app-brand app-brand-drawer" href="/">QuecDeck</a>'
    + '<button type="button" class="btn-close app-nav-close" data-bs-dismiss="offcanvas" aria-label="Close navigation"></button>'
    + '<ul class="navbar-nav app-nav">' + renderLinks() + '</ul>'
    + '<button type="button" class="app-logout logout-btn">' + logoutIcon + '<span>Log out</span></button>'
    + '</div></div></nav>';

  const placeholder = document.getElementById('nav-placeholder');
  if (placeholder) placeholder.outerHTML = navigation;

  // Below 992px the dropdown menus are forced open and static by CSS, so the
  // group buttons are headings rather than controls. Strip the toggle wiring
  // there instead of leaving a focusable button that does nothing.
  const groupToggles = document.querySelectorAll('.app-nav-group-label');

  function syncGroupToggles(isDesktop) {
    groupToggles.forEach(function (button) {
      if (isDesktop) {
        button.setAttribute('data-bs-toggle', 'dropdown');
        button.setAttribute('aria-expanded', 'false');
        button.removeAttribute('tabindex');
        button.removeAttribute('role');
        button.removeAttribute('aria-level');
        return;
      }
      // Inert down here, so stop announcing it as a button: it labels the list
      // below it and nothing else.
      button.removeAttribute('data-bs-toggle');
      button.removeAttribute('aria-expanded');
      button.setAttribute('tabindex', '-1');
      button.setAttribute('role', 'heading');
      button.setAttribute('aria-level', '3');
      button.classList.remove('show');
      const menu = button.nextElementSibling;
      if (menu) menu.classList.remove('show');
    });
  }

  // Bootstrap has no resize handling here either, so crossing the breakpoint
  // with the drawer open would leave the backdrop over a desktop layout.
  // matchMedia fires on the crossing only, not on every resize.
  const desktop = window.matchMedia('(min-width: 992px)');
  syncGroupToggles(desktop.matches);

  desktop.addEventListener('change', function (event) {
    syncGroupToggles(event.matches);
    if (!event.matches || !window.bootstrap) return;
    const drawer = document.getElementById('appNav');
    const instance = drawer && window.bootstrap.Offcanvas.getInstance(drawer);
    if (instance) instance.hide();
  });

  // Move the highlight on click rather than waiting for the next page to paint.
  // A page load here is slow enough that leaving the old item lit reads as a
  // missed tap. Modified and middle clicks open elsewhere, so they leave it be.
  document.querySelectorAll('.app-nav a').forEach(function (link) {
    link.addEventListener('click', function (event) {
      if (event.defaultPrevented || event.button !== 0) return;
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;

      document.querySelectorAll('.app-nav .active').forEach(function (el) {
        el.classList.remove('active');
        el.removeAttribute('aria-current');
      });
      link.classList.add('active');
      link.setAttribute('aria-current', 'page');

      const group = link.closest('.dropdown');
      const toggle = group && group.querySelector('.app-nav-group-label');
      if (toggle) toggle.classList.add('active');
    });
  });

  const logoutButton = document.querySelector('.logout-btn');
  if (logoutButton) {
    logoutButton.addEventListener('click', function () {
      fetch('/cgi-bin/auth_logout', { method: 'POST' }).finally(function () {
        window.location.href = '/login.html';
      });
    });
  }

  if (script) script.remove();
})();
