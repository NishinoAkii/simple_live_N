#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shlobj.h>
#include <windows.h>

#include <cwctype>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "d3d_guard.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// One string of this exe's VERSIONINFO, looked up the way path_provider does
// (US English, code page 1252 first, then Unicode).
std::wstring VersionString(std::vector<BYTE>& info, const wchar_t* key) {
  for (const wchar_t* block : {L"040904e4", L"040904b0"}) {
    std::wstring query =
        std::wstring(L"\\StringFileInfo\\") + block + L"\\" + key;
    wchar_t* value = nullptr;
    UINT length = 0;
    if (::VerQueryValueW(info.data(), query.c_str(),
                         reinterpret_cast<void**>(&value), &length) &&
        value != nullptr && length > 0) {
      return std::wstring(value, ::wcsnlen(value, length));
    }
  }
  return L"";
}

// path_provider's _sanitizedDirectoryName.
std::wstring SanitizedName(std::wstring name) {
  for (auto& c : name) {
    if (c != L'\0' && ::wcschr(L"<>:\"/\\|?*", c) != nullptr) {
      c = L'_';
    }
  }
  while (!name.empty() && std::iswspace(name.back())) {
    name.pop_back();
  }
  while (!name.empty() && name.back() == L'.') {
    name.pop_back();
  }
  if (name.size() > 255) {
    name.resize(255);
  }
  return name;
}

// The folder Dart gets from getApplicationSupportDirectory():
// %APPDATA%\<CompanyName>\<ProductName>, the product name falling back to the
// exe name. Test builds have their own product name, so their own folder.
std::wstring AppSupportDirectory() {
  wchar_t module[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, module, MAX_PATH) == 0) {
    return L"";
  }
  std::wstring company;
  std::wstring product;
  DWORD unused = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(module, &unused);
  if (size > 0) {
    std::vector<BYTE> info(size);
    if (::GetFileVersionInfoW(module, 0, size, info.data())) {
      company = SanitizedName(VersionString(info, L"CompanyName"));
      product = SanitizedName(VersionString(info, L"ProductName"));
    }
  }
  if (product.empty()) {
    std::wstring file(module);
    const size_t slash = file.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      file = file.substr(slash + 1);
    }
    const size_t dot = file.find_last_of(L'.');
    product = dot == std::wstring::npos ? file : file.substr(0, dot);
  }
  PWSTR roaming = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT,
                                    nullptr, &roaming)) ||
      roaming == nullptr) {
    return L"";
  }
  std::wstring directory(roaming);
  ::CoTaskMemFree(roaming);
  if (!company.empty()) {
    directory += L"\\" + company;
  }
  return directory + L"\\" + product;
}

// The GPU preference in the desktop settings page (GpuPreferenceSetting in
// Dart) is written to gpu_preference.txt in that folder and read here, so it
// takes effect on the next start.
// mpv draws with the D3D11 device media_kit creates on the adapter Flutter
// reports, so the video follows this choice too.
flutter::GpuPreference ReadGpuPreference() {
  const std::wstring directory = AppSupportDirectory();
  if (directory.empty()) {
    return flutter::GpuPreference::NoPreference;
  }
  // The file holds the GpuPreferenceSetting name; anything else means "auto".
  static const std::pair<const char*, flutter::GpuPreference> kChoices[] = {
      {"low_power", flutter::GpuPreference::LowPowerPreference},
      {"high_performance", flutter::GpuPreference::HighPerformancePreference},
  };
  std::string saved;
  std::ifstream(directory + L"\\gpu_preference.txt") >> saved;
  for (const auto& [name, preference] : kChoices) {
    if (saved == name) {
      return preference;
    }
  }
  return flutter::GpuPreference::NoPreference;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // Impeller, not Skia. With Skia the engine uploads and frees images on its
  // IO thread through a second GL context, on the same Direct3D 11 device the
  // raster thread draws with. On the NVIDIA driver 32.0.16.2124 that made the
  // app crash, freeze or lose the device in a live room, within minutes:
  // an access violation on a driver worker thread in nvwgf2umx.dll, or a jump
  // to address 0 from dxgi.dll when the window surface was re-created (window
  // moved to another monitor, maximized, resized). Impeller needs about
  // 15% more CPU and 80 MB more memory than Skia.
  project.set_impeller_switch(flutter::ImpellerSwitch::Enabled);
  // Which GPU Flutter (and with it mpv) uses, chosen in the settings.
  project.set_gpu_preference(ReadGpuPreference());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Impeller alone did not end the crashes in the NVIDIA driver: the engine
  // presents frames while its other thread uploads images on the same
  // Direct3D device. This has to run before the engine creates that device.
  InstallD3DGuard();
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Simple Live N", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    // Player shortcuts are taken before TranslateMessage, so the IME never
    // turns them into composition input.
    if (window.PreTranslateShortcutMessage(msg)) {
      continue;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // The window and the engine are shut down by now. Unloading the plugin DLLs
  // crashes on every exit (coremessaging.dll, while flutter_inappwebview tears
  // down), and writing the crash dump keeps the database locks for seconds, so
  // reopening the app right away cannot open the database. End the process here.
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
