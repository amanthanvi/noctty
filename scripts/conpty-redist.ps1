function Assert-ConPtySha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        throw "$Label SHA256 mismatch. Expected $Expected, got $actual."
    }
}

function Expand-ConPtyEntry {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$EntryPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $entry = $Archive.GetEntry($EntryPath)
    if (-not $entry) {
        throw "Pinned ConPTY package entry is missing: $EntryPath"
    }

    $entryStream = $entry.Open()
    try {
        $output = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $entryStream.CopyTo($output)
        }
        finally {
            $output.Dispose()
        }
    }
    finally {
        $entryStream.Dispose()
    }
}

function Install-ConPtyRedist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PinPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("x64", "arm64")]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$CacheRoot,

        [switch]$RequireConPty
    )

    $pin = Get-Content -LiteralPath $PinPath -Raw | ConvertFrom-Json
    if ($pin.schemaVersion -ne 1 -or
        $pin.packageId -ne "Microsoft.Windows.Console.ConPTY" -or
        $pin.license -ne "MIT") {
        throw "Unsupported ConPTY redistributable pin: $PinPath"
    }

    $architecturePin = $pin.architectures.PSObject.Properties[$Architecture].Value
    if (-not $architecturePin) {
        throw "ConPTY pin has no $Architecture payload."
    }

    $cacheDirectory = Join-Path $CacheRoot $pin.version
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    $packageName = [System.IO.Path]::GetFileName(([System.Uri]$pin.nupkg.url).AbsolutePath)
    $packagePath = Join-Path $cacheDirectory $packageName

    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        try {
            Assert-ConPtySha256 -Path $packagePath -Expected $pin.nupkg.sha256 -Label "Cached ConPTY package"
        }
        catch {
            Remove-Item -LiteralPath $packagePath -Force
        }
    }

    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        $downloadPath = Join-Path $cacheDirectory "$packageName.download-$([Guid]::NewGuid().ToString('N'))"
        try {
            try {
                Invoke-WebRequest -Uri $pin.nupkg.url -OutFile $downloadPath -ErrorAction Stop
            }
            catch {
                $message = "Bundled ConPTY download failed; this package will fall back to the in-box conhost, where Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped. $($_.Exception.Message)"
                if ($RequireConPty) {
                    throw $message
                }
                Write-Warning $message
                return $false
            }

            Assert-ConPtySha256 -Path $downloadPath -Expected $pin.nupkg.sha256 -Label "Downloaded ConPTY package"
            Move-Item -LiteralPath $downloadPath -Destination $packagePath
        }
        finally {
            if (Test-Path -LiteralPath $downloadPath) {
                Remove-Item -LiteralPath $downloadPath -Force
            }
        }
    }

    Assert-ConPtySha256 -Path $packagePath -Expected $pin.nupkg.sha256 -Label "Cached ConPTY package"

    $destinationRoot = [System.IO.Path]::GetFullPath($Destination)
    $temporaryRoot = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot ".conpty-stage-$([Guid]::NewGuid().ToString('N'))"))
    if (-not $temporaryRoot.StartsWith($destinationRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use ConPTY staging path outside the portable root: $temporaryRoot"
    }

    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    try {
        $temporaryConPty = Join-Path $temporaryRoot "conpty.dll"
        $temporaryOpenConsole = Join-Path $temporaryRoot "OpenConsole.exe"
        $archive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
        try {
            Expand-ConPtyEntry -Archive $archive -EntryPath $architecturePin.conptyDll.entryPath -Destination $temporaryConPty
            Expand-ConPtyEntry -Archive $archive -EntryPath $architecturePin.openConsoleExe.entryPath -Destination $temporaryOpenConsole
        }
        finally {
            $archive.Dispose()
        }

        Assert-ConPtySha256 -Path $temporaryConPty -Expected $architecturePin.conptyDll.sha256 -Label "conpty.dll"
        Assert-ConPtySha256 -Path $temporaryOpenConsole -Expected $architecturePin.openConsoleExe.sha256 -Label "OpenConsole.exe"
        Assert-PeMachine -PathToCheck $temporaryConPty -ExpectedArchitecture $Architecture
        Assert-PeMachine -PathToCheck $temporaryOpenConsole -ExpectedArchitecture $Architecture

        $stagedConPty = Join-Path $destinationRoot "conpty.dll"
        $stagedOpenConsole = Join-Path $destinationRoot "OpenConsole.exe"
        try {
            Copy-Item -LiteralPath $temporaryConPty -Destination $stagedConPty
            Copy-Item -LiteralPath $temporaryOpenConsole -Destination $stagedOpenConsole
        }
        catch {
            Remove-Item -LiteralPath $stagedConPty -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stagedOpenConsole -Force -ErrorAction SilentlyContinue
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }

    return $true
}
