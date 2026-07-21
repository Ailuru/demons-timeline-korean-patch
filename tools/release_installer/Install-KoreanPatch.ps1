[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Restore', 'Status')]
    [string]$Action,

    [string]$GameRoot,
    [string]$PatchAsset,
    [string]$BaselinePath,
    [string]$ReleaseManifestPath,
    [string]$BackupRoot,
    [switch]$Json,

    # Used only by disposable-tree regression tests to exercise rollback.
    [Parameter(DontShow)]
    [switch]$TestFailureAfterReplace,

    [Parameter(DontShow)]
    [ValidateRange(0, 100)]
    [int]$TestFailureAfterReplaceCount = 0
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-ExistingPath([string]$Path, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw "$Description does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-SafeRelativePath([string]$Root, [string]$Relative, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw "$Description must be a non-empty relative path."
    }
    $normalized = $Relative.Replace('\', '/')
    if ($normalized.Split('/') -contains '..') {
        throw "$Description may not contain parent traversal."
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $normalized.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $candidate.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description resolves outside its root."
    }
    return $candidate
}

function Write-JsonAtomic([object]$Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = Join-Path $parent ('.state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $old = Join-Path $parent ('.state-' + [Guid]::NewGuid().ToString('N') + '.old')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temp, $Path, $old, $true)
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    }
}

function Test-File([string]$Path, [long]$Length, [string]$Hash) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ([long](Get-Item -LiteralPath $Path).Length -ne $Length) { return $false }
    return (Get-Sha256 $Path) -eq $Hash.ToLowerInvariant()
}

function Copy-Verified([string]$Source, [string]$Destination, [long]$Length, [string]$Hash) {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    if (-not (Test-File $Destination $Length $Hash)) {
        throw "Copied file verification failed: $Destination"
    }
}

function Get-ManifestEntries([object]$Manifest, [string]$RepoRoot, [string]$PatchOverride) {
    $entries = @()
    if ([int]$Manifest.schema_version -eq 1) {
        $items = @([PSCustomObject]@{
            target_relative_path = [string]$Manifest.target_relative_path
            artifact = $Manifest.artifact
        })
    }
    elseif ([int]$Manifest.schema_version -eq 2) {
        $items = @($Manifest.artifacts)
        if (-not [string]::IsNullOrWhiteSpace($PatchOverride)) {
            throw 'PatchAsset override is supported only for a single-artifact schema-v1 manifest.'
        }
    }
    else {
        throw 'Unsupported release-candidate manifest schema.'
    }
    if ($items.Count -eq 0) { throw 'Release-candidate manifest has no artifacts.' }

    $seenTargets = @{}
    foreach ($item in $items) {
        $relative = ([string]$item.target_relative_path).Replace('\', '/')
        if ($seenTargets.ContainsKey($relative)) { throw 'Duplicate release target path.' }
        $seenTargets[$relative] = $true
        $artifact = $item.artifact
        $length = [long]$artifact.length
        $hash = ([string]$artifact.sha256).ToLowerInvariant()
        if ($length -le 0 -or $hash -notmatch '^[0-9a-f]{64}$') {
            throw 'Release-candidate artifact metadata is invalid.'
        }
        $artifactPath = if (-not [string]::IsNullOrWhiteSpace($PatchOverride)) {
            Resolve-ExistingPath $PatchOverride 'Patch asset'
        }
        else {
            Resolve-SafeRelativePath $RepoRoot ([string]$artifact.relative_path) 'Artifact path'
        }
        $entries += [PSCustomObject]@{
            target_relative_path = $relative
            artifact_path = $artifactPath
            patch_length = $length
            patch_sha256 = $hash
        }
    }
    return @($entries)
}

function Get-StateEntries([object]$State) {
    if ($null -eq $State) { return @() }
    if ($null -ne $State.files) { return @($State.files) }
    if ($null -ne $State.target_relative_path) {
        return @([PSCustomObject]@{
            target_relative_path = [string]$State.target_relative_path
            installed_patch_length = [long]$State.installed_patch_length
            installed_patch_sha256 = [string]$State.installed_patch_sha256
            original_sha256 = [string]$State.original_sha256
        })
    }
    return @()
}

function Get-BackupFileName([string]$Relative) {
    $leaf = [IO.Path]::GetFileName($Relative)
    if ([string]::IsNullOrWhiteSpace($leaf)) { throw 'Invalid backup target path.' }
    return $leaf + '.original'
}

if ([string]::IsNullOrWhiteSpace($GameRoot)) { $GameRoot = $repositoryRoot }
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path $repositoryRoot 'config\baseline.json' }
if ([string]::IsNullOrWhiteSpace($ReleaseManifestPath)) { $ReleaseManifestPath = Join-Path $repositoryRoot 'config\release_candidate.json' }

