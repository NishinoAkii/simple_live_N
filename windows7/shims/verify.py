"""Check that every import a binary takes from our shim DLLs is exported by them.
Usage: python verify.py <folder with patched binaries + shim dlls>"""
import glob
import os
import re
import subprocess
import sys

# DUMPBIN from the environment, else the newest dumpbin of any Visual Studio edition
DUMPBIN = os.environ.get("DUMPBIN") or sorted(glob.glob(
    r"C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe"))[-1]
SHIMS = {"k32w7.dll", "ws2w7.dll", "ntdw7.dll", "api-ms-win-core-path-l1-1-0.dll",
         "api-ms-win-core-synch-l1-2-0.dll", "api-ms-win-core-winrt-l1-1-0.dll",
         "api-ms-win-core-winrt-string-l1-1-0.dll", "api-ms-win-core-winrt-error-l1-1-0.dll"}


def run(*args):
    return subprocess.run([DUMPBIN, *args], capture_output=True, text=True, errors="replace").stdout


def exports(path):
    names, ords = set(), set()
    for ln in run("/exports", path).splitlines():
        m = re.match(r"^\s+(\d+)\s+[0-9A-F]*\s+[0-9A-F]{8}\s+(\S+)", ln)
        if m:
            ords.add(int(m.group(1)))
            names.add(m.group(2))
            continue
        m = re.match(r"^\s+(\d+)\s+[0-9A-F]{8}\s+\[NONAME\]", ln)
        if m:
            ords.add(int(m.group(1)))
    return names, ords


def imports(path):
    out, cur = {}, None
    for ln in run("/imports", path).splitlines():
        if "Summary" in ln or "delay load imports" in ln:
            break
        m = re.match(r"^\s{4}(\S+\.(?:dll|DLL))\s*$", ln)
        if m:
            cur = m.group(1).lower()
            out.setdefault(cur, [])
            continue
        if cur is None:
            continue
        m = re.match(r"^\s+Ordinal\s+(\d+)\s*$", ln)
        if m:
            out[cur].append(int(m.group(1)))
            continue
        m = re.match(r"^\s+[0-9A-Fa-f]+\s+(\S+)\s*$", ln)
        if m:
            out[cur].append(m.group(1))
    return out


folder = sys.argv[1]
bad = 0
cache = {}
for f in sorted(os.listdir(folder)):
    if not f.lower().endswith((".dll", ".exe")) or f.lower() in SHIMS:
        continue
    for dll, funcs in imports(os.path.join(folder, f)).items():
        if dll not in SHIMS:
            continue
        shim = os.path.join(folder, dll)
        if not os.path.exists(shim):
            print(f"{f}: {dll} is missing from the folder")
            bad += 1
            continue
        names, ords = cache.setdefault(dll, exports(shim))
        miss = [x for x in funcs if (x not in ords if isinstance(x, int) else x not in names)]
        status = "ok" if not miss else f"MISSING {miss}"
        print(f"{f} -> {dll}: {len(funcs)} imports, {status}")
        bad += bool(miss)
print("problems:", bad)
sys.exit(1 if bad else 0)
