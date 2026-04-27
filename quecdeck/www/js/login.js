function loginPage() {
  const params = new URLSearchParams(location.search);

  // Read ?next= from auth.lua redirect and validate client-side.
  // Rejects CGI paths, protocol-relative URLs, traversal, and the login page itself.
  const rawNext = params.get('next') || '';
  const next = /^\/([a-zA-Z0-9_-]+\.html)?$/.test(rawNext) && rawNext !== '/login.html' ? rawNext : '/';

  return {
    error:      false,
    locked:     false,
    expired:    params.get('expired')   === '1',
    submitting: false,
    nextUrl:    next,

    submitLogin(event) {
      const form = event.target;
      this.error = false;
      this.locked = false;
      this.submitting = true;

      const body = new URLSearchParams();
      body.append('username', 'admin');
      body.append('password', form.password.value);

      fetch('/cgi-bin/auth_login', { method: 'POST', body })
        .then(r => r.json())
        .then(data => {
          if (data.ok) {
            window.location.href = this.nextUrl;
          } else if (data.error === 'locked') {
            this.locked = true;
            this.submitting = false;
          } else {
            this.error = true;
            this.submitting = false;
          }
        })
        .catch(() => {
          this.error = true;
          this.submitting = false;
        });
    },
  };
}