$resolvedGameRoot = Resolve-ExistingPath $GameRoot 'Game root'
$resolvedBaselinePath = Resolve-ExistingPath $BaselinePath 'Baseline manifest'
$resolvedReleaseManifestPath = Resolve-ExistingPath $ReleaseManifestPath 'Release-candidate manifest'
$baseline = Get-Content -LiteralPath $resolvedBaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$releaseManifest = Get-Content -LiteralPath $resolvedReleaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$repositoryFull = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
$manifestFull = [IO.Path]::GetFullPath($resolvedReleaseManifestPath)
$artifactRoot = if ($manifestFull.StartsWith($repositoryFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $repositoryFull
} else {
    Split-Path -Parent $manifestFull
}
$manifestEntries = @(Get-ManifestEntries $releaseManifest $artifactRoot $PatchAsset)

$baselineByPath = @{}
foreach ($entry in $baseline.files) {
    $relative = ([string]$entry.path).Replace('\', '/')
    $baselineByPath[$relative] = $entry
}
foreach ($entry in $manifestEntries) {
    if (-not $baselineByPath.ContainsKey($entry.target_relative_path)) {
        throw ('Release target is absent from the baseline: ' + $entry.target_relative_path)
    }
}

if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $resolvedGameRoot '.demons-timeline-ko-backup' }
$backupRootFull = [IO.Path]::GetFullPath($BackupRoot)
$statePath = Join-Path $backupRootFull 'install-state.json'
$backupManifestPath = Join-Path $backupRootFull 'backup.json'
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $null }
$stateEntries = @(Get-StateEntries $state)
$stateByPath = @{}
foreach ($entry in $stateEntries) { $stateByPath[([string]$entry.target_relative_path).Replace('\', '/')] = $entry }

$targetPaths = @($manifestEntries | ForEach-Object { $_.target_relative_path })
$targetSet = @{}
foreach ($relative in $targetPaths) { $targetSet[$relative] = $true }

$supportMismatches = @()
foreach ($entry in $baseline.files) {
    $relative = ([string]$entry.path).Replace('\', '/')
    if ($targetSet.ContainsKey($relative)) { continue }
    $candidate = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Baseline support path'
    if (-not (Test-File $candidate ([long]$entry.length) ([string]$entry.sha256))) {
        $supportMismatches += $relative
    }
}
if ($supportMismatches.Count -ne 0) {
    throw ('Unsupported or modified game build; baseline mismatch count: ' + $supportMismatches.Count)
}

$runtimeEntries = @()
$backupNames = @{}
foreach ($manifest in $manifestEntries) {
    $relative = $manifest.target_relative_path
    $baselineEntry = $baselineByPath[$relative]
    $targetPath = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Release target path'
    $backupName = Get-BackupFileName $relative
    if ($backupNames.ContainsKey($backupName)) { throw 'Backup filename collision.' }
    $backupNames[$backupName] = $true
    $backupPath = Join-Path $backupRootFull $backupName
    $stateEntry = if ($stateByPath.ContainsKey($relative)) { $stateByPath[$relative] } else { $null }
    $currentHash = if (Test-Path -LiteralPath $targetPath -PathType Leaf) { Get-Sha256 $targetPath } else { $null }
    $currentLength = if (Test-Path -LiteralPath $targetPath -PathType Leaf) { [long](Get-Item -LiteralPath $targetPath).Length } else { 0 }
    $baselineHash = ([string]$baselineEntry.sha256).ToLowerInvariant()
    $baselineLength = [long]$baselineEntry.length
    $installedHash = if ($null -ne $stateEntry) { ([string]$stateEntry.installed_patch_sha256).ToLowerInvariant() } else { '' }
    $installedLength = if ($null -ne $stateEntry) { [long]$stateEntry.installed_patch_length } else { 0 }
    $runtimeEntries += [PSCustomObject]@{
        relative = $relative
        target = $targetPath
        backup = $backupPath
        baseline_hash = $baselineHash
        baseline_length = $baselineLength
        patch_path = $manifest.artifact_path
        patch_hash = $manifest.patch_sha256
        patch_length = $manifest.patch_length
        current_hash = $currentHash
        current_length = $currentLength
        is_baseline = ($currentHash -eq $baselineHash -and $currentLength -eq $baselineLength)
        is_known_patch = (-not [string]::IsNullOrWhiteSpace($installedHash) -and $currentHash -eq $installedHash -and $currentLength -eq $installedLength)
        backup_valid = (Test-File $backupPath $baselineLength $baselineHash)
    }
}

if ($Action -eq 'Status') {
    $allBaseline = @($runtimeEntries | Where-Object { -not $_.is_baseline }).Count -eq 0
    $allPatched = $runtimeEntries.Count -gt 0 -and @($runtimeEntries | Where-Object { -not $_.is_known_patch }).Count -eq 0
    $statusName = if ($allBaseline) { 'original' } elseif ($allPatched) { 'patched' } else { 'unknown' }
    $result = [PSCustomObject]@{
        action = 'Status'
        status = $statusName
        supported_build = $true
        backup_valid = (@($runtimeEntries | Where-Object { -not $_.backup_valid }).Count -eq 0)
        target_count = $runtimeEntries.Count
        targets = @($runtimeEntries | ForEach-Object {
            [PSCustomObject]@{ target_relative_path = $_.relative; target_sha256 = $_.current_hash }
        })
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result | Format-List }
    return
}

if ($Action -eq 'Install') {
    foreach ($entry in $runtimeEntries) {
        if (-not (Test-File $entry.patch_path $entry.patch_length $entry.patch_hash)) {
            throw ('Patch artifact does not match approved metadata: ' + $entry.relative)
        }
        if ($entry.patch_hash -eq $entry.baseline_hash) { throw 'Patch artifact is identical to its original.' }
        if (-not $entry.is_baseline -and -not $entry.is_known_patch) {
            throw ('Target is neither supported original nor recorded patch: ' + $entry.relative)
        }
    }

    New-Item -ItemType Directory -Path $backupRootFull -Force | Out-Null
    foreach ($entry in $runtimeEntries) {
        if (Test-Path -LiteralPath $entry.backup -PathType Leaf) {
            if (-not $entry.backup_valid) { throw ('Invalid fixed backup: ' + $entry.relative) }
        }
        else {
            if (-not $entry.is_baseline) { throw ('Verified original required for first backup: ' + $entry.relative) }
            $backupTemp = Join-Path $backupRootFull ('.backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Copy-Verified $entry.target $backupTemp $entry.baseline_length $entry.baseline_hash
                [IO.File]::Move($backupTemp, $entry.backup)
            }
            finally { Remove-Item -LiteralPath $backupTemp -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-JsonAtomic ([PSCustomObject]@{
        schema_version = 2
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        files = @($runtimeEntries | ForEach-Object {
            [PSCustomObject]@{ target_relative_path = $_.relative; backup_file = [IO.Path]::GetFileName($_.backup); source_length = $_.baseline_length; source_sha256 = $_.baseline_hash }
        })
    }) $backupManifestPath

    $operations = @()
    $replacementCount = 0
    try {
        foreach ($entry in $runtimeEntries) {
            $parent = Split-Path -Parent $entry.target
            $stage = Join-Path $parent ('.ko-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $rollback = Join-Path $parent ('.ko-rollback-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Copy-Verified $entry.patch_path $stage $entry.patch_length $entry.patch_hash
            $operation = [PSCustomObject]@{ entry = $entry; stage = $stage; rollback = $rollback; previous_hash = $entry.current_hash; replaced = $false }
            $operations += $operation
            [IO.File]::Replace($stage, $entry.target, $rollback, $true)
            $operation.replaced = $true
            $replacementCount++
            if (-not (Test-File $entry.target $entry.patch_length $entry.patch_hash)) { throw 'Post-install verification failed.' }
            if ($TestFailureAfterReplace -or ($TestFailureAfterReplaceCount -gt 0 -and $replacementCount -eq $TestFailureAfterReplaceCount)) {
                throw 'Simulated post-replacement failure.'
            }
        }
        $statePayload = [PSCustomObject]@{
            schema_version = 2
            installed_at_utc = [DateTime]::UtcNow.ToString('o')
            target_slot = [string]$releaseManifest.target_slot
            files = @($runtimeEntries | ForEach-Object {
                [PSCustomObject]@{ target_relative_path = $_.relative; original_sha256 = $_.baseline_hash; installed_patch_length = $_.patch_length; installed_patch_sha256 = $_.patch_hash }
            })
        }
        # Preserve the schema-v1 convenience fields for existing automation
        # when a manifest contains only one target.
        if ($runtimeEntries.Count -eq 1) {
            $single = $runtimeEntries[0]
            $statePayload | Add-Member -NotePropertyName target_relative_path -NotePropertyValue $single.relative
            $statePayload | Add-Member -NotePropertyName original_sha256 -NotePropertyValue $single.baseline_hash
            $statePayload | Add-Member -NotePropertyName installed_patch_length -NotePropertyValue $single.patch_length
            $statePayload | Add-Member -NotePropertyName installed_patch_sha256 -NotePropertyValue $single.patch_hash
        }
        Write-JsonAtomic $statePayload $statePath
        foreach ($operation in $operations) { Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue }
    }
    catch {
        for ($index = $operations.Count - 1; $index -ge 0; $index--) {
            $operation = $operations[$index]
            if ($operation.replaced -and (Test-Path -LiteralPath $operation.rollback -PathType Leaf)) {
                $failed = Join-Path (Split-Path -Parent $operation.entry.target) ('.ko-failed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::Replace($operation.rollback, $operation.entry.target, $failed, $true)
                    if ((Get-Sha256 $operation.entry.target) -ne $operation.previous_hash) { throw 'Rollback hash verification failed.' }
                }
                finally { Remove-Item -LiteralPath $failed -Force -ErrorAction SilentlyContinue }
            }
        }
        throw
    }
    finally {
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.stage -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
        }
    }
    $result = [PSCustomObject]@{ action = 'Install'; status = 'installed'; target_count = $runtimeEntries.Count; backup_valid = $true }
    if ($Json) { $result | ConvertTo-Json -Depth 4 } else { $result | Format-List }
    return
}

if ($Action -eq 'Restore') {
    foreach ($entry in $runtimeEntries) {
        if (-not $entry.backup_valid) { throw ('Verified fixed backup required: ' + $entry.relative) }
    }
    $allBaseline = @($runtimeEntries | Where-Object { -not $_.is_baseline }).Count -eq 0
    if ($allBaseline) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        $result = [PSCustomObject]@{ action = 'Restore'; status = 'already-original'; target_count = $runtimeEntries.Count }
        if ($Json) { $result | ConvertTo-Json -Depth 4 } else { $result | Format-List }
        return
    }
    foreach ($entry in $runtimeEntries) {
        if (-not $entry.is_known_patch) { throw ('Current target is not the recorded patch: ' + $entry.relative) }
    }

    $operations = @()
    try {
        foreach ($entry in $runtimeEntries) {
            $parent = Split-Path -Parent $entry.target
            $stage = Join-Path $parent ('.restore-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $rollback = Join-Path $parent ('.restore-rollback-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Copy-Verified $entry.backup $stage $entry.baseline_length $entry.baseline_hash
            $operation = [PSCustomObject]@{ entry = $entry; stage = $stage; rollback = $rollback; previous_hash = $entry.current_hash; replaced = $false }
            $operations += $operation
            [IO.File]::Replace($stage, $entry.target, $rollback, $true)
            $operation.replaced = $true
            if (-not (Test-File $entry.target $entry.baseline_length $entry.baseline_hash)) { throw 'Post-restore verification failed.' }
            if ($TestFailureAfterReplace) { throw 'Simulated post-replacement failure.' }
        }
        Remove-Item -LiteralPath $statePath -Force
        foreach ($operation in $operations) { Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue }
    }
    catch {
        for ($index = $operations.Count - 1; $index -ge 0; $index--) {
            $operation = $operations[$index]
            if ($operation.replaced -and (Test-Path -LiteralPath $operation.rollback -PathType Leaf)) {
                $failed = Join-Path (Split-Path -Parent $operation.entry.target) ('.restore-failed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::Replace($operation.rollback, $operation.entry.target, $failed, $true)
                    if ((Get-Sha256 $operation.entry.target) -ne $operation.previous_hash) { throw 'Restore rollback hash verification failed.' }
                }
                finally { Remove-Item -LiteralPath $failed -Force -ErrorAction SilentlyContinue }
            }
        }
        throw
    }
    finally {
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.stage -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
        }
    }
    $result = [PSCustomObject]@{ action = 'Restore'; status = 'restored'; target_count = $runtimeEntries.Count }
    if ($Json) { $result | ConvertTo-Json -Depth 4 } else { $result | Format-List }
}
