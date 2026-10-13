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

# Preserve the original failure (including rollback details) after actionable advice.
trap {
    $failure = $_
    $cause = $failure.Exception
    while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
    if ($cause -is [UnauthorizedAccessException]) {
        Write-Host '[ACCESS_DENIED] 파일 접근이 거부되었습니다. 게임과 다른 설치기를 종료하고 폴더 쓰기 권한 및 Windows 보안의 차단 기록을 확인해 주세요. 신뢰한 패치라면 관리자 권한으로 다시 실행할 수 있습니다.' -ForegroundColor Red
    }
    elseif ($cause -is [IO.IOException]) {
        Write-Host '[FILE_IO] 파일을 읽거나 쓸 수 없습니다. 게임·다른 설치기·파일을 사용하는 프로그램을 종료하고 디스크 여유 공간과 폴더 접근 권한을 확인해 주세요.' -ForegroundColor Red
    }
    Write-Host '실패가 계속되면 오류 화면 전체를 제작자에게 전달해 주세요. 복원 백업과 롤백 파일은 삭제하지 마세요.' -ForegroundColor Yellow
    throw $failure
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-GameLocation([string]$Root) {
    $exe = Test-Path -LiteralPath (Join-Path $Root 'DemonsTimeline.exe') -PathType Leaf
    $data = Test-Path -LiteralPath (Join-Path $Root 'DemonsTimeline_Data') -PathType Container
    if (-not $exe -and -not $data) {
        throw "[GAME_LOCATION] 게임을 찾을 수 없는 위치입니다: $Root`nSteam → 게임 우클릭 → 관리 → 로컬 파일 탐색으로 연 폴더에 install.bat, restore.bat, DemonsTimeline_KoreanPatch 폴더를 함께 넣어 주세요. install.bat는 DemonsTimeline.exe와 같은 위치에 있어야 합니다. 압축 파일 안에서 바로 실행하지 말고 전체를 압축 해제해 주세요."
    }
    if (-not $exe -or -not $data) {
        throw "[GAME_INCOMPLETE] 게임 실행 파일 또는 데이터 폴더가 없습니다: $Root`nSteam의 로컬 파일 탐색으로 위치를 확인한 뒤, 속성 → 설치된 파일 → 게임 파일 무결성 검사를 실행해 주세요. 백신 격리 기록도 확인하되 보호 기능을 끄지는 마세요."
    }
}

function Read-InstallerJson([string]$Path, [string]$Code, [string]$Advice) {
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $value) { throw 'Empty JSON' }
        return $value
    }
    catch {
        throw "[$Code] 설정 또는 기록 파일을 읽을 수 없습니다: $Path`n$Advice`n상세: $($_.Exception.Message)"
    }
}

