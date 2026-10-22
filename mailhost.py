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

Fallback (0.2.1). Some boxes present a certificate whose names do not resolve
inside the container to anything that accepts the connection (for example a
wildcard for the primary domain whose public address has the mail port closed).
Then no candidate passes. The script next connects to the addon's own host
name and verifies the certificate against a name the certificate genuinely
carries (a concrete name, or "my." under a wildcard), with full verification:
CERT_REQUIRED, hostname check on, the system CA bundle. If that passes it
prints "<connect host> <tls name>"; start.sh exports the tls name and
mailtls.py (loaded as sitecustomize in the venv) substitutes it, and only it,
as the TLS server name for connections to that one host. Verification is never
relaxed. The reason for a failure goes to stderr (no credential is involved).

Test knobs, for the lab only, both harmless in production because a name is
still verified: ENDURAIN_MAIL_DIAG_SKIP_DIRECT=1 skips the direct candidates;
ENDURAIN_MAIL_DIAG_TLS_NAME=<name> replaces the certificate-derived TLS names.

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


def _tls_name_candidates(san_names: list[str]) -> list[str]:
    """Names the certificate genuinely carries, concrete first."""
    forced = os.environ.get("ENDURAIN_MAIL_DIAG_TLS_NAME", "").strip().lower()
    if forced:
        return [forced]
    names = [n for n in san_names if not n.startswith("*.")]
    names += [f"my.{n[2:]}" for n in san_names if n.startswith("*.")]
    seen: set[str] = set()
    ordered = []
    for name in names:
        name = name.strip().lower()
        if name and name not in seen:
            seen.add(name)
            ordered.append(name)
    return ordered


def _verified_starttls_as(host: str, port: int, tls_name: str) -> str:
    """Connect to host, verify the certificate against tls_name. "" on success,
    else a short reason. Full verification; nothing is relaxed."""
    try:
        context = ssl.create_default_context()
        context.check_hostname = True
        context.verify_mode = ssl.CERT_REQUIRED
        with smtplib.SMTP(host, port, timeout=TIMEOUT) as smtp:
            smtp.ehlo()
            code, _ = smtp.docmd("STARTTLS")
            if code != 220:
                return f"STARTTLS refused ({code})"
            tls = context.wrap_socket(smtp.sock, server_hostname=tls_name)
            tls.close()
        return ""
    except ssl.SSLCertVerificationError as error:
        return f"certificate verification failed: {error.verify_message}"
    except ssl.SSLError as error:
        return f"TLS error: {error.reason}"
    except (OSError, smtplib.SMTPException) as error:
        return f"connection failed: {type(error).__name__}"


def main() -> int:
    server = os.environ.get("CLOUDRON_MAIL_SMTP_SERVER", "")
    port = int(os.environ.get("CLOUDRON_MAIL_STARTTLS_PORT", "0") or 0)
    if not server or not port:
        return 1
    try:
        san_names = _certificate_names(server, port)
    except (OSError, smtplib.SMTPException, ValueError):
        san_names = []
    if not os.environ.get("ENDURAIN_MAIL_DIAG_SKIP_DIRECT"):
        for host in _candidates(san_names):
            if _verified_starttls(host, port):
                print(host)
                return 0
    reasons = []
    for name in _tls_name_candidates(san_names):
        reason = _verified_starttls_as(server, port, name)
        if not reason:
            print(f"{server} {name}")
            return 0
        reasons.append(f"{name}: {reason}")
    if not reasons:
        reasons.append("the certificate carries no usable name or could not be read")
    print("mailhost: no direct name passed; fallback to " + server + " failed ("
          + "; ".join(reasons) + ")", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
