param(
    [switch]$Release
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path -LiteralPath (
    Join-Path $PSScriptRoot ".."
)).Path

$modRoot = Join-Path $repo "mod"
$descriptorPath = Join-Path $modRoot "descriptor.mod"
$launcherPath = Join-Path $repo "yb_map.mod"
$attributesPath = Join-Path $repo ".gitattributes"

function Get-ModProperty {
    param(
        [string]$Content,
        [string]$Name
    )

    $pattern = '(?m)^\s*' +
        [regex]::Escape($Name) +
        '\s*=\s*"([^"]+)"'

    $match = [regex]::Match($Content, $pattern)

    if (-not $match.Success) {
        throw "Missing mod property: $Name"
    }

    return $match.Groups[1].Value
}

function Get-NormalizedDescriptor {
    param(
        [string]$Content,
        [switch]$RemovePath
    )

    $lines = @(
        ($Content -replace "`r`n", "`n") -split "`n" |
            Where-Object {
                -not (
                    $RemovePath -and
                    $_ -match '^\s*path\s*='
                )
            }
    )

    return ($lines -join "`n").Trim()
}

function Get-ArchiveHash {
    param(
        [Parameter(Mandatory)]
        $Entry
    )

    $stream = $Entry.Open()
    $algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = $algorithm.ComputeHash($stream)
        return [Convert]::ToHexString($bytes)
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

Write-Host "`n=== BUILD PREFLIGHT ===" -ForegroundColor Cyan

foreach ($path in @(
    $modRoot,
    $descriptorPath,
    $launcherPath,
    $attributesPath
)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

if (
    (Get-Item -LiteralPath $launcherPath -Force).LinkType
) {
    throw "Repository launcher must be a standalone file."
}

$descriptor = Get-Content -LiteralPath $descriptorPath -Raw
$launcher = Get-Content -LiteralPath $launcherPath -Raw

$version = Get-ModProperty -Content $descriptor -Name "version"

if ($version -notmatch '^[a-zA-Z0-9._-]+$') {
    throw "Invalid version: $version"
}

foreach ($property in @(
    "version",
    "name",
    "supported_version",
    "remote_file_id"
)) {
    $sourceValue = Get-ModProperty `
        -Content $descriptor -Name $property

    $launcherValue = Get-ModProperty `
        -Content $launcher -Name $property

    if ($sourceValue -ne $launcherValue) {
        throw "Descriptor mismatch: $property"
    }
}

$installedPath = Get-ModProperty `
    -Content $launcher -Name "path"

if ($installedPath -ne "mod/yb_map") {
    throw "Unexpected launcher path: $installedPath"
}

$normalizedDescriptor = Get-NormalizedDescriptor `
    -Content $descriptor

$normalizedLauncher = Get-NormalizedDescriptor `
    -Content $launcher -RemovePath

if ($normalizedDescriptor -ne $normalizedLauncher) {
    throw "The mod descriptors have different contents."
}

Write-Host "Version     : $version"
Write-Host "Descriptors : MATCH"

Write-Host "`n=== PACKAGE MANIFEST ===" -ForegroundColor Cyan

$sourceFiles = @(
    Get-ChildItem -LiteralPath $modRoot -File -Recurse -Force
)

if ($sourceFiles.Count -eq 0) {
    throw "No mod files were found."
}

$packageFiles = @()
$excludedFiles = @()

foreach ($file in $sourceFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath(
        $modRoot,
        $file.FullName
    )

    $relativeUnix = $relativePath.Replace("\", "/")
    $gitPath = "mod/$relativeUnix"

    $attributes = @(
        & git -C $repo check-attr export-ignore -- $gitPath
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Git attribute lookup failed: $gitPath"
    }

    if ($attributes -match ':\s*export-ignore:\s*set\s*$') {
        $excludedFiles += $relativeUnix
        continue
    }

    if (
        ($file.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Symbolic links are not allowed in release assets: $gitPath"
    }

    # Do not package unresolved Git LFS pointers.
    if ($file.Length -le 512) {
        $smallContent = [System.Text.Encoding]::ASCII.GetString(
            [System.IO.File]::ReadAllBytes($file.FullName)
        )

        if (
            $smallContent.StartsWith(
                "version https://git-lfs.github.com/spec/v1"
            )
        ) {
            throw "Unresolved Git LFS pointer: $gitPath"
        }
    }

    $packageFiles += [pscustomobject]@{
        Source   = $file.FullName
        Relative = $relativeUnix
        Hash     = (
            Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        ).Hash
    }
}

if ($packageFiles.Count -eq 0) {
    throw "The release package would be empty."
}

Write-Host "Included : $($packageFiles.Count) files"
Write-Host "Excluded : $($excludedFiles.Count) files"

foreach ($excluded in $excludedFiles) {
    Write-Host "EXCLUDED $excluded"
}

$distPath = Join-Path $repo "dist"
$zipPath = Join-Path $distPath "yb_map-$version.zip"

Write-Host "`nOutput: $zipPath"

if (-not $Release) {
    Write-Host "`nPREVIEW PASS" -ForegroundColor Green
    Write-Host "No files were changed."
    Write-Host "Use -Release to create the package."
    return
}

if (Test-Path -LiteralPath $zipPath) {
    throw "Release ZIP already exists: $zipPath"
}

Write-Host "`n=== BUILD RELEASE ===" -ForegroundColor Cyan

$stageRoot = Join-Path $repo (
    "development\local\build-stage\" + [guid]::NewGuid().ToString("N")
)

$stageMod = Join-Path $stageRoot "yb_map"

New-Item -ItemType Directory -Path $stageMod -Force |
    Out-Null

New-Item -ItemType Directory -Path $distPath -Force |
    Out-Null

$tempZip = Join-Path $distPath (
    ".yb_map-" + [guid]::NewGuid().ToString("N") + ".tmp"
)

try {
    foreach ($file in $packageFiles) {
        $destination = Join-Path $stageMod (
            $file.Relative.Replace(
                "/",
                [System.IO.Path]::DirectorySeparatorChar
            )
        )

        $parent = Split-Path -Parent $destination

        New-Item -ItemType Directory -Path $parent -Force |
            Out-Null

        Copy-Item -LiteralPath $file.Source `
            -Destination $destination -Force

        $copiedHash = (
            Get-FileHash -LiteralPath $destination -Algorithm SHA256
        ).Hash

        if ($copiedHash -ne $file.Hash) {
            throw "Staging verification failed: $($file.Relative)"
        }
    }

    Copy-Item -LiteralPath $launcherPath `
        -Destination (Join-Path $stageRoot "yb_map.mod")

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $tempZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    Write-Host "`n=== VERIFY RELEASE ===" -ForegroundColor Cyan

    $archive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)

    try {
        $expected = @(
            "yb_map.mod"
            foreach ($file in $packageFiles) {
                "yb_map/$($file.Relative)"
            }
        )

        $actual = @(
            $archive.Entries |
                Where-Object { $_.Name.Length -gt 0 } |
                ForEach-Object { $_.FullName.Replace("\", "/") }
        )

        $difference = @(
            Compare-Object $expected $actual
        )

        if ($difference.Count -gt 0) {
            $difference | Format-Table -AutoSize
            throw "ZIP manifest verification failed."
        }

        foreach ($file in $packageFiles) {
            $entry = $archive.GetEntry(
                "yb_map/$($file.Relative)"
            )

            if ($null -eq $entry) {
                throw "Missing ZIP entry: $($file.Relative)"
            }

            $archiveHash = Get-ArchiveHash -Entry $entry

            if ($archiveHash -ne $file.Hash) {
                throw "ZIP hash mismatch: $($file.Relative)"
            }
        }

        $launcherEntry = $archive.GetEntry("yb_map.mod")

        if ($null -eq $launcherEntry) {
            throw "Launcher descriptor missing from ZIP."
        }

        $launcherHash = (
            Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256
        ).Hash

        if (
            (Get-ArchiveHash -Entry $launcherEntry) -ne
            $launcherHash
        ) {
            throw "Launcher ZIP hash mismatch."
        }
    }
    finally {
        $archive.Dispose()
    }

    Move-Item -LiteralPath $tempZip -Destination $zipPath

    Write-Host "`n=== RELEASE PASS ===" -ForegroundColor Green

    Get-Item -LiteralPath $zipPath |
        Select-Object FullName, Length |
        Format-List

    Write-Host "Verified assets: $($packageFiles.Count)"
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $tempZip) {
        Remove-Item -LiteralPath $tempZip -Force
    }
}
