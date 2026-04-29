(function () {
  var _script = document.currentScript;
  const storedTheme = localStorage.getItem('theme') || 'dark';
  const themeLabel = storedTheme === 'dark' ? '☀️ Light' : '🌙 Dark';
  const links = [
    { href: '/',                label: 'Home' },
    { href: '/network.html',    label: 'Cellular Network' },
    { href: '/scanner.html',    label: 'Cell Scan' },
    { href: '/settings.html',   label: 'Settings' },
    { href: '/monitoring.html', label: 'Monitoring' },
    { href: '/sms.html',        label: 'SMS' },
    { href: '/deviceinfo.html', label: 'Device Information' },
    { href: '/logs.html',       label: 'Logs' },
    { href: '/developer.html',  label: 'Developer' },
  ];

  const path = window.location.pathname;

  function isActive(href) {
    if (href === '/') return path === '/' || path === '/index.html';
    return path === href;
  }

  const items = links.map(function (link) {
    const active = isActive(link.href);
    return '<li class="nav-item"><a class="nav-link' + (active ? ' active' : '') + '"'
      + (active ? ' aria-current="page"' : '')
      + ' href="' + link.href + '">' + link.label + '</a></li>';
  }).join('\n        ');

  const nav = '<nav class="navbar navbar-expand-lg">\n'
    + '          <div class="container-fluid px-3">\n'
    + '            <a class="navbar-brand" href="/">QuecDeck</a>\n'
    + '            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarText" aria-controls="navbarText" aria-expanded="false" aria-label="Toggle navigation">\n'
    + '              <span class="navbar-toggler-icon"></span>\n'
    + '            </button>\n'
    + '            <div class="collapse navbar-collapse" id="navbarText">\n'
    + '              <ul class="navbar-nav me-auto mb-2 mb-lg-0">\n'
    + '        ' + items + '\n'
    + '              </ul>\n'
    + '              <span class="navbar-text d-flex align-items-center gap-2">\n'
    + '                <button class="btn btn-link text-reset" id="darkModeToggle">' + themeLabel + '</button>\n'
    + '                <button type="button" class="btn btn-link text-reset p-0 ms-2" id="logoutBtn" title="Log out">'
    + '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" fill="currentColor" viewBox="0 0 16 16" aria-hidden="true">'
    + '<path fill-rule="evenodd" d="M10 12.5a.5.5 0 0 1-.5.5h-8a.5.5 0 0 1-.5-.5v-9a.5.5 0 0 1 .5-.5h8a.5.5 0 0 1 .5.5v2a.5.5 0 0 0 1 0v-2A1.5 1.5 0 0 0 9.5 2h-8A1.5 1.5 0 0 0 0 3.5v9A1.5 1.5 0 0 0 1.5 14h8a1.5 1.5 0 0 0 1.5-1.5v-2a.5.5 0 0 0-1 0z"/>'
    + '<path fill-rule="evenodd" d="M15.854 8.354a.5.5 0 0 0 0-.708l-3-3a.5.5 0 0 0-.708.708L14.293 7.5H5.5a.5.5 0 0 0 0 1h8.793l-2.147 2.146a.5.5 0 0 0 .708.708z"/>'
    + '</svg></button>\n'
    + '              </span>\n'
    + '            </div>\n'
    + '          </div>\n'
    + '        </nav>';

  const placeholder = document.getElementById('nav-placeholder');
  if (placeholder) placeholder.outerHTML = nav;

  const logoutBtn = document.getElementById('logoutBtn');
  if (logoutBtn) {
    logoutBtn.addEventListener('click', () => {
      fetch('/cgi-bin/auth_logout', { method: 'POST' }).finally(() => {
        window.location.href = '/login.html';
      });
    });
  }

  if (_script) _script.remove();
})();
