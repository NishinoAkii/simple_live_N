/* WinRT API sets for Windows 7 (share_plus_plugin.dll imports them).
 * Windows 7 has no WinRT: activation reports "class not registered", so
 * sharing fails with an error instead of the whole app failing to load.
 * One source, built four times with -DSHIM_CORE / -DSHIM_STRING / -DSHIM_ERROR / -DSHIM_ERROR11.
 * SHIM_ERROR11 is api-ms-win-core-winrt-error-l1-1-1: newer Windows SDKs (C++/WinRT) make the
 * notification plugin import from it; every function only reports "no error information".
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

#if defined(SHIM_ERROR) || defined(SHIM_ERROR11)
BOOL WINAPI RoOriginateError(HRESULT error, HSTRING_ message) {
    (void)error; (void)message;
    return FALSE;
}
#endif

#ifdef SHIM_ERROR11
BOOL WINAPI RoOriginateErrorW(HRESULT error, UINT length, const WCHAR *message) {
    (void)error; (void)length; (void)message;
    return FALSE;
}

BOOL WINAPI RoOriginateLanguageException(HRESULT error, HSTRING_ message, void *exception) {
    (void)error; (void)message; (void)exception;
    return FALSE;
}

BOOL WINAPI RoTransformError(HRESULT old_error, HRESULT new_error, HSTRING_ message) {
    (void)old_error; (void)new_error; (void)message;
    return FALSE;
}

BOOL WINAPI RoTransformErrorW(HRESULT old_error, HRESULT new_error, UINT length, const WCHAR *message) {
    (void)old_error; (void)new_error; (void)length; (void)message;
    return FALSE;
}

HRESULT WINAPI RoCaptureErrorContext(HRESULT error) {
    (void)error;
    return S_OK;
}

void WINAPI RoFailFastWithErrorContext(HRESULT error) {
    TerminateProcess(GetCurrentProcess(), (UINT)error);
}

void WINAPI RoClearError(void) {
}

HRESULT WINAPI RoReportUnhandledError(void *info) {
    (void)info;
    return S_OK;
}

HRESULT WINAPI GetRestrictedErrorInfo(void **info) {
    if (info) *info = NULL;
    return S_FALSE;
}

HRESULT WINAPI SetRestrictedErrorInfo(void *info) {
    (void)info;
    return S_OK;
}

HRESULT WINAPI RoGetMatchingRestrictedErrorInfo(HRESULT error, void **info) {
    (void)error;
    if (info) *info = NULL;
    return S_FALSE;
}

BOOL WINAPI IsErrorPropagationEnabled(void) {
    return FALSE;
}
#endif
