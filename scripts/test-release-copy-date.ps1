$ErrorActionPreference = "Stop"

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempRoot "winghostty-release-copy-date-$PID-$([Guid]::NewGuid().ToString('N'))"

try {
    [System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $helperPath = Join-Path $fixtureRoot "release-copy-date.ps1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "release-copy-date.ps1") -Destination $helperPath
    . $helperPath

    $cases = @(
        @{
            Name = "UTC DateTime"
            Value = [DateTime]::SpecifyKind([DateTime]::Parse("2026-08-06T22:01:54"), [DateTimeKind]::Utc)
            Expected = "2026-08-06"
        },
        @{
            Name = "ISO-8601 UTC string"
            Value = "2026-08-06T22:01:54Z"
            Expected = "2026-08-06"
        },
        @{
            Name = "ISO-8601 offset crosses UTC date"
            Value = "2026-08-07T01:30:00+03:00"
            Expected = "2026-08-06"
        },
        @{
            Name = "DateTimeOffset crosses UTC date"
            Value = [DateTimeOffset]::new(2026, 8, 7, 1, 30, 0, [TimeSpan]::FromHours(3))
            Expected = "2026-08-06"
        },
        @{
            Name = "Unspecified DateTime is GitHub UTC"
            Value = [DateTime]::SpecifyKind([DateTime]::Parse("2026-08-06T23:30:00"), [DateTimeKind]::Unspecified)
            Expected = "2026-08-06"
        }
    )

    foreach ($case in $cases) {
        $actual = ConvertTo-UtcReleaseDate -PublishedAt $case.Value
        if ($actual -ne $case.Expected) {
            throw "$($case.Name): expected $($case.Expected), got $actual."
        }
        Write-Host "PASS: $($case.Name) -> $actual"
    }

    Write-Host "Release copy UTC date tests passed ($($cases.Count) cases)." -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixtureRoot = [System.IO.Path]::GetFullPath($fixtureRoot)
        if (-not $resolvedFixtureRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove release-copy test directory outside the temp root: $resolvedFixtureRoot"
        }
        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
    }
}
