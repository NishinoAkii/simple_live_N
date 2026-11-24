/// Windows 的更新脚本（PowerShell 5.1）。App 每次更新时把它写进缓存目录再运行，
/// 路径全部从参数传进去，文本里不写任何本机的路径；窗口里的字从文件传进去（-TextFile）。
///
/// App 启动的这一份（-Ui）只显示窗口：进度、装完后问要不要打开 App；干活的是它再启动的一份
/// （-Worker，要管理员权限时这一份弹 UAC），两份靠状态、进度两个文件联系。
///
/// 换文件之前先留备份、写下“正在换”的标记；换到一半停了（出错、脚本被结束），从备份换回来。
/// 一个文件被别的程序占着、删不掉，只影响它自己，不会让整次更新或换回停在一半。
/// 同一个安装文件夹同一时间只有一份脚本在干活。
///
/// 只能用 ASCII：没有 BOM 的 .ps1 会按系统代码页（GBK）读，中文会把后面的行吞掉。
/// 测试（app_update_installers_test.dart）检查这一点，写文件时也用 ascii 编码。
const String windowsUpdateScript = r'''
# SimpleLive updater for Windows. The app writes this file and starts it.
# ASCII only: Windows PowerShell 5.1 reads a file without BOM in the ANSI code page.
# Every path comes in as an argument; nothing about this machine is written here.
# The texts of the window come from TextFile (UTF-8, one key=value per line).
#
# -Mode install  : unpack ZipFile into NewDir (when a ZipFile is given), tell the app to
#                  quit, wait for it, back up the files that change, copy the new ones over
#                  InstallDir and start the new version. On an error the backup is put back
#                  and the old version is started.
# -Mode rollback : put back the backup kept by the last install and start it.
# -Mode repair   : put back the backup of an install that was cut off while copying.
# -Ui            : do the work in a second copy of this script (-Worker), show its progress
#                  in a window and ask there whether to open the app.
# -Elevate       : the second copy runs elevated (one UAC prompt). The app is started from
#                  the first one, so it never runs elevated.
# -DryRun        : for tests: no waiting for the app and no starting it.
param(
    [ValidateSet('install', 'rollback', 'repair')]
    [string]$Mode = 'install',
    [string]$InstallDir = '',
    [string]$ExePath = '',
    [string]$ZipFile = '',
    [string]$NewDir = '',
    [string]$NewExe = 'simple_live_app.exe',
    [string]$BackupRoot = '',
    [string]$OldVersion = '',
    [string]$LogFile = '',
    [string]$StatusFile = '',
    [string]$ProgressFile = '',
    [string]$TextFile = '',
    [int]$TimeoutSec = 120,
    [switch]$Ui,
    [switch]$Elevate,
    [switch]$Worker,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
# Started by PowerShell 7 somewhere up the chain, its module folder would come first
$env:PSModulePath = [System.IO.Path]::Combine($PSHOME, 'Modules')
$ScriptPath = $MyInvocation.MyCommand.Path
$Retries = 10
$BackupParentName = 'SimpleLive-backup'
# In BackupRoot: which backup is the good one, and the one an unfinished install can be put back from
$CurrentName = 'current.txt'
$MarkerName = 'update-in-progress.txt'
# Added files of backups made before 1.27.4 (now <backup>.added.txt)
$OldAddedName = 'added-files.txt'
$ProgressAt = 0
$ProgressPhase = ''

function Write-Log([string]$Text) {
    if (-not $LogFile) { return }
    try {
        $role = 'main'
        if ($Worker) { $role = 'worker' } elseif ($Ui) { $role = 'window' } elseif ($Elevate) { $role = 'launcher' }
        $line = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + ' [' + $Mode + '/' + $role + '] ' + $Text
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
    for ($i = 1; ; $i++) {
        try {
            [System.IO.File]::WriteAllText($StatusFile, $Text)
            return
        } catch {
            # The app or the window may be reading it
            if ($i -ge 20) {
                Write-Log ('status not written: ' + $_.Exception.Message)
                return
            }
            [System.Threading.Thread]::Sleep(50)
        }
    }
}

function Get-Status {
    if (-not $StatusFile -or -not [System.IO.File]::Exists($StatusFile)) { return '' }
    for ($i = 1; $i -le 5; $i++) {
        try { return [System.IO.File]::ReadAllText($StatusFile).Trim() } catch { [System.Threading.Thread]::Sleep(30) }
    }
    return ''
}

# What the worker is doing, for the window: "phase done total"
function Set-Progress([string]$Phase, [double]$Done, [double]$Total) {
    if (-not $ProgressFile) { return }
    $now = [Environment]::TickCount
    if ($Phase -eq $script:ProgressPhase -and $Done -lt $Total -and [Math]::Abs($now - $script:ProgressAt) -lt 80) { return }
    $script:ProgressPhase = $Phase
    $script:ProgressAt = $now
    try {
        [System.IO.File]::WriteAllText($ProgressFile, ('{0} {1:0} {2:0}' -f $Phase, $Done, $Total))
    } catch {}
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

# Files can stay locked for a moment after the app exits: retry for about 5 s.
# Written beside the target and moved over it, so a failure never leaves half a file
function Copy-OneFile([string]$Source, [string]$Target, [int]$Tries = $Retries) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Target))
    $temp = $Target + '.slnew'
    for ($i = 1; ; $i++) {
        try {
            Clear-ReadOnly $temp
            [System.IO.File]::Copy($Source, $temp, $true)
            Clear-ReadOnly $temp
            Move-Over $temp $Target
            return
        } catch {
            if ($i -ge $Tries) {
                try { [System.IO.File]::Delete($temp) } catch {}
                throw
            }
            [System.Threading.Thread]::Sleep(500)
        }
    }
}

# Replaces To in one step
function Move-Over([string]$From, [string]$To) {
    if (-not [System.IO.File]::Exists($To)) {
        [System.IO.File]::Move($From, $To)
        return
    }
    Clear-ReadOnly $To
    [Microsoft.VisualBasic.FileIO.FileSystem]::MoveFile($From, $To, $true)
}

function Get-FileHashText([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)) } finally { $stream.Dispose(); $sha.Dispose() }
}

# Same content. A file that cannot be read counts as different
function Test-Same([string]$A, [string]$B) {
    try {
        if (-not [System.IO.File]::Exists($A) -or -not [System.IO.File]::Exists($B)) { return $false }
        if ((New-Object System.IO.FileInfo($A)).Length -ne (New-Object System.IO.FileInfo($B)).Length) { return $false }
        return (Get-FileHashText $A) -eq (Get-FileHashText $B)
    } catch {
        return $false
    }
}

# Copies the listed files that differ. One that fails does not stop the others and is tried again.
# Returns the ones that are still different
function Copy-Changed([string]$From, [string]$To, $List, [string]$Phase) {
    $left = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($rel in $List) { $count++ }
    $done = 0
    foreach ($rel in $List) {
        $source = [System.IO.Path]::Combine($From, $rel)
        $target = [System.IO.Path]::Combine($To, $rel)
        if (-not (Test-Same $source $target)) {
            try { Copy-OneFile $source $target 2 } catch { $left.Add($rel) }
        }
        $done++
        Set-Progress $Phase $done $count
    }
    for ($round = 1; $round -le 12 -and $left.Count -gt 0; $round++) {
        [System.Threading.Thread]::Sleep(500)
        $again = New-Object System.Collections.Generic.List[string]
        foreach ($rel in $left) {
            $source = [System.IO.Path]::Combine($From, $rel)
            $target = [System.IO.Path]::Combine($To, $rel)
            if (Test-Same $source $target) { continue }
            try { Copy-OneFile $source $target 1 } catch { $again.Add($rel) }
        }
        $left = $again
    }
    foreach ($rel in $left) { Write-Log ('not copied: ' + $rel) }
    return ,$left
}

# For cleaning up: never decides anything
function Remove-Quietly([string]$Path) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Remove-Tree $Path
            return
        } catch {
            if ($i -eq 3) { Write-Log ('left behind: ' + $Path + ' (' + $_.Exception.Message + ')') } else { [System.Threading.Thread]::Sleep(500) }
        }
    }
}

# The app's exe opened so that nobody can start it; $null when that is not possible
function Open-Exclusive([string]$Path) {
    for ($i = 1; $i -le 6; $i++) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        } catch {
            [System.Threading.Thread]::Sleep(300)
        }
    }
    return $null
}

# The first file of Manifest (name -> length) that is missing in Root or has another size; empty when all are there
function Find-Missing([string]$Root, $Manifest) {
    foreach ($rel in (Get-Names $Manifest)) {
        $info = New-Object System.IO.FileInfo([System.IO.Path]::Combine($Root, $rel))
        if (-not $info.Exists -or $info.Length -ne $Manifest[$rel]) { return $rel }
    }
    return ''
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
            [System.Threading.Thread]::Sleep(500)
        }
    }
}

# Copies the files in List (relative paths); the progress goes by size
function Copy-Files([string]$From, [string]$To, $List, [string]$Phase) {
    $total = 0.0
    $sizes = @{}
    foreach ($rel in $List) {
        $size = (New-Object System.IO.FileInfo([System.IO.Path]::Combine($From, $rel))).Length
        $sizes[$rel] = $size
        $total += $size
    }
    $done = 0.0
    Set-Progress $Phase 0 $total
    foreach ($rel in $List) {
        Copy-OneFile ([System.IO.Path]::Combine($From, $rel)) ([System.IO.Path]::Combine($To, $rel))
        $done += $sizes[$rel]
        Set-Progress $Phase $done $total
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

function Read-Line([string]$Name) {
    try { return [System.IO.File]::ReadAllText([System.IO.Path]::Combine($BackupRoot, $Name)).Trim() } catch { return '' }
}

# A finished backup: no .building beside it, and the app's exe in it
function Test-Backup([string]$Dir) {
    if ($Dir.EndsWith('.partial', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([System.IO.File]::Exists($Dir + '.building')) { return $false }
    return [System.IO.File]::Exists([System.IO.Path]::Combine($Dir, $ExeName))
}

# The backup named in a file of BackupRoot; empty when there is none or it is not finished.
# The name is one folder in BackupRoot, nothing else
function Get-NamedBackup([string]$File) {
    $name = Read-Line $File
    if (-not $name -or $name -notmatch '^[0-9A-Za-z._+-]+$') { return '' }
    $dir = [System.IO.Path]::Combine($BackupRoot, $name)
    if (Test-Backup $dir) { return $dir }
    return ''
}

function Find-Backup {
    if (-not [System.IO.Directory]::Exists($BackupRoot)) { return '' }
    $dir = Get-NamedBackup $CurrentName
    if ($dir) { return $dir }
    foreach ($dir in [System.IO.Directory]::GetDirectories($BackupRoot)) {
        if (Test-Backup $dir) { return $dir }
    }
    return ''
}

# The files the update that made this backup added
function Get-Added([string]$Backup) {
    foreach ($file in @(($Backup + '.added.txt'), [System.IO.Path]::Combine($BackupRoot, $OldAddedName))) {
        if ([System.IO.File]::Exists($file)) { return ,[System.IO.File]::ReadAllLines($file) }
    }
    return ,[string[]]@()
}

function Clear-Marker {
    $file = [System.IO.Path]::Combine($BackupRoot, $MarkerName)
    try { Remove-OneFile $file } catch {
        # Empty means there is nothing to put back
        try { [System.IO.File]::WriteAllText($file, '') } catch { Write-Log ('marker left: ' + $_.Exception.Message) }
    }
}

# Where the new exe is in Root: Root itself or its only folder; empty when it is not there
function Find-NewFolder([string]$Root) {
    if ([System.IO.File]::Exists([System.IO.Path]::Combine($Root, $NewExe))) { return $Root }
    if (-not [System.IO.Directory]::Exists($Root)) { return '' }
    $dirs = [System.IO.Directory]::GetDirectories($Root)
    if ($dirs.Length -eq 1 -and [System.IO.File]::Exists([System.IO.Path]::Combine($dirs[0], $NewExe))) { return $dirs[0] }
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
        if ($OldVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') { return 'bad old version' }
        if (-not $NewDir) { return 'missing arguments' }
        if ($ZipFile) {
            if (-not [System.IO.File]::Exists($ZipFile)) { return 'package not found' }
            # NewDir is emptied before unpacking
            if (Test-Inside $ZipFile $NewDir) { return 'package is inside the new folder' }
        } elseif (-not (Find-NewFolder $NewDir)) {
            return 'new files not found'
        }
        if ((Test-Inside $NewDir $InstallDir) -or (Test-Inside $InstallDir $NewDir)) { return 'new folder overlaps the install folder' }
    } elseif ($Mode -eq 'repair') {
        if (-not (Get-NamedBackup $MarkerName)) { return 'nothing to repair' }
    } elseif (-not (Find-Backup)) {
        return 'no backup found'
    }
    return ''
}

function Get-AppProcessIds {
    $ids = @()
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    foreach ($proc in [System.Diagnostics.Process]::GetProcessesByName($name)) {
        $path = $null
        try { $path = $proc.MainModule.FileName } catch {}
        if ($path -and [string]::Equals([System.IO.Path]::GetFullPath($path), $ExePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ids += $proc.Id
        }
    }
    return ,$ids
}

# One updater per install folder at a time
function Enter-OnlyOne {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($InstallDir.ToLowerInvariant()))
    $name = 'Local\SimpleLiveUpdater-' + [System.BitConverter]::ToString($bytes, 0, 8).Replace('-', '')
    try {
        $script:OnlyOne = New-Object System.Threading.Mutex($false, $name)
        return $script:OnlyOne.WaitOne(0)
    } catch {
        # The one before was killed: it is ours now. Anything else: somebody with other rights has it
        $e = $_.Exception
        while ($e) {
            if ($e -is [System.Threading.AbandonedMutexException]) { return $true }
            $e = $e.InnerException
        }
        return $false
    }
}

# The app gave up waiting and went on: leave everything as it is
function Exit-IfCancelled {
    if ((Get-Status).StartsWith('cancelled')) {
        Write-Log 'cancelled by the app'
        if ($ZipFile) { try { Remove-Tree $NewDir } catch {} }
        exit 4
    }
}

# Only processes started from this install's exe count; other SimpleLive folders are ignored
function Wait-AppExit {
    Set-Progress 'wait' 0 0
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ($true) {
        $ids = Get-AppProcessIds
        if ($ids.Count -eq 0) { return $true }
        Exit-IfCancelled
        if ([DateTime]::Now -gt $deadline) {
            Write-Log ('app still running after ' + $TimeoutSec + ' s: ' + ($ids -join ','))
            return $false
        }
        [System.Threading.Thread]::Sleep(300)
    }
}

# Unpacks ZipFile into an empty NewDir; entries that would land outside it are refused
function Expand-Package {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression')
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    Remove-Tree $NewDir
    [void][System.IO.Directory]::CreateDirectory($NewDir)
    $sizes = @{}
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFile)
    try {
        $total = 0.0
        foreach ($entry in $zip.Entries) { $total += $entry.Length }
        $done = 0.0
        Set-Progress 'extract' 0 $total
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($NewDir, $name))
            if (-not (Test-Inside $path $NewDir)) { throw ('entry outside the folder: ' + $name) }
            if ($name.EndsWith('\')) {
                [void][System.IO.Directory]::CreateDirectory($path)
                continue
            }
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
            $sizes[$path.Substring($NewDir.Length + 1)] = $entry.Length
            $done += $entry.Length
            Set-Progress 'extract' $done $total
        }
    } finally {
        $zip.Dispose()
    }
    return $sizes
}

# Name -> length of the new files in Source. Sizes are those of the package (relative to NewDir) or $null
function Get-Manifest([string]$Source, $Sizes) {
    $manifest = @{}
    if ($Sizes) {
        $prefix = $Source.Substring($NewDir.Length).TrimStart('\')
        if ($prefix) { $prefix += '\' }
        foreach ($rel in $Sizes.Keys) {
            if ($rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $manifest[$rel.Substring($prefix.Length)] = $Sizes[$rel] }
        }
    } else {
        foreach ($rel in (Get-RelativeFiles $Source)) {
            $manifest[$rel] = (New-Object System.IO.FileInfo([System.IO.Path]::Combine($Source, $rel))).Length
        }
    }
    return $manifest
}

# The names in a manifest, in a fixed order
function Get-Names($Manifest) {
    $names = New-Object string[] $Manifest.Count
    $Manifest.Keys.CopyTo($names, 0)
    [System.Array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
    return ,$names
}

# What went wrong, for the status: full disk, no rights, a broken package, or something else
function Get-ErrorKind($Record) {
    $e = $Record.Exception
    while ($e) {
        if ($e -is [System.UnauthorizedAccessException]) { return 'access denied' }
        if ($e -is [System.IO.InvalidDataException]) { return 'package not unpacked' }
        if ($e.HResult -eq -2147024784 -or $e.HResult -eq -2147024857) { return 'disk full' }
        $e = $e.InnerException
    }
    if ($Record.Exception.Message -like '*entry outside the folder*') { return 'package not unpacked' }
    return 'unpack failed'
}

# Copies the backup over the install folder, then deletes the files the update added.
# True when every file of the backup is in place; an added file that stays does no harm
function Restore-Backup([string]$Backup, $Added) {
    $left = Copy-Changed $Backup $InstallDir (Get-RelativeFiles $Backup) 'restore'
    if ($left.Count -gt 0) { return $false }
    foreach ($rel in $Added) {
        if (-not $rel) { continue }
        $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($InstallDir, $rel))
        if ((Test-Inside $path $InstallDir) -and ($path.Length -gt $InstallDir.Length)) {
            try { Remove-OneFile $path } catch { Write-Log ('added file left: ' + $rel) }
        }
    }
    return $true
}

# An earlier install was cut off while copying: put its backup back first
function Repair-Install {
    $backup = Get-NamedBackup $MarkerName
    if (-not $backup) { return $false }
    Write-Log ('unfinished install, putting back ' + [System.IO.Path]::GetFileName($backup))
    if (-not (Restore-Backup $backup (Get-Added $backup))) { throw 'the unfinished install could not be put back' }
    Clear-Marker
    Write-Log 'put back'
    return $true
}

# Only the files that are about to change are kept: the install folder may hold other things.
# A .building file beside the folder says it is not finished. The backups there were stay until the copy succeeded
function Save-Backup($Changed, $Added) {
    [void][System.IO.Directory]::CreateDirectory($BackupRoot)
    $before = Find-Backup
    $current = [System.IO.Path]::Combine($BackupRoot, $CurrentName)
    if ($before -and -not [System.IO.File]::Exists($current)) {
        [System.IO.File]::WriteAllText($current, [System.IO.Path]::GetFileName($before))
    }
    $name = $OldVersion
    for ($i = 2; ; $i++) {
        $dir = [System.IO.Path]::Combine($BackupRoot, $name)
        if (-not [System.IO.Directory]::Exists($dir) -and -not [System.IO.File]::Exists($dir + '.building')) { break }
        $name = $OldVersion + '-' + $i
    }
    [System.IO.File]::WriteAllText($dir + '.building', '')
    try {
        [void][System.IO.Directory]::CreateDirectory($dir)
        Copy-Files $InstallDir $dir $Changed 'backup'
        [System.IO.File]::WriteAllLines($dir + '.added.txt', [string[]]$Added.ToArray())
        Remove-OneFile ($dir + '.building')
    } catch {
        Remove-Quietly $dir
        Remove-Quietly ($dir + '.added.txt')
        Remove-Quietly ($dir + '.building')
        throw
    }
    return $dir
}

# The copy succeeded: this is the backup now, the others go
function Set-CurrentBackup([string]$Backup) {
    $name = [System.IO.Path]::GetFileName($Backup)
    try { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($BackupRoot, $CurrentName), $name) } catch { Write-Log ('current backup not written: ' + $_.Exception.Message) }
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($BackupRoot)) {
        $leaf = [System.IO.Path]::GetFileName($entry)
        if ($leaf -ne $CurrentName -and $leaf -ne $MarkerName -and $leaf -ne $name -and $leaf -ne ($name + '.added.txt')) { Remove-Quietly $entry }
    }
}

function Invoke-Install([string]$Source, $Manifest) {
    [void](Repair-Install)
    $missing = Find-Missing $Source $Manifest
    if ($missing -or $Manifest.Count -eq 0 -or -not $Manifest.ContainsKey($NewExe)) { throw ('new files missing: ' + $missing) }
    $changed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    $names = Get-Names $Manifest
    foreach ($rel in $names) {
        if ([System.IO.File]::Exists([System.IO.Path]::Combine($InstallDir, $rel))) { $changed.Add($rel) } else { $added.Add($rel) }
    }
    # The exe may have been renamed: the new one also goes there
    if (-not $Manifest.ContainsKey($ExeName)) { $changed.Add($ExeName) }
    $backup = Save-Backup $changed $added
    Write-Log ('backup: ' + $backup)
    $marker = [System.IO.Path]::Combine($BackupRoot, $MarkerName)
    [System.IO.File]::WriteAllText($marker, [System.IO.Path]::GetFileName($backup))
    $hold = $null
    try {
        # Nobody can start the app while its files change; its exe comes last
        $hold = Open-Exclusive $ExePath
        if (-not $DryRun) {
            $ids = Get-AppProcessIds
            if ($ids.Count -gt 0) { throw 'the app was opened again' }
        }
        $rest = New-Object System.Collections.Generic.List[string]
        foreach ($rel in $names) { if ($rel -ne $NewExe) { $rest.Add($rel) } }
        Copy-Files $Source $InstallDir $rest 'copy'
        if ($hold) { $hold.Dispose(); $hold = $null }
        $newExePath = [System.IO.Path]::Combine($Source, $NewExe)
        Copy-OneFile $newExePath ([System.IO.Path]::Combine($InstallDir, $NewExe))
        if (-not $Manifest.ContainsKey($ExeName)) { Copy-OneFile $newExePath $ExePath }
        $missing = Find-Missing $InstallDir $Manifest
        if ($missing) { throw ('not in place: ' + $missing) }
    } catch {
        Write-Log ('copy failed: ' + $_.Exception.Message)
        if ($hold) { $hold.Dispose() }
        if (-not (Restore-Backup $backup $added)) { throw 'the old version could not be put back completely' }
        Clear-Marker
        Write-Log 'old version restored'
        # The backup there was before stays the one to go back to
        $before = Get-NamedBackup $CurrentName
        if ($before -ne $backup) {
            Remove-Quietly $backup
            Remove-Quietly ($backup + '.added.txt')
        }
        return 'restored'
    }
    Clear-Marker
    Write-Log ('copied ' + $Manifest.Count + ' files, ' + $added.Count + ' of them new')
    Set-CurrentBackup $backup
    return 'ok'
}

function Invoke-Rollback {
    if (Repair-Install) { return 'ok' }
    $backup = Find-Backup
    if (-not $backup) { throw 'no backup found' }
    $added = Get-Added $backup
    $files = Get-RelativeFiles $backup
    # A copy of the current files that change, put back if the rollback fails halfway
    $touched = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $files) {
        if ([System.IO.File]::Exists([System.IO.Path]::Combine($InstallDir, $rel))) { $touched.Add($rel) }
    }
    $now = [System.IO.Path]::Combine($BackupRoot, 'now.' + [DateTime]::Now.Ticks + '.partial')
    [void][System.IO.Directory]::CreateDirectory($now)
    Copy-Files $InstallDir $now $touched 'backup'
    $hold = Open-Exclusive $ExePath
    if (-not $DryRun -and (Get-AppProcessIds).Count -gt 0) {
        if ($hold) { $hold.Dispose() }
        Remove-Quietly $now
        throw 'the app was opened again'
    }
    $rest = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $files) { if ($rel -ne $ExeName) { $rest.Add($rel) } }
    $left = Copy-Changed $backup $InstallDir $rest 'restore'
    if ($hold) { $hold.Dispose() }
    if ($left.Count -eq 0 -and $rest.Count -ne $files.Count) {
        $left = Copy-Changed $backup $InstallDir @($ExeName) 'restore'
    }
    if ($left.Count -gt 0) {
        Write-Log 'rollback failed'
        $back = Copy-Changed $now $InstallDir $touched 'restore'
        if ($back.Count -gt 0) { throw 'the current version could not be put back completely' }
        Remove-Quietly $now
        Write-Log 'current version kept'
        return 'restored'
    }
    foreach ($rel in $added) {
        if (-not $rel) { continue }
        $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($InstallDir, $rel))
        if ((Test-Inside $path $InstallDir) -and ($path.Length -gt $InstallDir.Length)) {
            try { Remove-OneFile $path } catch { Write-Log ('added file left: ' + $rel) }
        }
    }
    Write-Log ('rolled back to ' + [System.IO.Path]::GetFileName($backup))
    # The backup is the running version now. Marked unfinished first: what cannot be deleted is no backup
    try { [System.IO.File]::WriteAllText($backup + '.building', '') } catch {}
    Remove-Quietly $BackupRoot
    try {
        $parent = [System.IO.Path]::GetDirectoryName($BackupRoot)
        if ([System.IO.Directory]::Exists($parent) -and [System.IO.Directory]::GetFileSystemEntries($parent).Count -eq 0) {
            [System.IO.Directory]::Delete($parent)
        }
    } catch {}
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

# The Windows error behind an exception, 0 when there is none
function Get-NativeError($Record) {
    $e = $Record.Exception
    while ($e) {
        if ($e -is [System.ComponentModel.Win32Exception]) { return $e.NativeErrorCode }
        $e = $e.InnerException
    }
    return 0
}

# ERROR_CANCELLED: the user said no to UAC. Anything else is an error
function Set-ElevationStatus($Record) {
    $code = Get-NativeError $Record
    Write-Log ('elevation failed (' + $code + '): ' + $Record.Exception.Message)
    if ($code -eq 1223) { Set-Status 'declined' } else { Set-Status 'error: elevation failed' }
}

# Every path is quoted. Folder paths never end with a backslash here, which would escape the quote.
function Format-Argument([string]$Value) {
    return '"' + $Value + '"'
}

# The second copy of this script that does the work, hidden
function Start-Worker([string]$What = $Mode) {
    $list = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (Format-Argument $ScriptPath),
        '-Mode', $What,
        '-InstallDir', (Format-Argument $InstallDir),
        '-ExePath', (Format-Argument $ExePath),
        '-NewExe', (Format-Argument $NewExe),
        '-BackupRoot', (Format-Argument $BackupRoot),
        '-LogFile', (Format-Argument $LogFile),
        '-StatusFile', (Format-Argument $StatusFile),
        '-TimeoutSec', [string]$TimeoutSec,
        '-Worker')
    if ($ProgressFile) { $list += @('-ProgressFile', (Format-Argument $ProgressFile)) }
    if ($ZipFile) { $list += @('-ZipFile', (Format-Argument $ZipFile)) }
    if ($NewDir) { $list += @('-NewDir', (Format-Argument $NewDir)) }
    if ($OldVersion) { $list += @('-OldVersion', (Format-Argument $OldVersion)) }
    if ($DryRun) { $list += '-DryRun' }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = [System.IO.Path]::Combine($PSHOME, 'powershell.exe')
    $info.Arguments = $list -join ' '
    $info.WorkingDirectory = [System.IO.Path]::GetDirectoryName($ScriptPath)
    if ($Elevate) {
        $info.UseShellExecute = $true
        $info.Verb = 'runas'
        $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    } else {
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
    }
    return [System.Diagnostics.Process]::Start($info)
}

# Without a window: UAC once for the worker, then start the app from this unelevated process
function Invoke-Elevated {
    Set-Status 'elevating'
    try {
        $proc = Start-Worker
    } catch {
        Set-ElevationStatus $_
        return
    }
    Write-Log 'elevated worker started'
    $proc.WaitForExit()
    $status = Get-Status
    Write-Log ('worker finished: ' + $status)
    if ($status.StartsWith('done:')) {
        Start-App (Get-StartPath $status.Substring(5))
    } elseif ($status.StartsWith('started')) {
        # The app has been told to quit and the worker is gone
        Start-App $ExePath
    }
}

# ---------------------------------------------------------------- the window

$Texts = @{
    title = 'SimpleLive'
    folder = ''
    icon = ''
    accent = '#3F6FE0'
    onAccent = '#FFFFFF'
    dark = '0'
    preparing = 'Preparing...'
    elevating = 'Waiting for administrator permission...'
    extract = 'Unpacking...'
    wait = 'Waiting for the app to close...'
    backup = 'Backing up the current version...'
    copy = 'Installing...'
    restore = 'Putting the old files back...'
    ok = 'Installed'
    okHint = 'Open the app now?'
    restored = 'The update failed, the old version was put back'
    restoredHint = ''
    failed = 'The update failed'
    failedHint = ''
    busy = 'The app did not close, nothing was installed'
    busyHint = ''
    open = 'Open'
    skip = 'Not now'
    close = 'Close'
}

function Read-Texts {
    if (-not $TextFile -or -not [System.IO.File]::Exists($TextFile)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($TextFile, [System.Text.Encoding]::UTF8)) {
        $at = $line.IndexOf('=')
        if ($at -le 0) { continue }
        $Texts[$line.Substring(0, $at)] = $line.Substring($at + 1)
    }
}

# The share of the bar each step fills, in percent
function Get-Percent([string]$Phase, [double]$Done, [double]$Total) {
    $part = 0.0
    if ($Total -gt 0) { $part = [Math]::Min(1.0, $Done / $Total) }
    if ($Mode -eq 'rollback') {
        switch ($Phase) {
            'wait' { return 4 }
            'backup' { return 8 + 32 * $part }
            'restore' { return 40 + 60 * $part }
        }
        return 0
    }
    $from = 0
    if ($ZipFile) { $from = 45 }
    switch ($Phase) {
        'extract' { return $from * $part }
        'wait' { return $from }
        'backup' { return $from + (65 - $from) * $part }
        'copy' { return 65 + 35 * $part }
        'restore' { return 100 }
    }
    return 0
}

function New-UpdateWindow {
    foreach ($name in @('WindowsBase', 'PresentationCore', 'PresentationFramework', 'System.Xaml')) {
        if (-not [System.Reflection.Assembly]::LoadWithPartialName($name)) { throw ('missing ' + $name) }
    }
    # No GPU for a window this small
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
    $colors = @{ BACK = '#FFFFFF'; TEXT = '#1C1C1E'; SUB = '#6C6C72'; TRACK = '#E4E5E9'; LINE = '#D5D6DA'; KEY = '#EDEEF1' }
    if ($Texts.dark -eq '1') {
        $colors = @{ BACK = '#242529'; TEXT = '#F1F1F3'; SUB = '#A4A5AB'; TRACK = '#3B3C42'; LINE = '#3F4046'; KEY = '#393A40' }
    }
    foreach ($key in @('accent', 'onAccent')) {
        if ($Texts[$key] -notmatch '^#[0-9A-Fa-f]{6}$') { $Texts[$key] = @{ accent = '#3F6FE0'; onAccent = '#FFFFFF' }[$key] }
    }
    $colors.ACCENT = $Texts.accent
    $colors.ONACCENT = $Texts.onAccent
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        SizeToContent="Height" Width="480" WindowStartupLocation="CenterScreen" UseLayoutRounding="True"
        FontFamily="Segoe UI, Microsoft YaHei UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Key" TargetType="Button">
      <Setter Property="MinWidth" Value="92"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Shape" CornerRadius="7" Padding="16,7" Background="{TemplateBinding Background}"
                    BorderThickness="1.5" BorderBrush="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Shape" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Shape" Property="BorderBrush" Value="#SUB#"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="Card" Margin="14" CornerRadius="12" Background="#BACK#" BorderBrush="#LINE#" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.28" Color="#000000"/>
    </Border.Effect>
    <StackPanel Margin="24,22,24,20">
      <DockPanel LastChildFill="True">
        <Image x:Name="Logo" Width="46" Height="46" Margin="0,0,16,0" DockPanel.Dock="Left"
               RenderOptions.BitmapScalingMode="HighQuality"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="Heading" FontSize="16" FontWeight="SemiBold" Foreground="#TEXT#" TextWrapping="Wrap"/>
          <TextBlock x:Name="Detail" FontSize="12.5" Margin="0,4,0,0" Foreground="#SUB#" TextWrapping="Wrap"/>
        </StackPanel>
      </DockPanel>
      <DockPanel x:Name="Progress" Margin="0,18,0,0" LastChildFill="True">
        <TextBlock x:Name="Percent" DockPanel.Dock="Right" Width="46" TextAlignment="Right" FontSize="12.5" Foreground="#SUB#"/>
        <Grid x:Name="Track" Height="8" VerticalAlignment="Center">
          <Border CornerRadius="4" Background="#TRACK#"/>
          <Border x:Name="Fill" CornerRadius="4" Background="#ACCENT#" HorizontalAlignment="Left" Width="0"/>
        </Grid>
      </DockPanel>
      <StackPanel x:Name="Keys" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0" Visibility="Collapsed">
        <Button x:Name="CloseKey" Style="{StaticResource Key}" Background="#KEY#" Foreground="#TEXT#" IsCancel="True"/>
        <Button x:Name="OpenKey" Style="{StaticResource Key}" Background="#ACCENT#" Foreground="#ONACCENT#" Margin="10,0,0,0" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    foreach ($key in $colors.Keys) { $xaml = $xaml.Replace('#' + $key + '#', $colors[$key]) }
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $window.Title = $Texts.title
    if ($Texts.icon -and [System.IO.File]::Exists($Texts.icon)) {
        try {
            # Read at once, so the file is not held while it is replaced
            $image = New-Object System.Windows.Media.Imaging.BitmapImage
            $image.BeginInit()
            $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $image.UriSource = New-Object System.Uri($Texts.icon)
            $image.EndInit()
            $window.Icon = $image
            $window.FindName('Logo').Source = $image
        } catch {
            Write-Log ('icon not shown: ' + $_.Exception.Message)
        }
    }
    if (-not $window.FindName('Logo').Source) { $window.FindName('Logo').Visibility = 'Collapsed' }
    return $window
}

function Set-Window([string]$Heading, [string]$Detail, [double]$Percent) {
    $View.Heading.Text = $Heading
    $View.Detail.Text = $Detail
    $View.Detail.Visibility = $(if ($Detail) { 'Visible' } else { 'Collapsed' })
    $View.Target = $Percent
}

# One step of the bar towards Target
function Move-Bar {
    $View.Shown += ($View.Target - $View.Shown) * 0.3
    if ([Math]::Abs($View.Target - $View.Shown) -lt 0.2) { $View.Shown = $View.Target }
    $View.Fill.Width = [Math]::Max(0.0, $View.Track.ActualWidth * $View.Shown / 100)
    $View.Percent.Text = ('{0:0}%' -f $View.Shown)
}

function Show-Keys([string]$OpenText, [string]$CloseText) {
    $View.CloseKey.Content = $CloseText
    if ($OpenText) { $View.OpenKey.Content = $OpenText } else { $View.OpenKey.Visibility = 'Collapsed' }
    $View.Keys.Visibility = 'Visible'
    $View.Finished = $true
    [void]$View.Window.Activate()
    if ($OpenText) { [void]$View.OpenKey.Focus() } else { [void]$View.CloseKey.Focus() }
}

function Show-Result([string]$Result) {
    $View.Result = $Result
    if ($Result -eq 'ok') {
        Set-Window $Texts.ok $Texts.okHint 100
        Show-Keys $Texts.open $Texts.skip
        return
    }
    $View.Progress.Visibility = 'Collapsed'
    switch ($Result) {
        'restored' { Set-Window $Texts.restored $Texts.restoredHint 0; Show-Keys $Texts.open $Texts.close }
        'busy' { Set-Window $Texts.busy $Texts.busyHint 0; Show-Keys '' $Texts.close }
        default { Set-Window $Texts.failed $Texts.failedHint 0; Show-Keys $Texts.open $Texts.close }
    }
}

function Close-Window {
    $View.Finished = $true
    $View.Timer.Stop()
    $View.Window.Close()
}

# The worker is done or gone
function Complete-Window([string]$Status) {
    $View.Done = $true
    Write-Log ('worker finished: ' + $Status)
    if ($Status.StartsWith('done:')) {
        Show-Result $Status.Substring(5)
    } elseif ($Status.StartsWith('started')) {
        # The app has been told to quit and the worker is gone without a result
        if (-not $View.Repairing -and (Get-NamedBackup $MarkerName)) {
            # It was copying: put the old files back
            Write-Log 'worker gone while copying, repairing'
            $View.Repairing = $true
            $View.Done = $false
            Set-Window $Texts.restore $Texts.folder 100
            try {
                $View.Worker = Start-Worker 'repair'
                try { $View.WorkerId = $View.Worker.Id } catch {}
                return
            } catch {
                Write-Log ('repair not started: ' + $_.Exception.Message)
                $View.Done = $true
            }
        }
        Set-Status 'done:failed'
        Show-Result 'failed'
    } else {
        # The app is still open and says why
        if (-not $Status.StartsWith('error') -and -not $Status.StartsWith('cancelled')) { Set-Status 'error: worker stopped' }
        Close-Window
    }
}

# An elevated process may not let itself be asked: look whether it is still there
function Test-WorkerGone {
    try { return $View.Worker.HasExited } catch {}
    try {
        [void][System.Diagnostics.Process]::GetProcessById($View.WorkerId)
        return $false
    } catch {
        return $true
    }
}

function Update-Window {
    Move-Bar
    if ($View.Done) { return }
    $status = Get-Status
    $gone = Test-WorkerGone
    if ($View.Repairing -and -not $gone -and -not $status.StartsWith('done:')) { return }
    if ($gone -or $status.StartsWith('done:') -or $status.StartsWith('error')) {
        # Its last word may have come just after it was read
        Complete-Window $(if ($gone) { Get-Status } else { $status })
        return
    }
    $phase = ''
    $done = 0.0
    $total = 0.0
    try {
        $parts = [System.IO.File]::ReadAllText($ProgressFile).Trim().Split(' ')
        if ($parts.Length -eq 3) {
            $phase = $parts[0]
            $done = [double]$parts[1]
            $total = [double]$parts[2]
        }
    } catch {}
    if ($phase -and $Texts.ContainsKey($phase)) {
        Set-Window $Texts[$phase] $Texts.folder (Get-Percent $phase $done $total)
    }
}

function Start-Work {
    if ($Elevate) {
        Set-Status 'elevating'
        Set-Window $Texts.elevating $Texts.folder 0
        # UAC blocks this thread: draw first
        $View.Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
    try {
        $View.Worker = Start-Worker
    } catch {
        if ($Elevate) {
            Set-ElevationStatus $_
        } else {
            Write-Log ('worker not started: ' + $_.Exception.Message)
            Set-Status 'error: worker not started'
        }
        Close-Window
        return
    }
    try { $View.WorkerId = $View.Worker.Id } catch {}
    Write-Log 'worker started'
    Set-Window $Texts.preparing $Texts.folder 0
    $View.Timer.Start()
}

# Shows the window until it is closed. False when it cannot be shown: the work is then done without it
function Invoke-Window {
    try {
        # The app sees that the script runs, however long loading WPF takes
        Set-Status 'opening'
        Read-Texts
        $window = New-UpdateWindow
        $script:View = @{
            Window = $window; Worker = $null; WorkerId = 0; Done = $false; Finished = $false; Result = ''; Open = $false
            Shown = 0.0; Target = 0.0; Repairing = $false
        }
        foreach ($name in @('Card', 'Heading', 'Detail', 'Progress', 'Track', 'Fill', 'Percent', 'Keys', 'OpenKey', 'CloseKey')) {
            $View[$name] = $window.FindName($name)
        }
        $View.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $View.Timer.Interval = [TimeSpan]::FromMilliseconds(80)
        $View.Timer.Add_Tick({
            try { Update-Window } catch { Write-Log ('window: ' + $_.Exception.Message) }
        })
        $View.Card.Add_MouseLeftButtonDown({ try { $View.Window.DragMove() } catch {} })
        $View.OpenKey.Add_Click({ $View.Open = $true; Close-Window })
        $View.CloseKey.Add_Click({ Close-Window })
        $window.Add_Closing({
            param($from, $e)
            if ($View.Finished) { return }
            $status = Get-Status
            if ($status.StartsWith('started') -or $status.StartsWith('done:')) {
                $e.Cancel = $true
            } else {
                # Nothing has changed yet: the same as saying no
                Set-Status 'cancelled'
                $View.Timer.Stop()
            }
        })
        $window.Add_ContentRendered({
            [void]$View.Window.Activate()
            Start-Work
        })
        Set-Window $Texts.preparing $Texts.folder 0
    } catch {
        Write-Log ('no window: ' + $_.Exception.Message)
        return $false
    }
    [void]$window.ShowDialog()
    if ($View.Open) { Start-App (Get-StartPath $View.Result) }
    return $true
}

# ---------------------------------------------------------------- start

if ($InstallDir) { $InstallDir = Get-FullPath $InstallDir }
if ($ExePath) { $ExePath = [System.IO.Path]::GetFullPath($ExePath) }
if ($ZipFile) { $ZipFile = [System.IO.Path]::GetFullPath($ZipFile) }
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

if ($Ui -and -not $Worker) {
    if (Invoke-Window) { exit 0 }
}
if ($Elevate -and -not $Worker) {
    Invoke-Elevated
    exit 0
}

if (-not (Enter-OnlyOne)) {
    Write-Log 'another update of this folder is running'
    if ($Mode -ne 'repair') { Set-Status 'error: another update is running' }
    exit 6
}
Exit-IfCancelled
$source = $NewDir
$sizes = $null
$manifest = $null
if ($Mode -eq 'install') {
    # Unpack while the app is still open: a broken package changes nothing
    if ($ZipFile) {
        Set-Status 'preparing'
        Write-Log ('unpack: ' + $ZipFile)
        try {
            $sizes = Expand-Package
        } catch {
            Write-Log ('unpack failed: ' + $_.Exception.Message)
            Remove-Quietly $NewDir
            Set-Status ('error: ' + (Get-ErrorKind $_))
            exit 2
        }
    }
    $source = Find-NewFolder $NewDir
    if (-not $source) {
        Write-Log 'the app is not in the package'
        Remove-Quietly $NewDir
        Set-Status 'error: app not in the package'
        exit 2
    }
    $manifest = Get-Manifest $source $sizes
}
Exit-IfCancelled
if ($Mode -ne 'repair') { Set-Status 'started' }
Write-Log ('start: ' + $InstallDir)
$result = 'failed'
try {
    if ($DryRun -or (Wait-AppExit)) {
        if (-not $DryRun) { [System.Threading.Thread]::Sleep(800) }
        switch ($Mode) {
            'install' { $result = Invoke-Install $source $manifest }
            'rollback' { $result = Invoke-Rollback }
            'repair' { if (Repair-Install) { $result = 'restored' } }
        }
    } else {
        $result = 'busy'
    }
} catch {
    Write-Log ('failed: ' + $_.Exception.Message)
    $result = 'failed'
}
if ($Mode -eq 'install') {
    Remove-Quietly $NewDir
    if ($result -eq 'ok' -and $ZipFile) {
        try {
            Remove-OneFile $ZipFile
            Write-Log 'package deleted'
        } catch {
            Write-Log ('package not deleted: ' + $_.Exception.Message)
        }
    }
}
Write-Log ('result: ' + $result)
Set-Status ('done:' + $result)
if (-not $Worker) { Start-App (Get-StartPath $result) }
if ($result -eq 'ok') { exit 0 }
exit 1
''';
