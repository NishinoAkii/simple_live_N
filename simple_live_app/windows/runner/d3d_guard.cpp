#include "d3d_guard.h"

#include <d3d10_1.h>  // ID3D10Multithread; d3d10.h alone clashes with d3d11.h
#include <d3d11_4.h>
#include <windows.h>

#include <cstring>
#include <cwchar>

// Why
//
// Flutter draws through ANGLE on one Direct3D 11 device. Its raster thread
// draws and presents the frames, its IO thread uploads decoded images (every
// frame of an animated image is one upload). ANGLE puts the GL calls of both
// threads behind one global lock, but in Flutter 3.50 eglSwapBuffers, and with
// it IDXGISwapChain::Present, runs outside that lock. A Present can therefore
// run while the other thread is inside the immediate context. Direct3D 11
// allows that only on a device with multithread protection, which ANGLE does
// not turn on.
//
// On the NVIDIA driver 32.0.16.2124 this broke the driver's command queue:
// the app crashed in nvwgf2umx.dll or its picture froze (sound went on), some
// tens of minutes into a stream, sooner with animated emotes in the chat. A
// stress run (video plus 60 animated images, window maximized) died within 10
// seconds without the protection and ran its full 25 minutes with it.
//
// How
//
// The engine has no setting for this and does not hand out its device, so the
// device is caught where it is made. ANGLE looks D3D11CreateDevice up with
// GetProcAddress; the GetProcAddress import of flutter_windows.dll is pointed
// at a wrapper that hands out our D3D11CreateDevice, which turns the protection
// on for each device it returns. Nothing else in the process is touched: the
// video plugin and other libraries create their devices through their own
// imports.
//
// If a later Flutter finds D3D11CreateDevice some other way, nothing breaks,
// but the protection is gone. The outcome is written to the environment
// variable SIMPLE_LIVE_D3D_GUARD of this process ("hook=1 devices=1
// protected=1"), which the Dart side puts into the log at startup.

