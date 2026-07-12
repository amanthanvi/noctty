[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures = [System.Collections.Generic.List[string]]::new()
$node = Get-Command node -ErrorAction SilentlyContinue
$tracked = @(& git -C $repoRoot ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' '*.md' '*.yml' '*.yaml' '*.json')
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }

foreach ($relative in $tracked) {
    $path = Join-Path $repoRoot $relative
    if ($relative.EndsWith('.ps1') -or $relative.EndsWith('.psm1')) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        foreach ($error in $errors) { $failures.Add("${relative}: $($error.Message)") }
    }
    elseif ($relative.EndsWith('.json')) {
        try {
            $json = [System.IO.File]::ReadAllText($path)
            if ($null -ne $node) {
                $encodedPath = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($path))
                $script = @"
const fs = require('fs');
const path = Buffer.from(process.argv[2], 'base64').toString('utf8');
JSON.parse(fs.readFileSync(path, 'utf8'));
"@
                $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script))
                & $node.Source -e "eval(Buffer.from(process.argv[1], 'base64').toString('utf8'))" $encodedScript $encodedPath
                if ($LASTEXITCODE -ne 0) { throw "node JSON.parse failed" }
            } else {
                [void]($json | ConvertFrom-Json)
            }
        }
        catch { $failures.Add("${relative}: invalid JSON: $($_.Exception.Message)") }
    }
}

if ($failures.Count -gt 0) {
    $failures | Sort-Object -Unique | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Host 'PowerShell syntax and JSON validity checks passed.' -ForegroundColor Green
