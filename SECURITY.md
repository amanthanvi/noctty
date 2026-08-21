# Security policy

## Reporting a vulnerability

Please do not open a public issue for suspected security
vulnerabilities.

Report them privately through GitHub's security advisory flow for this
repository if it is enabled. If private reporting is unavailable, contact
the maintainer directly before publishing details.

If your report involves a crash, note that crash dumps and diagnostic
bundles stay local and may contain sensitive process memory. See
[docs/windows.md](docs/windows.md#crash-reports-and-diagnostics) before
attaching one.

Include:

- A concise description of the issue
- Affected versions or commit range
- Reproduction steps or proof of concept
- Expected impact
- Any suggested mitigation if you already have one

## Response expectations

This is a small maintained project, so response time is best-effort.
Reports that are clear, reproducible, and scoped to this repository will
be easier to triage quickly.

See [the Win32 paste-path security audit](docs/security-audit-paste-paths.md) for the current source-to-sink review.
