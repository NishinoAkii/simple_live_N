"""List imports in a Windows build folder that Windows 7 SP1 does not have.

Static check only: system DLLs that do not exist on Windows 7, API sets newer
than Windows 7's schema, and a list of well-known Windows 8+ functions.
Delay-loaded imports are listed separately (they only fail when called)."""
import os
import re
import subprocess
import sys

import glob

DUMPBIN = os.environ.get("DUMPBIN") or next(iter(sorted(glob.glob(
    r"C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe"),
    reverse=True)), None)
assert DUMPBIN, "dumpbin.exe not found"

# DLLs that are not on Windows 7 SP1.
WIN8_DLLS = {
    "shcore.dll", "dcomp.dll", "d3d12.dll", "windows.storage.dll", "dxcore.dll",
    "api-ms-win-core-path-l1-1-0.dll", "api-ms-win-core-winrt-l1-1-0.dll",
    "api-ms-win-core-winrt-error-l1-1-0.dll", "api-ms-win-core-winrt-error-l1-1-1.dll",
    "api-ms-win-core-winrt-string-l1-1-0.dll", "api-ms-win-core-synch-l1-2-0.dll",
    "api-ms-win-core-synch-l1-2-1.dll", "api-ms-win-shcore-scaling-l1-1-1.dll",
    "api-ms-win-core-memory-l1-1-2.dll", "api-ms-win-core-memory-l1-1-3.dll",
    "api-ms-win-core-memory-l1-1-6.dll", "api-ms-win-core-memory-l1-1-7.dll",
    "api-ms-win-core-libraryloader-l1-2-0.dll", "api-ms-win-core-file-l1-2-0.dll",
    "api-ms-win-core-file-l2-1-0.dll", "api-ms-win-core-sysinfo-l1-2-0.dll",
    "api-ms-win-core-processthreads-l1-1-1.dll", "api-ms-win-core-processthreads-l1-1-2.dll",
    "api-ms-win-core-processthreads-l1-1-3.dll", "api-ms-win-core-wow64-l1-1-1.dll",
    "api-ms-win-core-realtime-l1-1-0.dll", "api-ms-win-core-comm-l1-1-0.dll",
    "mfplat.dll",  # exists on 7 but different exports; flagged for a manual look
}
# Well-known Windows 8+ (or 10+) exports.
WIN8_FUNCS = {
    "GetSystemTimePreciseAsFileTime", "CreateFile2", "CopyFile2", "GetHostNameW",
    "PathCchCombineEx", "PathCchCombine", "PathCchAppendEx", "PathCchCanonicalizeEx",
    "PathCchRemoveFileSpec", "PathCchSkipRoot", "PathAllocCombine", "PathAllocCanonicalize",
    "RtlAddGrowableFunctionTable", "RtlDeleteGrowableFunctionTable", "RtlGrowFunctionTable",
    "SetThreadInformation", "GetThreadInformation", "SetProcessInformation",
    "GetProcessInformation", "GetCurrentThreadStackLimits", "PrefetchVirtualMemory",
    "DiscardVirtualMemory", "OfferVirtualMemory", "ReclaimVirtualMemory",
    "WaitOnAddress", "WakeByAddressSingle", "WakeByAddressAll",
    "SetThreadDescription", "GetThreadDescription", "VirtualAlloc2", "MapViewOfFile3",
    "InitializeSynchronizationBarrier", "EnterSynchronizationBarrier",
    "DeleteSynchronizationBarrier", "GetPackageFamilyName", "GetCurrentPackageFullName",
    "GetCurrentPackageId", "GetFirmwareType", "CreateDXGIFactory2", "DXGIGetDebugInterface1",
    "GetDpiForMonitor", "SetProcessDpiAwareness", "GetProcessDpiAwareness",
    "GetDpiForWindow", "GetDpiForSystem", "AdjustWindowRectExForDpi",
    "EnableNonClientDpiScaling", "SetThreadDpiAwarenessContext", "GetSystemMetricsForDpi",
    "SystemParametersInfoForDpi", "SetProcessDpiAwarenessContext", "GetPointerInfo",
    "GetPointerType", "GetPointerFrameInfo", "GetPointerPenInfo", "GetPointerTouchInfo",
    "EnableMouseInPointer", "InitializeTouchInjection", "InjectTouchInput",
    "RegisterPointerDeviceNotifications", "GetPointerDevices", "SetCoalescableTimer",
    "RoInitialize", "RoUninitialize", "RoGetActivationFactory", "WindowsCreateString",
    "WindowsDeleteString", "WindowsGetStringRawBuffer", "RoOriginateErrorW",
    "DCompositionCreateDevice", "DCompositionCreateDevice2", "D3D12CreateDevice",
    "GetSystemTimes2", "QueryUnbiasedInterruptTimePrecise", "QueryInterruptTimePrecise",
    "GetOverlappedResultEx", "CreateFileMappingFromApp", "MapViewOfFileFromApp",
    "VirtualProtectFromApp", "SetDefaultDllDirectories2", "GetModuleHandleExA2",
}

rx_dll = re.compile(r"^\s{4}(\S+\.(?:dll|DLL|exe|drv|sys))\s*$")
rx_fn = re.compile(r"^\s+[0-9A-F]+\s+(\S+)\s*$")


def imports(path, delay):
    out = subprocess.run([DUMPBIN, "/imports", path], capture_output=True, text=True,
                         errors="replace").stdout
    # dumpbin prints normal imports, then "Section contains the following delay load imports"
    parts = out.split("delay load imports")
    text = parts[1] if delay and len(parts) > 1 else (parts[0] if not delay else "")
    result, cur = {}, None
    for line in text.splitlines():
        m = rx_dll.match(line)
        if m:
            cur = m.group(1).lower()
            result.setdefault(cur, set())
            continue
        m = rx_fn.match(line)
        if m and cur:
            result[cur].add(m.group(1))
    return result


def main(folder):
    bad = 0
    for root, _, files in os.walk(folder):
        for f in sorted(files):
            if not f.lower().endswith((".dll", ".exe")):
                continue
            p = os.path.join(root, f)
            local = {x.lower() for x in os.listdir(root)}
            for delay in (False, True):
                for dll, fns in imports(p, delay).items():
                    tag = "delay" if delay else "LOAD"
                    hits = sorted(fn for fn in fns if fn in WIN8_FUNCS)
                    if dll in WIN8_DLLS and dll not in local:
                        print(f"[{tag}] {f}: needs {dll} ({len(fns)} functions: {', '.join(sorted(fns))})")
                        bad += not delay
                    # functions taken from DLLs in the app folder (our shims) are covered
                    if hits and dll not in local:
                        print(f"[{tag}] {f}: {dll} -> {', '.join(hits)}")
                        bad += not delay
                    if dll.startswith("api-ms-win-crt-") and not delay:
                        pass  # UCRT: on Windows 7 only with KB2999226 / VC++ redist
    print(f"\n{bad} load-time problems found in {folder}")
    return bad


if __name__ == "__main__":
    sys.exit(1 if main(sys.argv[1]) else 0)
