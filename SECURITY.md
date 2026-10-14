# Security Policy

## Supported versions

Security fixes are made for the latest release of NanoHTTP.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Send an email to the maintainer, Matthias Zenger
(<matthias@objecthub.com>), with

- a description of the problem and which versions are affected,
- a way to reproduce it (a request, a handler, a test),
- what an attacker gains.

You will get an answer as soon as possible. A fix is released together with a note in the
[CHANGELOG](CHANGELOG.md), and the report is credited if you wish.

## Scope

NanoHTTP is made for servers that are used by you, your own devices or a small trusted group. These are known
limitations that are documented and not vulnerabilities: there is no TLS, no authentication and no rate limiting; the
timeouts are pauses (a client that sends a byte every few seconds keeps its connection and its thread); the server does
not check the `Host` or `Origin` headers unless you switch that on (`hostPolicy`, `originPolicy`). See the article
*Security and Limits* in the documentation.

In scope are bugs in the framework that go beyond that: reading or writing files outside a shared directory,
crashes or unbounded memory use caused by a single request, injection of response headers, corrupted
connections, and the like.
