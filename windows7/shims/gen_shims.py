"""Generate the Windows 7 shim sources from flutter_windows.dll's import list.

Usage: python gen_shims.py <dumpbin /imports output> [<more outputs> ...] <out dir>
(build_win7.ps1 also passes flutter_local_notifications_windows.dll's imports)

Redirect shims (the engine's import entries for these DLLs get renamed to them):
  KERNEL32.dll -> k32w7.dll, WS2_32.dll -> ws2w7.dll, ntdll.dll -> ntdw7.dll
Every imported function becomes a jmp stub through a pointer filled at load:
the real function when Windows has it, else a replacement (Win7), else a stub
that fails with ERROR_CALL_NOT_IMPLEMENTED. So nothing fails at load time and
newer Windows keeps using the real functions.
"""
import io
import os
import re
import sys

REDIRECT = {
    "KERNEL32.dll": ("k32w7", "kernel32.dll"),
    "WS2_32.dll": ("ws2w7", "ws2_32.dll"),
    "ntdll.dll": ("ntdw7", "ntdll.dll"),
}

# replacements used when the real function is missing (Windows 7)
FALLBACKS = {
    "k32w7": {
        "GetCurrentThreadStackLimits": "W7_GetCurrentThreadStackLimits",
        "GetCurrentPackageFullName": "W7_GetCurrentPackageFullName",
    },
    "ws2w7": {"GetHostNameW": "W7_GetHostNameW"},
    "ntdw7": {
        "RtlAddGrowableFunctionTable": "W7_RtlAddGrowableFunctionTable",
        "RtlDeleteGrowableFunctionTable": "W7_RtlDeleteGrowableFunctionTable",
    },
}

FALLBACK_CODE = {
    "k32w7": r"""
/* Windows 8+: low = DeallocationStack, high = StackBase */
static void WINAPI W7_GetCurrentThreadStackLimits(PULONG_PTR low, PULONG_PTR high) {
    NT_TIB *tib = (NT_TIB *)NtCurrentTeb();
    MEMORY_BASIC_INFORMATION mbi;
    *high = (ULONG_PTR)tib->StackBase;
    if (VirtualQuery(&mbi, &mbi, sizeof(mbi))) {
        *low = (ULONG_PTR)mbi.AllocationBase;
    } else {
        *low = (ULONG_PTR)tib->StackLimit;
    }
}

/* Windows 8+: the app package's name. Windows 7 has no app packages; the generic
   stub would return 0 (ERROR_SUCCESS) and the caller would think it is packaged */
static LONG WINAPI W7_GetCurrentPackageFullName(UINT32 *length, PWSTR name) {
    (void)name;
    if (length != NULL) {
        *length = 0;
    }
    return 15700L; /* APPMODEL_ERROR_NO_PACKAGE */
}
""",
    "ws2w7": r"""
/* Windows 8+: wide host name. Windows 7: ANSI gethostname, converted */
static int WSAAPI W7_GetHostNameW(PWSTR name, int namelen) {
    char buf[256];
    if (gethostname(buf, (int)sizeof(buf)) != 0) {
        return SOCKET_ERROR;
    }
    if (name == NULL || namelen <= 0 ||
        MultiByteToWideChar(CP_ACP, 0, buf, -1, name, namelen) == 0) {
        WSASetLastError(WSAEFAULT);
        return SOCKET_ERROR;
    }
    return 0;
}
""",
    "ntdw7": r"""
/* Windows 8+ growable tables; Windows 7 has the fixed-size RtlAddFunctionTable */
static LONG NTAPI W7_RtlAddGrowableFunctionTable(PVOID *table, PRUNTIME_FUNCTION entries,
        DWORD count, DWORD max_count, ULONG_PTR base, ULONG_PTR end) {
    (void)max_count; (void)end;
    if (!RtlAddFunctionTable(entries, count, (DWORD64)base)) {
        return (LONG)0xC0000001L; /* STATUS_UNSUCCESSFUL */
    }
    *table = entries;
    return 0;
}

static void NTAPI W7_RtlDeleteGrowableFunctionTable(PVOID table) {
    RtlDeleteFunctionTable((PRUNTIME_FUNCTION)table);
}
""",
}


