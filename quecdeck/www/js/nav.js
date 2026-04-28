(function () {
  var _script = document.currentScript;
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
    + '          <div class="container-fluid">\n'
    + '            <a class="navbar-brand ps-2" href="/"><span class="mb-0 h4">QuecDeck</span></a>\n'
    + '            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarText" aria-controls="navbarText" aria-expanded="false" aria-label="Toggle navigation">\n'
    + '              <span class="navbar-toggler-icon"></span>\n'
    + '            </button>\n'
    + '            <div class="collapse navbar-collapse" id="navbarText">\n'
    + '              <ul class="navbar-nav me-auto mb-2 mb-lg-0">\n'
    + '        ' + items + '\n'
    + '              </ul>\n'
    + '              <span class="navbar-text">\n'
    + '                <button class="btn btn-link text-reset" id="darkModeToggle">Dark Mode</button>\n'
    + '              </span>\n'
    + '            </div>\n'
    + '          </div>\n'
    + '        </nav>';

  const placeholder = document.getElementById('nav-placeholder');
  if (placeholder) placeholder.outerHTML = nav;
  if (_script) _script.remove();
})();
