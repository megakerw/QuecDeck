// Show/hide button for password fields. Its own file loaded next to
// capslock.js, for the same reason: login.html and setup.html stay off
// utils.js to keep the pre-auth surface small.
//
// Self-installing rather than per-page markup: there are 14 password inputs
// across 5 pages, and the ones on setup.html, developer.html and the
// ssh.html credential modal live inside x-if templates, so they only exist
// once Alpine inserts them. Hence the observer as well as the initial scan.
//
// The field ends up wrapped in a Bootstrap .input-group, which is why
// capslock.js anchors its hint on the group when there is one.
(function () {
  function icon(shapes) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"'
      + ' fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"'
      + ' stroke-linejoin="round" aria-hidden="true">' + shapes + '</svg>';
  }

  var EYE = icon('<path d="M1.3 8S4 3.7 8 3.7 14.7 8 14.7 8 12 12.3 8 12.3 1.3 8 1.3 8Z"/>'
    + '<circle cx="8" cy="8" r="1.9"/>');
  var EYE_OFF = icon('<path d="M1.3 8S4 3.7 8 3.7 14.7 8 14.7 8 12 12.3 8 12.3 1.3 8 1.3 8Z"/>'
    + '<circle cx="8" cy="8" r="1.9"/><path d="M2.6 2.6l10.8 10.8"/>');

  function setState(input, button, shown) {
    input.type = shown ? 'text' : 'password';
    button.innerHTML = shown ? EYE_OFF : EYE;
    button.setAttribute('aria-label', shown ? 'Hide password' : 'Show password');
    button.setAttribute('aria-pressed', shown ? 'true' : 'false');
  }

  function decorate(input) {
    if (input.dataset.pwToggle || !input.parentNode) return;
    input.dataset.pwToggle = '1';

    var group = document.createElement('div');
    group.className = 'input-group';
    input.parentNode.insertBefore(group, input);
    group.appendChild(input);

    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'btn btn-outline-secondary';
    setState(input, button, false);
    button.addEventListener('click', function () {
      setState(input, button, input.type === 'password');
      // Changing the type drops focus in some browsers, so typing would
      // otherwise continue somewhere else.
      input.focus();
    });
    group.appendChild(button);
  }

  function scan(node) {
    if (node.nodeType !== 1) return;
    if (node.matches('input[type="password"]')) decorate(node);
    var found = node.querySelectorAll('input[type="password"]');
    for (var i = 0; i < found.length; i++) decorate(found[i]);
  }

  function start() {
    scan(document.body);
    new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var added = records[i].addedNodes;
        for (var j = 0; j < added.length; j++) scan(added[j]);
      }
    }).observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
