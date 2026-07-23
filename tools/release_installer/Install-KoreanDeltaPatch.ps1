[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Restore', 'Status')]
    [string]$Action,

    [string]$GameRoot,
    [string]$BaselinePath,
    [string]$ReleaseManifestPath,
    [string]$BackupRoot,
    [switch]$Json,

    [Parameter(DontShow)]
    [switch]$TestFailureAfterReplace,

    [Parameter(DontShow)]
    [ValidateRange(0, 100)]
    [int]$TestFailureAfterReplaceCount = 0,

    [Parameter(DontShow)]
    [ValidateSet('Auto', 'Running', 'NotRunning')]
    [string]$TestGameProcessState = 'Auto',

    [Parameter(DontShow)]
    [ValidateRange(0, 100)]
    [int]$TestRollbackFailureAtOperation = 0
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

function Write-JsonAtomic([object]$Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = Join-Path $parent ('.state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $old = Join-Path $parent ('.state-' + [Guid]::NewGuid().ToString('N') + '.old')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
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

function Write-Result([object]$Value) {
    if ($Json) {
        $Value | ConvertTo-Json -Depth 8
    }
    else {
        $key = ('{0}/{1}' -f [string]$Value.action, [string]$Value.status)
        $message = switch ($key) {
            'Install/installed' {
                if ([bool]$Value.forced) {
                    '한국어 패치 설치가 완료되었습니다. 지원되지 않는 게임 버전에 강제로 적용했으므로 정상 작동 여부를 확인해 주세요.'
                }
                else {
                    '한국어 패치 설치가 완료되었습니다.'
                }
                break
            }
            'Install/already-installed' {
                '한국어 패치가 이미 설치되어 있습니다.'
                break
            }
            'Install/cancelled' {
                '설치를 취소했습니다. 게임 파일은 변경되지 않았습니다.'
                break
            }
            'Restore/restored' {
                '원본 게임 파일 복원이 완료되었습니다.'
                break
            }
            'Restore/already-original' {
                '이미 원본 상태입니다. 복원할 파일이 없습니다.'
                break
            }
            'Status/original' {
                '현재 게임 파일은 원본 상태입니다.'
                break
            }
            'Status/patched' {
                '한국어 패치가 설치되어 있습니다.'
                break
            }
            'Status/unknown' {
                '게임 파일 상태를 확인할 수 없습니다.'
                break
            }
            default {
                '작업이 정상적으로 완료되었습니다.'
            }
        }
        Write-Output $message
    }
}

function Test-GameRunningForRoot([string]$Root) {
    if ($TestGameProcessState -eq 'Running') { return $true }
    if ($TestGameProcessState -eq 'NotRunning') { return $false }

    $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $Root 'DemonsTimeline.exe'))
    foreach ($process in @(Get-Process -Name 'DemonsTimeline' -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try { $processPath = [string]$process.Path }
        catch { return $true }
        if ([string]::IsNullOrWhiteSpace($processPath)) { return $true }
        if ([IO.Path]::GetFullPath($processPath).Equals(
            $expectedExecutable,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }
    return $false
}

function Enter-InstallerMutex([string]$Root) {
    $normalized = [IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $nameHash = ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    $mutex = [Threading.Mutex]::new($false, ('Local\DemonsTimelineKoreanPatch-' + $nameHash))
    try {
        try {
            if (-not $mutex.WaitOne(0)) {
                throw 'Another Korean patch install or restore is already running for this game folder.'
            }
        }
        catch [Threading.AbandonedMutexException] {
            # The abandoned mutex is acquired by this thread and can be used safely.
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-InstallerMutex([Threading.Mutex]$Mutex) {
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Initialize-MSDelta {
    if ('DemonsTimelineDelta.NativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DemonsTimelineDelta {
    public static class NativeMethods {
        [DllImport("msdelta.dll", EntryPoint = "ApplyDeltaW",
            CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ApplyDelta(
            long applyFlags,
            string sourceName,
            string deltaName,
            string targetName);

        public static void Apply(string sourceName, string deltaName, string targetName) {
            if (!ApplyDelta(0, sourceName, deltaName, targetName)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "MSDelta ApplyDeltaW failed");
            }
        }
    }
}
"@
}

function Invoke-MSDelta([string]$Source, [string]$Delta, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        throw "Delta destination already exists: $Destination"
    }
    Initialize-MSDelta
    [DemonsTimelineDelta.NativeMethods]::Apply($Source, $Delta, $Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw 'MSDelta did not create an output file.'
    }
}

function Get-StateEntries([object]$State) {
    if ($null -eq $State) { return @() }
    if ($null -ne $State.files) { return @($State.files) }
    if ($null -ne $State.target_relative_path) {
        return @([PSCustomObject]@{
            target_relative_path = [string]$State.target_relative_path
            original_length = 0
            original_sha256 = [string]$State.original_sha256
            installed_patch_length = [long]$State.installed_patch_length
            installed_patch_sha256 = [string]$State.installed_patch_sha256
        })
    }
    return @()
}

function Find-Backup(
    [string]$Root,
    [string]$Relative,
    [long]$Length,
    [string]$Hash,
    [object]$StateEntry
) {
    $objectPath = Join-Path (Join-Path $Root 'objects') ($Hash.ToLowerInvariant() + '.bin')
    if (Test-File $objectPath $Length $Hash) { return $objectPath }

    if ($null -ne $StateEntry -and -not [string]::IsNullOrWhiteSpace([string]$StateEntry.backup_object)) {
        $stateBackup = Resolve-SafeRelativePath $Root ([string]$StateEntry.backup_object) 'State backup object'
        if (Test-File $stateBackup $Length $Hash) { return $stateBackup }
    }

    $legacyPath = Join-Path $Root ([IO.Path]::GetFileName($Relative) + '.original')
    if (Test-File $legacyPath $Length $Hash) { return $legacyPath }
    return $null
}

function Save-BackupObject(
    [string]$Root,
    [string]$Source,
    [long]$Length,
    [string]$Hash
) {
    $objects = Join-Path $Root 'objects'
    New-Item -ItemType Directory -Path $objects -Force | Out-Null
    $destination = Join-Path $objects ($Hash.ToLowerInvariant() + '.bin')
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if (-not (Test-File $destination $Length $Hash)) {
            throw "Invalid content-addressed backup: $destination"
        }
        return $destination
    }
    $temporary = Join-Path $objects ('.backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Verified $Source $temporary $Length $Hash
        [IO.File]::Move($temporary, $destination)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    return $destination
}

function Get-RecordedBackup([string]$Root, [string]$Relative, [object]$StateEntry) {
    if ($null -eq $StateEntry) { return $null }
    $hash = ([string]$StateEntry.original_sha256).ToLowerInvariant()
    $length = if ($null -ne $StateEntry.original_length) {
        [long]$StateEntry.original_length
    }
    else { 0 }
    if ($hash -notmatch '^[0-9a-f]{64}$') { return $null }

    if (-not [string]::IsNullOrWhiteSpace([string]$StateEntry.backup_object)) {
        $path = Resolve-SafeRelativePath $Root ([string]$StateEntry.backup_object) 'Recorded backup object'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if ($length -le 0) { $length = [long](Get-Item -LiteralPath $path).Length }
            if (Test-File $path $length $hash) {
                return [PSCustomObject]@{ path = $path; length = $length; hash = $hash }
            }
        }
    }

    $legacy = Join-Path $Root ([IO.Path]::GetFileName($Relative) + '.original')
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        if ($length -le 0) { $length = [long](Get-Item -LiteralPath $legacy).Length }
        if (Test-File $legacy $length $hash) {
            return [PSCustomObject]@{ path = $legacy; length = $length; hash = $hash }
        }
    }
    return $null
}

function Invoke-Rollback([array]$Operations) {
    $failures = [Collections.Generic.List[string]]::new()
    $rollbackOrdinal = 0
    for ($index = $Operations.Count - 1; $index -ge 0; $index--) {
        $operation = $Operations[$index]
        if (-not $operation.replaced) { continue }
        $rollbackOrdinal++
        $failed = $null
        try {
            if ($TestRollbackFailureAtOperation -gt 0 -and
                $rollbackOrdinal -eq $TestRollbackFailureAtOperation) {
                throw 'Simulated rollback failure.'
            }
            if ($operation.target_existed) {
                if (-not (Test-Path -LiteralPath $operation.rollback -PathType Leaf)) {
                    throw 'Rollback source is missing.'
                }
                $failed = Join-Path (Split-Path -Parent $operation.target) ('.ko-failed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                [IO.File]::Replace($operation.rollback, $operation.target, $failed, $true)
                if (-not (Test-File $operation.target $operation.previous_length $operation.previous_hash)) {
                    throw 'Rollback verification failed.'
                }
                Remove-Item -LiteralPath $failed -Force -ErrorAction SilentlyContinue
            }
            elseif (Test-Path -LiteralPath $operation.target -PathType Leaf) {
                Remove-Item -LiteralPath $operation.target -Force
                if (Test-Path -LiteralPath $operation.target) {
                    throw 'Rollback could not remove a newly created target.'
                }
            }
            $operation.rollback_verified = $true
        }
        catch {
            $operation.rollback_failed = $true
            $recoveryFiles = @()
            foreach ($candidate in @($operation.rollback, $failed, $operation.target)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and
                    (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $recoveryFiles += [IO.Path]::GetFullPath([string]$candidate)
                }
            }
            $operation.recovery_files = $recoveryFiles
            $recoveryDescription = if ($recoveryFiles.Count -gt 0) {
                ' Recovery files: ' + ($recoveryFiles -join ', ')
            }
            else { '' }
            $failures.Add(('{0}: {1}{2}' -f $operation.target, $_.Exception.Message, $recoveryDescription)) | Out-Null
        }
    }
    if ($failures.Count -gt 0) {
        throw ('Rollback incomplete. ' + ($failures -join ' | '))
    }
}

if ([string]::IsNullOrWhiteSpace($GameRoot)) { $GameRoot = $repositoryRoot }
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path $repositoryRoot 'config\baseline.json' }
if ([string]::IsNullOrWhiteSpace($ReleaseManifestPath)) { $ReleaseManifestPath = Join-Path $repositoryRoot 'config\release_candidate.json' }

$resolvedGameRoot = Resolve-ExistingPath $GameRoot 'Game root'
$resolvedBaselinePath = Resolve-ExistingPath $BaselinePath 'Baseline manifest'
$resolvedReleaseManifestPath = Resolve-ExistingPath $ReleaseManifestPath 'Release-candidate manifest'
$baseline = Get-Content -LiteralPath $resolvedBaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$release = Get-Content -LiteralPath $resolvedReleaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestHash = Get-Sha256 $resolvedReleaseManifestPath
$packageVersion = if ([string]::IsNullOrWhiteSpace([string]$release.package_version)) {
    'unknown'
}
else { [string]$release.package_version }
if ([int]$release.schema_version -ne 3 -or [string]$release.delta_engine -ne 'windows_msdelta_raw') {
    throw 'Delta installer requires a schema-v3 Windows MSDelta manifest.'
}
if (@($release.artifacts).Count -eq 0) { throw 'Delta manifest contains no artifacts.' }

$repositoryFull = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
$manifestFull = [IO.Path]::GetFullPath($resolvedReleaseManifestPath)
$artifactRoot = if ($manifestFull.StartsWith($repositoryFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $repositoryFull
}
else {
    Split-Path -Parent $manifestFull
}

$baselineByPath = @{}
foreach ($item in $baseline.files) {
    $relative = ([string]$item.path).Replace('\', '/')
    $baselineByPath[$relative] = $item
}

$manifestEntries = @()
$seen = @{}
foreach ($item in $release.artifacts) {
    $relative = ([string]$item.target_relative_path).Replace('\', '/')
    if ($seen.ContainsKey($relative)) { throw 'Duplicate delta target path.' }
    $seen[$relative] = $true
    if (-not $baselineByPath.ContainsKey($relative)) {
        throw "Delta target is absent from baseline: $relative"
    }

    $sourceLength = [long]$item.source.length
    $sourceHash = ([string]$item.source.sha256).ToLowerInvariant()
    $resultLength = [long]$item.result.length
    $resultHash = ([string]$item.result.sha256).ToLowerInvariant()
    $deltaLength = [long]$item.delta.length
    $deltaHash = ([string]$item.delta.sha256).ToLowerInvariant()
    foreach ($hash in @($sourceHash, $resultHash, $deltaHash)) {
        if ($hash -notmatch '^[0-9a-f]{64}$') { throw 'Delta manifest contains an invalid SHA-256.' }
    }
    if ($sourceLength -le 0 -or $resultLength -le 0 -or $deltaLength -le 0) {
        throw 'Delta manifest contains an invalid length.'
    }

    $baselineEntry = $baselineByPath[$relative]
    if ([long]$baselineEntry.length -ne $sourceLength -or
        ([string]$baselineEntry.sha256).ToLowerInvariant() -ne $sourceHash) {
        throw "Delta source does not match baseline: $relative"
    }
    $deltaPath = Resolve-SafeRelativePath $artifactRoot ([string]$item.delta.relative_path) 'Delta path'
    if (-not (Test-File $deltaPath $deltaLength $deltaHash)) {
        throw "Delta payload verification failed: $relative"
    }

    $manifestEntries += [PSCustomObject]@{
        relative = $relative
        target = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Delta target path'
        source_length = $sourceLength
        source_hash = $sourceHash
        result_length = $resultLength
        result_hash = $resultHash
        delta_path = $deltaPath
        delta_length = $deltaLength
        delta_hash = $deltaHash
    }
}

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $resolvedGameRoot '.demons-timeline-ko-backup'
}
$backupRootFull = [IO.Path]::GetFullPath($BackupRoot)
$statePath = Join-Path $backupRootFull 'install-state.json'
$backupManifestPath = Join-Path $backupRootFull 'backup.json'
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else { $null }
$stateByPath = @{}
foreach ($entry in @(Get-StateEntries $state)) {
    $stateByPath[([string]$entry.target_relative_path).Replace('\', '/')] = $entry
}

$targetSet = @{}
foreach ($entry in $manifestEntries) { $targetSet[$entry.relative] = $true }
$supportMismatches = @()
foreach ($item in $baseline.files) {
    $relative = ([string]$item.path).Replace('\', '/')
    if ($targetSet.ContainsKey($relative)) { continue }
    $path = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Baseline support path'
    if (-not (Test-File $path ([long]$item.length) ([string]$item.sha256))) {
        $supportMismatches += $relative
    }
}

$runtimeEntries = @()
foreach ($entry in $manifestEntries) {
    $currentExists = Test-Path -LiteralPath $entry.target -PathType Leaf
    $currentLength = if ($currentExists) { [long](Get-Item -LiteralPath $entry.target).Length } else { 0 }
    $currentHash = if ($currentExists) { Get-Sha256 $entry.target } else { '' }
    $stateEntry = if ($stateByPath.ContainsKey($entry.relative)) { $stateByPath[$entry.relative] } else { $null }
    $installedLength = if ($null -ne $stateEntry) { [long]$stateEntry.installed_patch_length } else { 0 }
    $installedHash = if ($null -ne $stateEntry) { ([string]$stateEntry.installed_patch_sha256).ToLowerInvariant() } else { '' }
    $sourceBackup = Find-Backup $backupRootFull $entry.relative $entry.source_length $entry.source_hash $stateEntry
    $recordedBackup = Get-RecordedBackup $backupRootFull $entry.relative $stateEntry
    $isSource = $currentExists -and $currentLength -eq $entry.source_length -and $currentHash -eq $entry.source_hash
    $isResult = $currentExists -and $currentLength -eq $entry.result_length -and $currentHash -eq $entry.result_hash
    $isRecorded = $currentExists -and $installedLength -gt 0 -and $currentLength -eq $installedLength -and $currentHash -eq $installedHash
    $canKnownUpgrade = $isRecorded -and -not [string]::IsNullOrWhiteSpace([string]$sourceBackup)
    $runtimeEntries += [PSCustomObject]@{
        manifest = $entry
        state_entry = $stateEntry
        current_exists = $currentExists
        current_length = $currentLength
        current_hash = $currentHash
        is_source = $isSource
        is_result = $isResult
        is_recorded = $isRecorded
        source_backup = $sourceBackup
        recorded_backup = $recordedBackup
        can_known_upgrade = $canKnownUpgrade
        known_state = ($isSource -or $isResult -or $canKnownUpgrade)
    }
}

if ($Action -eq 'Status') {
    $allSource = @($runtimeEntries | Where-Object { -not $_.is_source }).Count -eq 0
    $allResult = @($runtimeEntries | Where-Object { -not $_.is_result }).Count -eq 0
    $allRecorded = $runtimeEntries.Count -gt 0 -and @($runtimeEntries | Where-Object { -not $_.is_recorded }).Count -eq 0
    $backupValid = $stateByPath.Count -gt 0
    if ($backupValid) {
        foreach ($entry in $runtimeEntries) {
            if (-not $entry.is_recorded -or $null -eq $entry.recorded_backup) { $backupValid = $false; break }
        }
    }
    $statusName = if ($allSource) { 'original' } elseif ($allResult -or $allRecorded) { 'patched' } else { 'unknown' }
    Write-Result ([PSCustomObject]@{
        action = 'Status'
        status = $statusName
        supported_build = ($supportMismatches.Count -eq 0)
        support_mismatch_count = $supportMismatches.Count
        backup_valid = $backupValid
        forced = ($null -ne $state -and $state.forced -eq $true)
        package_version = if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.package_version)) { [string]$state.package_version } else { $packageVersion }
        manifest_sha256 = $manifestHash
        installer_schema_version = 3
        target_count = $runtimeEntries.Count
        targets = @($runtimeEntries | ForEach-Object {
            [PSCustomObject]@{
                target_relative_path = $_.manifest.relative
                target_sha256 = $_.current_hash
            }
        })
    })
    return
}

if ($Action -eq 'Restore') {
    $restoreMutex = Enter-InstallerMutex $resolvedGameRoot
    try {
    if ($null -eq $state -or $stateByPath.Count -eq 0) {
        $allSource = @($runtimeEntries | Where-Object { -not $_.is_source }).Count -eq 0
        if ($allSource) {
            Write-Result ([PSCustomObject]@{ action = 'Restore'; status = 'already-original'; target_count = $runtimeEntries.Count })
            return
        }
        throw 'No verified installation state is available for restore.'
    }

    $restoreEntries = @()
    $expectedRestoreTargets = @()
    foreach ($entry in $runtimeEntries) {
        $stateEntry = $entry.state_entry
        if ($null -eq $stateEntry) { throw 'Install state does not cover every release target.' }
        $installedLength = [long]$stateEntry.installed_patch_length
        $installedHash = ([string]$stateEntry.installed_patch_sha256).ToLowerInvariant()
        $originalHash = ([string]$stateEntry.original_sha256).ToLowerInvariant()
        $originalLength = if ($null -ne $stateEntry.original_length -and [long]$stateEntry.original_length -gt 0) {
            [long]$stateEntry.original_length
        }
        elseif ($originalHash -eq $entry.manifest.source_hash) {
            $entry.manifest.source_length
        }
        elseif ($null -ne $entry.recorded_backup) {
            [long]$entry.recorded_backup.length
        }
        else { 0 }
        $expectedRestoreTargets += [PSCustomObject]@{
            target = $entry.manifest.target
            relative = $entry.manifest.relative
            length = $originalLength
            hash = $originalHash
        }

        if ($entry.current_exists -and $entry.current_length -eq $originalLength -and $entry.current_hash -eq $originalHash) {
            continue
        }
        if (-not $entry.current_exists -or $entry.current_length -ne $installedLength -or $entry.current_hash -ne $installedHash) {
            throw "Current target is not the recorded installed result: $($entry.manifest.relative)"
        }
        $backup = Find-Backup $backupRootFull $entry.manifest.relative $originalLength $originalHash $stateEntry
        if ([string]::IsNullOrWhiteSpace([string]$backup)) {
            throw "Verified restore backup is unavailable: $($entry.manifest.relative)"
        }
        $restoreEntries += [PSCustomObject]@{
            manifest = $entry.manifest
            target = $entry.manifest.target
            backup = $backup
            original_length = $originalLength
            original_hash = $originalHash
            current_length = $entry.current_length
            current_hash = $entry.current_hash
        }
    }
    if ($restoreEntries.Count -gt 0 -and (Test-GameRunningForRoot $resolvedGameRoot)) {
        throw 'Close the game before restoring the original files.'
    }

    $operations = @()
    $replacementCount = 0
    try {
        foreach ($entry in $restoreEntries) {
            $parent = Split-Path -Parent $entry.target
            $stage = Join-Path $parent ('.restore-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $rollback = Join-Path $parent ('.restore-rollback-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Copy-Verified $entry.backup $stage $entry.original_length $entry.original_hash
            $operation = [PSCustomObject]@{
                target = $entry.target
                stage = $stage
                rollback = $rollback
                target_existed = $true
                previous_length = $entry.current_length
                previous_hash = $entry.current_hash
                replaced = $false
                rollback_verified = $false
                rollback_failed = $false
                recovery_files = @()
            }
            $operations += $operation
            if (-not (Test-File $entry.target $entry.current_length $entry.current_hash)) {
                throw "Restore target changed after validation: $($entry.manifest.relative)"
            }
            if (Test-GameRunningForRoot $resolvedGameRoot) {
                throw 'The game started while restore was being prepared.'
            }
            [IO.File]::Replace($stage, $entry.target, $rollback, $true)
            $operation.replaced = $true
            $replacementCount++
            if (-not (Test-File $entry.target $entry.original_length $entry.original_hash)) {
                throw 'Post-restore verification failed.'
            }
            if ($TestFailureAfterReplace -or
                ($TestFailureAfterReplaceCount -gt 0 -and $replacementCount -eq $TestFailureAfterReplaceCount)) {
                throw 'Simulated post-replacement failure.'
            }
        }
        foreach ($expected in $expectedRestoreTargets) {
            if (-not (Test-File $expected.target $expected.length $expected.hash)) {
                throw "Final restore-set verification failed: $($expected.relative)"
            }
        }
        Remove-Item -LiteralPath $statePath -Force
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $primaryError = $_
        try { Invoke-Rollback $operations }
        catch {
            throw ('Restore failed: {0} Rollback also failed: {1}' -f
                $primaryError.Exception.Message,
                $_.Exception.Message)
        }
        throw $primaryError
    }
    finally {
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.stage -Force -ErrorAction SilentlyContinue
            if (-not $operation.rollback_failed) {
                Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Result ([PSCustomObject]@{ action = 'Restore'; status = 'restored'; target_count = $runtimeEntries.Count })
    return
    }
    finally {
        Exit-InstallerMutex $restoreMutex
    }
}

$allResult = @($runtimeEntries | Where-Object { -not $_.is_result }).Count -eq 0
$restoreStateValid = $stateByPath.Count -eq $runtimeEntries.Count
if ($restoreStateValid) {
    foreach ($entry in $runtimeEntries) {
        if (-not $entry.is_recorded -or $null -eq $entry.recorded_backup) {
            $restoreStateValid = $false; break
        }
    }
}
if ($allResult) {
    if (-not $restoreStateValid) {
        throw 'Patch files are present, but verified restore state is incomplete. Use Steam file verification before reinstalling.'
    }
    Write-Result ([PSCustomObject]@{
        action = 'Install'
        status = 'already-installed'
        target_count = $runtimeEntries.Count
        supported_build = ($supportMismatches.Count -eq 0)
    })
    return
}

$installMutex = Enter-InstallerMutex $resolvedGameRoot
try {
if (Test-GameRunningForRoot $resolvedGameRoot) {
    throw 'Close the game before installing the Korean patch.'
}

$knownTargets = @($runtimeEntries | Where-Object { -not $_.known_state }).Count -eq 0
$forced = $supportMismatches.Count -ne 0 -or -not $knownTargets
if ($forced) {
    if ($Json) {
        throw 'Unsupported installation requires interactive y/N consent.'
    }
    Write-Warning 'The installed game version or target files are not supported.'
    Write-Warning 'A forced delta attempt can make the game unplayable. Verified backups will be kept.'
    $answer = Read-Host 'Force installation attempt? [y/N]'
    if ($answer.Trim().ToLowerInvariant() -ne 'y') {
        Write-Result ([PSCustomObject]@{
            action = 'Install'
            status = 'cancelled'
            forced = $false
            target_count = $runtimeEntries.Count
        })
        return
    }
}

$requiredBytes = [long]0
foreach ($entry in $runtimeEntries) {
    if (-not $entry.is_result) { $requiredBytes += $entry.manifest.result_length }
    if ($entry.current_exists) {
        $objectPath = Join-Path (Join-Path $backupRootFull 'objects') ($entry.current_hash + '.bin')
        if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
            $requiredBytes += $entry.current_length
        }
    }
}
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($resolvedGameRoot))
if ($drive.AvailableFreeSpace -lt ($requiredBytes + 16MB)) {
    throw 'Insufficient free disk space for staged installation and verified backups.'
}

$prepared = @()
try {
    foreach ($entry in $runtimeEntries) {
        if ($entry.is_result) {
            $prepared += [PSCustomObject]@{
                runtime = $entry
                stage = $null
                result_length = $entry.current_length
                result_hash = $entry.current_hash
                selected_source = $null
                source_was_expected = $true
            }
            continue
        }

        $selectedSource = $null
        $sourceWasExpected = $false
        if ($entry.is_source) {
            $selectedSource = $entry.manifest.target
            $sourceWasExpected = $true
        }
        elseif ($entry.can_known_upgrade) {
            $selectedSource = $entry.source_backup
            $sourceWasExpected = $true
        }
        elseif ($forced) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.source_backup)) {
                $selectedSource = $entry.source_backup
                $sourceWasExpected = $true
            }
            elseif ($null -ne $entry.recorded_backup) {
                $selectedSource = $entry.recorded_backup.path
            }
            elseif ($entry.current_exists) {
                $selectedSource = $entry.manifest.target
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$selectedSource)) {
            throw "No usable delta source is available: $($entry.manifest.relative)"
        }

        $parent = Split-Path -Parent $entry.manifest.target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Target directory is missing: $parent"
        }
        $stage = Join-Path $parent ('.ko-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        Invoke-MSDelta $selectedSource $entry.manifest.delta_path $stage
        $resultLength = [long](Get-Item -LiteralPath $stage).Length
        $resultHash = Get-Sha256 $stage
        if ($sourceWasExpected -and
            ($resultLength -ne $entry.manifest.result_length -or $resultHash -ne $entry.manifest.result_hash)) {
            throw "Approved delta result verification failed: $($entry.manifest.relative)"
        }
        if ($resultLength -le 0) { throw 'Forced delta produced an empty result.' }

        $prepared += [PSCustomObject]@{
            runtime = $entry
            stage = $stage
            result_length = $resultLength
            result_hash = $resultHash
            selected_source = $selectedSource
            source_was_expected = $sourceWasExpected
        }
    }

    New-Item -ItemType Directory -Path $backupRootFull -Force | Out-Null
    $stateFiles = @()
    foreach ($item in $prepared) {
        $entry = $item.runtime
        $originalPath = $null
        $originalLength = 0
        $originalHash = ''

        if ($entry.is_source) {
            $originalPath = $entry.manifest.target
            $originalLength = $entry.current_length
            $originalHash = $entry.current_hash
        }
        elseif ($entry.is_recorded -and $null -ne $entry.recorded_backup) {
            $originalPath = $entry.recorded_backup.path
            $originalLength = $entry.recorded_backup.length
            $originalHash = $entry.recorded_backup.hash
        }
        elseif ($entry.current_exists -and -not $entry.is_result) {
            $originalPath = $entry.manifest.target
            $originalLength = $entry.current_length
            $originalHash = $entry.current_hash
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.source_backup)) {
            $originalPath = $entry.source_backup
            $originalLength = $entry.manifest.source_length
            $originalHash = $entry.manifest.source_hash
        }
        elseif ($entry.is_result -and $null -ne $entry.recorded_backup) {
            $originalPath = $entry.recorded_backup.path
            $originalLength = $entry.recorded_backup.length
            $originalHash = $entry.recorded_backup.hash
        }
        else {
            throw "No verified restore source is available: $($entry.manifest.relative)"
        }

        $backupObject = Save-BackupObject $backupRootFull $originalPath $originalLength $originalHash
        $backupRelative = 'objects/' + [IO.Path]::GetFileName($backupObject)
        $stateFiles += [PSCustomObject]@{
            target_relative_path = $entry.manifest.relative
            original_length = $originalLength
            original_sha256 = $originalHash
            backup_object = $backupRelative
            installed_patch_length = $item.result_length
            installed_patch_sha256 = $item.result_hash
            expected_release_length = $entry.manifest.result_length
            expected_release_sha256 = $entry.manifest.result_hash
            forced = ($forced -and -not $item.source_was_expected)
        }
    }

    Write-JsonAtomic ([PSCustomObject]@{
        schema_version = 3
        installer_schema_version = 3
        package_version = $packageVersion
        manifest_sha256 = $manifestHash
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        files = @($stateFiles | ForEach-Object {
            [PSCustomObject]@{
                target_relative_path = $_.target_relative_path
                backup_object = $_.backup_object
                source_length = $_.original_length
                source_sha256 = $_.original_sha256
            }
        })
    }) $backupManifestPath

    $operations = @()
    $replacementCount = 0
    try {
        foreach ($item in $prepared) {
            if ($null -eq $item.stage) { continue }
            $entry = $item.runtime
            $target = $entry.manifest.target
            $parent = Split-Path -Parent $target
            $rollback = Join-Path $parent ('.ko-rollback-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $operation = [PSCustomObject]@{
                target = $target
                stage = $item.stage
                rollback = $rollback
                target_existed = $entry.current_exists
                previous_length = $entry.current_length
                previous_hash = $entry.current_hash
                replaced = $false
                rollback_verified = $false
                rollback_failed = $false
                recovery_files = @()
            }
            $operations += $operation
            if (Test-GameRunningForRoot $resolvedGameRoot) {
                throw 'The game started while installation was being prepared.'
            }
            if ($entry.current_exists) {
                if (-not (Test-File $target $entry.current_length $entry.current_hash)) {
                    throw "Install target changed after staging: $($entry.manifest.relative)"
                }
                [IO.File]::Replace($item.stage, $target, $rollback, $true)
            }
            else {
                if (Test-Path -LiteralPath $target) {
                    throw "Install target appeared after staging: $($entry.manifest.relative)"
                }
                [IO.File]::Move($item.stage, $target)
            }
            $operation.replaced = $true
            $replacementCount++
            if (-not (Test-File $target $item.result_length $item.result_hash)) {
                throw 'Post-install result verification failed.'
            }
            if ($TestFailureAfterReplace -or
                ($TestFailureAfterReplaceCount -gt 0 -and $replacementCount -eq $TestFailureAfterReplaceCount)) {
                throw 'Simulated post-replacement failure.'
            }
        }

        foreach ($item in $prepared) {
            if (-not (Test-File $item.runtime.manifest.target $item.result_length $item.result_hash)) {
                throw "Final install-set verification failed: $($item.runtime.manifest.relative)"
            }
        }
        Write-JsonAtomic ([PSCustomObject]@{
            schema_version = 3
            installed_at_utc = [DateTime]::UtcNow.ToString('o')
            target_slot = [string]$release.target_slot
            installer_schema_version = 3
            package_version = $packageVersion
            manifest_sha256 = $manifestHash
            forced = $forced
            supported_build = ($supportMismatches.Count -eq 0)
            support_mismatch_count = $supportMismatches.Count
            files = $stateFiles
        }) $statePath
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $primaryError = $_
        try { Invoke-Rollback $operations }
        catch {
            throw ('Install failed: {0} Rollback also failed: {1}' -f
                $primaryError.Exception.Message,
                $_.Exception.Message)
        }
        throw $primaryError
    }
    finally {
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.stage -Force -ErrorAction SilentlyContinue
            if (-not $operation.rollback_failed) {
                Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Result ([PSCustomObject]@{
        action = 'Install'
        status = 'installed'
        target_count = $runtimeEntries.Count
        forced = $forced
        supported_build = ($supportMismatches.Count -eq 0)
        backup_valid = $true
        package_version = $packageVersion
        manifest_sha256 = $manifestHash
        installer_schema_version = 3
    })
}
finally {
    foreach ($item in $prepared) {
        if ($null -ne $item.stage) {
            Remove-Item -LiteralPath $item.stage -Force -ErrorAction SilentlyContinue
        }
    }
}
}
finally {
    Exit-InstallerMutex $installMutex
}
