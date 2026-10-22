"""Loaded by Python at start-up as the venv's sitecustomize (see Dockerfile).

jasil verifies the mail server's certificate against the host it connects to
and has no separate TLS name. On a box whose mail certificate carries no name
that resolves inside the container, mailhost.py proves a name the certificate
does carry and start.sh exports it. This hook substitutes that name, and only
for TLS connections made to the one host recorded for the mail server, and only
when the variables are set. Everything else is untouched, and verification is
never relaxed: check_hostname and CERT_REQUIRED stay as the caller set them, so
the substituted name is checked against the certificate like any other.
"""

import os
import ssl

try:
    _original = ssl.SSLContext.wrap_socket

    def _wrap_socket(self, sock, *args, **kwargs):
        host = os.environ.get("ENDURAIN_MAIL_TLS_FOR_HOST")
        name = os.environ.get("ENDURAIN_MAIL_TLS_SERVER_NAME")
        if host and name and kwargs.get("server_hostname") == host:
            kwargs["server_hostname"] = name
        return _original(self, sock, *args, **kwargs)

    if not getattr(_original, "_endurain_mail_tls", False):
        _wrap_socket._endurain_mail_tls = True
        ssl.SSLContext.wrap_socket = _wrap_socket
except Exception:  # never stop the interpreter from starting
    pass
