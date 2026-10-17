# The Windows 10 pre-release checklist must keep up with the code that branches on
# the Windows build, and the report-only workflow must stay what the checklist
# says it is. No GitHub-hosted image is Windows 10, so these contracts are what
# stops the checklist from going stale between releases.
$win10ChecklistPath = Join-Path $repoRoot 'docs\windows10-release-checklist.md'
$win10WorkflowPath = Join-Path $repoRoot '.github\workflows\windows10-branches.yml'
$win10Checklist = Get-Content -LiteralPath $win10ChecklistPath -Raw
$win10Workflow = Get-Content -LiteralPath $win10WorkflowPath -Raw

# Blanks every Zig comment, multi-line-string line, string literal and character literal, keeping
# the length, so an offset in the result is an offset in the source.
function Remove-ZigNonCode([string] $Text) {
    return [regex]::Replace($Text, '//[^\n]*|\\\\[^\n]*|''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*"', { param($m) ' ' * $m.Length })
}

# Every function whose body compares the Windows build to something, on either side of the
# operator, for the current os_build spelling, an OS_BUILD_ constant or RtlGetVersion's field.
# This is a bounded scan, not data-flow analysis: a future gate using another variable name must
# extend the scanner and fixtures. Comparisons in test blocks do not count.
function Get-WindowsBuildGateFunctions([string] $ZigText) {
    $code = Remove-ZigNonCode $ZigText
    $build = '(?:\bos_build\b|\bOS_BUILD_\w+\b|\bdwBuildNumber\b)'
    $comparison = [regex]('(?:' + $build + '\s*(?:>=|<=|==|!=|(?<![=\-])>|<)|(?:>=|<=|==|!=|(?<![=\-])>|<)\s*[\w.]*' + $build + ')')
    $containers = [regex]::Matches($code, '(?m)^[ \t]*(?:pub[ \t]+)?(?:inline[ \t]+)?fn[ \t]+(\w+)[ \t]*\(|^[ \t]*test[ \t]*(?:"|\{)')
    $found = [Collections.Generic.SortedSet[string]]::new()
    foreach ($hit in $comparison.Matches($code)) {
        $container = $containers | Where-Object { $_.Index -lt $hit.Index } | Select-Object -Last 1
        if ($null -eq $container) { throw 'A comparison of the Windows build sits outside any function.' }
        if ($container.Groups[1].Success) { [void]$found.Add($container.Groups[1].Value) }
    }
    return @($found)
}

