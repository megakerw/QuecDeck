function postSecurityAction(params) {
  return fetchJSON('/cgi-bin/manage_security', {
    method: 'POST',
    body: new URLSearchParams(params),
  });
}
