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
`Invoke-PortableSmoke.ps1`. The composite GUI suite requires an unlocked,
interactive Windows 11 desktop and therefore runs only after manual dispatch on
a self-hosted runner labeled `winghostty-interactive`.
