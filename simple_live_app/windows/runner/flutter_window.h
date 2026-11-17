#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <set>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Called by the message loop before TranslateMessage. Returns true when the
  // message was taken as a player shortcut and must be neither translated nor
  // dispatched, so the IME and Flutter never see it.
  bool PreTranslateShortcutMessage(const MSG& msg);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  using ShortcutChannel = flutter::MethodChannel<flutter::EncodableValue>;

  void SetUpShortcutChannel();
  // "setCapture" from Dart: which keys to take, and whether the IME has to
  // stay out of the way meanwhile.
  void OnShortcutCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Takes the IME context away from the Flutter view, so a Chinese input
  // method cannot turn the shortcut letters into composition text.
  void SuspendIme();
  // Gives the view its default IME context back.
  void ResumeIme();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // simple_live/desktop_shortcuts: Dart says when to capture which keys, and
  // gets the captured key-downs back.
  std::unique_ptr<ShortcutChannel> shortcut_channel_;
  // Virtual-key codes taken while a live room is shown and no
  // text field has focus. Empty when nothing is captured.
  std::set<UINT> shortcut_keys_;
  // The Flutter view while its IME context is taken away, null otherwise.
  HWND ime_suspended_view_ = nullptr;
  // Scan codes (with the extended-key bit) whose key-down was taken, so the
  // matching key-up is taken too and Flutter never sees an unpaired event.
  std::set<UINT> swallowed_scan_codes_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
