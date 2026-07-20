// Apply the stored theme before first paint. Loaded synchronously in <head>:
// the pages hardcode data-bs-theme="dark" as the no-JS default, and the full
// dark-mode.js (toggle UI) runs at end of body, so without this a light-mode
// user gets a dark flash on every navigation. CSP blocks inline scripts, so
// this must stay an external file.
var _theme = localStorage.getItem('theme') || 'dark';
document.documentElement.setAttribute('data-bs-theme', _theme);
// Set color-scheme inline (not just via the CSS rule) so the browser paints the
// canvas in the theme's color before the stylesheet applies. Firefox reads the
// CSS color-scheme too late and flashes white on navigation without this.
// dark-mode.js keeps it in sync on toggle.
document.documentElement.style.colorScheme = _theme;
