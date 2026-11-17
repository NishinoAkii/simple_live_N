#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <imm.h>

#include <optional>
#include <utility>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::optional<int64_t> EncodableInt(const flutter::EncodableValue& value) {
  // Not "small": rpcndr.h defines it as a macro.
  if (const auto* value32 = std::get_if<int32_t>(&value)) {
    return *value32;
  }
  if (const auto* value64 = std::get_if<int64_t>(&value)) {
    return *value64;
  }
  return std::nullopt;
}

// What a "setCapture" call asks for.
struct CaptureRequest {
  bool ime_off = false;
  std::set<UINT> keys;
};

const flutter::EncodableValue* Field(const flutter::EncodableMap& map,
                                     const char* name) {
  auto found = map.find(flutter::EncodableValue(name));
  return found == map.end() ? nullptr : &found->second;
}

// Arguments: {"imeOff": bool, "keys": [virtual-key codes]}; anything missing
// or of the wrong type counts as "off" / "no keys".
CaptureRequest ReadCaptureRequest(const flutter::EncodableValue* arguments) {
  CaptureRequest request;
  const auto* map =
      arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (map == nullptr) {
    return request;
  }
  if (const auto* ime = Field(*map, "imeOff")) {
    if (const auto* off = std::get_if<bool>(ime)) {
      request.ime_off = *off;
    }
  }
  if (const auto* keys = Field(*map, "keys")) {
    if (const auto* list = std::get_if<flutter::EncodableList>(keys)) {
      for (const auto& key : *list) {
        if (auto vk = EncodableInt(key)) {
          request.keys.insert(static_cast<UINT>(*vk));
        }
      }
    }
  }
  return request;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetUpShortcutChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Dart may have shown the window already, maximized when it restored a
    // maximized window (WindowMemory). Showing it again with SW_SHOWNORMAL
    // would un-maximize it.
    if (!::IsWindowVisible(GetHandle())) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetUpShortcutChannel() {
  auto* messenger = flutter_controller_->engine()->messenger();
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  shortcut_channel_ = std::make_unique<ShortcutChannel>(
      messenger, "simple_live/desktop_shortcuts", &codec);
  shortcut_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        OnShortcutCall(call, std::move(result));
      });
}

void FlutterWindow::OnShortcutCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "setCapture") {
    result->NotImplemented();
    return;
  }
  CaptureRequest request = ReadCaptureRequest(call.arguments());
  shortcut_keys_ = std::move(request.keys);
  if (request.ime_off) {
    SuspendIme();
  } else {
    ResumeIme();
  }
  result->Success();
}

void FlutterWindow::SuspendIme() {
  if (ime_suspended_view_ != nullptr || !flutter_controller_ ||
      !flutter_controller_->view()) {
    return;
  }
  // The keyboard focus, and with it the IME context, is on the Flutter view
  // child window, not on this top-level window.
  HWND view = flutter_controller_->view()->GetNativeWindow();
  if (view != nullptr && ::ImmAssociateContextEx(view, nullptr, 0)) {
    ime_suspended_view_ = view;
  }
}

void FlutterWindow::ResumeIme() {
  HWND view = std::exchange(ime_suspended_view_, nullptr);
  if (view != nullptr && ::IsWindow(view)) {
    ::ImmAssociateContextEx(view, nullptr, IACE_DEFAULT);
  }
}

bool FlutterWindow::PreTranslateShortcutMessage(const MSG& msg) {
  if (msg.message != WM_KEYDOWN && msg.message != WM_KEYUP) {
    return false;
  }
  HWND hwnd = GetHandle();
  if (!hwnd || (msg.hwnd != hwnd && !::IsChild(hwnd, msg.hwnd))) {
    return false;
  }
  // Scan code plus the extended-key bit identifies the physical key.
  const UINT scan_code = (msg.lParam >> 16) & 0x1ff;
  if (msg.message == WM_KEYUP) {
    // Take the key-up only if its key-down was taken.
    return swallowed_scan_codes_.erase(scan_code) > 0;
  }
  if (shortcut_keys_.empty() || !shortcut_channel_) {
    return false;
  }
  // Leave Ctrl, Alt and Win combinations (Ctrl+C, Alt+F4, Win+D...) alone.
  if ((::GetKeyState(VK_CONTROL) & 0x8000) ||
      (::GetKeyState(VK_MENU) & 0x8000) || (::GetKeyState(VK_LWIN) & 0x8000) ||
      (::GetKeyState(VK_RWIN) & 0x8000)) {
    return false;
  }
  // Bit 30: auto-repeat. A repeat whose first key-down reached Flutter stays
  // with Flutter, or Flutter would never see the key-up.
  const bool repeat = (msg.lParam & (1 << 30)) != 0;
  if (repeat && swallowed_scan_codes_.count(scan_code) == 0) {
    return false;
  }
  UINT vk = static_cast<UINT>(msg.wParam);
  if (vk == VK_PROCESSKEY) {
    // The IME took the key already; get the key back from the scan code.
    const UINT extended = (scan_code & 0x100) ? 0xE000 : 0;
    vk = ::MapVirtualKeyW(extended | (scan_code & 0xff), MAPVK_VSC_TO_VK_EX);
  }
  if (shortcut_keys_.count(vk) == 0) {
    return false;
  }
  flutter::EncodableMap arguments = {
      {flutter::EncodableValue("vk"),
       flutter::EncodableValue(static_cast<int32_t>(vk))},
      {flutter::EncodableValue("repeat"), flutter::EncodableValue(repeat)},
  };
  shortcut_channel_->InvokeMethod(
      "keyDown", std::make_unique<flutter::EncodableValue>(arguments));
  swallowed_scan_codes_.insert(scan_code);
  return true;
}

void FlutterWindow::OnDestroy() {
  // Give the IME back before the Flutter view is torn down.
  ResumeIme();
  swallowed_scan_codes_.clear();
  shortcut_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    // Key-ups released while another window is active never arrive here.
    swallowed_scan_codes_.clear();
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
