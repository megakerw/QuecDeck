// Apply the stored theme before first paint. Loaded synchronously in <head>:
// the pages hardcode data-bs-theme="dark" as the no-JS default, and the full
// dark-mode.js (toggle UI) runs at end of body, so without this a light-mode
// user gets a dark flash on every navigation. CSP blocks inline scripts, so
// this must stay an external file.
document.documentElement.setAttribute(
  'data-bs-theme',
  localStorage.getItem('theme') || 'dark'
);
