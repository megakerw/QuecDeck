// Caps Lock warning for password fields. Its own file rather than part of
// utils.js: login.html and setup.html deliberately stay off utils.js to keep
// the pre-auth surface small, and those are the pages the warning matters most
// on. Loaded by every page that has a password input.
//
// Caps Lock state is only readable from a key event, so the hint appears on the
// first keystroke rather than on focus. There is no way to know before that.
//
// One shared hint element is moved to whichever field is being typed in. Only
// one can hold focus at a time, and setup.html has four of them.
(function () {
  var hint;

  function hintEl() {
    if (!hint) {
      hint = document.createElement('div');
      hint.className = 'form-text text-warning';
      // Announced by screen readers when it appears, without stealing focus.
      hint.setAttribute('role', 'status');
      hint.textContent = 'Caps Lock is on';
    }
    return hint;
  }

  function detach() {
    if (hint && hint.parentNode) hint.parentNode.removeChild(hint);
  }

  function update(e) {
    var field = e.target;
    if (!field || field.type !== 'password') return;
    var on = typeof e.getModifierState === 'function' && e.getModifierState('CapsLock');
    if (!on) {
      detach();
      return;
    }
    var el = hintEl();
    if (field.nextElementSibling !== el) field.insertAdjacentElement('afterend', el);
  }

  // Capture phase: the password fields carry their own keydown handlers
  // (developer.html submits on Enter), and this must not depend on those
  // letting the event bubble.
  document.addEventListener('keydown', update, true);
  document.addEventListener('keyup', update, true);
  document.addEventListener('focusout', function (e) {
    if (e.target && e.target.type === 'password') detach();
  }, true);
})();
