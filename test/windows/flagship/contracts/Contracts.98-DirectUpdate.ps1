# The live updater test is opt-in and downloads only published releases.
# Keep its isolation and evidence-admission controls in the normal contract gate.
& (Join-Path $repoRoot 'test/windows/direct-update-contract.ps1')
