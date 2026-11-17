# Builds the Windows 7 package of simple_live_N from this source tree.
# See windows7\README.md for what it changes and what it needs.
#
# Run on Windows 10 or 11 from the repository root:
#   powershell -ExecutionPolicy Bypass -File windows7\build_win7.ps1
# Options:
#   -Out <zip>        output file (default: simple_live_app\build\win7\simple_live_N-<version>-<build>-win7-windows-x64.zip)
#   -Commit <text>    commit shown on the About page (--dart-define=SL_BUILD_COMMIT)
#   -Python <exe>     Python 3 to run the shim tools (default: python)
#   -Offline          flutter pub get --offline
#
# The script changes files under simple_live_app for the build and puts them back with git
# afterwards, so it refuses to run while simple_live_app has uncommitted changes.
param([string]$Out = '', [string]$Commit = '', [string]$Python = 'python', [switch]$Offline)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot
$app = "$root\simple_live_app"
$video = "$app\third_party\media_kit_video"
$libs = "$app\third_party\media_kit_libs_windows_video"
$shims = "$PSScriptRoot\shims"
$work = "$app\build\win7"
$env:PYTHONIOENCODING = 'utf-8'

if ((git -C $root status --porcelain -- simple_live_app) -ne $null) {
  throw 'simple_live_app has uncommitted changes; commit or stash them first'
}
if (-not (Test-Path $libs)) { throw 'third_party\media_kit_libs_windows_video not found: is this the simple_live_N tree?' }
$line = (Get-Content "$app\pubspec.yaml" | Select-String '^version:\s*([0-9.]+)\+([0-9]+)').Matches[0]
$ver = $line.Groups[1].Value
$buildNumber = $line.Groups[2].Value
if (-not $Out) { $Out = "$work\simple_live_N-$ver-$buildNumber-win7-windows-x64.zip" }
$dir = "$work\simple_live_N"
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null

try {
  # 1. Video: the Direct3D 11 renderer and the current libmpv need Windows 8 or later. For this
  #    build only, media_kit_video uses its older Windows code (windows7\media_kit_video_windows)
  #    and media_kit_libs_windows_video comes from pub.dev, with the older libmpv and ANGLE.
  Remove-Item "$video\windows" -Recurse -Force
  Copy-Item "$PSScriptRoot\media_kit_video_windows" "$video\windows" -Recurse
  Remove-Item $libs -Recurse -Force
  $p = [IO.File]::ReadAllText("$app\pubspec.yaml")
  $p2 = [regex]::Replace($p, '(?m)^  #[^\n]*\n  media_kit_libs_windows_video:\r?\n    path: third_party/media_kit_libs_windows_video\r?\n', '')
  if ($p2 -eq $p) { throw 'pubspec.yaml: override for media_kit_libs_windows_video not found' }
  [IO.File]::WriteAllText("$app\pubspec.yaml", $p2, (New-Object Text.UTF8Encoding $false))

  # 2. Release build. The CMake cache of an earlier Windows build knows the other plugin set.
  Set-Location $app
  if (Test-Path "$app\build\windows") { Remove-Item "$app\build\windows" -Recurse -Force }
  $get = if ($Offline) { 'flutter pub get --offline' } else { 'flutter pub get' }
  $define = if ($Commit) { "--dart-define=SL_BUILD_COMMIT=$Commit" } else { '' }
  cmd /c "$get > `"$work\build.log`" 2>&1 && flutter build windows --release --no-pub --build-name $ver --build-number $buildNumber --dart-define=FORK_BUILD=win7 $define >> `"$work\build.log`" 2>&1"
  $buildExit = $LASTEXITCODE
  $rel = "$app\build\windows\x64\runner\Release"
  if ($buildExit -ne 0 -or -not (Test-Path "$rel\flutter_windows.dll") -or -not (Test-Path "$rel\data\app.so")) {
    Get-Content "$work\build.log" -Tail 25; throw "build failed (exit $buildExit), see $work\build.log"
  }
  Copy-Item $rel $dir -Recurse
} finally {
  # put simple_live_app back as committed (Direct3D 11 path, pubspec override)
  Set-Location $root
  git -C $root checkout -- simple_live_app
  git -C $root clean -fdq -- simple_live_app/third_party
  if (Test-Path "$app\build\windows") { Remove-Item "$app\build\windows" -Recurse -Force }
}

# 3. Shims for the Windows 8+ functions: flutter_windows.dll imports kernel32 / ws2_32 / ntdll
#    through k32w7 / ws2w7 / ntdw7 (the real function when Windows has it, a Windows 7
#    replacement or an error stub otherwise); the notification plugin's kernel32 import too.
#    The API-set DLLs cover the path, synch and WinRT functions.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$dumpbin = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -Last 1)
if (-not $dumpbin) { throw 'dumpbin.exe not found (Visual Studio with the C++ tools is needed)' }
$env:DUMPBIN = $dumpbin
$notify = 'flutter_local_notifications_windows.dll'
& $dumpbin /imports "$dir\flutter_windows.dll" | Out-File "$work\imports_flutter_windows.txt" -Encoding utf8
& $dumpbin /imports "$dir\$notify" | Out-File "$work\imports_notifications.txt" -Encoding utf8
Set-Location $shims
& $Python gen_shims.py "$work\imports_flutter_windows.txt" "$work\imports_notifications.txt" gen
if ($LASTEXITCODE -ne 0) { throw 'gen_shims.py failed' }
cmd /c "`"$shims\build_shims.cmd`" > `"$work\shims.log`" 2>&1"
if ($LASTEXITCODE -ne 0) { Get-Content "$work\shims.log" -Tail 15; throw 'build_shims.cmd failed' }
Copy-Item "$shims\out\*.dll" $dir
& $Python patch_imports.py "$dir\flutter_windows.dll" gen\redirects.txt
if ($LASTEXITCODE -ne 0) { throw 'patch_imports.py failed on flutter_windows.dll' }
Set-Content "$work\redirects_notifications.txt" 'KERNEL32.dll|k32w7.dll' -Encoding ascii
& $Python patch_imports.py "$dir\$notify" "$work\redirects_notifications.txt"
if ($LASTEXITCODE -ne 0) { throw "patch_imports.py failed on $notify" }

# 4. Checks: every shimmed import is exported, nothing else needs Windows 8+
& $Python verify.py $dir
if ($LASTEXITCODE -ne 0) { throw 'the shim DLLs do not export everything that is imported from them' }
& $Python win7_scan.py $dir | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw 'something in the package still needs Windows 8 or later' }
Set-Location $root

# 5. License and third-party notices go into the package, then zip
Copy-Item "$root\LICENSE" "$dir\LICENSE.txt"
Copy-Item "$root\THIRD_PARTY_NOTICES.md" "$dir\THIRD_PARTY_NOTICES.md"
if (Test-Path $Out) { Remove-Item $Out -Force }
Compress-Archive -Path "$dir\*" -DestinationPath $Out
Remove-Item $dir -Recurse -Force
Get-Item $Out | Select-Object FullName, Length
