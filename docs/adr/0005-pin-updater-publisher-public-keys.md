# Pin updater publisher public keys

winghostty's downloaded-installer path requires a valid Authenticode signature
from a signer whose SubjectPublicKeyInfo (SPKI) matches a compiled SHA-256 pin.
Normal Windows chain trust is accepted. The exact `CERT_E_UNTRUSTEDROOT`
WinTrust result is accepted only after the actual WinTrust signer certificate
matches the compiled SPKI pin, which lets the pin act as the trust anchor for
the current self-signed release certificate without accepting broken signatures,
wrong publishers, expired/invalid chains, or other WinTrust failures.

The current release track pins the SPKI for the self-signed
`CN=winghostty Local Dev Signing` certificate used by v1.3.117:
`671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a`.
Checksums published beside an installer remain integrity metadata, not an
independent publisher identity.

Pins are compiled into the application as a small allowlist. Certificate
renewal with the same key needs no application change. Key rotation requires
an overlap release that trusts both the current and next public keys before
release signing moves to the next key; a later release may remove the retired
key. An empty allowlist or a signer mismatch disables verified download/apply
and fails visibly while leaving release-page checks available.

The staged installer and its containing stage directory must remain open
without delete sharing from hash and Authenticode verification until the
elevated launch handoff returns. The verifier rejects reparse points and
compares the installer's final handle path to the staged state path before
launch. This binds verification and execution to the same file object and keeps
the parent stage path from being renamed out from under `ShellExecuteW`.
