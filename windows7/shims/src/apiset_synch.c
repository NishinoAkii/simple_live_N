/* api-ms-win-core-synch-l1-2-0.dll for Windows 7 (Windows 8 API set):
 * WaitOnAddress / WakeByAddressSingle / WakeByAddressAll on SRW locks and
 * condition variables (both Vista+). Addresses hash into 64 buckets; a wake
 * wakes every waiter of the bucket, which WaitOnAddress allows (spurious
 * wakeups; callers re-check the value). The value is compared under the
 * bucket lock and SleepConditionVariableSRW releases it atomically, so a wake
 * between the compare and the sleep is not lost. No C runtime. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef struct {
    SRWLOCK lock;
    CONDITION_VARIABLE cv;
} Bucket;

static Bucket buckets[64]; /* zero = SRWLOCK_INIT / CONDITION_VARIABLE_INIT */

static Bucket *bucket_of(volatile void *address) {
    ULONG_PTR a = (ULONG_PTR)address;
    a ^= a >> 17;
    a ^= a >> 7;
    return &buckets[(a >> 3) & 63];
}

static BOOL same_value(volatile void *address, const void *compare, SIZE_T size) {
    switch (size) {
    case 1: return *(volatile BYTE *)address == *(const BYTE *)compare;
    case 2: return *(volatile WORD *)address == *(const WORD *)compare;
    case 4: return *(volatile DWORD *)address == *(const DWORD *)compare;
    case 8: return *(volatile DWORD64 *)address == *(const DWORD64 *)compare;
    default: {
        SIZE_T i;
        for (i = 0; i < size; i++) {
            if (((volatile BYTE *)address)[i] != ((const BYTE *)compare)[i]) return FALSE;
        }
        return TRUE;
    }
    }
}

BOOL WINAPI WaitOnAddress(volatile VOID *address, PVOID compare, SIZE_T size, DWORD ms) {
    Bucket *b;
    BOOL ok = TRUE;
    if (address == NULL || compare == NULL || size == 0 || size > 8) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    b = bucket_of(address);
    AcquireSRWLockExclusive(&b->lock);
    if (same_value(address, compare, size)) {
        ok = SleepConditionVariableSRW(&b->cv, &b->lock, ms, 0);
    }
    ReleaseSRWLockExclusive(&b->lock);
    return ok; /* FALSE + ERROR_TIMEOUT on timeout, as on Windows 8 */
}

static void wake(PVOID address) {
    Bucket *b = bucket_of(address);
    AcquireSRWLockExclusive(&b->lock);
    WakeAllConditionVariable(&b->cv);
    ReleaseSRWLockExclusive(&b->lock);
}

void WINAPI WakeByAddressSingle(PVOID address) { wake(address); }

void WINAPI WakeByAddressAll(PVOID address) { wake(address); }