namespace {

using CreateDeviceFn = HRESULT(WINAPI*)(IDXGIAdapter*, D3D_DRIVER_TYPE, HMODULE,
                                        UINT, const D3D_FEATURE_LEVEL*, UINT,
                                        UINT, ID3D11Device**,
                                        D3D_FEATURE_LEVEL*,
                                        ID3D11DeviceContext**);
using GetProcFn = FARPROC(WINAPI*)(HMODULE, LPCSTR);

CreateDeviceFn g_real_create = nullptr;
GetProcFn g_real_get_proc = nullptr;
// Import slots redirected, devices seen, devices protected.
LONG g_hooks = 0;
LONG g_devices = 0;
LONG g_protected = 0;

void Report() {
  wchar_t text[80];
  ::swprintf_s(text, L"hook=%ld devices=%ld protected=%ld", g_hooks, g_devices,
               g_protected);
  ::SetEnvironmentVariableW(L"SIMPLE_LIVE_D3D_GUARD", text);
}

bool Protect(ID3D11Device* device) {
  ID3D11DeviceContext* context = nullptr;
  device->GetImmediateContext(&context);
  if (context == nullptr) {
    return false;
  }
  bool done = false;
  ID3D11Multithread* multithread = nullptr;
  if (SUCCEEDED(context->QueryInterface(
          __uuidof(ID3D11Multithread),
          reinterpret_cast<void**>(&multithread))) &&
      multithread != nullptr) {
    multithread->SetMultithreadProtected(TRUE);
    multithread->Release();
    done = true;
  } else {
    // Windows without Direct3D 11.4: the same switch under its older name.
    ID3D10Multithread* legacy = nullptr;
    if (SUCCEEDED(device->QueryInterface(__uuidof(ID3D10Multithread),
                                         reinterpret_cast<void**>(&legacy))) &&
        legacy != nullptr) {
      legacy->SetMultithreadProtected(TRUE);
      legacy->Release();
      done = true;
    }
  }
  context->Release();
  return done;
}

HRESULT WINAPI CreateDevice(IDXGIAdapter* adapter, D3D_DRIVER_TYPE type,
                            HMODULE software, UINT flags,
                            const D3D_FEATURE_LEVEL* levels, UINT level_count,
                            UINT sdk, ID3D11Device** device,
                            D3D_FEATURE_LEVEL* level,
                            ID3D11DeviceContext** context) {
  const HRESULT hr = g_real_create(adapter, type, software, flags, levels,
                                   level_count, sdk, device, level, context);
  if (SUCCEEDED(hr) && device != nullptr && *device != nullptr) {
    ::InterlockedIncrement(&g_devices);
    if (Protect(*device)) {
      ::InterlockedIncrement(&g_protected);
    }
    Report();
  }
  return hr;
}

FARPROC WINAPI GetProc(HMODULE module, LPCSTR name) {
  const FARPROC real = g_real_get_proc(module, name);
  // A "name" below 0x10000 is an ordinal.
  if (real != nullptr && (reinterpret_cast<ULONG_PTR>(name) >> 16) != 0 &&
      std::strcmp(name, "D3D11CreateDevice") == 0) {
    g_real_create = reinterpret_cast<CreateDeviceFn>(real);
    return reinterpret_cast<FARPROC>(&CreateDevice);
  }
  return real;
}

// Points every import of [function] in [module]'s import table at
// [replacement]. Returns how many slots were changed; [previous] gets what
// the first of them held.
LONG RedirectImport(HMODULE module, const char* function, void* replacement,
                    void** previous) {
  const auto base = reinterpret_cast<BYTE*>(module);
  const auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  const auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
  const IMAGE_DATA_DIRECTORY& directory =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (directory.VirtualAddress == 0) {
    return 0;
  }
  LONG changed = 0;
  for (auto dll = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
           base + directory.VirtualAddress);
       dll->Name != 0; ++dll) {
    if (dll->OriginalFirstThunk == 0) {
      continue;
    }
    auto name =
        reinterpret_cast<IMAGE_THUNK_DATA*>(base + dll->OriginalFirstThunk);
    auto slot = reinterpret_cast<IMAGE_THUNK_DATA*>(base + dll->FirstThunk);
    for (; name->u1.AddressOfData != 0; ++name, ++slot) {
      if (IMAGE_SNAP_BY_ORDINAL(name->u1.Ordinal)) {
        continue;
      }
      const auto entry = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(
          base + name->u1.AddressOfData);
      if (std::strcmp(entry->Name, function) != 0) {
        continue;
      }
      DWORD protection = 0;
      if (!::VirtualProtect(&slot->u1.Function, sizeof(void*), PAGE_READWRITE,
                            &protection)) {
        continue;
      }
      if (changed == 0) {
        *previous = reinterpret_cast<void*>(slot->u1.Function);
      }
      slot->u1.Function = reinterpret_cast<ULONG_PTR>(replacement);
      ::VirtualProtect(&slot->u1.Function, sizeof(void*), protection,
                       &protection);
      ++changed;
    }
  }
  return changed;
}

}  // namespace

void InstallD3DGuard() {
  const HMODULE flutter = ::GetModuleHandleW(L"flutter_windows.dll");
  if (flutter != nullptr && g_hooks == 0) {
    // g_real_get_proc has to be set before the slot points at GetProc.
    const HMODULE kernel32 = ::GetModuleHandleW(L"kernel32.dll");
    g_real_get_proc = kernel32 == nullptr
                          ? nullptr
                          : reinterpret_cast<GetProcFn>(
                                ::GetProcAddress(kernel32, "GetProcAddress"));
    if (g_real_get_proc != nullptr) {
      void* previous = nullptr;
      g_hooks = RedirectImport(flutter, "GetProcAddress",
                               reinterpret_cast<void*>(&GetProc), &previous);
      if (previous != nullptr) {
        // What the slot held: the same function, unless something else had
        // already redirected it, and then that one must stay in the chain.
        g_real_get_proc = reinterpret_cast<GetProcFn>(previous);
      }
    }
  }
  // Also when nothing was hooked: a child window process must not keep the
  // value it inherited from the main window's process.
  Report();
}
