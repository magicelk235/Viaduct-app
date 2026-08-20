# Security Policy

## Supported Versions

Viaduct is distributed as a rolling release: only the latest version on the
`main` branch and the most recent published build receive security fixes. If
you are running an older build, update before reporting an issue.

| Version        | Supported          |
| -------------- | ------------------ |
| Latest release | :white_check_mark: |
| Older builds   | :x:                |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately through one of:

- **GitHub Security Advisories** — open a draft advisory at
  <https://github.com/magicelk235/viaduct-app/security/advisories/new>
  (preferred).
- **Email** — yehonatan.2350@gmail.com with subject line `SECURITY: viaduct-app`.

Please include:

- A description of the vulnerability and its impact.
- Steps to reproduce (a proof-of-concept if you have one).
- Affected version, macOS version, and any relevant configuration.

## What to Expect

- **Acknowledgement** within 5 business days.
- An assessment and, where confirmed, a fix timeline. Most issues are patched
  in the next release.
- Credit in the release notes once a fix ships, unless you ask to stay
  anonymous.

Please give a reasonable window to release a fix before any public disclosure.

## Scope Notes

Viaduct wraps the [`@magicelk235/viaduct`](https://www.npmjs.com/package/@magicelk235/viaduct)
command-line tool and can download extensions from the Chrome Web Store, sign
them with your local Apple identity, and download or update that tool from npm.
Reports touching any of these paths — CLI invocation, code signing, the
`viaduct://` URL scheme, or the auto-update flow — are in scope. Vulnerabilities
in the upstream CLI package itself should be reported against that package.
