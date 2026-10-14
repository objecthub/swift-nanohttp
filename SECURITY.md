# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 2.x | Yes: all fixes and new features, on the `main` branch. |
| 1.0.x | Security and crash fixes only, until the end of 2027 (31 December 2027), on the `release/1.x` branch. Everything else is made for 2.x: see [MIGRATION-2.0.md](MIGRATION-2.0.md) for how to upgrade. |
| Older | No. |

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
not check the `Host` or `Origin` headers unless you switch that on (`hostPolicy`, `originPolicy`). The demo server and
the programs in `Examples/` show how to use the framework: they listen at the loopback address unless started with
`--network`, and are no hardened servers. See the article *Security and Limits* in the documentation.

In scope are bugs in the framework that go beyond that: reading or writing files outside a shared directory,
crashes or unbounded memory use caused by a single request, injection of response headers, corrupted
connections, and the like.
