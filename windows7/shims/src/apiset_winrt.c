/* WinRT API sets for Windows 7 (share_plus_plugin.dll imports them).
 * Windows 7 has no WinRT: activation reports "class not registered", so
 * sharing fails with an error instead of the whole app failing to load.
 * One source, built three times with -DSHIM_CORE / -DSHIM_STRING / -DSHIM_ERROR.
 * No C runtime. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef void *HSTRING_;

#ifdef SHIM_CORE
HRESULT WINAPI RoGetActivationFactory(HSTRING_ class_id, REFIID iid, void **factory) {
    (void)class_id; (void)iid;
    if (factory) *factory = NULL;
    return (HRESULT)0x80040154L; /* REGDB_E_CLASSNOTREG */
}
#endif

#ifdef SHIM_STRING
typedef struct {
    UINT32 length;
    WCHAR text[1];
} ShimString;

static HRESULT make(const WCHAR *src, UINT32 length, HSTRING_ *out) {
    ShimString *s;
    UINT32 i;
    if (out == NULL) return E_INVALIDARG;
    *out = NULL;
    if (length == 0) return S_OK; /* empty string = NULL HSTRING */
    if (src == NULL) return E_POINTER;
    s = (ShimString *)HeapAlloc(GetProcessHeap(), 0, sizeof(ShimString) + length * sizeof(WCHAR));
    if (s == NULL) return E_OUTOFMEMORY;
    s->length = length;
    for (i = 0; i < length; i++) s->text[i] = src[i];
    s->text[length] = 0;
    *out = s;
    return S_OK;
}

HRESULT WINAPI WindowsCreateString(const WCHAR *src, UINT32 length, HSTRING_ *out) {
    return make(src, length, out);
}

/* the header is the caller's; a copy is simpler and Windows 7 never uses it */
HRESULT WINAPI WindowsCreateStringReference(const WCHAR *src, UINT32 length, void *header,
                                            HSTRING_ *out) {
    (void)header;
    return make(src, length, out);
}
#endif

#ifdef SHIM_ERROR
BOOL WINAPI RoOriginateError(HRESULT error, HSTRING_ message) {
    (void)error; (void)message;
    return FALSE;
}
#endif
