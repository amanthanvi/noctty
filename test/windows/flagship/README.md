# Flagship verification contracts

Versioned, machine-readable contracts for the flagship runtime rewrite.

- `scenario.schema.json`: stable scenario definition format.
- `result.schema.json`: runner output consumed by CI and baseline comparisons.
- `baseline-manifest.schema.json`: checksummed frozen-oracle inventory.
- `scenarios/`: workflow-runnable scenario definitions.
- `examples/`: format examples; hashes are placeholders, not frozen evidence.
- `baselines/`: immutable manifests tied to a base commit and verified hashes.

Validate the contracts:

```powershell
pwsh -File test/windows/flagship/Test-VerificationContracts.ps1
```

Hosted Windows CI runs the x64 portable smoke through
`Invoke-PortableSmoke.ps1`. Same-repository pull requests run the stable GUI
smoke subset; pushes to `main`, the nightly schedule, and opted-in manual
dispatches run the full composite on the unlocked self-hosted runner labeled
`winghostty-interactive`. Fork pull requests never execute on that runner.
The job fails unless the runner is Windows 11 x64, non-system, attached to the
active console session with an Explorer shell, on the `Default` input desktop,
and checked out at the exact workflow SHA. Its name, user, session, exact
commit, workflow run, and machine are persisted as a provenance artifact. This
narrows accidental runner drift; the self-hosted machine remains an explicit CI
trust boundary and must be registered ephemerally for release validation.