def parse(path):
    lines = io.open(path, encoding="utf-8-sig", errors="replace").read().splitlines()
    out, cur = {}, None
    for ln in lines:
        if "Summary" in ln or "delay load imports" in ln:
            break
        m = re.match(r"^\s{4}(\S+\.(?:dll|DLL))\s*$", ln)
        if m:
            cur = m.group(1)
            out.setdefault(cur, [])
            continue
        if cur is None:
            continue
        m = re.match(r"^\s+Ordinal\s+(\d+)\s*$", ln)
        if m:
            out[cur].append(("ord", int(m.group(1))))
            continue
        m = re.match(r"^\s+[0-9A-Fa-f]+\s+(\S+)\s*$", ln)
        if m:
            out[cur].append(("name", m.group(1)))
    return out


def main(imports_txts, outdir):
    """Several dumpbin outputs (engine + plugins): each shim exports the union of what
    the patched binaries import from its DLL, in first-seen order."""
    os.makedirs(outdir, exist_ok=True)
    imports = {}
    for path in imports_txts:
        for dll, entries in parse(path).items():
            merged = imports.setdefault(dll, [])
            for entry in entries:
                if entry not in merged:
                    merged.append(entry)
    built = []
    for dll, (shim, target) in REDIRECT.items():
        entries = imports.get(dll)
        if not entries:
            print("not imported:", dll)
            continue
        n = len(entries)
        fallbacks = FALLBACKS.get(shim, {})
        names_c, ords_c, fb_c, asm, defs = [], [], [], [], []
        for i, (kind, value) in enumerate(entries):
            if kind == "name":
                names_c.append(f'    "{value}",')
                ords_c.append("    0,")
                fb_c.append(f"    (void *){fallbacks.get(value, 'NotImpl')},")
                defs.append(f"    {value}=stub_{i}")
            else:
                names_c.append("    0,")
                ords_c.append(f"    {value},")
                fb_c.append("    (void *)NotImpl,")
                defs.append(f"    stub_{i} @{value} NONAME")
            asm.append(f"stub_{i} PROC\n    jmp QWORD PTR [g_ptrs + {8 * i}]\nstub_{i} ENDP")
        include = ("#include <winsock2.h>\n#include <windows.h>" if shim == "ws2w7"
                   else "#include <windows.h>")
        c = f"""/* generated by gen_shims.py: {dll} -> {shim}.dll ({n} functions) */
#define WIN32_LEAN_AND_MEAN
{include}

void *g_ptrs[{n}];

static INT_PTR WINAPI NotImpl(void) {{
    SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
    return 0;
}}
{FALLBACK_CODE.get(shim, '')}
static const char *const g_names[{n}] = {{
{chr(10).join(names_c)}
}};

static const unsigned short g_ords[{n}] = {{
{chr(10).join(ords_c)}
}};

static void *const g_fallbacks[{n}] = {{
{chr(10).join(fb_c)}
}};

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {{
        HMODULE target = GetModuleHandleW(L"{target}");
        int i;
        if (target == NULL) {{
            target = LoadLibraryW(L"{target}");
        }}
        for (i = 0; i < {n}; i++) {{
            FARPROC p = NULL;
            if (target != NULL) {{
                p = GetProcAddress(target, g_names[i] ? g_names[i]
                                                       : (LPCSTR)(ULONG_PTR)g_ords[i]);
            }}
            g_ptrs[i] = p ? (void *)p : g_fallbacks[i];
        }}
        DisableThreadLibraryCalls(inst);
    }}
    return TRUE;
}}
"""
        io.open(os.path.join(outdir, f"{shim}.c"), "w", encoding="utf-8").write(c)
        io.open(os.path.join(outdir, f"{shim}_stubs.asm"), "w", encoding="utf-8").write(
            "EXTERN g_ptrs:QWORD\n.code\n" + "\n".join(asm) + "\nEND\n")
        io.open(os.path.join(outdir, f"{shim}.def"), "w", encoding="utf-8").write(
            f"LIBRARY {shim}\nEXPORTS\n" + "\n".join(defs) + "\n")
        built.append((dll, shim, n))
        print(f"{dll} -> {shim}.dll: {n} functions, fallbacks: {', '.join(fallbacks) or '-'}")
    io.open(os.path.join(outdir, "redirects.txt"), "w", encoding="utf-8").write(
        "\n".join(f"{dll}|{shim}.dll" for dll, shim, _ in built) + "\n")


if __name__ == "__main__":
    # gen_shims.py <imports.txt> [<more imports.txt> ...] <out dir>
    main(sys.argv[1:-1], sys.argv[-1])
