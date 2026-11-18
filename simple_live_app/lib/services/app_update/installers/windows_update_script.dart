/// Windows 的更新脚本（PowerShell 5.1）。App 每次更新时把它写进缓存目录再运行，
/// 路径全部从参数传进去，文本里不写任何本机的路径。
///
/// 只能用 ASCII：没有 BOM 的 .ps1 会按系统代码页（GBK）读，中文会把后面的行吞掉。
/// 测试（app_update_installers_test.dart）检查这一点，写文件时也用 ascii 编码。
const String windowsUpdateScript = r'''
# SimpleLive updater for Windows. The app writes this file and starts it.
# ASCII only: Windows PowerShell 5.1 reads a file without BOM in the ANSI code page.
# Every path comes in as an argument; nothing about this machine is written here.
#
# -Mode install  : wait for the app to exit, back up InstallDir, copy NewDir over it
#                  and start the new version. On an error the backup is put back and
#                  the old version is started.
# -Mode rollback : put back the backup kept by the last install and start it.
# -Elevate       : do the work in an elevated copy of this script (one UAC prompt) and
#                  start the app from here, so the app never runs elevated.
# -DryRun        : for tests: no waiting for the app and no starting it.
param(
    [ValidateSet('install', 'rollback')]
    [string]$Mode = 'install',
    [string]$InstallDir = '',
    [string]$ExePath = '',
    [string]$NewDir = '',
    [string]$NewExe = 'simple_live_app.exe',
    [string]$BackupRoot = '',
    [string]$OldVersion = '',
    [string]$LogFile = '',
    [string]$StatusFile = '',
    [int]$TimeoutSec = 120,
    [switch]$Elevate,
    [switch]$Worker,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$Retries = 10
$AddedListName = 'added-files.txt'
$BackupParentName = 'SimpleLive-backup'

function Write-Log([string]$Text) {
    if (-not $LogFile) { return }
    try {
        $role = 'main'
        if ($Worker) { $role = 'worker' } elseif ($Elevate) { $role = 'launcher' }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [' + $Mode + '/' + $role + '] ' + $Text
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($LogFile))
        $info = New-Object System.IO.FileInfo($LogFile)
        if ($info.Exists -and $info.Length -gt 1MB) {
            $old = $LogFile + '.old'
            if ([System.IO.File]::Exists($old)) { [System.IO.File]::Delete($old) }
            [System.IO.File]::Move($LogFile, $old)
        }
        [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
    } catch {}
}

function Set-Status([string]$Text) {
    if (-not $StatusFile) { return }
    try {
        [System.IO.File]::WriteAllText($StatusFile, $Text)
    } catch {
        Write-Log ('status not written: ' + $_.Exception.Message)
    }
}

function Get-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

# Is Path equal to Root or inside it
function Test-Inside([string]$Path, [string]$Root) {
    $a = $Path.TrimEnd('\') + '\'
    $b = $Root.TrimEnd('\') + '\'
    return $a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeFiles([string]$Root) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not [System.IO.Directory]::Exists($Root)) { return ,$list }
    $prefix = $Root.TrimEnd('\') + '\'
    foreach ($file in [System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)) {
        $list.Add($file.Substring($prefix.Length))
    }
    return ,$list
}

function Clear-ReadOnly([string]$Path) {
    if ([System.IO.File]::Exists($Path)) {
        $attr = [System.IO.File]::GetAttributes($Path)
        if (($attr -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            [System.IO.File]::SetAttributes($Path, ($attr -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
        }
    }
}

# Files can stay locked for a moment after the app exits: retry for about 5 s
function Copy-OneFile([string]$Source, [string]$Target) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Target))
    for ($i = 1; ; $i++) {
        try {
            Clear-ReadOnly $Target
            [System.IO.File]::Copy($Source, $Target, $true)
            return
        } catch {
            if ($i -ge $Retries) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Remove-OneFile([string]$Path) {
    for ($i = 1; ; $i++) {
        try {
            if ([System.IO.File]::Exists($Path)) {
                Clear-ReadOnly $Path
                [System.IO.File]::Delete($Path)
            }
            return
        } catch {
            if ($i -ge $Retries) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Copy-Tree([string]$From, [string]$To) {
    foreach ($rel in (Get-RelativeFiles $From)) {
        Copy-OneFile ([System.IO.Path]::Combine($From, $rel)) ([System.IO.Path]::Combine($To, $rel))
    }
}

function Remove-Tree([string]$Path) {
    if ([System.IO.Directory]::Exists($Path)) {
        foreach ($file in [System.IO.Directory]::GetFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) {
            Clear-ReadOnly $file
        }
        [System.IO.Directory]::Delete($Path, $true)
    } elseif ([System.IO.File]::Exists($Path)) {
        Remove-OneFile $Path
    }
}

function Find-Backup {
    if (-not [System.IO.Directory]::Exists($BackupRoot)) { return '' }
    foreach ($dir in [System.IO.Directory]::GetDirectories($BackupRoot)) {
        if ($dir.EndsWith('.partial', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([System.IO.File]::Exists([System.IO.Path]::Combine($dir, $ExeName))) { return $dir }
    }
    return ''
}

function Test-Arguments {
    if (-not $InstallDir -or -not $ExePath -or -not $BackupRoot -or -not $LogFile) { return 'missing arguments' }
    if (-not [System.IO.Directory]::Exists($InstallDir)) { return 'install folder not found' }
    if (-not [System.IO.File]::Exists($ExePath)) { return 'app exe not found' }
    if ((Get-FullPath ([System.IO.Path]::GetDirectoryName($ExePath))) -ne $InstallDir) { return 'exe is not in the install folder' }
    if ([System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($BackupRoot)) -ne $BackupParentName) { return 'unexpected backup folder' }
    if ((Test-Inside $BackupRoot $InstallDir) -or (Test-Inside $InstallDir $BackupRoot)) { return 'backup folder overlaps the install folder' }
    if ($Mode -eq 'install') {
        if ($OldVersion -notmatch '^[0-9A-Za-z._+-]+$') { return 'bad old version' }
        if (-not $NewDir -or -not [System.IO.File]::Exists([System.IO.Path]::Combine($NewDir, $NewExe))) { return 'new files not found' }
        if ((Test-Inside $NewDir $InstallDir) -or (Test-Inside $InstallDir $NewDir)) { return 'new folder overlaps the install folder' }
    } elseif (-not (Find-Backup)) {
        return 'no backup found'
    }
    return ''
}

function Get-AppProcessIds {
    $ids = @()
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $proc.Path } catch {}
        if ($path -and [string]::Equals([System.IO.Path]::GetFullPath($path), $ExePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ids += $proc.Id
        }
    }
    return ,$ids
}

# Only processes started from this install's exe count; other SimpleLive folders are ignored
function Wait-AppExit {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $ids = Get-AppProcessIds
        if ($ids.Count -eq 0) { return $true }
        if ((Get-Date) -gt $deadline) {
            Write-Log ('app still running after ' + $TimeoutSec + ' s: ' + ($ids -join ','))
            return $false
        }
        Start-Sleep -Milliseconds 500
    }
}

# Delete the files the update added, then copy the backup over the install folder
function Restore-Backup([string]$Backup, $Added) {
    foreach ($rel in $Added) {
        if (-not $rel) { continue }
        $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($InstallDir, $rel))
        if ((Test-Inside $path $InstallDir) -and ($path.Length -gt $InstallDir.Length)) {
            Remove-OneFile $path
        }
    }
    Copy-Tree $Backup $InstallDir
}

# Keeps only the newest backup: build it beside the old one, then drop the old one
function Save-Backup {
    $final = [System.IO.Path]::Combine($BackupRoot, $OldVersion)
    $partial = $final + '.partial'
    [void][System.IO.Directory]::CreateDirectory($BackupRoot)
    Remove-Tree $partial
    [void][System.IO.Directory]::CreateDirectory($partial)
    Copy-Tree $InstallDir $partial
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($BackupRoot)) {
        if (-not [string]::Equals($entry, $partial, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Tree $entry
        }
    }
    [System.IO.Directory]::Move($partial, $final)
    return $final
}

function Invoke-Install {
    $backup = Save-Backup
    Write-Log ('backup: ' + $backup)
    $newFiles = Get-RelativeFiles $NewDir
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $newFiles) {
        if (-not [System.IO.File]::Exists([System.IO.Path]::Combine($InstallDir, $rel))) { $added.Add($rel) }
    }
    [System.IO.File]::WriteAllLines([System.IO.Path]::Combine($BackupRoot, $AddedListName), [string[]]$added.ToArray())
    try {
        Copy-Tree $NewDir $InstallDir
        Write-Log ('copied ' + $newFiles.Count + ' files, ' + $added.Count + ' of them new')
        return 'ok'
    } catch {
        Write-Log ('copy failed: ' + $_.Exception.Message)
        Restore-Backup $backup $added
        Write-Log 'old version restored'
        return 'restored'
    }
}

function Invoke-Rollback {
    $backup = Find-Backup
    if (-not $backup) { throw 'no backup found' }
    $listFile = [System.IO.Path]::Combine($BackupRoot, $AddedListName)
    $added = @()
    if ([System.IO.File]::Exists($listFile)) { $added = [System.IO.File]::ReadAllLines($listFile) }
    # A copy of the current files, put back if the rollback fails halfway
    $current = [System.IO.Path]::Combine($BackupRoot, 'current.partial')
    Remove-Tree $current
    [void][System.IO.Directory]::CreateDirectory($current)
    Copy-Tree $InstallDir $current
    try {
        Restore-Backup $backup $added
    } catch {
        Write-Log ('rollback failed: ' + $_.Exception.Message)
        Copy-Tree $current $InstallDir
        Remove-Tree $current
        Write-Log 'current version kept'
        return 'restored'
    }
    # The backup is the running version now
    Remove-Tree $BackupRoot
    $parent = [System.IO.Path]::GetDirectoryName($BackupRoot)
    if ([System.IO.Directory]::Exists($parent) -and [System.IO.Directory]::GetFileSystemEntries($parent).Count -eq 0) {
        [System.IO.Directory]::Delete($parent)
    }
    Write-Log ('rolled back to ' + [System.IO.Path]::GetFileName($backup))
    return 'ok'
}

function Get-StartPath([string]$Result) {
    if ($Result -eq 'busy') { return '' }
    if ($Mode -eq 'install' -and $Result -eq 'ok') { return [System.IO.Path]::Combine($InstallDir, $NewExe) }
    return $ExePath
}

function Start-App([string]$Path) {
    if (-not $Path) { return }
    if ($DryRun) {
        Write-Log ('dry run, would start ' + $Path)
        return
    }
    if (-not [System.IO.File]::Exists($Path)) {
        Write-Log ('not found: ' + $Path)
        return
    }
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $Path
        $info.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Path)
        $info.UseShellExecute = $true
        [void][System.Diagnostics.Process]::Start($info)
        Write-Log ('started ' + $Path)
    } catch {
        Write-Log ('start failed: ' + $_.Exception.Message)
    }
}

# Start-Process joins the list with spaces, so every path is quoted.
# Folder paths never end with a backslash here, which would escape the quote.
function Format-Argument([string]$Value) {
    return '"' + $Value + '"'
}

# UAC once for the worker; the app is started from this unelevated process afterwards
function Invoke-Elevated {
    $list = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (Format-Argument $ScriptPath),
        '-Mode', $Mode,
        '-InstallDir', (Format-Argument $InstallDir),
        '-ExePath', (Format-Argument $ExePath),
        '-NewExe', (Format-Argument $NewExe),
        '-BackupRoot', (Format-Argument $BackupRoot),
        '-LogFile', (Format-Argument $LogFile),
        '-StatusFile', (Format-Argument $StatusFile),
        '-TimeoutSec', [string]$TimeoutSec,
        '-Worker')
    if ($NewDir) { $list += @('-NewDir', (Format-Argument $NewDir)) }
    if ($OldVersion) { $list += @('-OldVersion', (Format-Argument $OldVersion)) }
    if ($DryRun) { $list += '-DryRun' }
    Set-Status 'elevating'
    try {
        $shell = [System.IO.Path]::Combine($PSHOME, 'powershell.exe')
        $proc = Start-Process -FilePath $shell -Verb RunAs -WindowStyle Hidden -ArgumentList $list -PassThru
    } catch {
        Write-Log ('elevation refused: ' + $_.Exception.Message)
        Set-Status 'declined'
        return
    }
    Write-Log 'elevated worker started'
    $proc.WaitForExit()
    $status = ''
    try { $status = [System.IO.File]::ReadAllText($StatusFile).Trim() } catch {}
    Write-Log ('worker finished: ' + $status)
    # Anything but done:... means the app was never told to quit
    if ($status.StartsWith('done:')) {
        Start-App (Get-StartPath $status.Substring(5))
    }
}

if ($InstallDir) { $InstallDir = Get-FullPath $InstallDir }
if ($ExePath) { $ExePath = [System.IO.Path]::GetFullPath($ExePath) }
if ($NewDir) { $NewDir = Get-FullPath $NewDir }
if ($BackupRoot) { $BackupRoot = Get-FullPath $BackupRoot }
$ExeName = [System.IO.Path]::GetFileName($ExePath)

$problem = ''
try { $problem = Test-Arguments } catch { $problem = $_.Exception.Message }
if ($problem) {
    Write-Log ('refused: ' + $problem)
    Set-Status ('error: ' + $problem)
    exit 3
}

if ($Elevate -and -not $Worker) {
    Invoke-Elevated
    exit 0
}

Set-Status 'started'
Write-Log ('start: ' + $InstallDir)
$result = 'failed'
try {
    if ($DryRun -or (Wait-AppExit)) {
        if (-not $DryRun) { Start-Sleep -Milliseconds 800 }
        if ($Mode -eq 'install') { $result = Invoke-Install } else { $result = Invoke-Rollback }
    } else {
        $result = 'busy'
    }
} catch {
    Write-Log ('failed: ' + $_.Exception.Message)
    $result = 'failed'
}
if ($Mode -eq 'install' -and $result -ne 'busy' -and $NewDir) {
    try { Remove-Tree $NewDir } catch { Write-Log ('cleanup failed: ' + $_.Exception.Message) }
}
Set-Status ('done:' + $result)
Write-Log ('result: ' + $result)
if (-not $Worker) { Start-App (Get-StartPath $result) }
if ($result -eq 'ok') { exit 0 }
exit 1
''';
