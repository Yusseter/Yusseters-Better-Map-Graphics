[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Rollback
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$sourceMod = Join-Path $repo "mod"
$sourceLauncher = Join-Path $repo "yb_map.mod"
$sourceDescriptor = Join-Path $sourceMod "descriptor.mod"

$ck3 = Join-Path $env:USERPROFILE "Documents\Paradox Interactive\Crusader Kings III"
$mods = Join-Path $ck3 "mod"
$installedMod = Join-Path $mods "yb_map"
$installedLauncher = Join-Path $mods "yb_map.mod"
$backups = Join-Path $repo "development\local\deployments"

function Get-Sha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ArchiveHash {
    param($Entry)

    $stream = $Entry.Open()
    $algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [Convert]::ToHexString(
            $algorithm.ComputeHash($stream)
        )
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Get-ModVersion {
    param([string]$Content)

    $match = [regex]::Match(
        $Content,
        '(?m)^\s*version\s*=\s*"([^"]+)"'
    )

    if (-not $match.Success) {
        throw "Could not read mod version."
    }

    return $match.Groups[1].Value
}

function Test-SameLauncher {
    param(
        [string]$Installed,
        [string]$ReleaseContent,
        [string]$InstalledMod
    )

    $installedText = (
        ([IO.File]::ReadAllText($Installed) -replace '\r\n?', "`n") `
            -replace '\n+$', ''
    )

    $releaseText = (
        ($ReleaseContent -replace '\r\n?', "`n") `
            -replace '\n+$', ''
    )

    $installedPathMatch = [regex]::Match(
        $installedText,
        '(?m)^\s*path\s*=\s*"([^"]+)"\s*$'
    )

    $releasePathMatch = [regex]::Match(
        $releaseText,
        '(?m)^\s*path\s*=\s*"([^"]+)"\s*$'
    )

    if (
        -not $installedPathMatch.Success -or
        -not $releasePathMatch.Success
    ) {
        return $false
    }

    $installedPath = (
        ($installedPathMatch.Groups[1].Value -replace '\\', '/') `
            -replace '/+$', ''
    )

    $releasePath = (
        ($releasePathMatch.Groups[1].Value -replace '\\', '/') `
            -replace '/+$', ''
    )

    $expectedAbsolute = (
        ($InstalledMod -replace '\\', '/') `
            -replace '/+$', ''
    )

    if ($releasePath -ine "mod/yb_map") {
        return $false
    }

    if (
        $installedPath -ine "mod/yb_map" -and
        $installedPath -ine $expectedAbsolute
    ) {
        return $false
    }

    $pathPattern = '(?m)^\s*path\s*=\s*"[^"]+"\s*(?:\n|$)'

    $installedBody = (
        [regex]::Replace(
            $installedText,
            $pathPattern,
            ''
        )
    ).Trim()

    $releaseBody = (
        [regex]::Replace(
            $releaseText,
            $pathPattern,
            ''
        )
    ).Trim()

    return ($installedBody -ceq $releaseBody)
}
function Test-SameDescriptor {
    param(
        [string]$Installed,
        [string]$Source
    )

    $installedText = (
        [IO.File]::ReadAllText($Installed) -replace '\r\n?', "`n"
    ).TrimEnd("`r", "`n")

    $sourceText = (
        [IO.File]::ReadAllText($Source) -replace '\r\n?', "`n"
    ).TrimEnd("`r", "`n")

    return ($installedText -ceq $sourceText)
}

function New-DeploymentId {
    param([string]$Root)

    New-Item -ItemType Directory -Path $Root -Force |
        Out-Null

    $base = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $candidate = $base
    $counter = 2

    while (Test-Path -LiteralPath (Join-Path $Root $candidate)) {
        $candidate = "$base-$('{0:D2}' -f $counter)"
        $counter++
    }

    return $candidate
}

# Restore a previous installation snapshot.
if (-not [string]::IsNullOrWhiteSpace($Rollback)) {
    if ($Rollback -notmatch '^(?:\d{8}-\d{6}-[a-f0-9]{8}|\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:-\d{2})?)$') {
        throw "Invalid backup ID."
    }

    $snapshot = Join-Path $backups $Rollback
    $manifestPath = Join-Path $snapshot "manifest.json"
    $previousMod = Join-Path $snapshot "previous-mod"
    $previousLauncher = Join-Path $snapshot "previous-launcher.mod"
    $replacedMod = Join-Path $snapshot "rollback-replaced-mod"
    $replacedLauncher = Join-Path $snapshot "rollback-replaced-launcher.mod"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Backup manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json

    if (-not $manifest.Completed -or $manifest.RolledBack) {
        throw "Backup is not eligible for rollback."
    }

    # Only the latest active deployment may be rolled back.
    foreach ($newer in @(
        Get-ChildItem -LiteralPath $backups -Directory |
            Where-Object { $_.Name -gt $Rollback }
    )) {
        $newerManifest = Join-Path $newer.FullName "manifest.json"

        if (Test-Path -LiteralPath $newerManifest -PathType Leaf) {
            $newerState = Get-Content -LiteralPath $newerManifest -Raw |
                ConvertFrom-Json

            if ($newerState.Completed -and -not $newerState.RolledBack) {
                throw "Rollback newer deployments first: $($newer.Name)"
            }
        }
    }

    if ($manifest.Mode -eq "DELTA") {
        Write-Host "`n=== DELTA ROLLBACK PREFLIGHT ===" -ForegroundColor Cyan

        if (-not (Test-Path -LiteralPath $installedMod -PathType Container)) {
            throw "Installed mod directory is missing."
        }

        foreach ($file in @($manifest.Files)) {
            $target = Join-Path $installedMod $file.Relative

            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                throw "Installed file missing: $($file.Relative)"
            }

            if ((Get-Sha256 $target) -ne $file.DeployedHash) {
                throw "Installed file was modified: $($file.Relative)"
            }

            if ($file.State -eq "CHANGE") {
                $backupFile = Join-Path $snapshot (
                    "files\" + $file.Relative
                )

                if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
                    throw "Backup missing: $($file.Relative)"
                }

                if ((Get-Sha256 $backupFile) -ne $file.PreviousHash) {
                    throw "Backup hash mismatch: $($file.Relative)"
                }
            }
        }

        if ((Get-Sha256 $installedLauncher) -ne $manifest.LauncherHash) {
            throw "Installed launcher was modified."
        }

        $launcherBackup = Join-Path $snapshot "previous-launcher.mod"

        if ($manifest.LauncherChanged) {
            if (-not (Test-Path -LiteralPath $launcherBackup -PathType Leaf)) {
                throw "Launcher backup is missing."
            }

            if ((Get-Sha256 $launcherBackup) -ne $manifest.PreviousLauncherHash) {
                throw "Launcher backup hash mismatch."
            }
        }

        if ($WhatIfPreference) {
            Write-Host "`nROLLBACK PREVIEW ONLY" -ForegroundColor Yellow
            Write-Host "No files were changed."
            return
        }

        Write-Host "`n=== DELTA ROLLBACK ===" -ForegroundColor Cyan

        foreach ($file in @($manifest.Files)) {
            $target = Join-Path $installedMod $file.Relative

            if ($file.State -eq "CREATE") {
                Remove-Item -LiteralPath $target -Force
                Write-Host "REMOVED  $($file.Relative)"
            }
            else {
                $backupFile = Join-Path $snapshot (
                    "files\" + $file.Relative
                )

                Copy-Item -LiteralPath $backupFile `
                    -Destination $target -Force

                if ((Get-Sha256 $target) -ne $file.PreviousHash) {
                    throw "Restore verification failed: $($file.Relative)"
                }

                Write-Host "RESTORED $($file.Relative)"
            }
        }

        if ($manifest.LauncherChanged) {
            Copy-Item -LiteralPath $launcherBackup `
                -Destination $installedLauncher -Force
        }

        $manifest.RolledBack = $true

        $manifest |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8

        Write-Host "`nROLLBACK PASS" -ForegroundColor Green
        return
    }

    if ($manifest.PreviousMod -and
        -not (Test-Path -LiteralPath $previousMod -PathType Container)) {
        throw "Previous mod directory is missing."
    }

    if ($manifest.PreviousLauncher -and
        -not (Test-Path -LiteralPath $previousLauncher -PathType Leaf)) {
        throw "Previous launcher is missing."
    }

    if (-not (Test-Path -LiteralPath $installedMod -PathType Container)) {
        throw "Current mod installation is missing."
    }

    if (-not (Test-Path -LiteralPath $installedLauncher -PathType Leaf)) {
        throw "Current launcher is missing."
    }

    foreach ($file in $manifest.Files) {
        $path = Join-Path $installedMod $file.Relative

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Rollback blocked: missing file $($file.Relative)"
        }

        if ((Get-Sha256 $path) -ne $file.Hash) {
            throw "Rollback blocked: modified file $($file.Relative)"
        }
    }

    if ((Get-Sha256 $installedLauncher) -ne $manifest.LauncherHash) {
        throw "Rollback blocked: launcher has changed."
    }

    if ((Test-Path -LiteralPath $replacedMod) -or
        (Test-Path -LiteralPath $replacedLauncher)) {
        throw "Rollback storage already exists."
    }

    if ($WhatIfPreference) {
        Write-Host "`nROLLBACK PREVIEW ONLY" -ForegroundColor Yellow
        Write-Host "No files were changed."
        return
    }

    Write-Host "`n=== ROLLBACK ===" -ForegroundColor Cyan

    Move-Item -LiteralPath $installedMod -Destination $replacedMod

    if ($manifest.PreviousMod) {
        Move-Item -LiteralPath $previousMod -Destination $installedMod
    }

    Move-Item -LiteralPath $installedLauncher -Destination $replacedLauncher

    if ($manifest.PreviousLauncher) {
        Copy-Item -LiteralPath $previousLauncher `
            -Destination $installedLauncher
    }

    $manifest.RolledBack = $true

    $manifest |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding utf8

    Write-Host "ROLLBACK PASS" -ForegroundColor Green
    Write-Host "Replaced installation preserved in: $snapshot"
    return
}

Write-Host "`n=== DEPLOY PREFLIGHT ===" -ForegroundColor Cyan

foreach ($path in @(
    $sourceMod,
    $sourceDescriptor,
    $sourceLauncher,
    $mods
)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

$descriptor = Get-Content -LiteralPath $sourceDescriptor -Raw
$version = Get-ModVersion $descriptor
$zipPath = Join-Path $repo "dist\yb_map-$version.zip"

if ($version -notmatch '^[a-zA-Z0-9._-]+$') {
    throw "Invalid mod version: $version"
}

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Release ZIP not found: $zipPath"
}

# Check whether the installed directory is still the old repository.
$installedExists = Test-Path -LiteralPath $installedMod -PathType Container
$legacyRepo = $installedExists -and (
    Test-Path -LiteralPath (Join-Path $installedMod ".git")
)

if ($legacyRepo) {
    if (-not (Test-Path -LiteralPath (
        Join-Path $installedMod "yb_map\descriptor.mod"
    ))) {
        throw "Unknown Git repository at installation path. Deployment blocked."
    }
}
elseif ($installedExists) {
    if (-not (Test-Path -LiteralPath (
        Join-Path $installedMod "descriptor.mod"
    ))) {
        throw "Unknown existing mod directory. Deployment blocked."
    }
}

if ((Test-Path -LiteralPath $installedLauncher) -and
    (Get-Item -LiteralPath $installedLauncher -Force).LinkType) {
    throw "Installed launcher is a symbolic link. Deployment blocked."
}

# Enumerate the actual release sources, respecting Git export-ignore.
$sources = @(
    foreach ($file in Get-ChildItem -LiteralPath $sourceMod -File -Recurse -Force) {
        $relative = [System.IO.Path]::GetRelativePath(
            $sourceMod,
            $file.FullName
        ).Replace("\", "/")

        $attribute = & git -C $repo check-attr export-ignore -- "mod/$relative"

        if ($LASTEXITCODE -ne 0) {
            throw "Git attribute lookup failed: $relative"
        }

        if ($attribute -match ':\s*export-ignore:\s*set\s*$') {
            continue
        }

        if (($file.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Symbolic link in release sources: $relative"
        }

        [pscustomobject]@{
            Relative = $relative
            Path     = $file.FullName
            Hash     = Get-Sha256 $file.FullName
        }
    }
)

$launcherHash = $null

# Validate that the ZIP is an exact copy of the release sources.
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)

try {
    $expected = @("yb_map.mod") + @(
        $sources | ForEach-Object { "yb_map/$($_.Relative)" }
    )

    $actual = @(
        $archive.Entries |
            Where-Object { $_.Name.Length -gt 0 } |
            ForEach-Object { $_.FullName.Replace("\", "/") }
    )

    if ($expected.Count -ne $actual.Count -or
        @(Compare-Object $expected $actual).Count -gt 0) {
        throw "Release ZIP manifest differs from current sources."
    }

    foreach ($file in $sources) {
        $entry = $archive.GetEntry("yb_map/$($file.Relative)")

        if ($null -eq $entry) {
            throw "Missing release file: $($file.Relative)"
        }

        $archiveHash = Get-ArchiveHash $entry

        if (
            $file.Relative -eq
            "gfx/map/terrain/flat_maps/flatmap_yb.dds"
        ) {
            if ($entry.Length -ne 21233792) {
                throw "Unexpected release DDS size."
            }

            $header = [byte[]]::new(128)
            $stream = $entry.Open()

            try {
                $read = 0

                while ($read -lt $header.Length) {
                    $n = $stream.Read(
                        $header,
                        $read,
                        $header.Length - $read
                    )

                    if ($n -eq 0) {
                        break
                    }

                    $read += $n
                }
            }
            finally {
                $stream.Dispose()
            }

            if (
                $read -ne 128 -or
                [Text.Encoding]::ASCII.GetString($header, 0, 4) -ne "DDS " -or
                [Text.Encoding]::ASCII.GetString($header, 84, 4) -ne "DXT1" -or
                [BitConverter]::ToUInt32($header, 12) -ne 4608 -or
                [BitConverter]::ToUInt32($header, 16) -ne 9216 -or
                [BitConverter]::ToUInt32($header, 28) -gt 1
            ) {
                throw "Unexpected release DDS format."
            }

            # Deployment must use the packaged DXT1 file hash.
            $file.Hash = $archiveHash
        }
        elseif ($archiveHash -ne $file.Hash) {
            throw "Release ZIP is outdated or corrupt: $($file.Relative)"
        }
    }

    $launcherEntry = $archive.GetEntry("yb_map.mod")

    if ($null -eq $launcherEntry) {
        throw "Release ZIP launcher is missing."
    }

    $reader = [IO.StreamReader]::new(
        $launcherEntry.Open(),
        [Text.Encoding]::UTF8,
        $true
    )

    try {
        $zipLauncher = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    $repoLauncher = [IO.File]::ReadAllText($sourceLauncher)

    $normalizedZip = (
        ($zipLauncher -replace '\r\n?', "`n") -replace '\n+$', ''
    )

    $normalizedRepo = (
        ($repoLauncher -replace '\r\n?', "`n") -replace '\n+$', ''
    )

    if ($normalizedZip -cne $normalizedRepo) {
        throw "Release ZIP launcher differs from source beyond line endings."
    }

    $launcherHash = Get-ArchiveHash $launcherEntry
}
finally {
    $archive.Dispose()
}

Write-Host "Version         : $version"
Write-Host "Release files   : $($sources.Count)"
Write-Host "ZIP verification: PASS"

# Calculate what will change.
$changes = @(
    foreach ($file in $sources) {
        $target = Join-Path $installedMod $file.Relative

        $state = if ($legacyRepo -or
            -not (Test-Path -LiteralPath $target -PathType Leaf)) {
            "CREATE"
        }
        elseif ((Get-Sha256 $target) -eq $file.Hash) {
            "SAME"
        }
        elseif (
            $file.Relative -eq "descriptor.mod" -and
            (Test-SameDescriptor -Installed $target -Source $file.Path)
        ) {
            "SAME"
        }
        else {
            "CHANGE"
        }

        [pscustomobject]@{
            State    = $state
            Relative = $file.Relative
        }
    }
)

$launcherState = if (-not (
    Test-Path -LiteralPath $installedLauncher -PathType Leaf
)) {
    "CREATE"
}
elseif ((Get-Sha256 $installedLauncher) -eq $launcherHash) {
    "SAME"
}
elseif (
    Test-SameLauncher `
        -Installed $installedLauncher `
        -ReleaseContent $zipLauncher `
        -InstalledMod $installedMod
) {
    "SAME"
}
else {
    "CHANGE"
}

if ($launcherState -eq "SAME") {
    $launcherHash = Get-Sha256 $installedLauncher
}

Write-Host "`n=== DEPLOYMENT PLAN ===" -ForegroundColor Cyan
Write-Host "Source : $repo"
Write-Host "Target : $installedMod"
Write-Host "Launcher: $launcherState"

$changes |
    Group-Object State |
    Select-Object Name, Count |
    Format-Table -AutoSize

if ($legacyRepo) {
    Write-Host "LEGACY REPOSITORY DETECTED" -ForegroundColor Yellow
    Write-Host "The old repository will be preserved in a backup."
}

if ($WhatIfPreference) {
    Write-Host "`nPREVIEW ONLY" -ForegroundColor Yellow
    Write-Host "No files were changed."
    Write-Host "Run without -WhatIf to deploy."
    return
}

$changedFiles = @($changes | Where-Object { $_.State -ne "SAME" })

if ($changedFiles.Count -eq 0 -and
    $launcherState -eq "SAME" -and
    -not $legacyRepo) {
    Write-Host "`nDEPLOY PASS: Already up to date." -ForegroundColor Green
    return
}

# Subsequent installations use verified, file-level updates.
# The first installation retains the existing full-directory backup path.
if ($installedExists -and -not $legacyRepo) {
    Write-Host "`n=== DELTA DEPLOY ===" -ForegroundColor Cyan

    if (Get-Process -Name "ck3" -ErrorAction SilentlyContinue) {
        throw "Close Crusader Kings III before deployment."
    }

    $id = New-DeploymentId -Root $backups

    $snapshot = Join-Path $backups $id
    $backupFiles = Join-Path $snapshot "files"
    $stage = Join-Path $snapshot "stage"
    $manifestPath = Join-Path $snapshot "manifest.json"

    New-Item -ItemType Directory -Path $backupFiles -Force |
        Out-Null

    $manifestFiles = @()

    Write-Host "`n=== BACKUP PREFLIGHT ===" -ForegroundColor Cyan

    foreach ($change in $changedFiles) {
        $source = @(
            $sources | Where-Object {
                $_.Relative -eq $change.Relative
            }
        )[0]

        $target = Join-Path $installedMod $source.Relative
        $previousHash = $null

        if ($change.State -eq "CHANGE") {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                throw "Target disappeared: $($source.Relative)"
            }

            $previousHash = Get-Sha256 $target

            $backup = Join-Path $backupFiles $source.Relative
            $parent = Split-Path -Parent $backup

            New-Item -ItemType Directory -Path $parent -Force |
                Out-Null

            Copy-Item -LiteralPath $target -Destination $backup

            if ((Get-Sha256 $backup) -ne $previousHash) {
                throw "Backup verification failed: $($source.Relative)"
            }
        }
        elseif (Test-Path -LiteralPath $target) {
            throw "Unexpected target exists: $($source.Relative)"
        }

        $manifestFiles += [pscustomobject]@{
            Relative     = $source.Relative
            State        = $change.State
            PreviousHash = $previousHash
            DeployedHash = $source.Hash
        }
    }

    $launcherChanged = $launcherState -eq "CHANGE"
    $previousLauncherHash = $null
    $launcherBackup = Join-Path $snapshot "previous-launcher.mod"

    if ($launcherChanged) {
        $previousLauncherHash = Get-Sha256 $installedLauncher

        Copy-Item -LiteralPath $installedLauncher `
            -Destination $launcherBackup

        if ((Get-Sha256 $launcherBackup) -ne $previousLauncherHash) {
            throw "Launcher backup verification failed."
        }
    }

    $manifest = [pscustomobject]@{
        Mode                 = "DELTA"
        BackupId             = $id
        Version              = $version
        CreatedAt            = (Get-Date).ToString("o")
        Completed            = $false
        RolledBack           = $false
        LauncherChanged      = $launcherChanged
        PreviousLauncherHash = $previousLauncherHash
        LauncherHash         = $launcherHash
        Files                = $manifestFiles
    }

    $manifest |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding utf8

    Write-Host "`n=== EXTRACT RELEASE ===" -ForegroundColor Cyan

    [System.IO.Compression.ZipFile]::ExtractToDirectory(
        $zipPath,
        $stage
    )

    $applied = @()
    $launcherApplied = $false

    try {
        Write-Host "`n=== APPLY CHANGES ===" -ForegroundColor Cyan

        foreach ($file in $manifestFiles) {
            $source = Join-Path $stage (
                "yb_map\" + $file.Relative
            )

            $target = Join-Path $installedMod $file.Relative
            $parent = Split-Path -Parent $target

            if ((Get-Sha256 $source) -ne $file.DeployedHash) {
                throw "Staged file hash mismatch: $($file.Relative)"
            }

            if ($file.State -eq "CHANGE") {
                if ((Get-Sha256 $target) -ne $file.PreviousHash) {
                    throw "Target changed after preflight: $($file.Relative)"
                }
            }
            elseif (Test-Path -LiteralPath $target) {
                throw "Unexpected target appeared: $($file.Relative)"
            }

            New-Item -ItemType Directory -Path $parent -Force |
                Out-Null

            $applied += $file

            Copy-Item -LiteralPath $source `
                -Destination $target -Force

            if ((Get-Sha256 $target) -ne $file.DeployedHash) {
                throw "Deployment hash mismatch: $($file.Relative)"
            }

            Write-Host "$($file.State) $($file.Relative)"
        }

        if ($launcherState -ne "SAME") {
            $launcherApplied = $true

            Copy-Item -LiteralPath (Join-Path $stage "yb_map.mod") `
                -Destination $installedLauncher -Force
        }

        if ((Get-Sha256 $installedLauncher) -ne $launcherHash) {
            throw "Installed launcher hash mismatch."
        }

        $manifest.Completed = $true

        $manifest |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8

        Write-Host "`n=== DEPLOY PASS ===" -ForegroundColor Green
        Write-Host "Changed files : $($manifestFiles.Count)"
        Write-Host "Backup ID     : $id"
        Write-Host "Backup        : $snapshot"
    }
    catch {
        $failure = $_
        $recoveryErrors = @()

        Write-Host "`nDeployment failed. Restoring changed files..." `
            -ForegroundColor Red

        for ($i = $applied.Count - 1; $i -ge 0; $i--) {
            $file = $applied[$i]
            $target = Join-Path $installedMod $file.Relative

            try {
                if ($file.State -eq "CREATE") {
                    if (Test-Path -LiteralPath $target) {
                        Remove-Item -LiteralPath $target -Force
                    }
                }
                else {
                    $backup = Join-Path $backupFiles $file.Relative

                    Copy-Item -LiteralPath $backup `
                        -Destination $target -Force

                    if ((Get-Sha256 $target) -ne $file.PreviousHash) {
                        throw "Restored hash does not match backup."
                    }
                }
            }
            catch {
                $recoveryErrors += "$($file.Relative): $_"
            }
        }

        if ($launcherApplied) {
            try {
                if ($launcherChanged) {
                    Copy-Item -LiteralPath $launcherBackup `
                        -Destination $installedLauncher -Force
                }
                elseif (Test-Path -LiteralPath $installedLauncher) {
                    Remove-Item -LiteralPath $installedLauncher -Force
                }
            }
            catch {
                $recoveryErrors += "Launcher: $_"
            }
        }

        if ($recoveryErrors.Count -gt 0) {
            $recoveryErrors | ForEach-Object { Write-Warning $_ }
            throw "Deployment failed and automatic recovery was incomplete: $failure"
        }

        throw $failure
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }

    return
}
$id = New-DeploymentId -Root $backups

$snapshot = Join-Path $backups $id
$previousMod = Join-Path $snapshot "previous-mod"
$previousLauncher = Join-Path $snapshot "previous-launcher.mod"
$extracted = Join-Path $snapshot "extracted"
$stageMod = Join-Path $snapshot "stage-mod"
$manifestPath = Join-Path $snapshot "manifest.json"

$launcherExisted = Test-Path -LiteralPath $installedLauncher -PathType Leaf

New-Item -ItemType Directory -Path $snapshot -Force | Out-Null

Write-Host "`n=== STAGING ===" -ForegroundColor Cyan

[System.IO.Compression.ZipFile]::ExtractToDirectory(
    $zipPath,
    $extracted
)

New-Item -ItemType Directory -Path $stageMod -Force | Out-Null

# Preserve non-managed files in a normal existing installation.
if ($installedExists -and -not $legacyRepo) {
    & robocopy `
        $installedMod `
        $stageMod `
        /E /COPY:DAT /DCOPY:DAT /SL /XJ /R:1 /W:1 /NFL /NDL /NP |
        Out-Null

    if ($LASTEXITCODE -ge 8) {
        throw "Staging copy failed. Existing installation is untouched."
    }
}

foreach ($file in $sources) {
    $from = Join-Path $extracted ("yb_map/" + $file.Relative)
    $to = Join-Path $stageMod $file.Relative

    $parent = Split-Path -Parent $to

    New-Item -ItemType Directory -Path $parent -Force |
        Out-Null

    Copy-Item -LiteralPath $from -Destination $to -Force

    if ((Get-Sha256 $to) -ne $file.Hash) {
        throw "Staging verification failed: $($file.Relative)"
    }
}

if ($launcherExisted) {
    Copy-Item -LiteralPath $installedLauncher `
        -Destination $previousLauncher

    if ((Get-Sha256 $previousLauncher) -ne
        (Get-Sha256 $installedLauncher)) {
        throw "Launcher backup verification failed."
    }
}

$manifest = [pscustomobject]@{
    BackupId         = $id
    Version          = $version
    CreatedAt        = (Get-Date).ToString("o")
    PreviousMod      = $installedExists
    PreviousLauncher = $launcherExisted
    LegacyRepository = $legacyRepo
    Completed        = $false
    RolledBack       = $false
    LauncherHash     = $launcherHash
    Files            = @(
        $sources | ForEach-Object {
            [pscustomobject]@{
                Relative = $_.Relative
                Hash     = $_.Hash
            }
        }
    )
}

$manifest |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "`n=== DEPLOY ===" -ForegroundColor Cyan

$oldMoved = $false
$newMoved = $false

try {
    if ($installedExists) {
        Move-Item -LiteralPath $installedMod -Destination $previousMod
        $oldMoved = $true
    }

    Move-Item -LiteralPath $stageMod -Destination $installedMod
    $newMoved = $true

    Copy-Item -LiteralPath (Join-Path $extracted "yb_map.mod") `
        -Destination $installedLauncher -Force

    foreach ($file in $sources) {
        $target = Join-Path $installedMod $file.Relative

        if ((Get-Sha256 $target) -ne $file.Hash) {
            throw "Installed file verification failed: $($file.Relative)"
        }
    }

    if ((Get-Sha256 $installedLauncher) -ne $launcherHash) {
        throw "Installed launcher verification failed."
    }

    $manifest.Completed = $true

    $manifest |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding utf8

    Write-Host "`n=== DEPLOY PASS ===" -ForegroundColor Green
    Write-Host "Installed : $installedMod"
    Write-Host "Backup ID : $id"
    Write-Host "Backup    : $snapshot"
}
catch {
    $deploymentError = $_

    Write-Host "Deployment failed. Restoring previous installation..." -ForegroundColor Red

    if ($newMoved -and (Test-Path -LiteralPath $installedMod)) {
        Move-Item -LiteralPath $installedMod `
            -Destination (Join-Path $snapshot "failed-deployment")
    }

    if ($oldMoved -and (Test-Path -LiteralPath $previousMod)) {
        Move-Item -LiteralPath $previousMod -Destination $installedMod
    }

    if ($launcherExisted) {
        Copy-Item -LiteralPath $previousLauncher `
            -Destination $installedLauncher -Force
    }
    elseif (Test-Path -LiteralPath $installedLauncher) {
        Remove-Item -LiteralPath $installedLauncher -Force
    }

    throw $deploymentError
}