# The scanner is part of the contract: each case below is a shape a gate can take.
foreach ($fixture in @(
        @{ Name = 'a forward comparison'; Zig = "fn gate(os_build: u32) bool { return os_build >= 22000; }"; Expect = @('gate') }
        @{ Name = 'a reversed comparison'; Zig = "fn rev(os_build: u32) bool { return 22000 <= os_build; }"; Expect = @('rev') }
        @{ Name = 'a comparison against a constant'; Zig = "fn k(x: u32) bool {`n    return x < c.OS_BUILD_WIN11_21H2;`n}"; Expect = @('k') }
        @{ Name = 'a comparison of RtlGetVersion output'; Zig = "fn probe() bool { return info.dwBuildNumber < 22621; }"; Expect = @('probe') }
        @{ Name = 'a comment'; Zig = "// os_build >= 22000 is only a comment`nfn nothing() void {}"; Expect = @() }
        @{ Name = 'a string'; Zig = "const text = `"os_build >= 22000`";`nfn nothing() void {}"; Expect = @() }
        @{ Name = 'a comparison in a test'; Zig = "fn plain() void {}`ntest `"x`" { try expect(os_build >= 1); }"; Expect = @() }
        @{ Name = 'an assignment'; Zig = "fn set(app: *App) void { app.os_build = c.OS_BUILD_WIN11_21H2; }"; Expect = @() }
    )) {
    $got = @(Get-WindowsBuildGateFunctions $fixture.Zig)
    if (($got -join ',') -ne ($fixture.Expect -join ',')) {
        throw "The Windows build gate scanner is wrong for $($fixture.Name): expected [$($fixture.Expect -join ',')], found [$($got -join ',')]."
    }
}

$win10GateFunctions = [Collections.Generic.SortedSet[string]]::new()
foreach ($zigFile in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Filter '*.zig' -Recurse -File) {
    foreach ($function in Get-WindowsBuildGateFunctions (Get-Content -LiteralPath $zigFile.FullName -Raw)) {
        [void]$win10GateFunctions.Add($function)
    }
}
if ($win10GateFunctions.Count -lt 3) {
    throw "Found only $($win10GateFunctions.Count) functions that compare the Windows build; the gate scan is out of date."
}

$win10BuildConstants = [regex]::Matches(
    (Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32\consts.zig') -Raw),
    '(?m)^pub const (OS_BUILD_\w+): u32 = (\d+);')
if ($win10BuildConstants.Count -lt 3) {
    throw 'src/apprt/win32/consts.zig no longer declares the OS_BUILD_ constants the checklist names.'
}

$win10RowIds = @([regex]::Matches($win10Checklist, '(?m)^\*\*(W10-\d{2}) ') | ForEach-Object { $_.Groups[1].Value })
if ($win10RowIds.Count -eq 0) { throw 'The Windows 10 checklist has no W10-nn rows.' }
$win10ExpectedIds = @(1..$win10RowIds.Count | ForEach-Object { 'W10-{0:D2}' -f $_ })

# The workflow's steps, with comments removed so that a comment cannot satisfy a pattern. Each one
# must stay in the job that runs unconditionally, because a green run is the evidence.
$win10Job = Get-YamlJobText -Content $win10Workflow -Name 'server-2022' -Source $win10WorkflowPath
function Get-Win10WorkflowStep([string] $Name, [string] $Job = $win10Job) {
    $step = Get-YamlStepBlock -Content $Job -Name $Name -Source $win10WorkflowPath
    return (($step -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
function Get-Win10StepCode([string] $Step) {
    # Inspect the actual run scalar, including inline comments; YAML metadata/comments are not code.
    $run = [regex]::Match($Step, '(?m)^        run: (?<scalar>[^\r\n]*)\r?$')
    if (-not $run.Success) { throw 'Windows 10 step lost its run command.' }
    $code = if ($run.Groups['scalar'].Value.Trim() -eq '|') {
        (($Step.Substring($run.Index + $run.Length) -split "`n") | Where-Object { $_ -match '^          ' } | ForEach-Object { $_.Substring(10) }) -join "`n"
    } else { $run.Groups['scalar'].Value }
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Windows 10 run command does not parse.' }
    $builder = [Text.StringBuilder]::new($code)
    foreach ($token in @($tokens | Where-Object Kind -eq 'Comment' | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    return $builder.ToString()
}
$win10WorkflowSteps = [ordered]@{
    'Require a Windows build below 22000' = @(
        '(?m)^\$os = Get-CimInstance Win32_OperatingSystem\s*$'
        '(?m)^\$build = \[int\]\$os\.BuildNumber\s*$'
        '(?m)^if \(\$build -ge 22000\) \{\s*throw '
    )
    'Full Zig test suite' = @(
        '(?m)^zig build test -Demit-test-exe=true -Dcustom-shaders=true --summary all 2>&1 \| Tee-Object -FilePath zig-test\.log\s*\r?\n\$code = \$LASTEXITCODE\s*$'
        '(?m)^if \(\$code -ne 0\) \{ exit \$code \}\s*$'
    )
    'noctty +version smoke' = @(
        '(?m)^\$versionText = & \.\\zig-out\\bin\\noctty\.com \+version \| Out-String\s*$'
        '(?m)^if \(\$LASTEXITCODE -ne 0\) \{ throw '
        '(?m)^if \(\$versionText -notmatch ''ConPTY''\) \{ throw '
    )
    'Hidden-desktop WARP lifecycle smoke' = @(
        '\A\./test/windows/renderer/Invoke-RendererParity\.ps1 -Binary \./renderer-smoke/bin/noctty\.exe -OutputDirectory \./renderer-smoke/evidence -WarpOnly\s*\z'
    )
    'Require the app to take the Windows 10 branch' = @(
        '(?m)^\$logs = @\(Get-ChildItem -Path renderer-smoke/evidence, hidden-evidence -Recurse -Filter stderr\.txt\)\s*$'
        '(?m)^if \(\$logs\.Count -eq 0\) \{ throw '
        '(?m)^\$lines = \$logs \| Select-String -Pattern ''os_build=\(\\d\+\) integrated_titlebar=\(true\|false\)''\s*$'
        '(?m)^if \(-not \$lines\) \{ throw '
        '(?m)^foreach \(\$line in \$lines\) \{\s*\$match = \[regex\]::Match\(\$line\.Line, ''os_build=\(\\d\+\) integrated_titlebar=\(true\|false\)''\)\s*\$build = \[int\]\$match\.Groups\[1\]\.Value\s*if \(\$build -ne \[int\]\$env:windows_build -or \$build -ge 22000 -or \$match\.Groups\[2\]\.Value -ne ''false''\) \{\s*throw '
    )
}

function Assert-Win10Step([string] $Name, [string] $Step) {
    $code = Get-Win10StepCode $Step
    foreach ($pattern in $win10WorkflowSteps[$Name]) {
        if ($code -notmatch $pattern) { throw "Windows 10 '$Name' lost a required executable guard." }
    }
}
$win10TriggerPattern = '(?ms)^on:\r?\n  schedule:\r?\n    - cron: "[^"\r\n]+"\r?\n  workflow_dispatch:\r?\n  pull_request:\r?\n    paths:\r?\n      - \.github/workflows/windows10-branches\.yml[ \t]*\r?\n\s*(?=^permissions:|\z)'
function Assert-Win10Triggers([string] $Workflow) {
    if ($Workflow -notmatch $win10TriggerPattern) { throw 'Windows 10 trigger block allows extra events or paths.' }
}
function Assert-Win10Inventory([string] $Checklist) {
    $inventory = [regex]::Match($Checklist, '(?ms)^## Gate inventory\r?\n(?<table>.*?)(?=^## |\z)').Groups['table'].Value
    $rows = @([regex]::Matches($inventory, '(?m)^\|[^\r\n]+\|[ \t]*\r?$') | ForEach-Object { $_.Value })
    foreach ($symbol in @($win10GateFunctions) + @($win10BuildConstants | ForEach-Object { $_.Groups[1].Value })) {
        if (-not ($rows | Where-Object { $_ -match ('`' + [regex]::Escape($symbol) + '`') })) { throw "Windows 10 inventory table lost $symbol." }
    }
    foreach ($row in $rows | Where-Object { $_ -match 'W10-' }) {
        foreach ($reference in [regex]::Matches($row, '\bW10-\d{2}\b')) {
            if ($win10RowIds -cnotcontains $reference.Value) { throw "Windows 10 inventory refers to undefined row $($reference.Value)." }
        }
    }
}
Assert-Win10Triggers $win10Workflow
Assert-Win10Inventory $win10Checklist

$win10Contracts = @(
    @{
        File = $win10ChecklistPath
        Content = { ($win10RowIds -join ',') }
        Pattern = ('^' + [regex]::Escape($win10ExpectedIds -join ',') + '$')
        Kind = 'Text'
        Description = 'checklist rows are numbered W10-01 upward with no gap or repeat'
    }
    @{
        File = $win10ChecklistPath
        Content = { ([regex]::Matches($win10Checklist, '(?m)^\| (W10-\d{2}) +\|') | ForEach-Object { $_.Groups[1].Value }) -join ',' }
        Pattern = ('\A' + [regex]::Escape(($win10ExpectedIds -join ',')) + '\z')
        Kind = 'Text'
        Description = 'the results table covers every checklist row'
    }
    @{
        File = $win10ChecklistPath
        Content = { $win10Checklist }
        Pattern = '\(\.\./\.github/workflows/windows10-branches\.yml\)'
        Kind = 'Text'
        Description = 'the checklist links the report-only Windows 10 workflow'
    }
    @{
        File = (Join-Path $repoRoot 'PACKAGING.md')
        Content = { Get-Content -LiteralPath (Join-Path $repoRoot 'PACKAGING.md') -Raw }
        Pattern = '(?s)### Release runbook.*docs/windows10-release-checklist\.md.*### WinGet'
        Kind = 'Text'
        Description = 'the release runbook links the Windows 10 checklist'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?m)^    runs-on: windows-2022\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow runs on the Server 2022 image, the only hosted one below build 22000'
    }
    @{
        File = (Join-Path $repoRoot 'src/apprt/win32.zig')
        Content = { Get-Content -LiteralPath (Join-Path $repoRoot 'src/apprt/win32.zig') -Raw }
        Pattern = 'log\.info\("win32 os_build=\{d\} integrated_titlebar=\{\}"'
        Kind = 'Text'
        Description = 'the startup log format still matches the workflow and checklist evidence reader'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = $win10TriggerPattern
        Kind = 'Text'
        Description = 'the Windows 10 workflow runs on a schedule and on demand, and on a pull request only for its own file'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?ms)^permissions:\s+contents: read\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow has read-only permissions'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?m)^    timeout-minutes: \d+\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow bounds its job'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?ms)- name: Setup Zig.*?with:\s+version: 0\.15\.2\s+use-cache: false'
        Kind = 'Text'
        Description = 'the Windows 10 workflow cannot restore failed Zig build caches'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Job -replace '(?s)\n    steps:.*', '' }
        Pattern = '(?s)^(?!.*(?:continue-on-error|\n    if:))'
        Kind = 'Text'
        Description = 'the Windows 10 job does not ignore failures or skip itself'
    }
)
foreach ($step in $win10WorkflowSteps.Keys) {
    # The text is read here, not in a script block: a block run later cannot see this file's functions.
    $stepText = Get-Win10WorkflowStep $step
    Assert-Win10Step $step $stepText
    foreach ($pattern in $win10WorkflowSteps[$step]) { $win10Contracts += @{
        File = "$win10WorkflowPath :: $step"
        Content = (Get-Win10StepCode $stepText)
        Pattern = $pattern
        Kind = 'Text'
        Description = "the Windows 10 workflow's '$step' step runs its check"
    } }
    $win10Contracts += @{
        File = "$win10WorkflowPath :: $step"
        Content = $stepText
        Pattern = '(?s)^(?!.*(?:continue-on-error|\n {8}if:))'
        Kind = 'Text'
        Description = "the Windows 10 workflow's '$step' step is unconditional and fails the job"
    }
}
Invoke-ContractTable -Contracts $win10Contracts

# Negative controls mutate only strings already read above. They never execute workflow commands.
$win10Mutations = 0
function Assert-Win10Mutation([string] $Name, [string] $Original, [string] $Mutated, [scriptblock] $Validate) {
    if ($Original -ceq $Mutated) { throw "Windows 10 mutation '$Name' changed nothing." }
    & $Validate $Original
    $rejected = $false
    try { & $Validate $Mutated } catch { $rejected = $true }
    if (-not $rejected) { throw "Windows 10 contract accepted '$Name'." }
    $script:win10Mutations++
}
foreach ($case in @(
    @{ Step = 'Require a Windows build below 22000'; From = '$build = [int]$os.BuildNumber'; To = '$build = 20348' }
    @{ Step = 'Require a Windows build below 22000'; From = '$build -ge 22000'; To = '$build -lt 22000' }
    @{ Step = 'Full Zig test suite'; From = '$code = $LASTEXITCODE'; To = '$code = 0' }
    @{ Step = 'Full Zig test suite'; From = '$code = $LASTEXITCODE'; To = '# $code = $LASTEXITCODE' }
    @{ Step = 'Full Zig test suite'; From = 'if ($code -ne 0) { exit $code }'; To = '' }
    @{ Step = 'Full Zig test suite'; From = '$code -ne 0'; To = '$code -eq 0' }
    @{ Step = 'Full Zig test suite'; From = 'exit $code'; To = 'exit 0' }
    @{ Step = 'noctty +version smoke'; From = '$LASTEXITCODE -ne 0'; To = '$LASTEXITCODE -eq 0' }
    @{ Step = 'noctty +version smoke'; From = "if (`$versionText -notmatch 'ConPTY')"; To = "if (`$versionText -match 'ConPTY')" }
    @{ Step = 'noctty +version smoke'; From = "if (`$versionText -notmatch 'ConPTY')"; To = "# if (`$versionText -notmatch 'ConPTY')" }
    @{ Step = 'Hidden-desktop WARP lifecycle smoke'; From = 'run: ./test/windows/renderer/Invoke-RendererParity.ps1'; To = 'run: # ./test/windows/renderer/Invoke-RendererParity.ps1' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = '$logs.Count -eq 0'; To = '$logs.Count -lt 0' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = 'if (-not $lines)'; To = 'if ($lines)' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = 'foreach ($line in $lines)'; To = 'foreach ($line in @())' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = '$build -ne [int]$env:windows_build -or '; To = '' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = '$build -ne [int]$env:windows_build'; To = '$build -eq [int]$env:windows_build' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = '$build -ge 22000 -or '; To = '' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = '$build -ge 22000'; To = '$build -lt 22000' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = " -or `$match.Groups[2].Value -ne 'false'"; To = '' }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = "`$match.Groups[2].Value -ne 'false'"; To = "`$match.Groups[2].Value -eq 'false'" }
    @{ Step = 'Require the app to take the Windows 10 branch'; From = '$build = [int]$match.Groups[1].Value'; To = '$build = [int]$env:windows_build' }
)) {
    $stepText = Get-Win10WorkflowStep $case.Step
    Assert-Win10Mutation "$($case.Step): $($case.From)" $stepText ($stepText.Replace($case.From, $case.To)) {
        param($text) Assert-Win10Step $case.Step $text
    }
}
Assert-Win10Mutation 'extra push event' $win10Workflow ($win10Workflow.Replace("on:`n", "on:`n  push:`n")) ${function:Assert-Win10Triggers}
Assert-Win10Mutation 'extra pull request path' $win10Workflow ($win10Workflow.Replace('      - .github/workflows/windows10-branches.yml', "      - .github/workflows/windows10-branches.yml`n      - src/**")) ${function:Assert-Win10Triggers}
foreach ($symbol in $win10GateFunctions) {
    $withoutRow = [regex]::Replace($win10Checklist, ('(?m)^\|[^\r\n]*`' + [regex]::Escape($symbol) + '`[^\r\n]*\r?\n'), '')
    # A prose mention cannot replace an inventory table entry.
    Assert-Win10Mutation "inventory row $symbol" $win10Checklist ($withoutRow + "`nProse only: ``$symbol``.`n") ${function:Assert-Win10Inventory}
}
Assert-Win10Mutation 'undefined inventory row reference' $win10Checklist ($win10Checklist.Replace('| W10-01 ', '| W10-99 ')) ${function:Assert-Win10Inventory}
Write-Host "Windows 10 checklist: $($win10RowIds.Count) rows, $($win10GateFunctions.Count) gate functions ($($win10GateFunctions -join ', ')); $win10Mutations mutation controls"
