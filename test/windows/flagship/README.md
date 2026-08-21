# Flagship verification contracts

Versioned, machine-readable contracts for the flagship runtime rewrite.

- `scenario.schema.json`: stable scenario definition format.
- `result.schema.json`: runner output consumed by CI and baseline comparisons.
- `baseline-manifest.schema.json`: checksummed frozen-oracle inventory.
- `scenarios/`: workflow-runnable scenario definitions.
- `examples/`: format examples; hashes are placeholders, not frozen evidence.
- `baselines/`: immutable manifests tied to a base commit and verified hashes.
- `Test-VerificationContracts.ps1`: stable entry point and aggregate-failure
  runner.
- `contracts/ContractHelpers.ps1`: shared assertions, AST helpers, and the
  table-contract failure collector.
- `contracts/Contracts.*.ps1`: ordered per-target contract fragments. A thrown
  code assertion stops only its fragment; table rows continue and report every
  failed row.

Validate the contracts:

```powershell
pwsh -NoProfile -File test/windows/flagship/Test-VerificationContracts.ps1
./test/windows/flagship/Test-VerificationContracts.ps1
```

Both forms resolve fragments relative to the entry point, independent of the
caller's current directory.

## Regenerating protected workflow digests

`contracts/Contracts.80-Release.ps1` freezes eight canonical SHA-256 values:
the full release and readiness workflows, three protected step envelopes, and
their three literal `run` bodies. A legitimate workflow edit requires semantic
review of the full file and protected steps before replacing any digest.

From the repository root, calculate the candidate values with the same
canonicalization and extraction helpers used by the contracts:

```powershell
$repoRoot = (Resolve-Path '.').Path
. (Join-Path $repoRoot 'test/windows/flagship/contracts/ContractHelpers.ps1')

$releasePath = Join-Path $repoRoot '.github/workflows/release.yml'
$readinessPath = Join-Path $repoRoot '.github/workflows/release-readiness.yml'
$release = Get-Content -LiteralPath $releasePath -Raw
$readiness = Get-Content -LiteralPath $readinessPath -Raw
$releasePreflight = Get-YamlStepBlock -Content $release -Name 'Release preflight' -Source $releasePath
$readinessPreflight = Get-YamlStepBlock -Content $readiness -Name 'Validate release configuration' -Source $readinessPath
$interactiveEvidence = Get-YamlStepBlock -Content $release -Name 'Require successful Test workflow for release SHA' -Source $releasePath

$pins = [ordered]@{
    releasePreflightScriptSha256 = (Get-CanonicalTextSha256 -Text (Get-YamlLiteralRunScript -Content $releasePreflight -Source 'Release preflight'))
    readinessPreflightScriptSha256 = (Get-CanonicalTextSha256 -Text (Get-YamlLiteralRunScript -Content $readinessPreflight -Source 'Validate release configuration'))
    releaseInteractiveEvidenceScriptSha256 = (Get-CanonicalTextSha256 -Text (Get-YamlLiteralRunScript -Content $interactiveEvidence -Source 'Require successful Test workflow for release SHA'))
    releaseInteractiveEvidenceStepSha256 = (Get-CanonicalTextSha256 -Text $interactiveEvidence)
    releasePreflightStepSha256 = (Get-CanonicalTextSha256 -Text $releasePreflight)
    readinessPreflightStepSha256 = (Get-CanonicalTextSha256 -Text $readinessPreflight)
    releaseWorkflowSha256 = (Get-CanonicalTextSha256 -Text $release)
    readinessWorkflowSha256 = (Get-CanonicalTextSha256 -Text $readiness)
}
$pins.GetEnumerator() | ForEach-Object { '{0} = {1}' -f $_.Key, $_.Value }
```

Update only the corresponding values near the top of
`Contracts.80-Release.ps1`, then rerun the contract entry point. The mutation
tests must remain unchanged and green.

Hosted Windows CI runs the x64 portable smoke through
`Invoke-PortableSmoke.ps1`. The full composite runs only on opted-in
manual dispatches (`run_interactive_win11=true`) on the unlocked
self-hosted runner labeled `winghostty-interactive`; no standing runner
exists, so the machine is registered ephemerally when release evidence
is needed. Fork pull requests never execute on that runner.
The job fails unless the runner is Windows 11 x64, non-system, attached to the
active console session with an Explorer shell, on the `Default` input desktop,
and checked out at the exact workflow SHA. Its name, user, session, exact
commit, workflow run, and machine are persisted as a provenance artifact. This
narrows accidental runner drift; the self-hosted machine remains an explicit CI
trust boundary and must be registered ephemerally for release validation.