function Resolve-ExistingPath([string]$Path, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw "[PATH_MISSING] 필요한 경로가 없습니다: $Path ($Description)`n게임 폴더 위치를 확인하고 패치 ZIP 전체를 다시 압축 해제해 주세요."
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

function Write-InstallerLog([string]$Tag, [string]$Message) {
    if ($Json) { return }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Tag) {
        'START' { 'Cyan' }
        'INFO' { 'Gray' }
        'CHECK' { 'DarkCyan' }
        'SCAN' { 'Blue' }
        'DONE' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'WRITE' { 'Magenta' }
        'ROLLBACK' { 'Yellow' }
        'LOCK' { 'DarkGray' }
        'BACKUP' { 'DarkYellow' }
        'STAGE' { 'Blue' }
        'VERIFY' { 'Green' }
        'STATE' { 'DarkCyan' }
        'PHASE' { 'Cyan' }
        'SKIP' { 'DarkGray' }
        'SOURCE' { 'Blue' }
        'DELTA' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host ('[{0}] [{1,-8}] {2}' -f $timestamp, $Tag, $Message) -ForegroundColor $color
}

function Write-InstallerBanner([string]$RequestedAction) {
    if ($Json) { return }
    $actionLabel = switch ($RequestedAction) {
        'Install' { '설치' }
        'Restore' { '복원' }
        'Status' { '상태 확인' }
        default { $RequestedAction }
    }
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '  Demons'' Timeline 한국어 패치 / MSDelta 설치기' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-InstallerLog 'START' ('요청 작업: {0}' -f $actionLabel)
}

function Get-ShortHash([string]$Hash) {
    if ([string]::IsNullOrWhiteSpace($Hash)) { return '없음' }
    if ($Hash.Length -le 12) { return $Hash }
    return $Hash.Substring(0, 12)
}

function Format-InstallerBytes([long]$Bytes) {
    return ('{0:N0} 바이트' -f $Bytes)
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
                throw '이 게임 폴더에서 다른 한국어 패치 설치 또는 복원이 이미 실행 중입니다.'
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
                throw new Win32Exception(Marshal.GetLastWin32Error(), "MSDelta ApplyDeltaW 호출 실패");
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
        Write-InstallerLog 'ROLLBACK' ('이전 파일 복원 [{0}]: {1}' -f $rollbackOrdinal, $operation.target)
        try {
            if ($TestRollbackFailureAtOperation -gt 0 -and
                $rollbackOrdinal -eq $TestRollbackFailureAtOperation) {
                throw 'Simulated rollback failure.'
            }
            if ($operation.target_existed) {
                if (-not (Test-Path -LiteralPath $operation.rollback -PathType Leaf)) {
                    throw '롤백 원본이 없습니다.'
                }
                $failed = Join-Path (Split-Path -Parent $operation.target) ('.ko-failed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                [IO.File]::Replace($operation.rollback, $operation.target, $failed, $true)
                if (-not (Test-File $operation.target $operation.previous_length $operation.previous_hash)) {
                    throw '롤백 검증에 실패했습니다.'
                }
                Remove-Item -LiteralPath $failed -Force -ErrorAction SilentlyContinue
            }
            elseif (Test-Path -LiteralPath $operation.target -PathType Leaf) {
                Remove-Item -LiteralPath $operation.target -Force
                if (Test-Path -LiteralPath $operation.target) {
                    throw '롤백 중 새로 생성된 대상 파일을 제거하지 못했습니다.'
                }
            }
            $operation.rollback_verified = $true
            Write-InstallerLog 'ROLLBACK' ('롤백 검증 완료: {0}' -f $operation.target)
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
                ' 복구용 파일: ' + ($recoveryFiles -join ', ')
            }
            else { '' }
            $failures.Add(('{0}: {1}{2}' -f $operation.target, $_.Exception.Message, $recoveryDescription)) | Out-Null
            Write-InstallerLog 'ERROR' ('롤백 실패: {0} / {1}' -f $operation.target, $_.Exception.Message)
        }
    }
    if ($failures.Count -gt 0) {
        throw ('롤백이 완전히 끝나지 않았습니다. ' + ($failures -join ' | '))
    }
    Write-InstallerLog 'ROLLBACK' ('롤백 절차 완료: {0}개 작업' -f $rollbackOrdinal)
}

if ([string]::IsNullOrWhiteSpace($GameRoot)) { $GameRoot = $repositoryRoot }
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path $repositoryRoot 'config\baseline.json' }
if ([string]::IsNullOrWhiteSpace($ReleaseManifestPath)) { $ReleaseManifestPath = Join-Path $repositoryRoot 'config\release_candidate.json' }

$resolvedGameRoot = Resolve-ExistingPath $GameRoot 'Game root'
Assert-GameLocation $resolvedGameRoot
$resolvedBaselinePath = Resolve-ExistingPath $BaselinePath 'Baseline manifest'
$resolvedReleaseManifestPath = Resolve-ExistingPath $ReleaseManifestPath 'Release-candidate manifest'
$baseline = Read-InstallerJson $resolvedBaselinePath 'PACKAGE_CONFIG' '최신 패치 ZIP을 다시 받아 전체를 압축 해제해 주세요. 다른 버전의 패치 파일을 섞지 마세요.'
$release = Read-InstallerJson $resolvedReleaseManifestPath 'PACKAGE_CONFIG' '최신 패치 ZIP을 다시 받아 전체를 압축 해제해 주세요. 다른 버전의 패치 파일을 섞지 마세요.'
$manifestHash = Get-Sha256 $resolvedReleaseManifestPath
$packageVersion = if ([string]::IsNullOrWhiteSpace([string]$release.package_version)) {
    'unknown'
}
else { [string]$release.package_version }
if ([int]$release.schema_version -ne 3 -or [string]$release.delta_engine -ne 'windows_msdelta_raw') {
    throw '델타 설치기에는 스키마 v3 Windows MSDelta 매니페스트가 필요합니다.'
}
if (@($release.artifacts).Count -eq 0) { throw '델타 매니페스트에 패치 대상이 없습니다.' }

