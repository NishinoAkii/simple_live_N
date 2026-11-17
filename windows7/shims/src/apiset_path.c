/* api-ms-win-core-path-l1-1-0.dll for Windows 7 (Windows 8 API set).
 * Only what flutter_windows.dll imports: PathCchCombineEx, PathCchRemoveFileSpec,
 * PathAllocCanonicalize. Backslash paths; roots: "C:\", "\\server\share\",
 * "\\?\C:\", "\\?\UNC\server\share\". On Windows 8+ the API set resolves to the
 * system and this file is never loaded. No C runtime. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define E_BUFFER ((HRESULT)0x8007007AL) /* HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER) */
#define TEMP_CCH 32768

static size_t wlen(PCWSTR s) {
    size_t n = 0;
    if (s) while (s[n]) n++;
    return n;
}

static int starts(PCWSTR s, PCWSTR prefix) {
    while (*prefix) {
        if (*s++ != *prefix++) return 0;
    }
    return 1;
}

static int is_drive(PCWSTR s) {
    return ((s[0] >= L'A' && s[0] <= L'Z') || (s[0] >= L'a' && s[0] <= L'z')) && s[1] == L':';
}

/* length of the root, including its trailing backslash when present */
static size_t root_len(PCWSTR p) {
    size_t i = 0, parts;
    if (starts(p, L"\\\\?\\UNC\\")) {
        i = 8;
        goto unc;
    }
    if (starts(p, L"\\\\?\\")) {
        p += 4;
        if (is_drive(p)) return 4 + (p[2] == L'\\' ? 3 : 2);
        return 4;
    }
    if (starts(p, L"\\\\")) {
        i = 2;
    unc:
        for (parts = 0; parts < 2 && p[i]; parts++) {
            while (p[i] && p[i] != L'\\') i++;
            if (p[i] == L'\\') i++;
        }
        return i;
    }
    if (is_drive(p)) return p[2] == L'\\' ? 3 : 2;
    if (p[0] == L'\\') return 1;
    return 0;
}

/* collapse "." and ".." after the root; returns chars written or (size_t)-1 */
static size_t canonicalize(PCWSTR in, PWSTR out, size_t cch) {
    size_t r = root_len(in), o = 0, i;
    size_t starts_at[256];
    size_t depth = 0;
    if (r + 1 > cch) return (size_t)-1;
    for (i = 0; i < r; i++) out[o++] = in[i];
    i = r;
    while (in[i]) {
        size_t s = i, n;
        while (in[i] && in[i] != L'\\') i++;
        n = i - s;
        if (in[i] == L'\\') i++;
        if (n == 0 || (n == 1 && in[s] == L'.')) continue;
        if (n == 2 && in[s] == L'.' && in[s + 1] == L'.') {
            if (depth > 0) o = starts_at[--depth];
            continue;
        }
        /* ".." goes back to where this component started (before its separator) */
        if (depth < 256) starts_at[depth++] = o;
        /* separator, except right after a root ending in "\" and in "C:name" */
        if (o > 0 && out[o - 1] != L'\\' && !(o == r && out[o - 1] == L':')) {
            if (o + 1 >= cch) return (size_t)-1;
            out[o++] = L'\\';
        }
        if (o + n + 1 > cch) return (size_t)-1;
        while (n--) out[o++] = in[s++];
    }
    out[o] = 0;
    return o;
}

static HANDLE heap(void) { return GetProcessHeap(); }

HRESULT WINAPI PathCchCombineEx(PWSTR out, size_t cch_out, PCWSTR in, PCWSTR more, ULONG flags) {
    PWSTR tmp;
    size_t a, b, n = 0, k;
    (void)flags;
    if (out == NULL || cch_out == 0) return E_INVALIDARG;
    out[0] = 0;
    tmp = (PWSTR)HeapAlloc(heap(), 0, TEMP_CCH * sizeof(WCHAR));
    if (tmp == NULL) return E_OUTOFMEMORY;
    a = wlen(in);
    b = wlen(more);
    if (b > 0 && root_len(more) > 0 && (more[0] != L'\\' || more[1] == L'\\' || a == 0)) {
        /* "more" is absolute (drive or UNC, or nothing to join to) */
        for (k = 0; k < b && n + 1 < TEMP_CCH; k++) tmp[n++] = more[k];
    } else if (b > 0 && more[0] == L'\\') {
        /* "\x" relative to the root of "in" */
        size_t r = root_len(in);
        if (r > 0 && in[r - 1] == L'\\') r--;
        for (k = 0; k < r && n + 1 < TEMP_CCH; k++) tmp[n++] = in[k];
        for (k = 0; k < b && n + 1 < TEMP_CCH; k++) tmp[n++] = more[k];
    } else {
        for (k = 0; k < a && n + 1 < TEMP_CCH; k++) tmp[n++] = in[k];
        if (n > 0 && b > 0 && tmp[n - 1] != L'\\' && n + 1 < TEMP_CCH) tmp[n++] = L'\\';
        for (k = 0; k < b && n + 1 < TEMP_CCH; k++) tmp[n++] = more[k];
    }
    tmp[n] = 0;
    k = canonicalize(tmp, out, cch_out);
    HeapFree(heap(), 0, tmp);
    if (k == (size_t)-1) {
        out[0] = 0;
        return E_BUFFER;
    }
    return S_OK;
}

HRESULT WINAPI PathCchRemoveFileSpec(PWSTR path, size_t cch) {
    size_t r, n, i;
    if (path == NULL || cch == 0) return E_INVALIDARG;
    r = root_len(path);
    n = wlen(path);
    if (n <= r) return S_FALSE;
    i = n;
    while (i > r && path[i - 1] != L'\\') i--;
    /* drop the name and the backslash before it, but never the root */
    if (i > r) i--;
    if (i < r) i = r;
    path[i] = 0;
    return S_OK;
}

HRESULT WINAPI PathAllocCanonicalize(PCWSTR in, ULONG flags, PWSTR *out) {
    size_t n, cch;
    PWSTR buf;
    (void)flags;
    if (out == NULL) return E_INVALIDARG;
    *out = NULL;
    if (in == NULL) return E_INVALIDARG;
    n = wlen(in);
    cch = n + 2;
    buf = (PWSTR)LocalAlloc(LMEM_FIXED, cch * sizeof(WCHAR));
    if (buf == NULL) return E_OUTOFMEMORY;
    if (canonicalize(in, buf, cch) == (size_t)-1) {
        LocalFree(buf);
        return E_BUFFER;
    }
    *out = buf;
    return S_OK;
}
