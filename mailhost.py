#!/usr/bin/env python3
"""Find a host name that reaches the sendmail addon over verified STARTTLS.

Upstream Endurain 0.20 verifies the SMTP server's certificate against
SMTP_HOST and refuses to send credentials without TLS. The addon's own host
name ("mail") is not on the mail server's certificate, and the certificate's
name differs from box to box, so no fixed name can be baked in.

This script is run by start.sh on every boot, before the application starts.
It reads the names the mail server's certificate covers, builds a short list
of candidates (the dashboard host from the OIDC issuer, "my." plus the mail
domain, and every name the certificate lists, with "my." and "mail." tried
under a wildcard), and prints the first one that (a) resolves from inside the
container and (b) completes a STARTTLS handshake with full certificate and
hostname verification on the addon's STARTTLS port. It prints nothing and
exits 1 when none does; start.sh then leaves email disabled and says so.

No credential is read or printed here.
"""

from __future__ import annotations

import os
import smtplib
import socket
import ssl
import sys
from urllib.parse import urlparse

TIMEOUT = 8


def _certificate_names(server: str, port: int) -> list[str]:
    """DNS names on the certificate the server presents (unverified read)."""
    from cryptography import x509

    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with smtplib.SMTP(server, port, timeout=TIMEOUT) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        der = smtp.sock.getpeercert(binary_form=True)
    cert = x509.load_der_x509_certificate(der)
    try:
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
    except x509.ExtensionNotFound:
        return []
    return san.value.get_values_for_type(x509.DNSName)


def _candidates(san_names: list[str]) -> list[str]:
    found: list[str] = []
    issuer = os.environ.get("CLOUDRON_OIDC_ISSUER", "")
    if issuer:
        found.append(urlparse(issuer).hostname or "")
    mail_domain = os.environ.get("CLOUDRON_MAIL_DOMAIN", "")
    if mail_domain:
        found.append(f"my.{mail_domain}")
    for name in san_names:
        if name.startswith("*."):
            found += [f"my.{name[2:]}", f"mail.{name[2:]}"]
        else:
            found.append(name)
    seen: set[str] = set()
    ordered = []
    for name in found:
        name = name.strip().lower()
        if name and name not in seen:
            seen.add(name)
            ordered.append(name)
    return ordered


def _verified_starttls(host: str, port: int) -> bool:
    try:
        socket.getaddrinfo(host, port)
        context = ssl.create_default_context()
        with smtplib.SMTP(host, port, timeout=TIMEOUT) as smtp:
            smtp.ehlo()
            smtp.starttls(context=context)
            smtp.ehlo()
        return True
    except (OSError, smtplib.SMTPException):
        return False


def main() -> int:
    server = os.environ.get("CLOUDRON_MAIL_SMTP_SERVER", "")
    port = int(os.environ.get("CLOUDRON_MAIL_STARTTLS_PORT", "0") or 0)
    if not server or not port:
        return 1
    try:
        san_names = _certificate_names(server, port)
    except (OSError, smtplib.SMTPException, ValueError):
        san_names = []
    for host in _candidates(san_names):
        if _verified_starttls(host, port):
            print(host)
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