Write-InstallerBanner $Action
Write-InstallerLog 'PHASE' '1/7 패키지 및 매니페스트 무결성 검증'
Write-InstallerLog 'INFO' ('패키지 버전: {0}' -f $packageVersion)
Write-InstallerLog 'INFO' ('게임 경로: {0}' -f $resolvedGameRoot)
Write-InstallerLog 'INFO' ('매니페스트: {0}... / 스키마 v3 / MSDelta RAW' -f (Get-ShortHash $manifestHash))
Write-InstallerLog 'CHECK' ('패치 대상 {0}개와 지원 게임 기준 정보를 불러왔습니다.' -f @($release.artifacts).Count)
Write-InstallerLog 'CHECK' '패키지 경로, 매니페스트 구조, 페이로드 해시를 검사합니다.'

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
    if ($seen.ContainsKey($relative)) { throw '델타 대상 경로가 중복되었습니다.' }
    $seen[$relative] = $true
    if (-not $baselineByPath.ContainsKey($relative)) {
        throw "기준 정보에 델타 대상이 없습니다: $relative"
    }

    $sourceLength = [long]$item.source.length
    $sourceHash = ([string]$item.source.sha256).ToLowerInvariant()
    $resultLength = [long]$item.result.length
    $resultHash = ([string]$item.result.sha256).ToLowerInvariant()
    $deltaLength = [long]$item.delta.length
    $deltaHash = ([string]$item.delta.sha256).ToLowerInvariant()
    foreach ($hash in @($sourceHash, $resultHash, $deltaHash)) {
        if ($hash -notmatch '^[0-9a-f]{64}$') { throw '델타 매니페스트에 올바르지 않은 SHA-256 값이 있습니다.' }
    }
    if ($sourceLength -le 0 -or $resultLength -le 0 -or $deltaLength -le 0) {
        throw '델타 매니페스트에 올바르지 않은 파일 크기가 있습니다.'
    }

    $baselineEntry = $baselineByPath[$relative]
    if ([long]$baselineEntry.length -ne $sourceLength -or
        ([string]$baselineEntry.sha256).ToLowerInvariant() -ne $sourceHash) {
        throw "델타 원본이 기준 정보와 일치하지 않습니다: $relative"
    }
    $deltaPath = Resolve-SafeRelativePath $artifactRoot ([string]$item.delta.relative_path) 'Delta path'
    if (-not (Test-File $deltaPath $deltaLength $deltaHash)) {
        throw "[PACKAGE_PAYLOAD] 패치 데이터가 없거나 손상되었습니다: $deltaPath`n최신 패치 ZIP을 다시 다운로드하고 전체를 압축 해제해 주세요. 게임 재설치로는 패치 파일 손상이 해결되지 않습니다."
    }
    Write-InstallerLog 'CHECK' ('델타 페이로드 검증 완료: {0} / {1} / SHA-256 {2}...' -f
        $relative, (Format-InstallerBytes $deltaLength), (Get-ShortHash $deltaHash))


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
    Read-InstallerJson $statePath 'BACKUP_STATE' '백업 폴더를 삭제하지 마세요. 이 화면과 install-state.json을 제작자에게 전달해 주세요. 원본 게임으로 돌아가려면 Steam 무결성 검사를 사용할 수 있습니다.'
}
else { $null }
$stateByPath = @{}
foreach ($entry in @(Get-StateEntries $state)) {
    $stateByPath[([string]$entry.target_relative_path).Replace('\', '/')] = $entry
}

$targetSet = @{}
foreach ($entry in $manifestEntries) { $targetSet[$entry.relative] = $true }
$supportMismatches = @()
$missingGameFiles = @()
foreach ($item in $baseline.files) {
    $relative = ([string]$item.path).Replace('\', '/')
    $gameFile = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Baseline game path'
    if (-not (Test-Path -LiteralPath $gameFile -PathType Leaf)) { $missingGameFiles += $relative }
    if ($targetSet.ContainsKey($relative)) { continue }
    $path = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Baseline support path'
    if (-not (Test-File $path ([long]$item.length) ([string]$item.sha256))) {
        $supportMismatches += $relative
    }
}

# Restore retains its existing state and backup validation path.
if ($Action -eq 'Install' -and $missingGameFiles.Count -gt 0) {
    throw ("[GAME_FILES_MISSING] 게임 파일이 누락되었습니다:`n" + ($missingGameFiles -join "`n") + "`nSteam → 속성 → 설치된 파일 → 게임 파일 무결성 검사 후 다시 설치해 주세요. 설치 위치도 확인해 주세요.")
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

if ($supportMismatches.Count -eq 0) {
    Write-InstallerLog 'CHECK' ('지원 게임 지문 확인 완료: 기준 파일 {0}개 일치' -f
        (@($baseline.files).Count - $manifestEntries.Count))
}
else {
    Write-InstallerLog 'WARN' ('지원 게임 지문 불일치: {0}개 파일' -f $supportMismatches.Count)
    foreach ($relative in $supportMismatches) {
        Write-InstallerLog 'WARN' ('변경된 기준 파일: {0}' -f $relative)
        $expectedSupport = $baselineByPath[$relative]
        $supportPath = Resolve-SafeRelativePath $resolvedGameRoot $relative 'Changed support path'
        $actualSupportLength = if (Test-Path -LiteralPath $supportPath -PathType Leaf) {
            [long](Get-Item -LiteralPath $supportPath).Length
        }
        else { 0 }
        $actualSupportHash = if (Test-Path -LiteralPath $supportPath -PathType Leaf) { Get-Sha256 $supportPath } else { '' }
        Write-InstallerLog 'INFO' ('  현재   -> {0} / SHA-256 {1}...' -f
            (Format-InstallerBytes $actualSupportLength), (Get-ShortHash $actualSupportHash))
        Write-InstallerLog 'INFO' ('  기대값 -> {0} / SHA-256 {1}...' -f
            (Format-InstallerBytes ([long]$expectedSupport.length)), (Get-ShortHash ([string]$expectedSupport.sha256)))
    }
    Write-InstallerLog 'WARN' '게임 업데이트 또는 외부 파일 변경이 감지되었습니다.'
}
foreach ($entry in $runtimeEntries) {
    $stateLabel = if ($entry.is_source) {
        '최신 원본'
    }
    elseif ($entry.is_result) {
        '현재 패치 결과'
    }
    elseif ($entry.can_known_upgrade) {
        '이전 패치 + 최신 원본 백업'
    }
    else {
        '미확인'
    }
    Write-InstallerLog 'SCAN' ('{0} -> {1} / {2} / SHA-256 {3}...' -f
        $entry.manifest.relative, $stateLabel, (Format-InstallerBytes $entry.current_length), (Get-ShortHash $entry.current_hash))
    Write-InstallerLog 'INFO' ('  기대 원본 -> {0} / SHA-256 {1}...' -f
        (Format-InstallerBytes $entry.manifest.source_length), (Get-ShortHash $entry.manifest.source_hash))
    Write-InstallerLog 'INFO' ('  기대 결과 -> {0} / SHA-256 {1}...' -f
        (Format-InstallerBytes $entry.manifest.result_length), (Get-ShortHash $entry.manifest.result_hash))
    if (-not $entry.known_state) {
        $backupLabel = if ([string]::IsNullOrWhiteSpace([string]$entry.source_backup)) { '없음' } else { '사용 가능' }
        Write-InstallerLog 'WARN' ('  최신 원본 백업 -> {0}' -f $backupLabel)
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
    $statusLabel = switch ($statusName) {
        'original' { '원본' }
        'patched' { '패치 적용됨' }
        default { '미확인' }
    }
    Write-InstallerLog 'DONE' ('상태 확인 완료: {0}' -f $statusLabel)
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
    Write-InstallerLog 'LOCK' '설치기 단독 실행 잠금을 확보했습니다.'
    try {
    if ($null -eq $state -or $stateByPath.Count -eq 0) {
        $allSource = @($runtimeEntries | Where-Object { -not $_.is_source }).Count -eq 0
        if ($allSource) {
            Write-InstallerLog 'DONE' '모든 대상이 기록된 원본과 이미 일치합니다.'
            Write-Result ([PSCustomObject]@{ action = 'Restore'; status = 'already-original'; target_count = $runtimeEntries.Count })
            return
        }
        throw '[BACKUP_MISSING] 복원에 사용할 검증된 설치 기록이 없습니다. .demons-timeline-ko-backup 폴더를 보존해 주세요. Steam 게임 파일 무결성 검사로 공식 원본을 복구할 수 있습니다.'
    }

    $restoreEntries = @()
    $expectedRestoreTargets = @()
    foreach ($entry in $runtimeEntries) {
        $stateEntry = $entry.state_entry
        if ($null -eq $stateEntry) { throw '설치 상태에 모든 릴리스 대상이 기록되어 있지 않습니다.' }
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
            Write-InstallerLog 'SCAN' ('복원 불필요: {0}' -f $entry.manifest.relative)
            continue
        }
        if (-not $entry.current_exists -or $entry.current_length -ne $installedLength -or $entry.current_hash -ne $installedHash) {
            throw "[RESTORE_CHANGED] 복원 대상이 누락되었거나 설치 기록 이후 변경되었습니다: $($entry.manifest.relative)`n다른 변경을 덮어쓰지 않도록 복원을 중단했습니다. 백업 폴더를 보존하고 제작자에게 문의하거나 Steam 무결성 검사로 원본을 복구해 주세요."
        }
        $backup = Find-Backup $backupRootFull $entry.manifest.relative $originalLength $originalHash $stateEntry
        if ([string]::IsNullOrWhiteSpace([string]$backup)) {
            throw "[BACKUP_INVALID] 검증된 복원 백업이 없거나 손상되었습니다: $($entry.manifest.relative)`n백업 폴더를 삭제하지 말고 제작자에게 오류 내역을 전달해 주세요. Steam 무결성 검사로 공식 원본을 복구할 수 있습니다."
        }
        Write-InstallerLog 'BACKUP' ('검증된 복원 원본: {0} / SHA-256 {1}...' -f
            $entry.manifest.relative, (Get-ShortHash $originalHash))
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
    Write-InstallerLog 'CHECK' ('복원 계획 준비 완료: 교체 {0}개, 최종 검증 대상 {1}개' -f $restoreEntries.Count, $expectedRestoreTargets.Count)
    if ($restoreEntries.Count -gt 0 -and (Test-GameRunningForRoot $resolvedGameRoot)) {
        throw '[GAME_RUNNING] 원본 파일을 복원하기 전에 게임을 종료해 주세요.'
    }

    $operations = @()
    $replacementCount = 0
    try {
        foreach ($entry in $restoreEntries) {
            $parent = Split-Path -Parent $entry.target
            $stage = Join-Path $parent ('.restore-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $rollback = Join-Path $parent ('.restore-rollback-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Write-InstallerLog 'STAGE' ('원본 준비 [{0}/{1}]: {2}' -f
                ($replacementCount + 1), $restoreEntries.Count, $entry.manifest.relative)
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
                throw "검증 후 복원 대상이 변경되었습니다: $($entry.manifest.relative)"
            }
            if (Test-GameRunningForRoot $resolvedGameRoot) {
                throw '복원을 준비하는 동안 게임이 실행되었습니다.'
            }
            Write-InstallerLog 'WRITE' ('검증된 원본으로 교체: {0}' -f $entry.manifest.relative)
            [IO.File]::Replace($stage, $entry.target, $rollback, $true)
            $operation.replaced = $true
            $replacementCount++
            if (-not (Test-File $entry.target $entry.original_length $entry.original_hash)) {
                throw '복원 후 검증에 실패했습니다.'
            }
            Write-InstallerLog 'VERIFY' ('복원 대상 검증 완료: {0} / {1} / SHA-256 {2}...' -f
                $entry.manifest.relative, (Format-InstallerBytes $entry.original_length), (Get-ShortHash $entry.original_hash))
            if ($TestFailureAfterReplace -or
                ($TestFailureAfterReplaceCount -gt 0 -and $replacementCount -eq $TestFailureAfterReplaceCount)) {
                throw 'Simulated post-replacement failure.'
            }
        }
        foreach ($expected in $expectedRestoreTargets) {
            if (-not (Test-File $expected.target $expected.length $expected.hash)) {
                throw "전체 복원 결과 최종 검증에 실패했습니다: $($expected.relative)"
            }
        }
        Write-InstallerLog 'VERIFY' ('전체 복원 결과 최종 검증 통과: {0}개 대상' -f $expectedRestoreTargets.Count)
        Write-InstallerLog 'STATE' '검증된 설치 상태를 정리합니다.'
        Remove-Item -LiteralPath $statePath -Force
        Write-InstallerLog 'STATE' '복원 성공 후 설치 상태를 정리했습니다.'
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $primaryError = $_
        Write-InstallerLog 'ERROR' ('마지막 표시 단계에서 복원 실패: {0}' -f $primaryError.Exception.Message)
        Write-InstallerLog 'ROLLBACK' ('완료된 교체 {0}개를 되돌립니다.' -f $replacementCount)
        try { Invoke-Rollback $operations }
        catch {
            throw ('복원 실패: {0} 롤백도 실패했습니다: {1}' -f
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
    Write-InstallerLog 'DONE' ('복원 완료: 대상 {0}개 검증 완료' -f $runtimeEntries.Count)
    Write-Result ([PSCustomObject]@{ action = 'Restore'; status = 'restored'; target_count = $runtimeEntries.Count })
    return
    }
    catch {
        Write-InstallerLog 'ERROR' ('마지막 표시 단계 이후 복원 중단: {0}' -f $_.Exception.Message)
        throw
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
        throw '패치 파일은 있지만 검증된 복원 상태가 불완전합니다. Steam 파일 무결성 검사를 실행한 뒤 다시 설치해 주세요.'
    }
    Write-InstallerLog 'DONE' '패치 파일과 검증된 복원 상태가 이미 최신입니다.'
    Write-Result ([PSCustomObject]@{
        action = 'Install'
        status = 'already-installed'
        target_count = $runtimeEntries.Count
        supported_build = ($supportMismatches.Count -eq 0)
    })
    return
}

$installMutex = Enter-InstallerMutex $resolvedGameRoot
Write-InstallerLog 'LOCK' '설치기 단독 실행 잠금을 확보했습니다.'
Write-InstallerLog 'PHASE' '2/7 사전 점검: 실행 중인 게임, 파일 출처, 사용자 동의, 디스크 공간'
try {
if (Test-GameRunningForRoot $resolvedGameRoot) {
    throw '[GAME_RUNNING] 한국어 패치를 설치하기 전에 게임을 종료해 주세요.'
}

Write-InstallerLog 'CHECK' '실행 중인 게임 확인 통과'
$knownTargets = @($runtimeEntries | Where-Object { -not $_.known_state }).Count -eq 0
$forced = $supportMismatches.Count -ne 0 -or -not $knownTargets
if ($forced) {
    Write-InstallerLog 'WARN' ('강행 설치 확인 필요: 기준 파일 불일치={0}, 미확인 대상={1}' -f
        $supportMismatches.Count, @($runtimeEntries | Where-Object { -not $_.known_state }).Count)
    Write-InstallerLog 'WARN' '위의 변경 파일과 기대값/현재값 해시를 확인하십시오.'
    if ($Json) {
        throw '[GAME_FILES_CHANGED] 게임 파일이 지원 기준과 다릅니다. 자동 설치를 중단했습니다. 게임 위치와 최신 패치 여부를 확인해 주세요. 강행하려면 대화형 y/N 동의가 필요합니다.'
    }
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host '[GAME_FILES_CHANGED] 게임 파일이 패치의 지원 기준과 일치하지 않습니다.' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ''
    Write-Host '게임이 업데이트되었거나 다른 패치·모드로 파일이 변경된 상태일 수 있습니다.'
    Write-Host '파일 차이만으로 실제 게임 버전 변경을 확정할 수는 없습니다.'
    Write-Host 'Steam에서 연 게임 폴더인지 확인하고, 최신 패치를 사용해 주세요. 계속되면 위의 변경 파일/미확인 파일 내역을 제작자에게 전달해 주세요.'
    Write-Host ''
    Write-Host '계속 설치하면 게임이 실행되지 않거나 한국어 표시가 깨질 수 있습니다.' -ForegroundColor Red
    Write-Host '패치의 최신 버전이 있는지 먼저 확인해 주세요.'
    Write-Host ''
    Write-Host '그래도 위험을 감수하고 설치를 강행하시겠습니까? (y/N)' -ForegroundColor Red
    $answer = Read-Host
    if ($answer.Trim().ToLowerInvariant() -ne 'y') {
        Write-InstallerLog 'DONE' '사용자가 강행 설치를 거부했습니다. 대상 파일은 교체하지 않았습니다.'
        Write-Result ([PSCustomObject]@{
            action = 'Install'
            status = 'cancelled'
            forced = $false
            target_count = $runtimeEntries.Count
        })
        return
    }
    Write-InstallerLog 'WARN' '명시적인 y 동의를 받았습니다. 사전 준비와 롤백 보호는 계속 적용됩니다.'
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
    throw ('[DISK_SPACE] 게임 드라이브의 여유 공간이 부족합니다. 필요: {0:N0}바이트 / 사용 가능: {1:N0}바이트. 공간을 확보한 뒤 다시 실행해 주세요. 복원 백업은 삭제하지 마세요.' -f ($requiredBytes + 16MB), $drive.AvailableFreeSpace)
}

$prepared = @()
Write-InstallerLog 'CHECK' ('디스크 공간 점검 통과: 필요 {0}, 사용 가능 {1}' -f
    (Format-InstallerBytes ($requiredBytes + 16MB)), (Format-InstallerBytes $drive.AvailableFreeSpace))
Write-InstallerLog 'PHASE' '3/7 쓰기 전 모든 델타 결과 생성 및 검증'
try {
    foreach ($entry in $runtimeEntries) {
        if ($entry.is_result) {
            Write-InstallerLog 'SKIP' ('이미 최신 상태라 델타 적용 불필요: {0}' -f $entry.manifest.relative)
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
            throw "사용할 수 있는 델타 원본이 없습니다: $($entry.manifest.relative)"
        }

        $parent = Split-Path -Parent $entry.manifest.target
        $sourceDescription = if ($selectedSource -eq $entry.manifest.target) {
            if ($sourceWasExpected) { '현재 검증된 원본' } else { '현재 미검증 파일' }
        }
        elseif ($sourceWasExpected) {
            '검증된 최신 원본 백업'
        }
        else {
            '기록된 대체 백업'
        }
        Write-InstallerLog 'SOURCE' ('{0} <- {1}' -f $entry.manifest.relative, $sourceDescription)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "대상 디렉터리가 없습니다: $parent"
        }
        $stage = Join-Path $parent ('.ko-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        Write-InstallerLog 'DELTA' ('MSDelta 적용: {0} / 페이로드 {1}' -f
            $entry.manifest.relative, (Format-InstallerBytes $entry.manifest.delta_length))
        Invoke-MSDelta $selectedSource $entry.manifest.delta_path $stage
        $resultLength = [long](Get-Item -LiteralPath $stage).Length
        $resultHash = Get-Sha256 $stage
        if ($sourceWasExpected -and
            ($resultLength -ne $entry.manifest.result_length -or $resultHash -ne $entry.manifest.result_hash)) {
            throw "승인된 델타 결과 검증에 실패했습니다: $($entry.manifest.relative)"
        }
        if ($resultLength -le 0) { throw '강행한 델타 적용 결과가 빈 파일입니다.' }

        Write-InstallerLog 'VERIFY' ('준비된 결과 검증 완료: {0} / {1} / SHA-256 {2}...' -f
            $entry.manifest.relative, (Format-InstallerBytes $resultLength), (Get-ShortHash $resultHash))
        $prepared += [PSCustomObject]@{
            runtime = $entry
            stage = $stage
            result_length = $resultLength
            result_hash = $resultHash
            selected_source = $selectedSource
            source_was_expected = $sourceWasExpected
        }
    }

    Write-InstallerLog 'CHECK' ('모든 준비 결과 완료: 대상 {0}개' -f $prepared.Count)
    Write-InstallerLog 'PHASE' '4/7 내용 해시 기반 복원 백업 보존'
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
            throw "검증된 복원 원본을 사용할 수 없습니다: $($entry.manifest.relative)"
        }

        $expectedBackupObject = Join-Path (Join-Path $backupRootFull 'objects') ($originalHash + '.bin')
        $backupDisposition = if (Test-Path -LiteralPath $expectedBackupObject -PathType Leaf) { '재사용' } else { '생성' }

        $backupObject = Save-BackupObject $backupRootFull $originalPath $originalLength $originalHash
        $backupRelative = 'objects/' + [IO.Path]::GetFileName($backupObject)
        Write-InstallerLog 'BACKUP' ('복원 원본 저장: {0} / {1}' -f
            $entry.manifest.relative, (Format-InstallerBytes $originalLength))
        Write-InstallerLog 'BACKUP' ('백업 {0}: {1} / SHA-256 {2}...' -f
            $backupDisposition, $entry.manifest.relative, (Get-ShortHash $originalHash))
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
    Write-InstallerLog 'STATE' ('백업 매니페스트 저장: {0}' -f $backupManifestPath)
    Write-InstallerLog 'PHASE' '5/7 대상 파일 원자적 교체 및 각 쓰기 검증'

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
                throw '설치를 준비하는 동안 게임이 실행되었습니다.'
            }
            Write-InstallerLog 'WRITE' ('원자적 교체 [{0}/{1}]: {2}' -f ($replacementCount + 1), @($prepared | Where-Object { $null -ne $_.stage }).Count, $entry.manifest.relative)
            if ($entry.current_exists) {
                if (-not (Test-File $target $entry.current_length $entry.current_hash)) {
                    throw "준비 완료 후 설치 대상이 변경되었습니다: $($entry.manifest.relative)"
                }
                [IO.File]::Replace($item.stage, $target, $rollback, $true)
            }
            else {
                if (Test-Path -LiteralPath $target) {
                    throw "준비 완료 후 없던 설치 대상이 생성되었습니다: $($entry.manifest.relative)"
                }
                [IO.File]::Move($item.stage, $target)
            }
            $operation.replaced = $true
            $replacementCount++
            if (-not (Test-File $target $item.result_length $item.result_hash)) {
                throw '설치 후 결과 검증에 실패했습니다.'
            }
            Write-InstallerLog 'VERIFY' ('설치 대상 검증 완료: {0} / SHA-256 {1}...' -f
                $entry.manifest.relative, (Get-ShortHash $item.result_hash))
            if ($TestFailureAfterReplace -or
                ($TestFailureAfterReplaceCount -gt 0 -and $replacementCount -eq $TestFailureAfterReplaceCount)) {
                throw 'Simulated post-replacement failure.'
            }
        }

        Write-InstallerLog 'PHASE' '6/7 전체 설치 대상 최종 검증'
        foreach ($item in $prepared) {
            if (-not (Test-File $item.runtime.manifest.target $item.result_length $item.result_hash)) {
                throw "전체 설치 결과 최종 검증에 실패했습니다: $($item.runtime.manifest.relative)"
            }
        }
        Write-InstallerLog 'VERIFY' ('전체 설치 결과 최종 검증 통과: 대상 {0}개' -f $prepared.Count)
        Write-InstallerLog 'PHASE' '7/7 검증된 설치 상태 저장'
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
        Write-InstallerLog 'STATE' ('설치 상태 저장: {0}' -f $statePath)
        foreach ($operation in $operations) {
            Remove-Item -LiteralPath $operation.rollback -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $primaryError = $_
        Write-InstallerLog 'ERROR' ('마지막 표시 단계에서 설치 실패: {0}' -f $primaryError.Exception.Message)
        Write-InstallerLog 'ROLLBACK' ('완료된 교체 {0}개를 되돌립니다.' -f $replacementCount)
        try { Invoke-Rollback $operations }
        catch {
            throw ('설치 실패: {0} 롤백도 실패했습니다: {1}' -f
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

    $forcedLabel = if ($forced) { 'True' } else { 'False' }
    Write-InstallerLog 'DONE' ('설치 완료: 대상 {0}개, 강행 설치={1}' -f $runtimeEntries.Count, $forcedLabel)
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
catch {
    Write-InstallerLog 'ERROR' ('마지막 표시 단계 이후 설치 중단: {0}' -f $_.Exception.Message)
    throw
}
finally {
    Exit-InstallerMutex $installMutex
}
